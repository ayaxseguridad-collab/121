#!/usr/bin/env bash
# test-supervision.sh — Tests HERMÉTICOS del doctor de instancia y de la re-acreditación (TAL-8043).
#
# Sin red ni DB. Los dobles de `tmux`, `sudo`, `ps`, `crontab` e `incus` viven en un PATH temporal:
# JAMÁS se consultan las sesiones, el crontab ni el bus REALES de la máquina. El árbol de skills que
# ejecuta el doctor es una COPIA temporal con `repo-identity.conf` sintéticos. Un único smoke usa un
# tmux real con socket propio (SKIP, listado aparte, si no hay tmux).
#
# ── MÉTODO (C4 de la auditoría del plan): UN VERDE Y MUTANTES DE UNA SOLA PIEZA ────────────────
# El fixture VERDE es el control positivo (rc 0, una línea OK por comprobación). Cada mutante quita
# UNA pieza —torre, cron, cursor, `ctx:`, auditor, `alternate_on`, estado 770, sello, contenedor,
# `usuario=`— y exige rc 1 con SOLO esa categoría en FALLA y cero NOVERIF cuando la consulta es observable.
# Estado con escritura compartida exige además NOVERIF de acreditación del CEO, por la frontera del lector.
# Un doctor «siempre rc 0»
# enrojece los mutantes; uno «siempre rc 1», el verde.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final exige que ejecutados + saltados == TOTAL_ESPERADO.
set -uo pipefail
umask 022 # Padres seguros del fixture positivo; los mutantes conservan sus chmod.
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SK="$(cd "$ROOT/.." && pwd)"
PKG="$(cd "$SK/.." && pwd)"

TOTAL_ESPERADO=605
PASS=0; FAIL=0; SKIP=0; SKIPPED=''
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); SKIPPED="$SKIPPED [$1]"; printf '  SKIP %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d /tmp/tdXXXXXX)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
ME="$(id -un)"
FX="$T/fx"; FXBIN="$T/bin"; FXSK="$T/sk"
FXP="$T/perfil.tsv"; FXBUS="$T/bus.log"; RUN="$T/run"; CDIR="$RUN/talent-ceo/cursores"
NOW0="$(date -u +%s)"
CREADA=$((NOW0 - 3600))
export SHIM_ME="$ME"

# ═══ el árbol de skills que ejecuta el doctor: COPIA con identidad sintética ═══════════════════
mkdir -p "$FXSK/talent-ceo" "$FXSK/talent-orchestrator" "$FXSK/talent-channel-operation"
cp -r "$SK/talent-ceo/scripts" "$FXSK/talent-ceo/scripts"
cp -r "$SK/talent-orchestrator/scripts" "$FXSK/talent-orchestrator/scripts"
cp -r "$SK/talent-channel-operation/scripts" "$FXSK/talent-channel-operation/scripts"
conf_canal() { # PKG_IDENTITY_PROJECT
  printf 'PKG_IDENTITY_PROJECT=%s\nTCO_REPO_DIR=repo-ejemplo\nTCO_REPO_SLUG=org-ejemplo/repo-ejemplo\nTCO_REPO_STACK=ninguno\nTCO_ANEXO_FILE=references/anexo-ejemplo.md\nTCO_LINEAR_INPROGRESS_STATE=11111111-1111-4111-8111-111111111111\nTCO_LINEAR_INREVIEW_STATE=22222222-2222-4222-8222-222222222222\nTCO_HOST_ENV_REL=ejemplo/.env.local\nTCO_TF_MANIFEST=%s/autoridad.conf\n' "$1" "$T" > "$FXSK/talent-channel-operation/scripts/repo-identity.conf"
}
conf_orq() { printf 'PKG_IDENTITY_PROJECT=%s\nTORC_HOST_ENV_REL=ejemplo/.env.local\n' "$1" > "$FXSK/talent-orchestrator/scripts/repo-identity.conf"; }
DOC="$FXSK/talent-ceo/scripts/doctor.sh"
REAC="$FXSK/talent-ceo/scripts/reacreditar.sh"
SELLAR="$FXSK/talent-ceo/scripts/bus-sellar.sh"

# ═══ dobles en un PATH temporal ════════════════════════════════════════════════════════════════
mkdir -p "$FXBIN"
cat > "$FXBIN/tmux" <<'SH'
#!/usr/bin/env bash
# doble de tmux: sesiones por usuario bajo $FX/tmux/<usuario>/<sesion>.{exists,panepid,alt,created,cap}
U="${SHIM_USER:-$SHIM_ME}"; D="$FX/tmux/$U"
sub="${1-}"; shift || true
tgt=''; pos=''
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tgt="$2"; shift 2 ;;
    -F) pos="$2"; shift 2 ;;
    -p|-J|-e) shift ;;
    *) pos="$1"; shift ;;
  esac
done
S="${tgt#=}"; S="${S%:}"
case "$sub" in
  -V) echo 'tmux 3.4'; exit 0 ;;
  has-session) [ -e "$D/$S.exists" ] ;;
  list-panes) [ -e "$D/$S.exists" ] && cat "$D/$S.panepid" ;;
  display-message) [ -e "$D/$S.exists" ] && printf '%s|%s\n' "$(cat "$D/$S.alt")" "$(cat "$D/$S.created")" ;;
  capture-pane) [ -e "$D/$S.exists" ] && awk -v label="$(cat "$D/$S.model")" '{ if (/ctx:/) { sub(/ctx:/, "[" label "] ctx:"); seen=1 }; print } END { if (!seen) print "[" label "]" }' "$D/$S.cap" ;;
  *) exit 1 ;;
esac
SH
cat > "$FXBIN/sudo" <<'SH'
#!/usr/bin/env bash
# doble de sudo -n -u <usuario> -- cmd…: solo los usuarios de $FX/sudo-allow; el resto, rechazo de permiso
[ "${1-}" = -n ] && [ "${2-}" = -H ] && [ "${3-}" = -u ] || { echo "sudo: uso inesperado en el doble" >&2; exit 2; }
u="$4"; shift 4; [ "${1-}" = -- ] && shift
printf '%s|' "$u" >> "$FX/sudo.log"; printf '%q ' "$@" >> "$FX/sudo.log"; printf '\n' >> "$FX/sudo.log"
grep -qx -- "$u" "$FX/sudo-allow" 2>/dev/null || { echo "sudo: a password is required" >&2; exit 1; }
HOME="$SHIM_HOME_ROOT/$u" SHIM_USER="$u" exec "$@"
SH
cat > "$FXBIN/ps" <<'SH'
#!/usr/bin/env bash
cat "$FX/ps.txt"
SH
cat > "$FXBIN/crontab" <<'SH'
#!/usr/bin/env bash
f="$FX/cron.${SHIM_USER:-$SHIM_ME}"
[ "${1-}" = -l ] || exit 2
[ -f "$f" ] && cat "$f" || { echo "no crontab for ${SHIM_USER:-$SHIM_ME}" >&2; exit 1; }
SH
cat > "$FXBIN/incus" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  list) cat "$FX/incus.list" ;;
  exec)
    c="$2"; cmd="$8"
    case "$cmd" in
      *capture-pane*)
        if [[ $cmd == *':.0'* ]]; then panel=desarrollo; else panel=auditor; fi
        [ -f "$FX/$panel.cap" ] || exit 1
        cat "$FX/$panel.cap" ;;
      *display-message*) cat "$FX/aud-pid.$c" ;;
      *'ps -e'*|*'bash -c'*) cat "$FX/aud-ps.$c" | awk -v root="$(cat "$FX/aud-pid.$c")" '{ par[$1]=$2; comm[$1]=$3 } END { for(p in comm) { q=p; for(i=0;i<64 && q;i++) { if(q==root) { print comm[p]; break }; q=par[q] } } }' ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FXBIN"/*

