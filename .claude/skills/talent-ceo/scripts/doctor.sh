#!/usr/bin/env bash
# doctor.sh — Doctor de instancia: contrasta lo DECLARADO en el perfil con lo que CORRE (talent-ceo, ref 07).
#
# Un perfil válido (`lib-perfil.sh --check`) solo acredita ESTRUCTURA. Este script acredita que cada
# fila declarada existe de verdad en el runtime: torres, estaciones, canales, crons, bus, cursores.
# Es de SOLO LECTURA (consulta tmux, crontab, incus, ps y stat; jamás repara ni reanima un actor).
# Repo-agnóstico, token-only, sin MCP. Patrón: `talent-sentry-guard/scripts/sentry_doctor.sh`.
#
# Uso:
#   doctor.sh            # evalúa TODO; no hay opción que apague una comprobación
#   doctor.sh --informe  # tabla Markdown exportable; mismo recorrido y rc
#   doctor.sh --help
#
# Salida: una línea por comprobación:  OK|FALLA|NOVERIF|AVISO <categoría> <id>: detalle
#         y al final  `RESUMEN ok=N falla=N noverif=N`  y  `PUERTA ABIERTA|CERRADA`.
#         AVISO es solo informativo: no entra en RESUMEN ni cierra la puerta (en --informe va aparte, «info»).
#
# Modo escritor aparte (cron diario del usuario CEO):  doctor.sh --seguridad
#   Hace la búsqueda CARA de LiteLLM (hogares y canales, profundidad 6/7, 600 s por sujeto) y deja su resultado SELLADO
#   en el bus. El doctor normal NO la repite: lee ese último resultado (FALLA si es rojo, si tiene NOVERIF o si tiene más
#   de 26 h; NOVERIF si no existe o su sello no cuadra). Es el único modo que escribe, y solo su resultado.
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0  todo OK · puerta ABIERTA
#   1  algún FALLA o NOVERIF · puerta CERRADA (un NOVERIF cuenta como fallo: «no he podido
#      comprobarlo» NO es «está bien»)
#   2  NO PUEDE EVALUAR (no se emite ninguna línea de comprobación): sin `tmux` o sin `crontab`,
#      perfil ausente/ilegible/inválido, ninguna máquina `acceso=local`, sin ruta del bus
#      (ni TA_BUS ni fila `bus` con path=), TA_ESCALADO_MIN no numérico, o perfil sin nada que
#      comprobar (un doctor que no comprueba nada NO da verde).
#
# ── ALCANCE: SOLO LA MÁQUINA Y EL USUARIO LOCALES ──────────────────────────────────────────────
# Las filas de OTRA máquina no se verifican desde aquí: salen `NOVERIF` (cuenta como fallo). Las de
# otro USUARIO de esta máquina (el perfil declara `usuario=` por rol, y tmux es por usuario) se
# consultan con `sudo -n -u <usuario> …` SOLO si eso está permitido sin contraseña; si sudo lo
# rechaza, `NOVERIF`. Nunca verde sin comprobar.
#
# Entorno (todo opcional): TA_PERFIL / SECRET_DIR (perfil, como el resto del skill) · TA_BUS ·
# TA_BUS_CURSOR_DIR · XDG_RUNTIME_DIR · TA_ESCALADO_MIN (minutos, defecto 15) · TA_SEG_RAIZ (SOLO pruebas:
# prefijo de /usr, /etc y /tmp para las sondas de seguridad; en producción vacío).
# Las sondas de seguridad (Node, LiteLLM, sesiones zombi) se evalúan si el manifiesto de la instancia declara
# `talent-channels` (una fábrica real siempre lo declara); si falta, el doctor lo AVISA en cada corrida.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"
# shellcheck source=/dev/null
. "$HERE/lib-bus.sh"
# shellcheck source=/dev/null
. "$SKILLS/talent-channel-operation/scripts/lib.sh"

INFORME=0; SEGURIDAD=0
case "${1-}" in
  --help) sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
  --informe) INFORME=1 ;;
  --seguridad) SEGURIDAD=1 ;;
  '') : ;;
  *) echo "doctor: argumento desconocido: $1 (uso: doctor.sh [--help])" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'doctor: demasiados argumentos' >&2; exit 2; }

die2() { printf 'doctor: PRECOND: %s\n' "$*" >&2; exit 2; }

# shellcheck source=/dev/null
. "$HERE/lib-desvio.sh"
# shellcheck source=/dev/null
. "$HERE/lib-seguridad.sh"
# shellcheck disable=SC2034 # Arrays compartidos con lib-desvio.sh.
declare -A D_GRAVEDAD=() D_VOLVER=() D_SHA=() D_GUARDAS=()
# shellcheck disable=SC2034
declare -a D_FILAS=() D_MEMBERS=() D_OVERLAY=() D_PREFIX=()
REMEDIOS_OK=1
desvio_remedios "$HERE/doctor-volver.tsv" || REMEDIOS_OK=0

# ── UN CAMPO DEL PERFIL (o del runtime) NO PUEDE MANDAR SOBRE EL TERMINAL ───────────────────────
# Misma neutralización que `perfil-render.sh`: el perfil valida ESTRUCTURA, no que sus campos sean
# inertes, y estas líneas se pintan en la terminal de quien las lee. Se quita el CONTROL (C0, DEL y
# los C1, incluido el CSI de 8 bits); lo demás se pinta tal cual. Se acota el largo: un detalle de
# diagnóstico no necesita volcar un pane.
inerte() {
  local v="${1-}" c1=0
  # Camino rápido: solo ASCII imprimible (bajo LC_ALL=C, [:print:] = 0x20..0x7E) no lleva control alguno.
  case "$v" in
    *[![:print:]]*) : ;;
    *) printf '%s' "${v:0:200}"; return 0 ;;
  esac
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || c1=1
  else
    c1=1
  fi
  if [ "$c1" -eq 1 ]; then
    v="$(printf '%s' "$v" | sed -e 's/\x9b/\x1b[/g; s/\x9d/\x1b]/g; s/\x90/\x1bP/g; s/\x98/\x1bX/g; s/\x9e/\x1b^/g; s/\x9f/\x1b_/g; s/\x9c/\x1b\\/g' -e 's/[\x80-\x9f]//g')"
  fi
  if command -v iconv >/dev/null 2>&1; then v="$(printf '%s' "$v" | iconv -c -f UTF-8 -t UTF-8)"; fi
  printf '%s' "$v" | sed 's/\xc2[\x80-\x9f]//g' | tr -d '[:cntrl:]' | cut -c1-200
}

