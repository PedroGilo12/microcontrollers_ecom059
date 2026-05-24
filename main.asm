#include <avr/io.h>

; --- Mapeamento de Hardware ---
; Pinos do buzzer
.equiv BUZZER_PORT, PORTD    
.equiv BUZZER_DDR, DDRD
.equiv BUZZER_PIN, 7
    
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

; --- Definicoes de Configuracao ---
; Calculo para 1ms @ 16MHz:
; F_CPU / (Prescaler * Desired_Freq) - 1
; 16.000.000 / (64 * 1000) - 1 = 249
.equiv TIMER_TOP, 249		    ; Valor de comparacao para 1ms

.equiv DISPLAY_POOL_PERIOD_TICK, 3  ; Chaveamento a 30hz, periodo (8) = (1/30)/4, 4 = numero de displays
.equiv MAIN_CLOCK_PERIOD_TICK, 1000 ; Periodo de atualizacao do valor a cada 1 segundo
.equiv BLINK_PERIOD, 250	    ; pisca a cada 250ms   
.equiv BUZZER_DURATION, 100	    ; duracao do bip em ms   
    
; --- Estados da maquina de estados ---    
.equiv FSM_MODE1, 1 
.equiv FSM_MODE2_STOPPED, 2
.equiv FSM_MODE2_RUNNING, 3
.equiv FSM_MODE3, 4    
    
; A ideia e simular o que o "tick" de um OS represente
; ou seja, o menor tempo possivel para execucao de uma tarefa
; Para isso o Timer1 vai estourar a cada 1 segundo
; E cada tarefa vai possui um contador que sera decrementado
.section .bss
    
display_pool_tick_counter: .byte 1	; Reserva 1 byte para armazenar o contador de tick que chaveia os displays
main_clock_tick_counter_low: .byte 1    ; Reserva 2 bytes para o contador do relogio 
main_clock_tick_counter_high: .byte 1   ; Reserva 2 bytes para o contador do relogio
blink_counter: .byte 1			; contador para piscar o digito selecionado    

;  Flags
display_pool_event_flag: .byte 1
main_clock_event_flag: .byte 1
chrono_clock_event_flag: .byte 1 
blink_event_flag:   .byte 1     
    
btn_start_flag:   .byte 1
btn_mode_flag:    .byte 1
btn_reset_flag:   .byte 1
    
uart_print_flag: .byte 1   ; levantada quando deve imprimir na serial no modo 1   

buzzer_flag:        .byte 1    ; 1 = bip solicitado
buzzer_active:      .byte 1    ; 1 = Timer2 est� gerando tom
buzzer_counter:     .byte 1    ; contador de dura��o em ms    
    
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
.global __vector_7           ; Vetor de interrupcao: TIMER2_COMPA
 
; --- Rotina de Interrupcao ---
__vector_14:
    ; Salva o contexto
    push r16                            ; empilha r16 para preservar seu valor durante a ISR
    in r16, _SFR_IO_ADDR(SREG)          ; le o registrador de status (SREG): contem as flags C,Z,N,V,S,H,T,I
    push r16                            ; empilha SREG para restaurar as flags ao sair da ISR

    ; Decrementa e verifica o contador do chaveamento de display
    lds r16, display_pool_tick_counter  ; carrega o contador de tick do display da RAM em r16
    tst r16                             ; testa r16: seta flag Z se r16 == 0, seta flag N se r16 < 0
    breq _display_tick                  ; se Z=1 (contador zerado), salta para recarregar e levantar flag
    dec r16                             ; decrementa r16 (nao altera carry)
    sts display_pool_tick_counter, r16  ; salva o novo valor decrementado de volta na RAM

_check_blink_counter:    
    lds r16, blink_counter              ; carrega o contador de blink da RAM em r16
    tst r16                             ; testa r16: seta flag Z se r16 == 0
    breq _blink_tick                    ; se Z=1 (contador zerado), salta para recarregar e levantar flag
    dec r16                             ; decrementa r16
    sts blink_counter, r16              ; salva o novo valor decrementado de volta na RAM
    rjmp _check_buzzer                  ; continua para o clock principal

_check_main_clock:
    ; Decrementa e verifica o contador do relogio principal
    push r17                            ; empilha r17 para uso como byte alto do contador de 16 bits

    lds r16, main_clock_tick_counter_low  ; carrega o byte baixo do contador de 16 bits (bits 7:0)
    lds r17, main_clock_tick_counter_high ; carrega o byte alto do contador de 16 bits (bits 15:8)

    subi r16, 1                         ; subtrai 1 do byte baixo; seta C=1 se houve borrow (underflow)
    sbci r17, 0                         ; subtrai 0 + carry do byte alto; propaga o borrow do subi anterior

    ; O comando sbci preserva a flag Z (Zero) acionada pelo subi anterior.
    ; O breq so vai saltar se a flag Z continuar ativa apos as duas operacoes, 
    ; o que significa que o valor total de 16 bits (r17:r16) chegou a 0.
    breq _main_clock_tick               ; se Z=1 (par r17:r16 == 0), dispara o evento de 1 segundo

    sts main_clock_tick_counter_low, r16  ; salva byte baixo atualizado na RAM
    sts main_clock_tick_counter_high, r17 ; salva byte alto atualizado na RAM
    
    pop r17                             ; restaura r17 do stack

    ; Restaura o contexto
