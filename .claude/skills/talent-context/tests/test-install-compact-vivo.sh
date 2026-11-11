#!/usr/bin/env bash
# Dobles del CLI, settings temporales y suma del árbol en negativos y --check.
# shellcheck disable=SC2016,SC2034 # check evalúa las aserciones.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INS="$ROOT/scripts/install-compact-vivo.sh"; REG="$ROOT/scripts/compact-vivo-inscribir.sh"
TW="$(mktemp -d)"; trap 'rm -rf "$TW"' EXIT
ok=0; ko=0
check() { if eval "$2"; then ok=$((ok+1)); printf 'PASS %s\n' "$1"; else ko=$((ko+1)); printf 'FAIL %s\n' "$1"; fi; }
mkdir -p "$TW/bin289" "$TW/bin288" "$TW/binbad" "$TW/binrc7" "$TW/binnone"
printf '#!/bin/sh\necho "2.1.289 (Claude Code)"\n' > "$TW/bin289/claude"
printf '#!/bin/sh\necho "2.1.288 (Claude Code)"\n' > "$TW/bin288/claude"
printf '#!/bin/sh\necho "ilegible"\n' > "$TW/binbad/claude"
printf '#!/bin/sh\necho "2.1.289 (Claude Code)"\nexit 7\n' > "$TW/binrc7/claude"
chmod +x "$TW"/bin*/claude
for b in jq sort cmp mktemp cp mv chmod date dirname grep head tail tr cat sed bash rm mkdir realpath readlink stat wc; do
  p="$(command -v "$b")"; ln -s "$p" "$TW/binnone/$b"
done
export COMPACT_VIVO_INCLUIR="$TW/config/incluir"
export COMPACT_VIVO_GUARDA_B="$TW/config/guarda-b"
inst() { local v="$1"; shift; PATH="$TW/$v:$TW/binnone" HOME="$TW/home" bash "$INS" "$@"; }
# Suma de nombres, permisos y contenido; no incluye mtime ni los logs de las pruebas.
suma() { find "$1" -printf '%P %m %y\n' | sort; find "$1" -type f -exec sha256sum {} + | sort; }
S="$TW/s1/settings.json"; mkdir -p "$TW/s1"
printf '{"otra":42,"env":{"AJENA":"x"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo previo"}]}]}}\n' > "$S"
inst bin289 --puesto ceo --settings "$S" > "$TW/o" 2> "$TW/e"; rc=$?
check "C9 ceo rc0" '[ "$rc" = 0 ]'
check "C9 ceo 300000/60" 'jq -e ".env.CLAUDE_CODE_AUTO_COMPACT_WINDOW==\"300000\" and .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE==\"60\"" "$S" >/dev/null'
check "C9 ajenos conservados" 'jq -e ".otra==42 and .env.AJENA==\"x\" and .hooks.Stop[0].hooks[0].command==\"echo previo\"" "$S" >/dev/null'
check "C9 seis eventos" '[ "$(jq ".hooks | length" "$S")" = 6 ]'
check "C9 timeouts 10/20" 'jq -e ".hooks.PostCompact[-1].hooks[0].timeout==20 and .hooks.PreCompact[-1].hooks[0].timeout==10" "$S" >/dev/null'
check "C9 copia 0755 idéntica" '[ "$(stat -c %a "$TW/s1/compact-vivo.sh")" = 755 ] && cmp -s "$ROOT/hooks/compact-vivo.sh" "$TW/s1/compact-vivo.sh"'
check "C9 copia previa única" '[ "$(find "$TW/s1" -name "settings.json.bak-*" | wc -l)" = 1 ]'
check "C9 lista 0600" '[ "$(stat -c %a "$COMPACT_VIVO_INCLUIR")" = 600 ]'
antes="$(suma "$TW/s1")"
inst bin289 --puesto ceo --settings "$S" > "$TW/o" 2> "$TW/e"; rc=$?
check "C9 idempotente árbol y rc0" '[ "$rc" = 0 ] && [ "$antes" = "$(suma "$TW/s1")" ] && grep -qx ESTADO=sin-cambios "$TW/o"'
for spec in pm:300000 torre:200000 estacion:200000 canal:200000; do
  rol="${spec%:*}"; want="${spec#*:}"; s="$TW/$rol/settings.json"
  inst bin289 --puesto "$rol" --settings "$s" > "$TW/o" 2> "$TW/e"; rc=$?
  check "C9 $rol defaults" '[ "$rc" = 0 ] && [ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW "$s")" = "$want" ]'
  antes="$(suma "$TW/$rol")/$(suma "$TW/config")"
  inst bin289 --puesto "$rol" --settings "$s" --check > "$TW/o" 2> "$TW/e"; rc=$?
  check "C13 $rol check conforme y solo lectura" '[ "$rc" = 0 ] && grep -qx ESTADO=conforme "$TW/o" && [ "$antes" = "$(suma "$TW/$rol")/$(suma "$TW/config")" ]'
  printf 'FIXTURE %s\n' "$rol"; cat "$TW/o"