# ═══ el fixture VERDE ══════════════════════════════════════════════════════════════════════════
tab() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
perfil_verde() {
  tab tipo id maquina contenedor sesion atributos
  tab maquina maq-mando maq-mando - - 'ip=192.0.2.10;acceso=local'
  tab ceo CEO maq-mando - ses-ceo "roles=ceo;usuario=$ME"
  tab pm PM - - ninguna 'ejercido_por=CEO'
  tab torre torre-uno maq-mando - ses-torre 'usuario=daemon'
  tab estacion est-uno maq-mando - ses-est 'usuario=nobody'
  tab canal canal-uno maq-mando cont-canal-1 - 'usuario=bin'
  tab runner run-uno maq-mando cont-runner-1 - 'usuario=bin'
  tab cron cron-uno - - - 'dueno=CEO;minutos=07,22,37,52'
  tab bus bus-uno maq-mando - - "path=$FXBUS;lectores=CEO,torre-uno,est-uno"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sello() { # rol marcador minutos_atras [nota]
  printf '%s [rol: %s] [marcador: %s]%s\n' "$(iso $((NOW0 - $3 * 60)))" "$1" "$2" "${4:+ $4}" >> "$FXBUS"
}
fx_cursores() { # recalcula cursor+marca de cada lector al final del bus actual
  local l tam id
  tam="$(wc -c < "$FXBUS" | tr -d ' ')"; id="$(stat -c '%d:%i' "$FXBUS")"
  mkdir -p "$CDIR"; chmod 700 "$RUN/talent-ceo" "$CDIR"
  for l in CEO torre-uno est-uno; do printf '%s' "$tam" > "$CDIR/$l.cursor"; printf '%s' "$id" > "$CDIR/$l.bus"; done
}
fx_ses() { # usuario sesion panepid alt cap
  local d="$FX/tmux/$1"
  mkdir -p "$d"; : > "$d/$2.exists"; printf '%s\n' "$3" > "$d/$2.panepid"; printf '%s\n' "$4" > "$d/$2.alt"
  printf '%s\n' "$CREADA" > "$d/$2.created"; printf '%s\n' "$5" > "$d/$2.cap"
  if [ "$2" = ses-ceo ]; then printf 'Opus 4.8' > "$d/$2.model"; else printf 'Sonnet 5' > "$d/$2.model"; fi
}
CAP_OK='  trabajando en el encargo
  opus · ctx: 42% · ? for shortcuts'
CAP_MENU='  Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · ctx: 42%'
fx_nuevo() {
  rm -rf "${FX:?}" "${RUN:?}" "${T:?}/tok" "${T:?}/home" "${T:?}/secret" "${T:?}/tmp"
  mkdir -p "$FX/tmux" "$RUN" "$T/tok" "$T/home/ejemplo" "$T/secret" "$T/tmp"
  chmod 700 "$RUN"
  mkdir -p "$RUN/homes/daemon" "$RUN/homes/nobody" "$RUN/homes/bin"
  local hogar
  for hogar in "$T/home" "$RUN/homes/daemon" "$RUN/homes/nobody"; do
    mkdir -p "$hogar/.config/talent-channel-operation"
    printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 4-8 sonnet 5 > "$hogar/.config/talent-channel-operation/modelos.conf"
  done
  conf_canal ejemplo; conf_orq ejemplo
  printf 'TF_PROJECT=ejemplo\nTF_REPO_URL=https://example.invalid/org-ejemplo/repo-ejemplo\n' > "$T/autoridad.conf"
  perfil_verde > "$FXP"
  : > "$FXBUS"
  sello CEO HITO-1 30 'arranque del dia'; sello torre-uno HITO-T 20; sello est-uno HITO-E 20
  fx_cursores
  fx_ses "$ME" ses-ceo 201 0 "$CAP_OK"; fx_ses daemon ses-torre 301 0 "$CAP_OK"; fx_ses nobody ses-est 401 0 "$CAP_OK"
  printf '1 0 init\n100 1 tmux: server\n201 100 bash\n202 201 claude\n301 100 bash\n302 301 claude\n401 100 bash\n402 401 claude\n501 1 bash\n502 501 codex\n' > "$FX/ps.txt"
  printf '07,22,37,52 * * * * bash /opt/ejemplo/cron.sh cron-uno\n' > "$FX/cron.$ME"
  printf 'cont-canal-1,RUNNING\ncont-runner-1,RUNNING\n' > "$FX/incus.list"
  printf '501\n' > "$FX/aud-pid.cont-canal-1"; printf '501 1 bash\n502 501 codex\n' > "$FX/aud-ps.cont-canal-1"
  printf 'daemon\nnobody\nbin\n' > "$FX/sudo-allow"
  printf 'LINEAR_API_KEY=CANARIO-NO-DEBE-SALIR\n' > "$T/tok/.env.local"; chmod 600 "$T/tok/.env.local"
  printf 'LINEAR_API_KEY=CANARIO-NO-DEBE-SALIR\n' > "$T/home/ejemplo/.env.local"; chmod 600 "$T/home/ejemplo/.env.local"
}
TOK="$T/tok/.env.local"

# corre el doctor del fixture; OUT = salida, RC = rc. Argumentos: VAR=valor adicionales.
READONLY_FAIL=0
dr() {
  local snapshot_antes snapshot_despues
  snapshot_antes="$(hash_estado)" || READONLY_FAIL=$((READONLY_FAIL+1))
  OUT="$(env -i PATH="$FXBIN:/usr/bin:/bin" HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" TMPDIR="$T/tmp" \
    XDG_RUNTIME_DIR="$RUN" SHIM_HOME_ROOT="$RUN/homes" TA_PERFIL="$FXP" TA_BUS="$FXBUS" FX="$FX" SHIM_ME="$ME" TCO_AUDIT_CLI=codex TCO_HOST_ENV="$TOK" \
    LC_ALL=C "$@" bash "$DOC" 2>&1)"; RC=$?
  if [ -n "${TF_REMEDIACIONES_LOG:-}" ]; then
    printf '%s\n' "$OUT" | jq -cRs --argjson rc "$RC" '{fase:"F7",rc:$rc,salida:.}' >> "$TF_REMEDIACIONES_LOG"
  fi
  snapshot_despues="$(hash_estado)" || READONLY_FAIL=$((READONLY_FAIL+1))
  [ "$snapshot_antes" = "$snapshot_despues" ] || READONLY_FAIL=$((READONLY_FAIL+1))
}
cats()  { printf '%s\n' "$OUT" | awk '$1=="FALLA"{print $2}' | sort -u | paste -sd, -; }
nnov()  { printf '%s\n' "$OUT" | grep -c '^NOVERIF' || true; }
nok()   { printf '%s\n' "$OUT" | grep -c '^OK ' || true; }
solo()  { assert_eq "$1: rc 1 y SOLO FALLA $2 (0 NOVERIF)" "1|$2|0" "$RC|$(cats)|$(nnov)"; }
hash_regular() { # Solo fixtures propios: abre lectura temporal y restaura ANTES de dr.
  local f="$1" mode cambiado=0 rc
  mode="$(stat -c '%a' -- "$f")" || return 1
  if [ ! -r "$f" ]; then
    [ -O "$f" ] && chmod u+r -- "$f" || return 1
    cambiado=1
  fi
  sha256sum -- "$f"; rc=$?
  if [ "$cambiado" -eq 1 ]; then chmod "$mode" -- "$f" || return 1; fi
  return "$rc"
}
hash_estado() {
  { local f rc=0
    if [ -e "$RUN" ]; then
      find "$RUN" -printf '%p %y %m %U %G %l\n' | sort
      while IFS= read -r -d '' f; do hash_regular "$f" || rc=1; done < <(find "$RUN" -type f -print0 | sort -z)
    else printf 'ESTADO-AUSENTE\n'; fi
    if [ -f "$FXBUS" ]; then hash_regular "$FXBUS" || rc=1; else printf 'BUS-AUSENTE\n'; fi
    return "$rc"
  } | sha256sum
}

