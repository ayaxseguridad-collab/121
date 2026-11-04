#!/usr/bin/env bash
# Helpers de seguridad compartidos (montar.sh, movil.sh, tests).
# Solo definiciones: sourcear este archivo jamas ejecuta nada (INV-TB-002).

exigir_0600() { # secreto reutilizable: propietario actual y modo 0600, o
  # nada (hallazgo M12 de la E2) — un backup/restauracion que deje 0644 no
  # "se acepta y ya".
  local f="$1" modo dueno
  [ -f "$f" ] || { echo "exigir_0600: no existe $f" >&2; return 1; }
  modo="$(stat -c '%a' "$f")" || return 1
  dueno="$(stat -c '%U' "$f")" || return 1
  if [ "$dueno" != "$(id -un)" ]; then
    echo "exigir_0600: $f pertenece a '$dueno', no a '$(id -un)'" >&2
    return 1
  fi
  if [ "$modo" != "600" ]; then
    echo "exigir_0600: $f tiene modo $modo (exigido 600); corrige con chmod 600 tras revisar quien pudo leerlo" >&2
    return 1
  fi
}

# reconciliar_env <env> <clave=valor>...
# Reconciliacion de claves INVARIANTES de un .env conservado (huecos 6-7 de la
# ronda de seguridad): un .env heredado puede traer BUZZ_IMAGE distinto
# (bypass del pin M3), BUZZ_REQUIRE_RELAY_MEMBERSHIP=false (auth fuera) o
# frontera/URLs divergentes. Contrato:
# - El .env se verifica 0600+dueño ANTES de tocarlo (fail-closed).
# - Cada clave dada se fija a SU valor (reemplazo o alta); el resto de lineas
#   — los secretos — se conservan byte a byte.
# - Reescritura ATOMICA (tmp en el mismo directorio + mv); el modo final es
#   0600 explicito.
reconciliar_env() {
  local envf="$1"; shift
  exigir_0600 "$envf" || return 1
  # Claves DUPLICADAS en el heredado => fail-closed (sugerencia Alta r5): un
  # duplicado significa que compose usara "el ultimo que gane" — con un
  # secreto (HMAC) eso es una identidad ambigua. No se normaliza en
  # silencio: se explica y el operador decide cual sobra.
  local dups
  dups="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$envf" | sort | uniq -d || true)"
  if [ -n "$dups" ]; then
    echo "reconciliar_env: claves DUPLICADAS en $envf (elimina la sobrante a mano):" >&2
    echo "$dups" >&2
    return 1
  fi
  # Los valores a reconciliar no pueden llevar saltos de linea (romperian el
  # formato .env) ni los metacaracteres de reemplazo de sed sin escapar
  # (&, \, |) — se validan y escapan ANTES de tocar nada (CodeRabbit rA).
  local par clave valor
  for par in "$@"; do
    case "$par" in
      *$'\n'*) echo "reconciliar_env: valor con salto de linea en '$par'" >&2; return 1 ;;
      *=*) : ;;
      *) echo "reconciliar_env: '$par' no tiene forma clave=valor" >&2; return 1 ;;
    esac
  done
  # Cada comando critico verifica su estado y aborta la funcion: reconciliar_env
  # se invoca como operando izquierdo de || (set -e suprimido) y un fallo a
  # mitad NO debe dejar un tmp a medias como resultado "bueno".
  local tmp
  tmp="$(mktemp "$envf.XXXXXX")" || return 1
  if ! cp "$envf" "$tmp"; then rm -f "$tmp"; return 1; fi
  for par in "$@"; do
    clave="${par%%=*}"
    valor="${par#*=}"
    if grep -q "^${clave}=" "$tmp"; then
      # sed con delimitador | ; el reemplazo escapa \, & y | del valor.
      local par_esc
      par_esc="${clave}=$(printf '%s' "$valor" | sed -e 's/[\\&|]/\\&/g')"
      if ! sed -i "s|^${clave}=.*|${par_esc}|" "$tmp"; then rm -f "$tmp"; return 1; fi
    else
      if ! printf '%s\n' "$par" >> "$tmp"; then rm -f "$tmp"; return 1; fi
    fi
  done
  if ! chmod 600 "$tmp"; then rm -f "$tmp"; return 1; fi
  # mv es lo ultimo; si fallara (raro: mismo dir, rename) el original queda
  # intacto — se limpia el temporal para no dejar residuo (todos los caminos de
  # fallo limpian el tmp).
  if ! mv "$tmp" "$envf"; then rm -f "$tmp"; return 1; fi
}
