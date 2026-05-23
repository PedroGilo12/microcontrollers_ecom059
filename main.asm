#include <avr/io.h>

; --- Mapeamento de Hardware ---
; Pinos de chaveamento dos displays
.equiv DISPLAY_PORT,    PORTB
.equiv DISPLAY_DDR,     DDRB
.equiv DISPLAY_PIN_0,   1        
.equiv DISPLAY_PIN_1,   2        
.equiv DISPLAY_PIN_2,   3        
.equiv DISPLAY_PIN_3,   4    
.equiv DEBUG_LED_PIN, 0

; Mascara com todos os pinos de display: 0b00011110
.equiv DISPLAY_MASK,    (1 << DISPLAY_PIN_0) | (1 << DISPLAY_PIN_1) | (1 << DISPLAY_PIN_2) | (1 << DISPLAY_PIN_3)

; Pinos do barramento BCD compartilhado entre os displays
.equiv BCD_PORT,        PORTC
.equiv BCD_DDR,         DDRC
.equiv BCD_PIN_0,       0        
.equiv BCD_PIN_1,       1        
.equiv BCD_PIN_2,       2        
.equiv BCD_PIN_3,       3        

; Mascara com todos os pinos BCD: 0b00111100
.equiv BCD_MASK,        (1 << BCD_PIN_0) | (1 << BCD_PIN_1) | (1 << BCD_PIN_2) | (1 << BCD_PIN_3)

; Botoes (PORTD - PCINT2)
.equiv BTN_PORT,        PORTD
.equiv BTN_DDR,         DDRD
.equiv BTN_PIN,         PIND
.equiv BTN_MODE_PIN,    0        ; PD0 = botao MODE  (PCINT16)
.equiv BTN_START_PIN,   3        ; PD3 = botao START (PCINT19)
.equiv BTN_RESET_PIN,   2        ; PD2 = botao RESET (PCINT18)

; Mascara com os tres botoes
.equiv BTN_MASK,        (1 << BTN_MODE_PIN) | (1 << BTN_START_PIN) | (1 << BTN_RESET_PIN)

; A ideia e simular o que o "tick" de um OS represente
; ou seja, o menor tempo possivel para execucao de uma tarefa
; Para isso o Timer1 vai estourar a cada 1 segundo
; E cada tarefa vai possui um contador que sera decrementado
.section .bss
display_pool_tick_counter: .byte 1	; Reserva 1 byte para armazenar o contador de tick que chaveia os displays
main_clock_tick_counter_low: .byte 1    ; Reserva 2 bytes para o contador natural do relogio 
main_clock_tick_counter_high: .byte 1   ; Reserva 2 bytes para o contador natural do relogio
blink_counter: .byte 1    ; contador para piscar o dígito selecionado    

;  Flags
display_pool_event_flag: .byte 1
main_clock_event_flag: .byte 1
chrono_clock_event_flag: .byte 1 
blink_event_flag:   .byte 1     
    
btn_start_flag:   .byte 1
btn_mode_flag:    .byte 1
btn_reset_flag:   .byte 1
    
uart_print_flag: .byte 1   ; levantada quando deve imprimir na serial no modo 1   

; Estado atual
current_mode: .byte 1    
    
; Botoes
last_portd_state:   .byte 1
    
; Variaveis
display_index:      .byte 1
blink_state: .byte 1    
    
; Valores do relogio principal
seconds_units:      .byte 1
seconds_tens:       .byte 1
minutes_units:      .byte 1
minutes_tens:       .byte 1

; Valores do cronometro
chrono_seconds_units:   .byte 1
chrono_seconds_tens:    .byte 1
chrono_minutes_units:   .byte 1
chrono_minutes_tens:    .byte 1

; Buffer para o valor temporario de ajuste
adjust_seconds_units:   .byte 1
adjust_seconds_tens:    .byte 1
adjust_minutes_units:   .byte 1
adjust_minutes_tens:    .byte 1

; Valor selecionado
selected_digit: .byte 1
    
display_digits:     .byte 4
    
; --- Definicoes de Configuracao ---
; Calculo para 1ms @ 16MHz:
; F_CPU / (Prescaler * Desired_Freq) - 1
; 16.000.000 / (64 * 1000) - 1 = 249
.equiv TIMER_TOP, 249        ; Valor de comparacao para 1ms

