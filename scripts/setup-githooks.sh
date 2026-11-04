#!/usr/bin/env bash
# setup-githooks.sh — Activa los git hooks versionados en ESTE clon. One-shot, idempotente.
# Directorio de hooks (TAL-8037): '.githooks' en un repo de PRODUCTO (el que instala el onboarding) o 'githooks' en el
# motor — se elige por el que contiene pre-push (si existen ambos, gana '.githooks'). Mismo script en los dos sitios.
# El repo del motor usa el dir 'githooks/' (sin punto — README + motor-go.sh). Su pre-push exige el
# sentinel (SHA, refs/heads/main) que SOLO emite 'bash scripts/motor-go.sh' (TAL-2288). Sin activar
# core.hooksPath, ese enforcement NO corre y un push directo a main se cuela sin gates (TAL-2614).
# Onboarding del repo: córrelo una vez por máquina/clon.
#
# NO pisa core.hooksPath a ciegas: si ya hay otro hooksPath o hooks reales en .git/hooks, avisa y pide
# confirmación. En entornos NO interactivos (CI), no cuelga: ante conflicto, falla con instrucciones.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "setup-githooks: no estás en un repo git." >&2; exit 1; }
cd "$ROOT"

confirm() { # prompt  → 0 si el usuario acepta; 1 si rechaza o no es interactivo
  if [ -t 0 ]; then read -rp "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; else return 1; fi
}

# Regla (TAL-8037): con AMBOS directorios gana '.githooks' (el del repo de producto) y se AVISA por stderr, no en silencio.
if [ -f .githooks/pre-push ]; then
  HOOKS_DIR=".githooks"
  [ ! -f githooks/pre-push ] || echo "AVISO: existen .githooks/pre-push Y githooks/pre-push — se activa .githooks (ver la regla en la cabecera de este script)." >&2
elif [ -f githooks/pre-push ]; then HOOKS_DIR="githooks"
else echo "setup-githooks: no encuentro .githooks/pre-push ni githooks/pre-push en $ROOT." >&2; exit 1; fi

current="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ "$current" = "$HOOKS_DIR" ]; then
  echo "✓ core.hooksPath ya es $HOOKS_DIR — el hook pre-push ya está activo."
  exit 0
fi

if [ -n "$current" ]; then
  echo "AVISO: core.hooksPath ya apunta a '$current' (no $HOOKS_DIR)."
  confirm "¿Sobrescribir a $HOOKS_DIR?" || {
    echo "Cancelado. Resuelve el conflicto manualmente (o corre en terminal interactiva)." >&2; exit 1; }
fi

real_hooks="$(find .git/hooks -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | head -5 || true)"
if [ -n "$real_hooks" ]; then
  echo "AVISO: hay hooks en .git/hooks que dejarán de ejecutarse al cambiar core.hooksPath:"
  printf '%s\n' "$real_hooks" | sed 's/^/  /'
  confirm "¿Continuar igualmente?" || { echo "Cancelado." >&2; exit 1; }
fi

git config core.hooksPath "$HOOKS_DIR"
if [ "$HOOKS_DIR" = "githooks" ]; then   # el motor: su guía de push directo a main (motor-go.sh)
  echo "✓ core.hooksPath = $HOOKS_DIR. El hook pre-push (sentinel del motor, TAL-2288) está activo en este clon."
  echo "  Flujo: 'bash scripts/motor-go.sh' emite el sentinel antes de pushear a main. Salida consciente: 'git push --no-verify'."
else                                      # repo de producto: sin la guía del motor
  echo "✓ core.hooksPath = $HOOKS_DIR. El hook pre-push está activo en este clon. Salida consciente: 'git push --no-verify'."
fi
