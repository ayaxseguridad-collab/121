#!/usr/bin/env bash
# selftest-relay.sh — Verificación empírica de relay.sh + idle-check.sh SIN canales reales.
#
# Levanta una sesión tmux AISLADA (socket -L propio, jamás la sesión 'v'/'torre-*' de trabajo) con un
# fake-TUI que RENDERIZA el chrome CORNER (caja del composer + footer) y redibuja por tecla; así el caso
# de acuse OK atraviesa el parser estructural real (no un simple `read`). Cubre 8 grupos:
#   1 acuse OK · 2 sin acuse · 3 menú · 4 texto especial intacto · 5 ENCOLADO · 6 NO-READY ·
#   7 idle-check --classify (fixtures realistas separados) · 8 fronteras de los contratos de shell.
#
# Salida: 'RESULTADO: N PASS / M FAIL'; rc 0 solo si M=0. Requiere tmux.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY="$HERE/relay.sh"
IDLE="$HERE/idle-check.sh"

command -v tmux >/dev/null 2>&1 || { echo "selftest: falta tmux (requerido)"; exit 2; }

WORK="$(mktemp -d)"
STUB="$WORK/fake-tui.sh"
REC="$WORK/recibido.txt"
SOCK_N=0            # contador: cada start_stub usa un socket -L PROPIO (nunca reciclado)
SOCKS_USED=()        # registro para limpieza al salir
# kill-server + new-session inmediatos sobre el MISMO socket tienen una carrera real de tmux
# (el server nuevo puede morir al arrancar, "server exited unexpectedly") — socket único por
# invocación la elimina de raíz, en vez de intentar sincronizar contra el server saliente.

cleanup() {
  local s
  for s in "${SOCKS_USED[@]:-}"; do
    if [ -n "$s" ]; then tmux -L "$s" kill-server >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Entorno rápido y aislado para el selftest (no toca los defaults de producción). TC_MICRO_N se mantiene
# en el PISO del contrato (N>=3, TC_MICRO_N_MIN) — bajarlo desvirtuaría el propio muestreo que se prueba.
export TC_MICRO_N=3 TC_MICRO_GAP=1 TC_ACUSE_TIMEOUT=8 TC_SUBMIT_GAP=1 TC_STATUS_TAIL=8 TC_WAIT_READY=0

pass=0; fail=0; rcs=""
ck() { # <nombre> <rc_esperado> <rc_real>
  rcs="$rcs $3"
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'PASS  %-28s rc=%s\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL  %-28s rc=%s (esperado %s)\n' "$1" "$3" "$2"; fi
}
ck_true() { # <nombre> <cond-rc>
  rcs="$rcs $2"
  if [ "$2" = 0 ]; then pass=$((pass+1)); printf 'PASS  %-28s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %-28s\n' "$1"; fi
}

# --- fake-TUI ---
# El composer CORNER se renderiza SIEMPRE (idle y busy) — un TUI real no hace desaparecer la caja al
# trabajar; el auditor señaló que ocultarla en busy() dejaba el caso 1 pasar por "sin CORNER = vacío" en
# vez de por la transición estructural real. MODE=corrupt simula un envío alterado/truncado: el composer
# muestra un texto DISTINTO al tecleado, para probar que el check pre-submit exige el LITERAL exacto.
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
MODE="${MODE:-normal}"; REC="${REC:-/dev/null}"; buf=""; e=$'\033'
cls(){ printf '%s[H%s[2J' "$e" "$e"; }
composer(){ printf '╭──────────────────────────────╮\n'; printf '│ ❯ %s\n' "$1"; printf '╰──────────────────────────────╯\n'; printf '  ? for shortcuts   shift+tab\n'; }
# corrupt: el composer NUNCA refleja lo tecleado (simula un envío truncado/alterado en tránsito) — el
# pre-submit check debe exigir el LITERAL exacto y rechazar ANTES de someter, no "algún texto presente".
shown(){ if [ "$MODE" = corrupt ] && [ -n "$buf" ]; then printf 'OTRA COSA (no lo tecleado)'; else printf '%s' "$buf"; fi; }
box(){ cls; printf 'transcripcion linea 1\ntranscripcion linea 2\n'; composer "$(shown)"; }
# Layout REAL observado en producción (TAL-5141, pasada r15 — cierra el requisito (d) del BLOQUEANTE
# de la pasada fresca: "fake-TUI end-to-end que atraviese el frame real y produzca relay rc0"): el
# indicador de actividad es el frame de DOS LÍNEAS capturado en campo — "✶ Sock-hopping…" (sin contador,
# sin paréntesis) seguida de su línea de pie "⎿ Tip: …" — no el formato antiguo de una sola línea con
# contador. Al usarse en el flujo normal de acuse (tests 1/4/4b/4c más abajo), TODOS ejercitan ahora el
# frame real de punta a punta, no una aproximación.
busy(){ cls; printf 'transcripcion linea 1\n'; printf '\xe2\x9c\xb6 Sock-hopping\xe2\x80\xa6\n'; printf '\xe2\x8e\xbf Tip: Control this session from the mobile app \xc2\xb7 run /remote-control\n'; composer ""; }
menu(){ cls; printf 'Would you like to proceed?\n❯ 1. Yes\n  2. No\n'; }
queued(){ cls; printf 'transcripcion\n'; composer "$(shown)"; printf 'Press up to edit queued messages\n'; }
# blank: pantalla SIN ningún composer reconocible (ni esquinas, ni regla plana, ni cursor) — simula el
# caso "no localicé el ancla" end-to-end, para probar que relay.sh se traduce a NO-MEDIDO/rc2 y CERO
# send-keys, no un rc6/NOT-READY (MAYOR de la pasada fresca r14: faltaba esta traducción real).
blank(){ cls; printf 'pantalla sin composer reconocible, texto de relleno cualquiera\n'; }
case "$MODE" in
  busy)        busy;   while :; do sleep 5; done ;;
  menu)        menu;   while :; do sleep 5; done ;;
  blank)       blank;  while :; do sleep 5; done ;;
  # preencolado: cola YA presente ANTES de que relay intente teclear (distinto del grupo 5, que encola
  # DESPUÉS de mi propio submit) — ejercita la rama de PRECONDICIÓN (relay.sh: ic_relay_ready falla,
  # NO teclea), no la del bucle de acuse. El predicado ic_queue_pending es el MISMO en ambas ramas y
  # debe dar el MISMO rc en las dos (bounce de M3 sobre #2156: daba 6 aquí y 5 en la otra rama).
  preencolado) queued; while :; do sleep 5; done ;;
esac
stty raw -echo 2>/dev/null || true
box
while IFS= read -rN1 ch; do
  case "$ch" in
    $'\r'|$'\n')
      case "$MODE" in
        encolado) queued; sleep 3; box ;;
        noacuse)  buf=""; box ;;
        *)        printf '%s\n' "$buf" >> "$REC"; buf=""; busy; sleep 3; box ;;
      esac ;;
    *) buf="$buf$ch"; box ;;
  esac
done
STUBEOF
chmod +x "$STUB"