N_OK=0; N_FALLA=0; N_NOVERIF=0; N_AVISO=0; D_AVISOS=()
emit() { # estado categoría id detalle
  if [ -z "${D_VOLVER[$2]+x}" ] && [ "$2" != doctor.d ]; then
    set -- NOVERIF doctor.d remedios "categoría $2 sin remedio declarado"
  fi
  if [ "$INFORME" -eq 0 ]; then
    printf '%s %s %s: %s\n' "$1" "$(inerte "$2")" "$(inerte "$3")" "$(inerte "$4")"
  elif [ "$1" = AVISO ]; then
    # Informativo: gravedad literal «info» (la tabla solo admite alta|media|baja) y fuera de las desviaciones.
    D_AVISOS+=("| $(desvio_md "$1 $2 $3: $4") | info | $(desvio_md "${D_VOLVER[$2]:-Restaurar la tabla de remedios del doctor.}") |")
  elif [ "$1" != OK ]; then
    D_FILAS+=("| $(desvio_md "$1 $2 $3: $4") | ${D_GRAVEDAD[$2]:-alta} | $(desvio_md "${D_VOLVER[$2]:-Restaurar la tabla de remedios del doctor.}") |")
  fi
  # AVISO tiene rama propia: ni cuenta como NOVERIF ni cierra la puerta, y RESUMEN no cambia de formato.
  case "$1" in OK) N_OK=$((N_OK + 1)) ;; FALLA) N_FALLA=$((N_FALLA + 1)) ;; AVISO) N_AVISO=$((N_AVISO + 1)) ;; *) N_NOVERIF=$((N_NOVERIF + 1)) ;; esac
}
ok()   { emit OK "$@"; }
falla() { emit FALLA "$@"; }
noverif() { emit NOVERIF "$@"; }
# shellcheck disable=SC2329 # la invoca lib-seguridad.sh
aviso() { emit AVISO "$@"; }

# ── Precondiciones: sin ellas NO se evalúa nada (rc 2) ─────────────────────────────────────────
command -v tmux >/dev/null 2>&1 || die2 "no hay \`tmux\` en el PATH; no se puede contrastar ninguna sesión"
command -v crontab >/dev/null 2>&1 || die2 "no hay \`crontab\` en el PATH; no se puede contrastar ninguna tabla"
ESC_MIN="${TA_ESCALADO_MIN:-15}"
case "$ESC_MIN" in ''|*[!0-9]*) die2 "TA_ESCALADO_MIN no es un entero de minutos: $ESC_MIN" ;; esac
[ "${#ESC_MIN}" -le 6 ] && [ "$ESC_MIN" -ge 1 ] || die2 "TA_ESCALADO_MIN fuera de rango (1..999999): $ESC_MIN"

PERFIL="$(perfil_path 2>/dev/null)" || die2 "sin perfil de instancia legible (o ambiguo); un doctor sin perfil no evalúa nada"
perfil_validate "$PERFIL" >/dev/null 2>&1 || die2 "el perfil no es válido (lib-perfil.sh --check $PERFIL); no se evalúa sobre un perfil roto"
# Todo lo que se invoque debajo (tablas-cron.sh) debe leer EL MISMO perfil que se acaba de validar.
export TA_PERFIL="$PERFIL"

# `sellar` identifica la máquina local por `acceso=local`; aquí igual: sin ella no se sabe qué es «local».
LOCAL_ID=''
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  perfil_campos "$_f"
  if [ "$(perfil_attr "${PERFIL_CAMPOS[5]-}" acceso || true)" = local ]; then LOCAL_ID="${PERFIL_CAMPOS[1]-}"; break; fi
done <<< "$(perfil_rows maquina 2>/dev/null || true)"
[ -n "$LOCAL_ID" ] || die2 "ninguna fila 'maquina' declara acceso=local; no se sabe qué máquina es ésta"

BUS_ROW="$(perfil_row1 bus 2>/dev/null || true)"
BUS_PERFIL=''; BUS_LECTORES=''
if [ -n "$BUS_ROW" ]; then
  perfil_campos "$BUS_ROW"
  BUS_PERFIL="$(perfil_attr "${PERFIL_CAMPOS[5]-}" path || true)"
  BUS_LECTORES="$(perfil_attr "${PERFIL_CAMPOS[5]-}" lectores || true)"
fi
BUS="${TA_BUS:-$BUS_PERFIL}"
[ -n "$BUS" ] || die2 "sin ruta del bus: ni TA_BUS ni una fila 'bus' con path=; no se puede evaluar el bus"

YO="$(id -un 2>/dev/null || true)"
D_TMP="$(mktemp -d 2>/dev/null)" || die2 "no se pudo crear un temporal para capturar stderr de sudo"
ERRF="$D_TMP/stderr"
trap 'rm -rf -- "$D_TMP"' EXIT
NOW="$(date -u +%s 2>/dev/null)"
case "$NOW" in ''|*[!0-9]*) die2 "no se pudo medir la hora; la antigüedad de un sello no se extrapola" ;; esac

# ── como <usuario> <cmd…> → COMO_OUT · COMO_RC · COMO_SUDO (1 = sudo rechazó, no el comando) ────
# El usuario del propio proceso (o vacío) ejecuta directo. Otro usuario: `sudo -n` (jamás pide
# contraseña). Si falla y stderr empieza por «sudo:» el fallo es de PERMISO, no del comando: la
# comprobación pasa a NOVERIF en vez de leerse como «la sesión no existe».
# COMO_TIMEOUT (s) y COMO_NICE (cualquier valor), vacíos por defecto: `timeout` y `nice -n 19` envuelven la orden ENTERA,
# sudo incluido, así que no entran en la firma del sudoers. COMO_ERR = primera línea del stderr de la orden.
COMO_OUT=''; COMO_RC=0; COMO_SUDO=0; COMO_TIMEOUT=''; COMO_NICE=''; COMO_ERR=''
como() {
  local u="$1"; shift
  local -a pre=()
  COMO_SUDO=0; COMO_OUT=''; COMO_RC=0; COMO_ERR=''
  [ -z "$COMO_TIMEOUT" ] || pre=(timeout "$COMO_TIMEOUT")
  [ -z "$COMO_NICE" ] || pre=(nice -n 19 "${pre[@]}")
  if [ -z "$u" ] || [ "$u" = "$YO" ]; then
    COMO_OUT="$("${pre[@]}" "$@" 2>"$ERRF")"; COMO_RC=$?; COMO_ERR="$(head -n1 "$ERRF" 2>/dev/null)"; return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then COMO_SUDO=1; COMO_RC=127; return 0; fi
  COMO_OUT="$("${pre[@]}" sudo -n -H -u "$u" -- "$@" 2>"$ERRF")"; COMO_RC=$?
  COMO_ERR="$(head -n1 "$ERRF" 2>/dev/null)"
  if [ "$COMO_RC" -ne 0 ] && printf '%s\n' "$COMO_ERR" | grep -q '^sudo:'; then COMO_SUDO=1; fi
  return 0
}
# Un `usuario=` que NO existe en esta máquina es un fallo firme (su sesión no puede existir), no un
# «no puedo comprobarlo»: se distingue ANTES de sudo, cuyo rechazo es de permiso y da NOVERIF.
usuario_ausente() { # usuario → rc 0 si es otro usuario y el SO no lo conoce
  [ -n "${1-}" ] && [ "$1" != "$YO" ] && ! id -u "$1" >/dev/null 2>&1
}
usuario_ok() { printf '%s' "${1-}" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }
nombre_ok()  { printf '%s' "${1-}" | grep -Eq '^[A-Za-z0-9_.-]{1,64}$'; }

# Descendientes de los PIDs raíz (incluidos ellos) a partir de `ps -e -o pid=,ppid=,comm=` en
# stdin: imprime el `comm` (ejecutable, NO la línea de comandos) de cada uno. Por ejecutable, jamás
# un patrón sobre la LÍNEA DE COMANDOS casa a quien MENCIONA «claude», no a quien lo ES.
descendientes_comm() { # $1 = PIDs raíz (separados por espacio/línea)
  TA_ROOTS="$1" awk '
    BEGIN { n = split(ENVIRON["TA_ROOTS"], r, /[ \n]+/); for (i = 1; i <= n; i++) if (r[i] != "") raiz[r[i]] = 1 }
    {
      pid = $1; par[pid] = $2; c = ""
      for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i
      com[pid] = c
    }
    END {
      for (p in com) {
        q = p; d = 0
        while (q != "" && d < 64) { if (q in raiz) { print com[p]; break }; q = par[q]; d++ }
      }
    }'
}

