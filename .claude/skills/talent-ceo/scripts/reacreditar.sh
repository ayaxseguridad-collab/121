#!/usr/bin/env bash
# reacreditar.sh — Re-acreditación de un actor persistente con un SELLO NUEVO en el bus (talent-ceo, ref 07).
#
# Tras un `/clear`, un reinicio de la sesión o una sesión nueva, un actor persistente queda
# NO ACREDITADO: el bus no distingue «el actor de antes» del actor que volvió sin su contexto, y un
# actor puede ESCRIBIR «SELLO …» en su pane sin ejecutar `bus-sellar.sh` (FAB-OBS-004/014). Acreditar es
# SELLAR en el bus un marcador cuyo nonce solo conoce quien acaba de pedirlo.
# Repo-agnóstico, token-only, sin MCP.
#
# Uso (se ejecuta COMO el usuario del actor: el estado vive en SU directorio de estado):
#   reacreditar.sh --rol <ROL> --iniciar     # ceba el cursor `acred-<ROL>` al final del bus, deja el
#                                            # estado NO_ACREDITADO y emite el comando de sellado
#   reacreditar.sh --rol <ROL> --verificar   # exige el sello ACRED-<ROL>-<nonce> en el tramo del bus
#                                            # POSTERIOR al cebado (sin reloj: orden de bytes, no de horas)
#   reacreditar.sh --help
#
# Entorno: TA_BUS (OBLIGATORIA) · XDG_RUNTIME_DIR (estado, como el resto del skill) · TA_PERFIL.
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0  --iniciar: cebado hecho y nonce emitido · --verificar: sello VÁLIDO (estado pasa a ACREDITADO)
#   1  --verificar: NO hay un sello válido posterior al cebado (otro rol, otro nonce, sello anterior,
#      o «SELLO …» escrito en una nota o en el pane no cuenta: solo la CABECERA del registro)
#   2  PRECONDICIÓN: --verificar sin --iniciar previo · rol fuera del charset, demasiado largo o ajeno
#      al perfil · sin perfil válido · TA_BUS ausente · el cebado/lectura del bus falló · estado inseguro
#
# ── QUÉ ESCRIBE (y solo eso) ────────────────────────────────────────────────────────────────────
# `--iniciar` y `--verificar` son los ÚNICOS que escriben, y solo bajo el directorio de estado
# (`$(bus_dir_estado)`): `acreditacion/<ROL>.estado` + `acreditacion/<ROL>.nonce` y, vía `bus-leer.sh`,
# el cursor propio `acred-<ROL>`. No sellan: el sello lo pone el actor con `bus-sellar.sh`, bajo su
# identidad verificada contra el perfil.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib-bus.sh"
# shellcheck source=/dev/null
. "$HERE/lib-perfil.sh"

_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }
die2() { printf 'reacreditar: PRECOND: %s\n' "$*" >&2; exit 2; }

rol=''; modo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --rol) _exige_valor $# "$1"; rol="${2-}"; shift 2 ;;
    --iniciar)
      [ -z "$modo" ] || die2 "--iniciar y --verificar son excluyentes"
      modo=iniciar; shift ;;
    --verificar)
      [ -z "$modo" ] || die2 "--iniciar y --verificar son excluyentes"
      modo=verificar; shift ;;
    --help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "reacreditar: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done
[ -n "$modo" ] || die2 "falta --iniciar o --verificar"
[ -n "$rol" ] || die2 "falta --rol"
# El lector del cebado se llama `acred-<ROL>` y su id debe caber en el charset de lectores (32): el
# rol admite, por tanto, 26 caracteres. Un rol más largo no se trunca ni se acepta: se rechaza.
printf '%s' "$rol" | grep -Eq '^[A-Za-z0-9_-]{1,26}$' || die2 "rol inválido (solo [A-Za-z0-9_-], 1..26): $(printf '%q' "$rol")"

perfil_path >/dev/null 2>&1 || die2 "sin perfil de instancia legible; no se acredita a un rol que el perfil no puede verificar"
en_perfil=0
for _t in torre estacion canal runner ceo pm; do
  perfil_row1 "$_t" "$rol" >/dev/null 2>&1 && { en_perfil=1; break; }
done
[ "$en_perfil" -eq 1 ] || die2 "el rol \"$rol\" no existe en el perfil como torre/estacion/canal/runner/ceo/pm"

bus="${TA_BUS-}"
[ -n "$bus" ] || die2 "TA_BUS no definida"
[ -f "$bus" ] && [ -r "$bus" ] || die2 "TA_BUS ausente o ilegible: $bus"

base="$(bus_dir_estado)"
adir="$base/acreditacion"
estado="$adir/$rol.estado"
nonce_f="$adir/$rol.nonce"
inicio_f="$adir/$rol.inicio"
lector="acred-$rol"
cdir="${TA_BUS_CURSOR_DIR:-$base/cursores}"

