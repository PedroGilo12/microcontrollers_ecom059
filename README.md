# Relógio Digital — AVR Assembly (ATmega328P)

Projeto acadêmico da disciplina de Microcontroladores (ECOM059) que implementa um relógio digital com cronômetro e ajuste de hora em assembly AVR, simulado no SimulIDE.

**Autores:** Pedro Henrique Vieira Giló, Thiago Fellype Laurentino Marquel, Caio Oliveira Franças dos Anjos

---

## Visão Geral

O sistema possui três modos de operação navegáveis pelo botão MODE, com feedback sonoro via buzzer passivo e debug serial via UART. A contagem de tempo utiliza um loop cooperativo com soft-timers baseados em interrupção, onde a ISR apenas levanta flags e o loop principal consome.

---

## Hardware

| Componente | Pino(s) | Observação |
|---|---|---|
| Display 7 seg (enable) | PB1, PB2, PB3, PB4 | Multiplexação ativa-alta |
| Barramento BCD | PC0, PC1, PC2, PC3 | Compartilhado entre os 4 displays |
| Botão MODE | PD0 (PCINT16) | Pull-up interno, borda de descida |
| Botão RESET | PD2 (PCINT18) | Pull-up interno, borda de descida |
| Botão START | PD3 (PCINT19) | Pull-up interno, borda de descida |
| Buzzer passivo | PD7 | Tom gerado por Timer2 |
| UART TX | PD1 | Ocupado pela UART — não pode ser usado como GPIO |
| LED debug | PB0 | Auxiliar para depuração |

> **PD1 (TX):** O pino PD1 é reservado pelo hardware UART para transmissão serial. Quando `TXEN0` é habilitado, o ATmega328P assume controle do pino e ele deixa de funcionar como entrada GPIO. Por isso o botão START foi movido de PD1 para PD3 durante o desenvolvimento.

---

## Máquina de Estados

O projeto usa 4 estados internos para representar os 3 modos do requisito, pois o MODO 2 (cronômetro) tem dois comportamentos distintos (parado e contando):

| Estado | Valor | Descrição |
|---|---|---|
| `FSM_MODE1` | 1 | Relógio — exibe e conta MM:SS |
| `FSM_MODE2_STOPPED` | 2 | Cronômetro parado — aceita START, RESET, MODE |
| `FSM_MODE2_RUNNING` | 3 | Cronômetro contando — só aceita START (parar) |
| `FSM_MODE3` | 4 | Ajuste de hora — navega e incrementa dígitos |

### Transições

```
[MODO 1] --MODE--> [MODO 2 Parado] --START--> [MODO 2 Contando]
                        |       ^--- START ---^
                        |
                      MODE
                        |
                        v
                   [MODO 3] --MODE--> [MODO 1]
```

No MODO 2 contando, os botões MODE e RESET são **ignorados** (flags consumidas sem ação) para evitar transições acidentais durante a contagem.

---

## Arquitetura de Software

### Loop Cooperativo com Soft-Timers

O Timer0 gera uma interrupção a cada **1ms** (CTC, prescaler 64, OCR0A = 249). Dentro da ISR, múltiplos contadores são decrementados e flags são levantadas quando expiram. O loop principal consome as flags e executa as tarefas correspondentes:

```
__vector_14 (1ms)
    ├── display_pool_tick_counter  → display_pool_event_flag  (a cada 3ms)
    ├── blink_counter              → blink_event_flag         (a cada 250ms)
    ├── buzzer_counter             → desliga Timer2           (duração do bip)
    └── main_clock_tick_counter    → main_clock_event_flag    (a cada 1000ms)
                                   → chrono_clock_event_flag  (a cada 1000ms)
```

```
loop:
    display_pool    ← consome display_pool_event_flag
    main_clock      ← consome main_clock_event_flag
    state_machine   ← consome btn_*_flag, uart_print_flag, blink_event_flag
```

### Separação de Responsabilidades por Flags

Cada consumidor tem sua **flag exclusiva**. Isso evita corridas entre tarefas que competem pelo mesmo recurso:

| Flag | Produtor | Consumidor |
|---|---|---|
| `main_clock_event_flag` | ISR Timer0 | `main_clock` (incrementa relógio) |
| `chrono_clock_event_flag` | ISR Timer0 | `chrono_clock` (incrementa cronômetro) |
| `uart_print_flag` | `main_clock` | `_handle_mode1` (imprime na serial) |
| `display_pool_event_flag` | ISR Timer0 | `display_pool` (multiplexação) |
| `blink_event_flag` | ISR Timer0 | `_handle_mode3` (piscar dígito) |
| `btn_mode_flag` | ISR PCINT2 | handler do estado ativo |
| `btn_start_flag` | ISR PCINT2 | handler do estado ativo |
| `btn_reset_flag` | ISR PCINT2 | handler do estado ativo |

A `uart_print_flag` existe porque `main_clock` e o handler do MODO 1 originalmente disputavam `main_clock_event_flag` — um consumia e o outro não executava. Separar em duas flags eliminou a corrida.

A `chrono_clock_event_flag` existe pelo mesmo motivo: `main_clock` e `chrono_clock` disputavam a mesma flag. Ambas são levantadas simultaneamente na ISR.

---

## Valores de Configuração

### Timer0 — Base de Tempo (1ms)

```
F_CPU = 16 MHz
Prescaler = 64
OCR0A = 249
Período = (249 + 1) × 64 / 16.000.000 = 1ms
```

### Soft-Timers derivados do Timer0

| Parâmetro | Valor | Resultado |
|---|---|---|
| `DISPLAY_POOL_PERIOD_TICK` | 3 | Chaveamento de display a cada 3ms (~333 Hz por display, ~83 Hz ciclo completo) |
| `MAIN_CLOCK_PERIOD_TICK` | 1000 | Incremento do relógio a cada 1s (contador de 16 bits: `hi8(1000)=3`, `lo8(1000)=232`) |
| `BLINK_PERIOD` | 250 | Alternância do dígito piscando a cada 250ms (2Hz visual) |
| `BUZZER_DURATION` | 100 | Duração do bip: 100ms |

### Timer2 — Geração de Tom do Buzzer (2kHz)

```
Prescaler = 64
OCR2A = 124
Frequência de interrupção = 16.000.000 / (64 × (124+1)) = 2.000 Hz
Frequência do tom = 2.000 / 2 = 1.000 Hz (toggle gera metade da frequência)
```

O Timer2 é **ligado e desligado sob demanda** pela sub-rotina `buzzer_beep` e pelo soft-timer `buzzer_counter`. Quando inativo, `TCCR2B = 0` (prescaler desabilitado, timer parado).

### UART — Debug Serial

```
Baud rate = 9600
UBRR = 16.000.000 / (16 × 9600) - 1 = 103
Formato: 8N1 (8 bits, sem paridade, 1 stop bit)
```

---

## Buffers de Dados

O projeto usa 4 conjuntos separados de variáveis de tempo para desacoplar contagem, exibição e ajuste:

| Buffer | Variáveis | Função |
|---|---|---|
| Relógio principal | `seconds_units/tens`, `minutes_units/tens` | Contagem contínua MM:SS — roda sempre |
| Cronômetro | `chrono_seconds_units/tens`, `chrono_minutes_units/tens` | Contagem independente do cronômetro |
| Ajuste temporário | `adjust_seconds_units/tens`, `adjust_minutes_units/tens` | Buffer editável no MODO 3 |
| Display | `display_digits[4]` | Buffer de apresentação — o que aparece nos displays |

### Fluxo de dados por modo

- **MODO 1:** `main_clock` incrementa relógio → handler copia para `display_digits`
- **MODO 2:** `chrono_clock` incrementa cronômetro → handler copia para `display_digits`
- **MODO 3 entrada:** relógio → `adjust_*` (cópia snapshot)
- **MODO 3 durante:** `increment_selected_digit` modifica `adjust_*` → handler copia para `display_digits` (com máscara de blink)
- **MODO 3 saída:** `adjust_*` → relógio (commit)

Essa separação permite que o relógio continue contando em background durante o MODO 2 e MODO 3. Ao retornar ao MODO 1, o display mostra o valor atualizado. No MODO 3, o commit só ocorre ao pressionar MODE — se o usuário saísse de outra forma (o que não existe no projeto), as alterações seriam descartadas.

---

## Detecção de Botões

Os 3 botões usam **PCINT2** (interrupção por mudança de pino no PORTD). Uma única ISR detecta borda de descida por software:

```asm
pressionado = (~PIND_atual) & PIND_anterior
```

