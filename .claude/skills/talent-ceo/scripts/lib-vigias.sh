#!/usr/bin/env bash
# lib-vigias.sh — Piezas comunes de los vigías del mando (talent-ceo, ref 08).
#
# Se "source-ea" (`. lib-vigias.sh`); no actúa por sí solo. Repo-agnóstico, token-only, sin MCP.
#
# ── EL CONTRATO DE UN VIGÍA: «UNA LÍNEA = UN EVENTO ACCIONABLE» ─────────────────────────────────
# Un vigía es UN tick: una pasada que emite 0..n líneas y sale con rc 0. El bucle vive solo en
# `vigias.sh`. Cada línea es un evento que alguien tiene que atender:
#     <CLASE> <detalle> <HH:MM:SSZ>
# UNA sola línea, UTF-8 válido, sin caracteres de control, de 220 bytes como máximo, con la hora
# MEDIDA por `date -u` (nunca reconstruida). Lo que no se puede medir NO se calla: sale una línea
# `<CLASE>-NO-MEDIDO` (una vez por transición), porque un monitor sin eventos no puede ser
# indistinguible de uno sano.
#
# ── POR CURSOR, NO POR COLA EN VIVO ─────────────────────────────────────────────────────────────
# Un vigía que sigue un fichero en vivo (`tail -F -n0`) no reproduce lo escrito mientras él estaba
# caducado: lo que se escribe en el hueco no se entrega nunca. Aquí el vigía del bus lleva su propio
# cursor de bytes y lo escrito durante el hueco sale en el primer tick que vuelve.
#
# ── POR TRANSICIÓN, NO POR NIVEL ────────────────────────────────────────────────────────────────
# La transición la decide `vigia-cuota.sh` (no se reimplementa). Sin estado previo se parte de
# «bajo»: un recurso que ya está en rojo avisa en el primer tick. La línea que imprime
# `vigia-cuota.sh` se descarta y se emite la propia del vigía.
#
# Herramientas: bash, coreutils (`date`, `df`, `du`, `stat`, `tac`, `head`, `tr`, `cksum`), `grep`,
# `sed`, `iconv` (libc) y `ps`; dobles por PATH en las pruebas. Ningún filtro que bufferice la
# entrada: un monitor mudo por bufferizar es justo el defecto que esto cierra.
set -uo pipefail
export LC_ALL=C
VIG_AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$VIG_AQUI/lib-bus.sh"
# shellcheck source=/dev/null
. "$VIG_AQUI/lib-perfil.sh"

VIG_MAX_LINEA=220
VIG_DIR=''
VIG_PEND=()
VIG_CENT=0
VIG_NUCLEOS=0
VIG_CARGA_C=0
# Comando remoto: constante POSIX, sin datos del perfil dentro. Imprime «<núcleos> <carga a 5 min>».
VIG_REMOTO='n=$(grep -c ^processor /proc/cpuinfo); read -r a b c < /proc/loadavg; echo "$n $b"'

# Un `shift 2` con la opcion como ULTIMO argumento no desplaza nada (rc != 0) y, sin `set -e`, el
# bucle vuelve a leer el mismo `$1`: BUCLE INFINITO. Se exige el valor ANTES de desplazar.
_exige_valor(){ [ "$1" -ge 2 ] || { printf '%s: PRECOND: %s exige un valor\n' "${0##*/}" "$2" >&2; exit 2; }; }
vig_precond() { printf '%s: PRECOND: %s\n' "${0##*/}" "$1" >&2; exit 2; }

# Entero de hasta 18 dígitos: cabe siempre en los 64 bits de bash (la misma guarda que vigia-cuota).
vig_ent_acotado() { case "${1-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 18 ]; }

vig_hora() {
  local h
  h="$(date -u +%H:%M:%SZ 2>/dev/null)" || return 1
  case "$h" in [0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z) printf '%s' "$h" ;; *) return 1 ;; esac
}

vig_epoch() {
  local e
  e="$(date -u +%s 2>/dev/null)" || return 1
  vig_ent_acotado "$e" || return 1
  printf '%s' "$e"
}

# Texto libre -> UNA línea limpia: NUL, C0 y DEL -> espacio; C1, separadores de línea/párrafo y
# controles de dirección -> espacio; los espacios se colapsan. Los bytes que no son UTF-8 se quitan en
# `vig_evento`, DESPUÉS de recortar: es el único sitio donde cortar por bytes puede partir un carácter.
vig_limpia() {
  printf '%s' "${1-}" | tr '\000-\037\177' ' ' \
    | sed -E 's/\xc2[\x80-\x9f]/ /g; s/\xe2\x80[\xa8-\xae]/ /g; s/\xe2\x81[\xa6-\xa9]/ /g; s/\xef\xbb\xbf/ /g; s/ +/ /g; s/^ //; s/ $//'
}