start_stub() { # <mode>
  SOCK_N=$((SOCK_N+1))
  SOCK="relay-selftest-$$-${SOCK_N}"
  SOCKS_USED+=("$SOCK")
  export TC_TMUX_L="$SOCK"
  : > "$REC"
  tmux -L "$SOCK" new-session -d -s s -x 120 -y 40 "MODE='$1' REC='$REC' bash '$STUB'"
  # Espera DETERMINISTA a que el fake-TUI esté renderizado y ESTABLE (dos capturas idénticas no vacías)
  # antes de devolver: evita que RELAY-READY capture una pantalla a medio dibujar (falso NO-READY).
  local prev="" cur n=0
  while [ "$n" -lt 20 ]; do
    cur="$(tmux -L "$SOCK" capture-pane -t s -p 2>/dev/null)"
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && return 0
    prev="$cur"; n=$((n+1)); sleep 0.3
  done
  return 0
}

echo "== Grupo 1-6: relay.sh contra el fake-TUI (host:s) =="

# 1. acuse OK
start_stub normal
rc=0; printf 'adjudica ch44 YA' | "$RELAY" host:s || rc=$?
ck "1-acuse-ok" 0 "$rc"
ck_true "1-recibido-registrado" "$([ "$(cat "$REC")" = 'adjudica ch44 YA' ] && echo 0 || echo 1)"

# 2. sin acuse (stub que limpia pero NO va busy)
start_stub noacuse
rc=0; printf 'orden que no acusa' | "$RELAY" host:s || rc=$?
ck "2-sin-acuse" 1 "$rc"

# 3. menú abierto -> rc 3, sin teclear (recibido vacío)
start_stub menu
rc=0; printf 'no debe teclear' | "$RELAY" host:s || rc=$?
ck "3-menu-abierto" 3 "$rc"
ck_true "3-no-tecleo" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

# 4. texto con comillas/$/backticks intacto
start_stub normal
# Literal a propósito: $HOME, backticks y comillas son BYTES de prueba, no deben expandirse.
# shellcheck disable=SC2016
ESPECIAL='dijo "hola" $HOME `x` y '\''fin'\'''
rc=0; printf '%s' "$ESPECIAL" | "$RELAY" host:s || rc=$?
ck "4-especial-acuse" 0 "$rc"
ck_true "4-literal-intacto" "$([ "$(cat "$REC")" = "$ESPECIAL" ] && echo 0 || echo 1)"

# 4b. envío corrupto/truncado en tránsito: el composer NUNCA refleja el literal -> pre-submit lo
# rechaza (rc 2), NUNCA se somete (recibido vacío) — cierra el falso-acuse de un envío alterado.
start_stub corrupt
rc=0; printf 'texto que se corrompe' | "$RELAY" host:s >/dev/null 2>&1 || rc=$?
ck "4b-corrupto-rechazado" 2 "$rc"
ck_true "4b-corrupto-no-sometido" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

# 4c. texto LARGO que fuerza el ajuste de línea real de tmux (pane de 120 cols): confirma que -J (ya en
# uso en TODAS las capturas del script) reensambla la línea antes de buscar el literal. Evidencia de
# campo reportada: un grep sin -J puede dar 0 coincidencias en un relay que SI entró porque el composer
# ENVUELVE el texto largo en varias líneas — no aplica aquí, pero se prueba explícitamente.
start_stub normal
LARGOTXT="linea_larga_$(printf 'x%.0s' $(seq 1 160))_fin"
rc=0; printf '%s' "$LARGOTXT" | "$RELAY" host:s >/dev/null 2>&1 || rc=$?
ck "4c-texto-largo-envuelto-acuse" 0 "$rc"
ck_true "4c-texto-largo-registrado-intacto" "$([ "$(cat "$REC")" = "$LARGOTXT" ] && echo 0 || echo 1)"

# 5. ENCOLADO -> rc 5, sin declarar OK, sin duplicar
start_stub encolado
rc=0; printf 'orden que se encola' | "$RELAY" host:s || rc=$?
ck "5-encolado" 5 "$rc"
ck_true "5-no-registrado" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

# 6. NO-READY (pane ya busy al invocar) -> rc 6, sin teclear
start_stub busy
rc=0; printf 'no debe teclear' | "$RELAY" host:s || rc=$?
ck "6-no-ready" 6 "$rc"
ck_true "6-no-tecleo" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

# 6a. ENCOLADO PRE-EXISTENTE (cola ya visible ANTES de que yo intente teclear) -> rc 5, sin teclear.
# Distinto del grupo 5 (encolo YO tras mi propio submit, rama del bucle de acuse): esto ejercita la
# rama de PRECONDICIÓN. Mismo predicado ic_queue_pending, mismo contrato de la línea 10 del propio
# fichero ("un mensaje ENCOLADO ... es un estado propio (rc 5), jamás un OK") -> debe dar el MISMO rc
# que el grupo 5, NUNCA el 6 de "no idle estable" (bounce de M3 sobre #2156: relay.sh daba 6 aquí).
start_stub preencolado
rc=0; printf 'no debe teclear' | "$RELAY" host:s || rc=$?
ck "6a-preencolado" 5 "$rc"
ck_true "6a-no-tecleo" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

# 6b. NO-MEDIDO end-to-end (pantalla sin ancla localizable) -> rc 2, CERO send-keys — la traducción real
# de relay.sh que exigió el MAYOR de la pasada fresca r14 (antes solo se probaba a nivel de
# ic_relay_ready aislado, nunca atravesando el binario real contra un pane vivo).
start_stub blank
rc=0; printf 'no debe teclear ni esperar' | "$RELAY" host:s || rc=$?
ck "6b-no-medido-end-to-end" 2 "$rc"
ck_true "6b-no-tecleo" "$([ ! -s "$REC" ] && echo 0 || echo 1)"

tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true