# Escritura ATÓMICA de un fichero de estado (mismo directorio → rename(2)); nombre impredecible.
escribe_estado() { # ruta contenido
  local t
  bus_asegura_regular "$1" || exit 2
  t="$(mktemp "$adir/.$rol.XXXXXX")" || die2 "no se pudo crear un temporal en $adir"
  printf '%s\n' "$2" > "$t" || { rm -f "$t"; die2 "no se pudo escribir el estado"; }
  mv -f "$t" "$1" || { rm -f "$t"; die2 "no se pudo mover el estado a su sitio"; }
}

case "$modo" in
  iniciar)
    bus_asegura_dir "$base" || exit 2
    bus_asegura_dir "$adir" || exit 2
    escribe_estado "$estado" "NO_ACREDITADO"
    # Cebado: leer TODO lo que hay (se descarta) deja el cursor `acred-<ROL>` al final del bus. Todo
    # lo que se selle a partir de aquí cae en el tramo POSTERIOR; lo anterior no puede acreditar.
    if ! bash "$HERE/bus-leer.sh" --lector "$lector" >/dev/null 2>&1; then
      die2 "no se pudo cebar el cursor $lector (¿bus rotado o cursor corrupto? ver bus-leer.sh)"
    fi
    pos=0
    [ ! -f "$cdir/$lector.cursor" ] || pos="$(cat "$cdir/$lector.cursor")" || die2 'cursor ilegible'
    id_bus="$(stat -c '%d:%i' "$bus")" || die2 'no se pudo observar el bus'
    # El bus vacío también deja un cebado explícito; nunca se infiere de un cursor perdido.
    escribe_estado "$cdir/$lector.cursor" "$pos"
    escribe_estado "$cdir/$lector.bus" "$id_bus"
    nonce="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{8}$' || die2 "no se pudo generar el nonce"
    escribe_estado "$nonce_f" "$nonce"
    escribe_estado "$inicio_f" "$pos|$id_bus"
    echo "reacreditar: $rol queda NO_ACREDITADO; cursor $lector cebado al final del bus"
    echo "reacreditar: marcador: ACRED-$rol-$nonce"
    echo "reacreditar: sella COMO $rol:  bash $HERE/bus-sellar.sh --rol $rol --marcador ACRED-$rol-$nonce --nota \"acreditado tras reinicio\""
    echo "reacreditar: y confirma con:   bash $HERE/reacreditar.sh --rol $rol --verificar"
    exit 0 ;;
  verificar)
    # Sin cebado previo no hay «posterior a qué»: precondición, no un 1.
    [ -f "$nonce_f" ] && [ ! -L "$nonce_f" ] || die2 "sin --iniciar previo para \"$rol\" (falta $nonce_f)"
    bus_asegura_dir "$adir" || exit 2
    nonce="$(head -n1 "$nonce_f" 2>/dev/null || true)"
    printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{8}$' || die2 "el nonce guardado no es válido: $nonce_f"
    for f in "$inicio_f" "$cdir/$lector.cursor" "$cdir/$lector.bus"; do
      if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -O "$f" ] || [ ! -r "$f" ]; then
        echo 'reacreditar: NO ACREDITADO: cebado perdido o inseguro' >&2; exit 1
      fi
    done
    inicio="$(cat "$inicio_f")" || exit 1
    [[ $inicio =~ ^(0|[1-9][0-9]{0,17})\|[0-9]+:[0-9]+$ ]] || exit 1
    pos="${inicio%%|*}"; id_bus="${inicio#*|}"
    [ "$(cat "$cdir/$lector.cursor")" = "$pos" ] &&
      [ "$(cat "$cdir/$lector.bus")" = "$id_bus" ] &&
      [ "$(stat -c '%d:%i' "$bus")" = "$id_bus" ] || { echo 'reacreditar: NO ACREDITADO: cebado divergente' >&2; exit 1; }
    # `--peek`: el tramo posterior al cebado, SIN mover el cursor (verificar es repetible).
    if ! tramo="$(bash "$HERE/bus-leer.sh" --lector "$lector" --peek 2>/dev/null)"; then
      die2 "no se pudo leer el tramo posterior al cebado (bus-leer.sh falló)"
    fi
    # Solo cuenta la CABECERA del registro: `<ts> [rol: ROL] [marcador: ACRED-ROL-nonce]`. El texto
    # de una nota que cite el marcador, o un «SELLO …» escrito en un pane, no la cumple.
    hallado=0
    cab_re='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) \[rol: ([A-Za-z0-9_-]+)\] \[marcador: ([^][]+)\]($| .*)'
    while IFS= read -r line; do
      [[ $line =~ $cab_re ]] || continue
      ts="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; m="${BASH_REMATCH[3]}"
      [ "$r" = "$rol" ] && [ "$m" = "ACRED-$rol-$nonce" ] || continue
      canon="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || continue
      [ "$canon" = "$ts" ] && hallado=$((hallado+1))
    done <<< "$tramo"
    if [ "$hallado" -ge 1 ]; then
      escribe_estado "$estado" "ACREDITADO"
      echo "reacreditar: $rol ACREDITADO (sello ACRED-$rol-$nonce posterior al cebado)"
      exit 0
    fi
    echo "reacreditar: NO ACREDITADO: no hay sello [rol: $rol] [marcador: ACRED-$rol-$nonce] posterior al cebado" >&2
    exit 1 ;;
esac
