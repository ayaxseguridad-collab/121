# Fixtures de pane (calibración del fallback de `tco_pane_busy`)

Cada entrada del registro `TCO_PANE_CALIBRATED` (par `cli:version`, `scripts/00-config.sh`) EXIGE aquí un
juego COMPLETO de cuatro capturas **no vacías** en `fixtures/pane/<cli>_<version>/`:

| Fichero | Estado del pane | `tco_pane_busy_from` debe dar |
|---|---|---|
| `idle.txt` | composer presente y quieto | `1` (idle) |
| `busy.txt` | turno en curso (actividad en footer o pegada al compositor) | `0` (busy) |
| `modal.txt` | diálogo/menú abierto, sin composer | `2` (desconocido) |
| `redraw.txt` | recorte de captura real anterior al compositor (chrome incompleto) | `2` (desconocido) |

El instalador (`calibrar-pane.sh`, F7) exige para registrar un par dos capturas más: `done.txt` (turno terminado,
reposo → `1`) y `barra.txt` (`/model` tecleado sin Enter, con la lista de órdenes abierta → `1`).

El arnés (`tests/run-tests.sh`, sección «Fixtures de pane») comprueba, para cada par del registro: los cuatro
ficheros existen y no están vacíos, cada uno clasifica como arriba, y ninguno contiene secretos, cuentas ni
rutas personales (`tco_fixture_secret_scan`). Un par sin juego completo hace fallar la suite.

## `synthetic_0.0.0/`

Entrada **sintética** (texto escrito a mano, NO una captura real): demuestra que el mecanismo funciona y sirve
de control positivo/negativo del arnés. NO está en el registro por defecto (`TCO_PANE_CALIBRATED` nace VACÍO:
sin capturas reales de un Codex vivo el fallback es inerte → rc 2 → entrega manual verificada, INV-CO-020).

## Alta de una entrada REAL (primer Codex vivo del ensayo en frío, TAL-8047)

1. Con el pane en cada estado, desde el host de operación:
   `bash scripts/capture-pane-fixtures.sh <idle|busy|modal|redraw> <carril> [pane]`
   (resuelve `cli:version` del proceso real y escribe `tests/fixtures/pane/<cli>_<version>/<estado>.txt`).
2. El capturador **se niega a escribir** si detecta un secreto, una cuenta (correo) o una ruta personal
   en la entrada ORIGINAL antes de normalizar, y vuelve a escanear el resultado antes de escribir.
   Solo se aceptan rutas previamente neutralizadas como `/home/USER`. Nunca se imprime el valor detectado.
3. Con los cuatro ficheros, añadir `cli:version` a `TCO_PANE_CALIBRATED` (`agents.conf`) y, si los regex
   globales de chrome no segmentan ese CLI, el override por CLI correspondiente.
4. Revisar las capturas a mano antes de hacer commit: son datos versionados.

Antes de capturar `idle`, dejar la pantalla sin hashes ni cuentas con la orden `/clear` del CLI.
El escáner rechaza cadenas opacas largas, incluidos los hashes completos de commits; no se omite
esa comprobación para obtener una captura.

Para `redraw` no hace falta provocar un redimensionado. El capturador toma una pantalla real,
localiza el compositor íntegro y conserva exclusivamente las líneas anteriores a su borde superior.
Exige un recorte no vacío y clasificación desconocida (rc 2). Sin compositor localizable falla;
no añade texto manual ni acepta una captura incompleta como entrada.

## Capturas de Codex 0.166.0

| Dato | Valor |
|---|---|
| Fuente | TUI vivo de `codex-cli 0.166.0`, instalado con npm, lanzado como el lanzador `codex-root` del golden (`IS_SANDBOX=1` y los flags de modo autónomo de `CODEX_ROOT_FLAGS`) en tmux de 200×50 |
| Sistema | Ubuntu 26.04.1 LTS |
| Fecha | 4-nov-2026 |
| Cuenta | de ensayo; ninguna captura muestra cuenta, correo ni plan (pasan `tco_fixture_secret_scan`) |

