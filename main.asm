#include <avr/io.h>

; --- Mapeamento de Hardware ---
; Pinos de chaveamento dos displays
.equiv DISPLAY_PORT,    PORTB
.equiv DISPLAY_DDR,     DDRB
.equiv DISPLAY_PIN_0,   1        
.equiv DISPLAY_PIN_1,   2        
.equiv DISPLAY_PIN_2,   3        
.equiv DISPLAY_PIN_3,   4        

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
.equiv BTN_START_PIN,   1        ; PD1 = botao START (PCINT17)
.equiv BTN_RESET_PIN,   2        ; PD2 = botao RESET (PCINT18)

; Mascara com os tres botoes
.equiv BTN_MASK,        (1 << BTN_MODE_PIN) | (1 << BTN_START_PIN) | (1 << BTN_RESET_PIN)

; A ideia e simular o que o "tick" de um OS represente
; ou seja, o menor tempo possivel para execucao de uma tarefa
; Para isso o Timer1 vai estourar a cada 1 segundo
; E cada tarefa vai possui um contador que sera decrementado
.section .bss
display_pool_tick_counter: .byte 1	; Reserva 1 byte para armazenar o contador de tick que chaveia os displays
main_clock_tick_counter_low: .byte 1    ; Reserva 2 bytes para o contador natural do relï¿½gio 
main_clock_tick_counter_high: .byte 1   ; Reserva 2 bytes para o contador natural do relï¿½gio

;  Flags
display_pool_event_flag: .byte 1
main_clock_event_flag: .byte 1
    
btn_mode_flag:      .byte 1
btn_start_flag:   .byte 1
btn_reset_flag:   .byte 1

; Estado atual
current_mode: .byte 1    
    
; Botoes
last_portd_state:   .byte 1
    
; Variaveis
display_index:      .byte 1
    
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
    
display_digits:     .byte 4
    
; --- Definicoes de Configuracao ---
; Calculo para 1ms @ 16MHz:
; F_CPU / (Prescaler * Desired_Freq) - 1
; 16.000.000 / (64 * 1000) - 1 = 249
.equiv TIMER_TOP, 249        ; Valor de comparacao para 1ms

.equiv DISPLAY_POOL_PERIOD_TICK, 8  ; Chaveamento a 30hz, periodo = (1/30)/4, 4 = numero de displays
.equiv MAIN_CLOCK_PERIOD_TICK, 1000 ; Periodo de atualizacao do valor a cada 1 segundo
; --- Registradores para armazenar as contagens regressivas das tarefas
.section .text

.global main
.global __vector_14          ; Vetor de interrupcao: TIMER0_COMPA
.global __vector_5           ; Vetor de interrupcao: PCINT2 (PORTD)

; Registradores especificos
.set seconds, r18
.set minutes, r19
.set hours, r20
 
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

    ; Configura os pinos de chaveamento dos displays como saï¿½da
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
    ldi r16, (1 << PCINT16) | (1 << PCINT17) | (1 << PCINT18)
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
    
    ; Checa se o botao MODE foi pressionado
    lds r16, btn_mode_flag
    tst r16
    breq _end_handle_mode1        ; flag nao levantada: nada a fazer

    ; Consome a flag
    ldi r16, 0
    sts btn_mode_flag, r16

    ; Transita para o MODO 2
    ldi r16, 2
    sts current_mode, r16

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
    ldi r16, 1                       ; MODO 3 = estado 4
    sts current_mode, r16
    rjmp _end_handle_mode2_parado

_check_start_parado:
    ; START -> inicia cronômetro (vai para estado contando = 3)
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_parado
    ldi r16, 0
    sts btn_start_flag, r16
    ldi r16, 3                       ; estado contando
    sts current_mode, r16
    rjmp _end_handle_mode2_parado

_check_reset_parado:
    ; RESET -> zera cronômetro (só se parado)
    lds r16, btn_reset_flag
    tst r16
    breq _end_handle_mode2_parado
    ldi r16, 0
    sts btn_reset_flag, r16
    sts chrono_seconds_units, r16
    sts chrono_seconds_tens,  r16
    sts chrono_minutes_units, r16
    sts chrono_minutes_tens,  r16

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
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_contando
    ldi r16, 0
    sts btn_start_flag, r16
    ldi r16, 2                       ; volta para estado parado
    sts current_mode, r16

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
    ; MODE  ? vai para MODO 1, bip
    ; START ? avanï¿½a selected_digit (0?1?2?3?0)
    ; RESET ? incrementa o dï¿½gito selecionado
    ret
    
;-------------------- Fim Maquina de Estados -----------------------------------
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
    lds r16, main_clock_event_flag
    tst r16
    breq _end_chrono_clock

    ; Consome a flag
    ldi r16, 0
    sts main_clock_event_flag, r16

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
