#!/usr/bin/env bash
# lectura-estable-base.sh — Base de los casos lectura-estable-* (issue 9011): el espejo VÁLIDO de base-espejo.sh
# más un `gh` doble (gh-secuencia.sh) en el PATH, para correr A2/A2b EN VIVO (sin TRO_PROTECTION_JSON ni
# TRO_REPO_JSON) con el reloj simulado del helper: sin esperas reales y sin ninguna llamada a GitHub.
#
# Fichas de los endpoints: `nuevo` (lo que A2/A2b exigen, los mismos stubs de base-espejo.sh) y `viejo`
# (la réplica anterior a la escritura). Se sourcea desde cada fixture; el fixture fija las secuencias,
# llama a correr_vivo y termina con veredicto.
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "${BASH_SOURCE[0]}")/base-espejo.sh"
set -u

GH_DOBLE_DIR="$(mktemp -d)"
: "${GH_DOBLE_DIR:?}"
GH_DOBLE_SLUG="$TEST_SLUG"
export GH_DOBLE_DIR GH_DOBLE_SLUG
cleanup_lectura_estable() {
  cleanup_espejo
  case "$GH_DOBLE_DIR" in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf -- "$GH_DOBLE_DIR" ;; esac
}
trap cleanup_lectura_estable EXIT
mkdir -p "$GH_DOBLE_DIR/bin"
cp -- "$(dirname "${BASH_SOURCE[0]}")/gh-secuencia.sh" "$GH_DOBLE_DIR/bin/gh"
chmod 755 "$GH_DOBLE_DIR/bin/gh"

cp -- "$ESPEJO_PROTECTION" "$GH_DOBLE_DIR/proteccion.nuevo.json"
cp -- "$ESPEJO_REPO_JSON" "$GH_DOBLE_DIR/repo.nuevo.json"
jq '.enforce_admins.enabled = true | .required_linear_history.enabled = false' "$ESPEJO_PROTECTION" \
  > "$GH_DOBLE_DIR/proteccion.viejo.json"
# La réplica vieja del ensayo: los valores de antes del PATCH.
printf '%s\n' '{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true}' \
  > "$GH_DOBLE_DIR/repo.viejo.json"

# secuencia <clave> <ficha>... — fija la secuencia que servirá el doble para esa clave.
secuencia() {
  local clave="$1"; shift
  printf '%s\n' "$@" > "$GH_DOBLE_DIR/$clave.seq"
}
# alterna <clave> <ficha>... — como secuencia, pero vuelve a empezar al agotarse (sin fin).
alterna() {
  secuencia "$@"
  : > "$GH_DOBLE_DIR/$1.ciclo"
}
# lecturas <clave> — cuántas lecturas sirvió el doble para esa clave.
lecturas() {
  if [ -f "$GH_DOBLE_DIR/$1.n" ]; then cat "$GH_DOBLE_DIR/$1.n"; else printf '0\n'; fi
}
# gh_doble <args>... — el doble tal cual (p. ej. la lectura previa de f4-proteccion en la carrera).
gh_doble() {
  bash "$GH_DOBLE_DIR/bin/gh" "$@"
}

secuencia proteccion nuevo
secuencia repo nuevo

# correr_vivo — el checker EN VIVO con el doble y el reloj simulado. Deja RC_VIVO, SALIDA_VIVO y DURACION_VIVO.
correr_vivo() {
  local inicio="$SECONDS"
  RC_VIVO=0
  SALIDA_VIVO="$(env -u TRO_PROTECTION_JSON -u TRO_REPO_JSON \
    PATH="$GH_DOBLE_DIR/bin:$PATH" \
    LECTURA_ESTABLE_RELOJ=simulado \
    TRO_REPO_SLUG="$TEST_SLUG" \
    TRO_RECEIPTS_DIR="$ESPEJO_RECEIPTS" \
    TRO_ATTEST_DIR="$ESPEJO_ATTEST" \
    TRO_RECEIPT_AUTHORITIES="$AUTH_UID" \
    bash "$CHECKER" "$ESPEJO_DIR" 2>&1)" || RC_VIVO=$?
  DURACION_VIVO=$(( SECONDS - inicio ))
}

FALLOS=()
# exige <descripción> <orden>... — anota la descripción si la orden falla.
exige() {
  local descripcion="$1"; shift
  "$@" || FALLOS+=("$descripcion")
}
contiene() { printf '%s' "$SALIDA_VIVO" | command grep -qF -- "$1"; }
no_contiene() { ! contiene "$1"; }
# Sin esperas reales: el reloj simulado. Con esperas reales, cada caso tardaría ≥ 20 s (5 s entre lecturas).
sin_esperas_reales() { [ "$DURACION_VIVO" -lt 20 ] && contiene 'reloj simulado'; }

# veredicto <resumen> — PASS si no hubo fallos; si no, FAIL con la lista y la cola de la salida.
veredicto() {
  if [ "${#FALLOS[@]}" -eq 0 ]; then
    printf 'PASS: %s (rc=%d, %d s)\n' "$1" "$RC_VIVO" "$DURACION_VIVO"
    return 0
  fi
  printf 'FAIL: %s (rc=%d, %d s)\n' "$(IFS='; '; printf '%s' "${FALLOS[*]}")" "$RC_VIVO" "$DURACION_VIVO"
  printf '%s\n' "$SALIDA_VIVO" | tail -n 30
  return 1
}
