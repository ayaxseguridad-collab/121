#!/usr/bin/env bash
# test-medidores.sh — Tests HERMÉTICOS del sellador alineado y del canario de main (talent-ceo, ref 08).
#
# Sin red, sin ssh, sin incus, sin GitHub: repos git sintéticos con un `origin` local y un DOBLE de
# `run-gate-sealed.sh` (parámetro `--sellado`) que escribe un receipt sintético y sale con el rc que pida
# cada caso. El sellador se prueba con un perfil sintético y un doble de `date` por PATH.
#
# ── MÉTODO: UN VERDE Y UN MUTANTE POR GUARDA ───────────────────────────────────────────────────
# Cada comportamiento vive en una función `esc_*` que recibe la RUTA del script y devuelve 0 si el
# comportamiento es el esperado. El caso verde la corre sobre el script real; cada mutante la corre sobre una
# COPIA del script a la que se le cambia UNA cadena exacta (que debe aparecer una sola vez) y exige que
# el escenario FALLE. Un mutante que no enrojece su caso es un caso decorativo.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final exige que ejecutados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# TEST_SELLAR_SCRIPT y TEST_CANARIO_SCRIPT solo existen para demostrar la prueba de mejora (el sellador de ANTES
# enrojece S1 y S2) o un canario de juguete: la suite del skill siempre prueba los scripts reales.
SELLAR="${TEST_SELLAR_SCRIPT:-$ROOT/scripts/bus-sellar.sh}"
CANARIO="${TEST_CANARIO_SCRIPT:-$ROOT/scripts/canario-main.sh}"
REF08="$ROOT/references/08-vigias-y-medidores.md"

TOTAL_ESPERADO=59
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
DIAG=''
falla() { DIAG="$DIAG [$1]"; }
chk() { [ "$2" = "$3" ] || falla "$1: esperado='$2' obtenido='$3'"; }            # <nombre> <esperado> <obtenido>
limpia() { if declare -F limpia_lanzados >/dev/null; then limpia_lanzados; fi; }   # retira lo que el caso lanzó (ley de corte, más abajo)
check() { local n="$1"; shift; DIAG=''; if "$@"; then ok "$n"; else bad "$n$DIAG"; fi; limpia; }
mata() {   # <nombre> <escenario> <script-mutante>: el mutante DEBE enrojecer el escenario
  DIAG=''
  if "$2" "$3" >/dev/null 2>&1; then bad "mutante $1: NO enrojece su caso"; else ok "mutante $1: enrojece su caso"; fi
  limpia
}

T="$(mktemp -d "${TMPDIR:-/tmp}/tdmed.XXXXXX")" || exit 2
_fin() {
  limpia
  : "${T:?}"
  case "$T" in "${TMPDIR:-/tmp}"/tdmed.*) chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "$T" ;; esac
}
trap _fin EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"
FX_REAL_DATE="$(command -v date)"; export FX_REAL_DATE
CORTES_LOG="$T/cortes.log"   # lo que la suite VA a señalar, listado antes de cada señal
printf '== medidores: sellador alineado y canario de main ==\n'

# ═══ dobles ═══════════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/bin"
cat > "$T/bin/date" <<'__FIN_DBL_DATE__'
#!/usr/bin/env bash
if [ -n "${FX_AHORA-}" ] && [ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ]; then printf '%s\n' "$FX_AHORA"; exit 0; fi
exec "$FX_REAL_DATE" "$@"
__FIN_DBL_DATE__
chmod 755 "$T/bin/date"
DOBLE="$T/doble-sellado.sh"
cat > "$DOBLE" <<'__FIN_DBL_SELLADO__'
#!/usr/bin/env bash
# Doble de run-gate-sealed.sh: registra su invocación y escribe el receipt que pida FX_MODO, con el rc de FX_RC.
gate="$1"; shift
args=("$gate" "$@")
rec=''; sha=''; repo=''
while [ $# -gt 0 ]; do
  case "$1" in --receipts) rec="$2"; shift 2 ;; --sha) sha="$2"; shift 2 ;; --repo) repo="$2"; shift 2 ;; *) shift ;; esac
done
{ printf 'CALL'; printf ' <%s>' "${args[@]}"; printf '\n'; printf 'HEAD %s\n' "$(git -C "$repo" rev-parse HEAD 2>/dev/null)"; } >> "$FX_DIR/llamadas.log"
# Si un intento ANTERIOR dejó su pid, deja constancia de si seguía vivo cuando arrancó ESTE (kill -0 no señala nada).
if [ -r "$FX_DIR/pid-doble" ]; then
  st="$(ps -o stat= -p "$(cat "$FX_DIR/pid-doble")" 2>/dev/null)"
  if [ -n "$st" ] && [ "${st:0:1}" != Z ]; then echo PREVIO_VIVO=si; else echo PREVIO_VIVO=no; fi >> "$FX_DIR/llamadas.log"
fi
if [ -n "${FX_ESPERA-}" ]; then : > "$FX_DIR/en-curso"; while [ ! -e "$FX_ESPERA" ]; do sleep 0.1; done; fi
# El colgado lleva un argv[0] ÚNICO de esta suite: es lo que permite identificarlo antes de señalarlo.
if [ -n "${FX_CUELGA-}" ]; then printf '%s\n' "$$" > "$FX_DIR/pid-doble"; exec -a "fx-colgado:$FX_DIR" sleep 300; fi
ahora="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$rec"
receipt() {   # <result> <sha> <gate> <finished_at>
  printf '{"sha":"%s","gate_id":"%s","result":"%s","started_at":"%s","finished_at":"%s"}\n' "$2" "$3" "$1" "$ahora" "$4" > "$rec/unit.json"
}
case "${FX_MODO-pass}" in
  pass)     receipt PASS "$sha" "$gate" "$ahora"; exit "${FX_RC-0}" ;;
  fail)     receipt FAIL "$sha" "$gate" "$ahora"; exit "${FX_RC-1}" ;;
  skip)     receipt SKIP "$sha" "$gate" "$ahora"; exit "${FX_RC-0}" ;;
  otrosha)  receipt PASS 0000000000000000000000000000000000000000 "$gate" "$ahora"; exit "${FX_RC-0}" ;;
  otrogate) receipt PASS "$sha" otro-gate "$ahora"; exit "${FX_RC-0}" ;;
  viejo)    receipt PASS "$sha" "$gate" 2000-01-01T00:00:00Z; exit "${FX_RC-0}" ;;
  sinfin)   printf '{"sha":"%s","gate_id":"%s","result":"PASS"}\n' "$sha" "$gate" > "$rec/unit.json"; exit "${FX_RC-0}" ;;
  basura)   printf 'no es json{{{\n' > "$rec/unit.json"; exit "${FX_RC-0}" ;;
  sinrec)   printf 'unit rc=1\n'; exit "${FX_RC-0}" ;;
esac
exit 99
__FIN_DBL_SELLADO__
chmod 755 "$DOBLE"

