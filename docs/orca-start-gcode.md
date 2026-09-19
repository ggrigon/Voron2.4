# Start G-code do OrcaSlicer

Fica em *Printer settings → Machine G-code → Machine start G-code*.

## 2026-09-19 — config atual

```
;M190 S0
;M109 S0
PRINT_START EXTRUDER=[nozzle_temperature_initial_layer] BED=[bed_temperature_initial_layer_single] CHAMBER=[chamber_temperature] FILAMENT_TYPE=[filament_type]
```

Por que mudou:

- O perfil padrão aquecia a mesa (`M190`) e o bico a 260 °C (`M109`) antes do
  `PRINT_START`. O `CLEAN_NOZZLE` logo em seguida baixa o bico para 220 °C, e
  o `activate_gcode` do Tap espera cair abaixo de 175 °C. No log de
  2026-09-19 isso custou ~75 s por impressão (53 s subindo até 260, 23 s
  esperando voltar a 220), além de deixar o ABS escorrendo antes de sondar.
- As linhas `;M190 S0` e `;M109 S0` estão comentadas de propósito: o Orca só
  deixa de inserir os comandos de temperatura se encontrar `M190`/`M109` no
  start gcode. Quem aquece é o `PRINT_START`.
- `FILAMENT_TYPE` não era enviado, então o bloco `{% if filament_type == "PLA" %}`
  do `PRINT_START` nunca rodava.
- `PRINT_MIN`/`PRINT_MAX` não são necessários: o `BED_MESH_CALIBRATE ADAPTIVE=1`
  usa os objetos do `EXCLUDE_OBJECT_DEFINE`, que o Orca já gera.

Para conferir: fatiar algo e verificar que não há `M190`/`M109` antes do
`PRINT_START` no início do `.gcode`.

## Até 2026-09-19 — config anterior (padrão do perfil Voron do Orca 2.4.2)

Para voltar, cole isto de novo:

```
M190 S[bed_temperature_initial_layer_single]
M109 S[nozzle_temperature_initial_layer]
PRINT_START EXTRUDER=[nozzle_temperature_initial_layer] BED=[bed_temperature_initial_layer_single] Chamber=[chamber_temperature]
; You can use following code instead if your PRINT_START macro support Chamber and print area bedmesh
; PRINT_START EXTRUDER=[nozzle_temperature_initial_layer] BED=[bed_temperature_initial_layer_single] Chamber=[chamber_temperature] PRINT_MIN={first_layer_print_min[0]},{first_layer_print_min[1]} PRINT_MAX={first_layer_print_max[0]},{first_layer_print_max[1]}
```
