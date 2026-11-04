#!/usr/bin/env bash
# Resolución de la clave de Linear por las sesiones de rol de una instalación.
#
# Orden: LINEAR_API_KEY exportada > fichero de TA_OPERATION_ENV (y SOLO ese) > .env.local de la
# raíz del repo. Cubre el procedimiento bash de SKILL.md (con un curl de mentira), el cargador de
# scripts/linear-client.ts (y el bloque de dispatch que lo usa, y sus casos «clave:» del selftest),
# que batch-issues y upload-attachment lo reutilicen, y el cargador de talent-issue-craft.
#
# Ficheros sintéticos en un directorio temporal, claves FALSAS, sin red y sin Linear real. La
# salida de ningún caso puede contener una clave falsa (se comprueba con grep).
#
# PORTÁTIL: corre con cualquier Node >= 18 (el de apt de Ubuntu 24.04 es 18.19.1), sin tsx, sin
# compilador y sin red. Los casos de TypeScript los ejecuta tests/cargador-portable.cjs, que LEE el
# código de producción (.ts), recorta el trozo que se prueba, le borra los tipos y lo evalúa: no hay
# copia que pueda divergir. Si el node del sistema ejecuta TypeScript de forma nativa
# (--experimental-transform-types, Node >= 22.7), además se contrasta con el selftest REAL de
# linear-client.ts (equivalencia: los mismos casos «clave:» en verde en ambos); la capacidad se mide cargando
# un .ts mínimo, no por la bandera, y sin ella se toma la rama INFO. SKIP solo si NO HAY node.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISSUE_CRAFT="$(cd "$ROOT/../talent-issue-craft/scripts" 2>/dev/null && pwd)/issue_craft_helper.ts"
LINEAR_TS="$ROOT/scripts/linear-client.ts"
COND="$ROOT/tests/cargador-portable.cjs"
T="$(cd "$(mktemp -d)" && pwd -P)"
: "${T:?}"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
TOTAL_ESPERADO=22
TS_ESPERADOS=13   # comprobaciones que necesitan node (CLI 6 + selftest 1 + issue-craft 6)
# TS=1 marca las comprobaciones que ejecutan TypeScript vía node: solo se declaran SKIP si no hay node.
TS=0; TS_OK=0; NATIVO=0
TS_MOTIVO="node ausente en el PATH: los casos de TypeScript no se pueden medir (no son verdes)"
check() {
  local nombre="$1"; shift
  if [ "$TS" = 1 ] && [ "$TS_OK" = 0 ]; then
    skip=$((skip+1)); echo "SKIP $nombre — $TS_MOTIVO"; return 0
  fi
  if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $nombre"; fi
}
if command -v node >/dev/null 2>&1 && timeout 20 node -e 0 >/dev/null 2>&1; then
  TS_OK=1
  # Capacidad nativa (solo para la equivalencia): se mide CARGANDO un .ts con una anotación de tipo real.
  # Aceptar la bandera --experimental-transform-types no prueba nada: un node compilado sin TypeScript (el
  # paquete de la distribución) la acepta con -e y falla con ERR_NO_TYPESCRIPT solo al cargar el fichero.
  printf '%s\n' 'const x: number = 1;' > "$T/sonda.ts"
  if timeout 20 node --experimental-transform-types "$T/sonda.ts" >/dev/null 2>&1; then NATIVO=1; fi
else
  echo "AVISO: $TS_MOTIVO"
fi

command -v git >/dev/null 2>&1 || { echo "FALTA git: no se pueden montar las raíces de repo sintéticas"; exit 2; }
[ -f "$ISSUE_CRAFT" ] || { echo "FALTA $ISSUE_CRAFT"; exit 2; }
[ -f "$COND" ] || { echo "FALTA $COND"; exit 2; }

# ── Fixtures ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/home" "$T/op"
REPO="$T/raiz-con-clave"; VACIO="$T/raiz-sin-clave"
git init -q "$REPO" && git init -q "$VACIO" || { echo "git init falló"; exit 2; }
printf 'LINEAR_API_KEY=fake-repo-key\n' > "$REPO/.env.local"
printf 'OTRA=1\nLINEAR_API_KEY=fake-op-key\n' > "$T/op/operacion.env"
printf 'OTRA=1\nLINEAR_API_KEY=\n' > "$T/op/sin-clave.env"
AUSENTE="$T/op/no-existe.env"
STUB_LOG="$T/stub.log"