echo "== Grupo 7: idle-check --classify con fixtures realistas (bordes CORNER + ANSI) =="
classify() { printf '%b' "$1" | "$IDLE" --classify >/dev/null 2>&1; echo $?; }
# AskUserQuestion (caja + ❯ 1.) -> MENU/10, NO pending/11 (precedencia menú>pending)
ck "7-askuserquestion-menu" 10 "$(classify 'x\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\x1b[38;5;5m\xe2\x9d\xaf 1. Opcion A\x1b[0m\n  2. Opcion B\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n Enter to select\n')"
# ExitPlanMode -> MENU/10
# Fixture realista (opción resaltada con el glifo cursor, como toda selección interactiva real —
# consistente con menu-sin-composer más abajo): sin cursor en NINGUNA opción no hay forma estructural de
# distinguir un diálogo VIVO de una cita vieja a 2 líneas del final, y esa ambigüedad es real (hallazgo
# del auditor + evidencia de campo: "esc to interrupt" sin marca también fue falso positivo en producción).
ck "7-exitplanmode-menu" 10 "$(classify 'Would you like to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. No\n')"
# footer normal CON shift+tab literal -> idle-candidato (NO menú, NO busy)
ck "7-footer-shift-tab" 0 "$(classify 'hola\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mescribe...\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts   shift+tab to cycle\n')"
# cola -> 11
ck "7-cola" 11 "$(classify 'Press up to edit queued messages\n')"
# precedencia pending>busy: busy en tail Y texto real en el composer -> pending gana
ck "7-pending-gana-busy" 11 "$(classify '\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > adjudica ch44\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n  esc to interrupt\n')"
# anti-scrollback ESTRUCTURAL (repro DIRIGIDA del auditor: pane CORTO, cita vieja a poca distancia del
# composer — el bug real no era "ventana insuficiente", era "ventana absoluta" en vez de anclada al
# CORNER; el fix debe ganar sea cual sea la distancia, no solo cuando hay >=24 líneas de relleno):
# busy LEJOS (gap > TC_BUSY_LOOKBACK) -> excluido, idle-candidato. Fixture propia (hallazgo latente
# encontrado al diseñar este mismo test, ANTES de que el auditor lo pidiera): ic_detect_busy_from tenía
# la misma clase de bug que queued/menu (ventana absoluta TC_STATUS_TAIL sobre una captura corta).
ck "7-busy-lejos-excluido" 0 "$(classify "esc to interrupt viejo\nh\nh\nh\nh\nh\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n")"
# busy CERCA (layout real: el indicador vive justo encima de la caja, dentro del LOOKBACK) -> sigue
# detectado — control positivo, prueba que el fix no rompió el caso realista.
ck "7-busy-cerca-sigue-detectado" 1 "$(classify "t1\n\xe2\x97\x8f Working... (3s \xc2\xb7 esc to interrupt)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n")"
# busy CERCA sin contador (frase suelta, indistinguible de una cita en prosa a esa distancia) -> EXCLUIDO
# a propósito — hallazgo del auditor, corroborado con falsos positivos reales grepeando 'esc to interrupt'
# a secas contra estos mismos panes. La firma estricta exige contador/spinner en la zona ambigua.
ck "7-busy-cerca-sin-contador-excluido" 0 "$(classify "t1\nesc to interrupt (sin contador)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n")"
ck "7-anti-scrollback-queued-cerca" 0 "$(classify "Press up to edit queued messages (viejo)\nh\nh\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n")"
ck "7-anti-scrollback-menu-cerca" 0 "$(classify "Would you like to proceed? (viejo)\nh\nh\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n")"
# sin CORNER Y sin busy (shell listo / pantalla no calibrada) -> UNKNOWN/2, NUNCA idle-candidato (repro
# EXACTA del auditor: "un shell, pantalla incompleta o redraw estatico no es candidato a idle").
ck "7-sin-corner-sin-busy-unknown" 2 "$(classify "shell listo\n\$ \n")"
# controles POSITIVOS: un diálogo/cola que SUSTITUYE el composer (sin CORNER) sigue siendo lo ÚLTIMO
# renderizado -> debe seguir detectándose (probar que el cierre a UNKNOWN no mató la detección real).
ck "7-menu-sin-composer-sigue-detectado" 10 "$(classify 'Would you like to proceed?\n❯ 1. Yes\n  2. No\n')"
ck "7-encolado-sin-composer-sigue-detectado" 11 "$(classify 'algo\nPress up to edit queued messages\n')"
# CADENA ROTA (4 repros DIRIGIDOS del auditor): una señal histórica seguida de UNA SOLA línea distinta
# (un prompt) rompe la cadena y descarta la señal, sea cual sea la distancia -- la tolerancia por
# distancia (slack) admitía exactamente esta línea como "aceptable" y era el bug real.
ck "7-cadena-rota-menu-titulo" 2 "$(classify 'Would you like to proceed? (citado)\n$\n')"
ck "7-cadena-rota-menu-opcion" 2 "$(classify '\xe2\x9d\xaf 1. texto historico\n$\n')"
ck "7-cadena-rota-cola" 2 "$(classify 'Press up to edit queued messages (citado)\n$\n')"
ck "7-cadena-rota-busy" 2 "$(classify '\xe2\x97\x8f Working... (3s \xc2\xb7 esc to interrupt) (citado)\n$\n')"
# SEÑAL MÁS RECIENTE GANA (3 repros DIRIGIDOS del auditor): una coincidencia HISTÓRICA anterior, con
# contenido roto detrás, NO debe ocultar una coincidencia REAL posterior -- probar de mas reciente a mas
# antigua hasta que una valide, no fijar el inicio en el primer match global.
ck "7-recency-menu-real-tras-historico" 10 "$(classify 'señal de menu historica\nrespuesta ya cerrada\nWould you like to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. No\n')"
ck "7-recency-cola-real-tras-historico" 11 "$(classify 'cola historica\nrespuesta ya cerrada\nalgo\nPress up to edit queued messages\n')"
ck "7-recency-busy-real-tras-historico" 1 "$(classify 'busy historico (3s \xc2\xb7 esc to interrupt)\nrespuesta ya cerrada\n\xe2\x97\x8f Working... (5s \xc2\xb7 esc to interrupt)\n')"
# GUARDA ANTI-ECHO-DE-SHELL (3 repros DIRIGIDOS del auditor): una línea que solo CITA la señal dentro de
# un comando (p. ej. `$ echo "..."`) no es una candidata válida, aunque la contenga como subcadena.
ck "7-echo-shell-menu-excluido" 2 "$(classify '$ echo "Would you like to proceed?"\n')"
ck "7-echo-shell-cola-excluido" 2 "$(classify '$ echo "Press up to edit queued messages"\n')"
ck "7-echo-shell-busy-excluido" 2 "$(classify '$ echo "3s \xc2\xb7 esc to interrupt"\n')"
# LÍNEA COMPLETA, no subcadena (5 repros DIRIGIDOS del auditor): un sufijo/prefijo ajeno en la MISMA
# línea de la señal (comentario, log, comando) la descarta -- enumerar exclusiones por comando es un
# juego perdido; la firma debe ser la línea COMPLETA (menú/cola) o una estructura ANCLADA específica
# (busy: spinner + contador entre paréntesis), no una subcadena suelta en cualquier texto.
ck "7-sufijo-mismo-linea-menu" 2 "$(classify 'Would you like to proceed? (citado)\n')"
ck "7-sufijo-mismo-linea-cola" 2 "$(classify 'Press up to edit queued messages (citado)\n')"
ck "7-prefijo-mismo-linea-busy" 2 "$(classify 'nota del transcript: 3s \xc2\xb7 esc to interrupt (citado)\n')"
ck "7-log-info-no-es-busy" 2 "$(classify 'INFO resultado anterior: \xe2\x86\x93 9 elementos\n')"
ck "7-printf-no-es-busy" 2 "$(classify 'printf "3s \xc2\xb7 esc to interrupt"\n')"
# formato 1m3s (minutos+segundos, documentado por el sistema fuente) -> debe detectarse como busy, no
# solo el formato simple "Ns" (hallazgo BLOQUEANTE-adyacente del auditor).
ck "7-busy-formato-1m3s" 1 "$(classify 't1\n\xe2\x97\x8f Working... (1m3s \xc2\xb7 esc to interrupt)\n')"
# sufijo tras el paréntesis de cierre (sugerencia del auditor): la firma ya estaba anclada a inicio pero
# no a fin -- un sufijo ajeno en la MISMA línea, después del indicador real, no debe contar.
ck "7-busy-sufijo-tras-parentesis-excluido" 2 "$(classify '\xe2\x97\x8f Working... (3s \xc2\xb7 esc to interrupt) (citado)\n')"