# ¿Cuál fue el ÚLTIMO sello de <rol> en el bus? → US_TS (epoch) · US_MARK · rc 1 si nunca selló.
ultimo_sello() { # rol
  local linea ts canon cab_re
  linea="$(TA_ROL_Q="$1" awk '
    {
      if (match($0, /^[^ ]+ \[rol: [A-Za-z0-9_-]+\] \[marcador: [^][]+\]($| )/)) {
        cab = substr($0, RSTART, RLENGTH)
        sub(/ $/, "", cab)
        ts = cab; sub(/ .*$/, "", ts)
        rol = substr(cab, index(cab, "[rol: ") + 6); sub(/\].*$/, "", rol)
        mk = substr(cab, index(cab, "[marcador: ") + 11); sub(/\]$/, "", mk)
        # Los SEG-* los firma el cron de `doctor.sh --seguridad` con el rol del CEO: son sellos de la medición, no de la
        # sesión del CEO (no escalan, no acreditan ni refrescan el menú). Solo seg_sello_hora (lib-seguridad.sh) los lee.
        if (rol == ENVIRON["TA_ROL_Q"] && mk !~ /^SEG-/) { u = ts "\t" mk }
      }
    }
    END { if (u != "") print u }' "$BUS" 2>/dev/null)"
  [ -n "$linea" ] || return 1
  ts="${linea%%$'\t'*}"; US_MARK="${linea#*$'\t'}"
  cab_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [[ $ts =~ $cab_re ]] || return 1
  canon="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 1
  [ "$canon" = "$ts" ] || return 1
  US_TS="$(date -u -d "$ts" +%s 2>/dev/null)" || return 1
  case "$US_TS" in ''|*[!0-9]*) return 1 ;; esac
  [ "$US_TS" -le "$NOW" ] || return 1
  return 0
}

escalado_reciente() {
  local ts epoch canon
  while IFS= read -r ts; do
    [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || continue
    canon="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || continue
    [ "$canon" = "$ts" ] || continue
    epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || continue
    [ "$epoch" -le "$NOW" ] && [ $((NOW-epoch)) -le $((ESC_MIN*60)) ] && return 0
  done < <(TA_R="$1" awk '{
    if(index($0," [rol: " ENVIRON["TA_R"] "] [marcador: ESCALA-" ENVIRON["TA_R"] "-")==length($1)+1) print $1
  }' "$BUS")
  return 1
}

# ═══ 1 · Identidad y credenciales (C8): nunca se imprimen valores ni se lee `.env.local` ═══════════
# Asignaciones literales de agents.conf y manifiesto, sin eval/source ni expansión.
# Una instrucción o clave duplicada invalida el fichero completo.
leer_conf() { # ruta nombre de array asociativo [agents]
  local f="$1" tipo="${3-}" line k v seen=':'
  local -n dest="$2"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    # Solo agents.conf admite export seguido de UN espacio; el resto no se recorta.
    if [ "$tipo" = agents ]; then line="${line#export }"; fi
    if [ "$tipo" = agents ]; then
      [[ $line =~ ^[A-Z][A-Z0-9_]*= ]] || return 1
    else
      # Gramática de CLAVE de validate-manifest.sh; los gates conservan su sufijo minúsculo.
      [[ $line =~ ^[A-Za-z][A-Za-z0-9_]*= ]] || return 1
    fi
    k="${line%%=*}"; v="${line#*=}"
    case "$seen" in *":$k:"*) return 1 ;; esac; seen="$seen$k:"
    case "$v" in *'$'*|*'`'*|*"\\"*|*[[:cntrl:]]*) return 1 ;; esac
    # Una sola pareja envolvente; ningún fragmento adicional ni comilla interior.
    case "$v" in
      \"*\") v="${v:1:${#v}-2}"; case "$v" in *\"*) return 1 ;; esac ;;
      \'*\') v="${v:1:${#v}-2}"; case "$v" in *\'*) return 1 ;; esac ;;
      *) case "$v" in '~'*|*':~'*|*[[:space:]]*|*\"*|*\'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'('*|*')'*) return 1 ;; esac ;;
    esac
    # shellcheck disable=SC2034 # salida mediante nameref
    dest["$k"]="$v"
  done < "$f"
}

# Identidad CLAVE=VALOR: conserva el valor exacto como los consumidores reales.
# Las comillas no son sintaxis shell. Duplicados y controles siguen cerrando la puerta.
leer_identidad() { # ruta nombre de array asociativo
  local f="$1" line k seen=':'
  local -n identidad_dest="$2"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ $line =~ ^[A-Z][A-Z0-9_]*= ]] || return 1
    [[ $line =~ [[:cntrl:]] ]] && return 1
    k="${line%%=*}"
    case "$seen" in *":$k:"*) return 1 ;; esac; seen="$seen$k:"
    # shellcheck disable=SC2034 # salida mediante nameref
    identidad_dest["$k"]="${line#*=}"
  done < "$f"
}