_end_isr:
    pop r16                             ; desempilha o valor salvo de SREG
    out _SFR_IO_ADDR(SREG), r16         ; restaura SREG: todas as flags (C,Z,N,V,S,H,T,I) voltam ao estado anterior
    pop r16                             ; restaura r16 original
    reti                                ; retorna da interrupcao e reabilita interrupcoes globais (seta I em SREG)

_display_tick:
    ; Recarrega o periodo
    ldi r16, DISPLAY_POOL_PERIOD_TICK   ; carrega a constante de periodo (3 ticks = 3ms)
    sts display_pool_tick_counter, r16  ; salva na RAM para proxima contagem
    
    ; Apenas levanta a flag
    ldi r16, 1                          ; valor 1 = flag levantada
    sts display_pool_event_flag, r16    ; sinaliza ao loop principal que e hora de chavear o display
    
    ; Continua para decrementa o relogio principal
    rjmp _check_blink_counter
    
 _blink_tick:
    ; Recarrega o per�odo
    ldi r16, BLINK_PERIOD               ; carrega a constante de periodo de blink (250 ticks = 250ms)
    sts blink_counter, r16              ; salva na RAM para proxima contagem
    ; Levanta a flag
    ldi r16, 1                          ; valor 1 = flag levantada
    sts blink_event_flag, r16           ; sinaliza ao loop principal que e hora de alternar o estado de blink
    rjmp _check_buzzer
    
_check_buzzer:
    lds r16, buzzer_active              ; carrega o flag de buzzer ativo da RAM (0=inativo, 1=ativo)
    tst r16                             ; testa r16: seta Z=1 se r16 == 0
    breq _check_main_clock              ; se Z=1, buzzer nao estiver ativo: pula direto para o clock

    lds r16, buzzer_counter             ; carrega o contador de duracao do buzzer em ms
    tst r16                             ; testa r16: seta Z=1 se r16 == 0
    breq _buzzer_off                    ; se Z=1, contador chegou a 0: desliga o buzzer
    
    dec r16                             ; decrementa o contador de duracao (1 tick = 1ms)
    sts buzzer_counter, r16             ; salva o novo valor decrementado na RAM
    rjmp _check_main_clock

_buzzer_off:
    ; Desliga Timer2 (para o tom)
    ldi r16, 0
    sts TCCR2B, r16                     ; TCCR2B=0: zera CS22:CS20 (bits 2:0), desliga o clock do Timer2 (sem prescaler = parado)
    sts buzzer_active, r16              ; marca buzzer como inativo (0)
    ; Garante PD7 em LOW
    cbi _SFR_IO_ADDR(BUZZER_PORT), BUZZER_PIN  ; forca PD7 (pino do buzzer) para nivel baixo (0V), evitando ruido residual
    rjmp _check_main_clock    
    
_main_clock_tick:
    ; Recarrega o periodo
    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)  ; byte baixo de 1000 (0xE8): parte menos significativa do periodo de 1 segundo
    sts main_clock_tick_counter_low, r16  ; salva byte baixo na RAM
    ldi r16, hi8(MAIN_CLOCK_PERIOD_TICK)  ; byte alto de 1000 (0x03): parte mais significativa do periodo de 1 segundo
    sts main_clock_tick_counter_high, r16 ; salva byte alto na RAM

    ; Apenas levanta a flag
    ldi r16, 1                            ; valor 1 = flag levantada
    sts main_clock_event_flag, r16        ; sinaliza ao loop que o relogio principal deve incrementar
    sts chrono_clock_event_flag, r16      ; sinaliza ao loop que o cronometro deve incrementar (se rodando)
    
    pop r17                               ; restaura r17 empilhado em _check_main_clock
    rjmp _end_isr

; --- ISR PCINT2: deteccao de borda de descida dos botoes em PORTD ---
__vector_5:
    ; Salva contexto
    push r16                            ; empilha r16
    in r16, _SFR_IO_ADDR(SREG)          ; le SREG (flags do processador)
    push r16                            ; empilha SREG
    push r17                            ; empilha r17
    push r18                            ; empilha r18

    ; Le o estado atual do PIND e o estado anterior
    in   r16, _SFR_IO_ADDR(BTN_PIN)    ; r16 = estado atual de PIND: cada bit reflete o nivel logico do pino (1=alto, 0=baixo)
    lds  r17, last_portd_state         ; r17 = estado anterior (salvo na ultima interrupcao)

    ; Borda de descida: pino era 1 e agora e 0
    ;   pressionado = (~atual) & anterior
    mov  r18, r16                       ; copia estado atual para r18
    com  r18                            ; complemento de r18: inverte todos os bits (pinos agora em nivel baixo viram 1)
    and  r18, r17                       ; r18 = (~atual) & anterior: bit=1 apenas onde pino era alto e agora e baixo (borda de descida)

    ; Atualiza o estado anterior com o estado atual
    sts  last_portd_state, r16          ; salva o estado atual como "ultimo estado" para a proxima interrupcao

    ; r17 sera reutilizado como constante 1 para escrever nas flags
    ldi  r17, 1                         ; valor constante 1 para levantar flags

    ; Borda de descida no MODE (PD0)?
    sbrc r18, BTN_MODE_PIN              ; pula proxima instrucao se o bit BTN_MODE_PIN (PD0) em r18 for 0 (nao houve borda)
    sts  btn_mode_flag, r17             ; bit estava 1: houve borda de descida no MODE, levanta a flag

    ; Borda de descida no START (PD1)?
    sbrc r18, BTN_START_PIN             ; pula proxima instrucao se o bit BTN_START_PIN (PD3) em r18 for 0
    sts  btn_start_flag, r17            ; bit estava 1: houve borda de descida no START, levanta a flag

    ; Borda de descida no RESET (PD2)?
    sbrc r18, BTN_RESET_PIN             ; pula proxima instrucao se o bit BTN_RESET_PIN (PD2) em r18 for 0
    sts  btn_reset_flag, r17            ; bit estava 1: houve borda de descida no RESET, levanta a flag