O resultado é um bitmask onde cada bit `1` indica um botão que acabou de ser pressionado. As flags individuais (`btn_mode_flag`, `btn_start_flag`, `btn_reset_flag`) são levantadas via `sbrc`/`sts` — instruções que testam e gravam condicionalmente sem afetar outros bits.

O `last_portd_state` é inicializado no `main` com o estado real dos pinos antes de habilitar interrupções, evitando falsas bordas de descida na primeira ativação.

---

## Efeito Blink (MODO 3)

O dígito selecionado pisca usando um toggle controlado por soft-timer:

1. `blink_event_flag` é levantada a cada 250ms pela ISR
2. O handler do MODO 3 faz XOR em `blink_state` (0↔1)
3. Se `blink_state = 1`: o registrador do dígito selecionado é substituído por `0x0F` (valor inválido no decodificador BCD → display apaga)
4. Se `blink_state = 0`: o valor real do `adjust_*` é exibido

O `blink_state` e `selected_digit` são resetados ao entrar no MODO 3 para garantir estado inicial consistente.

---

## Decisões de Projeto

### Por que 4 estados em vez de 3 modos + flag

O cronômetro tem dois comportamentos completamente distintos (parado aceita MODE/START/RESET, contando só aceita START). Usar `chrono_running` como flag interna funcionaria, mas criaria verificações de sub-estado espalhadas pelo handler. Com 4 estados, cada handler é focado e autocontido.

### Por que `display_digits` como buffer intermediário

O `display_pool` não conhece MM:SS, cronômetro ou ajuste — ele só percorre um array de 4 posições. Isso permite que cada modo decida o que exibir sem modificar a lógica de multiplexação. No MODO 3, o dígito pode ser "apagado" (0x0F) sem afetar os valores reais.

### Por que `adjust_*` separado do relógio

Editar diretamente `seconds_units` etc. durante o ajuste faria o `main_clock` (que roda em paralelo) incrementar valores enquanto o usuário edita. Com buffer separado, o relógio conta internamente sem interferir na edição, e o commit é atômico ao sair do MODO 3.

### Por que `main_clock` roda no loop principal e não dentro da máquina de estados

A contagem do relógio é uma tarefa **independente do modo**. Colocá-la dentro de um handler específico acoplaria a contagem ao estado ativo. No loop, ela roda sempre — o MODO 1 só decide se exibe o valor ou não.

### Por que `buzzer_beep` nos handlers e não na ISR de botão

Chamar `buzzer_beep` dentro da ISR PCINT2 faria o buzzer tocar em toda mudança de pino (incluindo bordas de subida ao soltar o botão) e em eventos que devem ser ignorados (ex: RESET durante contagem). Nos handlers, o bip só ocorre quando a ação é efetivamente executada.

### Por que PCINT2 em vez de INT0/INT1 para os botões

O ATmega328P possui duas interrupções externas com detecção de borda por hardware: INT0 (PD2) e INT1 (PD3), que permitem configurar disparo por borda de descida diretamente nos registradores `EICRA`/`EIMSK`, sem necessidade de comparar estados anterior e atual por software. Apesar dessa vantagem, optamos por PCINT2 pelos seguintes motivos:

- **Quantidade de botões:** Temos 3 botões (MODE, START, RESET), mas INT0/INT1 cobrem apenas 2 pinos. O terceiro botão precisaria de PCINT de qualquer forma, resultando em duas abordagens diferentes de detecção no mesmo projeto — uma com borda por hardware e outra por software.
- **Uniformidade:** Usar PCINT2 para os 3 botões unifica toda a detecção em uma única ISR com uma única lógica de borda de descida por software (`(~atual) & anterior`). Isso simplifica a manutenção e facilita a explicação do código.
- **Flexibilidade de pinos:** O PCINT funciona em qualquer pino do PORTD. Quando descobrimos que PD1 conflitava com a UART TX e precisamos mover o START para PD3, bastou mudar a constante `BTN_START_PIN` e o bit em `PCMSK2`. Com INT0/INT1, os pinos são fixos — qualquer mudança de pino exigiria reescrever a abordagem de interrupção.
- **Conflito de pinos:** PD2 (RESET) compartilha o pino com INT0, e PD3 (START) com INT1. Usar INT0/INT1 para dois botões e PCINT para o terceiro criaria uma assimetria desnecessária no código, com dois vetores de interrupção diferentes e duas formas de detectar pressão de botão.