# ═══ C1 · el VERDE ═════════════════════════════════════════════════════════════════════════════
printf '== C1: topologia minima con todo presente (control positivo) ==\n'
fx_nuevo
h0="$(hash_estado)"; dr; h1="$(hash_estado)"
assert_eq "verde: rc 0" 0 "$RC"
assert_eq "verde: ni FALLA ni NOVERIF" "0" "$(printf '%s\n' "$OUT" | grep -cE '^(FALLA|NOVERIF)')"
assert_eq "verde: una linea OK por comprobacion (34)" 34 "$(nok)"
assert_eq "verde: PUERTA ABIERTA es la ultima linea" "PUERTA ABIERTA" "$(printf '%s\n' "$OUT" | tail -n1)"
assert_eq "verde: RESUMEN cuadra" "RESUMEN ok=34 falla=0 noverif=0" "$(printf '%s\n' "$OUT" | grep '^RESUMEN')"
assert_eq "verde: SOLO LECTURA (hash del arbol de estado y del bus identico)" "$h0" "$h1"
assert_eq "verde: no imprime el contenido del fichero de tokens" "0" "$(printf '%s\n' "$OUT" | grep -c 'CANARIO')"

# ═══ C2 · rc 2 sin evaluar ═════════════════════════════════════════════════════════════════════
printf '== C2/C14: no puede evaluar -> rc 2 y NINGUNA linea de comprobacion ==\n'
sin_lineas() { printf '%s\n' "$OUT" | grep -cE '^(OK|FALLA|NOVERIF|RESUMEN|PUERTA)'; }
dr TA_PERFIL="$T/no-existe.tsv"
assert_eq "perfil ausente: rc 2 y cero lineas" "2|0" "$RC|$(sin_lineas)"
perfil_verde | sed 's/^torre\ttorre-uno/torre\tCEO/' > "$T/p-inv.tsv"
dr TA_PERFIL="$T/p-inv.tsv"
assert_eq "perfil que viola V4: rc 2 y cero lineas" "2|0" "$RC|$(sin_lineas)"
perfil_verde | sed 's/;acceso=local//' > "$T/p-nolocal.tsv"
dr TA_PERFIL="$T/p-nolocal.tsv"
assert_eq "sin maquina acceso=local: rc 2" "2|0" "$RC|$(sin_lineas)"
perfil_verde | grep -v '^bus	' > "$T/p-nobus.tsv"
dr TA_PERFIL="$T/p-nobus.tsv" TA_BUS=
assert_eq "sin ruta del bus (ni TA_BUS ni fila bus): rc 2" "2|0" "$RC|$(sin_lineas)"
dr TA_ESCALADO_MIN=abc
assert_eq "TA_ESCALADO_MIN no numerico: rc 2" "2|0" "$RC|$(sin_lineas)"
dr TA_ESCALADO_MIN=0
assert_eq "TA_ESCALADO_MIN=0 fuera de rango: rc 2" "2|0" "$RC|$(sin_lineas)"
# un perfil VALIDO no basta: sin nada corriendo, rc 1 con FALLAs (no verde)
fx_nuevo; rm -rf "$FX/tmux" "$FX/cron.$ME" "$CDIR"; : > "$FX/ps.txt"
dr
assert_eq "perfil valido pero nada corriendo: rc 1 (la estructura no acredita)" 1 "$RC"
assert_eq "perfil valido pero nada corriendo: FALLA de torre, cron y cursor" "cron,cursor,torre" \
  "$(printf '%s\n' "$OUT" | awk '($1=="FALLA"||$1=="NOVERIF") && ($2=="torre"||$2=="cron"||$2=="cursor"){print $2}' | sort -u | paste -sd, -)"
# sin tmux / sin crontab
mkdir -p "$T/binmin"; ln -sf "$(command -v dirname)" "$T/binmin/dirname"
OUT="$(env -i PATH="$T/binmin" HOME="$T/home" TA_PERFIL="$FXP" TA_BUS="$FXBUS" /bin/bash "$DOC" 2>&1)"; RC=$?
assert_eq "sin tmux en el PATH: rc 2" "2|0" "$RC|$(sin_lineas)"
ln -sf "$FXBIN/tmux" "$T/binmin/tmux"
OUT="$(env -i PATH="$T/binmin" HOME="$T/home" TA_PERFIL="$FXP" TA_BUS="$FXBUS" /bin/bash "$DOC" 2>&1)"; RC=$?
assert_eq "sin crontab en el PATH: rc 2" "2|0" "$RC|$(sin_lineas)"
fx_nuevo
# C14: campos del perfil con control y C1: ni ESC ni 0x9b ni U+009B llegan a la salida
{ tab tipo id maquina contenedor sesion atributos
  tab maquina maq-mando - - - 'acceso=local'
  tab torre "$(printf 'torre\033[2J\x9b2Jx\xc2\x9b2Jy')" maq-mando - ses-fantasma 'usuario=daemon'
  tab bus bus-uno maq-mando - - "path=$FXBUS"; } > "$T/p-ctl.tsv"
dr TA_PERFIL="$T/p-ctl.tsv"
assert_eq "C14: id con ESC y C1: salida sin bytes de control ni C1 (rc 1, FALLA torre)" "1|0|0|torre" \
  "$RC|$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')")|$(printf '%s' "$OUT" | LC_ALL=C grep -cP '\x9b|\xc2\x9b')|$(cats | grep -o torre)"

# ═══ C3 · torre/estación ═══════════════════════════════════════════════════════════════════════
printf '== C3: torre y estacion ==\n'
fx_nuevo; rm -f "$FX/tmux/daemon/ses-torre.exists"; dr; assert_eq 'sesión ausente: consulta no verificable' '1|1' "$RC|$(nnov)"
fx_nuevo; grep -v '^302 ' "$FX/ps.txt" > "$T/ps2" && cp "$T/ps2" "$FX/ps.txt"; dr
solo "mutante TORRE: sesion viva SIN proceso claude descendiente del pane" torre
fx_nuevo; sed -i 's/^302 301 claude/302 301 claude-code/' "$FX/ps.txt"; dr
solo "el ejecutable decide, no el nombre parecido (claude-code != claude)" torre
fx_nuevo; sed -i 's/^302 301 claude/302 999 claude/' "$FX/ps.txt"; dr
solo "claude que NO desciende del pane (otro padre) no cuenta" torre
fx_nuevo; rm -f "$FX/tmux/nobody/ses-est.exists"; dr; assert_eq 'estación ausente: consulta no verificable' '1|1' "$RC|$(nnov)"
fx_nuevo; printf 'daemon\nbin\n' > "$FX/sudo-allow"; dr
assert_eq "usuario de otra torre sin sudo permitido: NOVERIF (no verde, no FALLA)" "1|1|" "$RC|$(nnov)|$(cats)"
fx_nuevo; perfil_verde | sed 's/^torre\ttorre-uno\tmaq-mando/torre\ttorre-uno\tmaq-otra/; s/^maquina\tmaq-mando\tmaq-mando\t-\t-\t\(.*\)$/maquina\tmaq-mando\tmaq-mando\t-\t-\t\1\nmaquina\tmaq-otra\tmaq-otra\t-\t-\tip=192.0.2.11/' > "$FXP"; dr
assert_eq "torre de OTRA maquina: NOVERIF = fallo, rc 1" "1|1|" "$RC|$(nnov)|$(cats)"
fx_nuevo; perfil_verde | sed 's/usuario=daemon/usuario=nadie-inexistente-xyz/' > "$FXP"; dr
solo "usuario del SO inexistente: FALLA firme de torre" torre

