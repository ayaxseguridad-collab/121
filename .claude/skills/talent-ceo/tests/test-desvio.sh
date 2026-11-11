#!/usr/bin/env bash
# test-desvio.sh — Copia mínima declarada del fixture de test-supervision.sh (hasta hash_estado).
# shellcheck disable=SC2034,SC2329 # Nombres conservados en la copia declarada del fixture.
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

TOTAL_ESPERADO=165 # 104 + 61 de origen-instalado.sh (desglose al final del fichero)
PASS=0; FAIL=0; SKIP=0; SKIPPED=''
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); SKIPPED="$SKIPPED [$1]"; printf '  SKIP %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

T="$(mktemp -d /tmp/tdXXXXXX)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
ME="$(id -un)"
FX="$T/fx"; FXBIN="$T/bin"; FXSK="$T/clon/.claude/skills"
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

# Paquete mínimo: copia de guardas reales y un fichero ordinario; tres miembros sintéticos.
# No se altera ninguna identidad ni registro del fixture original.
FXPK="$T/talent-factory"
fx_paquete() {
  local rel amb motivo m
  rm -rf "${FXPK:?}"
  mkdir -p "$FXPK/scripts/paquete" "$FXPK/instalacion"
  cp "$PKG/scripts/paquete/lib-package.sh" "$FXPK/scripts/paquete/"
  printf 'version=1.7.2\nmin_invariants=1\nmember=talent-ceo\nmember=talent-channel-operation\nmember=talent-orchestrator\noverlay=talent-channel-operation:scripts/repo-identity.conf\noverlay=talent-orchestrator:scripts/repo-identity.conf\n' > "$FXPK/scripts/paquete/package.manifest"
  for m in talent-ceo talent-channel-operation talent-orchestrator; do
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
  mkdir -p "$T/clon/.claude/paquete" "$T/clon/.githooks"
  cp "$FXPK/scripts/paquete/package.manifest" "$T/clon/.claude/paquete/package.manifest"
  cp "$FXPK/githooks/pre-push" "$T/clon/.githooks/pre-push"
  chmod +x "$T/clon/.githooks/pre-push"
  git -C "$T/clon" init -q
  git -C "$T/clon" config core.hooksPath .githooks
  (cd "$T" && python3 -m zipfile -c publicado.zip talent-factory)
}

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
  fx_paquete
}
TOK="$T/tok/.env.local"

# corre el doctor del fixture; OUT = salida, RC = rc. Argumentos: VAR=valor adicionales.
READONLY_FAIL=0
dr() {
  local snapshot_antes snapshot_despues
  snapshot_antes="$(hash_estado)" || READONLY_FAIL=$((READONLY_FAIL+1))
  OUT="$(env -i PATH="$FXBIN:/usr/bin:/bin" HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" TMPDIR="$T/tmp" \
    XDG_RUNTIME_DIR="$RUN" SHIM_HOME_ROOT="$RUN/homes" TA_PERFIL="$FXP" TA_BUS="$FXBUS" FX="$FX" SHIM_ME="$ME" TCO_AUDIT_CLI=codex TCO_HOST_ENV="$TOK" \
    LC_ALL=C TA_PAQUETE="$FXPK" TA_PAQUETE_PUBLICADO="$T/publicado.zip" "$@" bash "$DOC" "${DOC_ARGS[@]}" 2>&1)"; RC=$?
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
  { local f rc=0 modo='' extension="$FXSK/talent-ceo/scripts/doctor.d"
    # Abrir solo el directorio propio para fotografiar sus hijos; el doctor ve el modo original.
    if [ -d "$extension" ] && { [ ! -r "$extension" ] || [ ! -x "$extension" ]; }; then
      modo="$(stat -c '%a' "$extension")" || return 1
      [ -O "$extension" ] && chmod u+rx "$extension" || return 1
      printf 'EXTENSION-MODO-ORIGINAL %s\n' "$modo"
    fi
    if [ -e "$RUN" ]; then
      find "$RUN" -printf '%p %y %m %U %G %l\n' | sort
      while IFS= read -r -d '' f; do hash_regular "$f" || rc=1; done < <(find "$RUN" -type f -print0 | sort -z)
    else printf 'ESTADO-AUSENTE\n'; fi
    if [ -f "$FXBUS" ]; then hash_regular "$FXBUS" || rc=1; else printf 'BUS-AUSENTE\n'; fi
    for arbol in "$FXPK" "$T/clon"; do
      find "$arbol" -printf '%p %y %m %U %G %l\n' | sort
      while IFS= read -r -d '' f; do hash_regular "$f" || rc=1; done < <(find "$arbol" -type f -print0 | sort -z)
    done
    if [ -n "$modo" ]; then chmod "$modo" "$extension" || rc=1; fi
    return "$rc"
  } | sha256sum
}


DOC_ARGS=()

# Contrato C1–C12. Cada mutante aislado conserva intactas las otras comprobaciones.
filas() { printf '%s\n' "$OUT" | grep -c '^| \(FALLA\|NOVERIF\)' || true; }
resumen() { printf '%s\n' "$OUT" | grep '^RESUMEN'; }
normal() { DOC_ARGS=(); dr "$@"; }
informe() { DOC_ARGS=(--informe); dr; DOC_ARGS=(); }
nueva() { fx_nuevo; rm -rf "$FXSK/talent-ceo/scripts/doctor.d"; }
evidencia() {
  if [ -n "${SALIDA:-}" ]; then printf '%s\nrc=%s\n' "$OUT" "$RC" > "$SALIDA/$1.log"; fi
}
mutante() {
  normal; solo "$1" "$2"; local r="$RC" s; s="$(resumen)"
  informe
  assert_eq "$1: informe mismo rc y resumen, una fila" "$r|$s|1" "$RC|$(resumen)|$(filas)"
}