# Rechazo conservador también de marcadores entrecomillados; no transforma el valor leído.
identidad_pendiente() {
  local v="$1"
  [[ $v =~ ^PENDIENTE-[A-Z][A-Z0-9_]*$ ]] ||
    [[ $v =~ ^\"PENDIENTE-[A-Z][A-Z0-9_]*\"$ ]] ||
    [[ $v =~ ^\'PENDIENTE-[A-Z][A-Z0-9_]*\'$ ]]
}

# Mismo confinamiento del lector real de identidad, solo metadatos: nunca lee tokens.
env_rel_seguro() {
  local rel="$1" home_r target_r
  case "$rel" in /*|*"\\"*) return 1 ;; */.env.local) : ;; *) return 1 ;; esac
  [[ $rel =~ (^|/)\.\.?(/|$) ]] && return 1
  home_r="$(realpath -e -- "${HOST_HOME:-$HOME}" 2>/dev/null)" || return 1
  target_r="$(realpath -e -- "${HOST_HOME:-$HOME}/$rel" 2>/dev/null)" || return 1
  case "$target_r" in "$home_r"/*) [ -f "$target_r" ] ;; *) return 1 ;; esac
}

check_identidad() {
  local co="$SKILLS/talent-channel-operation/scripts" orq="$SKILLS/talent-orchestrator/scripts"
  local k v envf mode invalid=0
  local -A canal=() torre=() runtime=() autoridad=()
  AUDIT_CLI=''; DEV_CLI=''; TMUX_CANAL='v'; CUSER=''; IDENT_OK=0
  if ! leer_identidad "$co/repo-identity.conf" canal || ! leer_identidad "$orq/repo-identity.conf" torre; then
    falla identidad proyecto 'identidad ausente, ilegible o fuera de gramática clave=valor'; return
  fi
  if [ -e "${SECRET_DIR:-${HOST_HOME:-$HOME}/.config/talent-channel-operation}/agents.conf" ] &&
     ! leer_conf "${SECRET_DIR:-${HOST_HOME:-$HOME}/.config/talent-channel-operation}/agents.conf" runtime agents; then
    falla identidad canal-operation 'agents.conf no es dato literal comprobable'; return
  fi
  for k in PKG_IDENTITY_PROJECT TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE; do
    v="${canal[$k]-}"
    if [ -z "$v" ] || identidad_pendiente "$v"; then invalid=1; fi
  done
  for k in "${!canal[@]}"; do
    case "$k" in PKG_IDENTITY_PROJECT|TCO_REPO_DIR|TCO_REPO_SLUG|TCO_REPO_STACK|TCO_ANEXO_FILE|TCO_SUPABASE_REF|TCO_LINEAR_INPROGRESS_STATE|TCO_LINEAR_INREVIEW_STATE|TCO_POSTMERGE_CMD|TCO_HOST_ENV_REL|TCO_TF_MANIFEST) : ;; *) invalid=1 ;; esac
    v="${canal[$k]}"
    if [ -z "$v" ] || identidad_pendiente "$v"; then invalid=1; fi
    if { [[ -v $k ]] && [ "${!k}" != "${canal[$k]}" ]; } ||
       { [[ -v runtime[$k] ]] && [ "${runtime[$k]}" != "${canal[$k]}" ]; }; then invalid=1; fi
  done
  for k in TCO_REPO_DIR TCO_REPO_SLUG TCO_REPO_STACK TCO_ANEXO_FILE TCO_SUPABASE_REF TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE TCO_POSTMERGE_CMD TCO_HOST_ENV_REL TCO_HOST_ENV TCO_TF_MANIFEST; do
    v="${runtime[$k]-${!k-}}"
    identidad_pendiente "$v" && invalid=1
  done
  case "${canal[TCO_REPO_STACK]-}" in
    ninguno) case "${canal[TCO_SUPABASE_REF]-}" in ''|no-aplica) : ;; *) invalid=1 ;; esac ;;
    convex) [ "${canal[TCO_SUPABASE_REF]-}" = no-aplica ] || invalid=1 ;;
    supabase) [[ ${canal[TCO_SUPABASE_REF]-} =~ ^[a-z0-9]{15,30}$ ]] || invalid=1 ;;
    *) invalid=1 ;;
  esac
  for k in TCO_LINEAR_INPROGRESS_STATE TCO_LINEAR_INREVIEW_STATE; do
    [[ ${canal[$k]-} =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || invalid=1
  done
  [[ ${canal[PKG_IDENTITY_PROJECT]-} =~ ^[A-Za-z0-9_.-]+$ ]] || invalid=1
  [[ ${canal[TCO_REPO_DIR]-} =~ ^[A-Za-z0-9_.-]+$ ]] || invalid=1
  [[ ${canal[TCO_REPO_SLUG]-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || invalid=1
  [[ ${canal[TCO_ANEXO_FILE]-} =~ ^references/anexo-[A-Za-z0-9_.-]+\.md$ ]] || invalid=1
  # La procedencia se contrasta con la autoridad de ESTA instancia. Dos copias iguales
  # del origen no acreditan adjudicación. Solo datos TF_*, nunca ejecutar el manifiesto.
  local af="${canal[TCO_TF_MANIFEST]-${TF_MANIFEST-}}" slug
  if [ -z "$af" ] || ! leer_conf "$af" autoridad; then
    noverif identidad procedencia 'falta autoridad legible de instancia (TCO_TF_MANIFEST o TF_MANIFEST)'; invalid=1
  else
    slug="${autoridad[TF_REPO_URL]-}"; slug="${slug%.git}"; slug="${slug#https://}"; slug="${slug#*/}"
    [ "${autoridad[TF_PROJECT]-}" = "${canal[PKG_IDENTITY_PROJECT]-}" ] &&
      [ "$slug" = "${canal[TCO_REPO_SLUG]-}" ] && [ "${slug##*/}" = "${canal[TCO_REPO_DIR]-}" ] || invalid=1
  fi
  envf="${runtime[TCO_HOST_ENV]-${TCO_HOST_ENV-}}"
  if [ -n "$envf" ]; then
    case "$envf" in /*) : ;; *) invalid=1 ;; esac
  else
    env_rel_seguro "${canal[TCO_HOST_ENV_REL]-}" || invalid=1
    envf="${HOST_HOME:-$HOME}/${canal[TCO_HOST_ENV_REL]-}"
  fi
  if [ "$invalid" -ne 0 ]; then falla identidad canal-operation 'identidad sin adjudicar, formato inválido u override divergente'
  else
    ok identidad canal-operation 'identidad adjudicada leída como datos (sin overrides divergentes)'; IDENT_OK=1
    AUDIT_CLI="${runtime[TCO_AUDIT_CLI]-${TCO_AUDIT_CLI-}}"
    DEV_CLI="${runtime[TCO_DEV_CLI]-${TCO_DEV_CLI-}}"
    TMUX_CANAL="${runtime[TCO_TMUX]-${TCO_TMUX:-v}}"; CUSER="${runtime[TCO_CUSER]-${TCO_CUSER:-vivecoder}}"
    if [ ! -f "$envf" ]; then falla identidad tokens 'fichero de tokens ausente'
    elif ! mode="$(stat -c '%a' "$envf" 2>/dev/null)"; then noverif identidad tokens 'stat de tokens falló'
    elif [ "$mode" = 600 ]; then ok identidad tokens 'tokens presentes con modo 600 (solo stat)'
    else falla identidad tokens 'tokens sin modo 600'; fi
  fi
  # [issue 9011] Revisor sin capa externa: desviación DECLARADA (informativa, línea OK). Un valor fuera de
  # coderabbit|code-audit es FALLA; coderabbit o ausente no emite nada (el doctor de siempre).
  case "${runtime[TCO_REVISOR]-${TCO_REVISOR-}}" in
    ''|coderabbit) : ;;
    code-audit) ok desviacion revisor 'revisor sin capa externa (code-audit), desviación declarada: NO recomendable; M8 solo acepta un GO verificado del head' ;;
    *) falla desviacion revisor 'TCO_REVISOR fuera de coderabbit|code-audit' ;;
  esac
  local rel="${torre[TORC_HOST_ENV_REL]-}" orq_invalid=0
  for k in "${!torre[@]}"; do
    case "$k" in PKG_IDENTITY_PROJECT|TORC_HOST_ENV_REL) : ;; *) orq_invalid=1 ;; esac
    v="${torre[$k]}"
    if [ -z "$v" ] || identidad_pendiente "$v"; then orq_invalid=1; fi
  done
  if [ -z "${TORC_HOST_ENV-}" ]; then
    env_rel_seguro "$rel" || orq_invalid=1
  else
    case "$TORC_HOST_ENV" in /*) [ -f "$TORC_HOST_ENV" ] || orq_invalid=1 ;; *) orq_invalid=1 ;; esac
  fi
  if [ "$orq_invalid" -ne 0 ] || [ -z "${torre[PKG_IDENTITY_PROJECT]-}" ] || identidad_pendiente "${torre[PKG_IDENTITY_PROJECT]-}"; then
    falla identidad proyecto 'proyecto del orquestador sin adjudicar'
  elif [ "${canal[PKG_IDENTITY_PROJECT]-}" = "${torre[PKG_IDENTITY_PROJECT]}" ]; then
    ok identidad proyecto 'PKG_IDENTITY_PROJECT coincide entre identidades adjudicadas'
  else falla identidad proyecto 'PKG_IDENTITY_PROJECT difiere entre channel-operation y orchestrator'; fi
}

# ═══ 2 · Bus y cursores (C6): estado, permisos, cursor, marca de inodo — solo `stat`/`cat` ═════════
dir_seguro() { # ruta etiqueta → rc 0 seguro (700, propio, no symlink); emite la línea
  local d="$1" et="$2" modo
  if [ -L "$d" ]; then falla bus "$et" "es un symlink: $d"; return 1; fi
  if [ ! -e "$d" ]; then falla bus "$et" "no existe: $d"; return 1; fi
  if [ ! -d "$d" ]; then falla bus "$et" "existe y no es directorio: $d"; return 1; fi
  if [ ! -O "$d" ]; then falla bus "$et" "no pertenece al UID actual: $d"; return 1; fi
  modo="$(stat -c '%a' "$d" 2>/dev/null || true)"
  if [ "$modo" != 700 ]; then falla bus "$et" "modo ${modo:-ilegible}, se exige 700: $d"; return 1; fi
  ok bus "$et" "700 y propio"
  return 0
}

check_bus() {
  local base cdir lectores l cur marca pos tam idb idm ids='' t
  if [ -n "$BUS_PERFIL" ] && [ -n "${TA_BUS-}" ] && [ "$BUS_PERFIL" != "$TA_BUS" ]; then
    falla bus ruta "TA_BUS ($TA_BUS) difiere del path= de la fila bus ($BUS_PERFIL)"
  fi
  BUS_LEGIBLE=0
  if [ -f "$BUS" ] && [ -r "$BUS" ]; then
    BUS_LEGIBLE=1; ok bus fichero "legible: $BUS"
  else
    falla bus fichero "ausente o ilegible: $BUS"
  fi
  base="$(bus_dir_estado)"
  cdir="${TA_BUS_CURSOR_DIR:-$base/cursores}"
  dir_seguro "$base" estado || true
  dir_seguro "$cdir" cursores || true

  # Lectores: la fila bus los declara (`lectores=a,b`); por defecto, toda fila ceo/torre/estacion.
  if [ -n "$BUS_LECTORES" ]; then
    lectores="$(printf '%s' "$BUS_LECTORES" | tr ',' '\n')"
  else
    for t in ceo torre estacion; do
      while IFS= read -r _f; do
        [ -n "$_f" ] || continue; perfil_campos "$_f"; ids="${ids}${PERFIL_CAMPOS[1]-}"$'\n'
      done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
    done
    lectores="$ids"
  fi
  tam=''
  [ "$BUS_LEGIBLE" -eq 1 ] && tam="$(wc -c < "$BUS" 2>/dev/null | tr -d ' ')"
  idb=''
  [ "$BUS_LEGIBLE" -eq 1 ] && idb="$(stat -c '%d:%i' "$BUS" 2>/dev/null || true)"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if ! printf '%s' "$l" | grep -Eq "$BUS_ID_CHARSET"; then
      falla cursor "$l" "id de lector fuera del charset [A-Za-z0-9_-]{1,32}"; continue
    fi
    cur="$cdir/$l.cursor"; marca="$cdir/$l.bus"
    if [ -L "$cur" ]; then falla cursor "$l" "el cursor es un symlink"; continue; fi
    if [ ! -e "$cur" ]; then falla cursor "$l" "falta $l.cursor: ese lector nunca ha leído (¿el cron no corre?)"; continue; fi
    if [ ! -f "$cur" ]; then falla cursor "$l" "el cursor no es un fichero regular"; continue; fi
    if [ "$BUS_LEGIBLE" -ne 1 ]; then noverif cursor "$l" "bus ilegible: no se puede contrastar el cursor"; continue; fi
    pos="$(cat "$cur" 2>/dev/null || echo '')"
    case "$pos" in ''|*[!0-9]*) falla cursor "$l" "el cursor no es un entero"; continue ;; esac
    if [ "${#pos}" -gt 18 ] || [ "$pos" -gt "${tam:-0}" ]; then
      falla cursor "$l" "el cursor ($pos) supera el tamaño del bus (${tam:-?} bytes): truncado, rotado o corrupto"; continue
    fi
    if [ -L "$marca" ]; then falla cursor "$l" "la marca .bus es un symlink"; continue; fi
    idm=''
    [ -f "$marca" ] && idm="$(cat "$marca" 2>/dev/null || echo '')"
    if [ -z "$idm" ]; then
      if [ "$((10#$pos))" -eq 0 ]; then ok cursor "$l" "cursor en 0 sin marca (nada que perder)"
      else falla cursor "$l" "cursor en $pos sin marca .bus: no se puede acreditar que apunte a ESTE bus"; fi
    elif [ "$idm" != "$idb" ]; then
      falla cursor "$l" "la marca .bus ($idm) no es el inodo del bus ($idb): bus rotado o sustituido"
    else
      ok cursor "$l" "cursor $pos/${tam} con marca de inodo vigente"
    fi
  done <<< "$lectores"
}

# ═══ 3 · Crons (C5): cada fila `cron` debe tener su línea en `crontab -l` ═════════════════════════
check_crons() {
  local f id attrs usr min tab
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    perfil_campos "$f"; id="${PERFIL_CAMPOS[1]-}"; attrs="${PERFIL_CAMPOS[5]-}"
    usr="$(perfil_attr "$attrs" usuario || true)"
    if ! min="$(bash "$HERE/tablas-cron.sh" --minutos "$id" 2>/dev/null)" || [ -z "$min" ]; then
      falla cron "$id" "tablas-cron.sh --minutos no resuelve los minutos de la fila"; continue
    fi
    if [ -n "$usr" ] && ! usuario_ok "$usr"; then falla cron "$id" "usuario= fuera de charset"; continue; fi
    if usuario_ausente "$usr"; then falla cron "$id" "el usuario del SO \"$usr\" no existe en esta máquina: no hay crontab que contenga la línea"; continue; fi
    como "$usr" crontab -l
    if [ "$COMO_SUDO" -eq 1 ]; then noverif cron "$id" "no puedo leer el crontab de \"$usr\" sin contraseña (sudo -n)"; continue; fi
    if [ "$COMO_RC" -ne 0 ]; then noverif cron "$id" "crontab -l falló (rc=$COMO_RC)"; continue; fi
    tab="$(printf '%s\n' "$COMO_OUT" | TA_MIN="$min" TA_ID="$id" awk '
      /^[[:space:]]*#/ { next }
      $1 == ENVIRON["TA_MIN"] && $2 == "*" && $3 == "*" && $4 == "*" && $5 == "*" && index($0, ENVIRON["TA_ID"]) > 0 { n++ }
      END { print n + 0 }')"
    if [ "$tab" -ge 1 ]; then ok cron "$id" "línea presente con minutos $min"
    else falla cron "$id" "ninguna línea de crontab con los minutos $min y el id en el comando"; fi
  done <<< "$(perfil_rows cron 2>/dev/null || true)"
}

# ═══ 4 · Actores con sesión (torres, estaciones, ceo): C3 C4 C10 C11 ══════════════════════════════
LIB_TORRE="$SKILLS/talent-orchestrator/scripts/lib-torre.sh"
if [ -f "$LIB_TORRE" ]; then
  # shellcheck source=/dev/null
  . "$LIB_TORRE"
fi

# La regex del `ctx:` está DUPLICADA a propósito (sin `source` de 00-config.sh del orquestador): la
# misma de `tc_ctx_pct` (talent-context) y `torc_torre_ctx_pct`; un test las ata. Último match.
ctx_de_captura() { # stdin = captura → N · rc 1 sin match (UNKNOWN: jamás se asume 0)
  local esc pct; esc="$(printf '\033')"
  pct="$(sed -E -e "s/${esc}\[[0-9;]*m//g" | grep -oiE 'ctx[:= ][[:space:]]*[0-9]{1,3}[[:space:]]*%' \
    | tail -n 1 | grep -oE '[0-9]{1,3}')" || return 1
  [ -n "$pct" ] || return 1
  printf '%s\n' "$pct"
}

# Comprueba el registro del MISMO usuario que posee la torre.
check_modelo_actor() {
  local tipo="$1" id="$2" usr="$3" cap="$4" model label
  if [ "$tipo" = ceo ]; then tipo=ceo; else tipo=coordinador; fi
  # shellcheck disable=SC2016 # Código literal para el proceso del propietario.
  como "$usr" bash -c '. "$1"; tco_modelo_read "$2"' _ "$SKILLS/talent-channel-operation/scripts/lib-modelos.sh" "$tipo"
  if [ "$COMO_RC" -ne 0 ]; then noverif modelo "$id" 'registro del usuario ausente o inválido; ejecutar resolver-modelos.sh como ese usuario'; return; fi
  model="$COMO_OUT"
  label="$(printf '%s\n' "$cap" | grep -oiE '\[(Opus|Sonnet)[^][]*\]' | tail -1)"
  if printf '%s\n' "$label" | tco_modelo_etiqueta_is "$model"; then ok modelo "$id" "$model vigente"
  else falla modelo "$id" "torre pendiente de cambiar a $model"; fi
}
check_actor() { # tipo fila
  local tipo="$1" fila="$2" id maq ses attrs usr cat=torre rol pids ps_out comms cap alt created est runtime_dir
  perfil_campos "$fila"
  id="${PERFIL_CAMPOS[1]-}"; maq="${PERFIL_CAMPOS[2]-}"; ses="${PERFIL_CAMPOS[4]-}"; attrs="${PERFIL_CAMPOS[5]-}"
  rol="$id"; usr="$(perfil_attr "$attrs" usuario || true)"
  if ! printf '%s' "$rol" | grep -Eq "$BUS_ID_CHARSET"; then falla "$cat" "$id" 'rol fuera del charset'; return 0; fi
  if [ "$tipo" = ceo ]; then
    case "$ses" in ''|'-'|ninguna) return 0 ;; esac    # un CEO sin pane declarado no es un actor con sesión
  fi
  case "$maq" in
    ''|'-') falla "$cat" "$id" "el perfil no declara en qué máquina vive ($tipo)"; return 0 ;;
  esac
  if [ "$maq" != "$LOCAL_ID" ]; then
    noverif "$cat" "$id" "vive en la máquina \"$maq\" y ésta es \"$LOCAL_ID\": no se verifica desde aquí"; return 0
  fi
  case "$ses" in ''|'-'|ninguna) falla "$cat" "$id" "el perfil no declara sesión tmux ($tipo)"; return 0 ;; esac
  if ! nombre_ok "$ses"; then falla "$cat" "$id" "nombre de sesión fuera de charset"; return 0; fi
  if [ -n "$usr" ] && ! usuario_ok "$usr"; then falla "$cat" "$id" "usuario= fuera de charset"; return 0; fi
  if usuario_ausente "$usr"; then falla "$cat" "$id" "el usuario del SO \"$usr\" no existe en esta máquina: su sesión no puede existir"; return 0; fi

  como "$usr" tmux has-session -t "=$ses"
  if [ "$COMO_SUDO" -eq 1 ]; then noverif "$cat" "$id" "no puedo consultar tmux de \"$usr\" sin contraseña (sudo -n)"; return 0; fi
  if [ "$COMO_RC" -ne 0 ]; then noverif "$cat" "$id" "has-session falló (sesión ausente o consulta fallida)"; return 0; fi

  # Proceso: un `claude` DESCENDIENTE del pane, por ejecutable.
  como "$usr" tmux list-panes -t "=$ses:" -F '#{pane_pid}'
  if [ "$COMO_RC" -ne 0 ]; then noverif "$cat" "$id" 'list-panes falló'; return 0; fi
  pids="$COMO_OUT"
  if ! ps_out="$(ps -e -o pid=,ppid=,comm= 2>/dev/null)"; then noverif "$cat" "$id" 'ps falló'; return 0; fi
  comms="$(printf '%s\n' "$ps_out" | descendientes_comm "$pids")"
  if ! printf '%s\n' "$comms" | grep -qx 'claude'; then
    falla "$cat" "$id" "sesión \"$ses\" viva sin proceso claude descendiente del pane"; return 0
  fi
  ok "$cat" "$id" "sesión \"$ses\" viva con proceso claude"

  como "$usr" tmux display-message -p -t "=$ses:" '#{alternate_on}|#{session_created}'
  if [ "$COMO_RC" -ne 0 ]; then noverif renderer "$id" 'display-message falló'; return 0; fi
  alt="${COMO_OUT%%|*}"; created="${COMO_OUT#*|}"
  case "$alt" in
    1) falla renderer "$id" "alternate_on=1: el pane corre el renderer de pantalla alternativa (sin scrollback ni ctx: legible)" ;;
    0) ok renderer "$id" "alternate_on=0" ;;
    *) noverif renderer "$id" "alternate_on ilegible" ;;
  esac
  como "$usr" tmux capture-pane -p -J -t "=$ses:"
  cap="$COMO_OUT"
  local captura_rc="$COMO_RC"
  if [ "$captura_rc" = 0 ]; then check_modelo_actor "$tipo" "$id" "$usr" "$cap"; else noverif modelo "$id" "captura fallida"; fi
  COMO_RC="$captura_rc"
  if [ "$COMO_RC" -ne 0 ]; then
    noverif ctx "$id" "captura del pane fallida"
  elif est="$(printf '%s\n' "$cap" | ctx_de_captura)"; then
    ok ctx "$id" "ctx: ${est}%"
  else
    falla ctx "$id" "la barra de estado no muestra ctx: (UNKNOWN; nunca se asume 0)"
  fi

  # C10: menú abierto sin escalar.
  if ! declare -F torc_torre_menu_open >/dev/null 2>&1; then
    noverif menu "$id" "no encuentro lib-torre.sh (talent-orchestrator); no se puede detectar un menú abierto"
  elif [ "$COMO_RC" -ne 0 ]; then
    noverif menu "$id" "captura del pane fallida"
  elif printf '%s\n' "$cap" | torc_torre_menu_open; then
    if [ "$BUS_LEGIBLE" -ne 1 ]; then
      noverif menu "$id" "menú abierto pero el bus es ilegible: no se puede saber si escaló"
    elif ultimo_sello "$rol" && case "$US_MARK" in "ESCALA-$rol-"*) true ;; *) false ;; esac; then
      ok escalado "$id" "menú abierto y el último sello es $US_MARK"
    elif ultimo_sello "$rol" && [ "$US_TS" -le "$NOW" ] && [ $((NOW - US_TS)) -le $((ESC_MIN * 60)) ]; then
      ok menu-reciente "$id" "menú abierto; último sello hace $(((NOW - US_TS) / 60)) min (< $ESC_MIN)"
    else
      falla bloqueo-sin-escalar "$id" "menú abierto y sin sello ESCALA-$rol-* en los últimos $ESC_MIN min"
    fi
  else
    ok menu "$id" "sin menú abierto"
    if printf '%s\n' "$cap" | torc_torre_question_pending && [ "$BUS_LEGIBLE" -eq 1 ]; then
      if ! escalado_reciente "$rol"; then
        printf 'AVISO posible-pregunta-sin-escalar %s: pregunta final en reposo sin escalado en %s min (heurística informativa)\n' "$(inerte "$id")" "$ESC_MIN"
      fi
    fi
  fi

  # C11: acreditación — sello propio posterior al inicio de la sesión, y no NO_ACREDITADO.
  case "$created" in
    ''|*[!0-9]*) noverif acreditacion "$id" "session_created ilegible"; return 0 ;;
  esac
  if [ -n "$usr" ] && [ "$usr" != "$YO" ]; then
    runtime_dir="$(perfil_attr "$attrs" estado_bus || true)"
    if [ -n "$runtime_dir" ]; then
      case "$runtime_dir" in /*) : ;; *) noverif acreditacion "$id" 'estado_bus no es absoluto'; return 0 ;; esac
      como "$usr" env "TA_BUS_STATE_DIR=$runtime_dir" bash "$HERE/leer-acreditacion.sh" "$rol"
    elif [ -n "${TA_BUS_STATE_DIR:-}" ]; then
      runtime_dir="$(getent passwd "$usr" | cut -d: -f6)"
      case "$runtime_dir" in /*) : ;; *) noverif acreditacion "$id" 'home del actor no verificable'; return 0 ;; esac
      como "$usr" env "TA_BUS_STATE_DIR=$runtime_dir/.local/state/talent-ceo" bash "$HERE/leer-acreditacion.sh" "$rol"
    else
      runtime_dir="$(perfil_attr "$attrs" estado_runtime || true)"
      if [ -n "$runtime_dir" ]; then
        case "$runtime_dir" in /*) : ;; *) noverif acreditacion "$id" 'estado_runtime no es absoluto'; return 0 ;; esac
        como "$usr" env "XDG_RUNTIME_DIR=$runtime_dir" bash "$HERE/leer-acreditacion.sh" "$rol"
      else
        como "$usr" env -u XDG_RUNTIME_DIR bash "$HERE/leer-acreditacion.sh" "$rol"
      fi
    fi
  else
    como "$usr" bash "$HERE/leer-acreditacion.sh" "$rol"
  fi
  if [ "$COMO_RC" -ne 0 ]; then noverif acreditacion "$id" 'estado ausente no comprobable, ilegible, ajeno o inseguro'; return 0; fi
  est="$COMO_OUT"
  case "$est" in ACREDITADO|NO_ACREDITADO|AUSENTE) : ;; *) falla acreditacion "$id" 'contenido de estado desconocido'; return 0 ;; esac
  if [ "$est" = NO_ACREDITADO ]; then
    falla acreditacion "$id" "NO_ACREDITADO: re-acredita con reacreditar.sh --rol $rol --iniciar y sella el marcador"; return 0
  fi
  if [ "$BUS_LEGIBLE" -ne 1 ]; then
    noverif acreditacion "$id" "bus ilegible: no se pueden leer sus sellos"
  elif ! ultimo_sello "$rol"; then
    falla acreditacion "$id" "el rol nunca ha sellado en el bus"
  elif [ "$US_TS" -le "$created" ]; then
    falla acreditacion "$id" "sin sello propio posterior al inicio de su sesión (último: $US_MARK)"
  else
    ok acreditacion "$id" "sello propio posterior al inicio de la sesión ($US_MARK)"
  fi
}

check_actores() {
  local t f
  for t in torre estacion ceo; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      check_actor "$t" "$f"
    done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
  done
}

# ═══ 5 · Canales y runners (C7): contenedor vivo; pane de auditoría con el binario esperado ════════
# El mando aporta su registro; el operador solo consulta el panel con incus.
check_modelo_auditor() { # id usuario contenedor pane [fase]
  local id="$1" usr="$2" cont="$3" pane="$4" model cap label fase="${5:-audit}" categoria=modelo-auditor actor=auditor
  if [ "$fase" != audit ]; then categoria=modelo-desarrollo; actor=desarrollo; fi
  if ! model="$(tco_modelo_read "$fase" 2>/dev/null)" || [ -z "$model" ]; then
    noverif "$categoria" "$id" 'registro del mando ausente o inválido'; return
  fi
  como "$usr" incus exec "$cont" -- su - "$CUSER" -c "tmux capture-pane -p -t '$pane' -J -S -80"
  if [ "$COMO_RC" -ne 0 ]; then
    if [ "$fase" = audit ]; then noverif "$categoria" "$id" 'captura del auditor no comprobable'
    else noverif "$categoria" "$id" 'captura de desarrollo no comprobable'; fi
    return
  fi
  cap="$COMO_OUT"
  label="$(printf '%s\n' "$cap" | grep -oEi '\[(Opus|Sonnet)[^]]*\]' | tail -1)"
  if printf '%s\n' "$label" | tco_modelo_etiqueta_is "$model"; then ok "$categoria" "$id" "$model vigente"
  else falla "$categoria" "$id" "$actor pendiente de cambiar a $model"; fi
}

# El desarrollo puede estar en plan/fallback o coding; comprobar la versión de su familia.
check_modelo_desarrollo() { # id usuario contenedor pane
  local cap label fase=coding
  como "$2" incus exec "$3" -- su - "$CUSER" -c "tmux capture-pane -p -t '$4' -J -S -80"
  if [ "$COMO_RC" -ne 0 ]; then noverif modelo-desarrollo "$1" 'captura de desarrollo no comprobable'; return; fi
  cap="$COMO_OUT"
  label="$(printf '%s\n' "$cap" | grep -oEi '\[(Opus|Sonnet)[^]]*\]' | tail -1)"
  if printf '%s\n' "$label" | grep -qi '^\[Opus'; then fase=plan; fi
  check_modelo_auditor "$1" "$2" "$3" "$4" "$fase"
}

# Canales/runners RUNNING en esta máquina con usuario de canal resuelto: los miden las sondas de seguridad; los
# RUNNING que se quedan fuera (identidad sin resolver) se anotan en SEG_C_EXC para no omitirlos en silencio.
declare -a SEG_C_ID=() SEG_C_USR=() SEG_C_CONT=() SEG_C_EXC=()
check_canales() {
  local t f id maq cont attrs usr st bin pane comms
  for t in canal runner; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      perfil_campos "$f"
      id="${PERFIL_CAMPOS[1]-}"; maq="${PERFIL_CAMPOS[2]-}"; cont="${PERFIL_CAMPOS[3]-}"; attrs="${PERFIL_CAMPOS[5]-}"
      usr="$(perfil_attr "$attrs" usuario || true)"
      case "$maq" in ''|'-') falla canal "$id" "el perfil no declara en qué máquina vive ($t)"; continue ;; esac
      if [ "$maq" != "$LOCAL_ID" ]; then
        noverif canal "$id" "vive en la máquina \"$maq\" y ésta es \"$LOCAL_ID\": no se verifica desde aquí"; continue
      fi
      case "$cont" in ''|'-') falla canal "$id" "el perfil no declara contenedor ($t)"; continue ;; esac
      if ! nombre_ok "$cont"; then falla canal "$id" "contenedor fuera de charset"; continue; fi
      if [ -n "$usr" ] && ! usuario_ok "$usr"; then falla canal "$id" "usuario= fuera de charset"; continue; fi
      if usuario_ausente "$usr"; then falla canal "$id" "el usuario del SO \"$usr\" no existe en esta máquina: no opera contenedores aquí"; continue; fi
      if ! command -v incus >/dev/null 2>&1; then noverif canal "$id" "no hay \`incus\` en el PATH"; continue; fi
      como "$usr" incus list -c ns -f csv
      if [ "$COMO_SUDO" -eq 1 ]; then noverif canal "$id" "no puedo consultar incus como \"$usr\" sin contraseña (sudo -n)"; continue; fi
      if [ "$COMO_RC" -ne 0 ]; then noverif canal "$id" "incus list falló (rc=$COMO_RC)"; continue; fi
      st="$(printf '%s\n' "$COMO_OUT" | TA_C="$cont" awk -F',' '$1 == ENVIRON["TA_C"] { print $2; exit }')"
      if [ -z "$st" ]; then falla canal "$id" "contenedor \"$cont\" ausente"; continue; fi
      if [ "$st" != RUNNING ]; then falla canal "$id" "contenedor \"$cont\" en estado $st (no RUNNING)"; continue; fi
      ok canal "$id" "contenedor \"$cont\" RUNNING"
      if [ "${IDENT_OK:-0}" -eq 1 ] && usuario_ok "${CUSER-}"; then
        SEG_C_ID+=("$id"); SEG_C_USR+=("$usr"); SEG_C_CONT+=("$cont")
      else
        SEG_C_EXC+=("$id")
      fi
      [ "$t" = canal ] || continue
      # El binario del auditor sale de la identidad del canal: si ésta no se resolvió, el FALLA de
      # `identidad` ya cierra la puerta y no se inventa un segundo fallo sobre un dato que no existe.
      [ "${IDENT_OK:-0}" -eq 1 ] || continue
      # Pane de auditoría: el binario del descendiente del pane .1 debe ser TCO_AUDIT_CLI.
      if [ -z "${AUDIT_CLI-}" ]; then falla auditor "$id" "TCO_AUDIT_CLI vacío: no hay binario de referencia para el auditor"; continue; fi
      bin="$(tco_cli_exe "$AUDIT_CLI")" || { falla auditor "$id" 'lanzador del auditor inválido'; continue; }
      if ! usuario_ok "${CUSER-}" || ! nombre_ok "${TMUX_CANAL-}"; then
        noverif auditor "$id" "TCO_CUSER o TCO_TMUX ilegibles en la identidad del canal"; continue
      fi
      pane="${TMUX_CANAL}:.1"
      case "${DEV_CLI:-}" in *claude*) check_modelo_desarrollo "$id" "$usr" "$cont" "${TMUX_CANAL}:.0" ;; esac
      # Mismo criterio que el despacho: /proc/PID/exe y ruta resuelta del CLI,
      # incluidos scripts de intérpretes conocidos; cualquier lectura parcial cierra.
      como "$usr" bash "$HERE/leer-auditor.sh" "$cont" "$pane" "$CUSER" "$AUDIT_CLI"
      if [ "$COMO_RC" -ne 0 ]; then noverif auditor "$id" 'identidad real del pane no comprobable'; continue; fi
      comms="$COMO_OUT"
      if printf '%s\n' "$comms" | grep -qxF "$bin"; then
        # Ley del lead (7-nov): el revisor es SIEMPRE Codex. Un auditor que no lo es no se mide: se declara FALLA (se PARA y se escala).
        case "$bin" in
          codex|codex-root) ok auditor "$id" "pane de auditoría con el binario $bin" ;;
          *) falla auditor "$id" "el pane de auditoría ejecuta $bin y Codex es obligatorio como revisor: se PARA y se escala" ;;
        esac
      else
        falla auditor "$id" "el pane de auditoría no ejecuta $bin (procesos: $(printf '%s' "$comms" | tr '\n' ' '))"
      fi
    done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
  done
}

# ═══ 6 · Sellado imposible (C9): la MISMA regla de ambigüedad que `bus-sellar.sh` (rc 2) ═══════════
# Un actor que debe sellar (torre, estación, ceo) y otro actor de la MISMA máquina que no se distingue
# de él por `usuario=` → `bus-sellar.sh` se niega (rc 2). Se replica la regla para ver el fallo ANTES
# de que un actor intente sellar y no pueda; el guard NO se toca.
check_sellado() {
  local t f id maq attrs usr o rid rmaq rattrs rusr amb
  for t in torre estacion ceo; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      perfil_campos "$f"
      id="${PERFIL_CAMPOS[1]-}"; maq="${PERFIL_CAMPOS[2]-}"; attrs="${PERFIL_CAMPOS[5]-}"
      [ "$maq" = "$LOCAL_ID" ] || continue
      usr="$(perfil_attr "$attrs" usuario || true)"
      amb=''
      for o in torre estacion canal runner ceo pm; do
        while IFS= read -r _r; do
          [ -n "$_r" ] || continue
          perfil_campos "$_r"
          rid="${PERFIL_CAMPOS[1]-}"; rmaq="${PERFIL_CAMPOS[2]-}"; rattrs="${PERFIL_CAMPOS[5]-}"
          [ "$rid" = "$id" ] && continue
          [ "$rmaq" = "$LOCAL_ID" ] || continue
          rusr="$(perfil_attr "$rattrs" usuario || true)"
          if [ -z "$usr" ] || [ -z "$rusr" ] || [ "$rusr" = "$usr" ]; then amb="$rid"; break; fi
        done <<< "$(perfil_rows "$o" 2>/dev/null || true)"
        [ -n "$amb" ] && break
      done
      if [ -n "$amb" ]; then
        falla sellado-imposible "$id" "comparte máquina con \"$amb\" sin distinguirse por usuario=: bus-sellar.sh se negará (rc 2)"
      else
        ok sellado "$id" "distinguible por usuario= de todo actor de su máquina"
      fi
    done <<< "$(perfil_rows "$t" 2>/dev/null || true)"
  done
}

# Modo escritor: identidad y canales (salida descartada: solo llenan CUSER, IDENT_OK y la lista de canales), el
# manifiesto, la búsqueda y su sello. No ejecuta el resto del doctor.
if [ "$SEGURIDAD" -eq 1 ]; then
  { check_identidad; check_canales; } >/dev/null
  desvio_init
  seg_escritor; exit $?
fi
check_identidad
check_bus
check_crons
check_actores
check_canales
check_sellado

[ "$REMEDIOS_OK" -eq 1 ] || falla doctor.d remedios 'tabla de remedios ausente o inválida'
desvio_init
check_version
check_nucleo
check_miembros
check_modelos_rol
check_guardas
check_sondas_alcance
check_node
check_litellm_resultado
check_zombis
check_doctor_extra
[ "$INFORME" -eq 0 ] || desvio_informe
if [ "$INFORME" -eq 1 ] && [ "$N_AVISO" -gt 0 ]; then
  printf '\nAvisos informativos (no cierran la puerta):\n| aviso | gravedad | cómo volver |\n|---|---|---|\n'
  printf '%s\n' "${D_AVISOS[@]}"
fi

TOTAL=$((N_OK + N_FALLA + N_NOVERIF))
[ "$TOTAL" -gt 0 ] || die2 "el perfil no declara nada que comprobar; un doctor que no comprueba nada no da verde"
printf 'RESUMEN ok=%d falla=%d noverif=%d\n' "$N_OK" "$N_FALLA" "$N_NOVERIF"
if [ "$N_FALLA" -eq 0 ] && [ "$N_NOVERIF" -eq 0 ]; then
  echo 'PUERTA ABIERTA'; exit 0
fi
echo 'PUERTA CERRADA'; exit 1