.equiv DISPLAY_POOL_PERIOD_TICK, 8  ; Chaveamento a 30hz, periodo = (1/30)/4, 4 = numero de displays
.equiv MAIN_CLOCK_PERIOD_TICK, 1000 ; Periodo de atualizacao do valor a cada 1 segundo
.equiv BLINK_PERIOD, 250  ; pisca a cada 250ms   
    
; --- Registradores para armazenar as contagens regressivas das tarefas
.section .text
    
str_modo1:    .ascii "[MODO 1] "
              .byte 0
str_modo2_zero:  .ascii "[MODO 2] ZERO"
                 .byte 10, 13, 0
str_modo2_start: .ascii "[MODO 2] START"
                 .byte 10, 13, 0
str_modo2_reset: .ascii "[MODO 2] RESET"
                 .byte 10, 13, 0
str_modo3_useg:  .ascii "[MODO 3] Ajustando a unidade dos segundos"
                 .byte 10, 13, 0
str_modo3_dseg:  .ascii "[MODO 3] Ajustando a dezena dos segundos"
                 .byte 10, 13, 0
str_modo3_umin:  .ascii "[MODO 3] Ajustando a unidade dos minutos"
                 .byte 10, 13, 0
str_modo3_dmin:  .ascii "[MODO 3] Ajustando a dezena dos minutos"
                 .byte 10, 13, 0

.global main
.global __vector_14          ; Vetor de interrupcao: TIMER0_COMPA
.global __vector_5           ; Vetor de interrupcao: PCINT2 (PORTD)
 
; --- Rotina de Interrupcao ---
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

_check_blink_counter:    
    lds r16, blink_counter
    tst r16
    breq _blink_tick
    dec r16
    sts blink_counter, r16
    rjmp _check_main_clock      ; continua para o clock principal

_check_main_clock:
    ; Decrementa e verifica o contador do relogio principal
    push r17

    lds r16, main_clock_tick_counter_low
    lds r17, main_clock_tick_counter_high

    subi r16, 1
    sbci r17, 0

    ; O comando sbci preserva a flag Z (Zero) acionada pelo subi anterior.
    ; O breq so vai saltar se a flag Z continuar ativa apos as duas operacoes, 
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
    ; Recarrega o periodo
    ldi r16, DISPLAY_POOL_PERIOD_TICK
    sts display_pool_tick_counter, r16
    
    ; Apenas levanta a flag
    ldi r16, 1
    sts display_pool_event_flag, r16
    
    ; Continua para decrementa o relogio principal
    rjmp _check_blink_counter
    
 _blink_tick:
    ; Recarrega o período
    ldi r16, BLINK_PERIOD
    sts blink_counter, r16
    ; Levanta a flag
    ldi r16, 1
    sts blink_event_flag, r16
    rjmp _check_main_clock
    
_main_clock_tick:
    ; Recarrega o periodo
    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_low, r16
    ldi r16, hi8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_high, r16

    ; Apenas levanta a flag
    ldi r16, 1
    sts main_clock_event_flag, r16
    sts chrono_clock_event_flag, r16
    
    pop r17
    rjmp _end_isr

; --- ISR PCINT2: deteccao de borda de descida dos botoes em PORTD ---
__vector_5:
    ; Salva contexto
    push r16
    in r16, _SFR_IO_ADDR(SREG)
    push r16
    push r17
    push r18

    ; Le o estado atual do PIND e o estado anterior
    in   r16, _SFR_IO_ADDR(BTN_PIN)    ; r16 = estado atual
    lds  r17, last_portd_state         ; r17 = estado anterior

    ; Borda de descida: pino era 1 e agora e 0
    ;   pressionado = (~atual) & anterior
    mov  r18, r16
    com  r18                           ; r18 = ~atual
    and  r18, r17                      ; r18 = (~atual) & anterior

    ; Atualiza o estado anterior com o estado atual
    sts  last_portd_state, r16

    ; r17 sera reutilizado como constante 1 para escrever nas flags
    ldi  r17, 1

    ; Borda de descida no MODE (PD0)?
    sbrc r18, BTN_MODE_PIN
    sts  btn_mode_flag, r17

    ; Borda de descida no START (PD1)?
    sbrc r18, BTN_START_PIN
    sts  btn_start_flag, r17

    ; Borda de descida no RESET (PD2)?
    sbrc r18, BTN_RESET_PIN
    sts  btn_reset_flag, r17