# EVIDENCIA DE CAMPO (2 incidentes reales medidos contra paneles en producción, no hipotéticos):
# (a) NBSP (U+00A0) en el composer: la clase [[:space:]] lo reconoce como espacio de forma FRÁGIL
# (verificado: depende de la vía exacta de resolución del locale, distinta entre invocar el script como
# proceso externo y sourcearlo en la misma shell) -- un composer con SOLO un NBSP (placeholder de cursor
# real en algunos TUI) podía darse por "con texto" en unos contextos y no en otros. ic_norm_nbsp lo
# normaliza a espacio ASCII SOLO en el predicado de vacío/blanco, de forma determinista.
NBSP_FIXTURE='x\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \xc2\xa0\xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n'
# corrida EXTERNA (proceso real, subshell "$IDLE" --classify) -- vía de invocación 1.
rc=0; printf '%b' "$NBSP_FIXTURE" | "$IDLE" --classify >/dev/null || rc=$?
ck "7-nbsp-solo-proceso-externo" 0 "$rc"
# corrida SOURCEADA (función ic_classify en la MISMA shell, sin subproceso "$IDLE") -- vía de invocación 2,
# genuinamente distinta de la anterior (hallazgo del auditor: dos pruebas que solo variaban el nombre pero
# ambas invocaban "$IDLE" --classify como proceso externo no habrían sellado la discrepancia real, que
# vivía específicamente entre subproceso y sourcing).
rc=0
# shellcheck source=idle-check.sh disable=SC1091
out="$(printf '%b' "$NBSP_FIXTURE" | (. "$IDLE"; ic_classify) 2>&1)" || rc=$?
ck_true "7-nbsp-solo-sourceado" "$([ "$rc" = 0 ] && [ "$out" = IDLE-CANDIDATO ] && echo 0 || echo 1)"
rc=0
# shellcheck source=idle-check.sh disable=SC1091
out="$(printf 'a.b\n' | (. "$IDLE"; ic_chain_intact_from 1 '^a\.b$') 2>&1)" || rc=$?
ck_true 'regex dinámica conserva punto literal sin avisos' "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 0 || echo 1)"
rc=0
# shellcheck source=idle-check.sh disable=SC1091
out="$(printf 'aXb\n' | (. "$IDLE"; ic_chain_intact_from 1 '^a\.b$') 2>&1)" || rc=$?
ck_true 'regex dinámica rechaza otro carácter sin avisos' "$([ "$rc" = 1 ] && [ -z "$out" ] && echo 0 || echo 1)"
# CONTRATO LITERAL preservado (repro DIRIGIDA del auditor -- MAYOR): normalizar NBSP en ic_strip_dim/
# ic_strip_ansi de forma global rompía ic_composer_contains, que compara el texto ENVIADO byte-a-byte
# contra lo que aparece en el composer. Un NBSP real en el texto debe seguir coincidiendo consigo mismo,
# y NO debe confundirse con un espacio ASCII (eso enmascararía una alteración/corrupción real del envío).
CORNER_NBSP=$'\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > uno\xc2\xa0dos\xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n  ? for shortcuts\n'
rc=0
# shellcheck source=idle-check.sh disable=SC1091
printf '%s' "$CORNER_NBSP" | (. "$IDLE"; ic_composer_contains $'uno\xc2\xa0dos') >/dev/null || rc=$?
ck "7-nbsp-literal-coincide-consigo-mismo" 0 "$rc"
rc=0
# shellcheck source=idle-check.sh disable=SC1091
printf '%s' "$CORNER_NBSP" | (. "$IDLE"; ic_composer_contains 'uno dos') >/dev/null || rc=$?
ck "7-nbsp-literal-no-confunde-con-ascii" 1 "$rc"
# REGRESIÓN DEDICADA: chrome REAL de producción capturado en vivo (TAL-5141, demo AC-2 sobre el TUI real
# instalado hoy) — reglas PLANAS sin esquinas (ningún ╭/╰/│ en absoluto, solo '─'), cursor separado por
# NBSP, y el pie REAL de un menú de confirmación de herramienta ("Esc to cancel · Tab to amend · ctrl+e to
# explain", no "shift+tab"/"Enter to select"). Antes del fix, las tres daban rc=6/2/2 (NO-READY/UNKNOWN/
# UNKNOWN) contra el TUI real — este bloque fija el comportamiento correcto para que una regresión futura
# del ancla (volver a exigir ╭/╰ literales, o no ampliar el pie del menú) se detecte aquí, no en producción.
ck "7-real-chrome-flat-idle" 0 "$(classify '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\xc2\xa0\x1b[2mTry \x22fix lint errors\x22\x1b[0m\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\n  modo manual\n')"
ck "7-real-chrome-flat-pending" 11 "$(classify '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\xc2\xa0hola texto real pendiente sin enviar\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n')"
ck "7-real-chrome-flat-menu-pie-real" 10 "$(classify 'Bash command\n\n   ls /tmp\n\n Do you want to proceed?\n \xe2\x9d\xaf 1. Yes\n   2. Yes, allow reading from tmp/\n   3. No\n\n Esc to cancel \xc2\xb7 Tab to amend \xc2\xb7 ctrl+e to explain\n')"
# Variante REAL de la línea busy con duración "Nm Ns" (espacio, no pegado) y cierre "thought for Ns" en
# vez de "esc to interrupt" (recuento de tokens intercalado) — capturada en vivo (TAL-5141, re-demo AC-2).
ck "7-busy-real-duracion-con-espacio-thought-for" 1 "$(classify '\xe2\x9c\xa2 Working... (2m 29s \xc2\xb7 \xe2\x86\x93 10.3k tokens \xc2\xb7 thought for 7s)\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\xc2\xa0\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n')"
# REGRESIÓN DEDICADA (TAL-5141, pasada r15 — cierra el BLOQUEANTE de la pasada fresca r14): la captura
# de campo REAL es de DOS LÍNEAS — "✶ Sock-hopping…" (sin contador, sin paréntesis, glifo NO enumerado)
# seguida de su línea de pie "⎿ Tip: Control this session from the mobile app · run
# /remote-control". La pasada r14 recortó el fixture a la primera línea sola, o la pegó directamente al
# borde — "el fixture nuevo elimina precisamente la línea que rompe la detección" (cita literal del
# auditor: verificación amañada, un criterio que excluye el caso que lo pondría en rojo no mide nada).
# Este bloque usa el frame COMPLETO, sin recortar, en las cuatro pruebas permanentes que exigió el acta.
SOCK_LINE='\xe2\x9c\xb6 Sock-hopping\xe2\x80\xa6'
TIP_LINE='\xe2\x8e\xbf Tip: Control this session from the mobile app \xc2\xb7 run /remote-control'
FLAT_TOP='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'
FLAT_PROMPT='\xe2\x9d\xaf\xc2\xa0'
# (a) el frame COMPLETO (dos líneas), sin composer visible en absoluto (SIN CORNER) -> BUSY/1.
ck "7-busy-real-sock-hopping-sin-composer" 1 "$(classify "${SOCK_LINE}\n${TIP_LINE}\n")"
# TERCER frame real, capturado en vivo en OTRO pane (no reconstruido de memoria): glifo `*` (no `✶` —
# "el catálogo de glifos vuelve a quedarse corto en cuanto miras un pane distinto", la razón exacta por
# la que el ancla es por clase) y cierre "↓ Nk tokens" SIN "esc to interrupt" ni "thought for Ns" — el
# tercer formato que dejó corta la enumeración de cierres, cerrado generalizando a "un solo paréntesis
# bien formado" en vez de enumerar otra frase más.
ck "7-busy-real-bootstrapping-asterisco-sin-composer" 1 "$(classify '* Bootstrapping\xe2\x80\xa6 (12m 49s \xc2\xb7 \xe2\x86\x93 57.1k tokens)\n\xe2\x8e\xbf  Tip: Use /btw to ask a quick side question without interrupting the current work\n')"
# (b) el frame COMPLETO inmediatamente antes de un composer PLANO real -> BUSY/1 vía --classify, Y
# relay-ready NUNCA debe dar READY (el bug real: un pane ocupado se leía READY y relay.sh podía teclear
# encima). Con ventana de lookback=1 la línea que toca el borde sería SOLO la de "Tip", que por sí sola
# no lleva la señal — por eso el fix subió TC_BUSY_LOOKBACK a 2 (ver idle-check.sh).
ck "7-busy-real-sock-hopping-antes-composer-plano" 1 "$(classify "${SOCK_LINE}\n${TIP_LINE}\n${FLAT_TOP}\n${FLAT_PROMPT}\n${FLAT_TOP}\n")"
# Aserción OPERATIVA sobre ic_relay_ready real (no solo --classify): se sourcea idle-check.sh en un
# subshell aislado y se SOBREESCRIBE _tc_cap_e (el único punto de captura real vía tmux) para devolver
# el fixture fijo — así ic_relay_ready ejecuta su lógica REAL de principio a fin, incluida la resolución
# de target y el bucle de micro-continuidad, sin tocar tmux. Esta es la prueba que el hallazgo BLOQUEANTE
# exigía: no basta con que --classify diga BUSY, relay-ready (lo que relay.sh consulta antes de teclear)
# tiene que devolver NOT-READY, NUNCA READY, con el frame COMPLETO sin recortar.
# shellcheck disable=SC2059  # las variables SOLO llevan \x../\n literales (sin '%'), se usan como
# formato a propósito para que printf las interprete -- igual patrón que el resto del fichero.
SOCK_FIXTURE="$(printf "${SOCK_LINE}\n${TIP_LINE}\n${FLAT_TOP}\n${FLAT_PROMPT}\n${FLAT_TOP}\n")"
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf '%s\n' "$SOCK_FIXTURE"; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)"
ck_true "7-busy-sock-hopping-relay-ready-nunca-ready" "$(printf '%s' "$out" | grep -qE '^READY$' && echo 1 || echo 0)"
# (c) NEGATIVOS bilaterales EXIGIDOS por el auditor (no basta con que sea fail-closed: la clase debe
# RECHAZAR estructura viva falsa, no solo evitar el nombre "nota:"): una cita Markdown `>` y un bullet
# `•` terminados en elipsis, con VARIAS palabras entre el glifo y la elipsis — el hallazgo exacto de r14
# fue que un negativo que empieza por "nota:" NO ejercita ninguno de los dos, por construcción.
ck "7-cita-markdown-con-elipsis-no-es-busy" 2 "$(classify '> Sock-hopping through the results and thinking more...\n')"
ck "7-bullet-con-elipsis-no-es-busy" 2 "$(classify '\xe2\x80\xa2 Resumen hist\xc3\xb3rico\xe2\x80\xa6\n')"
# Negativo YA existente (más texto detrás en la misma línea, cita) -> sigue excluida.
ck "7-busy-sock-hopping-citado-excluido" 2 "$(classify 'nota: se vio \xe2\x9c\xb6 Sock-hopping\xe2\x80\xa6 en el log\n')"

