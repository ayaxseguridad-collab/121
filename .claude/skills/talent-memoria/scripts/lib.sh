#!/usr/bin/env bash
# lib.sh — utilidades compartidas del skill talent-memoria. Se sourcea.
# Contrato: NADA de aqui escribe fuera de los destinos que el llamador pasa.
# Colacion determinista tambien para quien sourcea lib.sh sin 00-config.sh
# (los manifiestos deben ordenar IGUAL en cualquier maquina y locale).
export LC_ALL=C

tm_say()  { printf '\n==== %s ====\n' "$*"; }
tm_ok()   { printf '  OK    %s\n' "$*"; }
tm_fail() { printf '  FALLO %s\n' "$*"; TM_FALLOS=$((TM_FALLOS+1)); }
tm_omit() { printf '  OMIT  %s\n' "$*"; }
tm_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
TM_FALLOS=0

# sha256 portable: GNU (sha256sum) o BSD/macOS (shasum -a 256)
tm_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Manifiesto de un directorio: "hash  ./ruta" por fichero, orden estable,
# rutas con espacios soportadas (-print0). Salida a stdout.
tm_manifest() {
  local dir="$1"
  # defensa en profundidad (item 6): los llamadores YA comprueban symlinks antes
  # de invocar esto, pero find -type f no los inventaria de todos modos — un
  # retarget entre esa comprobacion y esta lectura seria invisible sin este guard.
  tm_no_symlinks "$dir"
  # ./.git excluido: los metadatos de repositorio no son memoria. La exclusion es
  # SIMETRICA con el staging de salvaguarda.sh — si solo un lado lo excluyera, el
  # mundo cerrado cantaria los objetos de git como deltas fantasma.
  ( cd "$dir" && find . -path './.git' -prune -o -type f -print0 | sort -z | \
    while IFS= read -r -d '' f; do tm_sha "$f"; done )
}

# ¿El corpus <dir> tiene baseline git INEQUIVOCO? (criterios duros de references/03 §3)
# stdout: "git-valido" o "snapshot-obligatorio: <motivo>". Nunca modifica nada.
tm_git_baseline() {
  local dir="$1" f
  # defensa en profundidad (item 6): un symlink en <dir> podria retargetearse sin
  # dejar delta en find -type f, invisible tanto para esta funcion como para el
  # baseline git que informa.
  tm_no_symlinks "$dir"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'snapshot-obligatorio: fuera de un worktree git\n'; return 0; }
  git -C "$dir" rev-parse HEAD >/dev/null 2>&1 \
    || { printf 'snapshot-obligatorio: repo sin HEAD (sin commits)\n'; return 0; }
  while IFS= read -r -d '' f; do
    git -C "$dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 \
      || { printf 'snapshot-obligatorio: fichero sin rastrear: %s\n' "$f"; return 0; }
  # './.git' ADEMAS de './.git/*': en un WORKTREE .git es un FICHERO (gitdir: de
  # ~80 B), no un directorio — sin esta exclusion el censo lo captura, ls-files lo
  # marca sin rastrear y el baseline git-valido se vuelve inalcanzable en worktrees.
  done < <(cd "$dir" && find . -type f -not -path './.git/*' -not -path './.git' -print0)
  [ -z "$(git -C "$dir" status --porcelain -- . 2>/dev/null)" ] \
    || { printf 'snapshot-obligatorio: cambios sin commitear en el corpus\n'; return 0; }
  printf 'git-valido\n'
}

# Linea donde empieza el CUERPO de una nota (tras el frontmatter); 1 si no hay.
tm_body_start() {
  if [ "$(head -1 "$1" 2>/dev/null)" = "---" ]; then
    local fin; fin="$(awk 'NR>1 && /^---$/{print NR; exit}' "$1")"
    [ -n "$fin" ] && { printf '%s\n' "$((fin+1))"; return 0; }
  fi
  printf '1\n'
}