_end_pcint2:
    pop r18
    pop r17
    pop r16
    out _SFR_IO_ADDR(SREG), r16
    pop r16
    reti

; --- Setup e Loop ---
main:    
    ; Inicializa os contadores na RAM com os perï¿½odos iniciais
    ldi r16, DISPLAY_POOL_PERIOD_TICK
    sts display_pool_tick_counter, r16

    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_low, r16
    ldi r17, hi8(MAIN_CLOCK_PERIOD_TICK)
    sts main_clock_tick_counter_high, r17
    
    ldi r16, BLINK_PERIOD
    sts blink_counter, r16

    ; Configura os pinos de chaveamento dos displays como saï¿½da
    in r16, _SFR_IO_ADDR(DISPLAY_DDR)
    ori r16, DISPLAY_MASK
    out _SFR_IO_ADDR(DISPLAY_DDR), r16
    
    sbi _SFR_IO_ADDR(DDRB), DEBUG_LED_PIN

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

    ; Configura PD0 (MODE), PD1 (START) e PD2 (RESET) como entrada com pull-up
    in  r16, _SFR_IO_ADDR(BTN_DDR)
    andi r16, ~BTN_MASK                ; PD0, PD1, PD2 como entrada
    out _SFR_IO_ADDR(BTN_DDR), r16

    in  r16, _SFR_IO_ADDR(BTN_PORT)
    ori r16, BTN_MASK                  ; Ativa pull-up em PD0, PD1, PD2
    out _SFR_IO_ADDR(BTN_PORT), r16

    ; Inicializa last_portd_state com o estado atual do PIND
    ; (evita falsa borda de descida no primeiro disparo)
    in  r16, _SFR_IO_ADDR(BTN_PIN)
    sts last_portd_state, r16

    ; Habilita PCINT16 (PD0), PCINT17 (PD1) e PCINT18 (PD2) em PCMSK2
    ldi r16, (1 << PCINT16) | (1 << PCINT19) | (1 << PCINT18)
    sts PCMSK2, r16

    ; Habilita o grupo PCINT2 em PCICR
    lds r16, PCICR
    ori r16, (1 << PCIE2)
    sts PCICR, r16
    
    ldi r16, 0
    ldi r17, 0
    ldi r18, 0
    ldi r19, 0
    rcall update_display_digits
    
    ldi r16, 1
    sts current_mode, r16        ; inicia no MODO 1
    
    ; Configura UART: 9600 baud @ 16MHz
    ; UBRR = F_CPU / (16 * BAUD) - 1 = 16000000 / (16 * 9600) - 1 = 103
    ldi r16, 0
    sts UBRR0H, r16
    ldi r16, 103
    sts UBRR0L, r16

    ; Habilita transmissor
    ldi r16, (1 << TXEN0)
    sts UCSR0B, r16

    ; Formato: 8 bits, 1 stop bit, sem paridade
    ldi r16, (1 << UCSZ01) | (1 << UCSZ00)
    sts UCSR0C, r16
    
    cbi _SFR_IO_ADDR(PORTB), DEBUG_LED_PIN
    
    sei

loop:
    rcall display_pool               ; Executa a tarefa de chaveamento do display
    rcall main_clock		     ; Executa a atualizacao do relogio
    rcall state_machine		     ; Executa a maquina de estados
    
    ; Futuramente outras subrotinas podem ser chamadas aqui
    ; rcall outra_tarefa
    
    rjmp loop
    
; ############################ Sub Rotinas #####################################
; ------------------- Comeco Maquina de Estados --------------------------------
    
state_machine:
    lds r16, current_mode       ; Carrega o modo atual da RAM em r16

    cpi r16, 1                  ; Compara r16 com 1 (MODO 1: relógio)
    brne _sm_check2             ; Se não é 1, pula para verificar o próximo modo
    rjmp _handle_mode1          ; Se é 1, salta para o handler do modo 1

