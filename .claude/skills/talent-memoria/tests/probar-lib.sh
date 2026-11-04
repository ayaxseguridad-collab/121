#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-lib.sh — unitarios de lib.sh con ASERCION DE VALOR (no solo rc):
# tm_s3_desc/tm_s3_estado/tm_s3_ok por formato (item 3, S3 estricto).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
# shellcheck source=/dev/null
. "$SKILL/scripts/00-config.sh"
# shellcheck source=/dev/null
. "$SKILL/scripts/lib.sh"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }

echo "==== probar-lib: tm_s3_desc/tm_s3_estado/tm_s3_ok (asercion de VALOR) ===="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

nota() { # nota <fichero> <linea-description-completa>
  printf -- '---\nname: x\n%s\n---\ncontenido.\n' "$2" > "$T/$1"
}

# 1. quoted + bracket, ANULADA (formato de nota-historica-anulada-bien.md)
nota "f1.md" 'description: "[ANULADA 2026-07-27] → sucesora: decision-gestor-paquetes — usabamos npm"'
v="$(tm_s3_estado "$T/f1.md")"
[ "$v" = "ANULADA" ] && ok "formato 1 (quoted+bracket ANULADA): token='$v'" || mal "formato 1: token='$v' (esperaba ANULADA)"
tm_s3_ok "$T/f1.md" && ok "formato 1: tm_s3_ok=true" || mal "formato 1: tm_s3_ok deberia ser true"

# 2. quoted + bracket, ALIAS-STUB (formato de politica-commits-notas.md)
nota "f2.md" 'description: "[ALIAS-STUB 2026-07-27] → sucesora: politica-commits — consolidada"'
v="$(tm_s3_estado "$T/f2.md")"
[ "$v" = "ALIAS-STUB" ] && ok "formato 2 (quoted+bracket ALIAS-STUB): token='$v'" || mal "formato 2: token='$v' (esperaba ALIAS-STUB)"

# 3. sin comillas ni corchete, token directo (formato del descriptor-1a-linea-blanco)
nota "f3.md" 'description: ANULADA — indentamos con tabs'
v="$(tm_s3_estado "$T/f3.md")"
[ "$v" = "ANULADA" ] && ok "formato 3 (sin comillas/corchete): token='$v'" || mal "formato 3: token='$v' (esperaba ANULADA)"

# 4. PENDIENTE quoted+bracket (formato de references/02 paso 5)
nota "f4.md" 'description: "[PENDIENTE 2026-07-27] conflicto sin adjudicar: politica de ramas"'
v="$(tm_s3_estado "$T/f4.md")"
[ "$v" = "PENDIENTE" ] && ok "formato 4 (PENDIENTE quoted+bracket): token='$v'" || mal "formato 4: token='$v' (esperaba PENDIENTE)"

# 5. NEGATIVO — sin estado (description vigente, plana)
nota "f5.md" 'description: indentamos con tabs'
v="$(tm_s3_estado "$T/f5.md")"
[ -z "$v" ] && ok "negativo: description sin estado → token vacio" || mal "negativo: token='$v' (esperaba vacio)"
tm_s3_ok "$T/f5.md" && mal "negativo: tm_s3_ok deberia ser false" || ok "negativo: tm_s3_ok=false"

# 6. REGRESION (el bug que cierra el item 3) — el estado aparece de PASADA, no
# abriendo: "...la anterior quedo ANULADA en mayo". Antes del fix, grep -qE
# "$TM_ESTADOS" en cualquier sitio del bloque daba VERDE (falso); ahora debe
# dar vacio/false porque el token no ABRE el contenido efectivo.
nota "f6.md" 'description: politica vigente de ramas; la anterior quedo ANULADA en mayo'
v="$(tm_s3_estado "$T/f6.md")"
[ -z "$v" ] && ok "regresion: estado de pasada (no abre) → token vacio" || mal "regresion: token='$v' (esperaba vacio: el estado NO abre)"
tm_s3_ok "$T/f6.md" && mal "regresion: tm_s3_ok deberia ser false (S3 sin abrir)" || ok "regresion: tm_s3_ok=false"

# 7. estado en OTRO campo (status:), description limpio → S3 sigue sin estado
nota "f7.md" 'description: indentamos con tabs
status: ANULADA'
v="$(tm_s3_estado "$T/f7.md")"
[ -z "$v" ] && ok "otro campo (status:): S3 no lo cuenta, token vacio" || mal "otro campo: token='$v' (esperaba vacio)"

