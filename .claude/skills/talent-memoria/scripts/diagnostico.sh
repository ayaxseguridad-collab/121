#!/usr/bin/env bash
# shellcheck disable=SC2016  # comillas simples deliberadas: el patron busca backticks literales
# diagnostico.sh [DIR] — censo de un corpus de memoria. SOLO LECTURA por contrato:
# no escribe ficheros, no crea temporales, no toca nada (lo prueba
# tests/probar-diagnostico.sh hermeticamente). Reporta metricas y candidatos,
# nunca el contenido de las notas.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

# --- localizar corpus ---------------------------------------------------------
CORPUS=""
if [ $# -ge 1 ]; then
  [ -d "$1" ] || tm_die "no existe el directorio: $1"
  CORPUS="$1"
else
  # Autodeteccion fail-closed: candidatos conocidos bajo el directorio actual y el HOME.
  slug="$(pwd | tr '/ ' '--')"
  for c in ".claude/memory" "$HOME/.claude/projects/$slug/memory"; do
    [ -d "$c" ] && { CORPUS="$c"; break; }
  done
  if [ -z "$CORPUS" ]; then
    printf 'No encuentro un corpus en las rutas candidatas:\n'
    printf '  - %s\n' "$(pwd)/.claude/memory" "$HOME/.claude/projects/$slug/memory"
    printf 'Pasame la ruta: bash scripts/diagnostico.sh /ruta/a/tu/memoria\n'
    exit 1
  fi
fi

# symlinks: fuera del inventario de find -type f → un retarget seria invisible
# para el censo. Fail-closed antes de medir nada (mismo criterio que
# verificar.sh/salvaguarda.sh).
tm_no_symlinks "$CORPUS"

tm_say "DIAGNOSTICO (solo lectura) — $CORPUS"

# --- censo base ---------------------------------------------------------------
NOTAS=0; SIN_FECHA=0; CON_ESTADO=0; S3_ROTO=0
SIN_FECHA_L=""; S3_ROTO_L=""; MUERTAS_L=""
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [ "$base" = "$TM_INDEX_FILE" ] && continue
  NOTAS=$((NOTAS+1))
  tm_tiene_fecha "$f" || { SIN_FECHA=$((SIN_FECHA+1)); SIN_FECHA_L="$SIN_FECHA_L  - $base"$'\n'; }
  if grep -qE "$TM_ESTADOS" "$f" 2>/dev/null; then
    CON_ESTADO=$((CON_ESTADO+1))
    tm_s3_ok "$f" || { S3_ROTO=$((S3_ROTO+1)); S3_ROTO_L="$S3_ROTO_L  - $base (estado en cuerpo, description sin estado)"$'\n'; }
  fi
  # instrucciones muertas: rutas relativas citadas entre backticks que no existen
  while IFS= read -r ruta; do
    [ -n "$ruta" ] || continue
    [ -e "$CORPUS/$ruta" ] || [ -e "$ruta" ] || MUERTAS_L="$MUERTAS_L  - $base cita \`$ruta\` (no existe)"$'\n'
  done < <(grep -oE '`[A-Za-z0-9._/-]+\.(sh|sql|md|py|ts|js|json)`' "$f" 2>/dev/null | tr -d '`' | sort -u)
done < <(find "$CORPUS" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)

BYTES="$(find "$CORPUS" -maxdepth 1 -type f -name '*.md' -print0 | sort -z | { total=0; while IFS= read -r -d '' f; do s=$(wc -c < "$f"); total=$((total+s)); done; printf '%s' "$total"; })"
printf '  notas: %s · tamano total: %s bytes\n' "$NOTAS" "$BYTES"
printf '  notas sin fecha detectable: %s\n' "$SIN_FECHA"
[ -n "$SIN_FECHA_L" ] && printf '%s' "$SIN_FECHA_L"
printf '  notas con estado marcado (%s): %s\n' "ANULADA/ACOTADA/CADUCADA/SUPERSEDED/ALIAS-STUB/PENDIENTE" "$CON_ESTADO"
printf '  estados solo-en-cuerpo (violan S3): %s\n' "$S3_ROTO"
[ -n "$S3_ROTO_L" ] && printf '%s' "$S3_ROTO_L"

# --- candidatos a duplicado (prefijo comun de nombre) -------------------------
tm_say "CANDIDATOS A DUPLICADO (la decision es tuya)"
DUPS=0
prev=""
prevfull=""
while IFS= read -r -d '' f; do
  base="$(basename "$f" .md)"
  pref="$(printf '%s' "$base" | cut -c1-"$TM_DUP_PREFIJO")"
  if [ -n "$prev" ] && [ "$pref" = "$prev" ]; then
    printf '  - %s ~ %s\n' "$prevfull" "$base"; DUPS=$((DUPS+1))
  fi
  prev="$pref"; prevfull="$base"
done < <(find "$CORPUS" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
[ "$DUPS" -eq 0 ] && printf '  (ninguno por nombre; la contradiccion semantica se detecta leyendo)\n'

# --- instrucciones muertas ----------------------------------------------------
tm_say "RUTAS CITADAS QUE NO EXISTEN (candidatas a instruccion muerta)"
if [ -n "$MUERTAS_L" ]; then printf '%s' "$MUERTAS_L"; else printf '  (ninguna)\n'; fi

# --- indice -------------------------------------------------------------------
tm_say "INDICE ($TM_INDEX_FILE)"
IDX="$CORPUS/$TM_INDEX_FILE"
if [ ! -f "$IDX" ]; then
  printf '  no hay indice — references/04 explica como montarlo\n'
else
  LINEAS="$(wc -l < "$IDX")"
  printf '  lineas: %s' "$LINEAS"
  [ "$LINEAS" -gt "$TM_INDICE_LINEAS_MAX" ] && printf '  (> %s: candidato a compactar/dividir, references/04)' "$TM_INDICE_LINEAS_MAX"
  printf '\n'
  # entradas del indice que apuntan a notas inexistentes
  ROTAS=0
  while IFS= read -r ruta; do
    [ -e "$CORPUS/$ruta" ] || { printf '  - entrada rota: apunta a %s (no existe)\n' "$ruta"; ROTAS=$((ROTAS+1)); }
  done < <(grep -oE '\]\([^)]+\.md\)' "$IDX" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u)
  # notas sin entrada en el indice
  HUERFANAS=0
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [ "$base" = "$TM_INDEX_FILE" ] && continue
    grep -qF -- "$base" "$IDX" || { printf '  - nota sin entrada en el indice: %s\n' "$base"; HUERFANAS=$((HUERFANAS+1)); }
  done < <(find "$CORPUS" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
  printf '  entradas rotas: %s · notas sin indexar: %s\n' "$ROTAS" "$HUERFANAS"
fi

tm_say "SIGUIENTE PASO"
printf '  cada hallazgo → su paso del pipeline: references/01 seccion 5.\n'
printf '  antes de tocar NADA: bash scripts/salvaguarda.sh "%s"\n' "$CORPUS"
