#!/usr/bin/env bash
# run-tests.sh — Tests HERMÉTICOS de las funciones puras de talent-context.
# Sin tmux, sin red, sin DB: alimentan capturas sintéticas por stdin y comprueban el contrato
# (parseo ctx% fail-closed, umbral 0/2/3, ghost vs cola real). `bash tests/run-tests.sh` -> exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"
WATCH="$ROOT/scripts/ctx-watch.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# esc real para construir capturas con ANSI (ghost dim = \e[2m … \e[22m)
E="$(printf '\033')"

# assert_eq <nombre> <esperado> <obtenido>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }
# assert_rc <nombre> <esperado_rc> <obtenido_rc>
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (rc esperado=$2 obtenido=$3)"; fi; }

printf '== tc_ctx_pct ==\n'
assert_eq "ctx simple 42%"        "42" "$(printf 'ctx: 42%%\n' | tc_ctx_pct)"
assert_eq "ctx toma el ULTIMO"    "88" "$(printf 'ctx: 5%% ... luego\nctx: 88%%\n' | tc_ctx_pct)"
assert_eq "ctx con ANSI en barra" "63" "$(printf '%s[2mctx: 63%%%s[0m\n' "$E" "$E" | tc_ctx_pct)"
out="$(printf 'pane sin barra de contexto\n' | tc_ctx_pct)"; rc=$?
assert_rc "ctx ausente -> rc1 UNKNOWN" "1" "$rc"
assert_eq "ctx ausente -> stdout vacio" "" "$out"

printf '== tc_ctx_over (umbral 60) ==\n'
printf 'ctx: 59%%\n' | tc_ctx_over 60 >/dev/null; assert_rc "59<60 -> rc0"  "0" "$?"
printf 'ctx: 60%%\n' | tc_ctx_over 60 >/dev/null; assert_rc "60>=60 -> rc2" "2" "$?"
printf 'ctx: 91%%\n' | tc_ctx_over 60 >/dev/null; assert_rc "91>=60 -> rc2" "2" "$?"
printf 'sin barra\n'  | tc_ctx_over 60 >/dev/null; assert_rc "ilegible -> rc3 fail-closed" "3" "$?"

printf '== tc_input_state (ghost vs cola real) ==\n'
# cola real: frase en brillo pleno (sin dim)
assert_eq "cola real -> queued" "queued" \
  "$(printf 'algo\nPress up to edit queued messages\n> \n' | tc_input_state)"
# ghost: la frase iría en dim; un composer con solo autocomplete dim clasifica ghost
assert_eq "solo ghost dim -> ghost" "ghost" \
  "$(printf '> %s[2m/exit%s[22m\n' "$E" "$E" | tc_input_state)"
# texto real pendiente en el composer
assert_eq "texto real -> text" "text" \
  "$(printf '> continuemos con el fix\n' | tc_input_state)"
# composer vacio
assert_eq "vacio -> empty" "empty" \
  "$(printf '> \n' | tc_input_state)"
# regresion CODE-GATE r2 Mayor 1: composer vacio con caja COMPLETA (borde inferior + barra de
# estado) NO debe colarse como 'text' — tc_composer_text corta en la primera linea no bordeada.
assert_eq "vacio con borde+barra -> empty (no false-positive text)" "empty" \
  "$(printf '│ > │\n╰────╯\n? for shortcuts · opus · ctx: 72%%\n' | tc_input_state)"
# regresion: texto real en linea de CONTINUACION bordeada (multilinea) sigue detectando 'text'
# tras el corte por borde inferior/barra (guarda contra romper la deteccion legitima al arreglar
# el falso positivo de arriba).
assert_eq "texto real multilinea bordeado -> text" "text" \
  "$(printf '│ > algo real                    │\n│ mas texto                      │\n╰──────────────────────────────╯\n? for shortcuts · ctx: 40%%\n' | tc_input_state)"

printf '== tc_strip_ansi / tc_strip_ghost ==\n'
assert_eq "strip_ansi limpia SGR" "hola" \
  "$(printf '%s[2mhola%s[0m\n' "$E" "$E" | tc_strip_ansi)"