# ============================================================================
# TABLA DE VERDAD DE FECHA (tm_tiene_fecha, item 4 fix 2b / MAY-01 y bis):
# rangos validos (mes 01-12, dia 01-31) Y delimitacion contra digito adyacente.
# ============================================================================

fecha_caso() { # fecha_caso <nombre> <contenido-cuerpo> <rc-esperado>
  printf -- '---\nname: x\ndescription: x\n---\n%s\n' "$2" > "$T/fx.md"
  if bash -c '. "'"$SKILL"'/scripts/00-config.sh"; . "'"$SKILL"'/scripts/lib.sh"; tm_tiene_fecha "$1"' _ "$T/fx.md"; then rc=0; else rc=1; fi
  [ "$rc" -eq "$3" ] && ok "fecha: $1 (rc=$rc)" || mal "fecha: $1 (rc=$rc, esperaba $3)"
}

# positivos
fecha_caso "ISO en el cuerpo" "vencio el 2026-07-27 sin falta." 0
fecha_caso "compacta en el cuerpo" "vencio el 20260727 sin falta." 0
fecha_caso "ISO pegada a punto" "vencio el 2026-07-27." 0
fecha_caso "ISO pegada a parentesis" "revisar (2026-07-27) antes de seguir." 0
fecha_caso "ISO pegada a em-dash" "vencio el 2026-07-27—ya no aplica." 0
fecha_caso "sin fecha en NINGUN sitio (negativo de control)" "contenido sin fecha alguna." 1

# fecha SOLO en el basename (autodeteccion via basename, no via cuerpo)
printf -- '---\nname: x\ndescription: x\n---\ncontenido sin fecha en el cuerpo.\n' > "$T/nota-20260727.md"
bash -c '. "'"$SKILL"'/scripts/00-config.sh"; . "'"$SKILL"'/scripts/lib.sh"; tm_tiene_fecha "$1"' _ "$T/nota-20260727.md" \
  && ok "fecha: en el basename (nota-20260727.md)" || mal "fecha: basename no detectado"

# negativos: rango invalido
fecha_caso "rango invalido ISO (mes 00)" "> ANULADA 2026-00-39 — motivo." 1
fecha_caso "rango invalido compacta (mes 00)" "> ANULADA 20260039 — motivo." 1
fecha_caso "rango invalido ISO (mes 13)" "> ANULADA 2026-13-01 — motivo." 1
fecha_caso "rango invalido ISO (dia 32)" "> ANULADA 2026-12-32 — motivo." 1

# negativos: sin delimitar (fecha valida como SUBCADENA de una invalida)
fecha_caso "sin delimitar ISO (sufijo digito)" "> ANULADA 2026-12-310 — motivo." 1
fecha_caso "sin delimitar ISO (prefijo digito)" "> ANULADA 12026-12-31 — motivo." 1
fecha_caso "sin delimitar compacta (sufijo digito)" "> ANULADA 202612310 — motivo." 1
fecha_caso "sin delimitar compacta (prefijo digito)" "> ANULADA 120261231 — motivo." 1

# ============================================================================
# tm_no_symlinks defensa en profundidad (item 6): tm_manifest y tm_git_baseline
# fallan cerrado ante un symlink, no solo verificar.sh/salvaguarda.sh a nivel de
# script. tm_die hace exit 2 DENTRO del subshell de "$(...)"; se captura con
# set +e alrededor de la asignacion (el exit del subshell no mata este test).
# ============================================================================
if command -v ln >/dev/null 2>&1; then
  mkdir -p "$T/symlink-dir"
  printf 'x\n' > "$T/symlink-dir/nota.md"
  ln -s /etc/hostname "$T/symlink-dir/enlace.md"

  set +e
  SAL_M="$(tm_manifest "$T/symlink-dir" 2>&1)"; RC_M=$?
  set -e
  if [ "$RC_M" -eq 2 ] && printf '%s' "$SAL_M" | grep -qF "symlinks no soportados"; then
    ok "tm_manifest sobre dir con symlink → rc 2 (fail-closed)"
  else
    mal "tm_manifest NO fallo cerrado ante symlink (rc=$RC_M)"
  fi

  set +e
  SAL_G="$(tm_git_baseline "$T/symlink-dir" 2>&1)"; RC_G=$?
  set -e
  if [ "$RC_G" -eq 2 ] && printf '%s' "$SAL_G" | grep -qF "symlinks no soportados"; then
    ok "tm_git_baseline sobre dir con symlink → rc 2 (fail-closed)"
  else
    mal "tm_git_baseline NO fallo cerrado ante symlink (rc=$RC_G)"
  fi
else
  echo "  OMIT  tm_manifest/tm_git_baseline con symlink (ln no disponible)"
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