# curl de mentira: registra que lo llamaron y de qué clave falsa era la cabecera (nunca la imprime).
printf '%s\n' '#!/usr/bin/env bash' 'cfg=""' \
  'while [ $# -gt 0 ]; do [ "$1" = "--config" ] && cfg="$2"; shift; done' \
  'echo llamada >> "$STUB_LOG"' \
  'for n in repo op env; do grep -qF "fake-$n-key" "$cfg" && echo "usada=$n" >> "$STUB_LOG"; done' \
  "printf '{\"data\":{\"viewer\":{\"id\":\"x\",\"name\":\"n\"}}}'" > "$T/bin/curl"
chmod +x "$T/bin/curl"

# El bloque bash de SKILL.md (procedimiento de autenticación), tal cual, sin la sangría de la lista.
awk 'index($0, "REPO_ROOT=\"$(git rev-parse") > 0 { f = 1 } f { if ($0 ~ /^ *```/) exit; sub(/^   /, ""); print }' \
  "$ROOT/SKILL.md" > "$T/bloque.sh"

# Preludio solo para la equivalencia nativa: require/module (el .ts se carga como ESM).
printf '%s\n' \
  'import { createRequire } from "node:module";' \
  'globalThis.module = {};' \
  'globalThis.require = Object.assign(createRequire(import.meta.url), { main: globalThis.module });' > "$T/preludio.mjs"

sin_clave() { ! grep -q 'fake-' "$1"; }

# ── 1 · Procedimiento bash de SKILL.md ──────────────────────────────────────────────────────────
corre_bloque() { # <cwd> <salida> [VAR=valor ...]
  local cwd="$1" out="$2"; shift 2
  : > "$STUB_LOG"
  ( cd "$cwd" && env -i PATH="$T/bin:$PATH" HOME="$T/home" STUB_LOG="$STUB_LOG" "$@" bash "$T/bloque.sh" ) > "$out" 2>&1
}
bloque_positivo() { # <fuente-esperada> <cwd> [VAR=valor ...]
  local esperada="$1" cwd="$2"; shift 2
  corre_bloque "$cwd" "$T/salida" "$@" || return 1
  grep -qx "usada=$esperada" "$STUB_LOG" && [ "$(grep -c '^usada=' "$STUB_LOG")" = 1 ] && sin_clave "$T/salida"
}
bloque_negativo() { # <ruta> <variable> <cwd> [VAR=valor ...]
  local ruta="$1" variable="$2" cwd="$3"; shift 3
  if corre_bloque "$cwd" "$T/salida" "$@"; then return 1; fi
  [ ! -s "$STUB_LOG" ] && grep -qF -- "$ruta" "$T/salida" && grep -qF -- "$variable" "$T/salida" && sin_clave "$T/salida"
}
check "SKILL.md: bloque extraído" test -s "$T/bloque.sh"
check "SKILL.md bash: con TA_OPERATION_ENV toma la clave de ese fichero aunque la raíz tenga otra" \
  bloque_positivo op "$REPO" TA_OPERATION_ENV="$T/op/operacion.env"
check "SKILL.md bash: sin TA_OPERATION_ENV toma la de .env.local de la raíz" bloque_positivo repo "$REPO"
check "SKILL.md bash: LINEAR_API_KEY exportada gana" \
  bloque_positivo env "$REPO" LINEAR_API_KEY=fake-env-key TA_OPERATION_ENV="$AUSENTE"
check "SKILL.md bash: TA_OPERATION_ENV a un fichero que falta → error con ruta y variable, sin llamada ni caída a la raíz" \
  bloque_negativo "$AUSENTE" TA_OPERATION_ENV "$REPO" TA_OPERATION_ENV="$AUSENTE"
check "SKILL.md bash: el fichero existe pero no tiene LINEAR_API_KEY= → error con ruta y variable, sin llamada" \
  bloque_negativo "$T/op/sin-clave.env" TA_OPERATION_ENV "$REPO" TA_OPERATION_ENV="$T/op/sin-clave.env"
check "SKILL.md bash: ninguna fuente → error con ruta y variable, sin llamada" \
  bloque_negativo "$VACIO/.env.local" LINEAR_API_KEY "$VACIO"