# vig_evento <CLASE> <detalle>: emite UNA línea. La hora se mide AQUÍ y va al final; se recorta el
# cuerpo (no la hora) para que el total quepa en VIG_MAX_LINEA bytes. rc 2 si no se pudo emitir.
vig_evento() {
  local clase="${1-}" det="${2-}" h cuerpo
  h="$(vig_hora)" || { printf '%s: no se pudo medir la hora; un evento sin hora no se emite\n' "${0##*/}" >&2; return 2; }
  cuerpo="$(vig_limpia "$clase $det")"
  cuerpo="$(printf '%s' "$cuerpo" | head -c $((VIG_MAX_LINEA - 10)) | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
  cuerpo="${cuerpo%"${cuerpo##*[![:space:]]}"}"
  printf '%s %s\n' "$cuerpo" "$h" || return 2
}

# Directorio de estado de los vigías: 0700, bajo el de la fábrica (fuera de /tmp). Fija VIG_DIR.
vig_estado_dir() {
  local base
  base="$(bus_dir_estado)"
  bus_asegura_dir "$base" || return 2
  VIG_DIR="$base/vigias"
  bus_asegura_dir "$VIG_DIR" || return 2
}

vig_hash() { local s; s="$(printf '%s' "${1-}" | cksum)"; printf '%s' "${s%% *}"; }

# ── LA TRANSICIÓN SE DECIDE, SE EMITE Y SOLO ENTONCES SE CONFIRMA ───────────────────────────────
# `vigia-cuota.sh` persiste el estado nada más decidir, y no se toca. Para que un TERM entre la
# decisión y la emisión no borre el aviso, el detector corre sobre una COPIA del estado (la
# «sombra»): decide con su lógica de siempre, pero lo que persiste es la copia. El estado real solo
# se sustituye (`mv`, rename atómico) cuando el evento ya salió. Decidir, emitir y confirmar van bajo
# un candado propio por clave, que este proceso retiene hasta confirmar o descartar: dos ticks de la
# misma clave no pueden decidir la misma transición a la vez.
# Si el proceso muere antes de confirmar, el estado real no cambió y el tick siguiente repite el
# aviso: se prefiere repetir a perder, igual que el cursor del bus. Las sombras huérfanas las barre
# el siguiente ciclo de la misma clave. Límite declarado: el candado lo heredan los hijos que el
# proceso lance DURANTE el ciclo (`date`, el detector); si uno sobrevive a su padre, retiene el
# candado hasta terminar y el tick siguiente espera hasta 10 s.

vig_ciclo_ini() { VIG_PEND=(); }

# vig_decide <clave> <valor> <umbral>
# rc 0 = sin transición · 10 = sube (bajo->alto) · 11 = baja (alto->bajo) · 2 = error.
# Deja la sombra pendiente (VIG_PEND) hasta `vig_confirma` o `vig_descarta`. Sin estado previo se
# siembra «bajo».
vig_decide() {
  local clave="${1-}" valor="${2-}" umbral="${3-}" f lock sombra out rc fd
  printf '%s' "$clave" | grep -Eq '^[A-Za-z0-9._-]{1,120}$' || { echo "${0##*/}: clave de estado inválida" >&2; return 2; }
  [ -n "$VIG_DIR" ] || { echo "${0##*/}: falta el directorio de estado" >&2; return 2; }
  f="$VIG_DIR/$clave.estado"; lock="$VIG_DIR/$clave.ciclo"
  bus_asegura_regular "$f" || return 2
  bus_asegura_regular "$lock" || return 2
  exec {fd}>>"$lock" || { echo "${0##*/}: no se pudo abrir el candado $lock" >&2; return 2; }
  if ! flock -x -w "${TA_VIG_ESPERA:-10}" "$fd"; then
    echo "${0##*/}: PRECOND: candado de ciclo no adquirible: $lock" >&2
    exec {fd}>&-; return 2
  fi
  rm -f -- "$VIG_DIR/.sh@$clave@"* "$VIG_DIR/..sh@$clave@"*
  # noclobber = creación exclusiva (O_EXCL): no sigue un symlink precreado.
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then ( set -C; printf 'bajo' > "$f" ) 2>/dev/null || true; fi
  if ! sombra="$(mktemp "$VIG_DIR/.sh@$clave@XXXXXX")"; then
    echo "${0##*/}: no se pudo crear la sombra del estado" >&2; exec {fd}>&-; return 2
  fi
  VIG_PEND+=("$sombra" "$f" "$fd")
  [ -f "$f" ] && [ ! -L "$f" ] && cat -- "$f" > "$sombra" || return 2
  out="$(bash "$VIG_AQUI/vigia-cuota.sh" --valor "$valor" --umbral "$umbral" --estado "$sombra")"; rc=$?
  case "$rc" in
    0) return 0 ;;
    10) case "$out" in
          *'bajo->alto'*) return 10 ;;
          *'alto->bajo'*) return 11 ;;
        esac
        return 2 ;;
    *) return 2 ;;
  esac
}

