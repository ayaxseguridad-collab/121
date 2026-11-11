#!/usr/bin/env bash
# test-seguridad-doctor.sh — Sondas de seguridad del doctor: Node con suelo de parche, sesiones zombi y LiteLLM (issue 9559).
# shellcheck disable=SC2034 # Nombres compartidos con el fixture copiado de test-desvio.sh.
#
# Sin red ni DB. Los dobles de `tmux`, `sudo`, `ps`, `crontab`, `incus`, `node` y `getent` viven en un PATH
# temporal: JAMÁS se consultan las sesiones, los contenedores ni el bus REALES. Cada fixture nuevo vive en su propio
# directorio (`$T/g<N>`): la prueba no borra nada salvo su temporal al salir. `TA_SEG_RAIZ` desvía `/usr`, `/etc` y
# `/tmp` de las sondas a un árbol sintético, así que ni el sistema real ni el señuelo real de /tmp influyen. Las
# búsquedas de LiteLLM del host se hacen con el `find` REAL sobre ese árbol; las de los canales, con un doble de incus.
#
# ── MÉTODO ──────────────────────────────────────────────────────────────────────────────────────
# Un fixture VERDE (control positivo) y mutantes de UNA sola pieza. Contrato:
#   C1 todo al día → 0 FALLA y 0 AVISO · C2 Node bajo el suelo → FALLA · C3 indicadores de LiteLLM → FALLA y el
#   fichero sigue ahí · C4 el sitecustomize.py del sistema NO es hallazgo · C5 zombi → AVISO que no cierra la puerta ·
#   C6 no medible → NOVERIF, jamás OK · M1 un rc ≠ 0 del find nunca es una búsqueda completa · M3 sin talent-channels
#   el doctor lo AVISA, no calla · S: el doctor normal LEE el último resultado sellado de `doctor.sh --seguridad`
#   (FALLA si es rojo, si tiene NOVERIF o si tiene más de 26 h; NOVERIF si no existe o el sello no cuadra) ·
#   N1 un sello SEG- no es un sello de la sesión del CEO · N2 cobertura de sujetos · N3 controles anti-repetición ·
#   N4 flock, sellar antes de publicar y temporal huérfano apartado · N5 cuenta del perfil sin hogar.
# Cada doctor normal corre entre dos fotografías del árbol de fixtures (sha): no muta nada. El modo escritor
# (`--seguridad`) es el único que escribe, y solo su resultado y su sello en el bus.
# `TEST_RETRASO_SEG` (segundos, por defecto 0) atrasa NOW0 para demostrar que N1 no depende del reloj; solo existe aquí.
# `TEST_SEG_DOCTOR` / `TEST_SEG_LIB` sustituyen doctor.sh / lib-seguridad.sh SOLO para demostrar mutantes.
# La suite se afirma a sí misma: ejecutados + saltados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SK="$(cd "$ROOT/.." && pwd)"
PKG="$(cd "$SK/.." && pwd)"

TOTAL_ESPERADO=116   # 112 + 2 (issue 9681: directorio de LiteLLM completo en AVISO, 150 y 250 caracteres) + 2 (issue 9711: ruta de más de 200 y otra con espacios y «ñ», con su AVISO)
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  NO MEDIDO %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

# El temporal vive en $TMPDIR (disco, no tmpfs). La prueba NO borra nada (ley «no se borra NADA»): al salir MUEVE
# su temporal a «apartado/», junto a él, e imprime la ruta; si no puede, lo dice y lo deja donde está. Con root
# (id -u = 0) los casos que dependen de chmod 000/444 se SALTAN (NO MEDIDO): con root no se miden.
: "${TMPDIR:?TMPDIR sin definir: la prueba no escribe fuera de su temporal}"   # sentencia propia: dentro de $( … ) el «:?» no aborta el script
T="$(mktemp -d "$TMPDIR/tsXXXXXX")" && [ -d "$T" ] || { echo "no se pudo crear el temporal bajo $TMPDIR" >&2; exit 2; }
trap 'chmod -R u+rwX "$T" 2>/dev/null; mkdir -p "${T%/*}/apartado" && [ ! -e "${T%/*}/apartado/${T##*/}" ] && mv -- "$T" "${T%/*}/apartado/" && echo "temporal apartado: ${T%/*}/apartado/${T##*/}" >&2 || echo "NO se pudo apartar $T: se queda donde está" >&2' EXIT
AP_N=0; aparta() { AP_N=$((AP_N+1)); mkdir -p "$T/ap$AP_N" && mv -- "$1" "$T/ap$AP_N/"; }   # sin rm: lo que sobra se mueve
ME="$(id -un)"
FXBIN="$T/bin"
NOW0="$(( $(date -u +%s) - ${TEST_RETRASO_SEG:-0} ))"   # TEST_RETRASO_SEG (defecto 0, solo de esta prueba): simula una suite lenta; N1 se re-ancla
CREADA=$((NOW0 - 3600))
export SHIM_ME="$ME"
G=0
DOC_ARGS=()
RO_FAIL=0; RO_CHECK=1
CON_CANALES=1

# ═══ dobles en un PATH temporal (compartidos por todas las generaciones del fixture) ═══════════
mkdir -p "$FXBIN"
cat > "$FXBIN/tmux" <<'SH'
#!/usr/bin/env bash
# doble de tmux: sesiones por usuario bajo $FX/tmux/<usuario>/…; `list-panes -a` lee $FX/panes.<usuario>
U="${SHIM_USER:-$SHIM_ME}"; D="$FX/tmux/$U"
sub="${1-}"; shift || true
tgt=''; pos=''; all=''
while [ $# -gt 0 ]; do
  case "$1" in
    -t) tgt="$2"; shift 2 ;;
    -F) pos="$2"; shift 2 ;;
    -a) all=1; shift ;;
    -p|-J|-e) shift ;;
    *) pos="$1"; shift ;;
  esac
done
S="${tgt#=}"; S="${S%:}"
case "$sub" in
  -V) echo 'tmux 3.4'; exit 0 ;;
  has-session) [ -e "$D/$S.exists" ] ;;
  list-panes) if [ -n "$all" ]; then [ -f "$FX/panes.$U" ] && cat "$FX/panes.$U"; else [ -e "$D/$S.exists" ] && cat "$D/$S.panepid"; fi ;;
  display-message) [ -e "$D/$S.exists" ] && printf '%s|%s\n' "$(cat "$D/$S.alt")" "$(cat "$D/$S.created")" ;;
  capture-pane) [ -e "$D/$S.exists" ] && awk -v label="$(cat "$D/$S.model")" '{ if (/ctx:/) { sub(/ctx:/, "[" label "] ctx:"); seen=1 }; print } END { if (!seen) print "[" label "]" }' "$D/$S.cap" ;;
  *) exit 1 ;;
esac
SH
cat > "$FXBIN/sudo" <<'SH'
#!/usr/bin/env bash
# doble de sudo -n -H -u <usuario> -- cmd…: solo los usuarios de $FX/sudo-allow; el resto, rechazo de permiso
[ "${1-}" = -n ] && [ "${2-}" = -H ] && [ "${3-}" = -u ] || { echo "sudo: uso inesperado en el doble" >&2; exit 2; }
u="$4"; shift 4; [ "${1-}" = -- ] && shift
printf '%s|' "$u" >> "$FX/sudo.log"; printf '%q ' "$@" >> "$FX/sudo.log"; printf '\n' >> "$FX/sudo.log"
# Firma literal de cada orden (usuario TAB argumentos separados por el carácter 0x1f): la compara la prueba de la fuente única.
{ printf '%s\t' "$u"; printf '%s\037' "$@"; printf '\n'; } >> "$FX/sudo.argv"
grep -qx -- "$u" "$FX/sudo-allow" 2>/dev/null || { echo "sudo: a password is required" >&2; exit 1; }
# Montaje real: el sudoers solo admite consultas EXACTAS. Con $FX/sudo-solo-exactas, `incus exec` solo pasa para el panel.
if [ -f "$FX/sudo-solo-exactas" ] && [[ "$*" == *'incus exec'* && "$*" != *capture-pane* ]]; then
  echo "sudo: consulta no autorizada por el montaje" >&2; exit 1
