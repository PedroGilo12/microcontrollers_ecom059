#include <avr/io.h>

; --- Mapeamento de Hardware ---
; Pinos de chaveamento dos displays
.equiv DISPLAY_PORT,    PORTB
.equiv DISPLAY_DDR,     DDRB
.equiv DISPLAY_PIN_0,   1        
.equiv DISPLAY_PIN_1,   2        
.equiv DISPLAY_PIN_2,   3        
.equiv DISPLAY_PIN_3,   4        

; Máscara com todos os pinos de display: 0b00011110
.equiv DISPLAY_MASK,    (1 << DISPLAY_PIN_0) | (1 << DISPLAY_PIN_1) | (1 << DISPLAY_PIN_2) | (1 << DISPLAY_PIN_3)

; Pinos do barramento BCD compartilhado entre os displays
.equiv BCD_PORT,        PORTC
.equiv BCD_DDR,         DDRC
.equiv BCD_PIN_0,       0        
.equiv BCD_PIN_1,       1        
.equiv BCD_PIN_2,       2        
.equiv BCD_PIN_3,       3        

; Máscara com todos os pinos BCD: 0b00111100
.equiv BCD_MASK,        (1 << BCD_PIN_0) | (1 << BCD_PIN_1) | (1 << BCD_PIN_2) | (1 << BCD_PIN_3)

; A ideia é simular o que o "tick" de um OS represente
; ou seja, o menor tempo possível para execução de uma tarefa
; Para isso o Timer1 vai estourar a cada 1 segundo
; E cada tarefa vai possui um contador que será decrementado
.section .bss
display_pool_tick_counter: .byte 1	; Reserva 1 byte para armazenar o contador de tick que chaveia os displays
main_clock_tick_counter_low: .byte 1    ; Reserva 2 bytes para o contador natural do relógio 
main_clock_tick_counter_high: .byte 1   ; Reserva 2 bytes para o contador natural do relógio

;  Flags
display_pool_event_flag: .byte 1
main_clock_event_flag: .byte 1

; Variáveis
display_index:      .byte 1
seconds_units:      .byte 1
seconds_tens:       .byte 1
minutes_units:      .byte 1
minutes_tens:       .byte 1
display_digits:     .byte 4
    
; --- Definições de Configuração ---
; Cálculo para 1ms @ 16MHz:
; F_CPU / (Prescaler * Desired_Freq) - 1
; 16.000.000 / (64 * 1000) - 1 = 249
.equiv TIMER_TOP, 249        ; Valor de comparação para 1ms

.equiv DISPLAY_POOL_PERIOD_TICK, 8  ; Chaveamento a 30hz, periodo = (1/30)/4, 4 = numero de displays
.equiv MAIN_CLOCK_PERIOD_TICK, 1000 ; Periodo de atualização do valor a cada 1 segundo
; --- Registradores para armazenar as contagens regressivas das tarefas
.section .text

.global main
.global __vector_14          ; Vetor de interrupção: TIMER0_COMPA

; Registradores especificos
.set seconds, r18
.set minutes, r19
.set hours, r20
 
; --- Rotina de Interrupção ---
__vector_14:
    ; Salva o contexto
    push r16
    in r16, _SFR_IO_ADDR(SREG)
    push r16

    ; Decrementa e verifica o contador do chaveamento de display
    lds r16, display_pool_tick_counter
    tst r16
    breq _display_tick
    dec r16
    sts display_pool_tick_counter, r16

_check_main_clock:
    ; Decrementa e verifica o contador do relógio principal
    push r17

    lds r16, main_clock_tick_counter_low
    lds r17, main_clock_tick_counter_high

    subi r16, 1
    sbci r17, 0

    ; O comando sbci preserva a flag Z (Zero) acionada pelo subi anterior.
    ; O breq só vai saltar se a flag Z continuar ativa após as duas operações, 
    ; o que significa que o valor total de 16 bits (r17:r16) chegou a 0.
    breq _main_clock_tick

    sts main_clock_tick_counter_low, r16
    sts main_clock_tick_counter_high, r17
    
    pop r17

    ; Restaura o contexto
_end_isr:
    pop r16
    out _SFR_IO_ADDR(SREG), r16
    pop r16
    reti

_display_tick:
    ; Recarrega o período
    ldi r16, DISPLAY_POOL_PERIOD_TICK
    sts display_pool_tick_counter, r16
    
    ; Apenas levanta a flag
    ldi r16, 1
    sts display_pool_event_flag, r16
    
    ; Continua para decrementa o relógio principal
    rjmp _check_main_clock
    
_main_clock_tick:
    ; Recarrega o período
    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_low, r16
    ldi r16, hi8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_high, r16
    
    ; Apenas levanta a flag
    ldi r16, 1
    sts main_clock_event_flag, r16
    pop r17
    rjmp _end_isr

