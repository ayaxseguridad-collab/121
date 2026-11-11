#!/usr/bin/env bash
# node-al-dia.sh — sube Node al parche MÁS RECIENTE de su misma mayor en el host, la golden, los canales y el runner.
#
#   bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --plan
#   sudo bash "$PKG/skills/talent-channels/scripts/node-al-dia.sh" --ejecutar "$CODIGO"
#
# --plan: solo lectura. Mide cada sujeto (versión de apt, node -v, suelo de assets/node-suelos.tsv y parche más
#   reciente que ofrece NodeSource en la caché de apt), dice qué se subiría y qué se saltaría y por qué, y termina con
#   CONFIRMACION=<código>. El código sale del ESTADO medido (sujetos, energía, versiones, candidato, acción y la huella
#   del fichero de suelos); si no hay nada que subir no hay código.
# --ejecutar <código>: con root. Recalcula el estado; si el código no casa, rc 2 sin escribir nada. Sube cada sujeto con
#   `apt-get install --only-upgrade nodejs=<versión exacta>` desde el repositorio de NodeSource YA configurado y
#   autenticado por apt (llavero legible, sin marca de no verificado, `apt-get update` sin avisos de firma). Nunca ejecuta
#   el script de instalación de NodeSource. Después comprueba el suelo, fail-closed.
#
# Reglas:
#   - La mayor la fija lo instalado; nunca se cambia de mayor ni se baja. El suelo sale SOLO de assets/node-suelos.tsv.
#   - Un canal con tmux, claude o codex vivos, o con un proceso trabajando dentro del motor, se SALTA y se nombra
#     (detección compartida: scripts/lib-sesiones.sh del paquete). Ninguna sesión se para. El host no pasa por esa guarda:
#     el operador corre dentro de una sesión; dpkg reemplaza el binario por renombrado y los procesos vivos conservan el anterior.
#   - Un contenedor parado se arranca solo para operar y se devuelve a parado al terminar (también ante un fallo).
#   - Una mayor sin suelo (la de apt de Ubuntu) no se toca: se salta con el remedio. Los pozos de cuentas no están cubiertos.
#   - El paquete anterior no se borra: queda lo que conserve apt y se declara.
#
#   - La identidad de la instancia (golden, máquina, canales, usuario) sale de instalacion/estado/contexto.conf del paquete y
#     del fichero de respuestas que cita, no del entorno (sudo lo limpia). Sin ese fichero, el entorno con los TRES
#     GOLDEN=golden-<proyecto>, MACHINE_NUM y CUSER (sudo env GOLDEN=… MACHINE_NUM=… CUSER=… bash …); si falta algo, rc 2.
#     La golden y el runner de la instancia son sujetos esperados: si no existen, rc 1 (nunca se omiten en silencio).
#   - apt-get update se limita al fichero de fuentes de NodeSource (Dir::Etc::sourcelist, sin purgar listas ajenas): el
#     aviso o el fallo de un repositorio ajeno no impide subir Node.
# rc: 0 todo al día · 1 fallo duro (suelos ilegibles, no se pudo enumerar, golden o runner ausentes, fuente sin firma, suelo
#     no alcanzable, fallo de apt) · 2 uso, código ausente o que no casa, sin root o sin identidad de la instancia (siempre
#     sin escrituras) · 3 se saltó algún sujeto (se nombra cuál).
# Sourceable para las pruebas con NAD_NO_MAIN=1. Ganchos de pruebas (sudo los descarta): NAD_PATH fija el PATH y
# NAD_RAIZ la raíz del sistema de ficheros donde se comprueba la fuente de NodeSource (por defecto «/»).
# shellcheck shell=bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="${NAD_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"; export PATH
# Identidad EXPLÍCITA pedida por el entorno (alternativa a la de la instancia), capturada ANTES de cargar 00-config.sh,
# que rellena defaults (golden, vivecoder) y los haría pasar por explícitos. Raíz del paquete: la de lib-sesiones.sh.
NAD_X_GOLDEN="${GOLDEN-}"; NAD_X_MACHINE="${MACHINE_NUM-}"; NAD_X_CUSER="${CUSER-}"
NAD_PKG="$HERE/../../.."
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"
NAD_LIB_SESIONES="$HERE/../../../scripts/lib-sesiones.sh"
[ -r "$NAD_LIB_SESIONES" ] || { echo "ERROR: falta scripts/lib-sesiones.sh del paquete (detección de sesiones vivas)." >&2; exit 1; }
# shellcheck source=/dev/null
. "$NAD_LIB_SESIONES"

NAD_TSV="$HERE/../assets/node-suelos.tsv"
NAD_CACHE_AVISO_S=86400   # edad de la caché de apt a partir de la cual el plan avisa
NAD_APT_ESPERA_S=300      # espera del bloqueo de dpkg
NAD_TOPE_S=1800           # tope por orden de apt
NAD_RE_VER='^([0-9]+)\.([0-9]+)\.([0-9]+)([+~-].*)?$'

declare -A NAD_SUELO=() NAD_ENE=() NAD_INST=() NAD_APTV=() NAD_MAY=() NAD_CAND=() NAD_CANDPLAN=() NAD_ACC=() NAD_MOT=()
NAD_SUJ=()
NAD_ARR=()
NAD_MSG=''; NAD_HUELLA=''; NAD_VIVAS=''; NAD_GMOT=''; NAD_FOUT=''