fi
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
cat > "$FXBIN/node" <<'SH'
#!/usr/bin/env bash
# doble de node del host: versión en $FX/node.host; sin fichero, el binario "no se puede ejecutar"
[ "${1-}" = -v ] || exit 2
[ -f "$FX/node.host" ] || exit 127
cat "$FX/node.host"
SH
cat > "$FXBIN/getent" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = passwd ] && [ -n "${2-}" ] || exit 2
# con FX_SIN_HOGAR=<usuario> la cuenta existe pero su hogar NO (caso N5)
h="$SHIM_HOME_ROOT/$2"; [ "${FX_SIN_HOGAR-}" != "$2" ] || h="$SHIM_HOME_ROOT/$2-sin-hogar"
printf '%s:x:1000:1000::%s:/bin/sh\n' "$2" "$h"
SH
cat > "$FXBIN/timeout" <<'SH'
#!/usr/bin/env bash
# doble de timeout: con FX_TIMEOUT_RC todo "se agota" con ese rc; si no, el timeout real
[ -n "${FX_TIMEOUT_RC:-}" ] && exit "$FX_TIMEOUT_RC"
exec /usr/bin/timeout "$@"
SH
cat > "$FXBIN/incus" <<'SH'
#!/usr/bin/env bash
# doble de incus: `exec <c> -- su - <usuario> -c <orden>`; las órdenes de seguridad leen $FX/<tipo>.<c>
case "${1-}" in
  list) cat "$FX/incus.list" ;;
  exec)
    c="$2"; cmd="$8"
    case "$cmd" in
      'node -v') [ -f "$FX/node.$c" ] && cat "$FX/node.$c" || exit 1 ;;
      *'test -e /tmp/remote_code_loader.lock'*)
        printf 'INICIO\n'; [ ! -f "$FX/lock.$c" ] || printf 'PRESENTE\n'; [ -f "$FX/locksinfin.$c" ] || printf 'FIN\n' ;;
      *'/usr/bin/find'*)
        [ -f "$FX/scan.$c" ] || exit 1
        cat "$FX/scan.$c"; [ ! -f "$FX/scanerr.$c" ] || cat "$FX/scanerr.$c" >&2
        [ ! -f "$FX/scanrc.$c" ] || exit "$(cat "$FX/scanrc.$c")" ;;
      *'tmux list-panes -a'*) printf 'INICIO\n'; [ -f "$FX/panes.c.$c" ] || exit 1; cat "$FX/panes.c.$c" ;;
      'ps -e -o pid=,ppid=,comm=') [ -f "$FX/ps.c.$c" ] && cat "$FX/ps.c.$c" || exit 1 ;;
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

# ═══ el fixture VERDE (copia declarada del de test-desvio.sh) ═════════════════════════════════
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
sello() { printf '%s [rol: %s] [marcador: %s]%s\n' "$(iso $((NOW0 - $3 * 60)))" "$1" "$2" "${4:+ $4}" >> "$FXBUS"; }
fx_cursores() {
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

fx_paquete() {
  local rel amb motivo m miembros="talent-ceo talent-channel-operation talent-orchestrator"
  [ "$CON_CANALES" -eq 1 ] && miembros="talent-ceo talent-channel-operation talent-channels talent-orchestrator"
  mkdir -p "$FXPK/scripts/paquete" "$FXPK/instalacion"
  cp "$PKG/scripts/paquete/lib-package.sh" "$FXPK/scripts/paquete/"
  { printf 'version=1.7.2\nmin_invariants=1\n'
    for m in $miembros; do printf 'member=%s\n' "$m"; done
    printf 'overlay=talent-channel-operation:scripts/repo-identity.conf\noverlay=talent-orchestrator:scripts/repo-identity.conf\n'
  } > "$FXPK/scripts/paquete/package.manifest"
  for m in $miembros; do
    mkdir -p "$FXSK/$m" "$FXPK/skills/$m"
    printf '# Miembro de ejemplo\n' > "$FXSK/$m/SKILL.md"
    cp "$FXSK/$m/SKILL.md" "$FXPK/skills/$m/SKILL.md"
  done
  mkdir -p "$FXPK/skills/talent-ceo/references" "$FXSK/talent-ceo/references"
  printf 'Núcleo de ejemplo\n' > "$FXPK/skills/talent-ceo/references/nucleo.txt"
  cp "$FXPK/skills/talent-ceo/references/nucleo.txt" "$FXSK/talent-ceo/references/nucleo.txt"
  while IFS=$'\t' read -r rel amb motivo; do
    case "$rel" in ''|'#'*) continue ;; esac
    mkdir -p "$FXPK/$(dirname "$rel")"
    cp "$PKG/$rel" "$FXPK/$rel"
    if [ "$amb" = ambos ]; then
      mkdir -p "$FXSK/$(dirname "${rel#skills/}")"
      cp "$FXPK/$rel" "$FXSK/${rel#skills/}"
    fi
  done < "$ROOT/scripts/doctor-guardas.tsv"
  (
    cd "$FXPK" || exit 1
    sha256sum skills/talent-ceo/references/nucleo.txt
    while IFS=$'\t' read -r rel amb motivo; do
      case "$rel" in ''|'#'*) continue ;; esac
      sha256sum "$rel"
    done < "$ROOT/scripts/doctor-guardas.tsv"
  ) > "$FXPK/instalacion/NUCLEO.sha256"
  mkdir -p "$B/clon/.claude/paquete" "$B/clon/.githooks"
  cp "$FXPK/scripts/paquete/package.manifest" "$B/clon/.claude/paquete/package.manifest"
  cp "$FXPK/githooks/pre-push" "$B/clon/.githooks/pre-push"
  chmod +x "$B/clon/.githooks/pre-push"
  git -C "$B/clon" init -q
  git -C "$B/clon" config core.hooksPath .githooks
  (cd "$B" && python3 -m zipfile -c publicado.zip talent-factory)
}

# Árbol sintético de Python: el del sistema (con el sitecustomize de Debian) y un venv limpio en el hogar. Las raíces
# del sistema que la búsqueda exige (/usr/lib, /usr/local/lib, /opt) existen siempre.
fx_python() {
  mkdir -p "$SYS/etc/python3.12" "$SYS/usr/lib/python3.12" "$SYS/usr/lib/python3/dist-packages" "$SYS/usr/local/lib" "$SYS/opt" "$SYS/tmp"
  printf '# sitecustomize del sistema\n' > "$SYS/etc/python3.12/sitecustomize.py"
  ln -s "$SYS/etc/python3.12/sitecustomize.py" "$SYS/usr/lib/python3.12/sitecustomize.py"
  printf 'x = 1\n' > "$SYS/usr/lib/python3/dist-packages/paquete_ok.py"
  mkdir -p "$HOMEH/proj/.venv/lib/python3.12/site-packages/litellm" "$HOMEH/proj/.venv/lib/python3.12/site-packages/litellm-1.106.2.dist-info"
  printf 'x = 1\n' > "$HOMEH/proj/.venv/lib/python3.12/site-packages/litellm/__init__.py"
  printf 'Name: litellm\nVersion: 1.106.2\n' > "$HOMEH/proj/.venv/lib/python3.12/site-packages/litellm-1.106.2.dist-info/METADATA"
}
SP="proj/.venv/lib/python3.12/site-packages" # site-packages del venv del hogar del doctor

# sesión de tmux del fixture (fila de `list-panes -a`): usuario sesion pid días-de-inactividad
panes_add() {
  local ts=$((NOW0 - $4 * 86400 - 60))
  printf '%s|%s|%s|%s\n' "$2" "$ts" "$ts" "$3" >> "$FX/panes.$1"
}

fx_nuevo() {
  local hogar c
  G=$((G + 1)); B="$T/g$G"
  FX="$B/fx"; RUN="$B/run"; CDIR="$RUN/talent-ceo/cursores"; FXSK="$B/clon/.claude/skills"; FXPK="$B/talent-factory"
  FXP="$B/perfil.tsv"; FXBUS="$B/bus.log"; HOMEH="$B/home"; SYS="$B/sys"; TOK="$B/tok/.env.local"
  DOC="$FXSK/talent-ceo/scripts/doctor.sh"; SEGDIR="$RUN/talent-ceo/seguridad"
  mkdir -p "$FX/tmux" "$RUN" "$B/tok" "$HOMEH/ejemplo" "$B/secret" "$B/tmp" "$SYS" \
    "$FXSK/talent-ceo" "$FXSK/talent-orchestrator" "$FXSK/talent-channel-operation" "$FXSK/talent-channels/assets"
  chmod 700 "$RUN"
  mkdir -p "$RUN/homes/daemon" "$RUN/homes/nobody" "$RUN/homes/bin"
  cp -r "$SK/talent-ceo/scripts" "$FXSK/talent-ceo/scripts"
  cp -r "$SK/talent-orchestrator/scripts" "$FXSK/talent-orchestrator/scripts"
  cp -r "$SK/talent-channel-operation/scripts" "$FXSK/talent-channel-operation/scripts"
  cp "$SK/talent-channels/assets/node-suelos.tsv" "$FXSK/talent-channels/assets/node-suelos.tsv"
  [ -z "${TEST_SEG_DOCTOR:-}" ] || cp "$TEST_SEG_DOCTOR" "$DOC" || { printf 'FAIL: TEST_SEG_DOCTOR no se pudo copiar: %s\n' "$TEST_SEG_DOCTOR"; exit 2; }
  [ -z "${TEST_SEG_LIB:-}" ] || cp "$TEST_SEG_LIB" "$FXSK/talent-ceo/scripts/lib-seguridad.sh" || { printf 'FAIL: TEST_SEG_LIB no se pudo copiar: %s\n' "$TEST_SEG_LIB"; exit 2; }
  printf 'PKG_IDENTITY_PROJECT=ejemplo\nTCO_REPO_DIR=repo-ejemplo\nTCO_REPO_SLUG=org-ejemplo/repo-ejemplo\nTCO_REPO_STACK=ninguno\nTCO_ANEXO_FILE=references/anexo-ejemplo.md\nTCO_LINEAR_INPROGRESS_STATE=11111111-1111-4111-8111-111111111111\nTCO_LINEAR_INREVIEW_STATE=22222222-2222-4222-8222-222222222222\nTCO_HOST_ENV_REL=ejemplo/.env.local\nTCO_TF_MANIFEST=%s/autoridad.conf\n' "$B" > "$FXSK/talent-channel-operation/scripts/repo-identity.conf"
  printf 'PKG_IDENTITY_PROJECT=ejemplo\nTORC_HOST_ENV_REL=ejemplo/.env.local\n' > "$FXSK/talent-orchestrator/scripts/repo-identity.conf"
  for hogar in "$HOMEH" "$RUN/homes/daemon" "$RUN/homes/nobody"; do
    mkdir -p "$hogar/.config/talent-channel-operation"
    printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 4-8 sonnet 5 > "$hogar/.config/talent-channel-operation/modelos.conf"
  done
  printf 'TF_PROJECT=ejemplo\nTF_REPO_URL=https://example.invalid/org-ejemplo/repo-ejemplo\n' > "$B/autoridad.conf"
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
  printf 'LINEAR_API_KEY=CANARIO-NO-DEBE-SALIR\n' > "$B/tok/.env.local"; chmod 600 "$B/tok/.env.local"
  printf 'LINEAR_API_KEY=CANARIO-NO-DEBE-SALIR\n' > "$HOMEH/ejemplo/.env.local"; chmod 600 "$HOMEH/ejemplo/.env.local"
  # Sondas de seguridad: Node al día, venvs limpios, sesiones activas con claude vivo.
  printf 'v24.22.1\n' > "$FX/node.host"
  for c in cont-canal-1 cont-runner-1; do
    printf 'v24.22.1\n' > "$FX/node.$c"; printf 'INICIO\n' > "$FX/scan.$c"
    printf 'v|%s|%s|701\n' "$((NOW0 - 300))" "$((NOW0 - 300))" > "$FX/panes.c.$c"
    printf '701 1 bash\n702 701 claude\n' > "$FX/ps.c.$c"
  done
  panes_add "$ME" ses-ceo 201 0; panes_add daemon ses-torre 301 0; panes_add nobody ses-est 401 0
  fx_python
  fx_paquete
}