assert_eq "strip_ghost quita tramo dim" "" \
  "$(printf '%s[2m/exit%s[22m\n' "$E" "$E" | tc_strip_ghost | tr -d '[:space:]')"

printf '== ctx-watch.sh --stdin ==\n'
printf 'ctx: 72%%\n' | bash "$WATCH" --stdin --threshold 60 >/dev/null 2>&1; assert_rc "watch 72>=60 -> rc2" "2" "$?"
printf 'ctx: 30%%\n' | bash "$WATCH" --stdin --threshold 60 >/dev/null 2>&1; assert_rc "watch 30<60 -> rc0"  "0" "$?"
printf 'sin barra\n'  | bash "$WATCH" --stdin >/dev/null 2>&1;                assert_rc "watch ilegible -> rc3" "3" "$?"
bash "$WATCH" --threshold abc --stdin </dev/null >/dev/null 2>&1;             assert_rc "watch umbral no-num -> rc3" "3" "$?"
# regresion CR App bounce (6 findings): --threshold fuera de 0-100 pasaba la validacion numerica
# (p.ej. 101 -> ctx: 100% nunca dispara). Debe rechazarse con rc3, igual que un valor no-numerico.
bash "$WATCH" --threshold 101 --stdin </dev/null >/dev/null 2>&1;             assert_rc "watch umbral >100 -> rc3" "3" "$?"
printf 'ctx: 100%%\n' | bash "$WATCH" --stdin --threshold 100 >/dev/null 2>&1; assert_rc "watch umbral 100 valido -> rc2" "2" "$?"
# regresion CODE-GATE r2 sugerencia: valor faltante de --pane/--threshold -> rc3 (contrato 0/2/3),
# nunca escapar del contrato via ${var:?} sin capturar.
bash "$WATCH" --pane </dev/null >/dev/null 2>&1;                              assert_rc "watch --pane sin valor -> rc3" "3" "$?"
bash "$WATCH" --stdin --threshold </dev/null >/dev/null 2>&1;                 assert_rc "watch --threshold sin valor -> rc3" "3" "$?"
# regresion re-autoria bounce (F1): --pane vacio o sin '=' NO debe colar silenciosamente (antes
# "" llegaba a tmux capture-pane y podia matchear el pane activo en vez de fallar-cerrado).
bash "$WATCH" --pane "" </dev/null >/dev/null 2>&1;                           assert_rc "watch --pane vacio -> rc3" "3" "$?"
bash "$WATCH" --pane "sinigual" </dev/null >/dev/null 2>&1;                   assert_rc "watch --pane sin '=' -> rc3" "3" "$?"

# --- [TAL-8038] statusline-ctx.sh: la barra que emite `ctx: NN%` (sin ella el sensor queda ciego) -------------------
printf '== statusline-ctx.sh (barra) ==\n'
SL="$ROOT/assets/statusline-ctx.sh"
assert_eq "barra: 91.7 -> entero redondeado" "[Opus] ctx: 92%" \
  "$(printf '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":91.7}}' | bash "$SL")"
assert_eq "barra: entrada vacia -> N/A" "ctx: N/A" "$(printf '' | bash "$SL")"
assert_eq "barra: JSON roto -> N/A" "ctx: N/A" "$(printf '{rota' | bash "$SL")"
assert_eq "barra: campo null -> N/A (conserva modelo)" "[Opus] ctx: N/A" \
  "$(printf '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":null}}' | bash "$SL")"
assert_eq "barra: fuera de 0-100 -> N/A" "ctx: N/A" "$(printf '{"context_window":{"used_percentage":100.4}}' | bash "$SL")"
assert_eq "barra: no numerico (cadena) -> N/A" "ctx: N/A" "$(printf '{"context_window":{"used_percentage":"50"}}' | bash "$SL")"
assert_eq "barra: 0 es un valor legitimo" "ctx: 0%" "$(printf '{"context_window":{"used_percentage":0}}' | bash "$SL")"
assert_eq "barra: un modelo malicioso no falsifica un ctx" "[ctx 5] ctx: 77%" \
  "$(printf '{"model":{"display_name":"ctx: 5%%"},"context_window":{"used_percentage":77}}' | bash "$SL")"
