#!/usr/bin/env bash
# Capturas visibles en disco; los consumidores reciben los bytes originales.
tco_fixture_decode() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

controls = (*range(9), 11, 12, *range(14, 32), 127)
mapping = {0x2421 if byte == 127 else 0x2400 + byte: chr(byte)
           for byte in controls}
text = Path(sys.argv[1]).read_bytes().decode('utf-8')
sys.stdout.buffer.write(text.translate(mapping).encode('utf-8'))
PY
}

# Inverso exacto de tco_fixture_decode: los bytes de control de una captura cruda pasan a su símbolo visible. Sirve para
# producir capturas versionables y para probar la ida y vuelta (codificar y descodificar devuelven los mismos bytes).
tco_fixture_encode() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

controls = (*range(9), 11, 12, *range(14, 32), 127)
mapping = {byte: chr(0x2421 if byte == 127 else 0x2400 + byte) for byte in controls}
text = Path(sys.argv[1]).read_bytes().decode('utf-8')
sys.stdout.buffer.write(text.translate(mapping).encode('utf-8'))
PY
}

# Barrido de secretos de un árbol de fixtures versionados. Imprime cuántos elementos NO son publicables (0 = limpio):
#  - el CONTENIDO de cada fichero (las capturas .ansi.txt, ya descodificadas a sus bytes originales);
#  - los METADATOS: de cada SHA256SUMS, la columna de NOMBRES (los digests hex son opacos por diseño y darían falso positivo,
#    pero un nombre con un token y su suma válida es un secreto publicado; una línea mal formada se barre entera);
#  - las RUTAS (nombres) de todos los ficheros versionados.
tco_fixture_sweep() {
  local root="$1" bad=0 f
  while IFS= read -r f; do
    case "$f" in
      */SHA256SUMS) sed -E 's/^[0-9a-f]{64}  //' "$f" | tco_fixture_secret_scan >/dev/null 2>&1 || bad=$((bad+1)) ;;
      *.ansi.txt) tco_fixture_decode "$f" | tco_fixture_secret_scan >/dev/null 2>&1 || bad=$((bad+1)) ;;
      *) tco_fixture_secret_scan < "$f" >/dev/null 2>&1 || bad=$((bad+1)) ;;
    esac
  done < <(find "$root" -type f)
  find "$root" -type f -printf '%P\n' | tco_fixture_secret_scan >/dev/null 2>&1 || bad=$((bad+1))
  printf '%s\n' "$bad"
}

# Comprueba también el inventario: ninguna captura queda fuera de las sumas.
tco_fixture_check_sums() (
  set -euo pipefail
  cd "$1" || { printf 'FAIL cd: %s\n' "$1" >&2; exit 1; }
  local manifest actual digest file line contenido decoded
  contenido=$(cat SHA256SUMS) || { printf 'FAIL lectura: %s/SHA256SUMS\n' "$1" >&2; exit 1; }
  manifest=$(sed -n 's/^[0-9a-f]\{64\}  //p' <<< "$contenido") || {
    printf 'FAIL extracción: %s/SHA256SUMS\n' "$1" >&2; exit 1;
  }
  manifest=$(LC_ALL=C sort <<< "$manifest") || {
    printf 'FAIL sort manifiesto: %s/SHA256SUMS\n' "$1" >&2; exit 1;
  }
  actual=$(find . -type f -name '*.ansi.txt' -printf '%P\n') || {
    printf 'FAIL find: %s\n' "$1" >&2; exit 1;
  }
  actual=$(LC_ALL=C sort <<< "$actual") || {
    printf 'FAIL sort inventario: %s\n' "$1" >&2; exit 1;
  }
  [ -n "$manifest" ] && [ "$manifest" = "$actual" ] || {
    printf 'FAIL inventario de capturas codificadas: %s\n' "$1" >&2; exit 1;
  }
  decoded=$(mktemp) || { printf 'FAIL temporal: %s\n' "$1" >&2; exit 1; }
  trap 'rm -f "$decoded"' EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    digest=${line%%  *}; file=${line#*  }
    [[ $digest =~ ^[0-9a-f]{64}$ ]] && [ "$file" != "$line" ] || {
      printf 'FAIL formato: %s/SHA256SUMS: %s\n' "$1" "$line" >&2; exit 1;
    }
    tco_fixture_decode "$file" > "$decoded" || {
      printf 'FAIL descodificación: %s/%s\n' "$1" "$file" >&2; exit 1;
    }
    actual=$(sha256sum "$decoded") || {
      printf 'FAIL suma: %s/%s\n' "$1" "$file" >&2; exit 1;
    }
    [ "${actual%% *}" = "$digest" ] || {
      printf 'FAIL suma original de captura: %s/%s\n' "$1" "$file" >&2; exit 1;
    }
    printf 'OK suma original: %s\n' "$file"
  done <<< "$contenido"
)