_end_pcint2:
    pop r18                             ; restaura r18
    pop r17                             ; restaura r17
    pop r16                             ; desempilha valor de SREG salvo
    out _SFR_IO_ADDR(SREG), r16         ; restaura SREG: todas as flags voltam ao estado anterior a interrupcao
    pop r16                             ; restaura r16 original
    reti                                ; retorna da interrupcao e reabilita interrupcoes globais
    
__vector_7:
    push r16                            ; empilha r16
    in r16, _SFR_IO_ADDR(SREG)          ; le SREG para preservar as flags durante a ISR do Timer2
    push r16                            ; empilha SREG
    push r17                            ; empilha r17

    ; Toggle PD7
    in r16, _SFR_IO_ADDR(BUZZER_PORT)   ; le o estado atual de PORTD em r16 (todos os 8 pinos do porto)
    ldi r17, (1 << BUZZER_PIN)          ; r17 = 0b10000000: mascara com apenas o bit 7 (PD7, pino do buzzer) em 1
    eor r16, r17                        ; XOR: inverte apenas o bit 7 de r16 (toggle do pino do buzzer para gerar onda quadrada)
    out _SFR_IO_ADDR(BUZZER_PORT), r16  ; escreve o novo valor em PORTD, alternando o nivel de PD7

    pop r17                             ; restaura r17
    pop r16                             ; desempilha valor de SREG
    out _SFR_IO_ADDR(SREG), r16         ; restaura SREG
    pop r16                             ; restaura r16 original
    reti                                ; retorna da interrupcao e reabilita interrupcoes globais