# contrato de los parsers INTACTO: la salida 92% se lee; la N/A es ilegible (rc 1, jamas 0 ni 100)
assert_eq "tc_ctx_pct lee la barra: 92" "92" \
  "$(printf '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":91.7}}' | bash "$SL" | tc_ctx_pct)"
out="$(printf '{"context_window":{"used_percentage":null}}' | bash "$SL" | tc_ctx_pct)"; rc=$?
assert_rc "tc_ctx_pct sobre N/A -> rc1" "1" "$rc"; assert_eq "tc_ctx_pct sobre N/A -> vacio" "" "$out"
# el parser de la torre (lib-torre.sh del orquestador) lee la MISMA salida: se prueba en su suite (92 / rc 1)

# --- [TAL-8038] install-statusline.sh: aplicador unico (settings temporal, shim de claude) -----------------------------
printf '== install-statusline.sh ==\n'
INS="$ROOT/scripts/install-statusline.sh"
TW="$(mktemp -d)"; trap 'rm -rf "$TW"' EXIT
mkdir -p "$TW/bin288" "$TW/bin289" "$TW/bin277" "$TW/binbad" "$TW/binnone"
printf '#!/bin/sh\necho "2.1.288 (Claude Code)"\n' > "$TW/bin288/claude"
printf '#!/bin/sh\necho "2.1.289 (Claude Code)"\n' > "$TW/bin289/claude"
printf '#!/bin/sh\necho "2.1.277 (Claude Code)"\n' > "$TW/bin277/claude"
printf '#!/bin/sh\necho "version rara"\n' > "$TW/binbad/claude"
chmod +x "$TW"/bin*/claude
# PATH minimo con jq/sort/etc. pero SIN claude real: dir de enlaces a las utilidades necesarias
for b in jq sort cmp mktemp cp mv chmod date dirname grep head tail tr cat sed timeout bash rm mkdir printf realpath readlink awk; do
  p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$TW/binnone/$b"; done
inst() { local v="$1"; shift; PATH="$TW/$v:$TW/binnone" HOME="$TW/home" bash "$INS" "$@"; }

S="$TW/s1/settings.json"; mkdir -p "$TW/s1"
printf '{"model":"claude-sonnet-5","permissions":{"allow":["Bash(ls)"]},"otra":[1,2]}\n' > "$S"
inst bin289 --settings "$S" >"$TW/o1" 2>/dev/null; assert_rc "aplicar sobre settings con claves previas -> rc0" "0" "$?"
assert_eq "aplicar: .tui == default y statusLine de tipo command" "true" \
  "$(jq -e '.tui=="default" and .statusLine.type=="command"' "$S" 2>/dev/null || echo false)"
assert_eq "aplicar: claves previas intactas" "true" \
  "$(jq -e '.model=="claude-sonnet-5" and .permissions.allow==["Bash(ls)"] and .otra==[1,2]' "$S" 2>/dev/null || echo false)"
assert_eq "aplicar: la barra copiada es 0755 e identica al asset" "ok" \
  "$([ -x "$TW/s1/statusline-ctx.sh" ] && cmp -s "$SL" "$TW/s1/statusline-ctx.sh" && echo ok)"
assert_eq "aplicar: existe settings.json.bak-<UTC>" "1" "$(ls "$TW/s1"/settings.json.bak-* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "aplicar: ESTADO=cambios" "ESTADO=cambios" "$(tail -1 "$TW/o1")"
h1="$(sha256sum "$S" | cut -d' ' -f1)"
inst bin289 --settings "$S" >"$TW/o2" 2>/dev/null; assert_rc "2.a corrida -> rc0" "0" "$?"
assert_eq "2.a corrida: sha256 identico (idempotente)" "$h1" "$(sha256sum "$S" | cut -d' ' -f1)"
assert_eq "2.a corrida: ESTADO=sin-cambios y sin .bak nuevo" "ESTADO=sin-cambios/1" \
  "$(tail -1 "$TW/o2")/$(ls "$TW/s1"/settings.json.bak-* | wc -l | tr -d ' ')"