_sm_check2:
    cpi r16, 2                  ; Compara r16 com 2 (MODO 2: cronômetro parado)
    brne _sm_check3             ; Se não é 2, pula para verificar o próximo modo
    rjmp _handle_mode2_parado   ; Se é 2, salta para o handler do cronômetro parado

_sm_check3:
    cpi r16, 3                  ; Compara r16 com 3 (MODO 2: cronômetro contando)
    brne _sm_check4             ; Se não é 3, pula para verificar o próximo modo
    rjmp _handle_mode2_contando ; Se é 3, salta para o handler do cronômetro contando

_sm_check4:
    cpi r16, 4                  ; Compara r16 com 4 (MODO 3: configuração)
    brne _sm_end                ; Se não é 4, nenhum modo bateu: encerra
    rjmp _handle_mode3          ; Se é 4, salta para o handler de configuração

_sm_end:
    ret                         ; Retorna ao loop principal

; ------------------- FIM Maquina de Estados --------------------------------
; ------------------- Comeco Estado 1 --------------------------------
    
_handle_mode1:
    ; Atualiza o valor no buffer do display
    lds r16, minutes_tens
    lds r17, minutes_units
    lds r18, seconds_tens
    lds r19, seconds_units
    rcall update_display_digits
    
_default:
    ; Checa se o botao MODE foi pressionado
    lds r16, btn_mode_flag
    tst r16
    breq _check_uart_debug        ; flag nao levantada: nada a fazer

    ; Consome a flag
    ldi r16, 0
    sts btn_mode_flag, r16

    ; Transita para o MODO 2
    ldi r16, 2
    sts current_mode, r16

_check_uart_debug:
    ; Verifica se deve imprimir
    lds r16, uart_print_flag
    tst r16
    breq _end_handle_mode1

    ldi r16, 0
    sts uart_print_flag, r16

    ldi r30, lo8(str_modo1)
    ldi r31, hi8(str_modo1)
    rcall uart_send_string
    rcall uart_send_time
    
    
_end_handle_mode1:
    ret
    
; ------------------- FIM Estado 1 --------------------------------
; ------------------- Comeco Estado 2 (Parado) --------------------------------

_handle_mode2_parado:
    ; Atualiza display com cronômetro atual
    lds r16, chrono_minutes_tens
    lds r17, chrono_minutes_units
    lds r18, chrono_seconds_tens
    lds r19, chrono_seconds_units
    rcall update_display_digits
        
    ; MODE -> vai para MODO 3 (configuração)
    lds r16, btn_mode_flag
    tst r16
    breq _check_start_parado
    
    ldi r16, 0
    sts btn_mode_flag, r16
    ldi r16, 4                       ; MODO 3 = estado 4
    sts current_mode, r16
    
    ; Copia valores atuais do relógio para o buffer de ajuste
    lds r16, seconds_units
    sts adjust_seconds_units, r16
    lds r16, seconds_tens
    sts adjust_seconds_tens, r16
    lds r16, minutes_units
    sts adjust_minutes_units, r16
    lds r16, minutes_tens
    sts adjust_minutes_tens, r16
    
    rjmp _end_handle_mode2_parado

_check_start_parado:
    ; START -> inicia cronômetro (vai para estado contando = 3)
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_parado
    
    sbi _SFR_IO_ADDR(PORTB), DEBUG_LED_PIN

    ; Consome a flag
    ldi r16, 0
    sts btn_start_flag, r16
       
    ; Muda para o estado contando
    ldi r16, 3                       ; estado contando
    sts current_mode, r16
    
    ldi r30, lo8(str_modo2_start)
    ldi r31, hi8(str_modo2_start)
    rcall uart_send_string
    
    rjmp _end_handle_mode2_parado
    

_check_reset_parado:
    ; RESET -> zera cronômetro (só se parado)
    lds r16, btn_reset_flag
    tst r16
    breq _end_handle_mode2_parado
    
    ; Consome a flag
    ldi r16, 0
    sts btn_reset_flag, r16
    
    sts chrono_seconds_units, r16
    sts chrono_seconds_tens,  r16
    sts chrono_minutes_units, r16
    sts chrono_minutes_tens,  r16
    
    ; Imprime o debug na serial:
    ldi r30, lo8(str_modo2_zero)
    ldi r31, hi8(str_modo2_zero)
    rcall uart_send_string