# vig_confirma: el evento ya salió; las sombras pasan a ser el estado real y se sueltan los candados.
vig_confirma() {
  local i fd rc=0
  for ((i = 0; i < ${#VIG_PEND[@]}; i += 3)); do
    mv -f -- "${VIG_PEND[i]}" "${VIG_PEND[i+1]}" || rc=2
    rm -f -- "${VIG_PEND[i]}.lock"
    fd="${VIG_PEND[i+2]}"; exec {fd}>&-
  done
  VIG_PEND=()
  return "$rc"
}

# vig_descarta: la emisión falló o el ciclo no es válido; el estado real queda como estaba.
vig_descarta() {
  local i fd
  for ((i = 0; i < ${#VIG_PEND[@]}; i += 3)); do
    rm -f -- "${VIG_PEND[i]}" "${VIG_PEND[i]}.lock"
    fd="${VIG_PEND[i+2]}"; exec {fd}>&-
  done
  VIG_PEND=()
  return 0
}

# vig_avisa_sube <clave> <valor> <umbral> <CLASE> <detalle>: emite solo si la clave SUBE.
# rc 0 = nada que decir o emitido · 2 = fallo (de estado o de emisión).
vig_avisa_sube() {
  local rc
  vig_ciclo_ini
  vig_decide "$1" "$2" "$3"; rc=$?
  case "$rc" in
    0|11) vig_confirma; return $? ;;
    10) if vig_evento "$4" "$5"; then vig_confirma; return $?; fi
        vig_descarta; return 2 ;;
    *) vig_descarta; return 2 ;;
  esac
}

# vig_sinaviso <clave> <valor> <umbral>: actualiza el estado sin emitir nada (re-armar en silencio).
vig_sinaviso() {
  local rc
  vig_ciclo_ini
  vig_decide "$1" "$2" "$3"; rc=$?
  case "$rc" in
    0|10|11) vig_confirma; return $? ;;
    *) vig_descarta; return 2 ;;
  esac
}

# «No medido»: una vez por transición medido -> no medido; volver a medir re-arma en silencio.
vig_no_medido() { vig_avisa_sube "nm-$1" 1 1 "$2" "$3"; }
vig_medido() { vig_sinaviso "nm-$1" 0 1; }

# Decimal «0.3», «0,3», «2» -> centésimas enteras en VIG_CENT (aritmética entera, la coma vale igual).
vig_centesimas() {
  local s="${1-}" ent frac=''
  printf '%s' "$s" | grep -Eq '^[0-9]{1,9}([.,][0-9]{1,6})?$' || return 1
  ent="${s%%[.,]*}"
  case "$s" in *[.,]*) frac="${s#*[.,]}" ;; esac
  frac="${frac}00"; frac="${frac:0:2}"
  VIG_CENT=$(( 10#$ent * 100 + 10#$frac ))
}

vig_formato_cent() { printf '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 )); }

# vig_carga_maquina <destino|-local>: núcleos y carga a 5 min en VIG_NUCLEOS / VIG_CARGA_C
# (centésimas). Local por /proc; remota por `ssh -- <destino>`. rc 1 = no se pudo medir.
vig_carga_maquina() {
  local dest="${1-}" d out n l
  if [ "$dest" = '-local' ]; then
    d="${TA_PROC_DIR:-/proc}"
    n="$(grep -c '^processor' "$d/cpuinfo" 2>/dev/null)" || return 1
    { read -r _ l _ < "$d/loadavg"; } 2>/dev/null || return 1
  else
    out="$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=6 -- "$dest" "$VIG_REMOTO" 2>/dev/null)" || return 1
    out="${out##*$'\n'}"
    n="${out%% *}"; l="${out#* }"
  fi
  vig_ent_acotado "$n" && [ "$n" -ge 1 ] || return 1
  vig_centesimas "$l" || return 1
  VIG_NUCLEOS="$n"; VIG_CARGA_C="$VIG_CENT"
}

# Carpeta con tope: «RUTA» o «RUTA=GB» (el último «=» separa). Ruta absoluta, sin controles.
# Fija VIG_RUTA y VIG_TOPE (vacío si no hay tope). rc 1 = mal formada.
vig_valida_carpeta() {
  local s="${1-}"
  VIG_RUTA="$s"; VIG_TOPE=''
  case "$s" in *=*) VIG_RUTA="${s%=*}"; VIG_TOPE="${s##*=}" ;; esac
  [[ "$VIG_RUTA" == /* ]] || return 1
  [[ "$VIG_RUTA" != *[[:cntrl:]]* ]] || return 1
  [ -z "$VIG_TOPE" ] || { vig_ent_acotado "$VIG_TOPE" && [ "${#VIG_TOPE}" -le 9 ]; }
}
