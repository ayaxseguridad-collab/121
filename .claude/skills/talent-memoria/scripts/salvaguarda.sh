#!/usr/bin/env bash
# salvaguarda.sh <DIR> [DEST] — S1: snapshot restaurable + manifiesto de hashes.
# SIEMPRE crea el snapshot (universal: verificar.sh lo necesita como baseline).
# Ademas evalua si git podria servir de baseline (criterios duros fail-closed,
# references/03 §3) y lo REPORTA — informativo, nunca sustituye al snapshot aqui.
# El snapshot va a un directorio hermano fechado FUERA del corpus (o a DEST).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

[ $# -ge 1 ] || tm_die "uso: salvaguarda.sh <dir-de-memoria> [dir-destino]"
CORPUS="$1"
[ -d "$CORPUS" ] || tm_die "no existe el directorio: $CORPUS"
FECHA="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${2:-$(dirname "$CORPUS")/memoria-salvaguarda-$FECHA}"

# El destino JAMAS puede estar dentro del corpus (ni ser el corpus): un snapshot
# interno contamina el corpus y produce un manifiesto que no cuadra con el tar.
# Comparacion por rutas FISICAS resueltas (pwd -P), no por texto.
CORPUS_REAL="$(cd "$CORPUS" && pwd -P)"
DEST_PADRE_REAL="$(cd "$(dirname "$DEST")" 2>/dev/null && pwd -P)" \
  || tm_die "el padre del destino no existe: $(dirname "$DEST")"
DEST_REAL="$DEST_PADRE_REAL/$(basename "$DEST")"
case "$DEST_REAL/" in
  "$CORPUS_REAL/"*) tm_die "el destino '$DEST' esta DENTRO del corpus (fail-closed): la salvaguarda va FUERA";;
esac

# symlinks: fuera del inventario del manifiesto → no se salvaguardan (fail-closed)
tm_no_symlinks "$CORPUS"

tm_say "SALVAGUARDA S1 — $CORPUS"

# baseline git: solo informe (fail-closed: cualquier duda = snapshot obligatorio)
GITINFO="$(tm_git_baseline "$CORPUS")"
case "$GITINFO" in
  git-valido) printf '  git: baseline valido (rama + git diff tambien servirian)\n';;
  *)          printf '  git: %s\n' "$GITINFO";;
esac

[ -e "$DEST" ] && tm_die "el destino ya existe: $DEST (no piso salvaguardas previas)"
mkdir -p "$DEST"
chmod "$TM_SNAP_DIR_MODE" "$DEST"

# TOCTOU: tar y tm_manifest son DOS lecturas del corpus vivo. Un fichero que
# cambie entre la una y la otra entra al manifiesto con el hash nuevo y al tar
# con el viejo, y verificar.sh cantaria "intacto OK" sobre algo que si cambio.
# Staging inmutable: se copia UNA vez y tar+manifiesto salen del MISMO artefacto.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# .git NO entra al staging: si el corpus es la raiz de un worktree, sus metadatos
# de repositorio no son memoria — colarian miles de objetos al tar y al manifiesto,
# y el mundo cerrado de verificar.sh los cantaria como deltas fantasma.
tar -C "$CORPUS" --exclude='./.git' -cf - . | tar -C "$STAGE" -xf -

TAR="$DEST/snapshot-$FECHA.tar.gz"
tar -czf "$TAR" -C "$STAGE" .
chmod "$TM_SNAP_FILE_MODE" "$TAR"

tm_manifest "$STAGE" > "$DEST/manifest.txt"
chmod "$TM_SNAP_FILE_MODE" "$DEST/manifest.txt"

N="$(wc -l < "$DEST/manifest.txt")"
printf '  snapshot:   %s\n' "$TAR"
printf '  manifiesto: %s (%s ficheros)\n' "$DEST/manifest.txt" "$N"
printf '  permisos:   dir %s · ficheros %s\n' "$TM_SNAP_DIR_MODE" "$TM_SNAP_FILE_MODE"
printf '\n  restaurar = extraer sobre un directorio VACIO y comparar con el manifiesto:\n'
printf '    mkdir restaurado && tar -xzf "%s" -C restaurado\n' "$TAR"
printf '  verificar despues de reparar:\n'
printf '    bash scripts/verificar.sh "%s" "%s" cambios-declarados.tsv\n' "$DEST" "$CORPUS"