# ═══ ejecución del doctor entre dos fotografías del árbol de fixtures ═════════════════════════
hash_arbol() {
  { local d f
    for d in "$RUN" "$HOMEH" "$SYS" "$FXPK" "$B/clon"; do
      /usr/bin/find "$d" -printf '%p %y %m %U %G %l\n' 2>/dev/null | sort
      while IFS= read -r -d '' f; do sha256sum -- "$f" 2>/dev/null; done < <(/usr/bin/find "$d" -type f -print0 2>/dev/null | sort -z)
    done
    sha256sum -- "$FXBUS"
  } | sha256sum
}
dr() { # VAR=valor… adicionales → OUT, RC
  local antes despues
  [ "$RO_CHECK" -eq 0 ] || antes="$(hash_arbol)"
  OUT="$(env -i PATH="$FXBIN:/usr/bin:/bin" HOME="$HOMEH" HOST_HOME="$HOMEH" SECRET_DIR="$B/secret" TMPDIR="$B/tmp" \
    XDG_RUNTIME_DIR="$RUN" SHIM_HOME_ROOT="$RUN/homes" TA_PERFIL="$FXP" TA_BUS="$FXBUS" FX="$FX" SHIM_ME="$ME" TCO_AUDIT_CLI=codex TCO_HOST_ENV="$TOK" \
    LC_ALL=C TA_PAQUETE="$FXPK" TA_PAQUETE_PUBLICADO="$B/publicado.zip" TA_SEG_RAIZ="$SYS" "$@" bash "$DOC" "${DOC_ARGS[@]}" 2>&1)"; RC=$?
  if [ "$RO_CHECK" -ne 0 ]; then despues="$(hash_arbol)"; [ "$antes" = "$despues" ] || RO_FAIL=$((RO_FAIL + 1)); fi
}
normal() { DOC_ARGS=(); dr "$@"; }
informe() { DOC_ARGS=(--informe); dr; DOC_ARGS=(); }
escribe() { # modo escritor `doctor.sh --seguridad`: escribe su resultado y su sello (no entra en la foto de solo lectura)
  DOC_ARGS=(--seguridad); RO_CHECK=0; dr "$@"; RO_CHECK=1; DOC_ARGS=(); W_OUT="$OUT"; W_RC="$RC"
}
completo() { escribe; normal; } # escritor y luego doctor normal (que LEE el resultado sellado)
n() { printf '%s\n' "$OUT" | grep -c -- "$1" || true; }
cuenta_fich() { /usr/bin/find "$1" -maxdepth 1 -name "$2" 2>/dev/null | grep -c . || true; } # dir patrón
nw() { printf '%s\n' "$W_OUT" | grep -c -- "$1" || true; }
avisos() { printf '%s\n' "$OUT" | sed -n "s/^AVISO seguridad-litellm $1: $2\( (cont\.)\)\{0,1\}: //p" | tr -d '\n'; }   # id etiqueta → el texto troceado en líneas AVISO, reconstruido
cats() { printf '%s\n' "$OUT" | awk '$1=="FALLA"{print $2}' | sort -u | paste -sd, -; }
nnov() { printf '%s\n' "$OUT" | grep -c '^NOVERIF' || true; }
resumen() { printf '%s\n' "$OUT" | grep '^RESUMEN'; }
solo() { assert_eq "$1: rc 1 y SOLO FALLA $2 (0 NOVERIF)" "1|$2|0" "$RC|$(cats)|$(nnov)"; }
nuevo_canales() { CON_CANALES=1; fx_nuevo; }
# Resultado sellado A MANO, como si el modo escritor hubiera corrido hace <horas> h: filas «ESTADO TAB sujeto TAB detalle».
# Variantes de la trampa (se ponen antes de llamar y se restauran solas): RES_DESFASE = segundos que `medido=` va por
# DELANTE (hacia atrás en el tiempo) de la hora del sello · RES_ROL = rol que firma el sello · RES_SELLO_MIN = minutos
# atrás a los que se pone el sello (por defecto, los mismos que las horas del resultado).
RES_DESFASE=0; RES_ROL=CEO; RES_SELLO_MIN=''
res_manual() { # horas filas… (cada argumento puede traer varias filas separadas por salto de línea)
  local h="$1" ts sha nf
  shift
  mkdir -p "$SEGDIR"; chmod 700 "$SEGDIR"
  ts=$((NOW0 - h * 3600))
  nf="$(printf '%s\n' "$@" | grep -c . || true)"
  { printf '# seguridad medido=%s prof-hogar=6 prof-canal=7 presupuesto=600 sujetos=%s sondas=%s fallas=0 noverif=0\n' \
      "$((ts - RES_DESFASE))" "$nf" "$(sha256sum "$FXSK/talent-ceo/scripts/doctor-sondas.tsv" | cut -c1-16)"
    printf '%s\n' "$@" | grep .; } > "$SEGDIR/ultimo.res"
  chmod 600 "$SEGDIR/ultimo.res"
  sha="$(sha256sum "$SEGDIR/ultimo.res" | cut -d' ' -f1)"
  sello "$RES_ROL" "SEG-${sha:0:12}" "${RES_SELLO_MIN:-$((h * 60))}"
  RES_DESFASE=0; RES_ROL=CEO; RES_SELLO_MIN=''
}
# Una fila OK por cada sujeto que el modo escritor mide en el fixture verde (host, sistema, señuelo, 3 usuarios del
# perfil —daemon, nobody, bin— y los dos contenedores con su señuelo).
OKFILA=''
for s in host/senuelo host/sistema host host/daemon host/nobody host/bin canal-uno canal-uno/senuelo run-uno run-uno/senuelo; do
  OKFILA+="OK"$'\t'"$s"$'\t'"sin indicadores"$'\n'
done
OKFILA="${OKFILA%$'\n'}"

# ═══ C1 · el VERDE ════════════════════════════════════════════════════════════════════════════
printf '== C1: todo al día, venvs limpios, sin zombis ==\n'
nuevo_canales; completo
assert_eq 'C1 el modo escritor termina bien y sella' '0|1' "$W_RC|$(nw '^SEGURIDAD sellado SEG-[0-9a-f]\{12\} ok=10 falla=0 noverif=0$')"
assert_eq 'C1 rc 0 y puerta abierta' '0|PUERTA ABIERTA' "$RC|$(printf '%s\n' "$OUT" | tail -n1)"
assert_eq 'C1 0 FALLA, 0 NOVERIF y 0 AVISO' 0 "$(n '^\(FALLA\|NOVERIF\|AVISO\) ')"
assert_eq 'C1 Node: host y los dos contenedores en OK' 3 "$(n '^OK seguridad-node ')"
assert_eq 'C1 LiteLLM: UNA línea con el resultado sellado (el doctor normal no busca)' 1 "$(n '^OK seguridad-litellm resultado: sellado hace 0 h ')"
assert_eq 'C1 zombi: tres usuarios y dos contenedores medidos' 5 "$(n '^OK zombi ')"
assert_eq 'C1 RESUMEN cuadra con las líneas OK y sin AVISO' "RESUMEN ok=$(n '^OK ') falla=0 noverif=0" "$(resumen)"
assert_eq 'C1 el 24.22.1 se compara con su suelo' 1 "$(n '^OK seguridad-node host: 24.22.1 >= 24.22.1$')"
assert_eq 'C1 el escritor deja su resultado 0600 en un directorio 0700 y lo sella en el bus' '600|700|1' "$(stat -c %a "$SEGDIR/ultimo.res")|$(stat -c %a "$SEGDIR")|$(grep -c '\[rol: CEO\] \[marcador: SEG-' "$FXBUS")"
informe
assert_eq 'C1 informe: Sin desviaciones, sin sección de avisos y puerta abierta' '0|1|0|PUERTA ABIERTA' "$RC|$(n '^Sin desviaciones\.$')|$(n '^Avisos informativos')|$(printf '%s\n' "$OUT" | tail -n1)"