; --- Setup e Loop ---
main:    
    ; Inicializa os contadores na RAM com os per�odos iniciais
    ldi r16, DISPLAY_POOL_PERIOD_TICK   ; carrega o periodo de chaveamento do display (3 ticks)
    sts display_pool_tick_counter, r16  ; inicializa o contador na RAM

    ldi r16, lo8(MAIN_CLOCK_PERIOD_TICK)  ; byte baixo de 1000 (0xE8)
    sts main_clock_tick_counter_low, r16  ; inicializa byte baixo do contador de 16 bits na RAM
    ldi r17, hi8(MAIN_CLOCK_PERIOD_TICK)  ; byte alto de 1000 (0x03)
    sts main_clock_tick_counter_high, r17 ; inicializa byte alto do contador de 16 bits na RAM
    
    ldi r16, BLINK_PERIOD               ; carrega o periodo de blink (250 ticks = 250ms)
    sts blink_counter, r16              ; inicializa o contador de blink na RAM

    ; Configura os pinos de chaveamento dos displays como sa�da
    in r16, _SFR_IO_ADDR(DISPLAY_DDR)   ; le o registrador de direcao de PORTB (DDR: 0=entrada, 1=saida)
    ori r16, DISPLAY_MASK               ; seta os bits dos pinos de display (PB1..PB4) como saida (1)
    out _SFR_IO_ADDR(DISPLAY_DDR), r16  ; escreve a nova configuracao de direcao em DDRB
    
    sbi _SFR_IO_ADDR(DDRB), DEBUG_LED_PIN  ; seta o bit 0 de DDRB: configura PB0 (LED de debug) como saida

    ; Garante que todos os displays comecem desligados
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)  ; le o estado atual de PORTB
    andi r16, ~DISPLAY_MASK             ; zera os bits dos pinos de display (PB1..PB4), desliga todos os displays
    out _SFR_IO_ADDR(DISPLAY_PORT), r16 ; escreve em PORTB: todos os transistores de chaveamento ficam OFF
    
    ; Configura Timer0: Modo CTC, Prescaler 64
    ldi r16, (1 << WGM01)               ; WGM01=1, WGM00=0: modo CTC (Clear Timer on Compare Match) - reseta ao atingir OCR0A
    out _SFR_IO_ADDR(TCCR0A), r16       ; TCCR0A: registrador de controle A do Timer0; WGM01 (bit1) define o modo de operacao
    ldi r16, TIMER_TOP                  ; carrega 249: valor de comparacao para gerar interrupcao a cada 1ms
    out _SFR_IO_ADDR(OCR0A), r16        ; OCR0A: registrador de comparacao A do Timer0; timer reseta quando TCNT0 == OCR0A
    ldi r16, (1 << OCIE0A)              ; OCIE0A=1: habilita a interrupcao de comparacao A do Timer0
    sts TIMSK0, r16                     ; TIMSK0: registrador de mascara de interrupcoes do Timer0; bit OCIE0A (bit1) habilita a ISR
    ldi r16, (1 << CS01) | (1 << CS00) ; CS01=1, CS00=1: seleciona prescaler de 64 para o clock do Timer0 (16MHz/64 = 250kHz)
    out _SFR_IO_ADDR(TCCR0B), r16       ; TCCR0B: registrador de controle B do Timer0; bits CS02:CS00 definem o prescaler

    ; Configura PD0 (MODE), PD1 (START) e PD2 (RESET) como entrada com pull-up
    in  r16, _SFR_IO_ADDR(BTN_DDR)      ; le DDRD: registrador de direcao de PORTD
    andi r16, ~BTN_MASK                 ; zera os bits de PD0, PD2, PD3 em DDRD: configura como entrada (0)
    out _SFR_IO_ADDR(BTN_DDR), r16      ; escreve em DDRD

    in  r16, _SFR_IO_ADDR(BTN_PORT)     ; le PORTD: quando pino e entrada, escrever 1 ativa o resistor de pull-up interno
    ori r16, BTN_MASK                   ; seta os bits de PD0, PD2, PD3 em PORTD: ativa pull-up (~50kohm) em cada botao
    out _SFR_IO_ADDR(BTN_PORT), r16     ; escreve em PORTD: pinos ficam em nivel alto quando botao solto

    ; Inicializa last_portd_state com o estado atual do PIND
    ; (evita falsa borda de descida no primeiro disparo)
    in  r16, _SFR_IO_ADDR(BTN_PIN)      ; le PIND: registrador de leitura dos pinos fisicos de PORTD (reflete nivel real do pino)
    sts last_portd_state, r16           ; salva estado inicial; sem isso, a 1a interrupcao detectaria borda falsa

    ; Habilita PCINT16 (PD0), PCINT17 (PD1) e PCINT18 (PD2) em PCMSK2
    ldi r16, (1 << PCINT16) | (1 << PCINT19) | (1 << PCINT18)
                                        ; PCINT16=PD0 (MODE), PCINT19=PD3 (START), PCINT18=PD2 (RESET)
    sts PCMSK2, r16                     ; PCMSK2: mascara de pinos para o grupo PCINT2; bit=1 habilita a interrupcao no pino

    ; Habilita o grupo PCINT2 em PCICR
    lds r16, PCICR                      ; le PCICR: registrador de controle das interrupcoes de mudanca de pino
    ori r16, (1 << PCIE2)               ; PCIE2=1 (bit2): habilita o grupo de interrupcao PCINT2 (pinos PD0..PD7)
    sts PCICR, r16                      ; escreve em PCICR
    
    ldi r16, 0                          ; r16=0: dezena dos minutos inicial
    ldi r17, 0                          ; r17=0: unidade dos minutos inicial
    ldi r18, 0                          ; r18=0: dezena dos segundos inicial
    ldi r19, 0                          ; r19=0: unidade dos segundos inicial
    rcall update_display_digits         ; inicializa o buffer de display com zeros
    
    ldi r16, 1
    sts current_mode, r16               ; inicia no MODO 1
    
    ; Configura UART: 9600 baud @ 16MHz
    ; UBRR = F_CPU / (16 * BAUD) - 1 = 16000000 / (16 * 9600) - 1 = 103
    ldi r16, 0
    sts UBRR0H, r16                     ; UBRR0H: byte alto do registrador de baud rate (bits 11:8); aqui vale 0
    ldi r16, 103
    sts UBRR0L, r16                     ; UBRR0L: byte baixo do registrador de baud rate (bits 7:0); 103 = 9600 baud @ 16MHz

    ; Habilita transmissor
    ldi r16, (1 << TXEN0)               ; TXEN0=1 (bit3 de UCSR0B): habilita o transmissor da UART0
    sts UCSR0B, r16                     ; UCSR0B: registrador de controle B da UART; TXEN0 ativa o pino TXD0

    ; Formato: 8 bits, 1 stop bit, sem paridade
    ldi r16, (1 << UCSZ01) | (1 << UCSZ00)
                                        ; UCSZ01=1 e UCSZ00=1 (bits 2:1 de UCSR0C): com UCSZ02=0 (em UCSR0B), define frame de 8 bits
    sts UCSR0C, r16                     ; UCSR0C: registrador de controle C da UART; define formato do frame (tamanho, paridade, stop bits)
    
    ; -- Configuracao do timer2 para o buzzer
    ; Timer2: modo CTC, sem prescaler
    ldi r16, (1 << WGM21)              ; WGM21=1, WGM20=0: modo CTC para o Timer2 (reseta ao atingir OCR2A)
    sts TCCR2A, r16                    ; TCCR2A: registrador de controle A do Timer2; WGM21 (bit1) define o modo CTC
    ldi r16, 124
    sts OCR2A, r16                     ; OCR2A: valor de comparacao do Timer2; 124 com prescaler 64 @ 16MHz gera ~1kHz (tom do buzzer)

    ldi r16, 0
    sts TCCR2B, r16                    ; TCCR2B=0: CS22:CS20=000, clock do Timer2 parado (buzzer inativo ate ser acionado)
    
    cbi _SFR_IO_ADDR(PORTB), DEBUG_LED_PIN  ; zera o bit 0 de PORTB: LED de debug comeca apagado (nivel baixo)
    
    sbi _SFR_IO_ADDR(BUZZER_DDR), BUZZER_PIN   ; seta o bit 7 de DDRD: configura PD7 (pino do buzzer) como saida
    cbi _SFR_IO_ADDR(BUZZER_PORT), BUZZER_PIN  ; zera o bit 7 de PORTD: garante que PD7 comece em nivel baixo (buzzer mudo)
    
    sei                                ; seta o bit I (bit7) de SREG: habilita interrupcoes globais

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

    cpi r16, FSM_MODE1          ; Compara r16 com FSM_MODE1 (MODO 1: relogio)
    brne _sm_check2             ; Se nao e FSM_MODE1, pula para verificar o proximo modo
    rjmp _handle_mode1          ; Se e FSM_MODE1, salta para o handler do modo 1