; --- Setup e Loop ---
main:    
    ; Inicializa os contadores na RAM com os períodos iniciais
    ldi r16, DISPLAY_POOL_PERIOD_TICK
    sts display_pool_tick_counter, r16

    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_low, r16
    ldi r17, hi8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_high, r17

    ; Configura os pinos de chaveamento dos displays como saída
    in r16, _SFR_IO_ADDR(DISPLAY_DDR)
    ori r16, DISPLAY_MASK
    out _SFR_IO_ADDR(DISPLAY_DDR), r16

    ; Garante que todos os displays comecem desligados
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)
    andi r16, ~DISPLAY_MASK
    out _SFR_IO_ADDR(DISPLAY_PORT), r16
    
    ; Configura Timer0: Modo CTC, Prescaler 64
    ldi r16, (1 << WGM01)
    out _SFR_IO_ADDR(TCCR0A), r16
    ldi r16, TIMER_TOP
    out _SFR_IO_ADDR(OCR0A), r16
    ldi r16, (1 << OCIE0A)
    sts TIMSK0, r16
    ldi r16, (1 << CS01) | (1 << CS00)
    out _SFR_IO_ADDR(TCCR0B), r16
    sei
    
    rcall update_display_digits   ; Inicializa display_digits com 00:00

loop:
    rcall display_pool               ; Executa a tarefa de chaveamento do display
    rcall main_clock
    
    ; Futuramente outras subrotinas podem ser chamadas aqui
    ; rcall outra_tarefa
    
    rjmp loop
    
; ############################ Sub Rotinas #####################################
    
; ------------------- Começo Display Pool --------------------------------------
display_pool:
    ; Verifica se a ISR sinalizou um evento de chaveamento de display
    lds r16, display_pool_event_flag
    tst r16
    breq _end_display_pool           ; Nenhum evento pendente: sai da sub-rotina

    ; Consome a flag
    ldi r16, 0
    sts display_pool_event_flag, r16

    ; Desliga o display atual antes de trocar
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)
    andi r16, ~DISPLAY_MASK
    out _SFR_IO_ADDR(DISPLAY_PORT), r16
    
    ; Incrementa o índice PRIMEIRO
    lds r16, display_index
    inc r16
    cpi r16, 4
    brne _save_index
    ldi r16, 0

_save_index:
    sts display_index, r16          ; Salva o novo índice (0-3) na RAM

    ldi r30, lo8(display_digits + 3)  ; começa apontando para o último elemento
    ldi r31, hi8(display_digits + 3)
    sub r30, r16                       ; recua o ponteiro: display_digits[3 - index]
    ld  r17, Z

    in  r16, _SFR_IO_ADDR(BCD_PORT) ; Lê o estado atual do PORT C
    andi r16, ~BCD_MASK             ; Limpa apenas os bits BCD, preserva os outros pinos do PORT C
    andi r17, 0x0F                  ; Garante que só os 4 bits baixos do dígito serão usados
    or  r16, r17                    ; Combina os bits BCD do dígito com o restante do PORT C
    out _SFR_IO_ADDR(BCD_PORT), r16 ; Envia o valor BCD para os pinos

    lds r16, display_index          ; Recarrega o índice atual (0-3)
    ldi r17, (1 << DISPLAY_PIN_0)   ; R17 = máscara inicial apontando para o display 0 (bit 1 de PORTB)
    tst r16                         ; Testa se índice == 0
    breq _apply_display             ; Se sim, já está no display certo, não precisa deslocar

_shift_loop:
    lsl r17
    dec r16
    brne _shift_loop

_apply_display:
    ; Liga apenas o display ativo
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)
    andi r16, ~DISPLAY_MASK          ; Desliga todos os displays
    or r16, r17                      ; Liga apenas o display do índice atual
    out _SFR_IO_ADDR(DISPLAY_PORT), r16

_end_display_pool:
    ret
; ------------------- Fim Display Pool --------------------------------------
; ------------------- Começo Main Clock --------------------------------------
main_clock:
    ; Verifica se a ISR sinalizou o evento de 1 segundo
    lds r16, main_clock_event_flag
    tst r16
    breq _end_main_clock             ; Nenhum evento pendente: sai da sub-rotina

    ; Consome a flag para evitar decrementos múltiplos
    ldi r16, 0
    sts main_clock_event_flag, r16

    ; Apenas decrementa a variável de tempo global (r22)
    lds r16, seconds_units
    inc r16
    cpi r16, 10
    brlo _save_sec_units
    ldi r16, 0
    sts seconds_units, r16
    rjmp _inc_sec_tens

_save_sec_units:
    sts seconds_units, r16
    rjmp _end_main_clock

_inc_sec_tens:
    lds r16, seconds_tens
    inc r16
    cpi r16, 6
    brlo _save_sec_tens
    ldi r16, 0
    sts seconds_tens, r16
    rjmp _inc_min_units

_save_sec_tens:
    sts seconds_tens, r16
    rjmp _end_main_clock

_inc_min_units:
    lds r16, minutes_units
    inc r16
    cpi r16, 10
    brlo _save_min_units
    ldi r16, 0
    sts minutes_units, r16
    rjmp _inc_min_tens

_save_min_units:
    sts minutes_units, r16
    rjmp _end_main_clock

_inc_min_tens:
    lds r16, minutes_tens
    inc r16
    cpi r16, 6
    brlo _save_min_tens
    ldi r16, 0

_save_min_tens:
    sts minutes_tens, r16

_end_main_clock:
    rcall update_display_digits
    ret

update_display_digits:
    lds r16, minutes_tens
    sts display_digits,     r16
    lds r16, minutes_units
    sts display_digits + 1, r16
    lds r16, seconds_tens
    sts display_digits + 2, r16
    lds r16, seconds_units
    sts display_digits + 3, r16
    ret