# ═══ C4 · renderer y ctx ═══════════════════════════════════════════════════════════════════════
printf '== C4: alternate_on y ctx (nunca se asume 0) ==\n'
fx_nuevo; printf '1\n' > "$FX/tmux/daemon/ses-torre.alt"; dr; solo "mutante ALTERNATE_ON=1" renderer
fx_nuevo; printf 'sin barra de contexto\n' > "$FX/tmux/daemon/ses-torre.cap"; dr; solo "mutante CTX: sin 'ctx:' en la barra (UNKNOWN, no 0)" ctx
fx_nuevo; printf 'ctx: 0%%\n' > "$FX/tmux/daemon/ses-torre.cap"; dr
assert_eq "ctx: 0% es un dato legible, no un fallo" "0|0" "$RC|$(nnov)"

# ═══ C5 · crons ════════════════════════════════════════════════════════════════════════════════
printf '== C5: crons ==\n'
fx_nuevo; rm -f "$FX/cron.$ME"; dr; assert_eq 'cron sin tabla: consulta no verificable' '1|1' "$RC|$(nnov)"
fx_nuevo; printf '# 07,22,37,52 * * * * bash /x/cron.sh cron-uno\n' > "$FX/cron.$ME"; dr; solo "la linea comentada no cuenta" cron
fx_nuevo; printf '08,23,38,53 * * * * bash /x/cron.sh cron-uno\n' > "$FX/cron.$ME"; dr; solo "minutos distintos a tablas-cron.sh --minutos" cron
fx_nuevo; printf '07,22,37,52 * * * * bash /x/cron.sh otra-tabla\n' > "$FX/cron.$ME"; dr; solo "linea sin el id de la fila cron" cron
fx_nuevo; perfil_verde | sed 's/minutos=07,22,37,52/minutos=99/' > "$FXP"; dr; solo "fila cron con minutos invalidos" cron

# ═══ C6 · bus, estado y cursores ═══════════════════════════════════════════════════════════════
printf '== C6: bus, estado y cursores (el arbol de estado queda byte-identico) ==\n'
fx_nuevo; h0="$(hash_estado)"; rm -f "$CDIR/CEO.cursor"; h0="$(hash_estado)"; dr; h1="$(hash_estado)"
solo "mutante CURSOR: falta CEO.cursor" cursor
assert_eq "falla de cursor: estado byte-identico antes/despues" "$h0" "$h1"
fx_nuevo; printf 'abc' > "$CDIR/CEO.cursor"; dr; solo "cursor no entero" cursor
fx_nuevo; printf '+1' > "$CDIR/CEO.cursor"; dr; solo "cursor con signo" cursor
fx_nuevo; printf '999999' > "$CDIR/CEO.cursor"; dr; solo "cursor mayor que el bus (truncado)" cursor
fx_nuevo; printf '123456789012345678901234' > "$CDIR/CEO.cursor"; dr; solo "cursor de 24 digitos (desborda el entero de 64 bits)" cursor
fx_nuevo; printf '9:9' > "$CDIR/CEO.bus"; dr; solo "marca .bus distinta del inodo del bus" cursor
fx_nuevo; rm -f "$CDIR/CEO.bus"; dr; solo "cursor > 0 sin marca .bus" cursor
fx_nuevo; printf '0' > "$CDIR/CEO.cursor"; rm -f "$CDIR/CEO.bus"; dr
assert_eq "cursor en 0 sin marca: nada que perder, verde" "0" "$RC"
fx_nuevo; rm -f "$CDIR/CEO.cursor"; ln -s "$CDIR/torre-uno.cursor" "$CDIR/CEO.cursor"; dr; solo "cursor symlink" cursor
fx_nuevo; chmod 770 "$RUN/talent-ceo"; dr
assert_eq 'mutante ESTADO 770: FALLA bus y NOVERIF acreditación por escritura compartida' \
  '1|bus|1|1' "$RC|$(cats)|$(nnov)|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF acreditacion CEO:')"
fx_nuevo; chmod 770 "$CDIR"; dr; solo "directorio de cursores 770" bus
fx_nuevo; mv "$CDIR" "$T/cursores-reales"; ln -s "$T/cursores-reales" "$CDIR"; dr
assert_eq "directorio de cursores symlink: FALLA bus (y rc 1)" "1|bus" "$RC|$(cats | grep -o '^bus')"
fx_nuevo; chmod 000 "$FXBUS"; dr
assert_eq "bus ilegible: rc 1, FALLA bus (cursores y sellos NOVERIF)" "1|bus" "$RC|$(cats)"; chmod 600 "$FXBUS"
fx_nuevo; rm -f "$FXBUS"; dr
assert_eq "bus ausente: FALLA bus" "1|1" "$RC|$(cats | grep -c bus)"
fx_nuevo; dr TA_BUS="$T/otro-bus"
assert_eq "TA_BUS distinto de path= del perfil: FALLA bus" "bus" "$(cats | grep -o '^bus' | head -n1)"
fx_nuevo; perfil_verde | sed 's/;lectores=CEO,torre-uno,est-uno//' > "$FXP"; dr
assert_eq "sin lectores= se leen todas las filas ceo/torre/estacion (verde)" "0" "$RC"
fx_nuevo; perfil_verde | sed 's/lectores=CEO,/lectores=CEO,..\/x,/' > "$FXP"; dr
assert_eq "lector fuera del charset: FALLA cursor" "1|cursor" "$RC|$(cats)"

# ═══ C7 · canales, runners y auditor ═══════════════════════════════════════════════════════════
printf '== C7: canales, runners y auditor ==\n'
fx_nuevo; printf 'cont-runner-1,RUNNING\n' > "$FX/incus.list"; dr; solo "mutante CONTENEDOR: canal ausente" canal
fx_nuevo; printf 'cont-canal-1,STOPPED\ncont-runner-1,RUNNING\n' > "$FX/incus.list"; dr; solo "contenedor canal parado" canal
fx_nuevo; printf 'cont-canal-1,RUNNING\ncont-runner-1,STOPPED\n' > "$FX/incus.list"; dr; solo "runner parado" canal
fx_nuevo; printf 'cont-canal-1-otro,RUNNING\ncont-runner-1,RUNNING\n' > "$FX/incus.list"; dr; solo "el nombre del contenedor se compara EXACTO (prefijo no vale)" canal
fx_nuevo; printf '501 1 bash\n502 501 claude\n' > "$FX/aud-ps.cont-canal-1"; dr; solo "mutante AUDITOR: el pane de auditoria corre otro binario" auditor
fx_nuevo; printf '501 1 bash\n502 999 codex\n' > "$FX/aud-ps.cont-canal-1"; dr; solo "auditor que no desciende del pane" auditor
fx_nuevo; rm -f "$FX/aud-pid.cont-canal-1"; : > "$FX/aud-pid.cont-canal-1"; dr
assert_eq 'sin pane de auditoría: identidad no comprobable' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF auditor')"
fx_nuevo; dr TCO_AUDIT_CLI=; solo "TCO_AUDIT_CLI vacio: no hay referencia" auditor
fx_nuevo; dr TCO_AUDIT_CLI=/opt/bin/codex; assert_eq "TCO_AUDIT_CLI con ruta: se compara el binario" 0 "$RC"
fx_nuevo; : > "$FX/sudo-allow"; dr
assert_eq "operador de incus sin sudo permitido: NOVERIF, nunca verde" "1|" "$RC|$(cats)"