# Primera linea del CUERPO que matchea <regex ERE>; vacio si no hay.
# (El description del frontmatter NO cuenta: S3 y el marcador corporal son
# checks SEPARADOS — un estado solo-en-description es una nota disfrazada.)
tm_body_first_match() { # <fichero> <regex>
  local ini; ini="$(tm_body_start "$1")"
  awk -v ini="$ini" -v re="$2" 'NR>=ini && $0 ~ re {print NR; exit}' "$1"
}

# Fail-closed ante symlinks: el manifiesto (find -type f) no los inventaria, asi
# que un symlink podria cambiar de destino sin dejar delta. No se soportan.
tm_no_symlinks() { # <dir> ; exit 2 si hay alguno
  local l
  # .git excluido en coherencia con tm_manifest: sus internals quedan fuera del
  # inventario, asi que un symlink alli no puede afectar a la memoria vigilada.
  # awk NR<=5 en vez de head -5: head sale al 5o y el find aun escribiendo recibe
  # SIGPIPE (141) — bajo pipefail+set -e del llamador eso mata la funcion en un
  # corpus con muchos symlinks. awk lee TODO el input: mismo resultado, sin señal.
  l="$(find "$1" -path "${1%/}/.git" -prune -o -type l -print | awk 'NR<=5')"
  [ -z "$l" ] || tm_die "symlinks no soportados (fail-closed) en $1: $(printf '%s' "$l" | tr '\n' ' ')"
}

# ¿Tiene <fichero> alguna fecha detectable? (frontmatter, cuerpo o nombre) rc 0/1
# Rangos validos Y delimitada contra digito adyacente (TM_RE_FECHA_ISO/COMPACTA,
# 00-config.sh): el patron viejo aceptaba "2026-00-39" y colaba "2026-12-310"
# como subcadena valida — una nota fechada con basura contaba como FECHADA.
tm_tiene_fecha() {
  grep -qE "$TM_RE_FECHA_ISO|$TM_RE_FECHA_COMPACTA" "$1" 2>/dev/null \
    || basename "$1" | grep -qE "$TM_RE_FECHA_ISO|$TM_RE_FECHA_COMPACTA"
}

# Contenido EFECTIVO del description: DEL FRONTMATTER — el primer trozo no
# vacio: o bien el valor en la MISMA linea que "description:", o (si esa linea
# esta vacia o es solo un indicador de bloque YAML >/|) la primera linea de
# continuacion indentada no vacia. Los indices y previews solo enseñan esta
# linea, asi que es el UNICO sitio donde el estado cuenta como marca (S3).
tm_s3_desc() { # <fichero> → stdout: el trozo efectivo (1 linea), vacio si no hay
  awk '
    NR==1 { if ($0 != "---") exit 1; next }
    /^---$/ { exit }
    /^description:/ {
      d=1; val=$0
      sub(/^description:[[:space:]]*/, "", val)
      if (val ~ /^[|>][-+]?[[:space:]]*$/) val=""
      if (val != "") { print val; found=1; exit }
      next
    }
    d && !found && /^[[:space:]]*$/ { next }
    d && !found && /^[[:space:]]/ {
      val=$0; sub(/^[[:space:]]+/, "", val)
      if (val != "") { print val; found=1; exit }
      next
    }
    d && !found { exit }
  ' "$1" 2>/dev/null
  return 0
}

# Token de estado SOLO si ABRE el contenido efectivo (tolera comillas/espacios
# y un '[' de apertura antes del token) — un estado mencionado de pasada
# ("...la anterior quedo ANULADA en mayo") NO cuenta: el description sigue
# vendiendo la nota como vigente en indices y previews. Sin \b (no portable en
# BSD/macOS): el limite se comprueba a mano con "no-letra o fin de linea".
tm_s3_estado() { # <fichero> → stdout: el token de estado, vacio si no abre
  printf '%s' "$(tm_s3_desc "$1")" \
    | grep -oE "^[\"'[:space:]]*\\[?[[:space:]]*($TM_ESTADOS)([^A-Za-z]|\$)" \
    | grep -oE "$TM_ESTADOS" | sed -n 1p
  return 0
}