_sm_check2:
    cpi r16, FSM_MODE2_STOPPED  ; Compara r16 com FSM_MODE2_STOPPED (MODO 2: cronometro parado)
    brne _sm_check3             ; Se nao e FSM_MODE2_STOPPED, pula para verificar o proximo modo
    rjmp _handle_mode2_parado   ; Se e FSM_MODE2_STOPPED, salta para o handler do cronometro parado

_sm_check3:
    cpi r16, FSM_MODE2_RUNNING  ; Compara r16 com FSM_MODE2_RUNNING (MODO 2: cronometro contando)
    brne _sm_check4             ; Se nao e FSM_MODE2_RUNNING, pula para verificar o proximo modo
    rjmp _handle_mode2_contando ; Se e FSM_MODE2_RUNNING, salta para o handler do cronometro contando

_sm_check4:
    cpi r16, FSM_MODE3          ; Compara r16 com FSM_MODE3 (MODO 3: configuracao)
    brne _sm_end                ; Se nao e FSM_MODE3, nenhum modo bateu: encerra
    rjmp _handle_mode3          ; Se e FSM_MODE3, salta para o handler de configuracao

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
    breq _check_uart_debug        ; flag nao levantada: nada a fazer

    ; Consome a flag
    ldi r16, 0
    sts btn_mode_flag, r16
    
    ; Transita para o MODO 2
    ldi r16, FSM_MODE2_STOPPED
    sts current_mode, r16
    rcall buzzer_beep
    rjmp _end_handle_mode1

_check_uart_debug:
    ; Verifica se deve imprimir
    lds r16, uart_print_flag
    tst r16
    breq _end_handle_mode1

    ldi r16, 0
    sts uart_print_flag, r16

    ldi r30, lo8(str_modo1)     ; r30 = byte baixo do endereco da string em flash (parte baixa do ponteiro Z)
    ldi r31, hi8(str_modo1)     ; r31 = byte alto do endereco da string em flash (parte alta do ponteiro Z)
    rcall uart_send_string
    rcall uart_send_time
    
    
_end_handle_mode1:
    ret
    
; ------------------- FIM Estado 1 --------------------------------
; ------------------- Comeco Estado 2 (Parado) --------------------------------

_handle_mode2_parado:
    ; Atualiza display com cron�metro atual
    lds r16, chrono_minutes_tens
    lds r17, chrono_minutes_units
    lds r18, chrono_seconds_tens
    lds r19, chrono_seconds_units
    rcall update_display_digits
        
    ; MODE -> vai para MODO 3 (configuracao)
    lds r16, btn_mode_flag
    tst r16
    breq _check_start_parado
    
    ; Consome a flag
    ldi r16, 0
    sts btn_mode_flag, r16
    
    ; Transita de estado
    ldi r16, FSM_MODE3                       ; MODO 3 = estado 4
    sts current_mode, r16
    
    ; Copia valores atuais do rel�gio para o buffer de ajuste
    lds r16, seconds_units
    sts adjust_seconds_units, r16
    lds r16, seconds_tens
    sts adjust_seconds_tens, r16
    lds r16, minutes_units
    sts adjust_minutes_units, r16
    lds r16, minutes_tens
    sts adjust_minutes_tens, r16

    rcall buzzer_beep
    rjmp _end_handle_mode2_parado

_check_start_parado:
    ; START -> inicia cronometro (vai para estado contando = 3)
    lds r16, btn_start_flag
    tst r16
    breq _check_reset_parado
    
    sbi _SFR_IO_ADDR(PORTB), DEBUG_LED_PIN  ; seta bit 0 de PORTB: acende o LED de debug em PB0

    ; Consome a flag
    ldi r16, 0
    sts btn_start_flag, r16
       
    ; Muda para o estado contando
    ldi r16, FSM_MODE2_RUNNING                       ; estado contando
    sts current_mode, r16
    
    ldi r30, lo8(str_modo2_start)  ; r30 = byte baixo do endereco de str_modo2_start na flash
    ldi r31, hi8(str_modo2_start)  ; r31 = byte alto do endereco de str_modo2_start na flash
    rcall uart_send_string

    rcall buzzer_beep
    rjmp _end_handle_mode2_parado
    