done
s="$TW/override/settings.json"
inst bin289 --puesto canal --settings "$s" --ventana 400000 --pct 55 > "$TW/o" 2> "$TW/e"; rc=$?
check "C9 override de perfil" '[ "$rc" = 0 ] && [ "$(jq -r .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW "$s")/$(jq -r .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "$s")" = 400000/55 ]'
# Negativos preflight: settings, hook, backups y lista permanecen idénticos.
mkdir -p "$TW/neg"
export COMPACT_VIVO_INCLUIR="$TW/neg/incluir"
neg() {
  local nombre="$1" esperado="$2" version="$3"; shift 3
  local antes rc
  antes="$(suma "$TW/neg")"
  inst "$version" --puesto canal --settings "$TW/neg/settings.json" "$@" > "$TW/o" 2> "$TW/e"; rc=$?
  check "$nombre rc$esperado NADA escrito" '[ "$rc" = "$esperado" ] && [ "$antes" = "$(suma "$TW/neg")" ]'
  printf 'NEGATIVO %s rc=%s: ' "$nombre" "$rc"; cat "$TW/e"
}
neg 'C10 ventana 60000' 6 bin289 --ventana 60000
CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS=80000 neg 'C10 Read 80000 ventana 200000' 6 bin289 --ventana 200000
MAX_MCP_OUTPUT_TOKENS=80000 neg 'C10 MCP 80000' 6 bin289
BASH_MAX_OUTPUT_LENGTH=240003 neg 'C10 Bash dividido redondeo' 6 bin289
neg 'C10 pct0' 6 bin289 --pct 0
neg 'C10 pct101' 6 bin289 --pct 101
neg 'C10 ventana1000001' 6 bin289 --ventana 1000001
neg 'C12 versión menor' 4 bin288
neg 'C12 versión ilegible' 4 binbad
neg 'C12 Claude ausente' 4 binnone
neg 'M1 Claude versión válida rc7' 4 binrc7
antes="$(suma "$TW/neg")"
inst binrc7 --puesto canal --settings "$TW/neg/settings.json" --check > "$TW/o" 2> "$TW/e"; rc=$?
check "M1 check limpio rc2 NADA escrito" '[ "$rc" = 2 ] && grep -qx ESTADO=diferencias "$TW/o" && [ "$antes" = "$(suma "$TW/neg")" ]'
antes="$(suma "$TW/s1")/$(suma "$TW/config")"
COMPACT_VIVO_INCLUIR="$TW/config/incluir" inst binrc7 --puesto ceo --settings "$S" --check > "$TW/o" 2> "$TW/e"; rc=$?
check "M1 check instalado rc2 solo lectura" '[ "$rc" = 2 ] && grep -qx ESTADO=diferencias "$TW/o" && [ "$antes" = "$(suma "$TW/s1")/$(suma "$TW/config")" ]'
printf '{"env":{"CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS":"80000"}}' > "$TW/neg/settings.json"
neg 'C10 límite en settings' 6 bin289
printf '{"hooks":false}' > "$TW/neg/settings.json"
neg 'env/hooks inválidos' 1 bin289
printf '{rota' > "$TW/neg/settings.json"
neg 'JSON inválido' 1 bin289
antes="$(suma "$TW/neg")"
inst bin289 --puesto canal --settings "$TW/neg/settings.json" --check > "$TW/o" 2> "$TW/e"; rc=$?
check "C13 JSON roto rc2 siete claves solo lectura" '[ "$rc" = 2 ] && [ "$antes" = "$(suma "$TW/neg")" ] && [ "$(grep -c "=" "$TW/o")" = 7 ]'
# Datos sensibles: env sí, hooks/lista no (la escritura de env es el contrato).
mkdir "$TW/sensible"; export COMPACT_VIVO_INCLUIR="$TW/sensible/incluir"
inst bin289 --puesto canal --settings "$TW/sensible/settings.json" --datos-sensibles si > "$TW/o" 2> "$TW/e"; rc=$?
check "C11 rc5 solo env" '[ "$rc" = 5 ] && jq -e ".env.CLAUDE_CODE_AUTO_COMPACT_WINDOW==\"200000\" and (.hooks==null)" "$TW/sensible/settings.json" >/dev/null && [ ! -e "$TW/sensible/compact-vivo.sh" ] && [ ! -e "$COMPACT_VIVO_INCLUIR" ]'
check "C11 mensaje condición" 'grep -q "redacción de importes probada + GO del lead" "$TW/e"'
export COMPACT_VIVO_INCLUIR="$TW/config/incluir"
antes="$(suma "$TW/s1")"
inst binnone --puesto ceo --settings "$S" --check > "$TW/o" 2> "$TW/e"; rc=$?
check "C13 check sin Claude rc2 solo lectura" '[ "$rc" = 2 ] && [ "$antes" = "$(suma "$TW/s1")" ] && grep -qx ESTADO=diferencias "$TW/o"'
inst bin289 --puesto ceo --settings "$S" --check > "$TW/o" 2> "$TW/e"; rc=$?
check "C13 salida todas claves" '[ "$rc" = 0 ] && [ "$(grep -cE "^(hooks|ventana|pct|lista_blanca|sesiones_inscritas|guarda_b|ESTADO)=" "$TW/o")" = 7 ]'
for key in ausente no-listada; do
  export COMPACT_VIVO_INCLUIR="$TW/config/$key"
  antes="$(suma "$TW/config")"
  inst bin289 --puesto ceo --settings "$S" --check > "$TW/o" 2> "$TW/e"; rc=$?
  check "C13 lista $key rc2 sin escrituras" '[ "$rc" = 2 ] && [ "$antes" = "$(suma "$TW/config")" ] && grep -qx lista_blanca=ausente "$TW/o"'