# REGRESIÓN DEDICADA (TAL-5141, pasada r15 — cierra el MAYOR "el supuesto frame de dos líneas no se
# valida como frame"): reproducciones LITERALES del acta r15, forma MÍNIMA de dos campos (glifo +
# palabra-con-elipsis, SIN nada más detrás) — la clase que los negativos de arriba (r14, varias palabras
# entre el glifo y la elipsis) NO ejercitaba. Sin composer visible, el ancla no localiza el corner y el
# contrato es UNKNOWN/2 (no BUSY/1) — el propio acta cita estos ocho casos dando "rc=1 out=BUSY" contra
# el diseño previo a este fix; aquí quedan fijados en su forma corregida.
ck "7-short-quote-no-es-busy" 2 "$(classify '> Waiting\xe2\x80\xa6\n')"
ck "7-short-bullet-no-es-busy" 2 "$(classify '\xe2\x80\xa2 Resumen\xe2\x80\xa6\n')"
ck "7-markdown-bullet-no-es-busy" 2 "$(classify '* Nota\xe2\x80\xa6\n')"
ck "7-quote-parenthetical-no-es-busy" 2 "$(classify '> Waiting\xe2\x80\xa6 (citado)\n')"
ck "7-bullet-parenthetical-no-es-busy" 2 "$(classify '\xe2\x80\xa2 Resumen\xe2\x80\xa6 (hist\xc3\xb3rico)\n')"
ck "7-footer-short-no-es-busy" 2 "$(classify '? Atajos\xe2\x80\xa6\n')"
# fake_tip_chain: un indicador aparente seguido de una línea que solo CONTIENE la subcadena "Tip:" en
# prosa citada, no un pie ANCLADO estructuralmente (ic_is_pie_line exige que el PRIMER campo no-vacío sea
# "Tip:" tras un glifo no-alfanumérico) — el acta r15 lo dio como "rc=1 out=BUSY" bajo el diseño de sustring.
ck "7-fake-tip-chain-no-es-busy" 2 "$(classify '> Waiting\xe2\x80\xa6\ntexto Tip: citado\n')"