# Texto que corre DENTRO del sujeto (o en el host) para comprobar de forma estática que la fuente de NodeSource está
# autenticada. Recibe como $1 la raíz del sistema de ficheros ("/" en la ejecución real). Imprime una línea MAL por defecto.
# shellcheck disable=SC2016  # el guion viaja en comillas simples A PROPÓSITO (se expande en el sujeto)
NAD_FIRMA_TXT='# NAD_FIRMA
root="$1"; [ "$root" = / ] && root=""
hallado=0; mal=0
u=""; s=""; t=""
evalua() {
  case "$u" in *deb.nodesource.com*) ;; *) return 0 ;; esac
  hallado=1
  if [ -z "$s" ] || [ ! -s "$root$s" ]; then mal=1; echo "MAL llavero ausente o vacío (Signed-By) en $f"; fi
  if [ -n "$t" ]; then mal=1; echo "MAL fuente marcada como no verificada en $f"; fi
  return 0
}
for f in "$root/etc/apt/sources.list" "$root"/etc/apt/sources.list.d/*; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sources)
      u=""; s=""; t=""
      while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
          "") evalua; u=""; s=""; t="" ;;
          URIs:*|uris:*) u="$l" ;;
          Signed-By:*|signed-by:*) s="${l#*:}"; s="${s# }"; s="${s%% *}" ;;
          Trusted:*|trusted:*|Allow-Insecure:*|allow-insecure:*) case "$l" in *[Yy][Ee][Ss]*|*[Tt]rue*) t=1 ;; esac ;;
        esac
      done < "$f"
      evalua ;;
    *)
      while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in ""|"#"*) continue ;; esac
        case "$l" in *deb.nodesource.com*) ;; *) continue ;; esac
        hallado=1
        s=""; case "$l" in *signed-by=*) s="${l#*signed-by=}"; s="${s%%]*}"; s="${s%% *}" ;; esac
        if [ -z "$s" ] || [ ! -s "$root$s" ]; then mal=1; echo "MAL llavero ausente o vacío (signed-by) en $f"; fi
        case "$l" in *[Tt]rusted=yes*|*allow-insecure=yes*) mal=1; echo "MAL fuente marcada como no verificada en $f" ;; esac
      done < "$f" ;;
  esac
done
[ "$hallado" = 1 ] || { echo "MAL ninguna fuente de NodeSource configurada"; mal=1; }
[ "$mal" = 0 ]'

# Texto que corre en el sujeto: lista los ficheros de fuentes de apt que declaran NodeSource, para limitar `apt-get update`
# a ellos (el aviso de firma de un repositorio AJENO no es de NodeSource). $1 = raíz del sistema de ficheros ("/" real).
# Imprime «F <ruta>» por cada *.list o *.sources de sources.list.d y «M» si solo sources.list lo menciona (no se aísla).
# shellcheck disable=SC2016  # el guion viaja en comillas simples A PROPÓSITO (se expande en el sujeto)
NAD_FUENTE_TXT='# NAD_FUENTE
root="$1"; [ "$root" = / ] && root=""
for f in "$root"/etc/apt/sources.list.d/*.list "$root"/etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  if grep -qF deb.nodesource.com "$f"; then printf "F %s\n" "${f#"$root"}"; fi
done
if grep -qF deb.nodesource.com "$root/etc/apt/sources.list" 2>/dev/null; then printf "M\n"; fi
exit 0'

nad_uso() {
  printf 'uso: node-al-dia.sh --plan | node-al-dia.sh --ejecutar <código>   (el código sale de --plan)\n' >&2
  exit 2
}
nad_fin() { local rc="$1"; shift; printf '%s\n' "$*" >&2; exit "$rc"; }

# ── Identidad de la instancia ─────────────────────────────────────────────────────────────────────────────────────────
# La 2.0 escribe instalacion/estado/contexto.conf (respuestas=<ruta>) y, en el fichero de respuestas, proyecto,
# maquina_n, canales_n y cuser: de ahí salen GOLDEN=golden-<proyecto>, MACHINE_NUM, COUNT y CUSER, los mismos que
# fabrica closed_env de fases.py. `sudo` limpia el entorno: nada de esto puede depender de él. Alternativa explícita
# (sin contexto.conf): GOLDEN, MACHINE_NUM y CUSER los tres en el entorno, validados. Nunca se asume un default.
declare -A NAD_PAR=()
nad_pares() { # fichero → NAD_PAR (clave=valor, sin shell ni expansión); rc 1 con NAD_MSG si ilegible o malformado
  local f="$1" l k v
  NAD_PAR=()
  if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then NAD_MSG="ausente, ilegible o enlace simbólico: $f"; return 1; fi
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|'#'*) continue ;; esac
    if [[ ! $l =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then NAD_MSG="línea inválida en $f"; return 1; fi
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    if [ -n "${NAD_PAR[$k]+x}" ]; then NAD_MSG="clave repetida ($k) en $f"; return 1; fi
    case "$v" in *'$'*|*'`'*|*'\'*) NAD_MSG="valor no literal ($k) en $f"; return 1 ;; esac
    NAD_PAR[$k]="$v"
  done < "$f"
  return 0
}
nad_valida() { # clave valor → rc 0 si cumple el contrato del cuestionario
  case "$1" in
    GOLDEN) [[ $2 =~ ^golden-[a-z][a-z0-9-]{0,15}$ ]] ;;   # el cuestionario pide 2 a 16; aquí basta con un nombre seguro
    MACHINE_NUM) [[ $2 =~ ^[0-9]$ ]] ;;
    COUNT) [[ $2 =~ ^[1-9]$ ]] ;;
    CUSER) [[ $2 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ;;
    *) return 1 ;;
  esac
}
nad_identidad() { # fija GOLDEN, MACHINE_NUM, COUNT y CUSER o termina con rc 2 sin escribir nada
  local ctx="$NAD_PKG/instalacion/estado/contexto.conf" resp proyecto g m n u falta=() choque=() k
  if [ -e "$ctx" ] || [ -L "$ctx" ]; then
    nad_pares "$ctx" || nad_fin 2 "ERROR: identidad de la instancia ilegible: $NAD_MSG. No se ha escrito nada."
    resp="${NAD_PAR[respuestas]-}"
    if [[ ! $resp =~ ^/[A-Za-z0-9_./-]+$ || "/$resp/" == */../* ]]; then
      nad_fin 2 "ERROR: $ctx no trae una ruta de respuestas válida (respuestas=). No se ha escrito nada."
    fi
    nad_pares "$resp" || nad_fin 2 "ERROR: respuestas de la instancia ilegibles: $NAD_MSG. No se ha escrito nada."
    proyecto="${NAD_PAR[proyecto]-}"; m="${NAD_PAR[maquina_n]-}"; n="${NAD_PAR[canales_n]-}"; u="${NAD_PAR[cuser]-}"
    g="golden-$proyecto"
    [[ $proyecto =~ ^[a-z][a-z0-9-]{0,15}$ ]] || falta+=(proyecto)
    nad_valida MACHINE_NUM "$m" || falta+=(maquina_n)
    nad_valida COUNT "$n" || falta+=(canales_n)
    nad_valida CUSER "$u" || falta+=(cuser)
    [ "${#falta[@]}" -eq 0 ] || nad_fin 2 "ERROR: faltan o son inválidas en $resp: ${falta[*]}. No se ha escrito nada."
    [ -z "$NAD_X_GOLDEN" ] || [ "$NAD_X_GOLDEN" = "$g" ] || choque+=("GOLDEN=$NAD_X_GOLDEN (la instancia dice $g)")
    [ -z "$NAD_X_MACHINE" ] || [ "$NAD_X_MACHINE" = "$m" ] || choque+=("MACHINE_NUM=$NAD_X_MACHINE (la instancia dice $m)")
    [ -z "$NAD_X_CUSER" ] || [ "$NAD_X_CUSER" = "$u" ] || choque+=("CUSER=$NAD_X_CUSER (la instancia dice $u)")
    [ "${#choque[@]}" -eq 0 ] || nad_fin 2 "ERROR: identidad en conflicto entre el entorno y la instancia: ${choque[*]}. No se ha escrito nada."
    GOLDEN="$g"; MACHINE_NUM="$m"; COUNT="$n"; CUSER="$u"
  else
    [ -n "$NAD_X_GOLDEN" ] || falta+=(GOLDEN)
    [ -n "$NAD_X_MACHINE" ] || falta+=(MACHINE_NUM)
    [ -n "$NAD_X_CUSER" ] || falta+=(CUSER)
    if [ "${#falta[@]}" -gt 0 ]; then
      nad_fin 2 "ERROR: falta la identidad de la instancia: no existe $ctx y faltan en el entorno: ${falta[*]}. Corre desde el paquete de una instancia 2.0, o da los tres: sudo env GOLDEN=golden-<proyecto> MACHINE_NUM=<n> CUSER=<usuario> bash node-al-dia.sh … . No se ha escrito nada."
    fi
    for k in GOLDEN MACHINE_NUM CUSER; do
      case "$k" in GOLDEN) g="$NAD_X_GOLDEN" ;; MACHINE_NUM) g="$NAD_X_MACHINE" ;; CUSER) g="$NAD_X_CUSER" ;; esac
      nad_valida "$k" "$g" || choque+=("$k=$g")
    done
    [ "${#choque[@]}" -eq 0 ] || nad_fin 2 "ERROR: identidad explícita inválida: ${choque[*]} (GOLDEN=golden-<proyecto>, MACHINE_NUM un dígito, CUSER un usuario de Linux). No se ha escrito nada."
    GOLDEN="$NAD_X_GOLDEN"; MACHINE_NUM="$NAD_X_MACHINE"; CUSER="$NAD_X_CUSER"
  fi
  export GOLDEN MACHINE_NUM CUSER
}

# ── Suelos: UN solo sitio, assets/node-suelos.tsv, con las mismas exigencias que el doctor ────────────────────────────
nad_cargar_suelos() { # rc 0 con NAD_SUELO[mayor]=X.Y.Z · rc 1 con NAD_MSG
  local f="$NAD_TSV" m v x
  NAD_SUELO=()
  if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then NAD_MSG='node-suelos.tsv ausente, ilegible o enlace simbólico'; return 1; fi
  while IFS=$'\t' read -r m v x || [ -n "$m" ]; do
    case "$m" in ''|'#'*) continue ;; esac
    if [[ ! $m =~ ^[0-9]{1,6}$ || ! $v =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || [ "${v%%.*}" != "$m" ] ||
       [ -n "$x" ] || [ -n "${NAD_SUELO[$m]+x}" ]; then
      NAD_MSG='node-suelos.tsv con fila inválida o mayor repetida'; return 1
    fi
    NAD_SUELO[$m]="$v"
  done < "$f"
  [ "${#NAD_SUELO[@]}" -gt 0 ] || { NAD_MSG='node-suelos.tsv sin ningún suelo'; return 1; }
  NAD_HUELLA="$(sha256sum < "$f")"; NAD_HUELLA="${NAD_HUELLA%% *}"
  return 0
}
nad_suelo_de() { # mayor → suelo X.Y.Z o vacío
  printf '%s' "${NAD_SUELO[$1]-}"
}
nad_ge() { # a b (X.Y.Z, misma mayor) → rc 0 si a >= b; comparación numérica en base 10, como la golden y el doctor
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"; IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$((10#$a1))" -gt "$((10#$b1))" ] && return 0
  [ "$((10#$a1))" -lt "$((10#$b1))" ] && return 1
  [ "$((10#$a2))" -gt "$((10#$b2))" ] && return 0
  [ "$((10#$a2))" -lt "$((10#$b2))" ] && return 1
  [ "$((10#$a3))" -ge "$((10#$b3))" ]
}
nad_gt() { ! nad_ge "$2" "$1"; } # a > b
nad_triple() { # versión de apt → X.Y.Z
  [[ $1 =~ $NAD_RE_VER ]] || return 1
  printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}
nad_suelo_ok() { # salida de node -v → rc 0 si es X.Y.Z puro y cumple el suelo de su mayor
  local v="${1#v}" f
  v="${v//[[:space:]]/}"
  [[ $v =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  f="$(nad_suelo_de "${BASH_REMATCH[1]}")"
  [ -n "$f" ] || return 1
  nad_ge "$v" "$f"
}

# ── Lecturas (solo lectura) ───────────────────────────────────────────────────────────────────────────────────────────
nad_run() { # sujeto orden… → en el host directo; en un contenedor con incus exec
  local s="$1"; shift
  if [ "$s" = host ]; then "$@" </dev/null; else incus exec "$s" -- "$@" </dev/null; fi
}
nad_node_v() { # node -v tal como lo mide el doctor del CEO
  if [ "$1" = host ]; then node -v 2>/dev/null </dev/null; else incus exec "$1" -- su - "$CUSER" -c 'node -v' 2>/dev/null </dev/null; fi
}
nad_energia() { # rellena NAD_ENE desde incus list
  local out n e
  out="$(incus list -f csv -c ns 2>/dev/null)" || return 1
  NAD_ENE=()
  while IFS=, read -r n e _; do
    [ -n "$n" ] || continue
    NAD_ENE[$n]="$e"
  done <<< "$out"
  return 0
}
nad_version_de_status() { # stdin: /var/lib/dpkg/status → versión de nodejs instalado
  # Lee SIEMPRE hasta el final de stdin: si saliera al hallar nodejs, `incus file pull` (que sigue escribiendo) moriría por
  # SIGPIPE y, con pipefail, el rc 141 de la tubería borraría la versión («Node no instalado por apt», falso).
  local l pk="" st="" v="" hallada=""
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      'Package: '*) pk="${l#Package: }"; st=""; v="" ;;
      'Status: '*) st="${l#Status: }" ;;
      'Version: '*) v="${l#Version: }" ;;
      '')
        if [ -z "$hallada" ] && [ "$pk" = nodejs ] && [ "$st" = 'install ok installed' ] && [ -n "$v" ]; then hallada="$v"; fi
        pk=""; st=""; v="" ;;
    esac
  done
  if [ -z "$hallada" ] && [ "$pk" = nodejs ] && [ "$st" = 'install ok installed' ] && [ -n "$v" ]; then hallada="$v"; fi
  [ -n "$hallada" ] || return 1
  printf '%s' "$hallada"
}
nad_candidato() { # sujeto mayor → versión de apt MÁS RECIENTE de esa mayor ofrecida por NodeSource (vacío si ninguna)
  local s="$1" m="$2" out line v url best="" bu="" cu re_url
  re_url="^[[:space:]]*https://deb\.nodesource\.com/node_${m}\.x([[:space:]]|\$)"
  out="$(nad_run "$s" apt-cache madison nodejs 2>/dev/null)" || return 0
  while IFS= read -r line; do
    IFS='|' read -r _ v url <<< "$line"
    v="${v//[[:space:]]/}"
    [[ $url =~ $re_url ]] || continue
    cu="$(nad_triple "$v")" || continue
    [ "${cu%%.*}" = "$m" ] || continue
    if [ -z "$best" ] || nad_gt "$cu" "$bu"; then best="$v"; bu="$cu"; fi
  done <<< "$out"
  printf '%s' "$best"
  return 0
}
nad_decidir() { # s → fija NAD_ACC y NAD_MOT a partir de lo instalado, el candidato y el suelo
  local s="$1" i="${NAD_INST[$1]}" f cu
  f="$(nad_suelo_de "${NAD_MAY[$s]}")"; cu="$(nad_triple "${NAD_CAND[$s]}")"
  NAD_MOT[$s]=-
  if nad_gt "$cu" "$i"; then
    if nad_ge "$cu" "$f"; then NAD_ACC[$s]=subir
    else NAD_ACC[$s]=suelo-inalcanzable; NAD_MOT[$s]="NodeSource solo ofrece $cu, por debajo del suelo $f"; fi
  else
    if nad_ge "$i" "$f"; then NAD_ACC[$s]=al-dia
    else NAD_ACC[$s]=suelo-inalcanzable; NAD_MOT[$s]="instalado $i por debajo del suelo $f y NodeSource no ofrece uno mayor"; fi
  fi
  return 0
}
nad_clasificar() { # sujeto versión-de-apt modo(vivo|parado)
  local s="$1" ver="$2" modo="$3" nv up may cand
  if [ -z "$ver" ]; then NAD_MOT[$s]='Node no instalado por apt: SIN MEDIR'; return 0; fi
  if [[ ! $ver =~ $NAD_RE_VER ]]; then NAD_MOT[$s]="versión de apt no interpretable: $ver"; return 0; fi
  up="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"; may="${BASH_REMATCH[1]}"
  NAD_INST[$s]="$up"; NAD_APTV[$s]="$ver"; NAD_MAY[$s]="$may"
  if [ -z "$(nad_suelo_de "$may")" ]; then
    NAD_MOT[$s]="mayor $may sin suelo conocido: no se cambia de mayor; instala Node con el procedimiento de NodeSource de EMPIEZA-AQUI.md"
    return 0
  fi
  if [ "$modo" = vivo ]; then
    nv="$(nad_node_v "$s")"; nv="${nv//[[:space:]]/}"; nv="${nv#v}"
    if [ "$nv" != "$up" ]; then NAD_MOT[$s]="Node no gestionado por apt (node -v: ${nv:-nada}; apt: $up)"; return 0; fi
    cand="$(nad_candidato "$s" "$may")"
    if [ -z "$cand" ]; then NAD_MOT[$s]="SIN MEDIR: sin repositorio NodeSource de la mayor $may"; return 0; fi
    NAD_CAND[$s]="$cand"; nad_decidir "$s"
  else
    NAD_ACC[$s]=parado
  fi
  return 0
}
nad_medir_vivo() { # s (RUNNING o host) → mide de nuevo
  local s="$1" ver
  NAD_INST[$s]=-; NAD_APTV[$s]=-; NAD_MAY[$s]=-; NAD_CAND[$s]=-; NAD_ACC[$s]=saltar; NAD_MOT[$s]=-
  ver="$(nad_run "$s" dpkg-query -W -f='${Version}' nodejs 2>/dev/null)" || ver=""
  nad_clasificar "$s" "$ver" vivo
}
nad_medir_todo() {
  local s r t chs ver best bu cu
  nad_energia || nad_fin 1 'ERROR: no se pudo enumerar los contenedores (incus list).'
  chs="$(tc_list_real_channels)" || nad_fin 1 'ERROR: no se pudo enumerar los canales de esta máquina.'
  NAD_SUJ=()
  # La golden y el runner de la instancia son sujetos ESPERADOS: si no existen se para, nunca se omiten en silencio.
  if [ -n "${NAD_ENE[$GOLDEN]-}" ]; then NAD_SUJ+=("$GOLDEN")
  else nad_fin 1 "ERROR: la golden esperada $GOLDEN no existe en esta máquina (incus list); no se sube nada. Comprueba la identidad de la instancia."; fi
  while IFS= read -r s; do
    if [ -n "$s" ]; then NAD_SUJ+=("$s"); fi
  done <<< "$(printf '%s\n' "$chs" | LC_ALL=C sort)"
  r="runner-${GOLDEN#golden-}"
  if [ -n "${NAD_ENE[$r]-}" ]; then NAD_SUJ+=("$r")
  else nad_fin 1 "ERROR: el runner esperado $r no existe en esta máquina (incus list); no se sube nada. Comprueba la identidad de la instancia."; fi
  NAD_SUJ+=(host); NAD_ENE[host]=RUNNING
  for s in "${NAD_SUJ[@]}"; do
    NAD_INST[$s]=-; NAD_APTV[$s]=-; NAD_MAY[$s]=-; NAD_CAND[$s]=-; NAD_ACC[$s]=saltar; NAD_MOT[$s]=-
    case "${NAD_ENE[$s]}" in
      RUNNING)
        ver="$(nad_run "$s" dpkg-query -W -f='${Version}' nodejs 2>/dev/null)" || ver=""
        nad_clasificar "$s" "$ver" vivo ;;
      STOPPED)
        ver="$(incus file pull "$s/var/lib/dpkg/status" - 2>/dev/null | nad_version_de_status)" || ver=""
        nad_clasificar "$s" "$ver" parado ;;
      *) NAD_MOT[$s]="estado ${NAD_ENE[$s]} no esperado" ;;
    esac
  done
  # Segunda pasada: un contenedor parado toma el candidato de un sujeto vivo de su misma mayor; sin ninguno, se mide al arrancarlo.
  for s in "${NAD_SUJ[@]}"; do
    [ "${NAD_ACC[$s]}" = parado ] || continue
    best=""; bu=""
    for t in "${NAD_SUJ[@]}"; do
      [ "${NAD_ENE[$t]}" = RUNNING ] && [ "${NAD_MAY[$t]}" = "${NAD_MAY[$s]}" ] && [ "${NAD_CAND[$t]}" != - ] || continue
      cu="$(nad_triple "${NAD_CAND[$t]}")"
      if [ -z "$best" ] || nad_gt "$cu" "$bu"; then best="${NAD_CAND[$t]}"; bu="$cu"; fi
    done
    if [ -n "$best" ]; then
      NAD_CAND[$s]="$best"; nad_decidir "$s"
    else
      NAD_ACC[$s]=medir-al-ejecutar; NAD_MOT[$s]='parado: se mide al arrancarlo'
    fi
  done
  return 0
}
nad_pendiente() { # s → rc 0 si la acción pide escribir algo
  case "${NAD_ACC[$1]}" in subir|medir-al-ejecutar|suelo-inalcanzable) return 0 ;; esac
  return 1
}
nad_codigo() { # código derivado del ESTADO medido
  local s lineas=() texto
  for s in "${NAD_SUJ[@]}"; do
    lineas+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$s" "${NAD_ENE[$s]}" "${NAD_INST[$s]}" "${NAD_MAY[$s]}" "${NAD_CAND[$s]}" "${NAD_ACC[$s]}" "${NAD_MOT[$s]}")")
  done
  texto="node-al-dia-v1"$'\n'"$GOLDEN"$'\n'"$NAD_HUELLA"$'\n'"$(printf '%s\n' "${lineas[@]}" | LC_ALL=C sort)"$'\n'
  printf '%s' "$texto" | sha256sum | cut -c1-12
}

# ── Guarda de sesiones vivas (compartida con la resiembra) ────────────────────────────────────────────────────────────
nad_viva() { # contenedor → 0 sin sesiones · 1 con sesiones (NAD_VIVAS) · 2 no medible
  local out rc
  out="$(sesiones_vivas_en "$1" "/home/$CUSER/motor-paquete")"; rc=$?
  NAD_VIVAS="$(printf '%s' "$out" | tr '\n' ' ')"
  case "$rc" in 0) return 0 ;; 20) return 1 ;; *) return 2 ;; esac
}
nad_guarda() { # contenedor → rc 0 libre · rc 1 saltar (NAD_GMOT)
  nad_viva "$1"
  case $? in
    0) return 0 ;;
    1) NAD_GMOT="sesión viva: $NAD_VIVAS"; return 1 ;;
    *) NAD_GMOT='guarda de sesiones no medible'; return 1 ;;
  esac
}

# ── Plan ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
nad_plan() {
  local s m ahora marca edad pend=0 esperado extra vivas
  printf 'Node al día. Plan de solo lectura: no se instala, no se arranca ni se modifica nada.\n'
  printf 'Suelos (node-suelos.tsv, huella %s):' "${NAD_HUELLA:0:12}"
  for m in $(printf '%s\n' "${!NAD_SUELO[@]}" | LC_ALL=C sort); do printf ' %s=%s' "$m" "${NAD_SUELO[$m]}"; done
  printf '\n'
  printf '%-18s %-8s %-10s %-6s %-12s %-12s %s\n' SUJETO ENERGIA INSTALADO MAYOR MAS-RECIENTE ACCION NOTA
  ahora="$(date +%s)"
  for s in "${NAD_SUJ[@]}"; do
    extra="${NAD_MOT[$s]}"; [ "$extra" != - ] || extra=''
    if [ "${NAD_ENE[$s]}" = RUNNING ] && [ "$s" != host ] && { [ "${NAD_ACC[$s]}" = subir ] || [ "${NAD_ACC[$s]}" = suelo-inalcanzable ]; }; then
      if ! nad_guarda "$s"; then extra="$extra (${NAD_GMOT} → se SALTARÍA)"; fi
    fi
    printf '%-18s %-8s %-10s %-6s %-12s %-12s %s\n' "$s" "${NAD_ENE[$s]}" "${NAD_INST[$s]}" "${NAD_MAY[$s]}" \
      "$(nad_triple "${NAD_CAND[$s]}" 2>/dev/null || printf -- '-')" "${NAD_ACC[$s]}" "$extra"
    if [ "${NAD_ENE[$s]}" = RUNNING ]; then
      marca="$(nad_run "$s" stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null)" || marca=""
      if [[ $marca =~ ^[0-9]+$ ]] && [ "$((ahora - marca))" -gt "$NAD_CACHE_AVISO_S" ]; then
        edad=$(((ahora - marca) / 3600))
        printf '  AVISO: la caché de apt de %s tiene %s h; el candidato puede estar atrasado (la ejecución refresca la lista antes de decidir).\n' "$s" "$edad"
      fi
    fi
    if nad_pendiente "$s"; then pend=$((pend + 1)); fi
  done
  vivas="$(sesiones_vivas /proc 2>/dev/null | tr '\n' ' ')"
  [ -z "$vivas" ] || printf 'Sesiones vivas del host (informativo, no lo bloquean): %s\n' "$vivas"
  printf 'Pozos de cuentas: NO cubiertos por esta operación.\n'
  printf 'Paquete anterior: no se borra; se declarará por sujeto al terminar. Ninguna sesión se para.\n'
  if [ "$pend" -eq 0 ]; then
    printf 'Nada que subir: todo lo medido está al día en el parche más reciente de su mayor.\n'
    return 0
  fi
  esperado="$(nad_codigo)"
  printf 'CONFIRMACION=%s\n' "$esperado"
  return 0
}

# ── Ejecución ─────────────────────────────────────────────────────────────────────────────────────────────────────────
nad_apt() { # sujeto argumentos-de-apt-get…
  local s="$1"; shift
  nad_run "$s" timeout "$NAD_TOPE_S" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get "$@"
}
nad_firma() { # sujeto → rc 0 si la fuente de NodeSource está autenticada (comprobación estática); salida en NAD_FOUT
  NAD_FOUT="$(nad_run "$1" bash -c "$NAD_FIRMA_TXT" _ "${NAD_RAIZ:-/}")"
}
NAD_FUENTES=()
nad_fuentes() { # sujeto → NAD_FUENTES (ficheros de fuentes de NodeSource en el sujeto); rc 1 si no se localiza ninguna
  local out l p mixta=0
  NAD_FUENTES=()
  out="$(nad_run "$1" bash -c "$NAD_FUENTE_TXT" _ "${NAD_RAIZ:-/}")" || return 1
  while IFS= read -r l; do
    case "$l" in
      'F /'*)
        p="${l#F }"
        [[ $p =~ ^/etc/apt/sources\.list\.d/[A-Za-z0-9._+-]+$ ]] || return 1
        NAD_FUENTES+=("$p") ;;
      M) mixta=1 ;;
    esac
  done <<< "$out"
  [ "${#NAD_FUENTES[@]}" -gt 0 ] || [ "$mixta" = 1 ]
}
nad_update_ok() { # salida rc → rc 0 si apt-get update terminó sin avisos de firma
  [ "$2" -eq 0 ] || return 1
  case "$1" in *NO_PUBKEY*|*EXPKEYSIG*|*'is not signed'*|*'not been authenticated'*) return 1 ;; esac
  # Sin grep -q: saldría al primer acierto y printf moriría por SIGPIPE (rc 141 con pipefail) en una salida grande.
  [ -z "$(printf '%s\n' "$1" | grep -iE '^(W|E):.*nodesource')" ] || return 1
  return 0
}
nad_salta() { # sujeto motivo
  NAD_ACC[$1]=saltar; NAD_MOT[$1]="$2"
}
nad_salir() { # devuelve a parado lo que ESTE script arrancó
  local c
  for c in "${NAD_ARR[@]}"; do incus stop "$c" >/dev/null 2>&1; done
  return 0
}
nad_resumen() {
  local s ns=0 nl=0 na=0 rc=0
  for s in "${NAD_SUJ[@]}"; do
    case "${NAD_ACC[$s]}" in
      saltar) printf 'saltado: %s: %s\n' "$s" "${NAD_MOT[$s]}"; nl=$((nl + 1)) ;;
      al-dia) printf 'al día: %s\n' "$s"; na=$((na + 1)) ;;
      subido) ns=$((ns + 1)) ;;
    esac
  done
  printf 'NODE: %s subidos, %s saltados, %s al día\n' "$ns" "$nl" "$na"
  [ "$nl" -eq 0 ] || rc=3
  return "$rc"
}
nad_ejecutar() { # código
  local codigo="$1" esperado s pend=() subir=() out urc v vieja nuevo nv f
  for s in "${NAD_SUJ[@]}"; do
    if nad_pendiente "$s"; then pend+=("$s"); fi
  done
  if [ "${#pend[@]}" -eq 0 ]; then
    printf 'Nada que subir: todo lo medido está al día en el parche más reciente de su mayor.\n'
    nad_resumen; return $?
  fi
  esperado="$(nad_codigo)"
  [ "$codigo" = "$esperado" ] || nad_fin 2 'ERROR: el código no casa con el estado vuelto a medir (plan distinto o sin confirmar); repite --plan. No se ha escrito nada.'
  trap nad_salir EXIT
  # FASE A: guarda, fuente autenticada, lista refrescada y decisión, sujeto por sujeto. Aquí no se instala nada.
  for s in "${pend[@]}"; do
    if [ "${NAD_ENE[$s]}" = STOPPED ]; then
      if ! incus start "$s" >/dev/null 2>&1; then nad_salta "$s" 'no se pudo arrancar'; continue; fi
      NAD_ARR+=("$s")
      if ! tc_wait_container "$s"; then nad_salta "$s" 'no terminó de arrancar'; continue; fi
    fi
    if [ "$s" != host ]; then
      if ! nad_guarda "$s"; then nad_salta "$s" "$NAD_GMOT"; continue; fi
    fi
    if ! nad_firma "$s"; then nad_fin 1 "ERROR: la fuente de NodeSource de $s no está autenticada; no se instala nada en ningún sujeto. ${NAD_FOUT}"; fi
    nad_fuentes "$s" || nad_fin 1 "ERROR: no se pudo localizar la fuente de NodeSource de $s; no se instala nada."
    if [ "${#NAD_FUENTES[@]}" -eq 0 ]; then
      # NodeSource solo en /etc/apt/sources.list, mezclada con otras: no se puede aislar, se refresca todo como antes.
      out="$(nad_apt "$s" update -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o "DPkg::Lock::Timeout=$NAD_APT_ESPERA_S" 2>&1)"; urc=$?
      nad_update_ok "$out" "$urc" || nad_fin 1 "ERROR: apt-get update de $s falló o avisó de firma (rc $urc); no se instala nada. ${out}"
    fi
    # Solo la fuente de NodeSource: el aviso de firma o el fallo de un repositorio ajeno no secuestra el parche de Node, y
    # el aviso que se vigila es el de la fuente que se usa. List-Cleanup=0: no se purgan las listas de las demás fuentes.
    for f in "${NAD_FUENTES[@]}"; do
      out="$(nad_apt "$s" update -o "Dir::Etc::sourcelist=$f" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o "DPkg::Lock::Timeout=$NAD_APT_ESPERA_S" 2>&1)"; urc=$?
      nad_update_ok "$out" "$urc" || nad_fin 1 "ERROR: apt-get update de la fuente de NodeSource de $s ($f) falló o avisó de firma (rc $urc); no se instala nada. ${out}"
    done
    NAD_CANDPLAN[$s]="${NAD_CAND[$s]}"
    nad_medir_vivo "$s"
    case "${NAD_ACC[$s]}" in
      subir) subir+=("$s") ;;
      suelo-inalcanzable) nad_fin 1 "ERROR: $s: ${NAD_MOT[$s]}; no se instala nada." ;;
    esac
  done
  # FASE B: instalación, solo de lo decidido en la fase A.
  for s in "${subir[@]}"; do
    if [ "$s" != host ]; then
      if ! nad_guarda "$s"; then nad_salta "$s" "$NAD_GMOT"; continue; fi
    fi
    v="${NAD_CAND[$s]}"; vieja="${NAD_APTV[$s]}"
    out="$(nad_apt "$s" install --only-upgrade -y "nodejs=$v" -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o "DPkg::Lock::Timeout=$NAD_APT_ESPERA_S" 2>&1)" ||
      nad_fin 1 "ERROR: apt-get install de $s falló; ya subidos: ${NAD_SUBIDOS:-ninguno}. ${out}"
    nuevo="$(nad_run "$s" dpkg-query -W -f='${Version}' nodejs 2>/dev/null)" || nuevo=""
    [ "$nuevo" = "$v" ] || nad_fin 1 "ERROR: $s quedó en '${nuevo:-nada}' y se pidió $v; ya subidos: ${NAD_SUBIDOS:-ninguno}."
    nv="$(nad_node_v "$s")"
    nad_suelo_ok "$nv" || nad_fin 1 "ERROR: $s: tras instalar, node -v da '${nv:-nada}', por debajo del suelo; ya subidos: ${NAD_SUBIDOS:-ninguno}."
    NAD_SUBIDOS="${NAD_SUBIDOS:+$NAD_SUBIDOS }$s"
    printf 'subido: %s %s -> %s (suelo %s)' "$s" "$vieja" "$nuevo" "$(nad_suelo_de "${NAD_MAY[$s]}")"
    if [ "${NAD_CANDPLAN[$s]}" != "$v" ]; then printf ' [plan: %s; instalado: %s]' "${NAD_CANDPLAN[$s]}" "$v"; fi
    printf '\n'
    nad_anterior "$s" "$vieja"
    NAD_ACC[$s]=subido
  done
  printf 'Los procesos de Node ya arrancados siguen con el binario anterior hasta que se reinicien; no se ha reiniciado nada.\n'
  nad_resumen
  return $?
}
nad_anterior() { # sujeto versión-vieja
  local hay=no
  if [ -n "$(nad_run "$1" find /var/cache/apt/archives -maxdepth 1 -name "nodejs_${2}_*.deb" -print -quit 2>/dev/null)" ]; then hay=sí; fi
  printf '  paquete anterior: nodejs %s; no se borra nada; su .deb sigue en /var/cache/apt/archives: %s; volver atrás: apt-get install nodejs=%s (si el repositorio aún la ofrece)\n' "$2" "$hay" "$2"
}
NAD_SUBIDOS=''

nad_main() {
  local modo="${1:-}" codigo="${2:-}"
  case "$modo" in
    --plan) [ "$#" -eq 1 ] || nad_uso ;;
    --ejecutar) [ "$#" -eq 2 ] || nad_uso ;;
    *) nad_uso ;;
  esac
  if [ "$modo" = --ejecutar ]; then
    [[ $codigo =~ ^[0-9a-f]{12}$ ]] || nad_fin 2 'ERROR: el código de confirmación falta o no tiene el formato de --plan (12 caracteres hexadecimales). No se ha escrito nada.'
    [ "$(id -u)" -eq 0 ] || nad_fin 2 'ERROR: --ejecutar necesita root (sudo). No se ha escrito nada.'
  fi
  nad_identidad
  nad_cargar_suelos || nad_fin 1 "ERROR: $NAD_MSG ($NAD_TSV). No se sube nada."
  nad_medir_todo
  if [ "$modo" = --plan ]; then nad_plan; return $?; fi
  nad_ejecutar "$codigo"
}

[ "${NAD_NO_MAIN:-0}" = 1 ] || { nad_main "$@"; exit $?; }