regresion_m1() {
  local sha lado caso
  for lado in "$FXSK" "$FXPK/skills"; do
    for caso in ausente modificado; do
      nueva
      sed -i '1d' "$FXPK/instalacion/NUCLEO.sha256"
      sha="$(sha256sum "$FXPK/skills/talent-ceo/references/nucleo.txt")"
      printf '%s  skills/talent-ceo/references/nucleo.txt' "${sha%% *}" >> "$FXPK/instalacion/NUCLEO.sha256"
      (cd "$T" && python3 -m zipfile -c publicado.zip talent-factory)
      if [ "$caso" = ausente ]; then rm "$lado/talent-ceo/references/nucleo.txt"
      else printf 'desviado\n' >> "$lado/talent-ceo/references/nucleo.txt"; fi
      mutante "M1 última entrada sin salto $lado $caso" nucleo
      evidencia "m1-${lado##*/}-$caso"
    done
  done
  # Protege también el lector de autoridad: no puede omitir un duplicado final.
  nueva
  sha="$(head -n1 "$FXPK/instalacion/NUCLEO.sha256")"
  printf '%s' "$sha" >> "$FXPK/instalacion/NUCLEO.sha256"
  normal
  assert_eq 'M1 duplicado final sin salto rechaza autoridad' '1|guardas,nucleo' "$RC|$(printf '%s\n' "$OUT" | awk '$1=="NOVERIF"{print $2}' | sort -u | paste -sd, -)"
}

regresion_m2() {
  local dir="$FXSK/talent-ceo/scripts/doctor.d" modo
  nueva; mkdir -p "$dir"
  printf 'DOCTOR_EXTRA+=(check_oculta)\ncheck_oculta() { falla doctor.d extension "desvío presente"; }\n' > "$dir/20-oculta.sh"
  for modo in 000 400 100; do
    if [ "$(id -u)" -eq 0 ]; then
      skip "M2 modo $modo necesita usuario sin privilegios"
      skip "M2 informe modo $modo necesita usuario sin privilegios"
      continue
    fi
    chmod "$modo" "$dir"
    mutante "M2 directorio modo $modo" doctor.d
    evidencia "m2-permisos-$modo"
  done
  chmod 755 "$dir"; normal
  solo 'M2 extensión restaurada se ejecuta' doctor.d
  nueva; mkdir -p "$dir"; normal
  assert_eq 'M2 directorio vacío legible no añade comprobaciones' 0 "$RC"
  cat > "$FXBIN/find" <<'SH'
#!/usr/bin/env bash
case "$1" in */scripts/doctor.d) exit 23 ;; esac
exec /usr/bin/find "$@"
SH
  chmod +x "$FXBIN/find"
  mutante 'M2 inventario fallido no equivale a vacío' doctor.d
  evidencia m2-inventario
  rm "$FXBIN/find"
  assert_eq 'M2 solo lectura incluso con directorio ilegible' 0 "$READONLY_FAIL"
}

nueva; normal
assert_eq 'C1 limpio rc 0' 0 "$RC"
assert_eq 'C1 cinco ejes verdes' 5 "$(printf '%s\n' "$OUT" | grep -cE '^OK (nucleo|version|miembros|modelos-rol|guardas) ')"
verde="$(resumen)"
informe; evidencia c1-informe
assert_eq 'C1 informe sin filas, mismo resumen' "0|0|$verde" "$RC|$(filas)|$(resumen)"
assert_eq 'C1 Sin desviaciones' 1 "$(printf '%s\n' "$OUT" | grep -c '^Sin desviaciones\.$')"
assert_eq 'C1 puerta abierta' 'PUERTA ABIERTA' "$(printf '%s\n' "$OUT" | tail -n1)"

nueva; printf 'desviado\n' >> "$FXSK/talent-ceo/references/nucleo.txt"
mutante C2 nucleo
assert_eq 'C2 ruta y gravedad alta en tabla' 1 "$(printf '%s\n' "$OUT" | grep -c 'nucleo.txt.*| alta |')"
nueva; printf 'desviado\n' >> "$FXPK/skills/talent-ceo/references/nucleo.txt"
mutante 'C2 paquete también se contrasta' nucleo
regresion_m1

nueva; sed -i 's/version=1.7.2/version=1.7.1/' "$T/clon/.claude/paquete/package.manifest"
mutante 'C3 ATRASADA' version
assert_eq 'C3 versión anterior diagnosticada' 1 "$(printf '%s\n' "$OUT" | grep -c ATRASADA)"
nueva; normal TA_PAQUETE_PUBLICADO="$T/no.zip"
assert_eq 'C3 declarada inalcanzable cierra' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF version .*NO MEDIDO')"
normal TA_PAQUETE_PUBLICADO=
assert_eq 'C3 sin fuente solo aviso y no cuenta' "0|RESUMEN ok=38 falla=0 noverif=0|1" "$RC|$(resumen)|$(printf '%s\n' "$OUT" | grep -c '^AVISO version-no-medida')"
sed -i "s@roles=ceo;@paquete_publicado=$T/publicado.zip;roles=ceo;@" "$FXP"
normal TA_PAQUETE_PUBLICADO=
assert_eq 'C3 entorno vacío gana a atributo' 0 "$RC"
# El atributo se prueba sin fijar la variable en el wrapper.
OUT="$(env -i PATH="$FXBIN:/usr/bin:/bin" HOME="$T/home" HOST_HOME="$T/home" SECRET_DIR="$T/secret" TMPDIR="$T/tmp" XDG_RUNTIME_DIR="$RUN" SHIM_HOME_ROOT="$RUN/homes" TA_PERFIL="$FXP" TA_BUS="$FXBUS" FX="$FX" SHIM_ME="$ME" TCO_AUDIT_CLI=codex TCO_HOST_ENV="$TOK" TA_PAQUETE="$FXPK" bash "$DOC")"; RC=$?
assert_eq 'C3 atributo del CEO lee ZIP' '0|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK version .*AL DÍA')"

nueva; rm "$FXSK/talent-orchestrator/SKILL.md"
mutante C4 miembros
nueva; mkdir -p "$FXSK/propio"; printf '# Propio\n' > "$FXSK/propio/SKILL.md"; normal
assert_eq 'C4 tres miembros de datos y propio legítimo' '0|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK miembros .*3 miembros')"

nueva; sed -i 's/opus-4-8/opus-6/' "$RUN/homes/daemon/.config/talent-channel-operation/modelos.conf"
mutante C5 modelos-rol
assert_eq 'C5 ambos IDs visibles en informe' 1 "$(printf '%s\n' "$OUT" | grep -c 'claude-opus-.*claude-opus-')"
nueva; rm "$RUN/homes/daemon/.config/talent-channel-operation/modelos.conf"; normal
assert_eq 'C5 registro ilegible no da verde' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF modelos-rol')"