done
export COMPACT_VIVO_INCLUIR="$TW/registro/incluir"
bash "$REG" alta ABC; bash "$REG" alta ABC; bash "$REG" alta DEF
check "registro alta sin duplicados 0600" '[ "$(cat "$COMPACT_VIVO_INCLUIR")" = "$(printf "ABC\nDEF")" ] && [ "$(stat -c %a "$COMPACT_VIVO_INCLUIR")" = 600 ]'
bash "$REG" baja ABC
check "registro baja y lista" '[ "$(bash "$REG" lista)" = DEF ]'
bash "$REG" alta ../escape > "$TW/o" 2> "$TW/e"; rc=$?
check "registro rechaza traversal" '[ "$rc" = 1 ] && [ "$(cat "$COMPACT_VIVO_INCLUIR")" = DEF ]'
mkdir -p "$TW/ln/real"; printf '{"x":1}' > "$TW/ln/real/s.json"; ln -s real/s.json "$TW/ln/settings.json"
inst bin289 --puesto canal --settings "$TW/ln/settings.json" > "$TW/o" 2> "$TW/e"; rc=$?
check "C9 enlace de settings conservado" '[ "$rc" = 0 ] && [ -L "$TW/ln/settings.json" ] && [ -x "$TW/ln/compact-vivo.sh" ] && jq -e ".x==1 and .hooks.Stop!=null" "$TW/ln/real/s.json" >/dev/null'
# M3: ejecutar SOLO el bloque real agregado con hijos sintéticos, sin recursión.
sed -n '/^compact_log=/,/^\[ "$install_rc" = 0 \]/p' "$ROOT/tests/run-tests.sh" > "$TW/agregado.sh"
mkdir -p "$TW/hijos" "$TW/agregado-logs"
cat > "$TW/hijos/test-compact-vivo.sh" <<'HIJO'
#!/usr/bin/env bash
case "$0" in *test-install*) n=54 ;; *) n=187 ;; esac
case "$AGREGADO_CASO" in vacio) exit 0 ;; insuficiente) n=1 ;; esac
for ((i=0; i<n; i++)); do printf 'PASS caso-%s\n' "$i"; done
case "$AGREGADO_CASO" in
  sin-resumen) exit 0 ;;
  discordante) printf '%s PASS · 0 FAIL\n' "$((n+1))" ;;
  duplicado) printf '%s PASS · 0 FAIL\n%s PASS · 0 FAIL\n' "$n" "$n" ;;
  skip) printf 'SKIP caso omitido\n%s PASS · 0 FAIL\n' "$n" ;;
  fallo) printf 'FAIL defecto\n%s PASS · 1 FAIL\n' "$n" ;;
  *) printf '%s PASS · 0 FAIL\n' "$n" ;;
esac
[ "$AGREGADO_CASO" != rc-no-cero ]
HIJO
cp "$TW/hijos/test-compact-vivo.sh" "$TW/hijos/test-install-compact-vivo.sh"
for caso in vacio sin-resumen duplicado discordante insuficiente skip fallo rc-no-cero valido; do
  AGREGADO_CASO="$caso" AGREGADO_HIJOS="$TW/hijos" AGREGADO_LOGS="$TW/agregado-logs" bash -c '
    HERE="$AGREGADO_HIJOS"; TW="$AGREGADO_LOGS"
    PASS=0; FAIL=0
    ok() { PASS=$((PASS+1)); }; bad() { FAIL=$((FAIL+1)); }
    . "$1"
    [ "$FAIL" = 0 ]
  ' prueba "$TW/agregado.sh" > "$TW/agregado-salida" 2>&1; rc=$?
  esperado=1; [ "$caso" != valido ] || esperado=0
  check "M3 agregado $caso rc$esperado" '[ "$rc" = "$esperado" ]'
done
printf '\n%s PASS · %s FAIL\n' "$ok" "$ko"; [ "$ko" = 0 ]
