#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-invariants.sh — consumidor standalone y fail-closed de invariants.tsv:
# target ausente = ROJO · patron invalido = ROJO · MUST ausente = ROJO ·
# MUST_NOT presente = ROJO. Incluye prueba de MUTACION (una copia del skill con
# una invariante violada debe dar ROJO) y el check de allowlist de comandos.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${1:-$(dirname "$HERE")}"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }

# consume las invariantes de un directorio de skill; imprime y devuelve rc
consume() { # consume <skill-dir>  → rc 0 si todas verdes
  local dir="$1" rc=0 id fichero tipo patron leccion
  while IFS=$'\t' read -r id fichero tipo patron leccion; do
    [ -z "$id" ] && continue
    case "$id" in \#*) continue;; esac
    if [ ! -f "$dir/$fichero" ]; then echo "    ROJO $id: target ausente: $fichero"; rc=1; continue; fi
    if ! printf '' | grep -qE -- "$patron" 2>/dev/null; then
      # grep rc 1 con input vacio es lo esperado para un patron valido; rc>1 = patron invalido
      printf '' | grep -qE -- "$patron" 2>/dev/null; grc=$?
      if [ "$grc" -gt 1 ]; then echo "    ROJO $id: patron invalido: $patron"; rc=1; continue; fi
    fi
    case "$tipo" in
      MUST)
        grep -qE -- "$patron" "$dir/$fichero" || { echo "    ROJO $id ($leccion): '$patron' AUSENTE de $fichero"; rc=1; } ;;
      MUST_NOT)
        grep -qE -- "$patron" "$dir/$fichero" && { echo "    ROJO $id ($leccion): '$patron' PRESENTE en $fichero"; rc=1; } ;;
      *) echo "    ROJO $id: tipo invalido '$tipo'"; rc=1 ;;
    esac
  done < "$dir/invariants.tsv"
  return "$rc"
}

echo "==== probar-invariants: consumo fail-closed + mutacion + allowlist ===="

# 1. el skill real pasa todas sus invariantes
if consume "$SKILL"; then ok "las $(grep -c 'INV-' "$SKILL/invariants.tsv") invariantes del skill en verde"; else mal "invariantes en rojo sobre el skill real"; fi

# 2. MUTACION: violar una invariante en una copia → el consumidor DEBE dar rojo
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp -r "$SKILL" "$T/mutado"
sed -i.bak 's/NO VERIFICADA/todo verificado/g' "$T/mutado/SKILL.md" && rm -f "$T/mutado/SKILL.md.bak"
if consume "$T/mutado" >/dev/null 2>&1; then mal "mutacion (INV-ME-009 violada) paso en verde — el consumidor no muerde"; else ok "mutacion detectada: skill mutado da ROJO"; fi

# 3. target ausente → ROJO
cp -r "$SKILL" "$T/sin-target"
rm "$T/sin-target/references/02-pipeline-de-reparacion.md"
if consume "$T/sin-target" >/dev/null 2>&1; then mal "target ausente paso en verde"; else ok "target ausente da ROJO"; fi

# 4. patron invalido → ROJO
cp -r "$SKILL" "$T/mal-patron"
printf 'INV-XX-999\tSKILL.md\tMUST\t[invalido(\tprueba\n' >> "$T/mal-patron/invariants.tsv"
if consume "$T/mal-patron" >/dev/null 2>&1; then mal "patron invalido paso en verde"; else ok "patron invalido da ROJO"; fi

# 5. MUST_NOT presente → ROJO
cp -r "$SKILL" "$T/con-hold"
printf '\nHOLD\n' >> "$T/con-hold/SKILL.md"
if consume "$T/con-hold" >/dev/null 2>&1; then mal "MUST_NOT presente paso en verde"; else ok "MUST_NOT presente da ROJO"; fi

# 6. allowlist de comandos: todo comando externo invocado por scripts/ esta permitido
# shellcheck source=/dev/null
. "$SKILL/scripts/00-config.sh"
FUERA=""
# candidatos: primer token tras inicio de linea/pipe/&&/||/$( — heuristica sobre codigo sin comentarios
CANDS="$(sed 's/#.*$//' "$SKILL"/scripts/*.sh | \
  grep -oE '(^|[|]|&&|\$\(|;)[[:space:]]*[a-z][a-z0-9_-]{2,14}[[:space:]]' | \
  tr -d '|&$(;' | tr -d ' \t' | sort -u)"
for c in $CANDS; do
  case " $TM_ALLOWED_CMDS " in *" $c "*) : ;; *)
    # descartar builtins/keywords/funciones propias
    case "$c" in
      "if"|"then"|"else"|"elif"|"fi"|"for"|"while"|"do"|"done"|"case"|"esac"|"return"|"exit"|"local"|"printf"|"echo"|"read"|"shift"|"trap"|"set"|"cd"|"command"|"source"|"break"|"continue"|"true"|"false"|"test"|"eval"|"export"|"unset"|"next"|"print"|tm_*|"norm"|"snap_cat"|"prepara"|"corre"|"caso"|"ok"|"mal"|"consume") : ;;  # next/print: keywords de awk dentro de programas entrecomillados
      *) FUERA="$FUERA $c";;
    esac;;
  esac
done
if [ -z "$FUERA" ]; then ok "allowlist: todos los comandos externos de scripts/ estan permitidos"; else mal "comandos fuera de la allowlist:$FUERA"; fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