Juego de seis estados (`idle`, `busy`, `done`, `modal`, `redraw`, `barra`) más `slash/` con las nueve capturas de
las órdenes de F7 con color (`.ansi.txt`, cuyas sumas están en `SHA256SUMS`): reposo, texto corto, un `lee …` de
dos líneas, texto con un turno en curso, ocupado, la barra con un turno en curso, terminado, la barra y el selector.
Quitando las secuencias CSI, cada una es idéntica byte a byte a la captura sin color del mismo instante. Los
seis estados se leen con el perfil `codex` (`TCO_TUI_CLI=codex`); con el perfil de Claude no tienen estructura
(rc 2), y a la inversa. `idle`, `busy`, `done` y `modal` son la captura cruda; `barra` es la cruda sin su última fila
vacía; `redraw` es el recorte que produce `capture-pane-fixtures.sh` sobre `done` (las líneas anteriores al
compositor). Este juego es corpus de regresión y habilita la calibración de `codex:0.166.0` con
`calibrar-pane.sh`; no entra por sí solo en el registro (`TCO_PANE_CALIBRATED` sigue vacío por defecto).

## Capturas de Claude Code 2.1.302

Juego de seis estados de la calibración (`idle`, `busy`, `done`, `modal`, `redraw`, `barra`) más `slash/`
(`.txt` y `.ansi.txt`: reposo, `/model`, `/effort`, `/mod`, texto normal, `/effort xhigh` y un texto largo
de dos líneas), todo de un TUI vivo. `barra` es `/model` tecleado SIN Enter con la lista de órdenes abierta: el
estado que falló en el ensayo (rc 1, reposo) y que el estado `idle` no cubre. Desde la 2.1.295 esa lista lleva las
filas con cuatro espacios, la seleccionada con `  ❯ ` y la descripción en la columna 32 (en 2.1.289: dos espacios y
columna 36); `test-slash-composer.sh` ejercita ambas formas con capturas reales. Única edición sobre la captura
cruda: la ruta del directorio de trabajo del ensayo (cabecera del TUI) se sustituyó por `/…/Repo-Neutro`; el resto
pasó por `capture-pane-fixtures.sh` y `tco_fixture_secret_scan`. Los `.ansi.txt` llevan las sumas de los bytes
originales en `SHA256SUMS`. Este juego es corpus de regresión: no habilita por sí solo una entrada del registro
(`TCO_PANE_CALIBRATED` sigue vacío por defecto: lo escribe `calibrar-pane.sh --registrar` en cada instancia).

## Capturas de Claude Code 2.1.318 (diálogo del plan pendiente)

Tres ficheros REALES del ensayo de la 1.7.5 (VM e2, canal 11, 5-nov-2026), que respaldan a `tests/test-plan-pantalla.sh`.
No son un juego de calibración (no hay `idle`/`busy`/`modal`/`redraw`) ni entran en `TCO_PANE_CALIBRATED`.

| Fichero | Qué es | Origen | Edición |
|---|---|---|---|
| `plan-dialog.txt` | las 30 últimas líneas de `tmux capture-pane -p` del pane del dev con el diálogo «Would you like to proceed?» abierto (tres opciones, continuación y pie, sin compositor) y el final del plan | Claude Code 2.1.318, pane `.0`, 5-nov-2026 19:43:41Z | solo el nombre del fichero del plan en el pie (59 caracteres opacos que `tco_fixture_secret_scan` veta), sustituido por `plan-neutro.md` |
| `session-waiting.json` | `~/.claude/sessions/<pid>.json` con el diálogo abierto: `status` `waiting`, `waitingFor` `permission prompt`, `statusUpdatedAt` 19:22:07Z | misma sesión, leído el 5-nov-2026 19:43Z | `cwd`, `sessionId`, `pidDomain`, `name` y el resto de identificadores del anfitrión sustituidos por marcadores neutros; versión, estado y marcas de tiempo intactos |
| `exitplan-plan.txt` | `input.plan` real de los ExitPlanMode #2 y #3 (idénticos byte a byte, 15 935 B) | jsonl de la sesión, copia de solo lectura de la VM | la clave del encargo y la de otra issue por `ABC-…`, el slug de la rama de 58 caracteres (vetado por «cadena opaca larga») por uno corto, y el prefijo de rama del usuario por `usuario/`; el resto, tal cual. Se llamó `exitplan-plan.md` y se renombró a `.txt` (es dato, no documentación; el comprobador de programas de columnas del motor trata los `.md` como documentos ejecutables y este plan cita ese programa). Bytes idénticos: sha256 antes y después, en dos mitades por el barrido de secretos: `ff6fcff487f5362849463de3e4e3546c` y `aa78a753a2040908aa3729e6ed151f14` |