# ── 2 · scripts/linear-client.ts: cargador, bloque de dispatch y casos «clave:» del selftest ─────
# Todo con el conductor portable (node >= 18): cwd y entorno reales del proceso, sin fetch ni cliente.
TS=1
corre_cli() { # <cwd> [VAR=valor ...]  -> stdout del conductor en $T/salida, stderr en $T/cli.err
  local cwd="$1"; shift
  ( cd "$cwd" && env -i PATH="$PATH" HOME="$T/home" "$@" node "$COND" cli "$LINEAR_TS" "$ISSUE_CRAFT" ) > "$T/salida" 2> "$T/cli.err"
}
cli_positivo() { # <fuente-esperada> <cwd> [VAR=valor ...]
  local esperada="$1" cwd="$2"; shift 2
  corre_cli "$cwd" "$@"
  [ "$(cat "$T/salida")" = "OK $esperada" ] && sin_clave "$T/salida" && sin_clave "$T/cli.err"
}
cli_negativo() { # <ruta> <variable> <cwd> [VAR=valor ...]   (el dispatch sale con 1 y el mensaje nombra ruta y variable)
  local ruta="$1" variable="$2" cwd="$3"; shift 3
  corre_cli "$cwd" "$@"
  case "$(cat "$T/salida")" in "EXIT1 "*) ;; *) return 1 ;; esac
  grep -qF -- "$ruta" "$T/salida" && grep -qF -- "$variable" "$T/salida" && sin_clave "$T/salida" && sin_clave "$T/cli.err"
}
selftest_cli() {
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$T/home" node "$COND" selftest "$LINEAR_TS" "$ISSUE_CRAFT" ) > "$T/salida" 2> "$T/cli.err" || return 1
  [ "$(grep -c '^PASS clave:' "$T/salida")" = 7 ] && grep -q '^SELFTEST: PASS=7 FAIL=0$' "$T/salida" \
    && ! grep -q 'clave-falsa' "$T/salida" && sin_clave "$T/salida" && sin_clave "$T/cli.err"
}
check "linear-client CLI: con TA_OPERATION_ENV toma la clave de ese fichero aunque la raíz tenga otra" \
  cli_positivo op "$REPO" TA_OPERATION_ENV="$T/op/operacion.env"
check "linear-client CLI: sin TA_OPERATION_ENV toma la de .env.local de la raíz" cli_positivo repo "$REPO"
check "linear-client CLI: LINEAR_API_KEY exportada gana" \
  cli_positivo env "$REPO" LINEAR_API_KEY=fake-env-key TA_OPERATION_ENV="$AUSENTE"
check "linear-client CLI: TA_OPERATION_ENV a un fichero que falta → error con ruta y variable, sin red ni caída a la raíz" \
  cli_negativo "$AUSENTE" TA_OPERATION_ENV "$REPO" TA_OPERATION_ENV="$AUSENTE"
check "linear-client CLI: el fichero existe pero no tiene LINEAR_API_KEY= → error con ruta y variable, sin red" \
  cli_negativo "$T/op/sin-clave.env" TA_OPERATION_ENV "$REPO" TA_OPERATION_ENV="$T/op/sin-clave.env"
check "linear-client CLI: ninguna fuente → error con ruta y variable, sin red" \
  cli_negativo "$VACIO/.env.local" LINEAR_API_KEY "$VACIO"
check "linear-client selftest: los 7 casos de la resolución de la clave en verde" selftest_cli

# ── 3 · Los demás scripts del skill reutilizan el cargador, sin duplicarlo ──────────────────────
TS=0
reutiliza() { # <script>
  local f="$ROOT/scripts/$1"
  grep -Eq 'import \{[^}]*loadApiKey[^}]*\} from "\./linear-client"' "$f" && ! grep -q 'process\.env\.LINEAR_API_KEY' "$f"
}
check "batch-issues.ts reutiliza loadApiKey de linear-client y no lee el entorno por su cuenta" reutiliza batch-issues.ts
check "upload-attachment.ts reutiliza loadApiKey de linear-client y no lee el entorno por su cuenta" reutiliza upload-attachment.ts

# ── 4 · Cargador de talent-issue-craft (sube desde el cwd si no hay TA_OPERATION_ENV) ───────────
TS=1
issue_craft() { # <cwd> <env-json>
  ( cd "$1" && env -i PATH="$PATH" HOME="$T/home" node "$COND" issue "$LINEAR_TS" "$ISSUE_CRAFT" "$1" "$2" 2> "$T/ic.err" )
}
# stderr del conductor (también en el camino de éxito) no puede llevar ninguna clave falsa.
ic_positivo() { # <fuente-esperada> <cwd> <env-json>
  local salida; salida="$(issue_craft "$2" "$3")"
  [ "$salida" = "OK $1" ] && sin_clave "$T/ic.err"
}
ic_negativo() { # <ruta> <variable> <cwd> <env-json>
  local salida; salida="$(issue_craft "$3" "$4")"
  sin_clave "$T/ic.err" || return 1
  case "$salida" in "ERR "*) ;; *) return 1 ;; esac
  case "$salida" in *"$1"*) ;; *) return 1 ;; esac
  case "$salida" in *"$2"*) ;; *) return 1 ;; esac
  case "$salida" in *fake-*) return 1 ;; esac
  return 0
}
check "issue-craft: con TA_OPERATION_ENV toma la clave de ese fichero aunque el cwd tenga otra" \
  ic_positivo op "$REPO" "{\"TA_OPERATION_ENV\":\"$T/op/operacion.env\"}"