printf '== M3: sin talent-channels el doctor AVISA en cada corrida; con él, las tres emiten ==\n'
AVISO_M3='AVISO seguridad sondas: no se evalúan Node, LiteLLM ni zombis: el manifiesto de la instancia no declara talent-channels'
CON_CANALES=0; fx_nuevo; normal; CON_CANALES=1
assert_eq 'M3 sin talent-channels: la línea AVISO exacta sale UNA vez, rc 0 y ninguna otra sonda' "1|0|0" "$(printf '%s\n' "$OUT" | grep -cFx "$AVISO_M3")|$RC|$(n '^[A-Z]* \(seguridad-node\|seguridad-litellm\|zombi\) ')"
assert_eq 'M3 el AVISO no toca RESUMEN ni cierra la puerta' "0|PUERTA ABIERTA" "$(resumen | grep -c 'falla=[1-9]')|$(printf '%s\n' "$OUT" | tail -n1)"
informe
assert_eq 'M3 informe: el AVISO sale con gravedad info y remedio' '1' "$(n '^| AVISO seguridad sondas: .* | info | Informativo: añadir talent-channels')"
nuevo_canales; completo
assert_eq 'M3 con talent-channels no hay AVISO de seguridad y las tres categorías emiten' '0|1|1|1' "$(n '^AVISO seguridad ')|$([ "$(n '^OK seguridad-node ')" -gt 0 ] && echo 1 || echo 0)|$([ "$(n '^OK seguridad-litellm ')" -gt 0 ] && echo 1 || echo 0)|$([ "$(n '^OK zombi ')" -gt 0 ] && echo 1 || echo 0)"

# ═══ C2 · Node por debajo del suelo ═══════════════════════════════════════════════════════════
printf '== C2: Node bajo el suelo de su mayor ==\n'
nuevo_canales; printf 'v24.20.0\n' > "$FX/node.cont-canal-1"; completo
solo 'C2 canal con 24.20.0' seguridad-node
assert_eq 'C2 línea exacta del canal' 1 "$(n '^FALLA seguridad-node canal-uno: 24.20.0 < 24.22.1$')"
nuevo_canales; printf 'v24.20.0\n' > "$FX/node.host"; completo
solo 'C2 host con 24.20.0' seguridad-node
assert_eq 'C2 línea exacta del host' 1 "$(n '^FALLA seguridad-node host: 24.20.0 < 24.22.1$')"
nuevo_canales; printf 'v22.23.3\n' > "$FX/node.host"; completo
solo 'C2 22.23.3 por debajo' seguridad-node
nuevo_canales; printf 'v22.23.4\n' > "$FX/node.host"; printf 'v26.12.1\n' > "$FX/node.cont-runner-1"; completo
assert_eq 'C2 22.23.4 y 26.12.1 cumplen su suelo' '0|0' "$RC|$(n '^FALLA')"
nuevo_canales; printf 'v20.19.0\n' > "$FX/node.host"; completo
solo 'C2 mayor sin suelo conocido falla cerrado' seguridad-node
assert_eq 'C2 el detalle dice que no hay suelo' 1 "$(n 'la mayor 20 no tiene suelo')"
nuevo_canales; printf '24\t24.30.0\n22\t22.23.4\n26\t26.12.1\n' > "$FXSK/talent-channels/assets/node-suelos.tsv"; completo
assert_eq 'C2 la lista de suelos es la del tsv (no hay segunda lista)' '1|3' "$RC|$(n '^FALLA seguridad-node .*< 24.30.0$')"