_check_reset_parado:
    ; RESET -> zera cronOmetro
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
    ldi r30, lo8(str_modo2_zero)   ; r30 = byte baixo do endereco de str_modo2_zero na flash
    ldi r31, hi8(str_modo2_zero)   ; r31 = byte alto do endereco de str_modo2_zero na flash
    rcall uart_send_string

    rcall buzzer_beep

_end_handle_mode2_parado:
    ret

; ------------------- FIM Estado 2 (Parado) --------------------------------
; ------------------- Comeco Estado 2 (Contando) --------------------------------

_handle_mode2_contando:
    ; Incrementa o cronOmetro a cada segundo
    rcall chrono_clock

    ; Atualiza display com cronometro atual
    lds r16, chrono_minutes_tens
    lds r17, chrono_minutes_units
    lds r18, chrono_seconds_tens
    lds r19, chrono_seconds_units
    rcall update_display_digits

    ; Apenas START responde ? para o cronometro (volta para parado = 2)
    ; MODE e RESET sao ignorados mas as flags precisam ser consumidas
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
    
    ldi r16, FSM_MODE2_STOPPED                       ; volta para estado parado
    sts current_mode, r16

    ldi r30, lo8(str_modo2_start)  ; r30 = byte baixo do endereco de str_modo2_start na flash
    ldi r31, hi8(str_modo2_start)  ; r31 = byte alto do endereco de str_modo2_start na flash
    rcall uart_send_string

    rcall buzzer_beep
    rjmp _end_handle_mode2_contando

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
    breq _blink_apply            ; flag nao levantada: mantem estado atual

    ; Consome a flag e alterna o estado de piscar
    ldi r20, 0
    sts blink_event_flag, r20
    
    lds r20, blink_state
    ldi r21, 1
    eor r20, r21                 ; toggle: 0 -> 1 ou 1 -> 0
    sts blink_state, r20

_blink_apply:
    ; --- Controle do Efeito Blink (Piscar) ---
    ; blink_state = 0 -> Exibe o digito normalmente
    ; blink_state = 1 -> Mascara/apaga o digito selecionado para ajuste
    lds r20, blink_state
    tst r20
    breq _blink_done             ; Se blink_state == 0, pula a filtragem e exibe normal

    ; --- Aplicacao da Mascara no Digito Selecionado ---
    ; Carrega qual digito (0 a 3) deve ser apagado neste ciclo de blink
    lds r20, selected_digit
    
    tst r20                      ; Testa se e o digito 0 (dezena de minutos)
    brne _blink_d1
    ldi r16, 0x0F                ; Substitui valor original por 0x0F (apagado no decodificador BCD)
    rjmp _blink_done

_blink_d1:
    cpi r20, 1                   ; Testa se e o digito 1 (unidade de minutos)
    brne _blink_d2
    ldi r17, 0x0F                ; Substitui valor original por 0x0F
    rjmp _blink_done

_blink_d2:
    cpi r20, 2                   ; Testa se e o digito 2 (dezena de segundos)
    brne _blink_d3
    ldi r18, 0x0F                ; Substitui valor original por 0x0F
    rjmp _blink_done

_blink_d3:
    ; Se chegou aqui, selected_digit obrigatoriamente e 3 (unidade de segundos)
    ldi r19, 0x0F                ; Substitui valor original por 0x0F

_blink_done:
    ; Envia o arranjo de registradores (filtrados ou nao) para o buffer de exibicao
    rcall update_display_digits

    ; --- Monitoramento de Transicao de Estado (Botao MODE) ---
    lds r16, btn_mode_flag
    tst r16
    breq _check_start_mode3      ; Se botao nao foi pressionado, segue fluxo normal do Modo 3

    ; --- Salvar Alteracoes e Retornar ao Modo Relogio ---
    ldi r16, 0
    sts btn_mode_flag, r16       ; Consome a flag do botao para evitar re-gatilho

    ; Commit: Transfere os valores do buffer de ajuste temporario para o relogio real
    lds r16, adjust_seconds_units
    sts seconds_units, r16
    
    lds r16, adjust_seconds_tens
    sts seconds_tens, r16
    
    lds r16, adjust_minutes_units
    sts minutes_units, r16
    
    lds r16, adjust_minutes_tens
    sts minutes_tens, r16
    
    ; Altera o estado do sistema de volta para o MODO 1 (Relogio Principal)
    ldi r16, 1
    sts current_mode, r16
    
    rcall buzzer_beep            ; Feedback sonoro de salvamento concluido
    rjmp _end_handle_mode3       ; Sai da maquina de estados deste ciclo

_check_start_mode3:
    ; START -> avanca o digito selecionado (0 -> 1 -> 2 -> 3 -> 0)
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
    ldi r16, 0			; Se nao zera o indice
_save_selected_digit:
    ; Salva o digito que ta selecionado
    sts selected_digit, r16
    
    ; Imprime qual digito esta sendo ajustado
    tst r16
    brne _print_digit1
    ldi r30, lo8(str_modo3_dmin)   ; digito 0 = dezena dos minutos; r30 = byte baixo do endereco na flash
    ldi r31, hi8(str_modo3_dmin)   ; r31 = byte alto do endereco na flash
    rjmp _do_print_mode3
