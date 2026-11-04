#!/usr/bin/env bash
# lib-bus.sh — Helpers del BUS de la fábrica: identidad, candados, cursores (talent-ceo, ref 02).
#
# Se "source-ea" (`. lib-bus.sh`); no actúa por sí solo. Repo-agnóstico, token-only, sin MCP.
#
# El bus es un fichero append-only donde las estaciones sellan marcadores y los lectores avanzan un
# cursor PROPIO. Este fichero concentra lo que los dos ejecutables (bus-sellar.sh, bus-leer.sh)
# necesitan para no repetir —ni divergir en— las guardas de seguridad.
#
# ── MODELO DE AMENAZA, DECLARADO (no se promete de más) ────────────────────────────────────────
# Frente a un proceso del MISMO UID con permiso de escritura NO hay garantía criptográfica posible.
# El contrato se limita, literalmente, a: "no seguimos symlinks preexistentes y fallamos si el
# destino no es un fichero regular". Una carrera entre nuestra comprobación y nuestra escritura,
# ganada por un proceso del mismo UID, queda FUERA del claim. Se dice aquí para que nadie lea en
# estas guardas una promesa que no hacen.
#
# ── rc EXACTOS de los helpers ──────────────────────────────────────────────────────────────────
#   0 = OK · 2 = PRECONDICIÓN violada (fail-closed, nunca se escribe nada)
set -uo pipefail

BUS_ID_CHARSET='^[A-Za-z0-9_-]{1,32}$'

bus_die2() { printf 'bus: PRECOND: %s\n' "$*" >&2; return 2; }

# ── bus_dir_estado ─────────────────────────────────────────────────────────────────────────────
# Directorio propio para locks y cursores. FUERA de /tmp: /tmp es mundo-escribible y compartido,
# y un lock ahí es un punto de precreación para cualquier proceso de la máquina.
bus_dir_estado() {
  printf '%s\n' "${TA_BUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/talent-ceo}"
}

# ── bus_valida_id <ID> ─────────────────────────────────────────────────────────────────────────
# El ID de lector se usa para construir rutas => es superficie de traversal. Charset CERRADO: se
# acepta una lista blanca, no se rechaza una lista negra (una negra siempre olvida un caso).
# Un ID fuera del charset es PRECONDICIÓN (rc 2), no un error de escritura a medias.
bus_valida_id() {
  local id="${1-}"
  [ -n "$id" ] || { bus_die2 "id de lector vacío"; return 2; }
  if ! printf '%s' "$id" | grep -Eq "$BUS_ID_CHARSET"; then
    bus_die2 "id de lector inválido: solo [A-Za-z0-9_-], 1..32 (recibido: $(printf '%q' "$id"))"
    return 2
  fi
  return 0
}

# ── bus_asegura_dir <dir> ──────────────────────────────────────────────────────────────────────
# Crea el directorio de estado si falta, y si ya existe EXIGE que sea seguro:
#   -L ANTES que -d: un symlink a un directorio satisface `-d`, así que preguntar primero por
#   directorio deja pasar exactamente el ataque que se quiere impedir.
bus_asegura_dir() {
  local d="${1-}" modo
  [ -n "$d" ] || { bus_die2 "directorio de estado vacío"; return 2; }
  if [ -L "$d" ]; then bus_die2 "el directorio de estado es un symlink: $d"; return 2; fi
  if [ -e "$d" ]; then
    [ -d "$d" ] || { bus_die2 "el directorio de estado existe y no es directorio: $d"; return 2; }
    [ -O "$d" ] || { bus_die2 "el directorio de estado no pertenece al UID actual: $d"; return 2; }
    modo="$(stat -c '%a' "$d" 2>/dev/null)"
    [ "$modo" = "700" ] || { bus_die2 "el directorio de estado tiene modo $modo, se exige 700: $d"; return 2; }
  else
    mkdir -p -m 700 "$d" || { bus_die2 "no se pudo crear el directorio de estado: $d"; return 2; }
  fi
  return 0
}

# ── bus_asegura_regular <ruta> ─────────────────────────────────────────────────────────────────
# Para cursores y locks: si YA existe, tiene que ser un fichero regular y NO un symlink.
# Otra vez -L antes que -f, y por el mismo motivo.
bus_asegura_regular() {
  local f="${1-}"
  [ -n "$f" ] || { bus_die2 "ruta vacía"; return 2; }
  if [ -L "$f" ]; then bus_die2 "precreado como symlink: $f"; return 2; fi
  if [ -e "$f" ] && [ ! -f "$f" ]; then bus_die2 "precreado y no es fichero regular: $f"; return 2; fi
  return 0
}

# ── bus_contenido_en <ruta> <dir> ──────────────────────────────────────────────────────────────
# Verifica que la ruta resuelta cae DENTRO del directorio. Cinturón sobre el charset: si algún día
# el charset se relajara, esto sigue impidiendo el traversal.
bus_contenido_en() {
  local ruta="${1-}" dir="${2-}" rd dd
  dd="$(cd "$dir" 2>/dev/null && pwd -P)" || { bus_die2 "directorio irresoluble: $dir"; return 2; }
  rd="$(cd "$(dirname "$ruta")" 2>/dev/null && pwd -P)" || { bus_die2 "ruta irresoluble: $ruta"; return 2; }
  case "$rd" in
    "$dd") return 0 ;;
    *) bus_die2 "ruta fuera del directorio de estado: $ruta"; return 2 ;;
  esac
}

# ── bus_es_el_bus <src> <bus> ──────────────────────────────────────────────────────────────────
# IDENTIDAD, no comparación textual: `-ef` compara dispositivo+inodo, así que caza la ruta
# relativa, el `..`, el symlink Y el hardlink. Comparar cadenas dejaría pasar los cuatro.
# rc 0 = SON el mismo fichero (=> el llamador debe abortar) · rc 1 = son distintos.
bus_es_el_bus() {
  local src="${1-}" bus="${2-}"
  [ -e "$src" ] && [ -e "$bus" ] || return 1
  [ "$src" -ef "$bus" ]
}

# ── bus_ruta <var-entorno> <defecto> ───────────────────────────────────────────────────────────
bus_ruta() { local v="${1-}"; local d="${2-}"; printf '%s\n' "${!v:-$d}"; }
