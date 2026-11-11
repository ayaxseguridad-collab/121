#!/usr/bin/env bash
# Inscripción manual: alta/baja/lista; lista privada y rename atómico, sin duplicados.
set -uo pipefail
LISTA="${COMPACT_VIVO_INCLUIR:-${XDG_CONFIG_HOME:-$HOME/.config}/talent-context/compact-vivo.incluir}"
modo="${1:-}"; sid="${2:-}"
case "$modo" in
  lista) [ $# = 1 ] || exit 1; [ ! -e "$LISTA" ] || cat "$LISTA"; exit $? ;;
  alta|baja) [ $# = 2 ] && [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'session_id inválido' >&2; exit 1; } ;;
  *) echo 'Uso: compact-vivo-inscribir.sh alta|baja|lista [session_id]' >&2; exit 1 ;;
esac
[ ! -L "$LISTA" ] || { echo 'lista enlazada' >&2; exit 1; }
umask 077
mkdir -p "$(dirname "$LISTA")" || exit 1
# Candado de directorio: sin dependencias nuevas, no pierde altas concurrentes.
lock="$LISTA.lock"
mkdir "$lock" 2>/dev/null || { echo 'lista ocupada; reintenta' >&2; exit 1; }
tmp=''; trap '[ -z "$tmp" ] || rm -f "$tmp"; rmdir "$lock"' EXIT
[ ! -e "$LISTA" ] || [ -r "$LISTA" ] || { echo 'lista ilegible' >&2; exit 1; }
tmp="$(mktemp "$LISTA.XXXXXX")" || exit 1
if [ -e "$LISTA" ]; then cat "$LISTA" > "$tmp" || exit 1; fi
if [ "$modo" = alta ]; then printf '%s\n' "$sid" >> "$tmp" || exit 1; fi
# grep sin coincidencias es normal en una baja del último identificador.
contenido="$(grep -vxF -- "$sid" "$tmp" || :)"
if [ "$modo" = alta ]; then contenido="$(printf '%s\n%s\n' "$contenido" "$sid")"; fi
printf '%s\n' "$contenido" | sed '/^$/d' | sort -u > "$tmp" || exit 1
chmod 600 "$tmp" && mv -f "$tmp" "$LISTA" || exit 1
tmp=''
