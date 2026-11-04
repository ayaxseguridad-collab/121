#!/usr/bin/env bash
# lib.sh — utilidades compartidas. Se carga con `source`, no se ejecuta suelta.

set -uo pipefail

# ---------------------------------------------------------------- salida
_c() { [ -t 1 ] && printf '\033[%sm' "$1" || true; }
ok()    { _c '0;32'; printf '  OK   '; _c 0; printf '%s\n' "$*"; }
info()  { _c '0;36'; printf '  ..   '; _c 0; printf '%s\n' "$*"; }
warn()  { _c '0;33'; printf '  AVISO '; _c 0; printf '%s\n' "$*" >&2; }
fail()  { _c '0;31'; printf '  FALLO '; _c 0; printf '%s\n' "$*" >&2; }
omit()  { _c '0;90'; printf '  OMIT '; _c 0; printf '%s\n' "$*"; }
titulo(){ printf '\n'; _c '1'; printf '=== %s\n' "$*"; _c 0; }

# Muere explicando que hacer, no solo que fallo.
morir() {
  fail "$1"
  [ $# -gt 1 ] && { printf '\n'; shift; printf '  %s\n' "$@"; printf '\n'; }
  exit 1
}

# ---------------------------------------------------------------- dry-run
# DRY_RUN=1 hace que ejec() imprima en vez de ejecutar. Todo cambio de estado
# del sistema DEBE pasar por ejec() o por escribir(), o --dry-run miente.
: "${DRY_RUN:=0}"
ejec() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ejec CRITICO: si el comando falla, se para aqui. Es el que se usa para todo lo que,
# si no ocurre, deja el montaje roto (instalar paquetes, habilitar servicios, copiar
# ficheros). Sin esto un `apt-get` fallido se traga el error y el instalador acaba
# anunciando exito sobre una maquina a medias — que es peor que fallar.
ejecc() {
  ejec "$@" || morir "Ha fallado un paso imprescindible:  $*" \
    "El montaje se detiene aqui a proposito, para no dejarte una instalacion a medias" \
    "que parezca correcta. Corrige la causa y vuelve a lanzarlo: es reentrante."
}

# Escribe un fichero con permisos explicitos. En dry-run enseña destino y modo.
escribir() {
  local destino="$1" modo="${2:-0644}"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] escribiria %s (modo %s)\n' "$destino" "$modo"
    cat >/dev/null
    return 0
  fi
  install -D -m "$modo" /dev/null "$destino"
  cat >"$destino"
}

# ---------------------------------------------------------------- privilegios
exigir_root() {
  # En dry-run no se toca nada, asi que exigir administrador solo estorbaria: el
  # sentido de --dry-run es poder mirar ANTES de dar permisos.
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ "$(id -u)" -eq 0 ] || morir "Esta fase necesita privilegios de administrador." \
    "Vuelve a lanzarlo con:  sudo bash $0 $*"
}

# ---------------------------------------------------------------- confirmacion
# Devuelve 0 si el usuario acepta. Con LL_ASUMIR_SI=1 no pregunta (desatendido).
confirmar() {
  local pregunta="$1"
  [ "${LL_ASUMIR_SI:-0}" = "1" ] && { info "$pregunta -> si (desatendido)"; return 0; }
  [ -t 0 ] || { warn "$pregunta -> no hay terminal interactiva; asumo NO"; return 1; }
  local r
  read -r -p "  $pregunta [s/N] " r
  case "$r" in [sS]|[sS][iI]|[yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- idempotencia
# Inserta un bloque delimitado en un fichero, o lo reemplaza si ya estaba.
# Es lo que permite correr montar.sh dos veces sin duplicar nada.
MARCA_INI="# >>> talent-llm-local >>>"
MARCA_FIN="# <<< talent-llm-local <<<"

bloque_poner() {
  local fichero="$1" contenido="$2" modo="${3:-0644}"
  local tmp; tmp="$(mktemp)"
  if [ -f "$fichero" ]; then
    awk -v ini="$MARCA_INI" -v fin="$MARCA_FIN" '
      $0 == ini {dentro=1; next}
      $0 == fin {dentro=0; next}
      !dentro {print}
    ' "$fichero" >"$tmp"
  fi
  { printf '%s\n%s\n%s\n' "$MARCA_INI" "$contenido" "$MARCA_FIN"; } >>"$tmp"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] actualizaria el bloque de %s\n' "$fichero"
    rm -f "$tmp"; return 0
  fi
  install -D -m "$modo" "$tmp" "$fichero"
  rm -f "$tmp"
}

bloque_quitar() {
  local fichero="$1"
  [ -f "$fichero" ] || return 0
  grep -qF "$MARCA_INI" "$fichero" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v ini="$MARCA_INI" -v fin="$MARCA_FIN" '
    $0 == ini {dentro=1; next}
    $0 == fin {dentro=0; next}
    !dentro {print}
  ' "$fichero" >"$tmp"
  ejec install -m "$(stat -c %a "$fichero")" "$tmp" "$fichero"
  rm -f "$tmp"
}

# ---------------------------------------------------------------- claves
# Clave aleatoria por usuario. Nunca valores fijos: una clave predecible degrada
# la atribucion por usuario del medidor aunque todo escuche en loopback.
clave_nueva() {
  local prefijo="$1"
  printf '%s-%s' "$prefijo" "$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
}

# ---------------------------------------------------------------- claves en curl
# La clave NUNCA por argv: los argumentos de un proceso los lee cualquier usuario
# con `ps`, y eso es justo lo que la atribucion por usuario intenta evitar (ver
# gotcha 1). curl --config lee la cabecera de un fichero, que aqui sale en modo
# 0600. Uso:  cfg="$(conf_clave "$clave")"; curl --config "$cfg" ...; rm -f "$cfg"
conf_clave() {
  local clave="$1" f
  f="$(mktemp)"
  chmod 600 "$f"
  printf 'header = "Authorization: Bearer %s"\n' "$clave" >"$f"
  printf '%s' "$f"
}

# ---------------------------------------------------------------- red
esperar_http() {
  local url="$1" segundos="${2:-180}" i=0
  while [ "$i" -lt "$segundos" ]; do
    curl -sf -o /dev/null --max-time 3 "$url" && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- misc
tiene() { command -v "$1" >/dev/null 2>&1; }

# Compara dos versiones tipo "12.0" >= "10.0" sin depender de bc.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}
