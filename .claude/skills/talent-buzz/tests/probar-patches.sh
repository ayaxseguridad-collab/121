#!/usr/bin/env bash
# Los patches de assets/patches/ aplican limpios sobre block/buzz@<commit fijado>.
# Fuente del arbol: $TB_BUZZ_GIT (repo local) o clone superficial (necesita red).
# Sin ninguna de las dos: SKIP explicito (no un falso verde silencioso).
# TB_BUZZ_SIN_RED=1 exige checkout local y falla si desaparece; lo fija la batería.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$DIR/../assets/patches"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=00-config.sh
source "$DIR/../scripts/00-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null; git -C "${TB_BUZZ_GIT:-/nonexistent}" worktree prune 2>/dev/null || true' EXIT

TB_BUZZ_GIT="${TB_BUZZ_GIT:-$HOME/buzz}"
if [ -e "$TB_BUZZ_GIT/.git" ] && git -C "$TB_BUZZ_GIT" cat-file -e "$TB_BUZZ_COMMIT^{commit}" 2>/dev/null; then
  # El pin se RESUELVE a SHA completo antes de usarse y el arbol resultante se
  # compara contra el (hallazgo 11): un prefijo ambiguo o colisionado no pasa.
  PIN_SHA="$(git -C "$TB_BUZZ_GIT" rev-parse --verify "$TB_BUZZ_COMMIT^{commit}")" \
    || { echo "probar-patches: FALLO resolviendo $TB_BUZZ_COMMIT a SHA completo"; exit 1; }
  git -C "$TB_BUZZ_GIT" worktree add --detach "$TMP/arbol" "$PIN_SHA" >/dev/null 2>&1 \
    || { echo "probar-patches: FALLO creando worktree de $PIN_SHA en $TB_BUZZ_GIT"; exit 1; }
  ARBOL="$TMP/arbol"
  [ "$(git -C "$ARBOL" rev-parse HEAD)" = "$PIN_SHA" ] \
    || { echo "probar-patches: el worktree no esta en el pin resuelto $PIN_SHA"; exit 1; }
elif [ "${TB_BUZZ_SIN_RED:-0}" = 1 ]; then
  echo 'probar-patches: FALLO checkout local con pin ausente; red prohibida en esta batería'
  exit 1
elif git ls-remote "$TB_BUZZ_REPO_URL" >/dev/null 2>&1; then
  git init -q "$TMP/arbol"
  git -C "$TMP/arbol" remote add origin "$TB_BUZZ_REPO_URL"
  git -C "$TMP/arbol" fetch -q --depth 1 origin "$TB_BUZZ_COMMIT"
  git -C "$TMP/arbol" checkout -q FETCH_HEAD
  ARBOL="$TMP/arbol"
  # En la via remota el pin de 00-config es el SHA completo: HEAD debe SERLO.
  [ "$(git -C "$ARBOL" rev-parse HEAD)" = "$TB_BUZZ_COMMIT" ] \
    || { echo "probar-patches: FETCH_HEAD $(git -C "$ARBOL" rev-parse HEAD) != pin $TB_BUZZ_COMMIT"; exit 1; }
else
  echo "probar-patches: SKIP (ni repo local en \$TB_BUZZ_GIT ni red para clonar)"
  exit 0
fi

fallos=0
for p in "$PATCHES"/*.patch; do
  if git -C "$ARBOL" apply --check "$p" 2>"$TMP/err"; then
    echo "OK  $(basename "$p") aplica limpio sobre $TB_BUZZ_COMMIT"
  else
    echo "FALLO $(basename "$p"):"; cat "$TMP/err"; fallos=$((fallos+1))
  fi
done

if [ "$fallos" -eq 0 ]; then echo "probar-patches: TODO OK"; else echo "probar-patches: $fallos fallos"; exit 1; fi