# ═══ mutantes: copia del script con UNA cadena exacta cambiada ═══════════════════════════════════
mut_texto() {   # <origen> <destino> <viejo> <nuevo> -> 0 si <viejo> aparece EXACTAMENTE una vez
  local src rest
  src="$(cat "$1"; printf x)"; src="${src%x}"
  rest="${src//"$3"/}"
  [ $(( ${#src} - ${#rest} )) -eq "${#3}" ] || return 1
  printf '%s' "${src/"$3"/"$4"}" > "$2"
}
N_MUT=0
mutante() {   # <fichero-origen> <nombre> <viejo> <nuevo> <escenario> [dir-con-librerias]
  local origen="$1" nombre="$2" d
  N_MUT=$((N_MUT+1)); d="$T/mut/$N_MUT"; mkdir -p "$d"
  [ -z "${6-}" ] || cp "$6"/lib-*.sh "$d/"
  if ! mut_texto "$origen" "$d/${origen##*/}" "$3" "$4"; then bad "mutante $nombre: el patrón no aparece UNA vez"; return 0; fi
  chmod 755 "$d/${origen##*/}"
  mata "$nombre" "$5" "$d/${origen##*/}"
}

# ═══ sellador: perfil y escenarios ════════════════════════════════════════════════════════════════
YO="$(id -un)"; PERFIL="$T/perfil.tsv"; BUS="$T/bus.log"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10;rol=mando;acceso=local\n'
  printf 'ceo\tCEO\tmaq-alfa\t-\t-\troles=ceo;usuario=%s\n' "$YO"; } > "$PERFIL"
corre_sellar() {   # <script> <args…> -> OUT ERR RC
  local sc="$1"; shift
  OUT="$(env TA_PERFIL="$PERFIL" TA_BUS="$BUS" PATH="$T/bin:$PATH" bash "$sc" "$@" 2>"$T/err.txt")"; RC=$?
  ERR="$(cat "$T/err.txt")"
}
n_aviso() { printf '%s' "$ERR" | grep -c 'AVISO' || true; }
esc_s1() {   # aviso de hora por stderr, sin bloquear
  local sc="$1" caso reloj marca esp_aviso
  DIAG=''
  for caso in "08:31|MK1-0830|0" "14:00|MK2-0830|1" "14:00|MK3-8548|0" "14:00|MK4-2460|0" "00:02|MK5-2359|0" \
              "08:35|MK6-0830|0" "08:36|MK7-0830|1" "14:00|MK8|0" "14:00|MK9-830|0"; do
    reloj="${caso%%|*}"; marca="${caso#*|}"; esp_aviso="${marca#*|}"; marca="${marca%%|*}"
    : > "$BUS"
    FX_AHORA="2026-10-13T${reloj}:00Z" corre_sellar "$sc" --rol CEO --marcador "$marca"
    chk "s1 $marca reloj $reloj" "0|$esp_aviso" "$RC|$(n_aviso)"
    chk "s1 $marca sella" 1 "$(grep -c "marcador: $marca\]" "$BUS")"
  done
  [ -z "$DIAG" ]
}
esc_s1b() {   # el aviso no cambia la salida estándar y no se emite si el sello se rechaza antes
  local sc="$1" sin con
  DIAG=''; : > "$BUS"
  FX_AHORA='2026-10-13T08:31:00Z' corre_sellar "$sc" --rol CEO --marcador MKA-0830; sin="$OUT"
  FX_AHORA='2026-10-13T14:00:00Z' corre_sellar "$sc" --rol CEO --marcador MKB-0830; con="$OUT"
  chk "s1b stdout sin aviso" "bus: sellado MKA-0830 por CEO @ 2026-10-13T08:31:00Z" "$sin"
  chk "s1b stdout con aviso (idéntico en forma)" "bus: sellado MKB-0830 por CEO @ 2026-10-13T14:00:00Z" "$con"
  FX_AHORA='2026-10-13T14:00:00Z' corre_sellar "$sc" --rol CEO --marcador MKB-0830
  chk "s1b repetido: rc 3 y sin aviso" "3|0" "$RC|$(n_aviso)"
  [ -z "$DIAG" ]
}
esc_s2() {   # --src: vacío, inexistente, no regular -> rc 2 con motivo y el bus no cambia
  local sc="$1" antes
  DIAG=''; : > "$BUS"; printf 'previo\n' >> "$BUS"; antes="$(cat "$BUS")"
  : > "$T/src-vacio"; mkdir -p "$T/src-dir"; rm -f "$T/src-fifo"; mkfifo "$T/src-fifo"
  corre_sellar "$sc" --rol CEO --marcador S2A --src "$T/src-vacio"
  chk "s2 vacío" "2|1" "$RC|$(printf '%s' "$ERR" | grep -c 'vacío')"
  corre_sellar "$sc" --rol CEO --marcador S2B --src "$T/no-existe"
  chk "s2 inexistente" "2|1" "$RC|$(printf '%s' "$ERR" | grep -c 'no existe')"
  corre_sellar "$sc" --rol CEO --marcador S2C --src "$T/src-dir"
  chk "s2 directorio" "2|1" "$RC|$(printf '%s' "$ERR" | grep -c 'no es un fichero regular')"
  corre_sellar "$sc" --rol CEO --marcador S2D --src "$T/src-fifo"
  chk "s2 fifo" "2|1" "$RC|$(printf '%s' "$ERR" | grep -c 'no es un fichero regular')"
  chk "s2 el bus no cambia" "$antes" "$(cat "$BUS")"
  printf 'cuerpo del sello\n' > "$T/src-bueno"; ln -sf "$T/src-bueno" "$T/src-enlace"
  corre_sellar "$sc" --rol CEO --marcador S2E --src "$T/src-bueno"
  chk "s2 fichero bueno sella (rc 0, stdout intacto)" "0|1" "$RC|$(printf '%s' "$OUT" | grep -c '^bus: sellado S2E por CEO @ ')"
  corre_sellar "$sc" --rol CEO --marcador S2F --src "$T/src-enlace"
  chk "s2 symlink a fichero bueno sella" 0 "$RC"
  chk "s2 el contenido de --src NO se escribe en el bus" 0 "$(grep -c 'cuerpo del sello' "$BUS")"
  [ -z "$DIAG" ]
}
esc_s3() {   # alias del bus (con el bus VACÍO) -> rc 2 por IDENTIDAD, antes de la comprobación de vacío
  local sc="$1" a
  DIAG=''; : > "$BUS"
  ( cd "$T" && ln -sf bus.log alias-sym.log && ln -f bus.log alias-hard.log ) 2>/dev/null
  for a in "$BUS" "$T/./bus.log" "$T/sub/../bus.log" "$T/alias-sym.log" "$T/alias-hard.log"; do
    mkdir -p "$T/sub"
    corre_sellar "$sc" --rol CEO --marcador S3A --src "$a"
    chk "s3 alias ${a##*/}" "2|1|0" "$RC|$(printf '%s' "$ERR" | grep -c 'ES el bus')|$(printf '%s' "$ERR" | grep -c 'vacío')"
  done
  chk "s3 el bus no cambia" 0 "$(wc -c < "$BUS" | tr -d ' ')"
  [ -z "$DIAG" ]
}
check "S1 aviso de hora: -0830 con reloj 08:31 sin aviso; con 14:00 avisa; -8548 y -2460 no son horas; circular y borde de 5 min; rc 0" esc_s1 "$SELLAR"
check "S1b el aviso no cambia la salida estándar ni se emite en un sello rechazado" esc_s1b "$SELLAR"
check "S2 --src vacío, inexistente, directorio o fifo: rc 2 con motivo y el bus intacto; el bueno sella y su contenido no se escribe" esc_s2 "$SELLAR"
check "S3 alias del bus con el bus vacío: rc 2 por identidad, antes que la guarda de vacío" esc_s3 "$SELLAR"
SD="$ROOT/scripts"
mutante "$SELLAR" "sellador-sin-aviso" 'if [ "$dif" -gt 5 ]; then' 'if false; then' esc_s1 "$SD"
mutante "$SELLAR" "sellador-avisa-con-hora-inválida" '[ "$((10#$hh))" -lt 24 ] && [ "$((10#$mm))" -lt 60 ] || return 0' ':' esc_s1 "$SD"
mutante "$SELLAR" "sellador-avisa-por-stdout" '"$hhmm" "$rh" "$rn" "$dif" >&2' '"$hhmm" "$rh" "$rn" "$dif"' esc_s1b "$SD"
mutante "$SELLAR" "sellador-el-aviso-bloquea" '"$hhmm" "$rh" "$rn" "$dif" >&2' '"$hhmm" "$rh" "$rn" "$dif" >&2; exit 2' esc_s1 "$SD"
mutante "$SELLAR" "sellador-acepta-src-vacío" '[ -s "$src" ] ||' 'true ||' esc_s2 "$SD"
mutante "$SELLAR" "sellador-acepta-src-inexistente" '[ -e "$src" ] ||' 'true ||' esc_s2 "$SD"
mutante "$SELLAR" "sellador-acepta-src-no-regular" '[ -f "$src" ] ||' 'true ||' esc_s2 "$SD"
mutante "$SELLAR" "sellador-forma-antes-que-identidad" '  if bus_es_el_bus "$src" "$bus"; then' '  [ -s "$src" ] || { echo "bus: PRECOND: --src está vacío" >&2; exit 2; }
  if bus_es_el_bus "$src" "$bus"; then' esc_s3 "$SD"

# ═══ canario: mundo sintético y escenarios ═══════════════════════════════════════════════════════
mundo() {   # crea $W: up (origen), est (clon del canario), estado, manifiesto y carpeta de registros del doble
  W="$(mktemp -d "$T/w.XXXXXX")"
  git init -q -b main "$W/up"
  ( cd "$W/up" && printf 'a\n' > f && git add f && git commit -q -m A )
  git clone -q "$W/up" "$W/est" 2>/dev/null
  mkdir -p "$W/estado" "$W/fx"
  printf 'manifiesto sintetico\n' > "$W/manifest.conf"
}
avanza() { ( cd "$W/up" && printf '%s\n' "$1" >> f && git commit -q -am "$1" ); }
sha_up() { git -C "$W/up" rev-parse HEAD; }
corre_canario() {   # <script> [args…] -> OUT ERR RC  (un tick; las variables FX_* se heredan)
  local sc="$1"; shift
  OUT="$(FX_DIR="$W/fx" bash "$sc" --repo "$W/est" --estado "$W/estado" --runner runner-x --runner-repo /srv/repo \
         --manifest "$W/manifest.conf" --sellado "$DOBLE" --una-vez "$@" 2>"$T/err.txt")"; RC=$?
  ERR="$(cat "$T/err.txt")"
}
cuenta() { local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }   # 0 si el fichero no existe
n_llamadas() { cuenta '^CALL' "$W/fx/llamadas.log"; }
n_log() { cuenta '^CANARIO-FIN' "$W/estado/canario.log"; }
hecho() { grep -qxF -- "$1" "$W/estado/canario-hechos.txt"; }
n_wt() { find "$W/estado" -maxdepth 1 -name 'wt-canario-*' | wc -l | tr -d ' '; }
espera_fichero() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done; [ -e "$1" ]; }
# ── LEY DE CORTE de las propias pruebas ────────────────────────────────────────────────────────
# Nada se señala por un PID suelto ni por patrón (nada de `kill 0`, `pkill`, `pgrep` ni grupo derivado del padre).
# Lo que esta suite lanza se lanza en SESIÓN PROPIA (pid == pgid == sid, que queda registrado al lanzar) y SOLO se
# señala ese GRUPO REGISTRADO (`kill -SEÑAL -- -PGID`), tras listar sus miembros con `ps -o pid,pgid,sid,stat,args` y
# comprobar que el líder existe y que su línea de órdenes contiene el fragmento esperado. Si no coincide, NO se señala.
# Las funciones de este bloque se prueban con dobles de `ps` y `kill` (caso CORTE-T): no señalan nada real.
LANZADOS=()   # "g|pgid|fragmento": grupo registrado y fragmento que debe llevar la línea de órdenes de su líder
vivo() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [ -n "$s" ] && [ "${s:0:1}" != Z ]; }   # un zombi no cuenta como vivo
ident_lider() {   # <pid> <fragmento>: existe, es líder de su grupo (pid == pgid) y su línea de órdenes contiene el fragmento
  local p g a
  read -r p g a < <(ps -o pid=,pgid=,args= -p "$1" 2>/dev/null) || return 1
  [ "$p" = "$1" ] && [ "$g" = "$1" ] || return 1
  case "$a" in *"$2"*) return 0 ;; esac
  return 1
}
ident_marca() {   # <pid> <marca>: su línea de órdenes contiene la marca única de esta suite
  local a
  a="$(ps -o args= -p "$1" 2>/dev/null)" || return 1
  case "$a" in *"$2"*) return 0 ;; esac
  return 1
}
miembros() {   # <pgid>: "pid línea" de los miembros VIVOS de ese grupo Y de esa sesión (el grupo se lanzó con setsid: sid == pgid)
  local p g s st a
  while read -r p g s st a; do
    if [ "$g" = "$1" ] && [ "$s" = "$1" ] && [ "${st:0:1}" != Z ]; then printf '%s %s\n' "$p" "$a"; fi
  done < <(ps -eo pid=,pgid=,sid=,stat=,args= 2>/dev/null)
  return 0
}
verifica_grupo() {   # <pgid> <fragmento>: el líder existe y lleva el fragmento, y el grupo tiene miembros; los LISTA antes de nada
  local lineas
  ident_lider "$1" "$2" || return 1
  lineas="$(miembros "$1")"
  [ -n "$lineas" ] || return 1
  printf 'CORTE grupo=%s miembros: %s\n' "$1" "$(printf '%s' "$lineas" | tr '\n' ';')" >> "${CORTES_LOG:-/dev/null}"
  return 0
}
senal() {   # <SEÑAL> <pgid> <fragmento>: señala SOLO ese grupo registrado y SOLO tras verificarlo
  verifica_grupo "$2" "$3" || return 1
  kill -"$1" -- "-$2" 2>/dev/null
}
registra_grupo() {   # <pid> <fragmento>: registra el PGID que ese proceso tiene AHORA (leído con ps, no derivado del padre)
  local g
  g="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"
  case "$g" in ''|*[!0-9]*) return 1 ;; esac
  LANZADOS+=("g|$g|$2")
}
limpia_lanzados() {
  local e id frag
  for e in "${LANZADOS[@]-}"; do
    [ -n "$e" ] || continue
    id="${e#*|}"; frag="${id#*|}"; id="${id%%|*}"
    if verifica_grupo "$id" "$frag"; then
      kill -TERM -- "-$id" 2>/dev/null; sleep 0.3
      # El KILL exige VOLVER a verificar el líder y a listar el grupo: tras el TERM pudo morir y su PGID reutilizarlo otro.
      if verifica_grupo "$id" "$frag"; then kill -KILL -- "-$id" 2>/dev/null; fi
    fi
  done
  LANZADOS=()
  return 0
}
espera_muerto() { local n=0; while vivo "$1" && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done; ! vivo "$1"; }
esc_d1() {   # main avanza y unit pasa -> VERDE, CANARIO-FIN, worktree retirado, invocación exacta del gate
  local sc="$1" sha s9 llamada
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  corre_canario "$sc"
  chk "d1 rc y línea" "0|CANARIO-MAIN-$s9-VERDE gate=unit rc=0 result=PASS" "$RC|$OUT"
  chk "d1 registro CANARIO-FIN" 1 "$(grep -cE "^CANARIO-FIN $s9 [0-9]{2}:[0-9]{2}:[0-9]{2}Z rc=0 result=PASS$" "$W/estado/canario.log")"
  hecho "$sha" || falla "d1 el sha debe quedar hecho"
  chk "d1 worktree retirado (dir y registro)" "0|1" "$(n_wt)|$(git -C "$W/est" worktree list | wc -l | tr -d ' ')"
  llamada="$(grep '^CALL' "$W/fx/llamadas.log")"
  chk "d1 una sola invocación" 1 "$(n_llamadas)"
  for esperado in '<unit>' '<--runner> <runner-x>' '<--runner-repo> </srv/repo>' "<--run-group> <rgcan$s9>" "<--sha> <$sha>" \
                  "<--base> <$sha>" '<--pr> <0>' "<--manifest> <$W/manifest.conf>" "<--receipts> <$W/estado/rec/$s9." \
                  "<--repo> <$W/estado/wt-canario-$s9>"; do
    case "$llamada" in *"$esperado"*) : ;; *) falla "d1 la invocación no lleva $esperado" ;; esac
  done
  chk "d1 el gate corrió sobre el sha, en el worktree" "HEAD $sha" "$(grep '^HEAD' "$W/fx/llamadas.log")"
  [ -z "$DIAG" ]
}
esc_d2() {   # unit falla -> ROJO, mismo registro
  local sc="$1" sha s9
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  FX_MODO=fail FX_RC=1 corre_canario "$sc"
  chk "d2 rc y línea" "1|CANARIO-MAIN-$s9-ROJO gate=unit rc=1 result=FAIL" "$RC|$OUT"
  chk "d2 registro" 1 "$(grep -cE "^CANARIO-FIN $s9 [0-9:]{8}Z rc=1 result=FAIL$" "$W/estado/canario.log")"
  hecho "$sha" || falla "d2 un ROJO también deja el sha hecho"
  [ -z "$DIAG" ]
}
esc_d3() {   # el mismo sha dos veces: la segunda no corre nada; un sha nuevo sí
  local sc="$1"
  DIAG=''; mundo; avanza B
  corre_canario "$sc"; corre_canario "$sc"
  chk "d3 segunda vez: nada, rc 0" "0||1|1" "$RC|$OUT|$(n_llamadas)|$(n_log)"
  avanza C; corre_canario "$sc"
  chk "d3 un sha nuevo SÍ corre" "2|2" "$(n_llamadas)|$(n_log)"
  [ -z "$DIAG" ]
}
esc_d4() {   # rc 2 / 3 / tope del gate -> NO-MEDIDO aunque haya un receipt fresco que diga otra cosa; no queda hecho
  local sc="$1" sha s9 caso modo rc motivo
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  for caso in "pass|2|rc-2" "fail|3|rc-3" "pass|3|rc-3" "fail|2|rc-2"; do
    modo="${caso%%|*}"; rc="${caso#*|}"; motivo="${rc#*|}"; rc="${rc%%|*}"
    FX_MODO="$modo" FX_RC="$rc" corre_canario "$sc"
    chk "d4 $modo rc=$rc" "3|1" "$RC|$(printf '%s' "$OUT" | grep -c "^CANARIO-MAIN-$s9-NO-MEDIDO gate=unit motivo=$motivo rc=$rc ")"
    hecho "$sha" && falla "d4 $modo rc=$rc: el sha NO debe quedar hecho"
  done
  chk "d4 registro" "4|4" "$(grep -c 'result=NO-MEDIDO$' "$W/estado/canario.log")|$(n_log)"
  FX_CUELGA=1 corre_canario "$sc" --tope 1
  chk "d4 tope del gate agotado" "3|1" "$RC|$(printf '%s' "$OUT" | grep -c "motivo=tope-1s rc=124 ")"
  corre_canario "$sc"
  chk "d4 al arreglarse el instrumento se reintenta el mismo sha" "0|1" "$RC|$(printf '%s' "$OUT" | grep -c "^CANARIO-MAIN-$s9-VERDE ")"
  hecho "$sha" || falla "d4 tras el VERDE queda hecho"
  [ -z "$DIAG" ]
}
esc_d5() {   # receipt ausente, de otro sha/gate, anterior a T0, ilegible o incoherente con el rc -> NO-MEDIDO
  local sc="$1" sha caso modo rc motivo
  DIAG=''; mundo; avanza B; sha="$(sha_up)"
  for caso in "sinrec|0|receipt-ausente" "sinrec|1|receipt-ausente" "otrosha|0|receipt-otro-sha" "otrogate|0|receipt-otro-gate" \
              "viejo|0|receipt-anterior-a-T0" "viejo|1|receipt-anterior-a-T0" "sinfin|0|receipt-sin-finished_at" \
              "basura|0|receipt-ilegible" "skip|0|incoherente-rc0-receipt-SKIP" "pass|1|incoherente-rc1-receipt-PASS" \
              "fail|0|incoherente-rc0-receipt-FAIL"; do
    modo="${caso%%|*}"; rc="${caso#*|}"; motivo="${rc#*|}"; rc="${rc%%|*}"
    FX_MODO="$modo" FX_RC="$rc" corre_canario "$sc"
    chk "d5 $modo rc=$rc" "3|1|0" "$RC|$(printf '%s' "$OUT" | grep -c -e "-NO-MEDIDO gate=unit motivo=$motivo rc=$rc ")|$(printf '%s' "$OUT" | grep -cE -e '-(VERDE|ROJO) ')"
    hecho "$sha" && falla "d5 $modo rc=$rc: no puede quedar hecho"
  done
  [ -z "$DIAG" ]
}
lanza_canario() {   # <script> [args…]: lo lanza en SESIÓN PROPIA (pid == pgid), lo registra para el cierre y deja su pid en $PID_C
  local sc="$1"; shift
  FX_DIR="$W/fx" setsid bash "$sc" --repo "$W/est" --estado "$W/estado" --runner runner-x --runner-repo /srv/repo \
    --manifest "$W/manifest.conf" --sellado "$DOBLE" "$@" > "$W/out1.txt" 2> "$W/err1.txt" &
  PID_C=$!
  LANZADOS+=("g|$PID_C|canario-main.sh")
}
esc_d6() {   # el proceso muere a mitad de la corrida: el tick siguiente reintenta Y el gate del intento cortado ya no está vivo
  local sc="$1" sha s9 gpid
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  FX_CUELGA=1 lanza_canario "$sc" --una-vez
  if ! espera_fichero "$W/fx/pid-doble"; then falla "d6 el gate no arrancó"; limpia_lanzados; wait "$PID_C" 2>/dev/null; return 1; fi
  gpid="$(cat "$W/fx/pid-doble")"
  registra_grupo "$gpid" doble-sellado.sh || falla "d6 no se pudo registrar el grupo del gate"
  senal KILL "$PID_C" canario-main.sh || falla "d6 el canario no es el líder lanzado por la suite: no se señala"
  wait "$PID_C" 2>/dev/null
  vivo "$gpid" || falla "d6 (premisa) el gate del intento cortado debía seguir vivo tras matar al canario"
  hecho "$sha" && falla "d6 un sha cortado a mitad NO puede quedar hecho"
  corre_canario "$sc"     # un gate superviviente con el candado haría que este tick saliera rc 2
  chk "d6 el tick siguiente reintenta ese sha" "0|1" "$RC|$(printf '%s' "$OUT" | grep -c "^CANARIO-MAIN-$s9-VERDE ")"
  hecho "$sha" || falla "d6 tras el reintento queda hecho"
  chk "d6 el gate del intento cortado NO estaba vivo cuando arrancó el nuevo" "PREVIO_VIVO=no" "$(grep '^PREVIO_VIVO' "$W/fx/llamadas.log" | tail -n 1)"
  vivo "$gpid" && falla "d6 el gate del intento cortado sigue vivo tras el nuevo VERDE"
  chk "d6 no quedan worktrees ni registro de gate" "0|1|no" "$(n_wt)|$(git -C "$W/est" worktree list | wc -l | tr -d ' ')|$([ -e "$W/estado/gate-activo" ] && echo si || echo no)"
  [ -z "$DIAG" ]
}
esc_d7() {   # dos canarios sobre el mismo estado: el segundo sale rc 2 y ningún sha se corre dos veces
  local sc="$1" pid rc1
  DIAG=''; mundo; avanza B
  FX_ESPERA="$W/fx/go" lanza_canario "$sc" --una-vez; pid="$PID_C"
  if ! espera_fichero "$W/fx/en-curso"; then falla "d7 el primer canario no arrancó"; limpia_lanzados; wait "$pid" 2>/dev/null; return 1; fi
  corre_canario "$sc"
  chk "d7 el segundo sale rc 2 por candado y no invoca el gate (queda UNA invocación, la del primero)" "2|1|1" \
    "$RC|$(printf '%s' "$ERR" | grep -c 'otro canario')|$(n_llamadas)"
  : > "$W/fx/go"; wait "$pid"; rc1=$?
  chk "d7 el primero termina VERDE" "0|1|1" "$rc1|$(grep -c -- '-VERDE ' "$W/out1.txt")|$(n_llamadas)"
  [ -z "$DIAG" ]
}
esc_fetch() {   # un fetch que falla: NO-MEDIDO sin sha, rc 3, sin invocar el gate
  local sc="$1"
  DIAG=''; mundo; git -C "$W/est" remote set-url origin "$W/no-existe"
  corre_canario "$sc"
  chk "fetch-fallo" "3|CANARIO-MAIN-NO-MEDIDO fetch-fallo|0|0" "$RC|$OUT|$(n_llamadas)|$(n_log)"
  [ -z "$DIAG" ]
}
esc_pre() {   # precondiciones: rc 2 con motivo y nada tocado
  local sc="$1" base f i args
  DIAG=''; mundo
  base=(--repo "$W/est" --estado "$W/estado2" --runner r1 --runner-repo /srv/x --manifest "$W/manifest.conf" --sellado "$DOBLE" --una-vez)
  for f in --repo --estado --runner --runner-repo --manifest; do
    args=(); i=0
    while [ "$i" -lt "${#base[@]}" ]; do
      if [ "${base[$i]}" = "$f" ]; then i=$((i+2)); continue; fi
      args+=("${base[$i]}"); i=$((i+1))
    done
    OUT="$(timeout 20 bash "$sc" "${args[@]}" 2>"$T/err.txt")"; RC=$?; ERR="$(cat "$T/err.txt")"
    chk "pre falta $f" "2|1" "$RC|$(printf '%s' "$ERR" | grep -c "falta $f")"
  done
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --cada 5 2>"$T/err.txt")"; RC=$?; chk "pre --una-vez y --cada" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]:0:${#base[@]}-1}" 2>"$T/err.txt")"; RC=$?; chk "pre sin modo" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --runner 'con espacio' 2>"$T/err.txt")"; RC=$?; chk "pre runner con espacio" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --runner-repo relativa 2>"$T/err.txt")"; RC=$?; chk "pre runner-repo relativo" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --tope 0 2>"$T/err.txt")"; RC=$?; chk "pre tope 0" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --sellado "$W/no-existe.sh" 2>"$T/err.txt")"; RC=$?; chk "pre sellado inexistente" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" "${base[@]}" --nada 2>"$T/err.txt")"; RC=$?; chk "pre argumento desconocido" 2 "$RC"
  OUT="$(timeout 20 bash "$sc" --repo 2>"$T/err.txt")"; RC=$?; chk "pre opción sin valor (no es un bucle)" 2 "$RC"
  ln -s "$W/estado" "$W/lnk-estado"
  OUT="$(timeout 20 bash "$sc" --repo "$W/est" --estado "$W/lnk-estado" --runner r1 --runner-repo /srv/x --manifest "$W/manifest.conf" --sellado "$DOBLE" --una-vez 2>"$T/err.txt")"; RC=$?
  chk "pre estado symlink" 2 "$RC"
  ln -s "$W/manifest.conf" "$W/lnk-manifest"
  OUT="$(timeout 20 bash "$sc" --repo "$W/est" --estado "$W/estado" --runner r1 --runner-repo /srv/x --manifest "$W/lnk-manifest" --sellado "$DOBLE" --una-vez 2>"$T/err.txt")"; RC=$?
  chk "pre manifiesto symlink" 2 "$RC"
  ln -s "$W/manifest.conf" "$W/estado/canario-hechos.txt"
  OUT="$(timeout 20 bash "$sc" --repo "$W/est" --estado "$W/estado" --runner r1 --runner-repo /srv/x --manifest "$W/manifest.conf" --sellado "$DOBLE" --una-vez 2>"$T/err.txt")"; RC=$?
  chk "pre hechos symlink" 2 "$RC"
  chk "pre nada tocado (estado2 no se crea)" 0 "$(ls "$W/estado2" 2>/dev/null | wc -l | tr -d ' ')"
  OUT="$(timeout 20 bash "$sc" --help 2>/dev/null)"; RC=$?
  chk "pre --help: rc 0 y solo comentarios" "0|0" "$RC|$(printf '%s\n' "$OUT" | grep -vc '^#')"
  [ -z "$DIAG" ]
}
esc_loop() {   # --cada: repite ticks, atiende un sha nuevo y se detiene limpio por SIGTERM
  local sc="$1" pid n
  DIAG=''; mundo; avanza B
  lanza_canario "$sc" --cada 1; pid="$PID_C"
  n=0; while [ "$(n_log)" -lt 1 ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done
  avanza C
  n=0; while [ "$(n_log)" -lt 2 ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done
  senal TERM "$pid" canario-main.sh || falla "loop el canario no es el líder lanzado por la suite: no se señala"
  wait "$pid" 2>/dev/null
  chk "loop dos shas, dos veredictos, una invocación por sha" "2|2|2" "$(n_log)|$(grep -c -- '-VERDE ' "$W/out1.txt")|$(n_llamadas)"
  chk "loop sin worktrees tras detenerlo" 0 "$(n_wt)"
  [ -z "$DIAG" ]
}
esc_d11() {   # M2: un receipt PASS residual de un intento anterior (rc 2) NO es el veredicto del intento nuevo (rc 0 sin receipt)
  local sc="$1" sha s9 r1 r2 clave
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  clave='<--receipts> <'
  # Reloj FIJO para canario y doble: ambos intentos comparten el segundo, que es lo que el filtro `finished_at >= T0` no separa.
  PATH="$T/bin:$PATH" FX_AHORA='2026-10-13T08:00:00Z' FX_MODO=pass FX_RC=2 corre_canario "$sc"
  chk "d11 intento 1 (PASS residual, rc 2): NO-MEDIDO y pendiente" "3|1|no" "$RC|$(printf '%s' "$OUT" | grep -c -e "-NO-MEDIDO gate=unit motivo=rc-2 rc=2 ")|$(hecho "$sha" && echo si || echo no)"
  PATH="$T/bin:$PATH" FX_AHORA='2026-10-13T08:00:00Z' FX_MODO=sinrec FX_RC=0 corre_canario "$sc"
  chk "d11 intento 2 (rc 0 sin receipt, mismo segundo): NO-MEDIDO receipt-ausente, nunca VERDE" "3|1|0|no" \
    "$RC|$(printf '%s' "$OUT" | grep -c -e "-NO-MEDIDO gate=unit motivo=receipt-ausente rc=0 ")|$(printf '%s' "$OUT" | grep -c -e '-VERDE ')|$(hecho "$sha" && echo si || echo no)"
  r1="$(grep '^CALL' "$W/fx/llamadas.log" | head -n 1 | grep -o "${clave}[^>]*")"; r2="$(grep '^CALL' "$W/fx/llamadas.log" | tail -n 1 | grep -o "${clave}[^>]*")"
  [ -n "$r1" ] && [ "$r1" != "$r2" ] || falla "d11 cada intento debe usar su PROPIO directorio de receipts (1='$r1' 2='$r2')"
  [ -z "$DIAG" ]
}
esc_d12() {   # M3: TERM durante el gate -> el gate del canario (registrado en su propio grupo) no queda vivo
  local sc="$1" sha gpid pg reg
  DIAG=''; mundo; avanza B; sha="$(sha_up)"
  FX_CUELGA=1 lanza_canario "$sc" --una-vez
  if ! espera_fichero "$W/fx/pid-doble"; then falla "d12 el gate no arrancó"; limpia_lanzados; wait "$PID_C" 2>/dev/null; return 1; fi
  gpid="$(cat "$W/fx/pid-doble")"; registra_grupo "$gpid" doble-sellado.sh || falla "d12 no se pudo registrar el grupo del gate"
  reg="$(cat "$W/estado/gate-activo" 2>/dev/null)"; pg="${reg%% *}"
  case "$pg" in ''|*[!0-9]*) falla "d12 el gate no tiene su grupo REGISTRADO en gate-activo ('$reg')"; pg='' ;; esac
  if [ -n "$pg" ]; then
    ident_lider "$pg" doble-sellado.sh || falla "d12 el grupo registrado no es el del gate (líder de su grupo con el lanzador sellado)"
    [ "$pg" != "$PID_C" ] || falla "d12 el gate comparte grupo con el canario: no se puede cortar por separado"
  fi
  senal TERM "$PID_C" canario-main.sh || falla "d12 el canario no es el líder lanzado por la suite: no se señala"
  wait "$PID_C" 2>/dev/null
  espera_muerto "$gpid" || falla "d12 el gate sigue vivo tras el TERM del canario"
  if [ -n "$pg" ]; then chk "d12 el grupo registrado del gate quedó sin miembros" "" "$(miembros "$pg" | tr '\n' ' ')"; fi
  chk "d12 sin registro de gate, sin worktrees y el sha sigue pendiente" "no|0|no" \
    "$([ -e "$W/estado/gate-activo" ] && echo si || echo no)|$(n_wt)|$(hecho "$sha" && echo si || echo no)"
  [ -z "$DIAG" ]
}
esc_d13() {   # M3: un registro de gate cuyo grupo NO es el gate (otro proceso, mismo pgid) no se señala: se descarta
  local sc="$1" sha s9 ajeno n=0
  DIAG=''; mundo; avanza B; sha="$(sha_up)"; s9="${sha:0:9}"
  setsid bash -c 'exec -a "fx-ajeno:$1" sleep 300' _ "$W" > /dev/null 2>&1 &
  ajeno=$!; LANZADOS+=("g|$ajeno|fx-ajeno:$W")
  while ! ident_marca "$ajeno" "fx-ajeno:$W" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  ident_marca "$ajeno" "fx-ajeno:$W" || { falla "d13 el proceso ajeno no arrancó"; return 1; }
  printf '%s %s rgcan%s\n' "$ajeno" "$s9" "$s9" > "$W/estado/gate-activo"
  corre_canario "$sc"
  chk "d13 el tick sigue su curso: VERDE" "0|1" "$RC|$(printf '%s' "$OUT" | grep -c "^CANARIO-MAIN-$s9-VERDE ")"
  vivo "$ajeno" || falla "d13 se señaló a un proceso que NO es el gate (identidad sin verificar)"
  chk "d13 el registro obsoleto se retira" "no" "$([ -e "$W/estado/gate-activo" ] && echo si || echo no)"
  [ -z "$DIAG" ]
}
esc_d14() {   # M3-R2: el sleep del bucle va en su PROPIA sesión (grupo registrado) y un TERM al canario lo retira
  local sc="$1" pid sl='' sp n=0 p pp g s a
  DIAG=''; mundo; avanza B
  lanza_canario "$sc" --cada 300; pid="$PID_C"
  while [ -z "$sl" ] && [ "$n" -lt 100 ]; do
    while read -r p pp g s a; do
      if [ "$pp" = "$pid" ] && [ "$a" = "sleep 300" ]; then sl="$p"; sp="$g|$s"; fi
    done < <(ps -eo pid=,ppid=,pgid=,sid=,args= 2>/dev/null)
    [ -n "$sl" ] || { sleep 0.1; n=$((n+1)); }
  done
  [ -n "$sl" ] || { falla "d14 el canario no llegó a dormir"; senal KILL "$pid" canario-main.sh; wait "$pid" 2>/dev/null; return 1; }
  LANZADOS+=("g|$sl|sleep 300")
  chk "d14 el sleep es líder de su propia sesión y NO comparte grupo con el canario" "$sl|$sl|si" "${sp%%|*}|${sp##*|}|$([ "${sp%%|*}" != "$pid" ] && echo si || echo no)"
  senal TERM "$pid" canario-main.sh || falla "d14 el canario no es el líder lanzado por la suite: no se señala"
  wait "$pid" 2>/dev/null
  espera_muerto "$sl" || falla "d14 el sleep del bucle sigue vivo tras el TERM al canario"
  [ -z "$DIAG" ]
}
# ── Pruebas de la ley de corte con DOBLES de `ps` y `kill`: no se señala NADA real ──────────────────
extrae_fn() {   # <fichero> <nombre>: texto de la función `nombre() {` hasta su `}` en columna 0
  local l dentro=0 txt=''
  while IFS= read -r l; do
    if [ "$dentro" = 0 ]; then
      case "$l" in "$2() {"*) dentro=1; txt="$l"$'\n' ;; esac
    else
      txt="$txt$l"$'\n'
      [ "$l" != "}" ] || break
    fi
  done < "$1"
  printf '%s' "$txt"
}
dobles_ps_kill() {   # SOLO dentro de un ( … ): define ps, kill y sleep falsos; ps lee $FAKE_PS, kill anota en $FAKE_KLOG
  ps() {
    local modo='' pid='' p g s st a
    while [ $# -gt 0 ]; do
      case "$1" in -p) pid="$2"; shift 2 ;; -eo) modo=todos; shift 2 ;; -o) modo="$2"; shift 2 ;; *) shift ;; esac
    done
    while read -r p g s st a; do
      [ -n "$p" ] || continue
      [ -z "$pid" ] || [ "$p" = "$pid" ] || continue
      case "$modo" in
        todos) printf '%s %s %s %s %s\n' "$p" "$g" "$s" "$st" "$a" ;;
        pid=,pgid=,args=) printf '%s %s %s\n' "$p" "$g" "$a" ;;
        pid=,pgid=,sid=,args=) printf '%s %s %s %s\n' "$p" "$g" "$s" "$a" ;;
        pgid=) printf '%s\n' "$g" ;;
        stat=) printf '%s\n' "$st" ;;
      esac
    done <<<"$FAKE_PS"
  }
  # Tras un TERM, si el caso define FAKE_TRAS_TERM, la tabla de ps CAMBIA (el líder murió o su PGID lo reutilizó otro grupo).
  kill() { printf '%s\n' "$*" >> "$FAKE_KLOG"; case "$*" in -TERM*) [ -z "${FAKE_TRAS_TERM+x}" ] || FAKE_PS="$FAKE_TRAS_TERM" ;; esac; }
  sleep() { :; }
}
esc_corte_c() {   # <canario>: _corta_sueno señala SOLO el grupo registrado y SOLO si todos sus miembros son un `sleep <n>`
  local sc="$1" src klog="$T/klog-c"
  DIAG=''
  src="$(extrae_fn "$sc" _miembros)"$'\n'"$(extrae_fn "$sc" _corta_sueno)"   # $(…) recorta el salto final: se une con uno explícito
  [ -n "$src" ] || { falla "no se extrajeron _miembros/_corta_sueno de $sc"; return 1; }
  caso() {   # <tabla ps> -> "rc=<rc>|<lo señalado>"
    : > "$klog"
    # shellcheck disable=SC2034   # SUENO_PGID la lee la función evaluada
    ( dobles_ps_kill; FAKE_PS="$1"; FAKE_KLOG="$klog"; eval "$src"; SUENO_PGID=4242; _corta_sueno 2>/dev/null; printf 'rc=%s\n' "$?" > "$klog.rc" )
    printf '%s|%s' "$(cat "$klog.rc")" "$(tr '\n' ';' < "$klog")"
  }
  chk "corte-c sleep propio: señal al GRUPO (argumento negativo), una vez" "rc=0|-TERM -- -4242;" "$(caso '4242 4242 4242 S sleep 300')"
  chk "corte-c un miembro que no es un sleep: no se señala a nadie" "rc=1|" "$(caso '4242 4242 4242 S bash -c cosa-ajena')"
  chk "corte-c grupo mixto (sleep + ajeno): no se señala a nadie" "rc=1|" "$(caso $'4242 4242 4242 S sleep 300\n4243 4242 4242 S rm -rf x')"
  chk "corte-c un sleep de OTRA sesión con el mismo pgid no es del grupo registrado: nada que señalar" "rc=0|" "$(caso '4242 4242 9999 S sleep 300')"
  chk "corte-c grupo vacío: nada" "rc=0|" "$(caso '')"
  [ -z "$DIAG" ]
}
funciones_del_test() {   # texto de las funciones de corte de ESTA suite
  local f
  for f in ident_lider miembros verifica_grupo senal limpia_lanzados; do extrae_fn "${BASH_SOURCE[0]}" "$f"; done
}
esc_corte_t() {   # <fichero con las funciones de corte de la suite>: señalan SOLO el grupo registrado, verificado y listado
  local fn="$1" src klog="$T/klog-t" tabla propia ajena lista
  DIAG=''
  src="$(cat "$fn")"
  tabla=$'5000 5000 5000 S bash /x/canario-main.sh --una-vez\n5001 5000 5000 S git fetch'
  propia='canario-main.sh'; ajena='otra-cosa'
  caso() {   # <tabla> <orden…> -> "rc=<rc>|<lo señalado>|<listado>"
    local t="$1"; shift
    : > "$klog"; : > "$klog.lista"
    ( dobles_ps_kill; FAKE_PS="$t"; FAKE_KLOG="$klog"; CORTES_LOG="$klog.lista"; LANZADOS=(); [ -z "${TRAS_TERM+x}" ] || FAKE_TRAS_TERM="$TRAS_TERM"
      eval "$src"; "$@" 2>/dev/null; printf 'rc=%s\n' "$?" > "$klog.rc" )
    printf '%s|%s|%s' "$(cat "$klog.rc")" "$(tr '\n' ';' < "$klog")" "$(tr '\n' ';' < "$klog.lista")"
  }
  lanzados() { LANZADOS=("g|5000|$1"); limpia_lanzados; }
  chk "corte-t senal: líder y fragmento coinciden → señal al GRUPO y miembros listados antes" \
      "rc=0|-TERM -- -5000;|CORTE grupo=5000 miembros: 5000 bash /x/canario-main.sh --una-vez;5001 git fetch;" "$(caso "$tabla" senal TERM 5000 "$propia")"
  chk "corte-t senal: el fragmento no coincide → ninguna señal" "rc=1||" "$(caso "$tabla" senal TERM 5000 "$ajena")"
  chk "corte-t senal: el pgid no tiene líder (el pid 5000 no existe) → ninguna señal" "rc=1||" "$(caso $'5001 5000 5000 S bash /x/canario-main.sh' senal TERM 5000 "$propia")"
  lista='CORTE grupo=5000 miembros: 5000 bash /x/canario-main.sh --una-vez;5001 git fetch;'
  chk "corte-t limpieza: grupo verificado → TERM y, si resiste, KILL, siempre al grupo y con DOS listados (uno antes de cada señal)" \
      "rc=0|-TERM -- -5000;-KILL -- -5000;|$lista$lista" "$(caso "$tabla" lanzados "$propia")"
  # La tabla CAMBIA tras el TERM: el KILL exige volver a verificar el líder y listar; si ya no es el registrado, NO hay KILL.
  TRAS_TERM=$'5001 5000 5000 S git fetch'
  chk "corte-t limpieza: el líder desaparece tras el TERM (queda un miembro suelto) → sin KILL, un solo listado" \
      "rc=0|-TERM -- -5000;|$lista" "$(caso "$tabla" lanzados "$propia")"
  TRAS_TERM=$'5000 5000 5000 S sleep 99\n5001 5000 5000 S git fetch'
  chk "corte-t limpieza: su PGID lo reutiliza otro comando tras el TERM → sin KILL, un solo listado" \
      "rc=0|-TERM -- -5000;|$lista" "$(caso "$tabla" lanzados "$propia")"
  TRAS_TERM=''
  chk "corte-t limpieza: el grupo desaparece entero tras el TERM → sin KILL, un solo listado" \
      "rc=0|-TERM -- -5000;|$lista" "$(caso "$tabla" lanzados "$propia")"
  unset TRAS_TERM
  chk "corte-t limpieza: líder que no es lo registrado → ninguna señal" "rc=0||" "$(caso "$tabla" lanzados "$ajena")"
  [ -z "$DIAG" ]
}
check "D1 main avanza y unit pasa: VERDE, CANARIO-FIN, worktree retirado e invocación exacta del gate" esc_d1 "$CANARIO"
check "D2 unit falla (rc 1, receipt FAIL): ROJO con el mismo registro" esc_d2 "$CANARIO"
check "D3 el mismo sha en dos ticks no corre nada la segunda vez; un sha nuevo sí" esc_d3 "$CANARIO"
check "D4 rc 2, rc 3 o tope del gate: NO-MEDIDO aunque el receipt fresco diga otra cosa; el sha no queda hecho y se reintenta" esc_d4 "$CANARIO"
check "D5 sin receipt, de otro sha o gate, anterior a T0, ilegible, SKIP o incoherente con el rc: NO-MEDIDO, nunca rojo ni verde" esc_d5 "$CANARIO"
check "D6 el proceso muere a mitad: el tick siguiente reintenta, y el gate huérfano no retiene el candado" esc_d6 "$CANARIO"
check "D7 dos canarios a la vez sobre el mismo estado: el segundo rc 2 y ningún sha dos veces" esc_d7 "$CANARIO"
check "D8 un fetch que falla: NO-MEDIDO sin sha, rc 3, sin invocar el gate" esc_fetch "$CANARIO"
check "D9 precondiciones: argumentos, charsets, symlinks y --help, todo rc 2 sin tocar nada" esc_pre "$CANARIO"
check "D10 bucle --cada: dos shas, dos veredictos y parada limpia por SIGTERM" esc_loop "$CANARIO"
check "D11 un receipt PASS residual de un intento anterior (rc 2) no da VERDE a un intento nuevo rc 0 sin receipt en el mismo segundo" esc_d11 "$CANARIO"
check "D12 TERM durante el gate: el gate registrado en su propio grupo no queda vivo, ni registro, ni worktree" esc_d12 "$CANARIO"
check "D13 un registro de gate con un grupo que no es el gate no se señala: se descarta y el tick sigue" esc_d13 "$CANARIO"
check "D14 el sleep del bucle va en su propia sesión (grupo registrado) y un TERM al canario lo retira" esc_d14 "$CANARIO"
check "CORTE-C el corte del sleep del canario, con dobles de ps y kill: solo el grupo registrado y solo si todos sus miembros son un sleep" esc_corte_c "$CANARIO"
FUNCIONES_TEST="$T/funciones-corte.sh"; funciones_del_test > "$FUNCIONES_TEST"
check "CORTE-T las funciones de corte de esta suite, con dobles de ps y kill: solo el grupo registrado, verificado y listado" esc_corte_t "$FUNCIONES_TEST"
mutante "$CANARIO" "canario-marca-antes-de-correr" '# MARCA-DE-HECHO-SOLO-TRAS-VEREDICTO:' 'printf '"'"'%s\n'"'"' "$sha" >> "$hechos" #' esc_d6
mutante "$CANARIO" "canario-marca-antes-y-el-no-medido-no-reintenta" '# MARCA-DE-HECHO-SOLO-TRAS-VEREDICTO:' 'printf '"'"'%s\n'"'"' "$sha" >> "$hechos" #' esc_d4
mutante "$CANARIO" "canario-marca-hecho-un-no-medido" 'if [ "$veredicto" != NO-MEDIDO ]; then printf' 'if true; then printf' esc_d4
mutante "$CANARIO" "canario-veredicto-solo-por-el-rc" 'case "$rc_g:$codigo" in' 'case "$rc_g:ok:$([ "$rc_g" -eq 0 ] && echo PASS || echo FAIL)" in' esc_d5
mutante "$CANARIO" "canario-veredicto-por-el-journal" 'case "$rc_g:$codigo" in' 'case "$rc_g:ok:$(grep -q "^unit rc=1" "$estado/gate-$sha9.log" && echo FAIL || echo PASS)" in' esc_d5
mutante "$CANARIO" "canario-acepta-un-receipt-anterior-a-T0" 'elif .finished_at < $t0 then "anterior-a-T0"' 'elif false then "anterior-a-T0"' esc_d5
mutante "$CANARIO" "canario-acepta-un-receipt-de-otro-sha" 'elif .sha != $sha then "otro-sha"' 'elif false then "otro-sha"' esc_d5
mutante "$CANARIO" "canario-acepta-un-receipt-de-otro-gate" 'elif .gate_id != $gate then "otro-gate"' 'elif false then "otro-gate"' esc_d5
mutante "$CANARIO" "canario-trata-rc-2-y-3-como-rojo" '    1:ok:FAIL)' '    [1-3]:ok:FAIL)' esc_d4
mutante "$CANARIO" "canario-trata-rc-2-y-3-como-verde" '    0:ok:PASS)' '    [0-3]:ok:PASS)' esc_d4
mutante "$CANARIO" "canario-sin-candado" 'flock -n 9 ||' 'true ||' esc_d7
mutante "$CANARIO" "canario-el-gate-hereda-el-candado" '</dev/null >"$estado/gate-$sha9.log" 2>&1 9>&-' '</dev/null >"$estado/gate-$sha9.log" 2>&1' esc_d6
mutante "$CANARIO" "canario-deja-el-worktree" '_retira_wt "$w"; WT_ACTUAL='"''" 'WT_ACTUAL='"''" esc_d1
mutante "$CANARIO" "canario-ignora-el-fallo-del-fetch" "if ! git -C \"\$repo\" fetch -q --no-tags origin '+refs/heads/main:refs/remotes/origin/main' </dev/null >/dev/null 2>&1; then" 'if false; then' esc_fetch
mutante "$CANARIO" "canario-acepta-un-tope-cualquiera" '[[ $tope =~ ^[1-9][0-9]{0,5}$ ]] ||' 'true ||' esc_pre
mutante "$CANARIO" "canario-no-comprueba-el-estado-symlink" '[ ! -L "$estado" ] ||' 'true ||' esc_pre
mutante "$CANARIO" "canario-reutiliza-el-directorio-de-receipts" \
  'mkdir -p -- "$estado/rec" && recdir="$(mktemp -d "$estado/rec/$sha9.XXXXXX")" || recdir='"''" \
  'mkdir -p -- "$estado/rec/$sha9" && recdir="$estado/rec/$sha9" || recdir='"''" esc_d11
