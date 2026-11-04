#!/usr/bin/env bash
# probar-standalone.sh — gate de instalacion limpia: SOLO la carpeta del skill,
# copiada a un HOME temporal (con ESPACIOS en la ruta) y sin repo alrededor, debe
# funcionar igual y no contener UNA SOLA referencia runtime al repo de origen.
# Superficie del grep de agnosticismo: cuerpo publicable de SKILL.md (antes de
# '## Paquete de fábrica' — esa seccion no viaja en el artefacto del alumno),
# references/, assets/ y scripts/, insensible a mayusculas. Quedan fuera SOLO los
# ficheros cuya funcion exige esos terminos: CHANGELOG (trazabilidad), tests/
# (contienen estos mismos patrones) e invariants.tsv (los porta como texto).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGEN="$(dirname "$HERE")"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/home con espacios"
cp -r "$ORIGEN" "$T/home con espacios/talent-prd"
S="$T/home con espacios/talent-prd"
# los subprocesos corren con HOME en el temporal y cwd DENTRO de la copia: nada
# puede resolver el repo de origen ni por HOME ni por directorio de trabajo
aislado() { ( cd "$S" && HOME="$T/home con espacios" bash "$@" ); }

echo "==== probar-standalone: HOME limpio con espacios, sin repo ===="

# guarda anti-falso-verde: si falta un dir, el grep de abajo daria "cero matches"
# y pasaria en silencio — la ausencia del objetivo es FALLO, no limpieza
for d in references assets scripts tests; do
  [ -d "$S/$d" ] || { mal "estructura — falta $d/ en la copia (el grep de agnosticismo seria vacuo)"; }
done
[ -f "$S/SKILL.md" ] || { mal "estructura — falta SKILL.md en la copia"; echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"; exit 1; }

# --- 0. agnosticismo: cero nombres del repo/fabrica en la superficie publicable -------
awk '/^## Paquete de fábrica$/{exit} {print}' "$S/SKILL.md" > "$T/skill-publicable.md"
hits="$(grep -rilE 'Talent Engine|talent-factory|linear|blackamp' \
  "$T/skill-publicable.md" "$S/references" "$S/assets" "$S/scripts" 2>/dev/null || true)"
if [ -n "$hits" ]; then
  mal "agnosticismo — nombres del repo de origen en superficie publicable:"
  printf '%s\n' "$hits" | sed 's/^/      | /'
else
  ok "agnosticismo — SKILL.md publicable + references + assets + scripts limpios (case-insensitive)"
fi

# --- 1. cero red en scripts -----------------------------------------------------------
if grep -rnE '\b(curl|wget|nc|ssh|scp|rsync)\b' "$S/scripts" >/dev/null 2>&1; then
  mal "red — scripts/ invoca comandos de red"
else
  ok "red — cero comandos de red en scripts/"
fi

# --- 2. ciclo funcional completo en la ruta con espacios ------------------------------
if aislado "$S/scripts/verificar-prd.sh" "$S/tests/corpus-fake/greenfield" >/dev/null 2>&1; then
  ok "funcional — verificar-prd.sh en verde sobre el corpus copiado"
else
  mal "funcional — verificar-prd.sh fallo en el HOME limpio"
fi

if aislado "$S/scripts/auditar-gaps.sh" "$S/tests/corpus-fake/completo-minimo/prd.md" >/dev/null 2>&1; then
  ok "funcional — auditar-gaps.sh cero gaps sobre el Completo copiado"
else
  mal "funcional — auditar-gaps.sh fallo en el HOME limpio"
fi

set +e
aislado "$S/scripts/auditar-gaps.sh" "$S/tests/corpus-fake/con-gaps/prd.md" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  ok "funcional — auditar-gaps.sh sigue detectando gaps (rc 1) en la ruta con espacios"
else
  mal "funcional — auditar-gaps.sh no detecto gaps (rc=$rc)"
fi

# --- 3. los probadores del propio skill corren en el HOME limpio ----------------------
# (todos menos este mismo, para no recursar sin fin)
for prob in probar-verificar.sh probar-escenarios.sh probar-invariants.sh; do
  if aislado "$S/tests/$prob" >/dev/null 2>&1; then
    ok "recursion — $prob en verde dentro del HOME limpio"
  else
    mal "recursion — $prob fallo dentro del HOME limpio"
  fi
done

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