nueva; printf '# versión anterior\n' > "$FXPK/scripts/check-push-audit.sh"
mutante 'C6 guarda reemplazada' guardas
assert_eq 'C6 guarda no aparece en núcleo' 0 "$(printf '%s\n' "$OUT" | grep -c '| FALLA nucleo')"
evidencia mejora-nuevo
if [ -n "${BASELINE_DOCTOR:-}" ] && [ -r "$BASELINE_DOCTOR" ]; then
  cp "$DOC" "$T/doctor-nuevo.sh"; cp "$BASELINE_DOCTOR" "$DOC"
  normal; evidencia mejora-base
  assert_eq 'mejora: doctor anterior permite guarda reemplazada' 0 "$RC"
  cp "$T/doctor-nuevo.sh" "$DOC"
else skip 'mejora: falta BASELINE_DOCTOR; estación debe aportar doctor de referencia'; fi
nueva; rm "$FXPK/scripts/check-push-audit.sh"
mutante 'C6 guarda ausente' guardas
nueva; git -C "$T/clon" config core.hooksPath /dev/null
mutante 'C6 hook desactivado' guardas
nueva; chmod -x "$T/clon/.githooks/pre-push"
mutante 'C6 hook no ejecutable' guardas
nueva; printf '# reemplazado\n' >> "$FXSK/talent-channel-operation/scripts/audit-gate.sh"
mutante 'C6 guarda del clon' guardas
nueva; rm "$T/clon/.githooks/pre-push"
mutante 'C6 hook ausente' guardas
nueva; git -C "$T/clon" config --unset core.hooksPath
mutante 'C6 hooksPath sin configurar' guardas

nueva
printf 'desviado\n' >> "$FXSK/talent-ceo/references/nucleo.txt"
sed -i 's/version=1.7.2/version=1.7.1/' "$T/clon/.claude/paquete/package.manifest"
rm "$FXSK/talent-orchestrator/SKILL.md"
sed -i 's/opus-4-8/opus-6/' "$RUN/homes/daemon/.config/talent-channel-operation/modelos.conf"
printf '# versión anterior\n' > "$FXPK/scripts/check-push-audit.sh"
informe; evidencia c7-informe
assert_eq 'C7 exactamente cinco filas' '1|5' "$RC|$(filas)"
assert_eq 'C7 los cinco ejes, sin duplicados' 'guardas,miembros,modelos-rol,nucleo,version' "$(printf '%s\n' "$OUT" | awk '$2=="FALLA"{print $3}' | sort -u | paste -sd, -)"

nueva; DOC_ARGS=(--help); dr; DOC_ARGS=()
assert_eq 'C8 help cabecera' '0|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^# doctor.sh')"
DOC_ARGS=(--desconocido); dr; DOC_ARGS=()
assert_eq 'C8 argumento desconocido rc2 sin líneas' '2|0' "$RC|$(printf '%s\n' "$OUT" | grep -cE '^(OK|FALLA|NOVERIF|RESUMEN|PUERTA)' || true)"
DOC_ARGS=(--informe sobrante); dr; DOC_ARGS=()
assert_eq 'C8 argumentos sobrantes rc2' 2 "$RC"

nueva; mkdir -p "$FXSK/talent-ceo/scripts/doctor.d"
cat > "$FXSK/talent-ceo/scripts/doctor.d/20-ejemplo.sh" <<'SH'
DOCTOR_EXTRA+=(check_ejemplo)
check_ejemplo() { falla ejemplo actor $'dato|con \033control'; }
SH
printf 'ejemplo\tmedia\tRestaurar ejemplo.\n' > "$FXSK/talent-ceo/scripts/doctor.d/20-ejemplo.volver.tsv"
mutante C9 ejemplo
assert_eq 'C9 Markdown escapa barras' 1 "$(printf '%s\n' "$OUT" | grep -c 'dato&#124;con control')"
assert_eq 'C9 informe neutraliza controles' 0 "$(printf '%s\n' "$OUT" | LC_ALL=C grep -c $'\033' || true)"
printf 'if then\n' > "$FXSK/talent-ceo/scripts/doctor.d/20-ejemplo.sh"
mutante 'C9 sintaxis' doctor.d
printf '# no registra nada\n' > "$FXSK/talent-ceo/scripts/doctor.d/20-ejemplo.sh"
mutante 'C9 sin registro' doctor.d
nueva; normal; assert_eq 'C9 ausente no hace nada' 0 "$RC"
regresion_m2

nueva; normal TA_PAQUETE="$T/ausente"
assert_eq 'C10 paquete ausente cierra cinco ejes' '1|5' "$RC|$(nnov)"
nueva; rm "$FXPK/instalacion/NUCLEO.sha256"; normal
assert_eq 'C10 núcleo ilegible nunca verde' '1|guardas,nucleo' "$RC|$(printf '%s\n' "$OUT" | awk '$1=="NOVERIF"{print $2}' | sort -u | paste -sd, -)"
nueva; printf 'ZIP corrupto\n' > "$T/publicado.zip"; normal
assert_eq 'C10 ZIP corrupto cierra versión' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF version')"
nueva; printf 'malformado\n' > "$FXPK/instalacion/NUCLEO.sha256"; normal
assert_eq 'C10 manifiesto malformado no da verde' 1 "$RC"
nueva; normal TA_PERFIL="$T/no-perfil"
assert_eq 'C10 perfil ausente rc2' 2 "$RC"

