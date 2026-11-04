#!/usr/bin/env bash
# pozos-lib.sh — funciones comunes de la operación de pozos por TOKENS LARGOS (TAL-5115, doctrina 2026-09-01).
# Contrato de secretos: el valor de un token o access token JAMÁS se imprime, ni viaja por tmux/argv (queda en ps y en el
# scrollback): SIEMPRE por stdin a un fichero 0600 que el consumidor `source`a. Solo se imprimen longitudes, emails y porcentajes.
# Contrato anti-inyección (M5-BOUNCE 2026-09-02): TODO valor que acabe dentro de una orden ssh/incus/su/tmux pasa ANTES por
#   la allowlist de formatos (`pozos_require`) y se interpola SIEMPRE con `printf %q` (o va como argumento separado).
#   Los valores salen de ficheros del operador (pozos-lectores.map, consumidores.map) y de argv de otros pozos-*.sh: un typo
#   o una entrada comprometida NO puede convertirse en una orden extra ejecutada como root en toda la flota.
# Ficheros (todos fuera del repo, en $SECRET_DIR = ~/.config/talent-channels):
#   tokens/pN.token          token de larga duración (claude setup-token, 1 año) de la cuenta del pozo pN (0600)
#   pozos-lectores.map       "pN <contenedor-local>" | "pN <host-ip> <contenedor>" — dónde vive una LÍNEA OAuth logueada de esa cuenta
#                            (por defecto el propio contenedor pN); sirve para leer /api/oauth/usage (los tokens largos NO pueden)
#   consumidores.map         un consumidor por línea: "canal NN [A|B]" | "torre <sesion-tmux> [A|B]" | "remoto <sesion> <host-ip> <contenedor> [A|B]"
#                            (el grupo es SIEMPRE el último campo si vale A o B; por defecto canal=A, torre/remoto=B)
#   env/<consumidor>.env     (solo torres del host) fichero 0600 con `export CLAUDE_CODE_OAUTH_TOKEN=…` que la torre `source`a
#   state/                   dir PRIVADO 0700 del rotador (estado, pendiente, fallidos, pid, lock, log). NUNCA /tmp
#                            (world-readable + symlink attack). Reubicable con $POZOS_STATE_DIR.
#   ledger: $AM_LEDGER o talent-factory/ledger/cuentas.json — los pozos se DERIVAN de sus claves (nunca hardcodear p1-pN);
#           un pozo con `habilitada_fabrica: false` en el ledger NO se rota (aunque tenga token); si el campo falta, cuenta como habilitado.
set -o pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../talent-channel-operation/scripts" && pwd)/lib-modelos.sh"
SECRET_DIR=${SECRET_DIR:-$HOME/.config/talent-channels}
TOKENS_DIR=$SECRET_DIR/tokens
LEDGER=${AM_LEDGER:-${TF_ROOT:-$HOME/talent-factory}/ledger/cuentas.json}   # [TAL-8037] raíz de la fábrica parametrizable (TF_ROOT)
USAGE_CMD='TK=$(jq -r ".claudeAiOauth.accessToken // empty" ~/.claude/.credentials.json); [ -z "$TK" ] && { echo "{}"; exit; }; curl -s --max-time 15 "https://api.anthropic.com/api/oauth/usage" -H "Authorization: Bearer $TK" -H "Accept: application/json" -H "anthropic-beta: oauth-2025-04-20"'

# ------------------------------------------------- allowlist estricta de formatos (anti-inyección) -------------------
# pozos_valid <clase> <valor> → rc 0 solo si el valor encaja EXACTAMENTE en el formato permitido de esa clase:
#   host    IPv4, o hostname que empieza por alfanumérico y sigue con [A-Za-z0-9.-] (nunca por «-»: sería opción de ssh)
#   ct      contenedor incus:  [A-Za-z0-9._-]+
#   sesion  sesión/pane tmux:  [A-Za-z0-9._-]+
#   dir     carpeta del repo bajo $HOME del canal (un solo componente): [A-Za-z0-9._-]+
#   modelo  id de modelo:      claude-[a-z0-9-]+
#   pozo    id de pozo:        p[0-9]+
#   uuid    id de sesión CLI:  8-4-4-4-12 hex (para el `--resume` de las torres)
# Por construcción rechaza espacios, `;`, `|`, `&`, `$(`, backticks, comillas y saltos de línea.
pozos_valid(){ local k=$1 v=$2
  case $k in
    host)      [[ $v =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ;;
    ct|sesion|dir) [[ $v =~ ^[A-Za-z0-9._-]+$ ]] ;;
    modelo)    tco_modelos_read && { [ "$v" = "$TCO_OPUS_VIGENTE" ] || [ "$v" = "$TCO_SONNET_VIGENTE" ]; } ;;
    pozo)      [[ $v =~ ^p[0-9]+$ ]] ;;
    uuid)      [[ $v =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ;;
    *) return 1 ;;
  esac; }
