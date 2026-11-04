#!/usr/bin/env bash
# probar-escenarios.sh — 3 escenarios EXTREMO A EXTREMO del pipeline documentado,
# cada uno con su contra-variante naive. Frontera declarada sin adornos: esto
# ejercita el PROCEDIMIENTO con fixtures deterministas — NO es un eval del
# comportamiento del modelo entrevistando. E2 valida consistencia MECANICA del
# as-is contra el mini-repo fixture (las rutas citadas existen), no comprension
# semantica de codigo arbitrario.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
CORPUS="$HERE/corpus-fake"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

[ -f "$CORPUS/greenfield/prd.md" ] && [ -f "$CORPUS/con-gaps/prd.md" ] \
  && [ -f "$CORPUS/completo-minimo/prd.md" ] || { echo "FALLO: corpus-fake incompleto" >&2; exit 1; }

corre_v() { set +e; SALIDA="$(bash "$SKILL/scripts/verificar-prd.sh" "$@" 2>&1)"; RC=$?; set -e; }
corre_g() { set +e; SALIDA="$(bash "$SKILL/scripts/auditar-gaps.sh" "$@" 2>&1)"; RC=$?; set -e; }

echo "==== probar-escenarios: E1/E2/E3 (procedimiento VERDE vs naive ROJO) ===="

# ============================================================================
# E1 · greenfield (pipeline completo -> artefacto conforme)
#   procedimiento: PRD Lite APPROVED + wayfinder consistente + backlog trazado -> VERDE
#   naive: "el documento ya esta escrito" — sin cabecera de versionado, sin
#   criterios pass/fail, backlog sin trazabilidad -> ROJO con esos tres motivos
# ============================================================================
corre_v "$CORPUS/greenfield"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF "backlog conforme"; then
  ok "E1 procedimiento: artefacto greenfield completo -> VERDE"
else
  mal "E1 procedimiento NO dio VERDE (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -10
fi

mkdir -p "$T/e1"
{ echo "# PRD — Recordatorio de riego (naive)"; echo; \
  echo "## 1. Resumen"; echo "Una app que avisa de regar."; echo; \
  echo "## 2. Historias"; echo "- Como Marta, quiero avisos."; } > "$T/e1/prd.md"
{ echo "# tareas"; echo "- hacer la app"; } > "$T/e1/backlog.md"
corre_v "$T/e1"
if [ "$RC" -ne 0 ] && printf '%s' "$SALIDA" | grep -qF "cabecera" \
   && printf '%s' "$SALIDA" | grep -qF "PASA si" \
   && printf '%s' "$SALIDA" | grep -qF "backlog"; then
  ok "E1 naive: doc sin versionado/criterios/trazabilidad -> ROJO con los 3 motivos"
else
  mal "E1 naive NO dio ROJO por los motivos esperados (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -10
fi

# ============================================================================
# E2 · brownfield-reconversion (as-is verificable contra el mini-repo)
#   procedimiento: as-is con rutas citadas que EXISTEN en el repo fixture -> VERDE
#   naive: as-is de memoria — cita modulos que el repo no tiene -> ROJO
# ============================================================================
corre_v "$CORPUS/brownfield" --codigo "$CORPUS/brownfield"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF "rutas citadas existen"; then
  ok "E2 procedimiento: as-is extraido del codigo real -> VERDE"
else
  mal "E2 procedimiento NO dio VERDE (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -10
fi

rm -rf "$T/e2"; cp -r "$CORPUS/brownfield" "$T/e2"
sed -i 's|`codigo/exportar.sh`|`codigo/api/servidor.py`|' "$T/e2/prd.md"
corre_v "$T/e2" --codigo "$T/e2"
if [ "$RC" -ne 0 ] && printf '%s' "$SALIDA" | grep -qF "ruta citada inexistente en el repo: codigo/api/servidor.py"; then
  ok "E2 naive: as-is de memoria citando modulos inexistentes -> ROJO"
else
  mal "E2 naive NO dio ROJO por la ruta fantasma (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -10
fi

# ============================================================================
# E3 · auditoria de gaps consciente del appetite
#   rojo: PRD Estandar declarado con 8 exigibles ausentes -> los 8 GAP nombrados
#   verde: instancia real del nivel Completo -> cero gaps
#   guardia: un Lite completo NO es oraculo del Completo (0 gaps en SU nivel,
#   pero el mismo fichero auditado como completo daria 18)
# ============================================================================
corre_g "$CORPUS/con-gaps/prd.md"
if [ "$RC" -eq 1 ] && printf '%s' "$SALIDA" | grep -qF "gaps=8 appetite=estandar" \
   && printf '%s' "$SALIDA" | grep -qF "GAP Criterios de aceptacion" \
   && printf '%s' "$SALIDA" | grep -qF "GAP Interrogatorio sellado"; then
  ok "E3 rojo: PRD con huecos -> 8 GAP nombrados, rc 1"
else
  mal "E3 rojo NO dio el mapa esperado (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -12
fi

corre_g "$CORPUS/completo-minimo/prd.md"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF "gaps=0 appetite=completo exigibles=27 presentes=27"; then
  ok "E3 verde: instancia Completo real -> cero gaps sobre 27 exigibles"
else
  mal "E3 verde NO dio cero gaps (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -12
fi

corre_g "$CORPUS/greenfield/prd.md"
if [ "$RC" -eq 0 ] && printf '%s' "$SALIDA" | grep -qF "gaps=0 appetite=lite exigibles=9" \
   && printf '%s' "$SALIDA" | grep -qF "INFO fuera-de-appetite: Glosario"; then
  ok "E3 guardia: Lite completo -> 0 gaps EN SU NIVEL, superset informado como fuera-de-appetite"
else
  mal "E3 guardia fallo (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -12
fi

# el mismo Lite forzado a declarar completo SI da gaps: el nivel manda, no el fichero
rm -rf "$T/e3"; mkdir -p "$T/e3"; cp "$CORPUS/greenfield/prd.md" "$T/e3/prd.md"
sed -i '1s/appetite=lite/appetite=completo/' "$T/e3/prd.md"
corre_g "$T/e3/prd.md"
if [ "$RC" -eq 1 ] && printf '%s' "$SALIDA" | grep -qF "gaps=18 appetite=completo"; then
  ok "E3 guardia: el mismo Lite auditado como completo -> 18 gaps (el oraculo no se falsifica)"
else
  mal "E3 guardia-2 fallo (rc=$RC)"; printf '%s\n' "$SALIDA" | sed 's/^/      | /' | head -12
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