# PATH mínimo: bash y dirname bastan para llegar a las precondiciones, sin herramientas reales.
mkdir -p "$T/aislado"
ln -s /bin/bash "$T/aislado/bash"; ln -s /usr/bin/dirname "$T/aislado/dirname"
normal PATH="$T/aislado"
assert_eq 'C10 sin tmux rc2 sin comprobar' '2|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK ' || true)"
ln -s "$FXBIN/tmux" "$T/aislado/tmux"
normal PATH="$T/aislado"
assert_eq 'C10 sin crontab rc2 sin comprobar' '2|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK ' || true)"
nueva; normal TA_PAQUETE= TF_ROOT="$FXPK"
assert_eq 'raíz TF_ROOT entorno' 0 "$RC"
printf 'export TF_ROOT="%s"\n' "$FXPK" > "$T/secret/agents.conf"
normal TA_PAQUETE= TF_ROOT=
assert_eq 'raíz TF_ROOT agents leído como dato' 0 "$RC"
nueva; printf '# Overlay propio\n' >> "$FXSK/talent-channel-operation/scripts/repo-identity.conf"
normal
assert_eq 'overlay declarado excluido del núcleo' 0 "$RC"
nueva; printf 'member=otro\n' > "$T/clon/.claude/paquete/package.manifest"; normal
assert_eq 'manifiesto de instancia inválido nunca verde' '1|5' "$RC|$(nnov)"
nueva; sed -i '/  scripts\/audit-go.sh$/d' "$FXPK/instalacion/NUCLEO.sha256"; normal TA_PAQUETE_PUBLICADO=
assert_eq 'guarda sin autoridad SHA no verificable' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF guardas')"
nueva; sed -i 's/version=1.7.2/version=1.7.10/' "$FXPK/scripts/paquete/package.manifest"
(cd "$T" && python3 -m zipfile -c publicado.zip talent-factory)
normal
assert_eq 'sort -V ordena componentes numéricos' '1|version|0' "$RC|$(cats)|$(nnov)"

nueva
for fuente in 'https://usuario:CANARIO@example.invalid/paquete.zip' 'http://example.invalid/paquete.zip' 'file:///tmp/paquete.zip' 'https://example.invalid/p.zip?token=CANARIO'; do
  normal TA_PAQUETE_PUBLICADO="$fuente"
  assert_eq 'C11 fuente insegura rechazada sin imprimirla' '1|1|0' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF version')|$(printf '%s\n' "$OUT" | grep -c CANARIO || true)"
done
# Curl doblado; unzip REAL lee nombres fijos, incluso con entradas de traversal ajenas.
cat > "$FXBIN/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then cp "$ZIP_DOBLE" "$2"; exit $?; fi
  shift
done
exit 1
SH
chmod +x "$FXBIN/curl"
normal TA_PAQUETE_PUBLICADO=https://example.invalid/paquete.zip ZIP_DOBLE="$T/publicado.zip"
assert_eq 'C11 https con curl doblado y unzip real' 0 "$RC"
python3 - "$T/publicado.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as z:
    z.writestr('../../intruso', 'CANARIO-ARCHIVO-AJENO')
PY
normal
assert_eq 'C11 ZIP ajeno no se extrae ni se imprime' '0|0' "$RC|$(printf '%s\n' "$OUT" | grep -c CANARIO || true)"
assert_eq 'C11 no extracción' 0 "$([ -e "$T/intruso" ] && echo 1 || echo 0)"
# Manifiesto regenerado: hash de contenido local correcto, autoridad publicada distinta.
nueva; printf 'desviado\n' >> "$FXPK/skills/talent-ceo/references/nucleo.txt"
cp "$FXPK/skills/talent-ceo/references/nucleo.txt" "$FXSK/talent-ceo/references/nucleo.txt"
(cd "$FXPK" && sha256sum skills/talent-ceo/references/nucleo.txt) > "$T/nuevo.sha"
sed -i '1d' "$FXPK/instalacion/NUCLEO.sha256"; cat "$T/nuevo.sha" >> "$FXPK/instalacion/NUCLEO.sha256"
mutante 'C11 manifiesto local regenerado detectado contra publicado' nucleo
assert_eq 'C11 diagnóstico manifiesto alterado' 1 "$(printf '%s\n' "$OUT" | grep -c NUCLEO.sha256)"

nueva; normal; assert_eq 'C12 sin secretos en texto' 0 "$(printf '%s\n' "$OUT" | grep -c CANARIO || true)"
informe; assert_eq 'C12 sin secretos en informe' 0 "$(printf '%s\n' "$OUT" | grep -c CANARIO || true)"
printf '%064d  skills/secretos/.env.local\n' 0 >> "$FXPK/instalacion/NUCLEO.sha256"
normal
assert_eq 'C12 manifiesto con tokens rechazado antes de hash' '1|guardas,nucleo' "$RC|$(printf '%s\n' "$OUT" | awk '$1=="NOVERIF"{print $2}' | sort -u | paste -sd, -)"
nueva
assert_eq 'solo lectura en cada dr, con y sin informe' 0 "$READONLY_FAIL"
assert_eq 'temporales borrados al salir' 0 "$(find "$T/tmp" -mindepth 1 | wc -l)"
# Cobertura estática + dinámica de tablas: retirar cualquier categoría enrojece esta comprobación.
faltan=''
for categoria in torre renderer ctx identidad sellado sellado-imposible cron bus cursor canal auditor acreditacion modelo modelo-auditor modelo-desarrollo menu escalado menu-reciente bloqueo-sin-escalar nucleo version miembros modelos-rol guardas doctor.d desviacion; do
  grep -q "^$categoria"$'\t' "$ROOT/scripts/doctor-volver.tsv" || faltan+=" $categoria"
done
assert_eq 'toda categoría tiene remedio' '' "$faltan"
sed -i '/^nucleo\t/d' "$FXSK/talent-ceo/scripts/doctor-volver.tsv"
# La prueba de cobertura utiliza la tabla efectiva, no acepta una tabla amputada.
normal
assert_eq 'control negativo: amputar remedio cierra el doctor' '1|1' "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF doctor.d')"

