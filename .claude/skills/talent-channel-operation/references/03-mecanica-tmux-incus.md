# 03 — Mecánica tmux / Incus

Toda la mecánica vive en `lib.sh` y se apoya en `incus exec <contenedor> -- su - vivecoder -c
'tmux …'` **sin sudo** (grupo `incus-admin`).

## Table of Contents

- [1. Captura de pantalla](#1-captura-de-pantalla)
- [2. Doctrina de entrega v5: relay por archivo a AMBOS panes](#2-doctrina-de-entrega-v5-relay-por-archivo-a-ambos-panes)
- [3. Verificación de entrega](#3-verificación-de-entrega)
- [4. Aislamiento de fallos parciales](#4-aislamiento-de-fallos-parciales)
- [5. Higiene de lectura del pane](#5-higiene-de-lectura-del-pane)
- [6. Framing del contenido relevado](#6-framing-del-contenido-relevado)
- [7. Monitor por estado y detección sin falsos positivos](#7-monitor-por-estado-y-detección-sin-falsos-positivos)
- [8. Gate de plan en ExitPlanMode](#8-gate-de-plan-en-exitplanmode)
- [9. Enrutado de AskUserQuestion del dev](#9-enrutado-de-askuserquestion-del-dev)
- [10. Auto-nudge de relays de acción](#10-auto-nudge-de-relays-de-acción)
- [11. Bypass, effort y modelo](#11-bypass-effort-y-modelo)
- [PROC-00 — Arranque en frío](#proc-00--arranque-en-frío)
- [PROC-01 — Relay bajo el hook del host](#proc-01--relay-bajo-el-hook-del-host)
- [PROC-02 — Rebuild de pane de auditor muerto](#proc-02--rebuild-de-pane-de-auditor-muerto)
- [PROC-11 — Limpiar cola duplicada del composer](#proc-11--limpiar-cola-duplicada-del-composer)
- [PROC-17 — NO-GO de plan sin perder plan mode](#proc-17--no-go-de-plan-sin-perder-plan-mode)
- [13. Relay robusto v2 + carril PARKED + impasses](#13-relay-robusto-v2--carril-parked--impasses-p2tal-2295)
- [14. Flota remota (ssh + incus) — GAP no soportado](#14-flota-remota-ssh--incus--gap-no-soportado)

## 1. Captura de pantalla

`tco_cap_pane <carril> <pane> [scrollback_n]` → pantalla **visible** con `-J` (une soft-wraps), clave
para reconstruir el **JSON del veredicto** que el terminal parte en varias líneas. Capturar el scrollback
completo arrastra bloques viejos y rompe el parseo: el monitor y el parser miran la pantalla visible
(el sweep de recuperación usa scrollback amplio SOLO atado al nonce — ver `04`).

```bash
tco_cap_pane 01 "$(tco_pane_dev)"      # pane de desarrollo, pantalla actual
tco_cap_pane 01 "$(tco_pane_audit)"    # pane de auditoría
```

## 2. Doctrina de entrega v5: relay por archivo a AMBOS panes

`paste-buffer` **NO es fiable en NINGÚN pane**: falla en silencio al pane del dev (bug raíz de 1.0) y
falló también en panes de auditoría **originales y reciclados** (producción, batch v14) —
`tco_send_paste`/`tco_send_paste_raw` quedan **DEPRECADOS** (shims con aviso que delegan en
`tco_relay_file`; no usarlos en código nuevo). Doctrina v5 — file + `lee` para dev Y auditoría,
SIEMPRE con entrega verificada:

- **Vía canónica multilínea (ambos panes)** → `tco_relay_file <carril> <pane> <localfile> [tag] [msg]
  [verify_max]`: archivo único (nombre aleatorio del host bajo `~/.tco-relay`, `0600`) vía
  `incus file push` + `send-keys -l -- "lee <ruta> …"` (**un único submit**, sin fragmentar). Ruta y
  mensaje van como **parámetros posicionales** al shell remoto (inmune a comillas/`$`/backticks)
  [Mayor 2]. `tco_send_dev_file` queda como alias de compatibilidad.
- **Contenido con fences/backticks/`$()`/comillas anidadas → SIEMPRE la vía de archivo, NUNCA
  `send-keys` ni interpolado en `incus exec … -c '<script>'`**: al meter un HANDOFF (o cualquier
  bloque fenced) por esa ruta, el shell del HOST expande `$()`/backticks ANTES de entrar al
  contenedor y el bloque llega mutilado en silencio (visto: un relay de HANDOFF reventó con
  `unexpected EOF`). La vía canónica de arriba pasa ruta+mensaje como posicionales y por eso es
  inmune; la regla es no salirse de ella para contenido fenced.
- **Panes frescos tardan ~40s+** en procesar tras el `lee`: ventana de verificación configurable
  (`verify_max`); en el pane de auditoría usar `TCO_RELAY_VERIFY_MAX` (default 90).
- **Submit con propiedad acreditada**: ningún texto ni tecla de envío se entrega sin reposo,
  ausencia de anomalía, compositor identificable y vacío antes del tecleo, y eco propio íntegro
  antes del submit. `tco_send_submit` recibe el texto propio pendiente y exige igualdad exacta en
  Claude; vacío → rc 0 sin tecla, ajeno o ambiguo → rc 2. Otros CLI conservan las teclas históricas
  de `tco_audit_submit_keys`, fuera del alcance de esta lectura del compositor.
- **dev, single-line** → `tco_send_dev <carril> <pane> <text>` (`send-keys -l`). Rechaza multilínea;
  avisa si el texto contiene el literal `git push` (doctrina de fraseo, PROC-01).
- **GO de plan (no bloqueante)** → `tco_queue_dev_file`: exige también reposo y compositor vacío.
  Si el dev está ocupado o queda texto pendiente, devuelve rc 2 y escala sin encolar.
- **[Anti-menú] `capture-pane` ANTES de todo `send-keys` a pane ajeno**: si el pane destino tiene
  un menú abierto (ExitPlanMode `Would you like to proceed?`, AskUserQuestion `Enter to select`,
  `/model`, `/effort`) cualquier key enviado puede elegir una opción en silencio antes de
  que llegue el relay. Regla: `tco_cap_pane <carril> <pane>` ANTES de `tco_relay_file` /
  `tco_send_dev`; si se detecta menú → resolver el menú PRIMERO (§8/§9) y LUEGO enviar el relay.
  Modelo, effort y confianza se navegan automáticamente con captura nueva, título, filas,
  cursor y pie completos, sin compositor debajo, y efecto verificado. Un diálogo distinto,
  incompleto o citado se rechaza sin teclas. Las encuestas se descartan tras detectar de nuevo
  la anomalía correspondiente justo antes de `n` o `0`.

## 3. Verificación de entrega

[Cond. 2 + B1, endurecido TAL-3619] `tco_verify_delivered` prueba entrega por **AUTORIDAD en disco
primero** (con token + superficie de sesión calibrada): SET-DIFF de uuids de submisiones que
contienen el token entre ANTES/DESPUÉS del envío (`tco_user_submit_uuids_from`) — un uuid
REALMENTE NUEVO confirma; opera sobre el `.jsonl` persistido (append-only, sin límite de
scrollback), así que ninguna aparición vieja puede "salirse" entre lecturas (a diferencia del
conteo sobre el viewport del pane, que SÍ era vulnerable a eso). Con entrega confirmada, escribe el
`uuid` de la submisión en un **out-param por fichero** (`uuid_out`, opcional) — la única vía real
para cablear la cadena `parentUuid` de vuelta al llamador (`tco_verify_model_effect`).
**FALLBACK** (sin token/sin superficie calibrada): **transición del composer** — el texto debe
haber DESAPARECIDO del composer (consumido) tras el submit; ya NO basta con ver actividad de
fondo sin ligarla al envío propio (bug de ch06: `tco_send_dev` reportó exit 0 dos veces con el
texto NUNCA llegado). Precondición: `tco_wait_idle` (idle **estable** vía `tco_pane_idle_stable`, no
mera ausencia de texto [Mayor 3], y **tri-estado**: rc 2 ambigua NUNCA autoriza un envío, r11). El
**contador de líneas NO es criterio** (el eco de `lee <ruta>` lo movería).

Refuerzos [B1] (detalle y motivación en §4):

- **Ack por contenido**: además del flanco, confirmar la entrega por **contenido** — eco de un token
  conocido en el pane / confirmación del propio dev ("brief recibido"). No depender solo de idle→busy.
- **`sleep` corto entre `-l` y el submit**: sin un `sleep` breve en medio, tmux puede **descartar el
  literal** si el Enter llega antes de bufferarlo.
- **Anomalías antes de reintentar**: los reintentos de `tco_relay_file` pasan por `tco_pane_anomaly`;
  una cola duplicada NO se re-alimenta (rc 3, PROC-11) y la encuesta se declina antes de reintentar.
- **Bracketed-paste no submitea al primer Enter**: un pegado que el TUI muestra como
  `[Pasted text #N]` queda en el composer tras el primer Enter — hace falta un **segundo Enter**
  para submitear. Verificar la entrega **por conducta** (el pane consumió el contenido: eco/ack o
  idle→busy), nunca dar por enviado un paste por haber pulsado Enter una vez.

`tco_clear_input <carril> <pane>` y `tco_deep_clear_input` no hacen nada si está vacío. Solo borran
eco exacto del texto pendiente que este proceso tecleó y verifican el vacío después. Input ajeno,
ambiguo o desconocido devuelve rc 2 sin borrado; las sugerencias grises no cuentan como contenido.

## 3b. [TAL-3619] Evidencia en disco (Primitiva A) — AUTORIDAD sobre el chrome del pane

El propio CLI persiste su estado real (`~/.claude/sessions/<pid>.json`: `pid`, `sessionId`,
`cwd`, `procStart`, `status`, `statusUpdatedAt`, `version`) y su historial de turnos
(`~/.claude/projects/<slug-del-cwd>/<sessionId>.jsonl`, append-only) FUERA del pane. Eso es lo que
se verifica para modelo/effort servido, liveness y entrega — no el chrome del TUI, que un
contenido adversarial (un veredicto que CITE `esc to interrupt`, por ejemplo) puede imitar.

Cadena de resolución (seams inyectables, patrón `_tco_carril_git`): `tmux #{pane_pid}` → PID
descendiente cuyo `/proc/<pid>/cmdline` es el CLI → `sessions/<pid>.json`, validado por identidad
de PROCESO (`procStart` == `starttime` real de `/proc/<pid>/stat`, anti-reutilización de PID) y
`cwd` == repo del carril — **nunca por mtime** (r7-B1: el más reciente por mtime no demuestra que
pertenezca al pane objetivo; puede ser otra sesión en el mismo cwd). El `status` es un **estado
PERSISTENTE, no un lease** (r8-B1): la vigencia la da la identidad de proceso, no la antigüedad de
`statusUpdatedAt` — salvo la ÚNICA excepción asimétrica de un `busy` rancio sin corroboración de
`tool_use` en vuelo (`TCO_SESSION_BUSY_STALE_MAX`). [Endurecido en code-gate, TAL-3619/r14]
CONTRATO DUAL: se CALIBRAN **AMBOS** vocabularios explícitamente —
`TCO_SESSION_STATUS_BUSY_VALUES` (medido = `busy`) Y `TCO_SESSION_STATUS_IDLE_VALUES` (medido =
`idle`) — vía `tco_session_liveness_from`. Un `status` que NO calce con NINGUNO de los dos
vocabularios es **DESCONOCIDO SIEMPRE** (rc 2), incluso SIN turno `tool_use` en vuelo: la ausencia
de `tool_use` inflight **corrobora** (puede degradar idle→busy vía la excepción asimétrica de
arriba, nunca al revés) pero **jamás por sí sola clasifica** un status no-calibrado como reposo —
el status desconocido NUNCA se adivina como idle solo porque no hay turno en vuelo (r14: el
vocabulario viejo de un solo lado, "todo lo que no es busy es reposo", quedó retirado). Un
`status` VACÍO/no-legible sigue siendo desconocido (fail-closed: eso indica esquema roto, no
reposo).

**Solo cubre CLIs con esta superficie** (hoy: Claude). Para el resto (codex), estos helpers
fallan `rc 1` y el llamador cae a la Primitiva B (§2-3, región del TUI) — que a su vez EXIGE
calibración probada de `cli:versión` (`TCO_PANE_CALIBRATED`, registro que ships VACÍO: sin capturas
reales de un Codex vivo no hay entrada calibrable) antes de afirmar
`idle`/`busy`; sin calibración, `rc 2` SIEMPRE — nunca se teclea ni se submite sobre un estado
desconocido (r11: el puente `tco_pane_can_receive` que sí lo permitía fue RETIRADO del diseño).

### 3c. [TAL-8042] Calibración con fixtures y preflight de identidad de los panes

**Fixtures (`tests/fixtures/pane/<cli>_<ver>/{idle,busy,modal,redraw}.txt`).** Cada par de
`TCO_PANE_CALIBRATED` exige el juego **completo y no vacío**, y cada captura debe clasificar con
`tco_pane_busy_from` como **idle→1, busy→0, modal→2, redraw→2**; la suite lo asserta por cada entrada del
registro y ninguna captura puede contener secretos, cuentas ni rutas personales (`tco_fixture_secret_scan`).
`scripts/capture-pane-fixtures.sh <estado> <carril> [pane]` captura el pane vivo, normaliza `/home/<usuario>`
a `/home/USER` y **se niega a escribir** si detecta un secreto o una cuenta (nunca imprime el valor). La
entrada `synthetic_0.0.0/` es SINTÉTICA (control del mecanismo), no está en el registro. El alta de
`codex_<ver>` con capturas reales es del primer Codex vivo del ensayo en frío; hasta entonces el fallback
nace inerte (rc 2 ⇒ entrega manual verificada por captura, INV-CO-020: ninguna perilla autoriza envío bajo rc 2).

**Preflight de identidad (`tco_pane_identity_preflight`, llamado por `dispatch.sh` en normal y `--soft`
ANTES del gate de modelo, del brief y del rol).** El pane `.0` debe ejecutar el binario de `TCO_DEV_CLI` y el
`.1` el de `TCO_AUDIT_CLI`, **por proceso real**. Antes de lanzar, la **sonda** es un `respawn-pane -k` en
el MISMO pane de destino, con el mismo `-c` (el clon) y la misma forma de orden que el lanzamiento (nunca
una ventana nueva ni un servidor `tmux -L` propio): la shell de ESE pane resuelve el lanzador y el agente
(`command -v` + `readlink -e`) y los escribe en un marcador 0600 con el nonce del despacho, en
`~/.local/state/talent-channel-operation/sonda` del usuario del canal. Marcador ausente, nonce distinto,
ruta relativa o inexistente o permisos distintos de 0600 → fallo cerrado; el marcador se borra al leerlo.
El lanzamiento ejecuta la **ruta canónica absoluta** que acreditó la sonda (sin volver a resolver por PATH).
Por eso el despacho crea los dos panes y fija `remain-on-exit` ANTES de la sonda, y lanza después. La
identidad compara `/proc/<pid>/exe` del pane y sus descendientes con esa ruta acreditada por
dispositivo:inodo (la de ese proceso o, para el doctor y `--soft`, la del fichero 0600
`~/.local/state/talent-channel-operation/acreditacion/pane.<vida>.<N>` que escribe el despacho desde fuera del
pane, con la clave vida del servidor tmux (`#{pid}.#{start_time}`) + `%N`, porque tras `kill-server` o un
reinicio el servidor nuevo reutiliza los `%N`; ninguna opción de tmux acredita: no falsificable por la vía de
tmux; un proceso del mismo usuario con intención sí puede). Todo sitio que lanza lee una vez el id estable del
pane (`%N`) y, desde ese momento, es su ÚNICO destino: la sonda, el lanzamiento, `remain-on-exit`, la vida, la
identidad y todo lo que se espera, calibra, teclea o captura después. Donde la sesión YA EXISTÍA (`--soft` y el
relanzamiento de codex), los `%N` de los panes del canal se leen una vez, ANTES de cualquier tecla (en `--soft`, antes
del `/clear` del reciclaje, que los recibe), en UNA orden de tmux con todos los panes de la sesión
(`tco_panes_fijar_sesion`). El paquete nunca abre otra ventana en la sesión del canal (hecho observado), así que
con más de una ventana, con algún pane fuera de .0 y .1 en la única o sin los panes que necesita (`--soft` los
dos; el relanzamiento, el de su destino), falla cerrado (rc 1) sin teclear nada, con lo encontrado y el remedio
(«cierra las ventanas que no sean la del canal»). Condición: no abras otras
ventanas ni panes en la sesión del canal; con ellos `--soft` y el relanzamiento se niegan. La condición vale para
todo el canal, no solo para `--soft` y el relanzamiento: la comprobación de canal libre (`tco_carril_libre`) y el
«continuemos» de la reautenticación (`tco_reauth_carril`) todavía resuelven el pane por la ventana activa, así que
con otra ventana activa la comprobación puede dar el canal por libre y el «continuemos» llegar al pane de otro
agente. Lo que va por el `%N` no
lo desvía una ventana que se abra o se active DESPUÉS de esa lectura (medido en todo el relanzamiento y en el
reciclaje de `--soft`). El relanzamiento compara además la vida del servidor tmux (`#{pid}.#{start_time}`, fijada
al leer el `%N`) en cada observación: la espera del TUI, el salto de update/trust, el relay, cada captura del ACK
(antes y después) y la identidad tras el ACK; si el servidor murió y otro reutiliza ese `%N`, rc 1 sin «rol
recargado». Lo que se hace entre una comprobación y la siguiente no compara la vida: en una orden suelta, es la
carrera de esa orden; en el relay del rol (`tco_relay_file`), es todo el relay (su espera de reposo de hasta 120 s,
sus reintentos y su envío), así que si el servidor cambia durante el relay lo tecleado puede llegar al pane del
servidor nuevo con el mismo `%N`, y la comprobación siguiente da rc 1 sin «rol recargado». Si la vida cambia entre
la lectura del `%N` y la sonda, la sonda ya pudo matar el proceso de ese `%N` en
el servidor nuevo antes de fallar. La acreditación de este proceso solo vale en la vida del servidor con que se hizo:
la identidad de un `%N` de otra vida falla cerrada, también en la identidad y la calibración de `--soft`. `--soft` NO
compara la vida en la espera de reposo, el `/clear`, el modelo, el effort ni el brief: si el servidor tmux muere y
otro reutiliza el `%N` durante un despacho suave, esas órdenes irían al pane del servidor nuevo; no reinicies tmux
ni el contenedor durante un despacho. Quien llama directamente a `tco_recycle_carril <carril> --soft`, sin
`dispatch.sh`, no pasa por la identidad posterior: si el servidor cambió, el `/clear` pudo ir al pane del servidor
nuevo y aun así recibe rc 0 («recycle SUAVE hecho»). Si la sonda no
termina en 10 s se corta por PID verificado el árbol de ese pane y no queda marcador. El relanzamiento de codex
y la auditoría comprueban la identidad tras lanzar; el relanzamiento solo declara «rol recargado» con el ACK
de la respuesta del agente capturado de ese `%N` tras el relay (el mensaje del relay no lleva el token, así que
su eco no cuenta) y su identidad, comprobada otra vez tras el ACK, y cualquier fallo da rc 1 con el rc de cada paso; un pane que ninguna sonda acreditó (lo arranca por teclas `preparar-sesiones.sh`) se lee
resolviendo en la shell de lectura, sin lanzar nada. El nombre no acredita identidad. `TCO_DEV_CLI` y `TCO_AUDIT_CLI` son UN solo ejecutable
(gramática cerrada: nombre de lanzador o ruta absoluta; flags en `TCO_*_FLAGS`): una asignación `VAR=valor`,
`env`, un espacio, un metacarácter o una ruta relativa se rechaza antes de lanzar nada, en el despacho, la
auditoría, el relanzamiento de codex, `preparar-sesiones.sh` y este preflight. Con la topología `distinto` se
comparan además las rutas REALES de dev y auditor y su dispositivo:inodo: dos nombres o dos enlaces duros que
son el mismo ejecutable no son proveedores independientes. Tras `respawn-pane` el despacho comprueba que cada
pane sigue vivo (`tco_panes_vivos`, con `remain-on-exit` mientras se lanza, restaurado después exactamente como
estaba) y, si murió, falla con el CLI, el pane, el rc o la señal (o «estado de salida aún no disponible» si
tmux no lo da) y el remedio (nunca «can't find pane: 1»).
Los scripts se admiten exclusivamente con un intérprete conocido (`node`, `nodejs` o `python3`) y el primer
argumento resuelto a la ruta real declarada; opciones anteriores al script y envoltorios shell se rechazan.
Declara la ruta del binario o script real: un alias `-root` no se traduce automáticamente a otro ejecutable.
Cualquier dato ilegible o enumeración parcial detiene el despacho.
Una desviación detiene el despacho
(`tco_die`): el ACK del rol lo emite cualquier agente y `audit-gate.sh` solo mira que el pane exista, así que
sin este gate un auditor del mismo proveedor que el dev pasa por independiente. `TCO_AUDIT_TOPOLOGY`:
solo `distinto` (auditor Codex ≠ agente del dev; con otro valor, con un auditor que no sea Codex o si
coinciden, el despacho muere y se escala: no hay auditor de reserva, ley del lead del 7-nov). El despacho
imprime siempre `AUDITOR: <ejecutable> · topología: <valor>`.

**Preflight de calibración (`tco_pane_calibration_preflight`, llamado por `dispatch.sh` en normal y `--soft`
justo después del de identidad y ANTES del gate de modelo).** Cada pane resuelve su `cli:versión` instalada
(`_tco_pane_cli_version`: la salida COMPLETA de `<agente> --version`, leída en bytes, tiene que ser exactamente una
línea terminada en `\n` que case con la forma cerrada de ese CLI en `references/formas-version.tsv`; la versión es
el `x.y.z` de esa forma, y cualquier otra salida falla cerrado) y esa pareja debe estar en `TCO_PANE_CALIBRATED`.
Si no, el despacho muere sin teclear nada con «CLI <cli:versión> sin calibrar en <pane>: calibra con
f8-capturas.sh + calibrar-pane.sh --registrar (F7)»; si la versión no se resuelve, con su propio mensaje. Un CLI
nuevo puede cambiar el TUI (la 2.1.295 cambió la lista de órdenes de `/model`): la calibración se hace en F7, antes
del primer despacho, con los seis estados `idle`, `modal`, `busy`, `done`, `redraw` y `barra` (`/model` tecleado sin
Enter, con la lista abierta). El analizador acepta las dos formas reales de esa lista (2.1.289 y 2.1.295 en adelante).

## 4. Aislamiento de fallos parciales

[B1/M1/M2] **Un fallo parcial del arranque NO debe matar el dispatch ni orfanar un carril que trabaja
bien** — y "no orfanar" NO significa aceptar entregas sin confirmar. Origen (ráfaga M11): la verificación
solo-por-flanco daba falso negativo si el dev ya estaba busy por el arranque → el dispatch moría con
"no pude entregar el brief" aunque el brief SÍ había llegado, dejando carriles vivos sin coordinador:

- **Brief verificado por CONTENIDO, fail-closed**: se confirma por el **eco del relay**, no por el flanco
  idle→busy ni por pane-busy a secas (podría ser el splash de arranque, sin brief). Sin confirmación →
  el dispatch **FALLA** (escala): el carril **nunca avanza sin el brief del issue**.
- **No matar el dispatch** si el dev queda **demostrablemente trabajando** el issue: carril **vivo** +
  reintentar/reciclar la entrega, **nunca** escalar-y-morir dejándolo huérfano.
- **Rol de auditoría verificado por la RESPUESTA del auditor, fail-closed**: el rol pide responder
  `ROL-AUDITORIA-LISTO` **al final de su línea**; el dispatch confirma esa **respuesta real**
  (`tco_role_ack`, anclado a fin de línea — el eco, con el token a media línea, no falsea). Sin
  confirmación tras reintentos → el dispatch **FALLA**: un auditor sin rol no puede auditar.
- **El escalado deja el carril VIVO** para inspección/re-entrega (nunca marcado como hecho ni corriendo
  sin coordinador). El bug de la ráfaga M11 fue el **falso negativo** de verificación (el ack por
  contenido lo corrige), no que hubiera que avanzar sin brief/rol.

## 5. Higiene de lectura del pane

- **Sugerencia gris (autocomplete) ≠ input encolado — NO confundir**. El composer muestra en **gris
  atenuado** (ANSI `[2m` dim) una **sugerencia de autocompletado** de Claude Code. Un `GO`/`aprobar`/
  `procede` que aparezca en gris es **eso**: una sugerencia, **NO** una orden, **NO** contenido que
  el dev vaya a enviar, y **NO se ejecuta solo** — desaparece en cuanto se escribe (o se acepta con
  `Tab`). **Ante texto gris NO hay que hacer nada**: no "limpiarlo" con `Ctrl-U`, no `Escape`, no
  "neutralizar" el input, y **no es un incidente de seguridad**. El discriminador es el **brillo**,
  y para leerlo con certeza hay que **capturar con los códigos ANSI**: `tmux capture-pane -p -e`
  muestra el prefijo `^[[2m` en el texto atenuado (dim) — ese prefijo ES la marca de que es
  autocomplete. **[P2] Helper `tco_cap_pane_e <carril> <pane> [scrollback]`** (`lib.sh`): captura CON `-e`
  para revelar el ghost-text dim/bright; úsalo SOLO para ese discriminador (el resto de flujos usa
  `tco_cap_pane`). Paso obligatorio ante CUALQUIER texto inesperado en el input: capturar con `-e`
  ANTES de reaccionar; NO sobre-reaccionar al gris. El discriminador por brillo:
  - **Gris/dim** → sugerencia de autocomplete → inofensiva, ignórala.
  - **Texto normal (brillo pleno)** realmente tecleado y **encolado** en el input (p. ej. un
    *"GO sobre `<sha>`"* que el coordinador dejó a medio enviar) → **eso SÍ es real** y puede
    dispararse en el momento equivocado → **escalar sin enviar ni borrar**, conservando el input
    para inspección (§4 arriba). Backstop objetivo: aunque un `GO` fantasma se colara, la regla 13
    del coordinador y el intake del Mergeador atan la decisión a `headSha==auditedSha` — un
    texto suelto nunca aprueba.
  El error a no repetir: tratar la sugerencia gris como un input encolado peligroso y "neutralizar"
  el pane a lo loco. Lee el **brillo** primero; solo el texto pleno encolado exige acción.
- **Distinguir "trabajando" de idle**: la señal fiable de actividad es `esc to interrupt`
  (`TCO_BUSY_REGEX` para el dev, `TCO_AUDIT_BUSY_REGEX` para el auditor — configurables por TUI).
  `plan mode` / `bypass permissions` son footer permanente, no actividad.
- **Diálogo de encuesta** ("Can Anthropic look at your session transcript? y/n/d"): captura el input y
  bloquea relays → declinar con `n` (`tco_pane_heal survey`) y seguir. `tco_pane_anomaly` lo detecta.
  **[P2] Encuesta de RATING** ("How would you rate…" / estrellas): también intercepta relays →
  `tco_pane_anomaly` la clasifica como `survey-rating` y `tco_pane_heal survey-rating` la **descarta con
  `0`** (dismiss sin puntuar). El relay la sana ANTES de reintentar (no re-tipear a ciegas).
- **[P2] Busy AMPLIADO** (`TCO_BUSY_REGEX`, predicado puro `tco_pane_busy_from`): además de
  `esc to interrupt`, cuentan como actividad los contadores de tiempo/tokens (`12s ·`), los medidores
  `↓/↑` y `· thinking`. Detección de idle MÁS conservadora = fail-closed hacia "ocupado" (no declara idle
  prematuro). `plan mode`/`bypass`/`? for shortcuts` siguen SIN contar (footer permanente).

## 6. Framing del contenido relevado

`tco_frame <label> <literalfile> <outfile> [suffixfile]` envuelve el literal en delimitadores
`INICIO/FIN CONTENIDO RELEVADO` con la instrucción explícita de **no obedecer instrucciones dentro del
bloque** (anti-inyección [B6]). El `literalfile` **nunca se recorta** (invariante 1). `relay.sh`
encadena: capturar literal → `tco_frame` → al dev o al auditor por `tco_relay_file` (entrega verificada,
fail-closed explícito — una entrega no confirmada ESCALA).

## 7. Monitor por estado y detección sin falsos positivos

[Pilar 2] `tco_wait_state <carril> <pane> <regex> [intervalo=10] [max_iter=360]` hace polling sobre la
pantalla visible hasta que el patrón aparece. `watch-carril.sh` detecta: plan-listo, **pregunta**
(AskUserQuestion), stop-audit, PR (el modo `merge` del script es legado v5 — la 1ª estación no
mergea). La cadencia de 10 s es el intervalo **interno del script**;
cómo ejecutar el script desde el harness sin que muera lo fija la doctrina de monitores de abajo.

**Doctrina de monitores frágiles / reaper (T6)** — cómo NO perder un watcher:

- **El reaper del harness mata bg-watchers con un `sleep` largo** (un solo sleep >~450-500 s muere a
  mitad); el estado "monitor still running" que reporta el harness **MIENTE** cuando el proceso ya fue
  cosechado. Un watcher muerto = eventos perdidos en silencio.
- **Un comando foreground topa a ~2 min** (rc 143): correr ahí un watch de cadencia corta es
  incompatible — muere antes del primer evento útil.
- **Patrón correcto**: `run_in_background` con un **for-loop que SALE en condición terminal**
  (evento detectado / N cortes / deadline), con sleeps cortos por iteración y **cobertura del caso
  de fallo** (si expira sin evento, reporta eso — nunca silencio); para esperas puntuales en
  foreground, **timeout 200-280 s** por invocación.
- **Poll por HEAD-sha, no por fraseo**: el disparador objetivo es `git rev-parse HEAD` ≠ último
  auditado (commit real), nunca un grep de frases del scrollback — el fraseo false-positivea con
  scrollback viejo y con ruido tipo **"Auto-update failed"** (filtrarlo siempre; es ruido de la
  status-bar, no un evento).
- **Monitor persistente de 3 estados** al barrer canales: (1) **finisher** (terminó su encargo) →
  encolar el siguiente paso; (2) **idle-relayado** (idle con relay pendiente de consumir) → nudge;
  (3) **idle-auditándose** (su gate de auditoría está corriendo) → **NO tocar** (un nudge aquí
  contamina el gate — gotcha `continuemos`-consumido-como-GO, ref 09 §3).
- **[Anti-menú] Detectar menú abierto en el monitor**: un canal que presenta ExitPlanMode
  (`Would you like to proceed?`) o AskUserQuestion (`Enter to select`) se ve en el monitor
  como *aparentemente idle* pero con UI bloqueante — clasificarlo como `pendiente-decisión` (§9),
  NO como "idle para relay". Enviar un relay a un pane en menú puede elegir una opción en silencio.
  El predicado: buscar las frases `Would you like to proceed?` o `Enter to select` en la captura
  del pane ANTES de cualquier send-keys.

- **[TAL-3619] stop-audit real = CONTRATO INFORME-POR-FICHERO, el pane es solo señal**: con pantalla
  alternativa, `capture-pane` devuelve como MÁXIMO el viewport (~50-60 líneas) sea cual sea el
  `-S -N` pedido — un informe largo pierde su propio header antes de que el pane quede idle
  (ch01/ch02/ch05 estuvieron ~9h con code-gates pendientes sin detección por esto). El dev escribe
  el informe COMPLETO con su herramienta Write a `~/stop-audit-report.txt` (nunca heredoc/redirect
  bash) y solo IMPRIME el header en el pane como señal. `relay.sh extract-stop-audit <carril>
  <outfile>` prueba **fichero primero** (`tco_read_stop_audit_file`: existe + mtime dentro de
  `TCO_STOP_AUDIT_MAX_AGE` (guarda secundaria) + ancla literal STOP-AUDIT + **correlación de
  ronda** — el informe declara `· SHA auditado: <sha>` y debe ser EXACTAMENTE el HEAD vigente del
  clon, vía el seam `_tco_carril_git rev-parse HEAD` — y **rotación atómica** del fichero como
  condición NECESARIA del éxito, nunca un "después" best-effort: si el `mv` falla, no hay "extraído
  con éxito" reutilizable) y cae al **pane como fallback** solo si el fichero no resuelve
  (`tco_extract_stop_audit`: ancla en la línea que EMPIEZA por STOP-AUDIT o el header `informe
  pre-push`; la frase del dev "Estoy en el punto correcto de STOP-AUDIT" NO ancla; con varios
  informes gana el ÚLTIMO). **El corte YA NO es el primer separador de guiones** (`─{5,}`) — es
  producible por el CONTENIDO del dev y de hecho la propia plantilla del despacho lo manda bajo el
  header (causa exacta del informe de ch47 truncado a 1 línea): el corte pasa a ancla ESTRUCTURAL
  (borde del composer `╭`/`╰` o línea de hints del footer), chrome que la salida normal no
  reproduce. Una sola invocación, sin pipes en el host (PROC-01).
- **AskUserQuestion**: si el dev abre un menú (`Enter to select`), enrutar por **tipo de decisión** (§9);
  el carril **no se cuelga ni se mata** — queda vivo con un `pendiente-decisión` (M4).
- **ExitPlanMode**: GO/NO-GO por opción + **verificación del cursor `❯`** (§8). Si el dev imprimió el
  plan como texto sin presentarlo, `wait_plan_ready` hace un **nudge** único hacia ExitPlanMode.
- **Detección de la ENTREGA (PR) por `closes TAL-N` / `head_sha`, NUNCA por nombre de rama**: un dev
  puede renombrar su rama al entregar (visto: la rama cambió de nombre en la entrega) → un monitor
  keyed al nombre viejo da timeout falso. `watch-carril.sh pr` y el cierre buscan el PR por el
  `closes TAL-N` en el body (o por `head_sha`), estables frente al rename (ref 02 §4/§6).
- **Canal en un menú / esperando su gate = latencia de ADJUDICACIÓN del coordinador, no transición
  del canal**: cuando el dev presenta un plan (ExitPlanMode) o abre un AskUserQuestion, el reloj corre
  contra el COORDINADOR (que debe gatear o adjudicar), no contra el canal — el canal está SANO
  esperando respuesta. No contabilizar ese estado como atasco del canal ni reciclarlo: el SLA de esa
  espera pertenece al puesto de mando. **Cuantificado: SLA de menú = 1 pasada del barrido (~5 min)**
  — un `ExitPlanMode` (o cualquier menú del CLI) capturado en la pasada N no debe envejecer más de
  esa pasada sin **gate lanzado o adjudicación**; se le lanza el `audit-gate.sh` del plan o se
  adjudica el GO/NO-GO en esa misma pasada, no en la siguiente (doctrina de barrido persistente,
  `04` §Barrido persistente y cosecha-en-el-mismo-turno). Un plan que lleva > 1 pasada esperando sin
  gate ni adjudicación es tiempo muerto del canal (invariante 12, SKILL.md).
- **El estado del monitor se DERIVA del PROBE, nunca del último estado conocido.** Cada pasada
  re-deriva el estado real del canal de una sonda fresca del pane —**cred no-blanca + presencia de
  menú/diálogo + turno activo**—, NO del label que el coordinador le puso la pasada anterior. Caso
  real: un canal quedó etiquetado "esperando cred" (estado viejo) mientras en realidad **esperaba en
  un `ExitPlanMode`** listo para gatear → tiempo muerto hasta que alguien re-sondeó. Un estado
  cacheado es una hipótesis, no un hecho: si el probe dice menú-arriba, el canal necesita gate, aunque
  el label diga otra cosa.
- **El aviso «ESCALAR: sin eco del relay» de `dispatch.sh` es un falso negativo frecuente**: salta
  cuando el eco del comando no vuelve, pero el canal PUEDE ya estar procesando el issue. Antes de
  re-despachar, confirmar que el issue arrancó de verdad buscando su `TAL-N` en el pane; re-despachar
  guiado por el eco ausente DUPLICA el encargo (visto: dos canales ya planificando pese al aviso).

`tco_carril_libre <carril>` heurística de carril ocioso (ambos panes, fail-closed). `tco_recycle_carril
<carril>` mata sesión + procesos de agente + relay, **dentro del contenedor** del carril (Pilar 7); el
modo `--soft` y la gestión de modelo viven en `references/11-modelo-effort-y-recycle.md`.

## 8. Gate de plan en ExitPlanMode

El plan se aprueba/rechaza desde el **diálogo de ExitPlanMode** del pane `.0`. Mecánica de tecleo
(lección dura: una opción se seleccionó **antes de tiempo** y hubo que corregir por archivo):

- **Verificar la posición del cursor `❯` ANTES de seleccionar**: capturar el pane, confirmar en qué línea
  está el `❯`, y **solo entonces** enviar la tecla. Nunca seleccionar a ciegas.
- **NO-GO** → opción 4 (*seguir planificando / pedir cambios*) siguiendo **PROC-17**: confirmar,
  **verificar `plan mode on`**, y solo entonces relevar el feedback literal por archivo. Esto mantiene al
  dev en plan mode revisando (NO aprueba) y vuelve a iterar.
- **GO** → **opción 1** (aprobar) + relevar el **literal del GO** (sugerencias no bloqueantes) por archivo
  tras aprobar — el literal de la auditoría llega SIEMPRE al dev, también en GO (invariante 1). El diálogo
  de aprobación **IGNORA texto tipeado**: fijar el modelo con **`model="$(tco_model_for_phase coding "$carril")" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1`** (picker interactivo — `/model` **SIN** argumento inline, que es un NO-OP
  silencioso sin diálogo que confirmar) → verificar con `tco_verify_model_effect` → `/effort high` —
  DOS diálogos modales INDEPENDIENTES, cada uno con su propia confirmación, INMEDIATAMENTE DESPUÉS de
  aprobar (el switch interrumpe antes del primer token); el relay de sugerencias encolado
  (`relay.sh audit2dev-queue`) hace de nudge. **Trampas concretas de la coreografía sobre este diálogo
  modal** (aprobar → Escape → `tco_set_model` picker → UN `1` (solo si aparece el diálogo) →
  verificar modelo activo (picker o `tco_verify_model_effect`) → `/effort high` → UN
  `1` → verificar por la línea "Set effort level to high" → relevar GO): detalle en
  `references/11-modelo-effort-y-recycle.md` §6. **Fallback 5ª ronda**: misma coreografía con
  `model="$(tco_model_for_phase fallback)" && [ -n "$model" ] && tco_set_model "$carril" "$pane" "$model" || exit 1` (picker, nunca `/model` con argumento inline a mano)
  sobre el fix en curso (ref 11 §5).

## 9. Enrutado de AskUserQuestion del dev

Cuando el dev abre un `AskUserQuestion` (`Enter to select`), el coordinador **enruta por tipo de
decisión** (no responde todo igual), **una pregunta por turno** (en Academia Ejemplo: regla 22 del CLAUDE.md):

| Tipo de decisión | Ejemplos | Quién decide |
|---|---|---|
| **Diseño** (interno, técnico) | granularidad de un enum, mecanismo de supresión de un oráculo, mecanismo de un guard de CI | **Coordinador**, con el **recomendado del dev** (o "decide tú con criterio") |
| **Scope / Política / Disposición de datos** | cambio de schema del backend, migración de datos, composición del batch, ADR-only vs código | **ESCALAR al lead** (una pregunta por turno) |

**No confundir los DOS menús del dev en plan mode — disparan flujos DISTINTOS**: un `AskUserQuestion`
(`Enter to select`) se **enruta por tipo de decisión** (tabla de arriba) — **diseño** lo adjudica el
coordinador inline, pero **scope / política / disposición de datos se ESCALA al LEAD** (el coordinador
NO adjudica scope); un `ExitPlanMode` (`Would you like to proceed?`) es un **plan-GATE** que EXIGE
relevar el plan al auditor (§8) antes de aprobar. Tratar un ExitPlanMode como si fuera un
AskUserQuestion —resolverlo sin auditor— rompe el loop adversarial; tratar un AskUserQuestion como
plan-gate gasta un gate donde no toca. La forma del prompt los distingue sin ambigüedad.

El carril **no se mata** ante el menú: queda **vivo** con un archivo `pendiente-decisión` que el
coordinador resuelve e **inyecta** en el pane (coordinador-en-el-loop, M4); jamás escalar-y-morir
dejándolo colgado.

## 10. Auto-nudge de relays de acción

Todo relay que pide una **ACCIÓN** al dev (commitea, corre `draft-handoff.sh`, publica la rama,
re-emite el HANDOFF) debe
**terminar en un imperativo explícito** y luego **verificar el efecto** observable (commit nuevo /
PR draft creado / HANDOFF posteado) — no asumir que el dev lo hizo. Si el efecto no ocurre (el dev
leyó el fichero-relay y quedó **idle**), **re-nudge** (`tco_nudge_until`). Lección de la ráfaga M11:
los pasos de ENTREGA siempre necesitaron nudge. (Mergear o aplicar post-merge en prod NUNCA son
acciones relevables a un dev de producción — ADR-0043: la 1ª estación no mergea.)

## 11. Bypass, effort y modelo

- **Bypass desde el arranque**: lanzar el CLI con `TCO_DEV_FLAGS` (`--dangerously-skip-permissions`),
  **no** activar shift+tab a mano. El bypass está confinado al **contenedor unprivileged** (sandbox),
  nunca en el host [B7].
- **Plan mode**: shift+tab al inicio de Fase A (requiere `extended-keys on` en tmux, provisto por
  `talent-channels`).
- **Effort [Regla 0] — lo gestiona el COORDINADOR en cada transición de modo** (los agentes NO lo cambian
  solos); **`/effort max` PROHIBIDO**. Plan/dispatch → **`/effort xhigh`** (`dispatch.sh`); con el GO de
  plan, **`/effort high` inmediatamente tras aprobar, DESPUÉS de conmutar el modelo** (§8); NO-GO→re-plan
  → **`/effort xhigh`**. El resume de la sesión baja el effort → **re-fijar al nivel del modo**; nunca max
  (invariante 6). El CLI mínimo probado (2.1.289) aplica el esfuerzo sin diálogo. Si aparece una
  confirmación, su afirmativa debe nombrar el nivel pedido; «Yes» genérico es incompatible
  (rc 2 sin pulsarlo, con título visible y mínima exigida). Centralizado en `tco_set_effort` (`lib.sh`), **tri-estado** [v5]: rc 0 confirmado ·
  rc 1 el envío falló (fatal) · rc 2 enviado SIN confirmación visual dentro de `TCO_EFFORT_CONFIRM_MAX`
  (24s) → el caller hace verificación **DIFERIDA** (`tco_effort_confirmed_from` tras
  `TCO_EFFORT_DEFER_WAIT`) y ahí decide — mata el falso negativo 3/3 bajo carga sin ablandar el
  fail-closed.
- **Modelo [Regla 0 ampliada — modelo-por-fase, TAL-2675]**: la cuenta puede AGOTAR un modelo (un panel
  en el modelo agotado no avanza). Verificar/forzar el modelo capaz antes de despachar y tras cada
  recycle/resume (`tco_ensure_model` / `tco_set_model`). **El modelo YA NO es un valor único verificado**:
  arranca en **Opus vigente** para el plan y el coordinador lo conmuta a **Sonnet** para el coding en el GO
  (§8, diálogo INDEPENDIENTE del de effort), con **fallback a Opus vigente** si el code-gate no converge en 5
  rondas sobre el mismo fix. Doctrina completa (tabla, coreografía, contrato de rondas) en
  `references/11-modelo-effort-y-recycle.md`.

## 12. Procedimientos

### PROC-00 — Arranque en frío

Primer despliegue de una flota nueva (o coordinador en máquina recién aprovisionada):

1. **Re-login para activar el grupo `incus-admin`**: hasta re-login tras el provisioning, `incus` falla
   en la sesión del coordinador. Workaround estable: `sudo` (00-config resuelve `SUDO_USER`).
2. **`agents.conf` no existe hasta que el coordinador lo crea**
   (`~/.config/talent-channel-operation/agents.conf`, `0600`). Mínimo: `TCO_DEV_CLI/FLAGS`
   (`*_CLI` = UN solo ejecutable; los flags, en `*_FLAGS`), `TCO_AUDIT_CLI/FLAGS`, `TCO_DEV_MODEL_ARGS`/`TCO_AUDIT_MODEL_ARGS` (`--model …` — el lanzador del
   contenedor NO lo pasa), **`TCO_DEV_CARRILES` de ESTA máquina** (el default no aplica a flotas 2X/3X),
   `TCO_MAX_ACTIVE`, **`TCO_HOST_ENV`**, `TCO_AGENT_PROC_PAT="claude|codex"` (ERE anclada sobre el nombre del
   ejecutable, no sobre la línea de comandos — ref 11 §3). El auditor es SIEMPRE Codex (`TCO_AUDIT_CLI` Codex) y la
   topología es `distinto`: un auditor del mismo agente que el dev, o que no sea Codex, detiene el despacho.
   - **Cada TORRE copia scripts/config del skill a su ruta PRIVADA y despacha desde ahí.** El
     `agents.conf` (y los scripts que el coordinador ejecuta) viven en la ruta privada de la torre
     (`$SECRET_DIR/agents.conf`, gitignored, `0600`) — **la copia del repo es SOLO LECTURA**,
     plantilla de la que se parte, nunca el fichero que se edita ni desde el que se despacha.
     Incidente real: **dos torres se pisaron el `agents.conf` en el mismo working dir** (dos torres
     editando el mismo fichero del checkout compartido) → `TCO_DEV_CARRILES`/modelo cruzados →
     **dispatches intermitentemente rotos**. Regla: config y scripts operativos en `$SECRET_DIR` por
     torre; el checkout del repo no se muta para operar.
3. **`incus file push` NO sobrescribe** destinos existentes ("permission denied"): el patrón viejo de
   `mktemp` REMOTO pre-creaba el destino y **toda entrega moría en silencio**. La vía vigente
   (`tco_relay_file`) usa nombre aleatorio del host SIN pre-crear — no reintroducir pre-creación.
4. **Smoke de entrega end-to-end ANTES del primer dispatch real**: probe corto (texto → respuesta del
   pane) a **ambos panes** de un carril. Si el smoke no responde, no despachar nada.
5. **`--force-reset` consciente en el primer dispatch**: la sesión idle post-login muestra "bypass
   permissions" y `tco_carril_libre` la ve OCUPADA → verificar que no hay trabajo real y despachar con
   `--force-reset`. **[TAL-2276]** `--force-reset` además **resetea el git del carril a `origin/main`
   automáticamente** (pre-preflight, ejecutado por `preflight-issue.sh` SOLO tras su gate BD-sync en
   verde) — ya **no** hace falta el reset manual (`checkout main + reset --hard + clean -fd`) cuando el
   carril arrastra WIP/rama del issue previo. No aplica en `--soft` (conserva el guard `tco_wait_idle`).
6. **Toolchain**: `verify.sh` de `talent-channels` = PASS total antes de dar la flota por operativa
   (los CLIs npm globales pueden faltar en el golden).

**Sembrar la sesión tmux ANTES del primer dispatch (el dispatch es fail-closed sin sesión)**: si el
coordinador aún no ha creado la sesión (`v` + el split de los 2 panes dev/audit por canal), el primer
`dispatch.sh` rechaza el encargo como «OCUPADO» —no hay dónde teclear— y el canal queda sin arrancar
(visto: 8 canales rechazados en frío por sesión inexistente). El bootstrap del arranque en frío crea
la sesión y sus panes ANTES de despachar nada; recién entonces corre el smoke del paso 4.

### PROC-01 — Relay bajo el hook del host

El host tiene un hook PreToolUse que **bloquea comandos del coordinador que contengan los tokens
git+push en CUALQUIER compound** — INCLUSO cuando "push" solo aparece en una **RUTA** (verificado en
vivo: un comando de solo lectura con la ruta `.githooks/pre-push` fue bloqueado). Doctrina:

1. **Archivos de relevo escritos con la herramienta de archivos del coordinador (Write)** — JAMÁS con
   heredoc/redirect bash.
2. **Ningún archivo de relevo con "push" en el NOMBRE.**
3. **Fraseo sin literales**: "sube la rama de forma atómica", "publica" — nunca el literal
   (`tco_send_dev` avisa si lo detecta en el texto del relay).
4. **Una invocación = un send** (sin `;`, `|`, `(` en el comando del host). Por eso existe
   `relay.sh extract-stop-audit`: una sola invocación, sin componer capturas con pipes en el host.
5. El **contenido** viaja por `incus file push` — no dispara el hook (el hook solo inspecciona la línea
   de comandos del coordinador).
6. **`git push` real del coordinador** (operativo, p. ej. una rama del propio skill): comando ATÓMICO
   standalone, nunca dentro de un compound.

### PROC-02 — Rebuild de pane de auditor muerto

El pane del auditor puede MORIR (incidente real: codex murió en los 3 carriles a la vez — no fue su
usage limit — y los gates quedaron enviando al vacío hasta el timeout):

1. **Detección**: el sweep del coordinador incluye `tmux list-panes` — un carril con un solo pane es
   incidente. `audit-gate.sh` hace **fail-fast** si el pane del auditor no existe.
2. **Rebuild**: `split-window -c ~/<repo>` → lanzar el CLI de auditoría (`TCO_AUDIT_CLI` +
   `TCO_AUDIT_FLAGS` + `TCO_AUDIT_MODEL_ARGS`) → `tco_wait_tui_ready` → **rol vía `tco_relay_file`**
   (sin paste) → esperar la **respuesta** `ROL-AUDITORIA-LISTO` (`tco_role_ack`, anclada a fin de
   línea — el eco no falsea).
   - **Prompt "Update available!" del CLI del auditor**: al arrancar, el auto-update del CLI (codex)
     abre un prompt que **bloquea el priming del rol** (síntoma: "CLI auditoría no LISTO 90s"). Skip
     con la **opción 2** y recargar el rol a mano. Fix de raíz: deshabilitar el auto-update en el
     golden (`talent-channels`) — hasta entonces, contar con el Skip manual en cada rebuild/arranque.
3. Solo con el rol confirmado se re-lanza el gate. Un auditor sin rol no puede auditar (§4).
4. **Variante "parado sin morir" (Trusted-Access / "model at capacity")**: el pane del auditor
   sigue vivo pero no emite veredicto (diálogo pendiente o capacidad del modelo). Umbral: gate
   **>20 min sin veredicto** → inspeccionar el pane `.1`, resolver el diálogo o matar el gate y
   re-lanzarlo; artefactos grandes **>11 min** sin cosecha → `--parse-only` (PROC-03 en `04`).

### PROC-11 — Limpiar cola duplicada del composer

Un relay con reintento puede **DUPLICAR** el mensaje en la cola del composer ("Press up to edit queued
messages"). `tco_pane_anomaly` lo detecta (`queued-dup`) y los reintentos de `tco_relay_file` **NO
re-alimentan** una cola duplicada (rc 3 — el reintento ciego es precisamente lo que duplica):

1. **Verificar** con `Up` qué quedó encolado (revisar, no adivinar).
2. **Limpiar** con `Escape` + `C-a` + `C-k` + `C-u`.
3. **Triage por contenido**: un relay informativo duplicado es **benigno** (idempotente); una
   **orden de publicación/entrega duplicada NUNCA se deja** en la cola.

### PROC-17 — NO-GO de plan sin perder plan mode

Enviar la **opción 4** del diálogo de plan tras un NO-GO puede **SACAR al dev de plan mode** (el dev
consume el siguiente relay como texto/luz verde e implementa sin plan aprobado — incidente real: 5
archivos tocados). Además `send-keys "4"` solo MUEVE el selector: hace falta el submit.

1. Confirmar la opción 4 (`4` + submit).
2. **VERIFICAR `plan mode on`** en la captura. Si se perdió: `Escape` → confirmar **working tree
   limpio** en el carril (`git status`) → `BTab` (shift+tab) hasta recuperar plan mode — **ANTES de
   relevar el veredicto**.
3. Relevar el literal del NO-GO (`relay.sh audit2dev`) + re-fijar `/effort xhigh`.
4. Verificar tras el relay que sigue `plan mode on` y que el dev NO está editando (git limpio).

Si el dev llegó a codear sin GO: interrumpir (`Escape`), ordenar descartar
(`git reset --hard && git clean -fd`), re-entrar a plan mode verificado y pedir re-presentación del
plan. **El diff no auditado NUNCA avanza.**

## 13. Relay robusto v2 + carril PARKED + impasses [P2/TAL-2295]

**Enter separado real** (`_tco_send_text_submit`): el TEXTO y el SUBMIT (`Enter`/`C-m`) se envían en
invocaciones `incus`/`send-keys` **SEPARADAS**, con un `sleep TCO_RELAY_SUBMIT_GAP` (2 s) en medio — en
un TUI ocupado el `Enter` en la MISMA llamada se **pierde** (gotcha `tmux send-keys`). `tco_relay_file` y
`tco_send_dev` usan esta vía; el texto viaja como posicional (sin interpolación, anti-inyección).

**Dedupe anti-duplicado del relay** (`tco_input_pending_from`): al reintentar un `lee <ruta>`, si el eco
YA está en el composer (RELAY-QUEUED) NO se re-tipea (re-tipear a ciegas es lo que DUPLICA la cola). El
reintento sana las encuestas con detección actual; una cola duplicada se escala. Si el eco sigue
pendiente o es ambiguo, devuelve rc 2 **sin re-submit, limpieza ni re-tipeo**.
`tco_input_pending_from` distingue eco-pendiente (idle) de consumido (busy).

**Carril PARKED** (`tco_carril_parked`): un carril está parqueado cuando NO-busy **+** hay un **informe
REAL** de hand-back (`tco_parked_report_from`: "a la espera de feedback", "esperando tu decisión",
`PARKED`, "Awaiting your review"; `TCO_PARKED_REGEX`) **+ DEBOUNCE ×2** (persiste tras
`TCO_PARKED_DEBOUNCE_S`, 60 s). Un `esperando` suelto sin keyword NO es parked (evita falso positivo). Un
pane que quedó idle SIN informe no es parked: es un relay perdido (re-nudge), no un hand-back.
`tco_commits_ahead <carril>` (commits de HEAD por delante de `origin/main`) es señal de trabajo nuevo sin
entregar → candidato a **re-audit**.

**AskUserQuestion JAMÁS dentro del canal**: un agente de canal que abre `AskUserQuestion` **cuelga su
pane** esperando a un humano que no está mirando ese pane. El dev NO debe usarlo: si necesita una
decisión, **PARKEA** con un informe (el coordinador lo detecta con `tco_carril_parked` y enruta la
decisión por §9 — diseño al coordinador, scope/política al lead, **una pregunta por turno**). El
coordinador tampoco emite `AskUserQuestion` hacia un canal.

**Shell fantasma**: si el dev escribe la SINTAXIS de una tool-call como TEXTO (sin invocar la Bash real)
o queda con "1 shell fantasma" (`pgrep` vacío pero el TUI cuelga), no se mergea ni se avanza: se le
ordena "usa REALMENTE la herramienta Bash" y, si sigue colgado, **restart fresco + re-brief** (el
fantasma no se desatasca con nudges).

**Impasse → Orquestador**: un impasse real del encargo (circuit-breaker de NO-GO repetido, PROC-16;
defecto de diseño; scope que se disparó) se **escala al Orquestador** con el historial de rondas + el
root-cause que el dev articula al parquear — NO se itera indefinidamente ni se decide arquitectura en el
canal (regla 7).

**Verificar el ACK del rol por el marcador de RESPUESTA, no por el eco del `lee`**: al primar el rol
de un auditor, el "listo" que confirma que el rol quedó cargado es el **bullet de RESPUESTA que emite
el propio agente** (p. ej. `• ROL-AUDITORIA-LISTO`), no el eco del comando `lee <ruta>` en el
scrollback. El eco del `lee` es un falso positivo: aparece con el pane todavía en `bash` sin haber
procesado nada. Anclar el ACK al bullet de respuesta del agente, nunca al texto que se le tecleó.

## 14. Flota remota (ssh + incus) — GAP no soportado

Los scripts empaquetados del skill **asumen `incus` LOCAL** (mismo host que el coordinador). Cuando
los canales viven en **otro host**, esos scripts NO sirven tal cual y hoy la operación es **manual**:
`ssh <host>` + `incus exec <canal> …` para cada acción (dispatch, relay, gate, recycle). Es una
**limitación conocida**, no una feature: no existe hoy un modo remoto de primera clase. Un eventual
prefijo/env tipo `TCO_INCUS_SSH` en `lib.sh` que antepusiera el `ssh` a cada invocación de `incus`
sería el diseño natural para soportarlo, pero **NO está implementado** — mencionarlo como propuesta,
nunca operar como si existiera. Mientras tanto, quien opera una flota remota lo hace a mano y lo
declara así en su reporte.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
# Preparación antes del primer despacho

El montaje usa `scripts/preparar-sesiones.sh --plan CARRIL`, muestra el plan y
espera aprobación; después `--ejecutar CARRIL` crea solo una sesión ausente con
dev y auditor. `--verificar CARRIL` acredita sus binarios reales mediante las
funciones de dispatch/lib. Una sesión existente incompleta o con identidad
incorrecta queda roja y se conserva. No despacha una issue ni recicla panes.
Debe hacerse en F5 antes del doctor de F7. El usuario C1 necesita el mismo grupo
Incus del operador, que permite administrar los contenedores de la máquina.
El plan declara la aceptación de confianza para el directorio del repositorio
y del modo sin permisos. Tras aprobarlo, fusiona la línea base privada con jq
antes de arrancar agentes, conservando claves existentes y modo 0600.
La verificación rechaza un panel parado en un diálogo, aunque su binario sea correcto.