_end_handle_mode2_parado:
    ret

; ------------------- FIM Estado 2 (Parado) --------------------------------
; ------------------- Comeco Estado 2 (Contando) --------------------------------

_handle_mode2_contando:
    ; Incrementa o cronômetro a cada segundo
    rcall chrono_clock

    ; Atualiza display com cronômetro atual
    lds r16, chrono_minutes_tens
    lds r17, chrono_minutes_units
    lds r18, chrono_seconds_tens
    lds r19, chrono_seconds_units
    rcall update_display_digits

    ; Apenas START responde ? para o cronômetro (volta para parado = 2)
    ; MODE e RESET são ignorados mas as flags precisam ser consumidas
    lds r16, btn_mode_flag
    tst r16
    breq _check_start_contando
    ldi r16, 0
    sts btn_mode_flag, r16           ; ignora MODE

_check_start_contando:
    ; Verifica a flag
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_contando
    
    ; Consome a flag
    ldi r16, 0
    sts btn_start_flag, r16
    
    ldi r16, 2                       ; volta para estado parado
    sts current_mode, r16
    
    ldi r30, lo8(str_modo2_start)
    ldi r31, hi8(str_modo2_start)
    rcall uart_send_string

_check_reset_contando:
    lds r16, btn_reset_flag
    tst r16
    breq _end_handle_mode2_contando
    ldi r16, 0
    sts btn_reset_flag, r16          ; ignora RESET

_end_handle_mode2_contando:
    ret

; ------------------- FIM Estado 2 (Contando) --------------------------------
; ------------------- Comeco Estado 3 --------------------------------    

_handle_mode3:
    ; Carrega os valores reais do relogio
    lds r16, adjust_minutes_tens
    lds r17, adjust_minutes_units
    lds r18, adjust_seconds_tens
    lds r19, adjust_seconds_units
    
    ; Verifica se o soft-timer do blink disparou
    lds r20, blink_event_flag
    tst r20
    breq _blink_apply            ; flag não levantada: mantem estado atual

    ; Consome a flag e alterna o estado de piscar
    ldi r20, 0
    sts blink_event_flag, r20
    lds r20, blink_state
    ldi r21, 1
    eor r20, r21                 ; toggle: 0 -> 1 ou 1 -> 0
    sts blink_state, r20

_blink_apply:
    ; Se blink_state == 0: mostra normal
    ; Se blink_state == 1: apaga o dígito selecionado
    lds r20, blink_state
    tst r20
    breq _blink_done             ; estado 0: exibe normal, nao apaga nada

    ; Apaga o digito selecionado
    lds r20, selected_digit
    tst r20
    brne _blink_d1
    ldi r16, 0x0F                ; apaga posicao 0
    rjmp _blink_done
_blink_d1:
    cpi r20, 1
    brne _blink_d2
    ldi r17, 0x0F                ; apaga posicao 1
    rjmp _blink_done
_blink_d2:
    cpi r20, 2
    brne _blink_d3
    ldi r18, 0x0F                ; apaga posicao 2
    rjmp _blink_done
_blink_d3:
    ldi r19, 0x0F                ; apaga posicao 3

_blink_done:
    rcall update_display_digits

    ; MODE -> volta para MODO 1
    lds r16, btn_mode_flag
    tst r16
    breq _check_start_mode3
    
    ; Consome a flag
    ldi r16, 0
    sts btn_mode_flag, r16
   
    ; Copia buffer de ajuste de volta para o relógio real
    lds r16, adjust_seconds_units
    sts seconds_units, r16
    lds r16, adjust_seconds_tens
    sts seconds_tens, r16
    lds r16, adjust_minutes_units
    sts minutes_units, r16
    lds r16, adjust_minutes_tens
    sts minutes_tens, r16
    
    ; Volta para o modo 1
    ldi r16, 1
    sts current_mode, r16
    rjmp _end_handle_mode3

_check_start_mode3:
    ; START -> avança o dígito selecionado (0 -> 1 -> 2 -> 3 -> 0)
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_mode3
    
    ; Consome a flag
    ldi r16, 0
    sts btn_start_flag, r16
    
    ; Navegar entre os displays
    lds r16, selected_digit
    inc r16
    cpi r16, 4			; Verifica se o valor e igual a 4
    brlo _save_selected_digit	; Se for menor que 4, pula para _save_selected_digit
    ldi r16, 0			; Se nao zera o indiceã