mutante "$CANARIO" "canario-no-retira-el-gate-del-intento-cortado" 'if ! _retira_previo; then' 'if false; then' esc_d6
mutante "$CANARIO" "canario-no-corta-el-gate-al-terminar" 'if [ -n "$GATE_PID" ] || [ -e "$reg" ]; then _retira_previo || true; fi' ':' esc_d12
mutante "$CANARIO" "canario-gate-sin-verificar-identidad" 'case "$a" in *"$sellado"*"--run-group rgcan$2"*) return 0 ;; esac' 'case "$a" in *) return 0 ;; esac' esc_d13
mutante "$CANARIO" "canario-gate-sin-sesion-propia" 'setsid -w bash -c' 'bash -c' esc_d12
mutante "$CANARIO" "canario-sleep-sin-verificar-sus-miembros" '[[ $a =~ ^sleep\ [0-9]+$ ]] ||' 'true ||' esc_corte_c
mutante "$CANARIO" "canario-sleep-señalado-por-pid" 'kill -TERM -- "-$SUENO_PGID" 2>/dev/null' 'kill -TERM "$SUENO_PGID" 2>/dev/null' esc_corte_c
mutante "$CANARIO" "canario-sleep-sin-sesion-propia" 'setsid sleep "$1" </dev/null' 'sleep "$1" </dev/null' esc_d14
# Mutantes de las funciones de corte de ESTA suite: se mutan copias del texto extraído de ellas (no del fichero entero).
N_MUT_T=0
mutante_t() {   # <nombre> <viejo> <nuevo>: <viejo> debe aparecer UNA vez en las funciones de corte
  local d
  N_MUT_T=$((N_MUT_T+1)); d="$T/mutt/$N_MUT_T"; mkdir -p "$d"
  if ! mut_texto "$FUNCIONES_TEST" "$d/funciones.sh" "$2" "$3"; then bad "mutante $1: el patrón no aparece UNA vez"; return 0; fi
  mata "$1" esc_corte_t "$d/funciones.sh"
}
mutante_t "corte-t-senal-por-pid-positivo" 'kill -"$1" -- "-$2" 2>/dev/null' 'kill -"$1" "$2" 2>/dev/null'
mutante_t "corte-t-senal-sin-verificar-el-lider" 'verifica_grupo "$2" "$3" || return 1' ':'
mutante_t "corte-t-limpieza-por-pid-positivo" 'kill -TERM -- "-$id" 2>/dev/null; sleep 0.3' 'kill -TERM "$id" 2>/dev/null; sleep 0.3'
mutante_t "corte-t-limpieza-sin-verificar-el-grupo" 'if verifica_grupo "$id" "$frag"; then'$'\n      kill -TERM' 'if true; then'$'\n      kill -TERM'
mutante_t "corte-t-limpieza-sin-reverificar-antes-del-kill" 'if verifica_grupo "$id" "$frag"; then kill -KILL' 'if [ -n "$(miembros "$id")" ]; then kill -KILL'

# ═══ la referencia 08 existe (esta pieza solo AÑADE apartados; si no existe, FALLA y no la crea) ═════
esc_08() {   # <ruta del 08>: existe y trae los tres apartados
  local ref="$1" t
  DIAG=''
  [ -f "$ref" ] || { falla "no existe $ref: esta pieza no lo crea"; return 1; }
  for t in '## Cuotas' '## Canario' '## Sellador' '## Runners al d'; do
    grep -q "^$t" "$ref" || falla "falta el apartado $t"
  done
  [ -z "$DIAG" ]
}
check "R08 la referencia 08 existe y trae los apartados Cuotas, Canario y Sellador junto al de Runners al día" esc_08 "$REF08"
mata "referencia-08-ausente" esc_08 "$T/no-existe-08.md"

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desapareció un caso?)"; rc=1; }
exit "$rc"