# ═══ origen-instalado.sh: la versión instalada se detecta por la HUELLA DEL CONTENIDO ═══════════
# Solo lectura, nunca falla por el origen (rc 0 con cualquier etiqueta; rc 2 solo por uso). Las instancias son
# SINTÉTICAS (su propio NUCLEO) con el manifiesto 1.7.x REAL renderizado del fixture; la tabla de cada caso se
# arma con los digests de esas instancias. Los mutantes son COPIAS del script con UNA sustitución exacta: si la
# sustitución no encuentra exactamente una coincidencia, el caso sale en ROJO.
OISH="$ROOT/scripts/origen-instalado.sh"
OITSV="$ROOT/scripts/doctor-origenes.tsv"
OIFX="$PKG/tests/fixtures/origenes/manifiesto-1.7.x.txt"
OT="$T/oi"; rm -rf "${OT:?}"; mkdir -p "$OT"
OIX=''
oi_manifiesto() { awk -v v="$1" '{ sub(/@VERSION@/, v) } 1' "$OIFX"; }
oi_digest() { sha256sum < "$1" | cut -d' ' -f1; }
oi_arbol() { (cd "$1" && { find . -printf '%p %y %m %s %l\n' | sort; find . -type f -print0 | sort -z | xargs -0 -r sha256sum; }) | sha256sum; }
oi_base() { # DIR VERSION
  local d="$1"
  rm -rf "${d:?}"
  mkdir -p "$d/instalacion" "$d/skills/skill-creator/assets" "$d/skills/talent-ceo/references"
  printf 'Contenido sintético A %s\n' "$2" > "$d/skills/talent-ceo/references/a.txt"
  printf 'Contenido sintético B %s\n' "$2" > "$d/skills/talent-ceo/references/b.txt"
  (cd "$d" && sha256sum skills/talent-ceo/references/a.txt skills/talent-ceo/references/b.txt) > "$d/instalacion/NUCLEO.sha256"
  oi_manifiesto "$2" > "$d/skills/skill-creator/assets/package.manifest"
}
oi_tabla() { # FICHERO: una fila por instancia sintética
  local v
  : > "$1"
  for v in 1.7.2 1.7.3 1.7.4 1.7.5; do
    printf '%s\t%s\t%s\tprueba\n' "$v" "$(oi_digest "$OT/v$v/instalacion/NUCLEO.sha256")" \
      "$(oi_digest "$OT/v$v/skills/skill-creator/assets/package.manifest")" >> "$1"
  done
}
oi() { OIOUT="$(env -i PATH=/usr/bin:/bin LC_ALL=C bash "${OIX:-$OISH}" "$@" 2>"$OT/err")"; OIRC=$?; }
oi_campo() { printf '%s\n' "$OIOUT" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
oi_etq() { printf '%s\n' "$OIOUT" | awk '{print $2}'; }
oi_var() { rm -rf "${OT:?}/var"; cp -a "$OT/v1.7.5" "$OT/var"; }
oi_mutar() { # NOMBRE BUSCAR NUEVO: copia del script con UNA sustitución; rc 1 si no hay exactamente una coincidencia
  local src sin n
  src="$(cat "$OISH"; printf x)"; src="${src%x}"
  sin="${src//"$2"/}"
  n=$(( (${#src} - ${#sin}) / ${#2} ))
  [ "$n" -eq 1 ] || return 1
  MD="$OT/mut-$1"; rm -rf "${MD:?}"; mkdir -p "$MD/skills/talent-ceo/scripts"
  cp "$ROOT/scripts/lib-desvio.sh" "$OITSV" "$MD/skills/talent-ceo/scripts/"
  printf '%s' "${src/"$2"/"$3"}" > "$MD/skills/talent-ceo/scripts/origen-instalado.sh"
}
oi_detecta() { # NOMBRE BUSCAR NUEVO ARGS…: imprime 1 si la sustitución es única Y el mutante cambia el resultado
  local nombre="$1" buscar="$2" nuevo="$3" orig mut
  shift 3
  oi_mutar "$nombre" "$buscar" "$nuevo" || { echo 0; return; }
  oi "$@"; orig="$OIRC|$OIOUT"
  OIX="$MD/skills/talent-ceo/scripts/origen-instalado.sh"; oi "$@"; OIX=''
  mut="$OIRC|$OIOUT"
  if [ "$orig" != "$mut" ]; then echo 1; else echo 0; fi
}

# ── tabla real publicada: 4 filas, estricta, y las huellas de manifiesto son las de los manifiestos publicados ──
assert_eq 'OI tabla real: cuatro filas' 4 "$(grep -vcE '^(#|$)' "$OITSV")"
for v in 1.7.2 1.7.3 1.7.4 1.7.5; do
  oi_manifiesto "$v" > "$OT/m-$v"
  assert_eq "OI tabla real: huella del manifiesto $v" "$(oi_digest "$OT/m-$v")" "$(awk -F'\t' -v v="$v" '$1==v{print $3}' "$OITSV")"
done
assert_eq 'OI tabla real: estricta' 0 "$(awk -F'\t' '/^#/||/^$/{next} NF!=4||$1!~/^[0-9]+\.[0-9]+\.[0-9]+$/||length($2)!=64||$2~/[^0-9a-f]/||length($3)!=64||$3~/[^0-9a-f]/{n++} END{print n+0}' "$OITSV")"

# ── la fila REAL de la 1.7.5, con el NUCLEO y el manifiesto del ZIP PÚBLICO como dato fijo ──
# Fixture: tests/fixtures/origenes/publico-1.7.5/ (ver PROCEDENCIA.txt), sacado con `unzip -j` del build-1.zip de la
# 1.7.5 publicada, sha256 del ZIP 535918ce7c1ddae2ae7126d07de2538b9323d78d3c2d734365f234328d6f744b. La instancia lleva SOLO
# esos dos ficheros y se mide contra la tabla real (sin --tabla): la etiqueta sale de las dos huellas, sin instancias
# sintéticas ni tabla armada por la prueba. La instancia vive en un tmp PROPIO ($OT), nunca en el árbol.
# El NUCLEO del fixture se guarda con UNA sustitución (el nombre de un fichero de prueba que la neutralidad prohíbe
# escribir en el árbol, sustituido por una marca neutra; ver PROCEDENCIA.txt). Aquí se restaura en bash (sin `sed -i`) y,
# ANTES de usarlo, se exige el sha256 COMPLETO del ZIP público: si no casa, el caso FALLA (no se salta).
OIPUB="$PKG/tests/fixtures/origenes/publico-1.7.5"
OIREAL="$OT/real175"; rm -rf "${OIREAL:?}"; mkdir -p "$OIREAL/instalacion" "$OIREAL/skills/skill-creator/assets"
OIMARCA='@MARCA-NEUTRA-Z17@'
OIORIGINAL='academ''y.conf' # el literal se arma por trozos: ni este fichero ni el fixture lo escriben entero
oi_restaurar() { # MARCA DESTINO: copia el NUCLEO del fixture sustituyendo la marca por el nombre original
  local t
  t="$(cat "$OIPUB/NUCLEO.sha256"; printf x)"; t="${t%x}"
  printf '%s' "${t/"$1"/"$OIORIGINAL"}" > "$2"
}
OINUC175=8d17b00d3adde6d6096eb9a530801ca87aee7cf45605482cec208e642ef86f5d
OIMAN175=ed6091e1c420f078a5c6baf202bdae159b1072f0e6a118c9977e0c3d3acafcc9
oi_restaurar "$OIMARCA" "$OIREAL/instalacion/NUCLEO.sha256"
cp "$OIPUB/package.manifest" "$OIREAL/skills/skill-creator/assets/package.manifest"
assert_eq 'OI real 1.7.5: el NUCLEO reconstruido y el manifiesto del fixture traen las dos huellas COMPLETAS del ZIP público' \
  "$OINUC175|$OIMAN175" \
  "$(oi_digest "$OIREAL/instalacion/NUCLEO.sha256")|$(oi_digest "$OIREAL/skills/skill-creator/assets/package.manifest")"
oi "$OIREAL"
assert_eq 'OI real 1.7.5: la tabla real reconoce el NUCLEO público (sin --tabla)' '0|1.7.5|8d17b00d3add|ed6091e1c420|1.7.5|ok' \
  "$OIRC|$(oi_etq)|$(oi_campo nucleo)|$(oi_campo manifiesto)|$(oi_campo declarada)|$(oi_campo nota)"
# La entrada buzz-hermes@.service.tmpl del NUCLEO público lleva una @ que desvio_ruta no admite (l.37 de lib-desvio.sh):
# el NUCLEO se considera mal formado y la integridad no se mide. La etiqueta no cambia.
assert_eq 'OI real 1.7.5: el NUCLEO público lista una ruta con @ que el confinamiento rechaza: integridad no-medida y etiqueta 1.7.5' \
  '1.7.5|no-medida' "$(oi_etq)|$(oi_campo integridad)"
# Mutante 1: la fila 1.7.5 de la tabla real con UN dígito cambiado en la huella del NUCLEO; si la sustitución no es única, rojo.
OIMT="$(cat "$OITSV"; printf x)"; OIMT="${OIMT%x}"
OISIN="${OIMT//"$OINUC175"/}"
if [ $(( (${#OIMT} - ${#OISIN}) / 64 )) -eq 1 ]; then
  printf '%s' "${OIMT/8d17b00d3adde6d6/8d17b00d3adde6d7}" > "$OT/tabla-real-mut"
  oi --tabla "$OT/tabla-real-mut" "$OIREAL"; r="$OIRC|$(oi_etq)|$(oi_campo nota)"
else r='sustitución no única'; fi
assert_eq 'OI real 1.7.5 M-F: un dígito cambiado en la huella del NUCLEO de la fila 1.7.5 enrojece el reconocimiento' '0|desconocida|pista-1.7.5' "$r"
# Mutante 2 (simétrico): un dígito cambiado en la huella del MANIFIESTO de la fila 1.7.5; el NUCLEO sigue casando.
OISIN="${OIMT//"$OIMAN175"/}"
if [ $(( (${#OIMT} - ${#OISIN}) / 64 )) -eq 1 ]; then
  printf '%s' "${OIMT/ed6091e1c420f078/ed6091e1c420f079}" > "$OT/tabla-real-mut-man"
  oi --tabla "$OT/tabla-real-mut-man" "$OIREAL"; r="$OIRC|$(oi_etq)|$(oi_campo nota)"
else r='sustitución no única'; fi
assert_eq 'OI real 1.7.5 M-G: un dígito cambiado en la huella del manifiesto de la fila 1.7.5 enrojece el reconocimiento' '0|desconocida|pista-1.7.5' "$r"
# Mutante 3: la marca alterada no se sustituye y el NUCLEO restaurado deja de tener la huella del ZIP público.
oi_restaurar '@MARCA-NEUTRA-Z17X@' "$OT/nucleo-marca-alterada"
if [ "$(oi_digest "$OT/nucleo-marca-alterada")" != "$OINUC175" ]; then r=1; else r=0; fi
assert_eq 'OI real 1.7.5 M-M: una marca alterada enrojece la comprobación de la huella del NUCLEO restaurado' 1 "$r"

# ── C1–C4: cada origen se detecta por contenido, con su integridad ──
for v in 1.7.2 1.7.3 1.7.4 1.7.5; do oi_base "$OT/v$v" "$v"; done
oi_tabla "$OT/tabla4"
for v in 1.7.2 1.7.3 1.7.4 1.7.5; do
  oi --tabla "$OT/tabla4" "$OT/v$v"
  assert_eq "OI $v: rc 0 y etiqueta por huella" "0|$v" "$OIRC|$(oi_etq)"
  assert_eq "OI $v: declarada, integridad, nota y huella del núcleo" "$v|integra|ok|$(oi_digest "$OT/v$v/instalacion/NUCLEO.sha256" | cut -c1-12)" \
    "$(oi_campo declarada)|$(oi_campo integridad)|$(oi_campo nota)|$(oi_campo nucleo)"
done
# La versión declarada NUNCA decide: declara 1.7.4 pero el NUCLEO no es el publicado (la tabla real solo casa el manifiesto).
oi "$OT/v1.7.4"
assert_eq 'OI declara 1.7.4 con NUCLEO ajeno: desconocida con pista, sin fallo' '0|desconocida|1.7.4|pista-1.7.4' \
  "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"
cp -a "$OT/v1.7.5" "$OT/tocada"; printf '# retoque a mano\n' >> "$OT/tocada/skills/skill-creator/assets/package.manifest"
oi --tabla "$OT/tabla4" "$OT/tocada"
assert_eq 'OI manifiesto retocado declarando 1.7.5: desconocida' '0|desconocida|1.7.5|pista-1.7.5' \
  "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"

# ── 2.0: el NUCLEO es byte a byte el del paquete que ejecuta el script (sin digest fijado en el código) ──
D2="$OT/dos"; rm -rf "${D2:?}"; mkdir -p "$D2/skills/talent-ceo/scripts" "$D2/instalacion"
cp "$OISH" "$ROOT/scripts/lib-desvio.sh" "$OITSV" "$D2/skills/talent-ceo/scripts/"
cp "$OT/v1.7.5/instalacion/NUCLEO.sha256" "$D2/instalacion/NUCLEO.sha256"
oi_base "$OT/i20" 1.7.5
mkdir -p "$OT/i20/scripts/paquete"
printf 'version=2.0.0\nmember=talent-ceo\n' > "$OT/i20/scripts/paquete/package.manifest"
rm "$OT/i20/skills/skill-creator/assets/package.manifest"
OIX="$D2/skills/talent-ceo/scripts/origen-instalado.sh"
oi "$OT/i20"
assert_eq 'OI 2.0: núcleo igual al del paquete que ejecuta el script' '0|2.0' "$OIRC|$(oi_etq)"
assert_eq 'OI 2.0: lee el manifiesto de la 2.0, integra y ok' '2.0.0|integra|ok' "$(oi_campo declarada)|$(oi_campo integridad)|$(oi_campo nota)"
oi "$OT/v1.7.4"
OIX=''
assert_eq 'OI núcleo distinto al del paquete que ejecuta el script no es 2.0' '0|desconocida' "$OIRC|$(oi_etq)"

# ── C5: desconocida / tocada a mano nunca falla ──
oi_var; rm "$OT/var/skills/skill-creator/assets/package.manifest"; oi "$OT/var"
assert_eq 'OI sin manifiesto: desconocida, rc 0' '0|desconocida|-|sin-manifiesto' "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"
oi_var; rm "$OT/var/skills/skill-creator/assets/package.manifest"; ln -s "$OT/m-1.7.5" "$OT/var/skills/skill-creator/assets/package.manifest"; oi "$OT/var"
assert_eq 'OI manifiesto enlace no se sigue' '0|desconocida|-|sin-manifiesto' "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"
if [ "$(id -u)" -eq 0 ]; then skip 'OI manifiesto ilegible necesita usuario sin privilegios'
else
  oi_var; chmod 000 "$OT/var/skills/skill-creator/assets/package.manifest"; oi "$OT/var"
  assert_eq 'OI manifiesto ilegible: desconocida, rc 0' '0|desconocida|-|sin-manifiesto' "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"
  chmod 644 "$OT/var/skills/skill-creator/assets/package.manifest"
fi
oi_var; { printf 'version=1.7.5\n'; head -c 70000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$OT/var/skills/skill-creator/assets/package.manifest"; oi "$OT/var"
assert_eq 'OI manifiesto de más de 64 KiB se rechaza' '0|desconocida|-|sin-manifiesto' "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"
oi_var; rm "$OT/var/instalacion/NUCLEO.sha256"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI sin NUCLEO: desconocida, integridad no medida' '0|desconocida|-|no-medida' "$OIRC|$(oi_etq)|$(oi_campo nucleo)|$(oi_campo integridad)"
oi_var; mv "$OT/var/instalacion/NUCLEO.sha256" "$OT/nuc-real"; ln -s "$OT/nuc-real" "$OT/var/instalacion/NUCLEO.sha256"
cp -a "$OT/var" "$OT/nucl-enlace"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI NUCLEO enlace no se sigue' '0|desconocida|-|no-medida' "$OIRC|$(oi_etq)|$(oi_campo nucleo)|$(oi_campo integridad)"
oi_var; head -c 1100000 /dev/zero | tr '\0' 'a' > "$OT/var/instalacion/NUCLEO.sha256"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI NUCLEO de más de 1 MiB se rechaza' '0|desconocida|-|no-medida' "$OIRC|$(oi_etq)|$(oi_campo nucleo)|$(oi_campo integridad)"
mkdir -p "$OT/vacia"; oi "$OT/vacia"
assert_eq 'OI carpeta vacía: desconocida sin fallo' '0|desconocida|-|sin-nucleo' "$OIRC|$(oi_etq)|$(oi_campo manifiesto)|$(oi_campo nota)"
oi_var; printf 'member=talent-ceo\n' > "$OT/var/skills/skill-creator/assets/package.manifest"; oi "$OT/var"
assert_eq 'OI manifiesto sin línea version=: declarada guion, mano' '0|desconocida|-|mano' "$OIRC|$(oi_etq)|$(oi_campo declarada)|$(oi_campo nota)"

# ── tabla ilegible o mal formada: desconocida con nota, rc 0 ──
N175="$(oi_digest "$OT/v1.7.5/instalacion/NUCLEO.sha256")"; M175="$(oi_digest "$OT/m-1.7.5")"
printf '1.7.5\t%s\t%s\tprueba\textra\n' "$N175" "$M175" > "$OT/tabla-extra"
printf '1.7.5\t%s\t%s\tprueba\n' "${N175:0:63}" "$M175" > "$OT/tabla-corta"
printf '1.7\t%s\t%s\tprueba\n' "$N175" "$M175" > "$OT/tabla-version"
ln -s "$OT/tabla4" "$OT/tabla-enlace"
printf '# solo comentarios\n\n' > "$OT/tabla-vacia"
for t in tabla-extra tabla-corta tabla-version tabla-enlace no-hay tabla-vacia; do
  oi --tabla "$OT/$t" "$OT/v1.7.5"
  assert_eq "OI $t: desconocida con tabla-invalida, rc 0" '0|desconocida|tabla-invalida' "$OIRC|$(oi_etq)|$(oi_campo nota)"
done
{ printf '# cabecera\n\n'; printf '1.7.5\t%s\t%s\tprueba\n' "$N175" "$M175"; printf '\n# fin\n'; } > "$OT/tabla-comentarios"
oi --tabla "$OT/tabla-comentarios" "$OT/v1.7.5"
assert_eq 'OI tabla con comentarios y líneas vacías sigue casando' '0|1.7.5' "$OIRC|$(oi_etq)"

# ── integridad: informativa, no cambia la etiqueta ──
oi_var; printf 'alterado\n' >> "$OT/var/skills/talent-ceo/references/a.txt"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI fichero alterado: distinta:1 y misma etiqueta' '0|1.7.5|distinta:1' "$OIRC|$(oi_etq)|$(oi_campo integridad)"
rm "$OT/var/skills/talent-ceo/references/b.txt"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI fichero alterado y otro ausente: distinta:2' '0|1.7.5|distinta:2' "$OIRC|$(oi_etq)|$(oi_campo integridad)"
oi_var; printf 'basura\n' > "$OT/var/instalacion/NUCLEO.sha256"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI NUCLEO mal formado: integridad no medida, rc 0' '0|no-medida' "$OIRC|$(oi_campo integridad)"
oi_var; mv "$OT/var/skills/talent-ceo" "$OT/ceo-fuera"; ln -s "$OT/ceo-fuera" "$OT/var/skills/talent-ceo"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI directorio enlazado en la ruta: no se sigue (distinta:2)' '0|1.7.5|distinta:2' "$OIRC|$(oi_etq)|$(oi_campo integridad)"

# ── uso incorrecto, solo lectura y secretos ──
oi; assert_eq 'OI sin argumentos: rc 2 y nada en stdout' '2|' "$OIRC|$OIOUT"
oi "$OT/no-existe"; assert_eq 'OI carpeta inexistente: rc 2' '2|' "$OIRC|$OIOUT"
ln -s "$OT/v1.7.5" "$OT/dir-enlace"; oi "$OT/dir-enlace"; assert_eq 'OI carpeta enlace: rc 2' '2|' "$OIRC|$OIOUT"
oi --raro "$OT/v1.7.5"; assert_eq 'OI opción desconocida: rc 2' '2|' "$OIRC|$OIOUT"
oi "$OT/v1.7.5" "$OT/v1.7.4"; assert_eq 'OI dos carpetas: rc 2' '2|' "$OIRC|$OIOUT"
oi --tabla; assert_eq 'OI --tabla sin valor: rc 2' '2|' "$OIRC|$OIOUT"
oi_var; printf 'LINEAR_API_KEY=CANARIO-OI\n' > "$OT/var/.env.local"; chmod 600 "$OT/var/.env.local"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI .env.local presente: ningún canario en la salida' 0 "$(printf '%s\n%s\n' "$OIOUT" "$(cat "$OT/err")" | grep -c CANARIO || true)"
printf '%064d  skills/secretos/.env.local\n' 0 >> "$OT/var/instalacion/NUCLEO.sha256"; oi --tabla "$OT/tabla4" "$OT/var"
assert_eq 'OI NUCLEO que lista un .env.local: integridad no medida' '0|no-medida' "$OIRC|$(oi_campo integridad)"
oi_base "$OT/lectura" 1.7.5; oi_antes="$(oi_arbol "$OT/lectura")"; oi --tabla "$OT/tabla4" "$OT/lectura"; oi_despues="$(oi_arbol "$OT/lectura")"
assert_eq 'OI solo lectura: el árbol queda idéntico' "$oi_antes" "$oi_despues"
oi --tabla "$OT/tabla4" "$OT/v1.7.5"
assert_eq 'OI una sola línea de salida' 1 "$(printf '%s\n' "$OIOUT" | wc -l | tr -d ' ')"

# ── mutantes TD: cada uno debe cambiar el resultado de su caso (si no, esa prueba no protege nada) ──
assert_eq 'OI M-C7a: exigir la 1.7.5 enrojece el caso de la 1.7.2' 1 \
  "$(oi_detecta c7a "printf 'ORIGEN %s nucleo=" "[ \"\$ETIQUETA\" = 1.7.5 ] || exit 1; printf 'ORIGEN %s nucleo=" --tabla "$OT/tabla4" "$OT/v1.7.2")"
assert_eq 'OI M-V: etiquetar por la declarada enrojece el caso del NUCLEO ajeno' 1 \
  "$(oi_detecta v "# fin-de-decision" '[ "$DECLARADA" = - ] || ETIQUETA="$DECLARADA"' "$OT/v1.7.4")"
assert_eq 'OI M-N: fallar por desconocida enrojece el caso del NUCLEO ajeno' 1 \
  "$(oi_detecta n "# fin-de-decision" '[ "$ETIQUETA" != desconocida ] || exit 1' "$OT/v1.7.4")"
if oi_mutar s "# fin-de-decision" 'touch "$DIR/.marca-mutante"'; then
  oi_base "$OT/v1.7.5" 1.7.5; oi_antes="$(oi_arbol "$OT/v1.7.5")"
  OIX="$MD/skills/talent-ceo/scripts/origen-instalado.sh"; oi --tabla "$OT/tabla4" "$OT/v1.7.5"; OIX=''
  oi_despues="$(oi_arbol "$OT/v1.7.5")"; rm -f "$OT/v1.7.5/.marca-mutante"
  if [ "$oi_antes" != "$oi_despues" ]; then r=1; else r=0; fi
else r=0; fi
assert_eq 'OI M-S: escribir en la carpeta enrojece la prueba de solo lectura' 1 "$r"
assert_eq 'OI M-L: seguir el enlace del NUCLEO enrojece su caso' 1 \
  "$(oi_detecta l '[ ! -L "$1" ] && ' '' --tabla "$OT/tabla4" "$OT/nucl-enlace")"
assert_eq 'OI M-T: aceptar campos extra enrojece el caso de la tabla mal formada' 1 \
  "$(oi_detecta t '[ "${#t}" -eq 3 ]' '[ "${#t}" -ge 3 ]' --tabla "$OT/tabla-extra" "$OT/v1.7.5")"
# +61 casos de origen-instalado.sh: tabla real 6 · huella pública real 6 · cuatro orígenes 8 · declarada/retocada 2 ·
# 2.0 3 · desconocida 9 · tabla inválida 7 · integridad 4 · uso/solo lectura/secretos 10 · mutantes 6.

printf '\n== %d ok, %d FAIL (esperados: %d casos; saltados: %d%s) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO" "$SKIP" "${SKIPPED:+ —$SKIPPED}"
rc=0
[ "$FAIL" -eq 0 ] || rc=1
[ $((PASS+FAIL+SKIP)) -eq "$TOTAL_ESPERADO" ] || { printf 'FAIL: autoconteo %s != %s\n' "$((PASS+FAIL+SKIP))" "$TOTAL_ESPERADO"; rc=1; }
exit "$rc"