# ═══ C8 · identidad y credenciales ═════════════════════════════════════════════════════════════
printf '== C8: identidad (nunca imprime valores ni lee el .env.local) ==\n'
fx_nuevo; sed -i '/^TCO_REPO_SLUG=/d' "$FXSK/talent-channel-operation/scripts/repo-identity.conf"; dr; solo "tco_exigir_identidad rc!=0 (falta una clave de identidad)" identidad
fx_nuevo; dr TCO_REPO_DIR=otro-repo; solo "OVERRIDE DIVERGENTE del conf (env pisa la identidad)" identidad
fx_nuevo; conf_orq otro-proyecto; dr; solo "PKG_IDENTITY_PROJECT distinto entre channel-operation y orchestrator" identidad
fx_nuevo; chmod 644 "$TOK"; dr; solo "fichero de tokens con modo 644" identidad
fx_nuevo; rm -f "$TOK"; dr; solo "fichero de tokens ausente" identidad
fx_nuevo; chmod 600 "$TOK"; dr
assert_eq "tokens 600: el CANARIO del fichero nunca sale en la salida" "0|0" "$RC|$(printf '%s\n' "$OUT" | grep -c 'CANARIO')"
assert_eq "el doctor no lee el fichero de tokens (solo stat): sin cat/redireccion/source sobre envf" "" \
  "$(grep -nE '(cat|source|\. |<) *[^ ]*\$\{?envf|envf[^#]*(\| *(cat|grep|head)|< )' "$ROOT/scripts/doctor.sh" || true)"

# ═══ C9 · sellado imposible (paridad con bus-sellar) ═══════════════════════════════════════════
printf '== C9: sellado imposible, con paridad respecto al rc real de bus-sellar.sh ==\n'
sellar_rc() { # perfil → rc de sellar como CEO sobre una copia desechable del bus
  cp "$FXBUS" "$T/bus-paridad"; rm -rf "$T/run-par"; mkdir -p "$T/run-par"; chmod 700 "$T/run-par"
  env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$T/run-par" TA_PERFIL="$1" TA_BUS="$T/bus-paridad" \
    bash "$SELLAR" --rol CEO --marcador PARIDAD-$$ >/dev/null 2>&1; echo $?
}
fx_nuevo; dr
assert_eq "paridad (verde): el doctor no ve ambiguedad y bus-sellar sella (rc 0)" "0|0" "$(printf '%s\n' "$OUT" | grep -c 'sellado-imposible')|$(sellar_rc "$FXP")"
fx_nuevo; perfil_verde | sed "s/usuario=daemon/usuario=$ME/" > "$FXP"; cp "$FX/tmux/daemon/"* "$FX/tmux/$ME/" 2>/dev/null; dr
solo "mutante USUARIO=: torre y CEO indistinguibles" sellado-imposible
assert_eq "paridad (ambiguo): bus-sellar --rol CEO se niega (rc 2)" 2 "$(sellar_rc "$FXP")"
fx_nuevo; perfil_verde | sed 's/;usuario=bin//; s/usuario=bin//' > "$FXP"; dr
assert_eq "paridad (canal sin usuario=): TODOS los actores que sellan quedan ambiguos (3)" "3" "$(printf '%s\n' "$OUT" | grep -c '^FALLA sellado-imposible')"
assert_eq "paridad (canal sin usuario=): bus-sellar se niega (rc 2)" 2 "$(sellar_rc "$FXP")"

# ═══ C10 · menú abierto ════════════════════════════════════════════════════════════════════════
printf '== C10: menu abierto sin escalar ==\n'
menu_fx() { # minutos_ultimo_sello marcador  (reconstruye bus con ese ultimo sello de torre-uno)
  fx_nuevo; : > "$FXBUS"; sello CEO HITO-1 30; sello est-uno HITO-E 20; sello torre-uno "$2" "$1"; fx_cursores
  printf '%s\n' "$CAP_MENU" > "$FX/tmux/daemon/ses-torre.cap"
}
menu_fx 40 ESCALA-torre-uno-r1 'BLOQUEO-AUTORIDAD · espera:CEO · decision · default'; dr
assert_eq "menu + ultimo sello ESCALA-<ROL>-*: OK escalado (rc 0)" "0|1" "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK escalado')"
menu_fx 40 HITO-T; dr; solo "mutante MENU: abierto, sello viejo y sin ESCALA-*" bloqueo-sin-escalar
menu_fx 5 HITO-T; dr
assert_eq "menu + sello mas reciente que N: OK menu-reciente (rc 0)" "0|1" "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK menu-reciente')"
menu_fx 40 ESCALA-otro-rol-r1; dr; solo "un ESCALA de OTRO rol no escala a este" bloqueo-sin-escalar
fx_nuevo; : > "$FXBUS"; sello CEO HITO-1 30; sello est-uno HITO-E 20; fx_cursores; printf '%s\n' "$CAP_MENU" > "$FX/tmux/daemon/ses-torre.cap"; dr
assert_eq "menu y el rol nunca selló: bloqueo-sin-escalar (y acreditacion)" "1|acreditacion,bloqueo-sin-escalar" "$RC|$(cats)"
menu_fx 40 HITO-T; dr TA_ESCALADO_MIN=60
assert_eq "TA_ESCALADO_MIN=60 amplía la ventana: sello de hace 40 min es reciente" "0" "$RC"
fx_nuevo; dr
assert_eq "sin menu: OK menu en cada actor con sesion (3)" "3" "$(printf '%s\n' "$OUT" | grep -c '^OK menu ')"
fx_nuevo; printf '> 1. un texto tecleado\n  2. otra cosa\n Esc to cancel\n ctx: 40%%\n' > "$FX/tmux/daemon/ses-torre.cap"; dr
assert_eq "composer con '> 1.' (sin cursor ❯) NO es un menu" "0" "$RC"

# ═══ C11 · acreditación ════════════════════════════════════════════════════════════════════════
printf '== C11: acreditacion de actores persistentes ==\n'
fx_nuevo; : > "$FXBUS"; sello CEO HITO-1 30; sello est-uno HITO-E 20; sello torre-uno HITO-VIEJO 90; fx_cursores; dr
solo "mutante SELLO: el ultimo sello de torre-uno es ANTERIOR al inicio de su sesion" acreditacion
fx_nuevo; : > "$FXBUS"; sello CEO HITO-1 30; sello est-uno HITO-E 20; fx_cursores; dr
solo "mutante SELLO: la torre nunca ha sellado" acreditacion
fx_nuevo; mkdir -p "$RUN/homes/daemon/.cache/talent-ceo/acreditacion"; printf 'NO_ACREDITADO\n' > "$RUN/homes/daemon/.cache/talent-ceo/acreditacion/torre-uno.estado"; dr
solo "estado NO_ACREDITADO aunque haya sello posterior" acreditacion
fx_nuevo; mkdir -p "$RUN/homes/daemon/.cache/talent-ceo/acreditacion"; printf 'ACREDITADO\n' > "$RUN/homes/daemon/.cache/talent-ceo/acreditacion/torre-uno.estado"; dr
assert_eq "estado ACREDITADO con sello posterior: verde" "0" "$RC"

