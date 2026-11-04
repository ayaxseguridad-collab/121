#!/usr/bin/env bash
# CASO: exit 0 (OK) — COMPORTAMIENTO de extremo a extremo (TAL-8037, acta M1): partiendo de un repo SIN los IDENTICOS ni
# core.hooksPath, el onboarding (bucle del paso 2 de SKILL.md con el canon del PAQUETE) + el setup-githooks.sh INSTALADO
# dejan core.hooksPath=.githooks y el verificador termina en verde — sin fijar hooksPath a mano.
# shellcheck source=tests/fixtures/base-espejo.sh
source "$(dirname "$0")/base-espejo.sh"

# Paquete: el real (modo paquete) o uno sintético construido con el mapa desde el espejo (modo git).
PKG="${CANON_PKG_DIR:-}"
if [ -z "$PKG" ]; then
  PKG="$(mktemp -d)"
  while IFS=$'\t' read -r prod rel; do
    case "$prod" in '#'*|'') continue ;; esac
    mkdir -p "$PKG/$(dirname "$rel")"; cp -- "$ESPEJO_DIR/$prod" "$PKG/$rel"
  done < "$CANON_MAP_FILE"
  trap 'rm -rf "$PKG"; cleanup_espejo' EXIT
fi

# 1) Estado de partida: sin los IDENTICOS instalados y sin core.hooksPath.
while IFS=$'\t' read -r prod rel; do
  case "$prod" in '#'*|'') continue ;; esac
  rm -f "$ESPEJO_DIR/$prod"
done < "$CANON_MAP_FILE"
git -C "$ESPEJO_DIR" config --unset core.hooksPath

# 2) Onboarding: el bucle del paso 2 de SKILL.md (verbatim, ejecutado dentro del repo).
(
  cd "$ESPEJO_DIR"
  while IFS=$'\t' read -r prod rel; do
    case "$prod" in '#'*|'') continue ;; esac
    mkdir -p "$(dirname "$prod")"; cp -- "$PKG/$rel" "$prod"
    case "$prod" in *.sh|.githooks/pre-push) chmod +x "$prod" ;; esac
  done < "$CANON_MAP_FILE"
  # 3) El setup-githooks.sh INSTALADO (no el del paquete) activa los hooks.
  bash scripts/setup-githooks.sh >/dev/null
)
[ "$(git -C "$ESPEJO_DIR" config --local core.hooksPath)" = ".githooks" ] || { echo "FAIL: setup-githooks.sh no fijó .githooks"; exit 1; }

espejo_commit
run_check 0