# pozos_require <clase> <valor> [contexto] → valida o corta al llamante con mensaje y rc=2 (fail-closed, no ejecuta nada remoto).
pozos_require(){ local k=$1 v=$2 ctx=${3:-}
  pozos_valid "$k" "$v" && return 0
  printf 'FORMATO-INVALIDO %s=%q%s — fuera de la allowlist de la clase «%s»; no ejecuto nada remoto\n' \
    "$k" "$v" "${ctx:+ ($ctx)}" "$k" >&2
  return 2; }

# ------------------------------------------------- estado privado 0700 (anti symlink attack) -------------------------
# pozos_state_dir → imprime (creándolo 0700 si falta) el dir de estado privado del rotador. NUNCA /tmp.
pozos_state_dir(){ local d=${POZOS_STATE_DIR:-$SECRET_DIR/state}
  install -d -m 700 "$d" >/dev/null 2>&1 || { echo "ESTADO-INSEGURO: no pude crear $d con modo 700" >&2; return 2; }
  printf '%s\n' "$d"; }
# state_file <ruta> → deja la ruta lista para escribir: rechaza enlaces simbólicos y no-ficheros, y la crea 0600 con O_EXCL si falta.
state_file(){ local f=$1
  [ -L "$f" ] && { echo "ESTADO-INSEGURO: $f es un enlace simbólico — no escribo" >&2; return 2; }
  if [ ! -e "$f" ]; then ( umask 077; set -o noclobber; : > "$f" ) 2>/dev/null; fi
  [ -L "$f" ] && { echo "ESTADO-INSEGURO: $f es un enlace simbólico — no escribo" >&2; return 2; }
  [ -f "$f" ] || { echo "ESTADO-INSEGURO: $f no es un fichero regular" >&2; return 2; }
  return 0; }

