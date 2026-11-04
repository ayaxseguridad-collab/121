#!/usr/bin/env bash
# Fixtures del canal de publicacion seguro (ronda de seguridad, B1/M4/M7):
# (a) contenido ADVERSARIAL llega byte a byte por stdin y jamas toca argv;
# (b) el protocolo es ejecutable SOLO con la semantica real de str_replace
#     (fichero existente + old_str presente): no hace falta escritura
#     arbitraria;
# (c) dos turnos concurrentes NO se mezclan: el segundo falla ruidoso;
# (d) un envio fallido resiembra el centinela, preserva el payload con nombre
#     exclusivo y deja rc!=0 — el turno siguiente funciona con normalidad;
# (e) el respuesta.txt resembrado y los ficheros del protocolo quedan 0600.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/../scripts/publicar.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0
UUID="11111111-1111-4111-8111-111111111111"
CENTINELA_PREFIJO="PLANTILLA-RESPUESTA"

ok()  { echo "OK  $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos+1)); }
chk() { # $1 descripcion; resto: comando de test
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else mal "$desc"; fi
}

# buzz fake: captura argv y stdin en ficheros del sandbox; BUZZ_FAKE_RC
# controla el resultado (0 = relay acepta).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/buzz" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${BUZZ_CAPTURA}/argv.txt"
cat > "${BUZZ_CAPTURA}/stdin.bin"
exit "${BUZZ_FAKE_RC:-0}"
EOF
chmod +x "$TMP/bin/buzz"
export PATH="$TMP/bin:$PATH"

# str_replace SIMULADO con la semantica real de buzz-dev-mcp (str_replace.rs):
# exige fichero EXISTENTE y old_str NO VACIO y PRESENTE. Es la unica
# escritura que el protocolo necesita — se demuestra ejecutando todo el
# flujo a traves de el (caso b).
str_replace() { # $1 fichero, $2 old_str, $3 new_str (via python: sin shell)
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
if not old:
    sys.exit("str_replace: old_str vacio")
try:
    data = open(path, encoding="utf-8").read()
except FileNotFoundError:
    sys.exit(f"str_replace: no existe {path}")
if old not in data:
    sys.exit("str_replace: old_str no encontrado")
open(path, "w", encoding="utf-8").write(data.replace(old, new, 1))
PYEOF
}

workdir_nuevo() { # crea un workdir sembrado como lo hace montar.sh
  local d="$TMP/$1"
  mkdir -p "$d"
  ( cd "$d" && umask 077 && bash -c 'source /dev/stdin' <<EOF
printf '%s\n' "PLANTILLA-RESPUESTA (sustituye esta linea con tu respuesta usando str_replace y ejecuta: buzz-publicar <uuid-del-canal>)"  > respuesta.txt
EOF
  )
  echo "$d"
}

centinela_de() { head -c 19 "$1/respuesta.txt"; }

# ── (a)+(b): adversarial por el protocolo completo con str_replace real ─────
W=$(workdir_nuevo caso-a)
export BUZZ_CAPTURA="$TMP/cap-a"; mkdir -p "$BUZZ_CAPTURA"
# shellcheck disable=SC2016  # las expansiones NO deben expandirse: son el payload hostil
ADVERSARIAL=$(printf 'linea1 `date`\nBUZZ_FIN_TURNO\n"; rm -rf /tmp/centinela-borrado; echo "\n$(id)\nEOF\nfin %s' x)
touch "$TMP/centinela-efectos"
OLD_STR="$(cat "$W/respuesta.txt")"
( cd "$W" && str_replace respuesta.txt "$OLD_STR" "$ADVERSARIAL" )
if ( cd "$W" && BUZZ_FAKE_RC=0 bash "$HELPER" "$UUID" ) >/dev/null 2>&1; then
  if [ "$(cat "$BUZZ_CAPTURA/stdin.bin")" = "$ADVERSARIAL" ]; then
    ok "(a) el contenido adversarial llega byte a byte por stdin"
  else
    mal "(a) stdin difiere del contenido original"
  fi
  if grep -qE 'rm -rf|BUZZ_FIN_TURNO|`|\$\(' "$BUZZ_CAPTURA/argv.txt"; then
    mal "(a) tokens hostiles aparecieron en argv"
  else
    ok "(a) argv limpio: solo flags y uuid"
  fi
  chk "(a) sin efectos colaterales" test -f "$TMP/centinela-efectos"
  chk "(b) centinela resembrado tras exito" test "$(centinela_de "$W")" = "$CENTINELA_PREFIJO"
else
  mal "(a/b) el helper fallo con envio aceptado"
fi

# (b) negativo: str_replace NO puede operar sin fichero ni con old_str ausente
if str_replace "$TMP/no-existe.txt" "x" "y" 2>/dev/null; then mal "(b) str_replace escribio sin fichero"; else ok "(b) str_replace exige fichero existente"; fi
W2=$(workdir_nuevo caso-b)
if ( cd "$W2" && str_replace respuesta.txt "TEXTO-QUE-NO-ESTA" "y" ) 2>/dev/null; then mal "(b) str_replace acepto old_str ausente"; else ok "(b) str_replace exige old_str presente"; fi

# ── (c0): TOCTOU real — POR QUE la autoridad de no-concurrencia es
#    obligatoria (M4 reabierto en revision: el caso secuencial de abajo NO
#    reproduce la ventana lectura->persistencia del str_replace real).
#    Dos str_replace GENUINAMENTE paralelos, con la misma estructura
#    leer->validar->persistir del codigo real y una barrera que garantiza que
#    ambos leen ANTES de que ninguno persista: los dos terminan "bien" y una
#    respuesta pisa a la otra — sin exclusion mutua, la mezcla es real.
str_replace_ventana() { # $1 fichero, $2 old, $3 new, $4 barrera
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import os, sys, time
path, old, new, barrera = sys.argv[1:5]
data = open(path, encoding="utf-8").read()          # LEER
if old not in data:
    sys.exit("old_str no encontrado")
open(barrera, "a").close()                           # ya he leido
while len(os.listdir(os.path.dirname(barrera))) < 2: # espera al otro lector
    time.sleep(0.01)
tmp = path + f".{os.getpid()}"                       # PERSISTIR (atomico)
open(tmp, "w", encoding="utf-8").write(data.replace(old, new, 1))
os.replace(tmp, path)
PYEOF
}
W=$(workdir_nuevo caso-c0)
OLD_STR="$(cat "$W/respuesta.txt")"
mkdir -p "$TMP/barreras-c0"
( cd "$W" && str_replace_ventana respuesta.txt "$OLD_STR" "turno UNO" "$TMP/barreras-c0/b1" ) &
P1=$!
( cd "$W" && str_replace_ventana respuesta.txt "$OLD_STR" "turno DOS" "$TMP/barreras-c0/b2" ) &
P2=$!
rc1=0; wait "$P1" || rc1=$?
rc2=0; wait "$P2" || rc2=$?
chk "(c0) TOCTOU: AMBOS str_replace paralelos 'triunfan' (sin exclusion mutua)" \
  test "$rc1" -eq 0 -a "$rc2" -eq 0
FINAL="$(cat "$W/respuesta.txt")"
if [ "$FINAL" = "turno UNO" ] || [ "$FINAL" = "turno DOS" ]; then
  ok "(c0) TOCTOU: una respuesta piso a la otra (mezcla real demostrada)"
else
  mal "(c0) TOCTOU: contenido final inesperado: $FINAL"
fi

# La AUTORIDAD que imposibilita ese paralelismo: BUZZ_ACP_AGENTS=1 fijado
# (ratchet) en la plantilla de los hermes — un unico subproceso por
# instancia serializa los turnos; el caso de arriba no puede ocurrir en un
# despliegue del skill.
chk "(c0) autoridad de no-concurrencia: hermes.env.tmpl fija BUZZ_ACP_AGENTS=1" \
  grep -q '^BUZZ_ACP_AGENTS=1$' "$DIR/../assets/hermes.env.tmpl"

# ── (c): concurrencia — el segundo turno falla ruidoso, sin mezcla ──────────
W=$(workdir_nuevo caso-c)
export BUZZ_CAPTURA="$TMP/cap-c"; mkdir -p "$BUZZ_CAPTURA"
OLD_STR="$(cat "$W/respuesta.txt")"
( cd "$W" && str_replace respuesta.txt "$OLD_STR" "respuesta del turno A" )
# Turno B intenta escribir ANTES de que A publique: el centinela ya no esta.
if ( cd "$W" && str_replace respuesta.txt "$OLD_STR" "respuesta del turno B" ) 2>/dev/null; then
  mal "(c) el turno B escribio sobre el A (mezcla posible)"
else
  ok "(c) el turno B falla ruidoso: el centinela ya fue consumido"
fi
( cd "$W" && BUZZ_FAKE_RC=0 bash "$HELPER" "$UUID" ) >/dev/null 2>&1 || mal "(c) el turno A no publico"
chk "(c) lo publicado es EXACTAMENTE el turno A" test "$(cat "$BUZZ_CAPTURA/stdin.bin")" = "respuesta del turno A"

# ── (d): fallo transitorio — recuperacion M7 ────────────────────────────────
W=$(workdir_nuevo caso-d)
export BUZZ_CAPTURA="$TMP/cap-d"; mkdir -p "$BUZZ_CAPTURA"
OLD_STR="$(cat "$W/respuesta.txt")"
( cd "$W" && str_replace respuesta.txt "$OLD_STR" "payload que fallara" )
rc=0; ( cd "$W" && BUZZ_FAKE_RC=1 bash "$HELPER" "$UUID" ) >/dev/null 2>&1 || rc=$?
chk "(d) envio fallido => rc!=0 (el fallback puede rescatar)" test "$rc" -ne 0
chk "(d) centinela resembrado tras el fallo" test "$(centinela_de "$W")" = "$CENTINELA_PREFIJO"
FALLIDAS=("$W"/respuesta-fallida.*)
if [ -f "${FALLIDAS[0]}" ] && [ "$(cat "${FALLIDAS[0]}")" = "payload que fallara" ]; then
  ok "(d) payload fallido preservado como evidencia (nombre exclusivo)"
else
  mal "(d) payload fallido perdido"
fi
# Segundo turno tras el fallo: protocolo operativo.
( cd "$W" && str_replace respuesta.txt "$OLD_STR" "segundo turno tras fallo" )
rc=0; ( cd "$W" && BUZZ_FAKE_RC=0 bash "$HELPER" "$UUID" ) >/dev/null 2>&1 || rc=$?
chk "(d) el segundo turno publica con normalidad" \
  test "$rc" -eq 0 -a "$(cat "$BUZZ_CAPTURA/stdin.bin")" = "segundo turno tras fallo"

# ── (e): permisos del protocolo ─────────────────────────────────────────────
modo_resembrado="$(stat -c '%a' "$W/respuesta.txt")"
chk "(e) respuesta.txt resembrado en 0600 (real: $modo_resembrado)" test "$modo_resembrado" = "600"
modo_fallida="$(stat -c '%a' "${FALLIDAS[0]}")"
chk "(e) payload preservado en 0600 (real: $modo_fallida)" test "$modo_fallida" = "600"

# ── negativos de entrada del helper ─────────────────────────────────────────
W=$(workdir_nuevo caso-neg)
export BUZZ_CAPTURA="$TMP/cap-n"; mkdir -p "$BUZZ_CAPTURA"
rc=0; ( cd "$W" && bash "$HELPER" "$UUID" ) >/dev/null 2>&1 || rc=$?
chk "(neg) publicar la plantilla sin sustituir se rechaza" test "$rc" -ne 0
rc=0; ( cd "$W" && bash "$HELPER" "no-es-uuid" ) >/dev/null 2>&1 || rc=$?
chk "(neg) canal invalido se rechaza" test "$rc" -ne 0

# (neg) contenido SOLO-espacios (tabs y saltos, no solo espacio ASCII) se
# rechaza como vacio y nada se publica.
W=$(workdir_nuevo caso-blanco)
export BUZZ_CAPTURA="$TMP/cap-blanco"; mkdir -p "$BUZZ_CAPTURA"
OLD_STR="$(cat "$W/respuesta.txt")"
( cd "$W" && str_replace respuesta.txt "$OLD_STR" "$(printf '\t \n  \t')" )
rc=0; ( cd "$W" && BUZZ_FAKE_RC=0 bash "$HELPER" "$UUID" ) >/dev/null 2>&1 || rc=$?
chk "(neg) respuesta solo-espacios (tabs/saltos) se rechaza" test "$rc" -ne 0
chk "(neg) solo-espacios: nada llego al relay" test ! -f "$BUZZ_CAPTURA/stdin.bin"

if [ "$fallos" -eq 0 ]; then echo "probar-publicacion: TODO OK"; else echo "probar-publicacion: $fallos fallos"; exit 1; fi