# REGRESIÓN DEDICADA (TAL-5141, pasada r16 — cierra el MAYOR "anclado aquí significa POSICIÓN DE
# CAMPO, no IDENTIDAD ESTRUCTURAL del pie"): el negativo de arriba NO ejercitaba el defecto real —
# "texto Tip: citado" falla por tener el PRIMER campo alfanumérico ("texto"), una razón DISTINTA de la
# que se quería probar (exactamente el patrón del BLOQUEANTE de r14 en su forma negativa: un control
# que falla por otra causa no es un control). La forma NATURAL de una cita Markdown de dos líneas usa
# un glifo de cita real como primer campo (">", "┃", "•", "?") seguido de un segundo campo "Tip:" —
# bajo el diseño anterior (cualquier glifo no-alfanumérico = pie válido) las CUATRO daban "rc=1
# out=BUSY". Ahora ic_is_pie_line exige el glifo LITERAL "⎿" (identidad, no posición) y estas cuatro
# variantes quedan excluidas sin composer (UNKNOWN/2).
ck "7-quote-tip-glifo-mayor-no-es-busy" 2 "$(classify '> Waiting\xe2\x80\xa6\n> Tip: citado\n')"
ck "7-bar-tip-glifo-mayor-no-es-busy" 2 "$(classify '\xe2\x94\x83 Waiting\xe2\x80\xa6\n\xe2\x94\x83 Tip: citado\n')"
ck "7-bullet-tip-glifo-mayor-no-es-busy" 2 "$(classify '\xe2\x80\xa2 Resumen\xe2\x80\xa6\n\xe2\x80\xa2 Tip: citado\n')"
ck "7-footer-tip-glifo-mayor-no-es-busy" 2 "$(classify '? Atajos\xe2\x80\xa6\n? Tip: citado\n')"
# La otra mitad del MAYOR r16: la rama parentizada usaba una búsqueda de SUBCADENA ("[0-9]+m?s" sin
# límites de token), así que "(sha5sum)" colaba por la subcadena "5s" que lleva dentro — no es un
# predicado de estado, es un grep optimista. Y "> Waiting… (5s)" colaba por el mismo defecto de
# identidad de glifo que arriba (">" nunca es un glifo de BUSY real). Ahora la duración exige un TOKEN
# COMPLETO (split por espacio + regex anclada por token) y el glifo ">" queda excluido en ambas ramas.
ck "7-quote-duration-glifo-mayor-no-es-busy" 2 "$(classify '> Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-markdown-bullet-subcadena-sha5sum-no-es-busy" 2 "$(classify '* Nota\xe2\x80\xa6 (sha5sum)\n')"
# AISLADOR de la identidad de pie (pedido explícito de C1 tras r16: "el mutante combinado actual solo
# distingue subcadena-alfanumérica de segundo-campo-Tip: y no mide la colisión con marcadores de
# cita"): los cuatro casos de arriba usan un glifo EXCLUIDO (">","•","┃","?") también como PRIMER campo
# de la línea busy candidata, así que la exclusión de glifo de is_busy ya los rechaza ANTES de llegar a
# evaluar pie_next — mutar SOLO ic_is_pie_line no los enrojece (verificado). Este caso usa un glifo de
# BUSY real y NO excluido ("✶") en la línea candidata, con un companion FALSO que sí usa un glifo
# excluido (">") como su propio primer campo — así el único punto de fallo posible es el predicado de
# identidad del pie (is_pie), no la exclusión de glifo de is_busy.
ck "7-pie-identidad-aislada-no-es-busy" 2 "$(classify '\xe2\x9c\xb6 Sock-hopping\xe2\x80\xa6\n> Tip: citado\n')"
# AISLADOR de la frontera de token en la rama parentizada (mismo motivo): "* Nota… (sha5sum)" pasa por
# la exclusión de "*" (exige pie adyacente, que aquí falta) ANTES de llegar al chequeo de duración —
# mutar SOLO la vuelta a subcadena no lo enrojece (verificado). Este caso usa un glifo de BUSY real y NO
# ambiguo ("✶", nunca "*") para que el único punto de fallo posible sea el propio chequeo de duración.
ck "7-duracion-token-aislado-no-es-busy" 2 "$(classify '\xe2\x9c\xb6 Nota\xe2\x80\xa6 (sha5sum)\n')"

# REGRESIÓN DEDICADA (TAL-5141, pasada r17 — cierra el MAYOR "tu predicado sigue siendo un catálogo,
# más largo cada vez, en vez de una clase estructural"): la lista de exclusión de r16 ("bloqueada a >,
# •, ┃, ?") era, ella misma, un catálogo sin fin — CommonMark siempre tiene un marcador más ("-", "+",
# listas ordenadas "N."/"N)", em-dash). r17 ELIMINA la lista de exclusión por completo: el DEFAULT ahora
# es exigir el pie anclado real para CUALQUIER glifo salvo el par con identidad POSITIVA demostrada por
# captura real sin pie ("●", "✢") — cierra la clase entera de una vez, sin enumerar el próximo carácter.
ck "7-dash-bullet-duration-no-es-busy" 2 "$(classify '- Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-plus-bullet-duration-no-es-busy" 2 "$(classify '+ Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-ordered-bullet-duration-no-es-busy" 2 "$(classify '1. Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-ordered-paren-duration-no-es-busy" 2 "$(classify '1) Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-emdash-duration-no-es-busy" 2 "$(classify '\xe2\x80\x94 Waiting\xe2\x80\xa6 (5s)\n')"
ck "7-ordered-bullet-antes-de-composer-no-busy" 0 "$(classify '1. Waiting\xe2\x80\xa6 (5s)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n')"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf '1. Waiting\xe2\x80\xa6 (5s)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n'; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-ordered-bullet-relay-ready-da-ready" "$(printf '%s' "$out" | grep -qE '^READY$' && [ "$rc" -eq 0 ] && echo 0 || echo 1)"

# REGRESIÓN DEDICADA (TAL-5141, pasada fresca — MAYOR): el contrato "UNKNOWN -> NO-MEDIDO/rc2, nunca
# NOT-READY/rc1" (idle-check.sh, propagación en ic_relay_ready) no estaba protegido operativamente — el
# auditor mutó esa línea a `NOT-READY:${tok}`/rc1 y el selftest completo (79/0 en ese momento) no se
# enteró, porque solo probaba UNKNOWN vía --classify aislado, nunca atravesando ic_relay_ready de verdad.
# Los TRES casos sourcean idle-check.sh en un subshell y SOBREESCRIBEN _tc_cap_e (el único punto de
# captura real) para forzar la condición exacta, ejecutando la función REAL de punta a punta. FIX
# MAYOR (pasada fresca r14): el diseño anterior solo comparaba el TEXTO de salida (`grep`), nunca el
# `$?` — un mutante que cambiara SOLO `return 2` por `return 1` conservando el texto `NO-MEDIDO:...`
# pasaba el selftest entero en verde (rc no es lo mismo que copy: el llamador decide por rc). Ahora se
# exige la CONJUNCIÓN prefijo-de-texto Y rc==2, capturados con el patrón set-e-safe
# `rc=0; out="$(...)" || rc=$?` (nunca `out=$(...); rc=$?` bajo `set -e`, que puede perder el rc real).
# Y se separan los TRES casos distintos del contrato (idle-check.sh:523-526), no dos: captura válida
# pero sin ancla (UNKNOWN); captura vacía CON éxito (rc0, salida vacía); y captura FALLIDA de verdad
# (_tc_cap_e devuelve rc≠0) — el diseño anterior llamaba "fallida" a la vacía-con-éxito, que protege
# una rama distinta (línea ~524, no la 523).
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf 'texto sin ancla ni señal alguna, gibberish puro\n'; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-relay-ready-unknown-da-no-medido-rc2" "$(printf '%s' "$out" | grep -qE '^NO-MEDIDO:' && [ "$rc" -eq 2 ] && echo 0 || echo 1)"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf ''; }   # captura VACÍA pero EXITOSA (rc0) — protege idle-check.sh:524
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-relay-ready-captura-vacia-exitosa-da-no-medido-rc2" "$(printf '%s' "$out" | grep -qE '^NO-MEDIDO:' && [ "$rc" -eq 2 ] && echo 0 || echo 1)"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { return 7; }   # captura FALLIDA DE VERDAD (rc≠0) — protege idle-check.sh:523
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-relay-ready-captura-fallida-de-verdad-da-no-medido-rc2" "$(printf '%s' "$out" | grep -qE '^NO-MEDIDO:' && [ "$rc" -eq 2 ] && echo 0 || echo 1)"

