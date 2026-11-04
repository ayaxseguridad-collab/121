#!/usr/bin/env bash
# Valida que el nombre de la rama de un PR siga la convencion del proyecto.
# Uso: validar-rama-pr.sh "<nombre-rama>"
# Prefijos validos: feat/, fix/, refactor/, docs/, chore/, hotfix/

set -euo pipefail

NOMBRE_RAMA="${1:-}"

if [ -z "$NOMBRE_RAMA" ]; then
  echo "ERROR: no se recibio nombre de rama"
  exit 1
fi

if [[ "$NOMBRE_RAMA" == "main" || "$NOMBRE_RAMA" == "master" ]]; then
  echo "ERROR: no se admite PR desde la rama '$NOMBRE_RAMA'"
  exit 1
fi

REGEX='^(feat|fix|refactor|docs|chore|hotfix)/[a-z0-9._-]+$'

if [[ ! "$NOMBRE_RAMA" =~ $REGEX ]]; then
  cat <<EOF
ERROR: nombre de rama invalido: '$NOMBRE_RAMA'
Convencion: <prefijo>/<descripcion>
Prefijos permitidos: feat, fix, refactor, docs, chore, hotfix
Caracteres permitidos en descripcion: a-z 0-9 . _ -
Ejemplos validos:
  feat/portar-video-player
  fix/login-google-redirect
  refactor/supabase-clients
  docs/runbook-deploy
  chore/actualizar-dependencias
  hotfix/rls-questions
EOF
  exit 1
fi

echo "OK: nombre de rama valido ($NOMBRE_RAMA)"