check "issue-craft: sin TA_OPERATION_ENV sube desde el cwd hasta el .env.local" ic_positivo repo "$REPO" '{}'
check "issue-craft: LINEAR_API_KEY exportada gana" \
  ic_positivo env "$REPO" "{\"LINEAR_API_KEY\":\"fake-env-key\",\"TA_OPERATION_ENV\":\"$AUSENTE\"}"
check "issue-craft: TA_OPERATION_ENV a un fichero que falta → error con ruta y variable, sin caer al cwd" \
  ic_negativo "$AUSENTE" TA_OPERATION_ENV "$REPO" "{\"TA_OPERATION_ENV\":\"$AUSENTE\"}"
check "issue-craft: el fichero existe pero no tiene LINEAR_API_KEY= → error con ruta y variable" \
  ic_negativo "$T/op/sin-clave.env" TA_OPERATION_ENV "$REPO" "{\"TA_OPERATION_ENV\":\"$T/op/sin-clave.env\"}"
ic_directorio() { # TA_OPERATION_ENV apunta a un directorio: mensaje claro, no el EISDIR crudo
  local salida; salida="$(issue_craft "$REPO" "{\"TA_OPERATION_ENV\":\"$T/op\"}")"
  case "$salida" in *EISDIR*) return 1 ;; esac
  case "$salida" in *"no es un fichero"*) ;; *) return 1 ;; esac
  ic_negativo "$T/op" TA_OPERATION_ENV "$REPO" "{\"TA_OPERATION_ENV\":\"$T/op\"}"
}
check "issue-craft: TA_OPERATION_ENV apunta a un directorio → error claro con ruta y variable (no EISDIR crudo)" ic_directorio

# ── 5 · Equivalencia con el TypeScript NATIVO (solo si este node lo ejecuta; solo puede añadir fallos) ──
# El selftest real de linear-client.ts debe dar en verde los mismos casos «clave:» que el conductor portable.
if [ "$TS_OK" = 1 ] && [ "$NATIVO" = 1 ]; then
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$T/home" node --experimental-transform-types --import "file://$T/preludio.mjs" \
      "$LINEAR_TS" --action selftest ) > "$T/nativo.out" 2>&1
  nativo_rc=$?
  ( cd "$REPO" && env -i PATH="$PATH" HOME="$T/home" node "$COND" selftest "$LINEAR_TS" "$ISSUE_CRAFT" ) > "$T/portable.out" 2>/dev/null
  if [ "$nativo_rc" = 0 ] && diff <(grep '^PASS clave:' "$T/nativo.out") <(grep '^PASS clave:' "$T/portable.out") >/dev/null \
     && [ "$(grep -c '^PASS clave:' "$T/nativo.out")" = 7 ]; then
    echo "EQUIV selftest nativo == conductor portable (7 casos «clave:»)"
  else
    fail=$((fail+1)); echo "FAIL equivalencia: el selftest nativo de linear-client.ts y el conductor portable no coinciden (rc=$nativo_rc)"
  fi
elif [ "$TS_OK" = 1 ]; then
  echo "INFO: este node no ejecuta TypeScript nativo; la equivalencia con el selftest real se mide en un Node >= 22.7 (los casos de arriba SÍ se han ejecutado, con el conductor portable)"
fi

# ── Resultado: PASS, FAIL y SKIP se cuentan por separado; la omisión nunca es verde silencioso ────
echo "RESULTADO: PASS=$pass FAIL=$fail SKIP=$skip TOTAL_ESPERADO=$TOTAL_ESPERADO"
if [ "$skip" != 0 ]; then
  echo "SKIP=$skip: los casos de TypeScript NO se han medido en esta máquina ($TS_MOTIVO)"
fi
# SKIP solo puede ser 0 o exactamente los casos de TypeScript (sin node): cualquier otra omisión es un fallo.
[ "$fail" = 0 ] && [ $((pass + skip)) = "$TOTAL_ESPERADO" ] && { [ "$skip" = 0 ] || [ "$skip" = "$TS_ESPERADOS" ]; }