_save_selected_digit:
    ; Salva o digito que ta selecionado
    sts selected_digit, r16
    
    ; Imprime qual dígito está sendo ajustado
    tst r16
    brne _print_digit1
    ldi r30, lo8(str_modo3_dmin)   ; digito 0 = dezena dos minutos
    ldi r31, hi8(str_modo3_dmin)
    rjmp _do_print_mode3
_print_digit1:
    cpi r16, 1
    brne _print_digit2
    ldi r30, lo8(str_modo3_umin)   ; digito 1 = unidade dos minutos
    ldi r31, hi8(str_modo3_umin)
    rjmp _do_print_mode3
_print_digit2:
    cpi r16, 2
    brne _print_digit3
    ldi r30, lo8(str_modo3_dseg)   ; digito 2 = dezena dos segundos
    ldi r31, hi8(str_modo3_dseg)
    rjmp _do_print_mode3
_print_digit3:
    ldi r30, lo8(str_modo3_useg)   ; digito 3 = unidade dos segundos
    ldi r31, hi8(str_modo3_useg)
_do_print_mode3:
    rcall uart_send_string
    rjmp _end_handle_mode3

_check_reset_mode3:
    ; RESET ? incrementa o valor do digito selecionado
    lds r16, btn_reset_flag
    tst r16
    breq _end_handle_mode3
    ldi r16, 0
    sts btn_reset_flag, r16
    rcall increment_selected_digit

_end_handle_mode3:
    ret

; ------------------- FIM ESTADO 3    
; ------------------- Comeco Display Pool --------------------------------------
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
    
    ; Incrementa o indice PRIMEIRO
    lds r16, display_index
    inc r16
    cpi r16, 4
    brne _save_index
    ldi r16, 0

_save_index:
    sts display_index, r16          ; Salva o novo indice (0-3) na RAM

    ldi r30, lo8(display_digits + 3)  ; comeca apontando para o ultimo elemento
    ldi r31, hi8(display_digits + 3)
    sub r30, r16                       ; recua o ponteiro: display_digits[3 - index]
    ld  r17, Z

    in  r16, _SFR_IO_ADDR(BCD_PORT) ; Le o estado atual do PORT C
    andi r16, ~BCD_MASK             ; Limpa apenas os bits BCD, preserva os outros pinos do PORT C
    andi r17, 0x0F                  ; Garante que so os 4 bits baixos do digito serao usados
    or  r16, r17                    ; Combina os bits BCD do digito com o restante do PORT C
    out _SFR_IO_ADDR(BCD_PORT), r16 ; Envia o valor BCD para os pinos

    lds r16, display_index          ; Recarrega o indice atual (0-3)
    ldi r17, (1 << DISPLAY_PIN_0)   ; R17 = mascara inicial apontando para o display 0 (bit 1 de PORTB)
    tst r16                         ; Testa se indice == 0
    breq _apply_display             ; Se sim, ja esta no display certo, nao precisa deslocar

_shift_loop:
    lsl r17
    dec r16
    brne _shift_loop

_apply_display:
    ; Liga apenas o display ativo
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)
    andi r16, ~DISPLAY_MASK          ; Desliga todos os displays
    or r16, r17                      ; Liga apenas o display do indice atual
    out _SFR_IO_ADDR(DISPLAY_PORT), r16

_end_display_pool:
    ret
; ------------------- Fim Display Pool --------------------------------------
; ------------------- Comeco Main Clock --------------------------------------
main_clock:
    ; Verifica se a ISR sinalizou o evento de 1 segundo
    lds r16, main_clock_event_flag
    tst r16
    breq _end_main_clock             ; Nenhum evento pendente: sai da sub-rotina

    ; Consome a flag para evitar incrementos multiplos no mesmo segundo
    ldi r16, 0
    sts main_clock_event_flag, r16
    
    ; Levanta flag de impressão UART
    ldi r16, 1
    sts uart_print_flag, r16
    
    ; --- Incrementa unidade dos segundos (0-9) ---
    lds r16, seconds_units
    inc r16
    cpi r16, 10                      ; Chegou em 10? (estouro de dï¿½gito)
    brlo _save_sec_units             ; Nao: salva e encerra
    ldi r16, 0                       ; Sim: zera e propaga para dezena
    sts seconds_units, r16
    rjmp _inc_sec_tens