_print_digit1:
    cpi r16, 1
    brne _print_digit2
    ldi r30, lo8(str_modo3_umin)   ; digito 1 = unidade dos minutos; r30 = byte baixo do endereco na flash
    ldi r31, hi8(str_modo3_umin)   ; r31 = byte alto do endereco na flash
    rjmp _do_print_mode3
_print_digit2:
    cpi r16, 2
    brne _print_digit3
    ldi r30, lo8(str_modo3_dseg)   ; digito 2 = dezena dos segundos; r30 = byte baixo do endereco na flash
    ldi r31, hi8(str_modo3_dseg)   ; r31 = byte alto do endereco na flash
    rjmp _do_print_mode3
_print_digit3:
    ldi r30, lo8(str_modo3_useg)   ; digito 3 = unidade dos segundos; r30 = byte baixo do endereco na flash
    ldi r31, hi8(str_modo3_useg)   ; r31 = byte alto do endereco na flash
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
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)  ; le o estado atual de PORTB (contem os pinos de chaveamento dos displays)
    andi r16, ~DISPLAY_MASK             ; zera apenas os bits dos pinos de display (PB1..PB4), preserva PB0 e PB5..PB7
    out _SFR_IO_ADDR(DISPLAY_PORT), r16 ; escreve em PORTB: desliga todos os transistores de chaveamento (display apagado)
    
    ; Incrementa o indice PRIMEIRO
    lds r16, display_index
    inc r16
    cpi r16, 4
    brne _save_index
    ldi r16, 0

_save_index:
    sts display_index, r16          ; Salva o novo indice (0-3) na RAM

    ldi r30, lo8(display_digits + 3)  ; r30 = byte baixo do endereco do ultimo elemento do array (display_digits[3])
    ldi r31, hi8(display_digits + 3)  ; r31 = byte alto do endereco do ultimo elemento do array
    sub r30, r16                       ; recua o ponteiro: display_digits[3 - index]; acessa o digito correspondente ao display ativo
    ld  r17, Z                         ; carrega o valor BCD de display_digits[3-index] apontado por Z (r31:r30)

    in  r16, _SFR_IO_ADDR(BCD_PORT) ; Le o estado atual do PORT C (registrador de saida dos pinos PC0..PC7)
    andi r16, ~BCD_MASK             ; Limpa apenas os bits BCD (PC0..PC3), preserva os outros pinos do PORT C
    andi r17, 0x0F                  ; Garante que so os 4 bits baixos do digito serao usados (valor BCD valido: 0-15)
    or  r16, r17                    ; Combina os bits BCD do digito com o restante do PORT C
    out _SFR_IO_ADDR(BCD_PORT), r16 ; Envia o valor BCD para os pinos (PC0..PC3 -> decodificador BCD -> segmentos do display)

    lds r16, display_index          ; Recarrega o indice atual (0-3)
    ldi r17, (1 << DISPLAY_PIN_0)   ; R17 = 0b00000010: mascara inicial com bit 1 de PORTB (PB1 = display 0)
    tst r16                         ; Testa se indice == 0: seta Z=1 se r16 == 0
    breq _apply_display             ; Se sim, ja esta no display certo, nao precisa deslocar

_shift_loop:
    lsl r17                         ; desloca r17 um bit a esquerda: avanca para o pino do proximo display (PB1->PB2->PB3->PB4)
    dec r16                         ; decrementa o contador de deslocamentos restantes
    brne _shift_loop                ; repete enquanto r16 != 0 (flag Z=0)

_apply_display:
    ; Liga apenas o display ativo
    in r16, _SFR_IO_ADDR(DISPLAY_PORT)  ; le o estado atual de PORTB
    andi r16, ~DISPLAY_MASK             ; Desliga todos os displays (zera PB1..PB4)
    or r16, r17                         ; Liga apenas o display do indice atual (seta o bit correspondente em PORTB)
    out _SFR_IO_ADDR(DISPLAY_PORT), r16 ; escreve em PORTB: ativa o transistor do display selecionado

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
    
    ; Levanta flag de impressao UART
    ldi r16, 1
    sts uart_print_flag, r16
    
    ; --- Incrementa unidade dos segundos (0-9) ---
    lds r16, seconds_units
    inc r16
    cpi r16, 10                      ; Chegou em 10? (estouro de digito)
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
    brlo _save_min_units             ; Nao: salva e encerra
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
    lds r16, selected_digit      ; Carrega o indice do digito selecionado (0-3)

    cpi r16, 0                   ; E o digito 0?
    brne _check_digit1           ; Nao: verifica o proximo
    lds r17, adjust_minutes_tens        ; Sim: carrega a dezena dos minutos
    inc r17                      ; Incrementa
    cpi r17, 6                   ; Passou de 5? (dezena dos minutos vai de 0 a 5)
    brlo _save_min_tens_adj      ; Nao: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap - volta para 0
_save_min_tens_adj:
    sts adjust_minutes_tens, r17        ; Salva o novo valor da dezena dos minutos
    rjmp _end_increment          ; Encerra - so um digito por pressao de RESET

_check_digit1:
    cpi r16, 1                   ; E o digito 1?
    brne _check_digit2           ; Nao: verifica o proximo
    lds r17, adjust_minutes_units       ; Sim: carrega a unidade dos minutos
    inc r17                      ; Incrementa
    cpi r17, 10                  ; Passou de 9? (unidade vai de 0 a 9)
    brlo _save_min_units_adj     ; Nao: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap - volta para 0
