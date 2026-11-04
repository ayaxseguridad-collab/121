#!/usr/bin/env bash
# probar-invariants.sh — consume invariants.tsv en modo fail-closed y DEMUESTRA que
# muerde: ademas del verde sobre el skill real, una mutacion deliberada (borrar el
# literal NO VERIFICADA), un target ausente, un patron roto y un MUST_NOT violado
# tienen que dar ROJO. Un consumidor que no muerde es decoracion.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${1:-$(dirname "$HERE")}"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# consume <skill-dir> -> rc 0 si todas las invariantes pasan; imprime cada ROJO
consume() {
  local dir="$1" rc=0 linea solo_tabs id fichero tipo patron leccion grc
  [ -f "$dir/invariants.tsv" ] || { echo "    ROJO sin invariants.tsv"; return 1; }
  # el `|| [ -n "$linea" ]` procesa tambien una ultima fila sin salto de linea final
  while IFS= read -r linea || [ -n "$linea" ]; do
    case "$linea" in ""|"#"*) continue ;; esac
    # exactamente 5 columnas: IFS=TAB colapsaria TABs consecutivos (el TAB es
    # whitespace para read) y una columna vacia DESPLAZARIA los campos — se
    # cuentan los TABs crudos y se separa con un delimitador no-whitespace
    solo_tabs="${linea//[^$'\t']/}"
    if [ "${#solo_tabs}" -ne 4 ]; then
      echo "    ROJO fila con columnas != 5 (TABs=${#solo_tabs}): ${linea%%$'\t'*}"; rc=1; continue
    fi
    IFS=$'\x1f' read -r id fichero tipo patron leccion <<< "${linea//$'\t'/$'\x1f'}"
    if [ -z "$id" ] || [ -z "$fichero" ] || [ -z "$tipo" ] || [ -z "$patron" ]; then
      echo "    ROJO $id: fila con campos vacios (id/fichero/tipo/patron)"; rc=1; continue
    fi
    if [ ! -f "$dir/$fichero" ]; then echo "    ROJO $id: target ausente: $fichero"; rc=1; continue; fi
    set +e; printf '' | grep -qE -- "$patron" 2>/dev/null; grc=$?; set -e
    if [ "$grc" -gt 1 ]; then echo "    ROJO $id: patron invalido: $patron"; rc=1; continue; fi
    case "$tipo" in
      MUST)     grep -qE -- "$patron" "$dir/$fichero" || { echo "    ROJO $id ($leccion): '$patron' AUSENTE de $fichero"; rc=1; } ;;
      MUST_NOT)
        # fail-closed tambien aqui: grep rc>1 (target ilegible) es ROJO, no un pase en silencio
        set +e; grep -qE -- "$patron" "$dir/$fichero" 2>/dev/null; grc=$?; set -e
        if [ "$grc" -eq 0 ]; then echo "    ROJO $id ($leccion): '$patron' PRESENTE en $fichero"; rc=1
        elif [ "$grc" -gt 1 ]; then echo "    ROJO $id: target no legible: $fichero"; rc=1; fi ;;
      *) echo "    ROJO $id: tipo invalido '$tipo'"; rc=1 ;;
    esac
  done < "$dir/invariants.tsv"
  return "$rc"
}

echo "==== probar-invariants: consumo fail-closed + mutacion ===="

# 1. el skill real pasa todas sus invariantes
if consume "$SKILL"; then ok "skill real: todas las invariantes en verde"; else mal "el skill real viola sus propias invariantes"; fi

# 2. MUTACION: borrar el literal protegido debe dar ROJO (la mutacion es contrato)
cp -r "$SKILL" "$T/mutado"
sed -i 's/NO VERIFICADA/todo verificado/g' "$T/mutado/SKILL.md"
if consume "$T/mutado" >/dev/null 2>&1; then
  mal "mutacion (NO VERIFICADA borrado) paso en verde — el consumidor no muerde"
else
  ok "mutacion detectada: el skill mutado da ROJO"
fi

# 3. target ausente -> ROJO
cp -r "$SKILL" "$T/sin-target"
rm "$T/sin-target/references/04-review-adversarial-y-desgranado.md"
if consume "$T/sin-target" >/dev/null 2>&1; then mal "target ausente paso en verde"; else ok "target ausente da ROJO"; fi

# 4. patron ERE invalido -> ROJO
cp -r "$SKILL" "$T/patron-roto"
printf 'INV-XX-999\tSKILL.md\tMUST\t[invalido(\tprueba\n' >> "$T/patron-roto/invariants.tsv"
if consume "$T/patron-roto" >/dev/null 2>&1; then mal "patron invalido paso en verde"; else ok "patron invalido da ROJO"; fi

# 5. MUST_NOT violado -> ROJO (colar un nombre del repo de origen en un script)
cp -r "$SKILL" "$T/con-marca"
printf '\n# talent-factory\n' >> "$T/con-marca/scripts/verificar-prd.sh"
if consume "$T/con-marca" >/dev/null 2>&1; then mal "MUST_NOT violado paso en verde"; else ok "MUST_NOT violado da ROJO"; fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