# ═══ C12 · reacreditar.sh ══════════════════════════════════════════════════════════════════════
printf '== C12: reacreditar.sh --iniciar / --verificar ==\n'
rea() { env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$RUN" TA_PERFIL="$FXP" TA_BUS="$FXBUS" bash "$REAC" "$@" 2>"$T/rea.err"; }
ESTADO_CEO="$RUN/talent-ceo/acreditacion/CEO.estado"
sellar_como() { env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$RUN" TA_PERFIL="$FXP" TA_BUS="$FXBUS" bash "$SELLAR" --rol CEO --marcador "$1" ${2:+--nota "$2"} >/dev/null 2>&1; }
fx_nuevo
rea --rol CEO --verificar >/dev/null; assert_eq "--verificar sin --iniciar: rc 2" 2 $?
sal="$(rea --rol CEO --iniciar)"; rc=$?
M1="$(printf '%s\n' "$sal" | sed -n 's/^reacreditar: marcador: //p')"
assert_eq "--iniciar: rc 0, marcador ACRED-CEO-<8 hex> y estado NO_ACREDITADO" "0|si|NO_ACREDITADO" \
  "$rc|$(printf '%s' "$M1" | grep -Eq '^ACRED-CEO-[0-9a-f]{8}$' && echo si || echo no)|$(cat "$ESTADO_CEO" 2>/dev/null)"
dr
assert_eq "el doctor ve el NO_ACREDITADO que deja --iniciar (FALLA acreditacion, solo esa)" "1|acreditacion" "$RC|$(cats)"
rea --rol CEO --verificar >/dev/null; assert_eq "--verificar sin sello: rc 1" 1 $?
sellar_como "$M1"; rea --rol CEO --verificar >/dev/null
assert_eq "--verificar con el sello nuevo y el nonce: rc 0 y estado ACREDITADO" "0|ACREDITADO" "$?|$(cat "$ESTADO_CEO" 2>/dev/null)"
dr; assert_eq "tras acreditar el doctor vuelve a verde" 0 "$RC"
rea --rol CEO --verificar >/dev/null; assert_eq "--verificar es repetible (--peek no mueve el cursor)" 0 $?
# otro nonce
sal="$(rea --rol CEO --iniciar)"; M2="$(printf '%s\n' "$sal" | sed -n 's/^reacreditar: marcador: //p')"
sellar_como "ACRED-CEO-deadbeef"; rea --rol CEO --verificar >/dev/null; assert_eq "sello con OTRO nonce: rc 1" 1 $?
# sello anterior al cebado: se acredita con M2, se re-inicia y el sello viejo ya no vale
sellar_como "$M2"; sal="$(rea --rol CEO --iniciar)"; rea --rol CEO --verificar >/dev/null
assert_eq "sello ANTERIOR al ultimo --iniciar: rc 1 (sin reloj: orden de bytes)" 1 $?
M3="$(printf '%s\n' "$sal" | sed -n 's/^reacreditar: marcador: //p')"
# otro rol con el nonce correcto (cabecera forjada a mano: bus-sellar no dejaria)
printf '%s [rol: torre-uno] [marcador: %s]\n' "$(iso "$NOW0")" "$M3" >> "$FXBUS"
rea --rol CEO --verificar >/dev/null; assert_eq "marcador correcto sellado por OTRO rol: rc 1" 1 $?
# «SELLO ...» en una nota que cita el marcador: no cuenta
sellar_como "NOTA-CITA-$$" "SELLO CEO [marcador: $M3]"; rea --rol CEO --verificar >/dev/null
assert_eq "el marcador citado dentro de una NOTA no acredita: rc 1" 1 $?
printf '%s SELLO CEO %s (escrito en el pane, no sellado)\n' "$(iso "$NOW0")" "$M3" >> "$FXBUS"
rea --rol CEO --verificar >/dev/null; assert_eq "un «SELLO …» suelto en el bus (como en el pane) no acredita: rc 1" 1 $?
sal="$(rea --rol CEO --iniciar)"; M4="$(printf '%s\n' "$sal" | sed -n 's/^reacreditar: marcador: //p')"
sellar_como "$M4"; rea --rol CEO --verificar >/dev/null; assert_eq "y un --iniciar nuevo con su sello real si acredita: rc 0" 0 $?
rea --rol '../x' --iniciar >/dev/null; assert_eq "rol fuera del charset: rc 2" 2 $?
rea --rol 'ROL-DE-27-CARACTERES-EXACTOS' --iniciar >/dev/null; assert_eq "rol de 27 caracteres (no cabe acred-<ROL> en 32): rc 2" 2 $?
rea --rol ZZ --iniciar >/dev/null; assert_eq "rol ajeno al perfil: rc 2" 2 $?
rea --rol CEO >/dev/null; assert_eq "sin --iniciar ni --verificar: rc 2" 2 $?
rea --iniciar >/dev/null; assert_eq "sin --rol: rc 2" 2 $?
rea --rol CEO --iniciar --verificar >/dev/null; assert_eq "--iniciar y --verificar a la vez: rc 2" 2 $?
env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$RUN" TA_PERFIL="$FXP" bash "$REAC" --rol CEO --iniciar >/dev/null 2>&1
assert_eq "sin TA_BUS: rc 2" 2 $?
env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_RUNTIME_DIR="$RUN" TA_PERFIL="$T/no-existe" TA_BUS="$FXBUS" bash "$REAC" --rol CEO --iniciar >/dev/null 2>&1
assert_eq "sin perfil: rc 2" 2 $?
# solo escribe lo suyo: tras --iniciar los unicos ficheros nuevos son acreditacion/* y el cursor acred-CEO
fx_nuevo; antes="$(cd "$RUN" && find . -type f | sort)"; rea --rol CEO --iniciar >/dev/null
nuevos="$(cd "$RUN" && find . -type f | sort | comm -13 <(printf '%s\n' "$antes") - | grep -vE '^\./talent-ceo/(acreditacion/CEO\.(estado|nonce|inicio)|cursores/acred-CEO\.(cursor|bus|lock)|bus\.lock)$' || true)"
assert_eq "--iniciar solo escribe acreditacion/CEO.*, el cursor acred-CEO y los locks del bus" "" "$nuevos"
fx_nuevo; : > "$FXBUS"; fx_cursores; rea --rol CEO --iniciar >/dev/null; rc=$?
assert_eq "--iniciar con el bus VACIO: rc 0 (el cursor puede no existir)" 0 $rc
sellar_como "ACRED-CEO-$(cat "$RUN/talent-ceo/acreditacion/CEO.nonce")"
rea --rol CEO --verificar >/dev/null; assert_eq "--verificar tras cebar sobre bus vacio: rc 0" 0 $?

# shellcheck source=/dev/null
. "$HERE/supervision-ronda1.sh"
# shellcheck source=/dev/null
. "$HERE/supervision-ronda2.sh"
. "$HERE/supervision-ronda3.sh"

# ═══ C13 · el ejemplo ══════════════════════════════════════════════════════════════════════════
printf '== C13: manifiestos/ejemplo.perfil.tsv.example ==\n'
EJ="$PKG/manifiestos/ejemplo.perfil.tsv.example"
bash "$SK/talent-ceo/scripts/lib-perfil.sh" --check "$EJ" >/dev/null 2>&1; assert_eq "el ejemplo valida (rc 0)" 0 $?
assert_eq "el ejemplo NO se llama *.perfil.tsv" "0" "$(ls "$PKG/manifiestos"/*.perfil.tsv 2>/dev/null | wc -l | tr -d ' ')"
AIS="$T/aislado"; mkdir -p "$AIS/skills/talent-ceo/scripts" "$AIS/manifiestos"
cp "$SK/talent-ceo/scripts/lib-perfil.sh" "$AIS/skills/talent-ceo/scripts/"; cp "$EJ" "$AIS/manifiestos/"
env -i PATH="/usr/bin:/bin" bash "$AIS/skills/talent-ceo/scripts/lib-perfil.sh" --check >/dev/null 2>&1
assert_eq "sin TA_PERFIL, perfil_path NO elige el ejemplo (rc 2)" 2 $?
cp "$EJ" "$AIS/manifiestos/otro.perfil.tsv"
env -i PATH="/usr/bin:/bin" bash "$AIS/skills/talent-ceo/scripts/lib-perfil.sh" --check >/dev/null 2>&1
assert_eq "control: un *.perfil.tsv SI lo elegiria (rc 0) — por eso el ejemplo lleva otro nombre" 0 $?
# el doctor sobre el ejemplo: autoconsistente (sin sellado-imposible) y rc 1 en un host sin esa fabrica; solo lectura
fx_nuevo; rm -rf "$RUN"; h0="$(hash_estado)"; dr TA_PERFIL="$EJ" TA_BUS=; h1="$(hash_estado)"
assert_eq "doctor sobre el ejemplo en un host sin esa fabrica: rc 1" 1 "$RC"
assert_eq "el ejemplo no tiene ambiguedad de sellado (cero FALLA sellado-imposible)" 0 "$(printf '%s\n' "$OUT" | grep -c 'sellado-imposible')"
assert_eq "el ejemplo cierra por torre, cron y cursor/bus" "bus,canal,cron,cursor,torre" "$(printf '%s\n' "$OUT" | awk '$1=="FALLA"||$1=="NOVERIF"{print $2}' | grep -E '^(torre|cron|bus|canal|cursor)$' | sort -u | paste -sd, -)"
assert_eq "doctor sobre el ejemplo: no escribe nada" "$h0" "$h1"

# ═══ el doctor «siempre rc 0» y el «siempre rc 1» enrojecen esta suite ═════════════════════════
printf '== un doctor falso se detecta ==\n'
DOC_REAL="$DOC"
cp "$DOC_REAL" "$T/doctor.real"
fx_nuevo
printf '#!/usr/bin/env bash\necho "PUERTA ABIERTA"; exit 0\n' > "$DOC"; dr TA_BUS="$T/otro-bus"
assert_eq "doctor SIEMPRE rc 0: no pasaria el mutante de bus (rc 0 != 1)" "0" "$RC"
printf '#!/usr/bin/env bash\necho "PUERTA CERRADA"; exit 1\n' > "$DOC"; dr
assert_eq "doctor SIEMPRE rc 1: no pasaria el verde (rc 1 != 0)" "1" "$RC"
cp "$T/doctor.real" "$DOC"; chmod +x "$DOC"
dr; assert_eq "el doctor real restaurado vuelve a dar verde" 0 "$RC"

# ═══ estático ══════════════════════════════════════════════════════════════════════════════════
printf '== estatico: ni pgrep -f, ni kill, ni --skip; regex de ctx atada ==\n'
assert_eq "doctor.sh y reacreditar.sh sin pgrep -f / pkill / kill -9 / --skip" "" \
  "$(grep -nE 'pgrep -f|pkill|kill -9|--skip' "$ROOT/scripts/doctor.sh" "$ROOT/scripts/reacreditar.sh" || true)"
assert_eq "el doctor no hace source del 00-config.sh del orquestador" "" \
  "$(grep -nE '^[^#]*(\.|source) +[^ ]*talent-orchestrator/scripts/00-config' "$ROOT/scripts/doctor.sh" || true)"
ctx_re() { grep -oE "ctx\[:= \]\[\[:space:\]\]\*\[0-9\]\{1,3\}\[\[:space:\]\]\*%" "$1" | head -n1; }
R1="$(ctx_re "$ROOT/scripts/doctor.sh")"; R2="$(ctx_re "$SK/talent-orchestrator/scripts/lib-torre.sh")"; R3="$(ctx_re "$SK/talent-context/scripts/lib.sh")"
assert_eq "la regex de ctx: del doctor es la de torc_torre_ctx_pct y la de tc_ctx_pct" "3|1" "$([ -n "$R1" ] && [ "$R1" = "$R2" ] && [ "$R1" = "$R3" ] && echo 3 || echo 0)|1"
for muestra in 'opus · ctx: 42% · ?' 'ctx: 10%
ctx: 61%' 'barra sin contexto' 'CTX=7 %' 'ctx:100%'; do
  a="$(printf '%s\n' "$muestra" | (. "$SK/talent-orchestrator/scripts/lib-torre.sh"; torc_torre_ctx_pct) 2>/dev/null || echo UNK)"
  b="$(printf '%s\n' "$muestra" | (. "$SK/talent-context/scripts/lib.sh"; tc_ctx_pct) 2>/dev/null || echo UNK)"
  c="$(printf '%s\n' "$muestra" | env -i PATH=/usr/bin:/bin bash -c ". '$ROOT/scripts/lib-perfil.sh'; $(sed -n '/^ctx_de_captura() {/,/^}/p' "$ROOT/scripts/doctor.sh"); ctx_de_captura" 2>/dev/null || echo UNK)"
  assert_eq "ctx de «$(printf '%s' "$muestra" | tr '\n' '|')»: los tres lectores coinciden" "$a|$a" "$b|$c"
done

# ═══ D1 · issue 9011: revisor sin capa externa = desviación DECLARADA, de gravedad informativa ════════
printf '== D1: revisor code-audit (desviación declarada, informativa) ==\n'
ndes() { printf '%s\n' "$OUT" | grep -c '^OK desviacion revisor: revisor sin capa externa' || true; }
fx_nuevo; dr
assert_eq "D1 sin TCO_REVISOR: ninguna línea de desviación y puerta abierta" "0|0" "$RC|$(printf '%s\n' "$OUT" | grep -c ' desviacion ' || true)"
fx_nuevo; dr TCO_REVISOR=coderabbit
assert_eq "D1 revisor=coderabbit: ninguna línea de desviación y puerta abierta" "0|0" "$RC|$(printf '%s\n' "$OUT" | grep -c ' desviacion ' || true)"
fx_nuevo; dr TCO_REVISOR=code-audit
assert_eq "D1 revisor=code-audit por entorno: desviación OK informativa, puerta abierta" "0|1|" "$RC|$(ndes)|$(cats)"
fx_nuevo; printf 'TCO_REVISOR="code-audit"\n' > "$T/secret/agents.conf"; dr
assert_eq "D1 revisor=code-audit declarado en agents.conf: desviación OK informativa" "0|1|" "$RC|$(ndes)|$(cats)"
fx_nuevo; dr TCO_REVISOR=inventado
solo "D1 un revisor fuera de coderabbit|code-audit es FALLA, no informativa" desviacion

# ═══ Compatibilidad del generador: export solo en agents.conf ════════════════════════════════
fx_nuevo
printf 'export AM_LEDGER="/opt/ejemplo/ledger con espacios"\nexport TF_ROOT="/opt/ejemplo/fabrica"\nexport TF_MANIFEST="%s/autoridad.conf"\n' "$T" > "$T/secret/agents.conf"
dr; assert_eq 'export del generador acredita la configuracion' 0 "$RC"
# Extrae el lector real sin ejecutar el resto del doctor; nunca carga tokens.
sed -n '/^leer_conf() {/,/^}/p' "$DOC" > "$T/lector-conf.sh"
leidos="$(bash -c '
  . "$1"; declare -A datos=()
  leer_conf "$2" datos agents || exit 1
  printf "%s\n" "${datos[AM_LEDGER]}" "${datos[TF_ROOT]}" "${datos[TF_MANIFEST]}"
' prueba "$T/lector-conf.sh" "$T/secret/agents.conf")"; lector_rc=$?
esperados="$(printf '%s\n' '/opt/ejemplo/ledger con espacios' '/opt/ejemplo/fabrica' "$T/autoridad.conf")"
assert_eq 'export del generador conserva los tres valores literales' "0|$esperados" "$lector_rc|$leidos"
# shellcheck disable=SC2016 # las variables se expanden en el proceso hijo aislado
runtime="$(env -i PATH=/usr/bin:/bin HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" \
  bash -c '
    . "$1" || exit 1
    bash -c '\''printf "%s\n" "$AM_LEDGER" "$TF_ROOT" "$TF_MANIFEST"'\''
  ' prueba "$FXSK/talent-channel-operation/scripts/00-config.sh")"; runtime_rc=$?
assert_eq 'export doctor y 00-config.sh real coinciden tambien en procesos hijos' "0|$leidos" "$runtime_rc|$runtime"
# shellcheck disable=SC2016 # sustituciones hostiles como datos, jamás se ejecutan
for dato in 'export A=1 B=2' 'export -n A=1' 'export' 'declare A=1' 'readonly A=1' 'local A=1' 'env A=1' 'export  A=1' $'export\tA=1' ' export A=1' 'export A="ok"resto' 'export A=ok;true' 'export A=$(true)' 'export A=`true`' 'export export A=1'; do
  fx_nuevo; printf '%s\n' "$dato" > "$T/secret/agents.conf"; dr
  solo "prefijo o valor rechazado: $dato" identidad
done
for orden in export-primero export-despues; do
  fx_nuevo
  if [ "$orden" = export-primero ]; then
    printf 'export A=1\nA=1\n' > "$T/secret/agents.conf"
  else
    printf 'A=1\nexport A=1\n' > "$T/secret/agents.conf"
  fi
  dr; solo "clave duplicada con y sin export: $orden" identidad
done
fx_nuevo; printf 'export DATO=literal\n' >> "$FXSK/talent-channel-operation/scripts/repo-identity.conf"
dr; solo 'export sigue rechazado en identidad' identidad
fx_nuevo; printf 'export TF_PROJECT=ejemplo\nTF_REPO_URL=https://example.invalid/org-ejemplo/repo-ejemplo\n' > "$T/autoridad.conf"
dr; assert_eq 'export sigue rechazado en autoridad' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF identidad procedencia:')"
# shellcheck source=/dev/null
. "$HERE/supervision-manifiesto.sh"
fx_nuevo # el smoke siguiente requiere de nuevo identidad y autoridad válidas

# Ruta explícita persistente: misma observación con y sin runtime de sesión.
cat > "$FXBIN/getent" <<'SH'
#!/usr/bin/env bash
if [ "$1" = passwd ]; then
  printf '%s:x:1000:1000:fixture:%s/%s:/bin/bash\n' "$2" "$SHIM_HOME_ROOT" "$2"
else
  /usr/bin/getent "$@"
fi
SH
chmod +x "$FXBIN/getent"
for usr in daemon nobody; do
  mkdir -p "$RUN/homes/$usr/.local/state"
done
dr TA_BUS_STATE_DIR="$RUN/talent-ceo" XDG_RUNTIME_DIR="$T/runtime-ajeno"
explicit_out="$OUT"; explicit_rc="$RC"
assert_eq 'G62 doctor ignora runtime ajeno con ruta explícita' 0 "$RC"
dr TA_BUS_STATE_DIR="$RUN/talent-ceo" XDG_RUNTIME_DIR=
assert_eq 'G62 doctor idéntico sin runtime de sesión' "$explicit_rc|$explicit_out" "$RC|$OUT"
mkdir -p "$RUN/homes/daemon/estado-distinto/acreditacion" "$RUN/homes/daemon/.local/state/talent-ceo/acreditacion"
chmod 700 "$RUN/homes/daemon/estado-distinto"
printf 'ACREDITADO\n' > "$RUN/homes/daemon/estado-distinto/acreditacion/torre-uno.estado"
printf 'NO_ACREDITADO\n' > "$RUN/homes/daemon/.local/state/talent-ceo/acreditacion/torre-uno.estado"
sed -i "s@usuario=daemon@usuario=daemon;estado_bus=$RUN/homes/daemon/estado-distinto@" "$FXP"
dr TA_BUS_STATE_DIR="$RUN/talent-ceo"
assert_eq 'estado bus adjudicado distinto de convención acredita' 0 "$RC"
sed -i "s@estado_bus=$RUN/homes/daemon/estado-distinto@estado_bus=relativo@" "$FXP"
dr TA_BUS_STATE_DIR="$RUN/talent-ceo"
assert_eq 'estado bus relativo no verificable' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c 'estado_bus no es absoluto')"
sed -i 's/;estado_bus=relativo//' "$FXP"
rm "$RUN/homes/daemon/.local/state/talent-ceo/acreditacion/torre-uno.estado"
dr TA_BUS_STATE_DIR="$RUN/talent-ceo"
assert_eq 'estado bus ausente conserva convención' 0 "$RC"
rm -f "$FXBIN/getent"
fx_nuevo

# ═══ smoke con tmux REAL (socket propio, un solo caso) ═════════════════════════════════════════
printf '== smoke: tmux real ==\n'
if command -v tmux >/dev/null 2>&1; then
  SM="$(mktemp -d /tmp/tsXXXXXX)"; mkdir -p "$SM/tm" "$SM/run"; chmod 700 "$SM/run"
  # El `comm` de un proceso es el nombre del FICHERO ejecutado: un script llamado `claude` aparece
  # como `claude` (copiar `sleep` no vale: es un multi-call que se niega a llamarse de otro modo).
  printf '#!/bin/bash\nprintf "[Opus 4.8] · ctx: 33%%%% · ok\\n"\nsleep 300\n' > "$SM/claude"; chmod +x "$SM/claude"
  export TMUX_TMPDIR="$SM/tm"
  ( unset TMUX; tmux new-session -d -s ses-ceo "$SM/claude" ) >/dev/null 2>&1
  sleep 1
  perfil_smoke() { tab tipo id maquina contenedor sesion atributos; tab maquina maq-mando - - - 'acceso=local'
    tab ceo CEO maq-mando - ses-ceo "usuario=$ME"; tab bus bus-uno maq-mando - - "path=$SM/bus.log;lectores=CEO"; }
  perfil_smoke > "$SM/perfil.tsv"
  printf '%s [rol: CEO] [marcador: HITO-S]\n' "$(iso "$(date -u +%s)")" > "$SM/bus.log"
  mkdir -p "$SM/run/talent-ceo/cursores"; chmod 700 "$SM/run/talent-ceo" "$SM/run/talent-ceo/cursores"
  printf '%s' "$(wc -c < "$SM/bus.log" | tr -d ' ')" > "$SM/run/talent-ceo/cursores/CEO.cursor"
  printf '%s' "$(stat -c '%d:%i' "$SM/bus.log")" > "$SM/run/talent-ceo/cursores/CEO.bus"
  OUT="$(env -i PATH="/usr/bin:/bin" HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" TMPDIR="$T/tmp" TMUX_TMPDIR="$SM/tm" \
    XDG_RUNTIME_DIR="$SM/run" TA_PERFIL="$SM/perfil.tsv" TA_BUS="$SM/bus.log" TCO_AUDIT_CLI=codex TCO_HOST_ENV="$TOK" LC_ALL=C \
    bash "$DOC" 2>"$SM/err")"; RC=$?
  # La sesion creada antes que el sello: el sello (ahora) es posterior al session_created (hace ~1 s)
  assert_eq "smoke tmux real: torre, renderer, ctx, menu y acreditacion OK (rc 0)" "0|torre,renderer,ctx,menu,acreditacion" \
    "$RC|$(printf '%s\n' "$OUT" | awk '$1=="OK" && ($2=="torre"||$2=="renderer"||$2=="ctx"||$2=="menu"||$2=="acreditacion"){print $2}' | paste -sd, -)$(head -c 300 "$SM/err" | tr '\n' ' ')"
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$SM"; unset TMUX_TMPDIR
else
  skip "smoke tmux real: no hay tmux en el PATH"