# (b) ventana corta (4 líneas, SIN footer): la cola citada en el CUERPO (antes del composer) nunca debe
# contarse como pendiente; la misma cola en el PIE (tras el composer, ver caso hermano abajo) sí. Antes
# del ancla por-clase el resultado era UNKNOWN/2 (sin footer, el ancla vieja no localizaba el composer y
# la única red SIN-CORNER solo mira busy) — con el ancla por POSICIÓN (ya no exige footer) el composer SÍ
# se localiza, así que ahora resuelve a IDLE-CANDIDATO/0: una mejora, no una regresión — la afirmación del
# caso ("la cita del cuerpo NO cuenta como pendiente") se sigue cumpliendo (0 no es 5 ni 11), y encima deja
# de ser UNKNOWN cuando SÍ hay evidencia estructural suficiente para decidir.
ck "7-corto-cita-en-cuerpo-no-pending" 0 "$(classify 'Press up to edit queued messages\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n')"
ck "7-corto-cita-en-pie-si-pending" 11 "$(classify 'algo\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\nPress up to edit queued messages\n')"

# REGRESIÓN DEDICADA (TAL-5141, pasada r15 — MAYOR, con composer REAL localizado): el acta exige
# comprobar TAMBIÉN que ic_relay_ready da READY sobre el composer vacío acompañado de cada transcript
# inocuo, no solo --classify aislado sin corner. Con el corner presente y vacío, el ancla lo localiza y
# ninguno de los dos casos debe leerse como BUSY (1) ni como PENDING (11) — deben resolver IDLE-CANDIDATO/0.
ck "7-quote-parenthetical-antes-de-composer-no-busy" 0 "$(classify '> Waiting\xe2\x80\xa6 (citado)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n')"
ck "7-footer-short-tras-composer-no-busy" 0 "$(classify 'algo\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n? Atajos\xe2\x80\xa6\n')"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf '> Waiting\xe2\x80\xa6 (citado)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n'; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-quote-parenthetical-relay-ready-da-ready" "$(printf '%s' "$out" | grep -qE '^READY$' && [ "$rc" -eq 0 ] && echo 0 || echo 1)"

# REGRESIÓN DEDICADA (TAL-5141, pasada r16 — MAYOR): las mismas dos reproducciones literales de la
# acta ("> Waiting…" + "> Tip: citado" y "> Waiting… (5s)") pero JUSTO ANTES de un composer real vacío
# — el propio acta señaló que "el lookback entrega literalmente la siguiente línea al predicado", así
# que una cita de dos líneas ahí se leía BUSY y `ic_relay_ready` daba NOT-READY:BUSY sobre un pane
# realmente idle. Exige la conjunción IDLE-CANDIDATO/0 (--classify) Y READY (ic_relay_ready real).
ck "7-quote-tip-glifo-antes-de-composer-no-busy" 0 "$(classify '> Waiting\xe2\x80\xa6\n> Tip: citado\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n')"
ck "7-quote-duration-glifo-antes-de-composer-no-busy" 0 "$(classify '> Waiting\xe2\x80\xa6 (5s)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n')"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf '> Waiting\xe2\x80\xa6\n> Tip: citado\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n'; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-quote-tip-glifo-relay-ready-da-ready" "$(printf '%s' "$out" | grep -qE '^READY$' && [ "$rc" -eq 0 ] && echo 0 || echo 1)"
rc=0
out="$(
  # shellcheck source=idle-check.sh disable=SC1091
  . "$IDLE"
  # shellcheck disable=SC2317  # invocada indirectamente por ic_relay_ready tras el override
  _tc_cap_e() { printf '> Waiting\xe2\x80\xa6 (5s)\n\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 > \x1b[2mx\x1b[0m\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n'; }
  TC_MICRO_GAP=0
  ic_relay_ready host:s
)" || rc=$?
ck_true "7-quote-duration-glifo-relay-ready-da-ready" "$(printf '%s' "$out" | grep -qE '^READY$' && [ "$rc" -eq 0 ] && echo 0 || echo 1)"

# _tc_resolve PURO con TC_TMUX_L VACÍO (su valor NORMAL en producción, fuera del selftest): el selftest
# entero usa start_stub, que SIEMPRE fija TC_TMUX_L a un socket no vacío -- ningún caso anterior ejercitó
# jamás esta ruta. Hallazgo BLOQUEANTE del auditor: sin este test, host:*/torre-* fallaban en silencio en
# TODA invocación real (el último comando de esas ramas era '[ -n "$TC_TMUX_L" ] && ...', que devuelve rc
# 1 cuando la condición es falsa -- y ese rc se colaba como el propio return de _tc_resolve).
# shellcheck disable=SC2016
resolve_probe() { # <target> <rc_esperado>
  local out rc=0
  out="$(env -u TC_TMUX_L bash -c '
    set -euo pipefail
    # shellcheck source=idle-check.sh disable=SC1091
    . "'"$IDLE"'"
    rc=0; _tc_resolve "'"$1"'" || rc=$?
    echo "RC=$rc MODE=$TC_MODE SESSPANE=$TC_SESSPANE"
  ' 2>&1)" || rc=$?
  ck_true "8h-resolve-${1//[:.]/-}" "$(printf '%s' "$out" | grep -q "^RC=${2} " && [ "$rc" = 0 ] && echo 0 || echo 1)"
}
resolve_probe "host:s" 0
resolve_probe "torre-a" 0
resolve_probe "canal-1" 0

# tree_has_worker: fixtures de árbol de procesos (source puro). Contrato EXACTO (hallazgo del auditor):
# excluye SOLO el PID residente — CUALQUIER descendiente vivo cuenta como trabajo, sea cual sea su comm
# (un gate/watcher/tail vivo NO puede leerse como "sin trabajo" por parecer transitorio). "tuiproc" es un
# nombre NEUTRAL de fixture (no un producto real).
# shellcheck source=idle-check.sh disable=SC1091
. "$IDLE"
rc=0; printf '1000 1 bash\n1001 1000 tuiproc\n1002 1001 bash\n1003 1002 sleep\n' | ic_tree_has_worker_from 1001 || rc=$?
ck "7-tree-con-trabajo-sleep" 0 "$rc"
rc=0; printf '1000 1 bash\n1001 1000 tuiproc\n1002 1001 watch\n' | ic_tree_has_worker_from 1001 || rc=$?
ck "7-tree-con-trabajo-watch" 0 "$rc"
rc=0; printf '1000 1 bash\n1001 1000 tuiproc\n1002 1001 bash\n1003 1002 cat\n' | ic_tree_has_worker_from 1001 || rc=$?
ck "7-tree-con-trabajo-cat-anidado" 0 "$rc"
rc=0; printf '1000 1 bash\n1001 1000 tuiproc\n' | ic_tree_has_worker_from 1001 || rc=$?
ck "7-tree-sin-descendientes-idle" 1 "$rc"

echo "== Grupo 8: fronteras de los contratos de shell (pruebas negativas) =="
# 8a. source no ejecuta la CLI ni hace exit; el llamador continúa
out="$(bash -c '. "'"$IDLE"'"; echo VIVO' 2>/dev/null)"
ck_true "8-source-sin-exit" "$([ "$out" = VIVO ] && echo 0 || echo 1)"

