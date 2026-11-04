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

## Capturas de Claude Code 2.1.289

Seis pantallas reales escaneadas: `idle`, `modal`, `done` y arranques `t-1`, `t-3`, `t-5`.
`done.txt` conserva el turno terminado y clasifica como reposo (rc 1).
`busy.txt` copia la captura en curso con contador de `t-5.txt` (rc 0).
Los tres arranques muestran actividad (rc 0). `redraw.txt` se deriva de `busy.txt`
con `tco_redraw_fixture_from`, el mismo método del capturador.
Este juego conserva evidencia del ensayo; no habilita por sí solo una entrada del registro.
`TCO_PANE_CALIBRATED` sigue vacío por defecto.