Lo que prueban: el diálogo abierto (estructura de 2.1.318) y sus variantes negativas; que el estado `waiting` se persiste en
disco desde 19:22:07Z, después del rechazo del #2 (19:21:27.995Z) y antes del del #3 (19:45:53.502Z); y que el final del plan
en bruto y su render real del TUI NO coinciden con el criterio de espacios en blanco de la comparación con el ledger
(sin la sangría de 1 espacio, los `#`, `**` ni los backticks del TUI): un plan crudo contra uno renderizado se audita de
más, nunca de menos.
El jsonl de los casos se construye en el propio test con los datos medidos (marcas de tiempo, orden de los registros y este
`input.plan`); sus identificadores de herramienta y los registros `api-request`, `attachment` y `system` son sintéticos.

## Capturas de Claude Code 2.1.289

Seis pantallas reales escaneadas: `idle`, `modal`, `done` y arranques `t-1`, `t-3`, `t-5`.
`done.txt` conserva el turno terminado y clasifica como reposo (rc 1).
`busy.txt` copia la captura en curso con contador de `t-5.txt` (rc 0).
Los tres arranques muestran actividad (rc 0). `redraw.txt` se deriva de `busy.txt`
con `tco_redraw_fixture_from`, el mismo método del capturador.
Este juego conserva evidencia del ensayo; no habilita por sí solo una entrada del registro.
`TCO_PANE_CALIBRATED` sigue vacío por defecto.

## Capturas de Codex 0.167.0 y Claude Code 2.1.319 (diálogo de aprobación, issue 10264)

Juego PARCIAL de cinco capturas reales (ensayo de 7-nov-2026): no hay `idle`, `done`, `modal`, `redraw` ni `barra`, no es un
juego de calibración y NO entra en `TCO_PANE_CALIBRATED`. Aviso de efecto lateral: `calibrar-pane.sh` y `f8-capturas.sh`
deciden «sin capturas de referencia en el paquete» solo por que EXISTA el directorio `<cli>_<versión>`; con `codex_0.167.0/`
presente dejan de avisarlo para 0.167.0 aunque el juego esté incompleto. Es una decisión declarada de la issue 10264.

| Fichero | Qué es | Edición |
|---|---|---|
| `codex_0.167.0/dialogo-proceed-sandbox.txt` | diálogo «Would you like to run the following command?» con el sandbox roto (razón envuelta en dos líneas) | ninguna (byte a byte) |
| `codex_0.167.0/dialogo-proceed-lectura.txt` | el mismo diálogo para una orden de lectura, con la opción 2 envuelta y el historial «You approved … this time» encima | ninguna (byte a byte) |
| `codex_0.167.0/busy.txt` | Codex trabajando (`Working … esc to interrupt`), sin diálogo y con compositor | `~/Talent-Agents` por `~/producto` (cabecera y línea de estado) |
| `codex_0.167.0/historial-aprobado.txt` | pane tras interrumpir: solo historial `✔ You approved codex to run … this time`, sin diálogo abierto | usuario de `/home/…` por `USER`, SHA de 40 por 12 hex, espacios finales quitados, el proyecto y los títulos de tres filas de un índice por nombres neutros |
| `claude_2.1.319/exitplan-dialog.txt` | ExitPlanMode de Claude («…Would you like to proceed?», tres opciones): NO es un diálogo de Codex | el nombre del fichero del plan del pie (55 caracteres opacos) por `plan-neutro.md` |

Lo que prueban: la estructura del diálogo de Codex 0.167.0 (título, `Environment`, `Reason`, fila `$`, tres opciones con cursor `›` solo
en la primera, pie «Press enter to confirm or esc to cancel»), que no hay compositor ni línea de estado bajo él, y que ni el busy
ni el historial ya resuelto ni el ExitPlanMode de Claude son un diálogo de aprobación. Sin `SHA256SUMS` (son `.txt` planos).
Las variantes (un solo marcador, orden de red, orden de 30-40 líneas, diálogo citado, trust y update sintéticos) se derivan en un
temporal de la suite y nunca entran aquí. Trust y update son SINTÉTICOS y están «por medir»: no hay captura real.