inst bin289 --settings "$S" --check >/dev/null 2>&1; assert_rc "--check tras aplicar -> rc0" "0" "$?"
# --check detecta la diferencia (rc 2) y NO escribe
jq '.tui="fullscreen"' "$S" > "$TW/s1/t" && mv "$TW/s1/t" "$S"; h2="$(sha256sum "$S" | cut -d' ' -f1)"
inst bin289 --settings "$S" --check >/dev/null 2>&1; assert_rc "--check con .tui=fullscreen -> rc2" "2" "$?"
assert_eq "--check no escribe" "$h2" "$(sha256sum "$S" | cut -d' ' -f1)"
inst bin289 --settings "$S" >/dev/null 2>&1; assert_eq "aplicar corrige .tui=fullscreen" "default" "$(jq -r .tui "$S")"

# settings ausente: se crea (sin .bak, 0600)
S0="$TW/s0/settings.json"; inst bin289 --settings "$S0" >/dev/null 2>&1; assert_rc "settings ausente -> se crea (rc0)" "0" "$?"
assert_eq "settings ausente: contenido y modo 600" "true/600" \
  "$(jq -e '.tui=="default"' "$S0" >/dev/null 2>&1 && echo true)/$(stat -c %a "$S0")"

# statusLine AJENA: no se pisa sin --force (rc 3); --check-ctx decide si emite ctx:
S2="$TW/s2/settings.json"; mkdir -p "$TW/s2"
printf '#!/bin/sh\ncat >/dev/null; echo "mi barra ctx: 33%%"\n' > "$TW/s2/mia.sh"; chmod +x "$TW/s2/mia.sh"
printf '{"statusLine":{"type":"command","command":"bash %s/mia.sh"}}\n' "$TW/s2" > "$S2"
inst bin289 --settings "$S2" >/dev/null 2>&1; assert_rc "statusLine ajena sin --force -> rc3" "3" "$?"
assert_eq "ajena: NO se pisa la statusLine" "bash $TW/s2/mia.sh" "$(jq -r .statusLine.command "$S2")"
assert_eq "ajena: .tui si se aplica y no se copia la barra" "default/no" \
  "$(jq -r .tui "$S2")/$([ -e "$TW/s2/statusline-ctx.sh" ] && echo si || echo no)"
inst bin289 --settings "$S2" --check-ctx >/dev/null 2>&1; assert_rc "--check-ctx de una barra ajena legible -> rc0" "0" "$?"
printf '#!/bin/sh\ncat >/dev/null; echo "sin dato"\n' > "$TW/s2/mia.sh"
inst bin289 --settings "$S2" --check-ctx >/dev/null 2>&1; assert_rc "--check-ctx de una barra ajena SIN ctx -> rc2" "2" "$?"
inst bin289 --settings "$S2" --force >/dev/null 2>&1; assert_rc "--force pisa la ajena -> rc0" "0" "$?"
assert_eq "--force: ahora es la del paquete" "bash $TW/s2/statusline-ctx.sh" "$(jq -r .statusLine.command "$S2")"
inst bin289 --settings "$S2" --check-ctx >/dev/null 2>&1; assert_rc "--check-ctx de la barra propia -> rc0" "0" "$?"

# JSON invalido -> rc 1 y NADA escrito
S3="$TW/s3/settings.json"; mkdir -p "$TW/s3"; printf '{rota' > "$S3"
inst bin289 --settings "$S3" >/dev/null 2>&1; assert_rc "JSON invalido -> rc1" "1" "$?"
assert_eq "JSON invalido: nada escrito (sin .bak ni barra)" "{rota/0" \
  "$(cat "$S3")/$(ls "$TW/s3" | grep -vc '^settings.json$')"
printf '[1,2]' > "$S3"; inst bin289 --settings "$S3" >/dev/null 2>&1; assert_rc "JSON no-objeto -> rc1" "1" "$?"