pozos_list(){ python3 -c "import json,sys; d=json.load(open('$LEDGER')); print(' '.join(sorted(d.get('pozos',{}).keys(), key=lambda k:(len(k),k))))"; }
# pozos habilitados para la fábrica: excluye `habilitada_fabrica: false` (campo ausente ⇒ habilitado)
pozos_list_habilitados(){ python3 -c "
import json; d=json.load(open('$LEDGER')); pz=d.get('pozos',{})
print(' '.join(sorted((k for k,v in pz.items() if (v or {}).get('habilitada_fabrica', True) is not False), key=lambda k:(len(k),k))))"; }
pozo_cuenta(){ python3 -c "import json; d=json.load(open('$LEDGER')); print((d['pozos'].get('$1') or {}).get('cuenta','?'))"; }
# escribe un token (por stdin) en un fichero 0600 creado ANTES de volcar el contenido (sin ventana de exposición)
token_env_write(){ local dest=$1; ( umask 077; : > "$dest" ) && chmod 600 "$dest" && { printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$(cat)"; } > "$dest"; }
# normaliza consumidores.map → una línea por consumidor: "tipo nombre host contenedor grupo" ("-" en host/contenedor si no aplica)
map_entries(){ local f=${1:-$SECRET_DIR/consumidores.map}
  awk '!/^[[:space:]]*(#|$)/ { tipo=$1; nombre=$2; host="-"; ct="-"; grupo=""
      if ($NF=="A" || $NF=="B") { grupo=$NF; n=NF-1 } else { n=NF }
      if (tipo=="remoto" && n>=4) { host=$3; ct=$4 }
      if (grupo=="") grupo = (tipo=="canal") ? "A" : "B"
      print tipo, nombre, host, ct, grupo }' "$f"; }
# lector de una cuenta: devuelve JSON de /oauth/usage leído DENTRO del contenedor lector (token nunca cruza al host).
# host/contenedor salen de pozos-lectores.map: pasan por la allowlist Y por `printf %q` antes de tocar ssh/incus/su.
# Con POZOS_USAGE_JSON_FILE definido (selftest) lee ese fichero en vez de la red.
pozo_usage_json(){ local p=$1 line host ct remote
  if [ -n "${POZOS_USAGE_JSON_FILE:-}" ]; then cat "$POZOS_USAGE_JSON_FILE"; return; fi
  pozos_require pozo "$p" "pozo_usage_json" || return 2
  line=$(grep -E "^$p " "$SECRET_DIR/pozos-lectores.map" 2>/dev/null | head -1)
  set -- $line; host=""; ct=$p
  [ -n "${2:-}" ] && { if [ -n "${3:-}" ]; then host=$2; ct=$3; else ct=$2; fi; }
  pozos_require ct "$ct" "pozos-lectores.map[$p]" || return 2
  if [ -n "$host" ]; then
    pozos_require host "$host" "pozos-lectores.map[$p]" || return 2
    # el shell del host remoto RE-PARSEA el argumento de ssh: cada pieza va con %q para que llegue como UN literal
    remote=$(printf 'incus exec %q -- su - vivecoder -c %q' "$ct" "$USAGE_CMD")
    timeout 40 ssh -o BatchMode=yes -- "root@$host" "$remote" 2>/dev/null
  else incus exec "$ct" -- su - vivecoder -c "$USAGE_CMD" 2>/dev/null; fi; }
# parse: "p 5h_pct reset5_epoch 7d_pct reset7_epoch fable7d_pct fable_reset_epoch" (−1 si no hay lectura; fable=-1 si la cuenta no tiene ese cubo).
# Nunca revienta: scope.model puede ser dict ({display_name}), string o faltar; cualquier forma inesperada ⇒ fable 0/-1.
pozo_usage_row(){ local p=$1; pozo_usage_json "$p" | python3 -c "
import sys,json,datetime
p='$p'
try: d=json.load(sys.stdin)
except Exception: d={}
if not isinstance(d,dict): d={}
def epoch(r):
    try: return int(datetime.datetime.fromisoformat(str(r).replace('Z','+00:00')).timestamp())
    except Exception: return -1
def w(k):
    x=d.get(k) or {}
    if not isinstance(x,dict): x={}
    u=x.get('utilization'); r=x.get('resets_at')
    try: u=int(u) if u is not None else -1
    except Exception: u=-1
    return u, (epoch(r) if r else -1)
a,b=w('five_hour'); c,e=w('seven_day')
fab=-1; fabr=-1
lims=d.get('limits') or []
if not isinstance(lims,list): lims=[]
for l in lims:
    if not isinstance(l,dict): continue
    sc=(l.get('scope') or {}) if isinstance(l.get('scope'),dict) else {}
    m=sc.get('model')
    name=m.get('display_name','') if isinstance(m,dict) else (m if isinstance(m,str) else '')
    if l.get('kind')=='weekly_scoped' and str(name).lower()=='fable':
        try: fab=int(l.get('percent') or 0)
        except Exception: fab=0
        fabr=epoch(l.get('resets_at')) if l.get('resets_at') else -1
print(p,a,b,c,e,fab,fabr)"; }
# pozo_row_valida "<fila de pozo_usage_row>" → rc 0 solo si la cuenta es USABLE para ordenar la cola:
#   5h y 7d LEGIBLES (utilization ≥ 0) Y AMBOS resets válidos (epoch > 0). Cualquier otra fila queda fuera del orden
#   (una cuota ilegible no puede decidir a quién se gasta) y el rotador la registra como `SIN-LECTURA <pozo>`.
pozo_row_valida(){ local p a b c e rest; read -r p a b c e rest <<<"${1:-}"
  [ -n "${e:-}" ] || return 1
  [ "$a" -ge 0 ] 2>/dev/null || return 1
  [ "$c" -ge 0 ] 2>/dev/null || return 1
  [ "$b" -gt 0 ] 2>/dev/null || return 1
  [ "$e" -gt 0 ] 2>/dev/null || return 1
  return 0; }
fmt_cdmx(){ [ "$1" -gt 0 ] 2>/dev/null && TZ=America/Mexico_City date -d @$1 "+%a %d-%b %H:%M" || echo "?"; }