_save_sec_units:
    sts seconds_units, r16           ; Salva unidade dos segundos sem estouro
    rjmp _end_main_clock

    ; --- Incrementa dezena dos segundos (0-5) ---
_inc_sec_tens:
    lds r16, seconds_tens
    inc r16
    cpi r16, 6                       ; Chegou em 6? (60 segundos completos)
    brlo _save_sec_tens              ; Nao: salva e encerra
    ldi r16, 0                       ; Sim: zera e propaga para unidade dos minutos
    sts seconds_tens, r16
    rjmp _inc_min_units

_save_sec_tens:
    sts seconds_tens, r16            ; Salva dezena dos segundos sem estouro
    rjmp _end_main_clock

    ; --- Incrementa unidade dos minutos (0-9) ---
_inc_min_units:
    lds r16, minutes_units
    inc r16
    cpi r16, 10                      ; Chegou em 10? (estouro de digito)
    brlo _save_min_units             ; Nï¿½o: salva e encerra
    ldi r16, 0                       ; Sim: zera e propaga para dezena dos minutos
    sts minutes_units, r16
    rjmp _inc_min_tens

_save_min_units:
    sts minutes_units, r16           ; Salva unidade dos minutos sem estouro
    rjmp _end_main_clock

    ; --- Incrementa dezena dos minutos (0-5) ---
_inc_min_tens:
    lds r16, minutes_tens
    inc r16
    cpi r16, 6                       ; Chegou em 6? (60 minutos completos: volta a 00:00)
    brlo _save_min_tens              ; Nao: salva e encerra
    ldi r16, 0                       ; Sim: zera ? ciclo completo de 59:59 ? 00:00

_save_min_tens:
    sts minutes_tens, r16            ; Salva dezena dos minutos (com ou sem estouro)

_end_main_clock:
    ret
; ----------------------- Fim main clock --------------------------------------

; ------------------- Comeco Chrono Clock ------------------------------------
chrono_clock:
    ; Verifica se a ISR sinalizou o evento de 1 segundo
    lds r16, chrono_clock_event_flag
    tst r16
    breq _end_chrono_clock

    ; Consome a flag
    ldi r16, 0
    sts chrono_clock_event_flag, r16

    ; --- Incrementa unidade dos segundos (0-9) ---
    lds r16, chrono_seconds_units
    inc r16
    cpi r16, 10
    brlo _save_chrono_sec_units
    ldi r16, 0
    sts chrono_seconds_units, r16
    rjmp _inc_chrono_sec_tens

_save_chrono_sec_units:
    sts chrono_seconds_units, r16
    rjmp _end_chrono_clock

_inc_chrono_sec_tens:
    lds r16, chrono_seconds_tens
    inc r16
    cpi r16, 6
    brlo _save_chrono_sec_tens
    ldi r16, 0
    sts chrono_seconds_tens, r16
    rjmp _inc_chrono_min_units

_save_chrono_sec_tens:
    sts chrono_seconds_tens, r16
    rjmp _end_chrono_clock

_inc_chrono_min_units:
    lds r16, chrono_minutes_units
    inc r16
    cpi r16, 10
    brlo _save_chrono_min_units
    ldi r16, 0
    sts chrono_minutes_units, r16
    rjmp _inc_chrono_min_tens

_save_chrono_min_units:
    sts chrono_minutes_units, r16
    rjmp _end_chrono_clock

_inc_chrono_min_tens:
    lds r16, chrono_minutes_tens
    inc r16
    cpi r16, 6
    brlo _save_chrono_min_tens
    ldi r16, 0

_save_chrono_min_tens:
    sts chrono_minutes_tens, r16

_end_chrono_clock:
    ret
; ------------------- Fim Chrono Clock ---------------------------------------   
    