# 8b. target con metacaracteres -> rc 2 y CERO llamadas a tmux/incus (shim contador en PATH)
SHIMDIR="$WORK/shim"; mkdir -p "$SHIMDIR"
for b in tmux incus; do printf '#!/usr/bin/env bash\ntouch "%s/CALLED-%s"\nexit 0\n' "$WORK" "$b" > "$SHIMDIR/$b"; chmod +x "$SHIMDIR/$b"; done
rm -f "$WORK"/CALLED-*
rc=0; PATH="$SHIMDIR:$PATH" printf 'x' | PATH="$SHIMDIR:$PATH" "$RELAY" 'host:foo;rm -rf /' >/dev/null 2>&1 || rc=$?
ck "8-target-metachar-rc2" 2 "$rc"
ck_true "8-target-metachar-cero-tmux" "$([ ! -e "$WORK/CALLED-tmux" ] && [ ! -e "$WORK/CALLED-incus" ] && echo 0 || echo 1)"

# 8c. token inválido en TC_SUBMIT_SEQ -> rechazado antes de teclear (sin eval), sin llamar a tmux
rm -f "$WORK"/CALLED-*
rc=0; PATH="$SHIMDIR:$PATH" bash -c '
  set -uo pipefail
  # shellcheck source=relay.sh
  . "'"$RELAY"'"
  TC_MODE=host; TC_SESSPANE=s.0; TC_TMUX_CMD=(tmux); TC_SUBMIT_SEQ="rm -rf"
  _tc_submit
' >/dev/null 2>&1 || rc=$?
ck_true "8-submit-token-rechazado" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
ck_true "8-submit-token-cero-tmux"  "$([ ! -e "$WORK/CALLED-tmux" ] && echo 0 || echo 1)"

# 8d. estado persistido bajo dos escrituras concurrentes -> fichero íntegro y parseable
STATE_TMP="$WORK/state"; mkdir -p "$STATE_TMP"
rc=0; bash -c '
  set -uo pipefail
  export TC_STATE_DIR="'"$STATE_TMP"'"
  # shellcheck source=idle-check.sh
  . "'"$IDLE"'"
  ( _tc_state_first_seen slugc AAAA >/dev/null ) &
  ( _tc_state_first_seen slugc AAAA >/dev/null ) &
  wait
' || rc=$?
lines="$(wc -l < "$STATE_TMP/slugc.state" 2>/dev/null || echo 99)"
integ="$(grep -cE '^[A-Za-z0-9._-]+[[:space:]]+[0-9]+$' "$STATE_TMP/slugc.state" 2>/dev/null || echo 0)"
ck_true "8-estado-concurrente-1linea" "$([ "$lines" = 1 ] && [ "$integ" = 1 ] && echo 0 || echo 1)"

# 8e. recorrido de rc: {0,1,2,3,5,6,10,11} deben haber aparecido (señal de completitud, complementa 8f)
missing=""
for want in 0 1 2 3 5 6 10 11; do case " $rcs " in *" $want "*) ;; *) missing="$missing $want";; esac; done
if [ -z "$missing" ]; then ck_true "8-recorrido-rc-completo" 0; else printf 'faltan rc:%s\n' "$missing" >&2; ck_true "8-recorrido-rc-completo" 1; fi

# 8f. set -e REAL: cada rc representativo se alcanza dentro de un llamador con 'set -euo pipefail'
# EXPLÍCITO, probado por un marcador REACHED-<rc> impreso DESPUÉS de la llamada (no solo por la
# presencia del número en una lista acumulada — eso es lo que el auditor marcó como insuficiente).
sete_probe() { # <rc_esperado> <script-bash>
  # $rc aqui es el exit del 'bash -c' EXTERIOR (debe ser 0: el script interno captura su propio rc con
  # '|| rc=$?' y termina con un echo exitoso — un rc exterior != 0 significaria que 'set -e' abortó
  # ANTES de imprimir el marcador, justo el fallo que esta prueba busca). La prueba real está en el
  # marcador REACHED-<rc>, que codifica el rc INTERNO capturado.
  local want="$1" script="$2" out rc=0
  out="$(bash -c "set -euo pipefail; $script" 2>/dev/null)" || rc=$?
  ck_true "8f-sete-rc${want}" "$([ "$rc" = 0 ] && [ "$out" = "REACHED-${want}" ] && echo 0 || echo 1)"
}
# Comillas mixtas intencionales ('literal' + "$VAR" + 'literal'): $rc/$? deben permanecer LITERALES
# hasta que el bash -c anidado de sete_probe los evalúe — un solo par de comillas dobles los expandiría
# aquí mismo, antes de tiempo. shellcheck no distingue esa intención de un error de quoting real.
# shellcheck disable=SC2016
sete_probe 2 'rc=0; printf "" | "'"$IDLE"'" --classify >/dev/null || rc=$?; echo "REACHED-$rc"'
# shellcheck disable=SC2016
sete_probe 10 'rc=0; printf "Would you like to proceed?\n" | "'"$IDLE"'" --classify >/dev/null || rc=$?; echo "REACHED-$rc"'
# shellcheck disable=SC2016
sete_probe 11 'rc=0; printf "Press up to edit queued messages\n" | "'"$IDLE"'" --classify >/dev/null || rc=$?; echo "REACHED-$rc"'
start_stub menu
# shellcheck disable=SC2016
sete_probe 3 'rc=0; printf "x" | "'"$RELAY"'" host:s >/dev/null 2>&1 || rc=$?; echo "REACHED-$rc"'
# rc 1 (deadline sin acuse), rc 5 (encolado) y rc 6 (no-ready) — hallazgo MAYOR: el resumen los daba por
# cubiertos por la mera presencia en $rcs, sin probe real bajo set -e.
start_stub noacuse
# shellcheck disable=SC2016
sete_probe 1 'rc=0; printf "x" | "'"$RELAY"'" host:s >/dev/null 2>&1 || rc=$?; echo "REACHED-$rc"'
start_stub encolado
# shellcheck disable=SC2016
sete_probe 5 'rc=0; printf "x" | "'"$RELAY"'" host:s >/dev/null 2>&1 || rc=$?; echo "REACHED-$rc"'
start_stub busy
# shellcheck disable=SC2016
sete_probe 6 'rc=0; printf "x" | "'"$RELAY"'" host:s >/dev/null 2>&1 || rc=$?; echo "REACHED-$rc"'

# 8g. TC_MICRO_N por debajo del piso del contrato (N>=3) -> rechazado en config, SIN intentar tmux/incus
# (el rechazo ocurre en la validación, antes de cualquier captura).
rm -f "$WORK"/CALLED-*
rc=0; out="$(PATH="$SHIMDIR:$PATH" TC_MICRO_N=2 "$IDLE" --relay-ready host:s 2>&1)" || rc=$?
ck "8g-micron-bajo-piso-rc2" 2 "$rc"
ck_true "8g-micron-bajo-piso-sin-captura" "$(printf '%s' "$out" | grep -q 'NO-MEDIDO:config' && echo 0 || echo 1)"
ck_true "8g-micron-bajo-piso-cero-tmux" "$([ ! -e "$WORK/CALLED-tmux" ] && [ ! -e "$WORK/CALLED-incus" ] && echo 0 || echo 1)"

echo
echo "RESULTADO: $pass PASS / $fail FAIL"
[ "$fail" -eq 0 ]