fi

assert_eq 'H10 todas las corridas dr conservan contenido y estructura' 0 "$READONLY_FAIL"
fx_nuevo; printf 'Sonnet 6.1' > "$FX/tmux/daemon/ses-torre.model"; dr
solo "torre con modelo distinto al registro" modelo
fx_nuevo; rm "$RUN/homes/daemon/.config/talent-channel-operation/modelos.conf"; dr
assert_eq "registro de otro usuario ausente cierra doctor" "1|1" "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF modelo torre-uno')"
fx_nuevo; printf 'Opus 6' > "$FX/tmux/$ME/ses-ceo.model"
sed -i 's/opus-4-8/opus-6/' "$T/home/.config/talent-channel-operation/modelos.conf"; dr
assert_eq "doctor acepta versión futura del CEO desde registro propio" 0 "$RC"
fx_nuevo; printf '[Opus 6]\nctx: 42%%\n' > "$FX/tmux/$ME/ses-ceo.cap"
sed -i 's/opus-4-8/opus-6/' "$T/home/.config/talent-channel-operation/modelos.conf"; dr
solo "modelo histórico no acredita la etiqueta vigente del panel" modelo
# shellcheck source=/dev/null
. "$HERE/supervision-modelo-mando.sh"
printf '\n== %d ok, %d FAIL (esperados: %d casos; saltados: %d%s) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO" "$SKIP" "${SKIPPED:+ —$SKIPPED}"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL + SKIP)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos ejecutados+saltados $((PASS + FAIL + SKIP)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desaparecio un caso?)"; rc=1; }
exit "$rc"
