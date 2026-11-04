#!/usr/bin/env bash
# fake-authmove.sh — stub de auth-move.sh (P1) para los 2 tests del MOVE de codex de P2 (TAL-2295).
# NO re-implementa el MOVE (eso lo cubre el arnés de talent-channels): EMULA sus DOS desenlaces con sus
# efectos en el filesystem, para verificar que el WRAPPER tco_reauth_carril_codex decide bien y NUNCA
# restaura al donante en un fallo post-commit.
#
# Env del arnés:
#   FAM_MODE     precommit | postcommit | done141 | post137
#   FAM_DONOR    ruta del marcador de credencial del DONANTE
#   FAM_DEST     ruta del marcador de credencial del DESTINO
#   FAM_JOURNAL  ruta del "journal" pendiente (se crea en postcommit, se borra en resume)
#   FAM_TX       id de la transacción simulada
set -uo pipefail
cmd="${1:-}"; shift || true
case "$cmd" in
  move)
    # argv: <cuenta> <from> <to> --agent codex
    to="${3:-}"
    case "${FAM_MODE:-}" in
      precommit)
        # auth-move reconcilia INTERNAMENTE: donante restaurado, destino sin auth. rc pre-commit (1).
        mkdir -p "$(dirname "$FAM_DONOR")"; : > "$FAM_DONOR"
        rm -f "$FAM_DEST"
        exit 1 ;;
      postcommit)
        # COMMIT hecho (credencial YA en destino) pero health POST-commit falló → rc 4. Donante consumido.
        mkdir -p "$(dirname "$FAM_DEST")"; : > "$FAM_DEST"
        rm -f "$FAM_DONOR"
        mkdir -p "$(dirname "$FAM_JOURNAL")"; printf '%s DEST_INSTALLED acme donor→%s\n' "$FAM_TX" "$to" > "$FAM_JOURNAL"
        exit 4 ;;
      done141)
        # [TAL-8042] MOVE COMPLETO (journal DONE, credencial en destino) pero el CLI devuelve 141 (SIGPIPE por
        # salida cerrada tras DONE: FAB-OBS-002). El wrapper NO debe leerlo como pre-commit.
        mkdir -p "$(dirname "$FAM_DEST")"; : > "$FAM_DEST"
        rm -f "$FAM_DONOR"
        mkdir -p "$(dirname "$FAM_JOURNAL")"; printf '%s DONE acme donor→%s\n' "$FAM_TX" "$to" > "$FAM_JOURNAL"
        exit 141 ;;
      post137)
        # [TAL-8042] muerte del CLI (rc 137) justo tras persistir DEST_INSTALLED: commit hecho → reparar EN destino.
        mkdir -p "$(dirname "$FAM_DEST")"; : > "$FAM_DEST"
        rm -f "$FAM_DONOR"
        mkdir -p "$(dirname "$FAM_JOURNAL")"; printf '%s DEST_INSTALLED acme donor→%s\n' "$FAM_TX" "$to" > "$FAM_JOURNAL"
        exit 137 ;;
      *) echo "fake-authmove: FAM_MODE no configurado" >&2; exit 2 ;;
    esac ;;
  status)
    [ -f "${FAM_JOURNAL:-/nonexistent}" ] && cat "$FAM_JOURNAL"
    exit 0 ;;
  repair|resume)
    # reparación EN DESTINO: destino sigue siendo el propietario, donante NO se toca; cierra el journal.
    : > "$FAM_DEST"
    rm -f "$FAM_JOURNAL"
    exit 0 ;;
  *) echo "fake-authmove: subcomando '$cmd' no soportado" >&2; exit 2 ;;
esac