# ¿El campo description: DEL FRONTMATTER lleva estado ABRIENDO su contenido? (S3)
# Especifico a proposito: un estado en OTRO campo (status:, name:), en el cuerpo,
# o en cualquier posicion que NO sea la apertura, NO satisface S3.
tm_s3_ok() {
  [ -n "$(tm_s3_estado "$1")" ]
}

# Linea de APERTURA de un bloque de anulacion, acotada a TM_ESTADOS_ANULACION
# (ALIAS-STUB/PENDIENTE tienen contrato propio y NO cuentan aqui): primera
# linea del CUERPO, desde <ini>, que abre un blockquote `>` con uno de esos
# estados. NO valida fecha ni motivo (eso lo hace el llamador sobre la MISMA
# linea, para dar un motivo de fallo especifico por cada defecto).
tm_anulacion_apertura() { # <fichero> <linea-inicio-cuerpo> → stdout: "NUMLINEA<TAB>ESTADO"
  local f="$1" ini="$2" nl estado
  nl="$(awk -v ini="$ini" -v re="^>[[:space:]]*($TM_ESTADOS_ANULACION)([^A-Za-z]|\$)" \
    'NR>=ini && $0 ~ re {print NR; exit}' "$f" 2>/dev/null)"
  [ -n "$nl" ] || return 0
  estado="$(sed -n "${nl}p" "$f" | grep -oE "($TM_ESTADOS_ANULACION)" | sed -n 1p)"
  printf '%s\t%s\n' "$nl" "$estado"
  return 0
}

# Bloque de citas `>` CONTIGUAS desde <linea-apertura> (inclusive) hasta la
# primera linea que NO empiece por `>` (o EOF). Es el "cuerpo del bloque" sobre
# el que se buscan las etiquetas (Linea muerta / Linea vigente / 4o campo).
tm_anulacion_bloque() { # <fichero> <linea-apertura> → stdout: las lineas del bloque
  awk -v ini="$2" 'NR>=ini { if ($0 ~ /^>/) { print; next } else { exit } }' "$1" 2>/dev/null
  return 0
}

# ¿El <bloque> (texto multilinea) trae la <etiqueta> (ERE, sin ancla ni ':')
# con PAYLOAD real (>=2 alfanumericos) tras los dos puntos? Etiqueta tolerante
# a un calificador entre parentesis antes de los ':' (p. ej. "Linea muerta
# (como criterio GENERAL):", references/02 §4) y sin \b (no portable BSD/macOS).
tm_anulacion_campo() { # <bloque> <etiqueta-ere> ; rc 0/1
  local bloque="$1" etiqueta="$2" linea payload
  linea="$(printf '%s\n' "$bloque" \
    | grep -E "^>[[:space:]]*${etiqueta}([[:space:]]*\\([^)]*\\))?[[:space:]]*:" | sed -n 1p)"
  [ -n "$linea" ] || return 1
  payload="$(printf '%s' "$linea" \
    | sed -E "s/^>[[:space:]]*${etiqueta}([[:space:]]*\\([^)]*\\))?[[:space:]]*://")"
  printf '%s' "$payload" | grep -qE '[[:alnum:]]{2}'
}

# Linea de la etiqueta <etiqueta-ere> dentro del <bloque> (texto completo de la
# linea, no solo el payload) — para correlacionar la cita con el descriptor.
tm_anulacion_linea_etiqueta() { # <bloque> <etiqueta-ere> → stdout: la linea, vacio si no hay
  printf '%s\n' "$1" \
    | grep -E "^>[[:space:]]*${2}([[:space:]]*\\([^)]*\\))?[[:space:]]*:" | sed -n 1p
  return 0
}