# version: 2.1.277 y lectura ilegible -> rc 4 (y nada escrito); ausente -> rc 4; 2.1.289 -> rc0
S4="$TW/s4/settings.json"
inst bin288 --settings "$S4" >/dev/null 2>&1; assert_rc "claude 2.1.288 -> rc4" "4" "$?"
inst bin277 --settings "$S4" >/dev/null 2>&1; assert_rc "claude 2.1.277 -> rc4" "4" "$?"
inst binbad --settings "$S4" >/dev/null 2>&1; assert_rc "version ilegible -> rc4" "4" "$?"
inst binnone --settings "$S4" >/dev/null 2>&1; assert_rc "sin claude en el PATH -> rc4" "4" "$?"
assert_eq "version insuficiente: nada escrito" "no" "$([ -e "$S4" ] && echo si || echo no)"
inst bin289 --check-version >/dev/null 2>&1; assert_rc "--check-version 2.1.289 -> rc0" "0" "$?"
inst bin277 --check-version >/dev/null 2>&1; assert_rc "--check-version 2.1.277 -> rc4" "4" "$?"
inst bin289 --settings "$S4" --bogus >/dev/null 2>&1; assert_rc "flag desconocido -> rc1" "1" "$?"
# --settings RELATIVO: el comando de la statusLine es SIEMPRE una ruta absoluta (funciona desde cualquier cwd)
mkdir -p "$TW/rel"; ( cd "$TW/rel" && PATH="$TW/bin289:$TW/binnone" HOME="$TW/home" bash "$INS" --settings rel.json >/dev/null 2>&1 ); assert_rc "--settings relativo -> rc0" "0" "$?"
assert_eq "--settings relativo: statusLine.command absoluto" "bash $(cd "$TW/rel" && pwd -P)/statusline-ctx.sh" "$(jq -r .statusLine.command "$TW/rel/rel.json" 2>/dev/null)"
# settings.json es un ENLACE simbolico (dotfiles): se escribe en su destino y el enlace se conserva
mkdir -p "$TW/ln/real"; printf '{"x":1}\n' > "$TW/ln/real/s.json"; ln -s real/s.json "$TW/ln/settings.json"
inst bin289 --settings "$TW/ln/settings.json" >/dev/null 2>&1; assert_rc "settings.json enlace simbolico -> rc0" "0" "$?"
assert_eq "enlace: sigue siendo un enlace y el destino tiene tui + claves previas" "enlace/true" \
  "$([ -L "$TW/ln/settings.json" ] && echo enlace)/$(jq -e '.tui=="default" and .x==1 and .statusLine.type=="command"' "$TW/ln/real/s.json" >/dev/null 2>&1 && echo true)"
assert_eq "enlace: la copia previa queda junto al destino y la barra junto al enlace" "1/ok" \
  "$(ls "$TW/ln/real"/s.json.bak-* 2>/dev/null | wc -l | tr -d ' ')/$([ -x "$TW/ln/statusline-ctx.sh" ] && echo ok)"
hl="$(sha256sum "$TW/ln/real/s.json" | cut -d' ' -f1)"; inst bin289 --settings "$TW/ln/settings.json" >/dev/null 2>&1
assert_eq "enlace: 2.a corrida idempotente" "$hl" "$(sha256sum "$TW/ln/real/s.json" | cut -d' ' -f1)"
# -h imprime SOLO la cabecera de uso (sin lineas de codigo)
hout="$(inst bin289 -h 2>&1)"; assert_rc "-h -> rc0" "0" "$?"
assert_eq "-h: muestra Uso: y NO codigo del script" "1/0" "$(printf '%s\n' "$hout" | grep -c '^Uso:')/$(printf '%s\n' "$hout" | grep -cE 'set -uo pipefail|^HERE=|^ASSETS=')"
assert_eq "la minima declarada es 2.1.289" "2.1.289" "$(tr -d '[:space:]' < "$ROOT/assets/claude-min-version")"

printf '\n== RESULTADO: %d ok, %d FAIL ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