increment_selected_digit:
    lds r16, selected_digit      ; Carrega o índice do dígito selecionado (0-3)

    cpi r16, 0                   ; É o dígito 0?
    brne _check_digit1           ; Não: verifica o próximo
    lds r17, adjust_minutes_tens        ; Sim: carrega a dezena dos minutos
    inc r17                      ; Incrementa
    cpi r17, 6                   ; Passou de 5? (dezena dos minutos vai de 0 a 5)
    brlo _save_min_tens_adj      ; Não: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap ? volta para 0
_save_min_tens_adj:
    sts adjust_minutes_tens, r17        ; Salva o novo valor da dezena dos minutos
    rjmp _end_increment          ; Encerra ? só um dígito por pressão de RESET

_check_digit1:
    cpi r16, 1                   ; É o dígito 1?
    brne _check_digit2           ; Não: verifica o próximo
    lds r17, adjust_minutes_units       ; Sim: carrega a unidade dos minutos
    inc r17                      ; Incrementa
    cpi r17, 10                  ; Passou de 9? (unidade vai de 0 a 9)
    brlo _save_min_units_adj     ; Não: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap ? volta para 0
_save_min_units_adj:
    sts adjust_minutes_units, r17       ; Salva o novo valor da unidade dos minutos
    rjmp _end_increment

_check_digit2:
    ; --- Dígito 2: dezena dos segundos (range 0-5) ---
    cpi r16, 2                   ; É o dígito 2?
    brne _check_digit3           ; Não: só resta o dígito 3, cai no próximo bloco
    lds r17, adjust_seconds_tens        ; Sim: carrega a dezena dos segundos
    inc r17                      ; Incrementa
    cpi r17, 6                   ; Passou de 5? (dezena dos segundos vai de 0 a 5)
    brlo _save_sec_tens_adj      ; Não: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap ? volta para 0
_save_sec_tens_adj:
    sts adjust_seconds_tens, r17        ; Salva o novo valor da dezena dos segundos
    rjmp _end_increment

_check_digit3:
    ; --- Dígito 3: unidade dos segundos (posição mais à direita, range 0-9) ---
    ; Não precisa de cpi ? se chegou aqui, só pode ser o dígito 3
    lds r17, adjust_seconds_units       ; Carrega a unidade dos segundos
    inc r17                      ; Incrementa
    cpi r17, 10                  ; Passou de 9? (unidade vai de 0 a 9)
    brlo _save_sec_units_adj     ; Não: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap ? volta para 0
_save_sec_units_adj:
    sts adjust_seconds_units, r17       ; Salva o novo valor da unidade dos segundos

_end_increment:
    ret                          ; Retorna ao handler do modo 3
    
; Recebe os 4 digitos prontos nos registradores e grava no buffer
; r16 = display_digits[0] (dezena dos minutos)
; r17 = display_digits[1] (unidade dos minutos)
; r18 = display_digits[2] (dezena dos segundos)
; r19 = display_digits[3] (unidade dos segundos)
update_display_digits:
    sts display_digits,     r16
    sts display_digits + 1, r17
    sts display_digits + 2, r18
    sts display_digits + 3, r19
    ret

uart_send_char:
    push r17                 
_uart_wait:
    lds r17, UCSR0A
    sbrs r17, UDRE0
    rjmp _uart_wait
    sts UDR0, r16
    pop r17                  
    ret
    
uart_send_string:
    lpm r16, Z+              ; carrega byte da flash e avança ponteiro
    tst r16                  ; é o terminador nulo?
    breq _end_uart_string    ; sim: encerra
    rcall uart_send_char     ; não: envia o caractere
    rjmp uart_send_string
_end_uart_string:
    ret
    
uart_send_time:
    ; Envia dezena dos minutos
    lds r16, minutes_tens
    ori r16, '0'             ; converte dígito para ASCII
    rcall uart_send_char

    ; Envia unidade dos minutos
    lds r16, minutes_units
    ori r16, '0'
    rcall uart_send_char

    ; Envia ':'
    ldi r16, ':'
    rcall uart_send_char

    ; Envia dezena dos segundos
    lds r16, seconds_tens
    ori r16, '0'
    rcall uart_send_char

    ; Envia unidade dos segundos
    lds r16, seconds_units
    ori r16, '0'
    rcall uart_send_char

    ; Envia newline
    ldi r16, 10
    rcall uart_send_char
    ldi r16, 13
    rcall uart_send_char
    ret