_save_min_units_adj:
    sts adjust_minutes_units, r17       ; Salva o novo valor da unidade dos minutos
    rjmp _end_increment

_check_digit2:
    ; --- Digito 2: dezena dos segundos (range 0-5) ---
    cpi r16, 2                   ; E o digito 2?
    brne _check_digit3           ; Nao: so resta o digito 3, cai no proximo bloco
    lds r17, adjust_seconds_tens        ; Sim: carrega a dezena dos segundos
    inc r17                      ; Incrementa
    cpi r17, 6                   ; Passou de 5? (dezena dos segundos vai de 0 a 5)
    brlo _save_sec_tens_adj      ; Nao: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap - volta para 0
_save_sec_tens_adj:
    sts adjust_seconds_tens, r17        ; Salva o novo valor da dezena dos segundos
    rjmp _end_increment

_check_digit3:
    ; --- Digito 3: unidade dos segundos (posicao mais a direita, range 0-9) ---
    ; Nao precisa de cpi - se chegou aqui, so pode ser o digito 3
    lds r17, adjust_seconds_units       ; Carrega a unidade dos segundos
    inc r17                      ; Incrementa
    cpi r17, 10                  ; Passou de 9? (unidade vai de 0 a 9)
    brlo _save_sec_units_adj     ; Nao: salva o valor incrementado
    ldi r17, 0                   ; Sim: wrap - volta para 0
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

; --- uart_send_char ---
; Envia o byte em r16 pela UART0
; Aguarda o registrador de transmissao estar livre antes de enviar
uart_send_char:
    push r17                        ; empilha r17 para nao corromper o seu valor (r16 e o parametro de entrada, nao pode ser sobrescrito)
_uart_wait:
    lds r17, UCSR0A                 ; UCSR0A: registrador de status A da UART0
                                    ;   bit 7 RXC0:  1 = dado recebido disponivel no buffer
                                    ;   bit 6 TXC0:  1 = transmissao concluida (shift register vazio)
                                    ;   bit 5 UDRE0: 1 = UDR0 vazio e pronto para receber novo byte (usado aqui)
                                    ;   bit 4 FE0:   1 = erro de framing detectado
                                    ;   bit 3 DOR0:  1 = data overrun (dado perdido)
                                    ;   bit 2 UPE0:  1 = erro de paridade
                                    ;   bit 1 U2X0:  1 = modo de velocidade dupla habilitado
                                    ;   bit 0 MPCM0: 1 = modo multi-processador habilitado
    sbrs r17, UDRE0                 ; pula a proxima instrucao se o bit UDRE0 (bit5) de r17 for 1 (buffer livre)
    rjmp _uart_wait                 ; UDRE0=0: buffer ainda ocupado, espera
    sts UDR0, r16                   ; UDR0: registrador de dados da UART0; escrever aqui inicia a transmissao do byte em r16
    pop r17                         ; restaura r17 do stack
    ret
    
uart_send_string:
    lpm r16, Z+              ; carrega byte da flash e avanca ponteiro
    tst r16                  ; e o terminador nulo?
    breq _end_uart_string    ; sim: encerra
    rcall uart_send_char     ; nao: envia o caractere
    rjmp uart_send_string
_end_uart_string:
    ret
    
uart_send_time:
    ; Envia dezena dos minutos
    lds r16, minutes_tens
    ori r16, '0'             ; converte digito para ASCII
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
    
; --- buzzer_beep ---
; Inicia um bip no buzzer ativando o Timer2 em modo CTC
; O Timer2 gera interrupcoes periodicas que fazem toggle no pino PD7
buzzer_beep:
    ; Carrega duracao e ativa o buzzer
    ldi r16, BUZZER_DURATION        ; carrega a duracao do bip em ms (100ms)
    sts buzzer_counter, r16         ; salva na RAM; sera decrementado a cada tick de 1ms pela ISR do Timer0
    ldi r16, 1
    sts buzzer_active, r16          ; marca o buzzer como ativo (1); a ISR do Timer0 usara este flag para controlar o contador

    ; Liga Timer2: prescaler 64
    ldi r16, (1 << CS22)            ; CS22=1, CS21=0, CS20=0: seleciona prescaler de 64 para o Timer2
                                    ;   com OCR2A=124 e prescaler 64: f = 16MHz / (64 * (124+1)) = ~1000Hz
    sts TCCR2B, r16                 ; TCCR2B: registrador de controle B do Timer2; bits CS22:CS20 definem o prescaler e iniciam o clock

    ; Habilita interrupcao do Timer2
    lds r16, TIMSK2                 ; TIMSK2: registrador de mascara de interrupcoes do Timer2
                                    ;   bit 1 OCIE2A: 1 = habilita interrupcao de comparacao A do Timer2 (__vector_7)
                                    ;   bit 0 TOIE2:  1 = habilita interrupcao de overflow do Timer2
    ori r16, (1 << OCIE2A)          ; seta OCIE2A (bit1): habilita a ISR que faz o toggle do pino PD7 a cada comparacao
    sts TIMSK2, r16                 ; escreve em TIMSK2 com o bit OCIE2A setado
    ret