# ═══ C3 · indicadores de LiteLLM (los halla el modo escritor; el doctor normal los reporta como FALLA) ═══
printf '== C3: indicadores de la puerta trasera de LiteLLM ==\n'
nuevo_canales; printf 'x\n' > "$HOMEH/$SP/cook.pth"; completo
solo 'C3 cook.pth en el venv del host' seguridad-litellm
assert_eq 'C3 fila con la ruta y el fichero sigue ahí' "1|si|1" "$(n "^FALLA seguridad-litellm \($HOMEH\|[^ ]*\.\.\.[^ ]*\)/$SP/cook.pth: ")|$([ -f "$HOMEH/$SP/cook.pth" ] && echo si || echo no)|$W_RC"
nuevo_canales; printf 'x\n' > "$HOMEH/$SP/cook.py"; completo
solo 'C3 cook.py' seguridad-litellm
nuevo_canales; mkdir -p "$HOMEH/$SP/litellm-1.107.0.dist-info"; completo
solo 'C3 litellm-1.107.0.dist-info' seguridad-litellm
assert_eq 'C3 el dist-info sigue ahí' si "$([ -d "$HOMEH/$SP/litellm-1.107.0.dist-info" ] && echo si || echo no)"
nuevo_canales; : > "$SYS/tmp/remote_code_loader.lock"; completo
solo 'C3 señuelo remote_code_loader.lock en el host (comprobado aparte, no por el find)' seguridad-litellm
assert_eq 'C3 el señuelo sigue ahí y el resto de sujetos del host siguen midiéndose' 'si|1' "$([ -e "$SYS/tmp/remote_code_loader.lock" ] && echo si || echo no)|$(nw '^OK seguridad-litellm host/sistema:')"
nuevo_canales; mkdir -p "$RUN/homes/daemon/v/lib/python3.12/site-packages"; : > "$RUN/homes/daemon/v/lib/python3.12/site-packages/cook.pth"; completo
solo 'C3 venv de otro usuario del perfil (por sudo)' seguridad-litellm
assert_eq 'C3 el sujeto es ese usuario' 1 "$(n 'cook.pth: .*(host/daemon)')"
nuevo_canales; printf 'INICIO\n/home/v/lib/python3.12/site-packages/cook.pth\n' > "$FX/scan.cont-canal-1"; completo
solo 'C3 indicador dentro de un canal' seguridad-litellm
assert_eq 'C3 fila del canal' 1 "$(n '^FALLA seguridad-litellm /home/v/lib/python3.12/site-packages/cook.pth: .*(canal-uno)')"
nuevo_canales; : > "$FX/lock.cont-canal-1"; completo
solo 'C3 señuelo PRESENTE en un canal (su propia orden exacta)' seguridad-litellm
assert_eq 'C3 fila del señuelo del canal' 1 "$(n '^FALLA seguridad-litellm /tmp/remote_code_loader.lock: .*(canal-uno/senuelo)')"
nuevo_canales; printf 'x\n' > "$HOMEH/proj/.venv/lib/python3.12/site-packages/cook.pth"; completo
assert_eq 'C3 un hallazgo no se confunde con un OK del resultado' 0 "$(n '^OK seguridad-litellm resultado')"
nuevo_canales; mkdir -p "$HOMEH/p2/.venv/lib/python3.13t/site-packages"; : > "$HOMEH/p2/.venv/lib/python3.13t/site-packages/cook.pth"; completo
assert_eq 'm3: una librería python3.13t (CPython sin hilos) también se juzga' 1 "$(n '^FALLA seguridad-litellm .*python3.13t.*cook.pth')"
nuevo_canales; mkdir -p "$HOMEH/p3/lib/pypy3.10/site-packages"; : > "$HOMEH/p3/lib/pypy3.10/site-packages/cook.pth"; completo
assert_eq 'm3: una librería pypy3.10 también se juzga' 1 "$(n '^FALLA seguridad-litellm .*pypy3.10.*cook.pth')"
nuevo_canales; PL="$HOMEH/$(printf 'd%.0s' $(seq 1 220))/lib/pypy3.10/site-packages"; mkdir -p "$PL"; : > "$PL/cook.pth"; completo
assert_eq 'issue 9711: una ruta de >200 caracteres no cabe: la FALLA conserva el fichero final y las líneas AVISO reconstruyen la ruta exacta' '1|1|1' "$(n '^FALLA seguridad-litellm [^ ]*\.\.\.[^ ]*/cook.pth: ')|$([ "$(avisos ruta-completa 'ruta completa')" = "$PL/cook.pth" ] && echo 1 || echo 0)|$([ "${#PL}" -gt 200 ] && echo 1 || echo 0)"
nuevo_canales; L0=$((${#HOMEH} + 13)); K=$(((L0 / 170 + 1) * 170 - 1 - L0))   # la «ñ» (2 bytes) cae a caballo de un corte de 170 del AVISO
PL="$HOMEH/mi proyecto $(printf 'd%.0s' $(seq 1 "$K"))ñ$(printf 'd%.0s' $(seq 1 40))  otra/lib/pypy3.10/site-packages"; mkdir -p "$PL"; : > "$PL/cook.pth"; completo   # un solo componente (<= 255 bytes), a profundidad 5
assert_eq 'issue 9711: una ruta con espacios, doble espacio y una «ñ» en el corte: la FALLA lleva cook.pth y el AVISO reconstruye la ruta byte a byte' '1|1' "$(n '^FALLA seguridad-litellm .*cook.pth: ')|$([ "$(avisos ruta-completa 'ruta completa')" = "$PL/cook.pth" ] && echo 1 || echo 0)"
nuevo_canales; mkdir -p "$HOMEH/p4"; : > "$HOMEH/p4/cook.py"; completo
assert_eq 'm3: un cook.py de un proyecto (fuera de una librería de Python) no es hallazgo (límite documentado)' '0|0' "$RC|$(n '^FALLA seguridad-litellm')"

# ═══ C4 · sitecustomize.py ════════════════════════════════════════════════════════════════════
printf '== C4: el sitecustomize.py del sistema es legítimo; cualquier otro, no ==\n'
nuevo_canales; completo
assert_eq 'C4 el del sistema (ruta anclada /usr/lib/python3.N/) no da filas y su sujeto queda OK' '0|1' "$(n '^FALLA seguridad-litellm')|$(nw '^OK seguridad-litellm host/sistema:')"
nuevo_canales; printf 'import os\n' > "$HOMEH/$SP/sitecustomize.py"; completo
solo 'C4 sitecustomize.py ajeno en site-packages' seguridad-litellm
nuevo_canales; mkdir -p "$SYS/usr/lib/python3.13"; printf 'import os\n' > "$SYS/usr/lib/python3.13/sitecustomize.py"; completo
assert_eq 'C4 LÍMITE ACEPTADO (CEO, 23-oct-2026): un fichero regular en la ruta anclada del sistema no se distingue del enlace de Debian' '0|0' "$RC|$(n '^FALLA seguridad-litellm')"
nuevo_canales
mkdir -p "$HOMEH/falso/usr/lib/python3.12" "$HOMEH/falso/etc/python3.12"
printf 'import os\n' > "$HOMEH/falso/etc/python3.12/sitecustomize.py"
ln -s "$HOMEH/falso/etc/python3.12/sitecustomize.py" "$HOMEH/falso/usr/lib/python3.12/sitecustomize.py"
completo
solo 'C4 imitación de la ruta del sistema colgada de un hogar de usuario' seguridad-litellm

printf '== poda: node_modules, .git y la poda declarada no se recorren; un venv fuera de ellas sí ==\n'
nuevo_canales
mkdir -p "$HOMEH/proj/node_modules/x/lib/python3.12/site-packages" "$HOMEH/proj/.git/lib/python3.12/site-packages" "$HOMEH/.cache/y/lib/python3.12/site-packages"
: > "$HOMEH/proj/node_modules/x/lib/python3.12/site-packages/cook.pth"; : > "$HOMEH/proj/.git/lib/python3.12/site-packages/cook.py"; : > "$HOMEH/.cache/y/lib/python3.12/site-packages/cook.pth"
completo
assert_eq 'poda: indicadores bajo node_modules, .git y .cache no se recorren (la búsqueda real del host los salta)' '0|0' "$RC|$(n '^FALLA seguridad-litellm')"
: > "$HOMEH/$SP/cook.pth"; completo
assert_eq 'poda: el mismo indicador en un venv fuera de las podadas sigue dando FALLA' '1|1' "$RC|$(n '^FALLA seguridad-litellm .*cook.pth')"

# ═══ M1 · un rc ≠ 0 del find nunca es una búsqueda completa ═══════════════════════════════════
printf '== M1: permiso, raíz inexistente, tiempo: NOVERIF con su motivo, nunca OK ==\n'
if [ "$(id -u)" -eq 0 ]; then
  skip 'M1 subdirectorio ilegible: el runner corre como root y chmod 000 no impide leer'
else
  nuevo_canales; mkdir -p "$HOMEH/secreto/lib/python3.12/site-packages"; : > "$HOMEH/secreto/lib/python3.12/site-packages/cook.pth"; chmod 000 "$HOMEH/secreto"
  completo
  assert_eq 'M1 subdirectorio 000 con un cook.pth dentro: el escritor da NOVERIF con la ruta y «Permiso denegado», rc 1' '1|1' "$W_RC|$(nw "^NOVERIF seguridad-litellm host: búsqueda incompleta (rc=1): .*secreto.*\(Permission denied\|Permiso denegado\)")"
  assert_eq 'M1 y el doctor normal lo reporta como FALLA (nunca OK) con el sujeto' '1|0' "$(n '^FALLA seguridad-litellm host: búsqueda sin completar: .*\(Permission denied\|Permiso denegado\)')|$(n '^OK seguridad-litellm resultado')"
  chmod 755 "$HOMEH/secreto"
fi
nuevo_canales; mkdir -p "$SYS/opt/containerd"; chmod 000 "$SYS/opt/containerd"; completo
if [ "$(id -u)" -eq 0 ]; then skip 'M1 containerd 000: runner root'
else assert_eq 'M1 containerd (directorio de root) está en la poda declarada: no hace falta ninguna tolerancia por rc' '0|1' "$RC|$(n '^OK seguridad-litellm resultado')"; fi
chmod 755 "$SYS/opt/containerd"
nuevo_canales; mkdir -p "$HOMEH/otro-ilegible"; chmod 000 "$HOMEH/otro-ilegible"; completo
if [ "$(id -u)" -eq 0 ]; then skip 'M1 otro directorio ilegible: runner root'
else assert_eq 'M1 cualquier OTRO directorio ilegible no se tolera: NOVERIF del escritor' 1 "$(nw '^NOVERIF seguridad-litellm host: búsqueda incompleta')"; fi
chmod 755 "$HOMEH/otro-ilegible"
nuevo_canales; aparta "$SYS/opt"; completo
assert_eq 'M1 una raíz que no existe (/opt) es NOVERIF con su motivo, no OK' '1|1' "$W_RC|$(nw '^NOVERIF seguridad-litellm host/sistema: búsqueda incompleta (rc=1): .*opt.*\(No such file or directory\|No existe\)')"
nuevo_canales; escribe FX_TIMEOUT_RC=124
assert_eq 'M1 búsqueda agotada: NOVERIF que dice el presupuesto, el sujeto y la raíz' '1|1' "$W_RC|$(nw '^NOVERIF seguridad-litellm host: agotado tras 600 s en ')"
nuevo_canales; printf 'INICIO\n' > "$FX/scan.cont-canal-1"; printf '124\n' > "$FX/scanrc.cont-canal-1"; completo
assert_eq 'M1 búsqueda del canal agotada por su timeout (rc 124 con INICIO): NOVERIF con presupuesto, sujeto y raíces' '1|1' "$W_RC|$(nw '^NOVERIF seguridad-litellm canal-uno: agotado tras 600 s en /usr/lib /usr/local/lib /opt /home (prof. 7)$')"
nuevo_canales; : > "$FX/scan.cont-canal-1"; completo
assert_eq 'M1 búsqueda del canal sin INICIO (la orden no llegó a ejecutarse): NOVERIF y no OK' '1|1|0' "$W_RC|$(nw '^NOVERIF seguridad-litellm canal-uno: la orden no llegó')|$(nw '^OK seguridad-litellm canal-uno:')"
nuevo_canales; printf 'INICIO\n' > "$FX/scan.cont-canal-1"; printf '1\n' > "$FX/scanrc.cont-canal-1"; printf "/usr/bin/find: '/home/x': Permiso denegado\n" > "$FX/scanerr.cont-canal-1"; completo
assert_eq 'M1 rc 1 del find en el canal (permiso): NOVERIF con el motivo, ya no «búsqueda completa»' '1|1' "$W_RC|$(nw "^NOVERIF seguridad-litellm canal-uno: búsqueda incompleta (rc=1): .*Permiso denegado")"
nuevo_canales; : > "$FX/locksinfin.cont-canal-1"; completo
assert_eq 'M1 el señuelo del canal sin FIN: NOVERIF' 1 "$(nw '^NOVERIF seguridad-litellm canal-uno/senuelo:')"

# ═══ S · el doctor normal LEE el último resultado sellado ═════════════════════════════════════
printf '== S: resultado inexistente, viejo, rojo, con NOVERIF o con el sello que no cuadra ==\n'
nuevo_canales; normal
assert_eq 'S sin resultado: NOVERIF con su remedio (correr doctor.sh --seguridad) y el directorio COMPLETO en su línea AVISO (no se corta a 200)' '1|1|1' "$RC|$(n '^NOVERIF seguridad-litellm resultado: no existe .*doctor.sh --seguridad')|$([ "$(avisos resultado 'directorio completo')" = "$SEGDIR" ] && echo 1 || echo 0)"
ldir() { local d="$B"; while [ "${#d}" -lt "$1" ]; do d="$d/dddddddddddddddddddddddddddddd"; done; printf '%s' "$d"; }   # directorio de >= N caracteres bajo el temporal
for N in 150 250; do
  nuevo_canales; LD="$(ldir "$N")"; mkdir -p "$LD/seguridad"; chmod 755 "$LD/seguridad"; : > "$LD/seguridad/ultimo.res"; chmod 644 "$LD/seguridad/ultimo.res"; normal TA_BUS_STATE_DIR="$LD"
  assert_eq "H4 con un TA_BUS_STATE_DIR de $N caracteres: sale el motivo (NOVERIF) y el directorio COMPLETO en su línea AVISO, que no es NOVERIF" '1|1|1' "$([ "${#LD}" -ge "$N" ] && echo 1 || echo 0)|$(n '^NOVERIF seguridad-litellm resultado: el resultado o su directorio no son propios con modo 0600/0700')|$([ "$(avisos resultado 'directorio completo')" = "$LD/seguridad" ] && echo 1 || echo 0)"
done
nuevo_canales; res_manual 27 "$OKFILA"; normal
assert_eq 'S resultado de 27 h: FALLA (más de 26 h)' '1|1' "$RC|$(n '^FALLA seguridad-litellm resultado: resultado sellado hace 27 h (más de 26 h)')"
touch "$SEGDIR/ultimo.res"; normal
assert_eq 'S un touch no lo rejuvenece: el tiempo sale del sello del bus, no del mtime' 1 "$(n '^FALLA seguridad-litellm resultado: resultado sellado hace 27 h')"
nuevo_canales; res_manual 25 "$OKFILA"; normal
assert_eq 'S resultado de 25 h: OK, y sin ningún AVISO del directorio (solo sale con NOVERIF o FALLA)' '0|1|0' "$RC|$(n '^OK seguridad-litellm resultado: sellado hace 25 h ')|$(n '^AVISO seguridad-litellm resultado')"
nuevo_canales; res_manual 1 "$OKFILA" $'FALLA\t/home/x/cook.pth\tindicador de la puerta trasera de LiteLLM 1.107.0 (host)'; normal
assert_eq 'S resultado ROJO fresco: FALLA con el hallazgo' '1|1|0' "$RC|$(n '^FALLA seguridad-litellm /home/x/cook.pth: ')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; res_manual 1 "$OKFILA" $'NOVERIF\tcanal-uno\tagotado tras 600 s en /usr/lib /usr/local/lib /opt /home (prof. 7)'; normal
assert_eq 'S resultado con NOVERIF: FALLA (no NOVERIF), con el sujeto y la raíz' '1|1|0' "$RC|$(n '^FALLA seguridad-litellm canal-uno: búsqueda sin completar: agotado tras 600 s en /usr/lib /usr/local/lib /opt /home')|$(n '^NOVERIF seguridad-litellm')"
nuevo_canales; res_manual 1 "$OKFILA"; printf 'OK\thost/otro\tañadido a mano\n' >> "$SEGDIR/ultimo.res"; normal
assert_eq 'S contenido alterado (el sha ya no tiene sello): NOVERIF con su remedio' '1|1' "$RC|$(n '^NOVERIF seguridad-litellm resultado: el sha del resultado no tiene sello SEG- válido en el bus; .*doctor.sh --seguridad')"
nuevo_canales; res_manual 1 "$OKFILA"; chmod 644 "$SEGDIR/ultimo.res"; normal
assert_eq 'S resultado con modo 0644: NOVERIF' 1 "$(n '^NOVERIF seguridad-litellm resultado: el resultado o su directorio no son propios')"
nuevo_canales; res_manual 1 "$OKFILA"; printf '%s\n' "$(sed '1s/sondas=[0-9a-f]*/sondas=0000000000000000/' "$SEGDIR/ultimo.res")" > "$B/otro.res"; cp "$B/otro.res" "$SEGDIR/ultimo.res"; chmod 600 "$SEGDIR/ultimo.res"
sha="$(sha256sum "$SEGDIR/ultimo.res" | cut -d' ' -f1)"; sello CEO "SEG-${sha:0:12}" 60; normal
assert_eq 'S resultado de OTRAS sondas (doctor-sondas.tsv cambió) aunque tenga sello: NOVERIF con su remedio' 1 "$(n '^NOVERIF seguridad-litellm resultado: el resultado es de otras sondas')"
nuevo_canales; res_manual 1 "$OKFILA"; sello CEO "SEG-000000000000" 1; : > "$SEGDIR/ultimo.res"; normal
assert_eq 'S resultado vacío: NOVERIF (no hay sello de su sha)' 1 "$(n '^NOVERIF seguridad-litellm resultado:')"
nuevo_canales; res_manual -1 "$OKFILA"; normal
assert_eq 'S sello con hora FUTURA: NOVERIF, no FALLA ni OK' '1|0' "$(n '^NOVERIF seguridad-litellm resultado:')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; completo; mv "$SEGDIR/ultimo.res" "$B/guardado.res"; ln -s "$B/guardado.res" "$SEGDIR/ultimo.res"; normal
assert_eq 'S resultado que es un enlace simbólico: NOVERIF' 1 "$(n '^NOVERIF seguridad-litellm resultado: el resultado o su directorio no son propios')"

# ═══ N1 · el sello SEG- del cron se firma con el rol del CEO, pero NO es un sello de su sesión ═════
printf '== N1: un SEG- no escala, no acredita la sesión del CEO ni hace pasar menu-reciente ==\n'
NOW0="$(date -u +%s)"   # N1: los sellos se calculan con la hora de ESTE escenario, no con la del arranque (issue 9711)
CAP_MENU_CEO='  Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · ctx: 42%'
n1_menu() { # bus reconstruido: último HITO del CEO hace 30 min (posterior al inicio de su sesión) y el menú abierto en su pane
  : > "$FXBUS"; sello CEO HITO-1 30; sello est-uno HITO-E 20; sello torre-uno HITO-T 20
  printf '%s\n' "$CAP_MENU_CEO" > "$FX/tmux/$ME/ses-ceo.cap"
}
nuevo_canales; n1_menu; sello CEO ESCALA-CEO-r1 40; fx_cursores; escribe; normal
assert_eq 'N1 ESCALA-CEO-… y después el SEG- del cron real: sigue «escalado», sin FALLA bloqueo-sin-escalar' '1|0' "$(n '^OK escalado CEO: menú abierto y el último sello es ESCALA-CEO-r1$')|$(n '^FALLA bloqueo-sin-escalar')"
nuevo_canales; : > "$FXBUS"; sello CEO HITO-VIEJO 90; sello est-uno HITO-E 20; sello torre-uno HITO-T 20; fx_cursores; completo
assert_eq 'N1 un SEG- posterior al inicio de la sesión NO acredita al CEO (su último sello propio es anterior)' '1|0' "$(n '^FALLA acreditacion CEO: sin sello propio posterior al inicio de su sesión (último: HITO-VIEJO)$')|$(n '^OK acreditacion CEO')"
nuevo_canales; n1_menu; fx_cursores; escribe; normal
assert_eq 'N1 un SEG- de menos de 15 min NO hace pasar menu-reciente: FALLA bloqueo-sin-escalar' '1|0' "$(n '^FALLA bloqueo-sin-escalar CEO: ')|$(n '^OK menu-reciente CEO')"
nuevo_canales; n1_menu; sello CEO HITO-SEG-5 5; fx_cursores; normal
assert_eq 'N1 el filtro es por prefijo anclado: un HITO-SEG-… (no es SEG-…) sigue siendo un sello ordinario' '1|0' "$(n '^OK menu-reciente CEO: ')|$(n '^FALLA bloqueo-sin-escalar')"

# ═══ N2 · el lector exige cobertura: cada sujeto actual del perfil tiene su fila ═══════════════
printf '== N2: un resultado que no cubre a todos los sujetos (ni siquiera cero) no se da por medido ==\n'
nuevo_canales; res_manual 1; normal
assert_eq 'N2 resultado con CERO sujetos (cabecera sujetos=0): NOVERIF por cada uno de los 10 sujetos del perfil, nunca OK' '1|10|0' "$RC|$(n '^NOVERIF seguridad-litellm resultado: sujeto .* sin medir en el último resultado')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; res_manual 1 "$OKFILA"
tab canal canal-dos maq-mando cont-canal-2 - 'usuario=bin' >> "$FXP"; printf 'cont-canal-2,RUNNING\n' >> "$FX/incus.list"
printf 'v24.22.1\n' > "$FX/node.cont-canal-2"; printf 'INICIO\n' > "$FX/scan.cont-canal-2"; printf 'v|%s|%s|701\n' "$((NOW0 - 300))" "$((NOW0 - 300))" > "$FX/panes.c.cont-canal-2"
printf '701 1 bash\n702 701 claude\n' > "$FX/ps.c.cont-canal-2"; printf '501\n' > "$FX/aud-pid.cont-canal-2"; printf '501 1 bash\n502 501 codex\n' > "$FX/aud-ps.cont-canal-2"
normal
assert_eq 'N2 un canal añadido DESPUÉS del último cron: NOVERIF de canal-dos y de su señuelo, no OK' '1|1|0' "$(n '^NOVERIF seguridad-litellm resultado: sujeto canal-dos sin medir en el último resultado')|$(n '^NOVERIF seguridad-litellm resultado: sujeto canal-dos/senuelo sin medir')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; res_manual 1 "$OKFILA"; printf '%s\n' "$(sed '1s/sujetos=[0-9]*/sujetos=11/' "$SEGDIR/ultimo.res")" > "$B/otro.res"; cp "$B/otro.res" "$SEGDIR/ultimo.res"; chmod 600 "$SEGDIR/ultimo.res"
sha="$(sha256sum "$SEGDIR/ultimo.res" | cut -d' ' -f1)"; sello CEO "SEG-${sha:0:12}" 60; normal
assert_eq 'N2 la cabecera dice sujetos=11 y trae 10 filas (recortado o alterado): NOVERIF' '1|0' "$(n '^NOVERIF seguridad-litellm resultado: la cabecera declara sujetos=11 y el resultado trae 10 filas')|$(n '^OK seguridad-litellm resultado')"

# ═══ N3 · los controles anti-repetición del lector ═════════════════════════════════════════════
printf '== N3: tolerancia de 120 s entre lo medido y el sello, sello de otro rol, resultado viejo con sello falso ==\n'
nuevo_canales; RES_DESFASE=150; res_manual 1 "$OKFILA"; normal
assert_eq 'N3 medido 150 s antes del sello: NOVERIF (la hora no cuadra)' '1|1|0' "$RC|$(n '^NOVERIF seguridad-litellm resultado: la hora medida del resultado no cuadra con su sello')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; RES_DESFASE=100; res_manual 1 "$OKFILA"; normal
assert_eq 'N3 medido 100 s antes del sello (dentro de la tolerancia): OK' '0|1' "$RC|$(n '^OK seguridad-litellm resultado: sellado hace 1 h ')"
nuevo_canales; RES_SELLO_MIN=1; res_manual 72 "$OKFILA"; normal
assert_eq 'N3 resultado de hace 3 días con un sello falso recién puesto: NOVERIF (no se rejuvenece), ni OK ni FALLA por edad' '1|1|0|0' "$RC|$(n '^NOVERIF seguridad-litellm resultado: la hora medida del resultado no cuadra con su sello')|$(n '^FALLA seguridad-litellm resultado')|$(n '^OK seguridad-litellm resultado')"
nuevo_canales; RES_ROL=torre-uno; res_manual 1 "$OKFILA"; normal
assert_eq 'N3 sello SEG- de OTRO rol sobre el sha del resultado: NOVERIF (sin sello SEG- válido del CEO)' '1|1|0' "$RC|$(n '^NOVERIF seguridad-litellm resultado: el sha del resultado no tiene sello SEG- válido')|$(n '^OK seguridad-litellm resultado')"

# ═══ N4 · un solo escritor a la vez, y sellar ANTES de publicar ═══════════════════════════════
printf '== N4: flock entre escritores; temporal huérfano apartado (mv); sello fallido no publica ==\n'
nuevo_canales; mkdir -p "$SEGDIR"; chmod 700 "$SEGDIR"
r4="$( ( exec 8>"$SEGDIR/.lock"; flock -n 8 || exit 9; escribe; printf '%s|%s' "$W_RC" "$(printf '%s\n' "$W_OUT" | grep -c 'ya hay otra búsqueda de seguridad en marcha')" ) )"
assert_eq 'N4 con otra búsqueda en marcha (bloqueo tomado), el segundo --seguridad sale con rc 2, lo dice y no escribe nada' '2|1|no' "$r4|$([ -e "$SEGDIR/ultimo.res" ] && echo si || echo no)"
nuevo_canales; mkdir -p "$SEGDIR"; chmod 700 "$SEGDIR"; : > "$SEGDIR/.res.ABC123"; escribe
assert_eq 'N4 un temporal .res.* huérfano NO se borra: se aparta con mv a apartado/ y la corrida termina bien' '0|no|1' "$W_RC|$([ -e "$SEGDIR/.res.ABC123" ] && echo si || echo no)|$(cuenta_fich "$SEGDIR/apartado" '.res.ABC123.*')"
if [ "$(id -u)" -eq 0 ]; then skip 'N4 sello fallido: el runner corre como root y chmod 444 no impide escribir en el bus'
else
  nuevo_canales; escribe; antes="$(sha256sum "$SEGDIR/ultimo.res" | cut -d' ' -f1)"
  chmod 444 "$FXBUS"; escribe; chmod 644 "$FXBUS"
  despues="$(sha256sum "$SEGDIR/ultimo.res" | cut -d' ' -f1)"
  assert_eq 'N4 si el sello en el bus falla, rc 2, el resultado anterior queda intacto y el temporal va a apartado/ (no queda .res.*)' '2|igual|0|1' "$W_RC|$([ "$antes" = "$despues" ] && echo igual || echo cambiado)|$(cuenta_fich "$SEGDIR" '.res.*')|$(cuenta_fich "$SEGDIR/apartado" '.res.*')"
fi

# ═══ N5 · una cuenta del perfil sin hogar no se mide «a medias» ════════════════════════════════
printf '== N5: usuario del perfil sin hogar → NOVERIF host/<usuario> con su motivo ==\n'
nuevo_canales; escribe FX_SIN_HOGAR=bin
assert_eq 'N5 el hogar de bin no existe: NOVERIF host/bin con la causa (rc del find), y el escritor sale con rc 1' '1|1' "$W_RC|$(nw '^NOVERIF seguridad-litellm host/bin: búsqueda incompleta (rc=1): .*\(No such file\|No existe\)')"

# ═══ C5 · zombis ══════════════════════════════════════════════════════════════════════════════
printf '== C5: sesión con claude vivo e inactiva más de 25 días ==\n'
nuevo_canales; panes_add "$ME" viejo 601 26; printf '601 100 bash\n602 601 claude\n' >> "$FX/ps.txt"; completo
assert_eq 'C5 AVISO zombi 26 d y la puerta sigue abierta' "1|0|PUERTA ABIERTA" "$(n "^AVISO zombi $ME/viejo: 26 d\$")|$RC|$(printf '%s\n' "$OUT" | tail -n1)"
assert_eq 'C5 RESUMEN sin falla ni noverif y sin contar el AVISO' 'falla=0 noverif=0' "$(resumen | sed 's/^RESUMEN ok=[0-9]* //')"
informe
assert_eq 'C5 informe: fila con gravedad info y remedio, aparte de las desviaciones' '1|1|1|0' "$(n "^| AVISO zombi $ME/viejo: 26 d | info | Informativo")|$(n '^Sin desviaciones\.$')|$(n '^Avisos informativos')|$RC"
nuevo_canales; panes_add "$ME" viejo 601 24; printf '601 100 bash\n602 601 claude\n' >> "$FX/ps.txt"; completo
assert_eq 'C5 24 d no avisa' '0|0' "$(n '^AVISO')|$RC"
nuevo_canales; panes_add "$ME" viejo 601 40; printf '601 100 bash\n602 601 vim\n' >> "$FX/ps.txt"; completo
assert_eq 'C5 sin claude ni codex vivo no avisa' '0|0' "$(n '^AVISO')|$RC"
nuevo_canales; panes_add "$ME" viejo 601 40; printf '601 100 bash\n602 601 claude-code\n' >> "$FX/ps.txt"; completo
assert_eq 'C5 el ejecutable decide, no el nombre parecido' 0 "$(n '^AVISO')"
nuevo_canales; panes_add nobody viejo 601 40; printf '601 100 bash\n602 601 codex\n' >> "$FX/ps.txt"; completo
assert_eq 'C5 codex vivo de otro usuario del perfil (por sudo)' '1|0' "$(n '^AVISO zombi nobody/viejo: 40 d$')|$RC"
nuevo_canales; printf 'v|%s|%s|701\n' "$((NOW0 - 30 * 86400))" "$((NOW0 - 30 * 86400))" > "$FX/panes.c.cont-canal-1"; completo
assert_eq 'C5 sesión zombi dentro de un canal' '1|0' "$(n '^AVISO zombi canal-uno/v: 30 d$')|$RC"
nuevo_canales; printf 'v|%s|%s|701\n' "$((NOW0 - 40 * 86400))" "$((NOW0 - 60))" > "$FX/panes.c.cont-canal-1"; completo
assert_eq 'C5 actividad reciente de una ventana evita el aviso' 0 "$(n '^AVISO')"
nuevo_canales; panes_add "$ME" viejo 601 26; printf '601 100 bash\n602 601 claude\n' >> "$FX/ps.txt"
{ grep -v '^zombi' "$FXSK/talent-ceo/scripts/doctor-volver.tsv" > "$B/volver-sin-zombi.tsv"; cp "$B/volver-sin-zombi.tsv" "$FXSK/talent-ceo/scripts/doctor-volver.tsv"; }
completo
assert_eq 'C5 control negativo: sin remedio declarado, ni el AVISO ni el OK de zombi pasan: NOVERIF doctor.d y rc 1' '1|0|si' "$RC|$(n '^AVISO zombi')|$([ "$(n '^NOVERIF doctor.d')" -ge 1 ] && echo si || echo no)"

# ═══ C6 · lo que no se puede medir es NOVERIF, nunca OK ═══════════════════════════════════════
printf '== C6: node ausente, canal inalcanzable, suelos o sondas ilegibles ==\n'
nuevo_canales; aparta "${FX:?}/node.host"; completo
assert_eq 'C6 node del host no ejecutable: NOVERIF y ningún OK de Node del host' '1|1|0' "$RC|$(n '^NOVERIF seguridad-node host')|$(n '^OK seguridad-node host')"
nuevo_canales; printf 'hola\n' > "$FX/node.host"; completo
assert_eq 'C6 salida de node -v ilegible: NOVERIF' '1|1' "$RC|$(n '^NOVERIF seguridad-node host')"
nuevo_canales; aparta "${FX:?}/node.cont-canal-1"; completo
assert_eq 'C6 canal inalcanzable: NOVERIF de Node y nada OK de ese canal' '1|1|0' "$RC|$(n '^NOVERIF seguridad-node canal-uno')|$(n '^OK seguridad-node canal-uno')"
nuevo_canales; aparta "${FXSK:?}/talent-channels/assets/node-suelos.tsv"; completo
assert_eq 'C6 tsv de suelos ausente: un NOVERIF y ningún OK de Node' '1|1|0' "$RC|$(n '^NOVERIF seguridad-node suelos')|$(n '^OK seguridad-node ')"
nuevo_canales; : > "$FXSK/talent-channels/assets/node-suelos.tsv"; completo
assert_eq 'C6 tsv sin suelos: NOVERIF' '1|1' "$RC|$(n '^NOVERIF seguridad-node suelos')"
nuevo_canales; printf '24\t24.22.1\n24\t24.30.0\n' > "$FXSK/talent-channels/assets/node-suelos.tsv"; completo
assert_eq 'C6 mayor repetida en el tsv: NOVERIF' '1|1' "$RC|$(n '^NOVERIF seguridad-node suelos')"
nuevo_canales; escribe FX_TIMEOUT_RC=124; normal FX_TIMEOUT_RC=124
assert_eq 'C6 todo agotado por timeout: nada de Node en OK, y zombi NOVERIF (rc ≥ 2) en vez de callar' '0|1' "$(n '^OK seguridad-node')|$([ "$(n '^NOVERIF zombi')" -ge 1 ] && echo 1 || echo 0)"
nuevo_canales; printf '1 0 init\n' > "$FX/ps.txt"; completo
assert_eq 'C6 ps fallido o vacío no inventa zombis' 0 "$(n '^AVISO')"
nuevo_canales; printf 'nobody\nbin\n' > "$FX/sudo-allow"; completo
assert_eq 'C6 sudo no deja medir a otro usuario del perfil: NOVERIF en el escritor (la búsqueda) y en zombi, no omisión' '1|1' "$(nw '^NOVERIF seguridad-litellm host/daemon: sudo -n no autoriza')|$(n '^NOVERIF zombi daemon: sudo -n no autoriza')"
nuevo_canales; : > "$FX/sudo-solo-exactas"; completo
assert_eq 'C6 montaje con sudoers de consultas exactas: Node y zombi de cada canal en NOVERIF y la búsqueda del escritor también, nunca OK' '2|2|2|0' "$(n '^NOVERIF seguridad-node .*: sudo -n no autoriza')|$(n '^NOVERIF zombi .*: sudo -n no autoriza')|$(nw '^NOVERIF seguridad-litellm canal-uno\(/senuelo\)\?: sudo -n no autoriza')|$(nw '^OK seguridad-litellm canal-uno')"
nuevo_canales; printf '%s\n' "$(perfil_verde | grep -v '^canal	\|^runner	')" > "$FXP"; completo
assert_eq 'M3 sin canales ni runners declarados: líneas explícitas «nada que medir en canales» en Node y zombi, no silencio' '1|1' "$(n '^OK seguridad-node canales: ningún canal ni runner RUNNING')|$(n '^OK zombi canales: ningún canal ni runner RUNNING')"

# ═══ fuente única: lo que el doctor pide por sudo es EXACTAMENTE lo que dice doctor-sondas.tsv ═══
printf '== fuente única: lo que el doctor pide por sudo es EXACTAMENTE lo que dice doctor-sondas.tsv ==\n'
# Expansión INDEPENDIENTE del tsv (awk, sin el lector del doctor) de las órdenes de ámbito canal y usuario del fixture.
expande_tsv() { # → «usuario TAB argumentos separados por 0x1f», una línea por orden que debe pasar por sudo
  local c u pres
  pres="$(awk -F'\t' '$1 == "presupuesto-s" && $2 == "const" { print $3 }' "$ROOT/scripts/doctor-sondas.tsv")"
  for c in cont-canal-1 cont-runner-1; do
    awk -F'\t' -v dest=bin -v cont="$c" -v cuser=vivecoder -v pres="$pres" '$0 !~ /^#/ && $2 == "canal" {
      printf "%s\t", dest; for (i = 3; i <= NF; i++) { a = $i; gsub(/\{contenedor\}/, cont, a); gsub(/\{cuser\}/, cuser, a); gsub(/\{presupuesto\}/, pres, a); printf "%s\037", a }; printf "\n" }' "$ROOT/scripts/doctor-sondas.tsv"
  done
  for u in daemon nobody bin; do
    awk -F'\t' -v dest="$u" -v hogar="$RUN/homes/$u" '$0 !~ /^#/ && $2 == "usuario" {
      printf "%s\t", dest; for (i = 3; i <= NF; i++) { a = $i; gsub(/\{hogar\}/, hogar, a); printf "%s\037", a }; printf "\n" }' "$ROOT/scripts/doctor-sondas.tsv"
  done
}
sondas_reales() { # las órdenes de sonda que el doctor pasó por sudo (el doble las registra en sudo.argv)
  awk -F'\t' '{ n = split($2, a, "\037"); last = a[n - 1]
    if (a[1] == "/usr/bin/find" || (a[1] == "tmux" && a[2] == "list-panes" && a[3] == "-a") ||
        (a[1] == "incus" && a[2] == "exec" && last ~ /^(node -v|echo INICIO|ps -e -o pid=,ppid=,comm=)/)) print }' "$FX/sudo.argv"
}
nuevo_canales; completo
esperado="$(expande_tsv | sort -u)"; real="$(sondas_reales | sort -u)"
assert_eq 'fuente única: 16 órdenes distintas (5 por contenedor × 2 + 2 por usuario × 3)' 16 "$(printf '%s\n' "$esperado" | grep -c .)"
assert_eq 'fuente única: las órdenes por sudo del doctor y del escritor == la expansión del tsv (ni una más ni una menos)' '' "$(diff <(printf '%s\n' "$esperado") <(printf '%s\n' "$real"))"
assert_eq 'fuente única: ninguna orden de sonda lleva comodín de fnmatch (* ? [ ]) ni barra invertida' 0 "$(printf '%s\n' "$real" | awk -F'\t' '$2 ~ /[*?\[\]\\]/' | grep -c .)"

printf '== remedios, solo lectura y límites ==\n'
faltan=''
for categoria in seguridad seguridad-node seguridad-litellm zombi; do
  grep -q "^$categoria"$'\t' "$ROOT/scripts/doctor-volver.tsv" || faltan+=" $categoria"
done
assert_eq 'las categorías de seguridad tienen remedio en la tabla' '' "$faltan"
assert_eq 'gravedades: node y litellm altas, zombi y el aviso de alcance bajas' 'alta|alta|baja|baja' "$(awk -F'\t' '$1=="seguridad-node"{a=$2} $1=="seguridad-litellm"{b=$2} $1=="zombi"{c=$2} $1=="seguridad"{d=$2} END{print a"|"b"|"c"|"d}' "$ROOT/scripts/doctor-volver.tsv")"
nuevo_canales
assert_eq 'el doctor y su librería no usan kill, pkill ni la forma prohibida de buscar procesos' 0 "$(cat "$DOC" "$FXSK/talent-ceo/scripts/lib-seguridad.sh" | grep -cE 'pgrep -f|pkill|kill -9|--skip' || true)"
assert_eq 'todo find del doctor y de su librería va con la ruta absoluta de /usr/bin' 0 "$(cat "$DOC" "$FXSK/talent-ceo/scripts/lib-seguridad.sh" | grep -cE '(^|[^/])find ' || true)"
assert_eq 'solo lectura: el árbol de fixtures no cambió en ninguna corrida del doctor normal' 0 "$RO_FAIL"

printf '\n== %d ok, %d FAIL (esperados: %d casos; no medidos: %d) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO" "$SKIP"
rc=0
[ "$FAIL" -eq 0 ] || rc=1
[ $((PASS+FAIL+SKIP)) -eq "$TOTAL_ESPERADO" ] || { printf 'FAIL: autoconteo %s != %s\n' "$((PASS+FAIL+SKIP))" "$TOTAL_ESPERADO"; rc=1; }
exit "$rc"
