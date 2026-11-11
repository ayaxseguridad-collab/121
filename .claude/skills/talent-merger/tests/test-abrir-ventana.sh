#!/usr/bin/env bash
# test-abrir-ventana.sh — Pruebas de abrir-ventana.sh (casos C1-C14, mas argumentos, ayuda y rc del sellador) con
# repos git sintéticos (origin local), `gh` y sellador sustituidos por dobles, `date` y `git` por dobles de PATH.
# Sin red ni forja real. Esperados LITERALES escritos a mano. Cada caso de rechazo exige que el sellador NO se llame.
# Entorno del corredor de mutantes: TF_SCRIPTS_DIR (copia de scripts/ bajo prueba).
# Línea final: RESULTADO: PASS=<n> FAIL=<n>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-test.sh
. "$HERE/lib-test.sh" || exit 2
SD="${TF_SCRIPTS_DIR:-$T_SCRIPTS_REAL}"
for dep in git jq python3; do command -v "$dep" >/dev/null 2>&1 || { echo "falta $dep" >&2; exit 2; }; done
gv="$(git --version)"; gv="${gv#git version }"; gmaj="${gv%%.*}"; gmin="${gv#*.}"; gmin="${gmin%%.*}"
if ! { [ "$gmaj" -gt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -ge 38 ]; }; }; then
  echo "FAIL git $gv < 2.38: falta 'git merge-tree --write-tree'; la prueba lo exige y no se omite"; exit 2
fi
t_tmp || exit 2
trap t_limpiar EXIT
W="$T_W"; mkdir -p "$W/home" "$W/bin" "$W/bingit"
SLUG="org-ejemplo/prod"
REAL_DATE="$(command -v date)"; REAL_GIT="$(command -v git)"

# ── Mundo A: main con src/app.ts; PR 7 y PR 8 chocan en src/app.ts; PR 11 solo toca docs/ ───────────
M="$W/mundoA"; t_repo_sintetico "$M" || exit 2
t_commit "$M" src/app.ts 'linea base' 'app base' >/dev/null && git -C "$M" push -q origin main 2>/dev/null
sha7="$(t_rama "$M" feat/siete src/app.ts 'cambio siete')"
sha8="$(t_rama "$M" feat/ocho src/app.ts 'cambio ocho')"
sha11="$(t_rama "$M" feat/once docs/once.md 'doc once')"
# ── Mundo B: la PR 9 choca con un main que avanzó después de ramificar ──────────────────────────────
B="$W/mundoB"; t_repo_sintetico "$B" || exit 2
t_commit "$B" src/app.ts 'linea base' 'app base' >/dev/null && git -C "$B" push -q origin main 2>/dev/null
sha9="$(t_rama "$B" feat/nueve src/app.ts 'cambio nueve')"
t_commit "$B" src/app.ts 'main avanza' 'main avanza' >/dev/null && git -C "$B" push -q origin main 2>/dev/null

# ── Dobles compartidos: gh (fixtures por GH_FIXTURES), date y git (versión vieja) ────────────────────
t_gh_doble "$W/bin" "$W/fx-inicial" || exit 2
cat > "$W/bin/date" <<'__FIN_DATE_DOBLE__'
#!/usr/bin/env bash
if [ "$*" = "-u +%Y-%m-%dT%H:%MZ" ]; then echo "${AHORA_DOBLE:-2026-10-13T01:30Z}"; exit 0; fi
exec "${REAL_DATE:?}" "$@"
__FIN_DATE_DOBLE__
cat > "$W/bingit/git" <<'__FIN_GIT_DOBLE__'
#!/usr/bin/env bash
if [ "${1-}" = --version ]; then echo "git version 2.30.1"; exit 0; fi
exec "${REAL_GIT:?}" "$@"
__FIN_GIT_DOBLE__
chmod +x "$W/bin/date" "$W/bingit/git"
# Dobles que se quedan colgados: git cuando sus argumentos contienen GIT_COLGAR; gh siempre.
mkdir -p "$W/bincuelga-git" "$W/bincuelga-gh"
cat > "$W/bincuelga-git/git" <<'__FIN_GIT_CUELGA__'
#!/usr/bin/env bash
case "$*" in *"${GIT_COLGAR:-__nunca__}"*) exec sleep 300 ;; esac
exec "${REAL_GIT:?}" "$@"
__FIN_GIT_CUELGA__
cat > "$W/bincuelga-gh/gh" <<'__FIN_GH_CUELGA__'
#!/usr/bin/env bash
exec sleep 300
__FIN_GH_CUELGA__
chmod +x "$W/bincuelga-git/git" "$W/bincuelga-gh/gh"
MAPA="$W/mapa.conf"
{
  printf '%s\n' 'TF_INPUTS_UNIVERSAL="package.json"'
  printf '%s\n' 'TF_INPUTS_docs="docs/**"'
  printf '%s\n' 'TF_INPUTS_lint="src/**"'
} > "$MAPA"
BASEENV=(HOME="$W/home" LC_ALL=C REAL_DATE="$REAL_DATE" REAL_GIT="$REAL_GIT")

# ── Utilería de casos ────────────────────────────────────────────────────────────────────────────────
CASO=0; ENVX=(); BIN_PATH=''
fxbase() { printf '%s/%s' "$FX" "${1//\//__}"; }
fx_pr() { # <n> <sha> <ref> <mergeable_state en JSON>
  printf '{"number":%s,"head":{"sha":"%s","ref":"%s"},"mergeable_state":%s}\n' "$1" "$2" "$3" "$4" > "$(fxbase "repos/$SLUG/pulls/$1").json"
}
fx_status() { printf '{"statuses":[{"context":"local-gates","state":"%s"}]}\n' "$2" > "$(fxbase "repos/$SLUG/commits/$1/status").json"; }
fx_lista() { # <página> <n:ref>...
  local p="$1"; shift
  jq -n '[$ARGS.positional[] | split(":") | {number: (.[0] | tonumber), head: {ref: .[1], sha: "0000000000000000000000000000000000000000"}}]' --args "$@" \
    > "$(fxbase "repos/$SLUG/pulls?state=open&base=main&per_page=100").p$p.json"
}
nuevo_caso() { # <mundo> <pr> <ref> <sha> [ms-json] [estado-lg]
  local ms="${5:-}"; [ -n "$ms" ] || ms='"clean"'
  CASO=$((CASO + 1)); D="$W/c$CASO"; mkdir -p "$D/fx"
  FX="$D/fx"; LOGGH="$D/gh.log"; SELL="$D/sellador"; SELLO="$D/sello.txt"
  git clone -q "$W/$1.origin.git" "$D/clon" 2>/dev/null || { echo "no pude clonar el origen de $1" >&2; exit 2; }
  t_sellador_doble "$SELL"; printf 'CEO-VENTANA de prueba\n' > "$SELLO"
  fx_pr "$2" "$4" "$3" "$ms"; fx_status "$4" "${6:-success}"; fx_lista 1 "$2:$3"
  ENVX=(TF_SLUG="$SLUG" TF_VENTANA_CLON="$D/clon" TF_CLONE="$D/suites" TF_SELLAR="$SELL" TA_ROL=est-a GH_FIXTURES="$FX" GH_LOG="$LOGGH" LG_INSUMOS_CONF="$MAPA")
  BIN_PATH="$W/bin:$PATH"
}
quitar_var() { local n=() e; for e in "${ENVX[@]}"; do case "$e" in "$1="*) ;; *) n+=("$e") ;; esac; done; ENVX=("${n[@]}"); }
ejecutar() { env -i PATH="$BIN_PATH" "${BASEENV[@]}" "${ENVX[@]}" bash "$SD/abrir-ventana.sh" "$@"; }
run() { OUT="$(ejecutar "$@" 2>&1)"; RC=$?; }
n_sellos() { if [ -f "$SELL.log" ]; then grep -c . "$SELL.log" || true; else echo 0; fi; }
n_gh() { if [ -f "$LOGGH" ]; then grep -c . "$LOGGH" || true; else echo 0; fi; }
sin_sello() { t_ok "$1: el sellador no se llamó" 0 "$(n_sellos)"; }

# ── C1: camino feliz ───────────────────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
run 11 MARC-1 "$SELLO"
t_ok "C1 rc" 0 "$RC"
t_linea "C1 estado del head" "PR #11 head=${sha11:0:9} mergeable_state=clean local-gates=success"
t_linea "C1 CERROJO OK" "CERROJO OK: sello MARC-1"
t_ok "C1 el sellador se llamó una vez" 1 "$(n_sellos)"
t_ok "C1 argumentos del sellador" "--marcador MARC-1 --rol est-a --src $SELLO" "$(head -n 1 "$SELL.log")"
t_ok "C1 el sello recibido es el fichero" "CEO-VENTANA de prueba" "$(cat "$SELL.src.1")"
SELLADOR_RC_OK="$(ENVX+=(SELLADOR_DOBLE_RC=3); ejecutar 11 MARC-2 "$SELLO" >/dev/null 2>&1; echo $?)"
t_ok "El rc del sellador se propaga" 3 "$SELLADOR_RC_OK"

# ── C2: congelamiento por agenda ───────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
CF="$D/cong.txt"; ENVX+=(TF_CONGELAMIENTO="$CF")
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba\n' > "$CF"
run 11 M "$SELLO"
t_ok "C2 dentro de la ventana: rc" 4 "$RC"
t_contiene "C2 mensaje" "$OUT" "RECHAZO CONGELAMIENTO"
sin_sello "C2"
t_ok "C2 sin llamadas a la forja al rechazar por agenda" 0 "$(n_gh)"
printf '2026-10-12T00:00Z 2026-10-12T02:00Z Directo de ayer\n' > "$CF"
run 11 M "$SELLO"; t_ok "C2 fuera de la ventana: rc" 0 "$RC"
printf '2026-10-13T00:00Z 2026-10-13T01:30Z Termina ahora\n' > "$CF"
run 11 M "$SELLO"; t_ok "C2 el fin de la ventana es exclusivo" 0 "$RC"
printf '2026-10-13T01:30Z 2026-10-13T03:30Z Empieza ahora\n' > "$CF"
run 11 M "$SELLO"; t_ok "C2 el inicio de la ventana es inclusivo" 4 "$RC"

# ── C3: GO del lead por fichero ────────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba\n' > "$D/cong.txt"; ENVX+=(TF_CONGELAMIENTO="$D/cong.txt" GO_LEAD_FREEZE="$D/go.txt")
printf 'CITA: orden literal del lead\nPRS: 8 11 12\n' > "$D/go.txt"
run 11 M "$SELLO"
t_ok "C3 GO válido: rc" 0 "$RC"
t_contiene "C3 GO válido: constancia" "$OUT" "CONGELAMIENTO EXCEPTUADO por GO del lead ($D/go.txt, md5 "
printf 'PRS: 11\n' > "$D/go.txt"; run 11 M "$SELLO"; t_ok "C3 sin CITA: rc" 4 "$RC"
printf 'CITA:   \nPRS: 11\n' > "$D/go.txt"; run 11 M "$SELLO"; t_ok "C3 CITA vacía: rc" 4 "$RC"
printf 'CITA: orden\nPRS: 110 8\n' > "$D/go.txt"; run 11 M "$SELLO"; t_ok "C3 PRS que no lista el PR: rc" 4 "$RC"
printf 'CITA: orden\nPRS: 8,11\n' > "$D/go.txt"; run 11 M "$SELLO"; t_ok "C3 PRS separado por comas: rc" 0 "$RC"

# ── C4: exención por diff, nunca por variable autodeclarada ─────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba\n' > "$D/cong.txt"; ENVX+=(TF_CONGELAMIENTO="$D/cong.txt")
run 11 M "$SELLO"; t_ok "C4 sin exención declarada: rc" 4 "$RC"
ENVX+=(CEO_APPS_SOLO=1); run 11 M "$SELLO"; t_ok "C4 CEO_APPS_SOLO=1 no cambia nada" 4 "$RC"
quitar_var CEO_APPS_SOLO; ENVX+=(TF_CONGELAMIENTO_EXENTO_RE='^docs/')
run 11 M "$SELLO"
t_ok "C4 diff 100 % dentro de la exención: rc" 0 "$RC"
t_contiene "C4 constancia" "$OUT" "CONGELAMIENTO EXCEPTUADO: el diff de #11"
ENVX+=(TF_CONGELAMIENTO_EXENTO_RE='(')
run 11 M "$SELLO"; t_ok "C4 ERE inválida no exime: rc" 4 "$RC"
nuevo_caso mundoA 7 feat/siete "$sha7"
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba\n' > "$D/cong.txt"; ENVX+=(TF_CONGELAMIENTO="$D/cong.txt" TF_CONGELAMIENTO_EXENTO_RE='^docs/')
run 7 M "$SELLO"
t_ok "C4 un fichero fuera de la exención: rc" 4 "$RC"
sin_sello "C4 fuera de la exención"

# ── C5: congelamiento declarado pero ilegible, vacío, malformado o viejo ────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
ENVX+=(TF_CONGELAMIENTO="$D/no-existe.txt")
run 11 M "$SELLO"
t_ok "C5 fichero ausente: rc 4 fail-closed" 4 "$RC"
t_contiene "C5 fichero ausente: mensaje" "$OUT" "falta o no es legible el fichero de congelamiento"
sin_sello "C5 ausente"
quitar_var TF_CONGELAMIENTO; ENVX+=(TF_CONGELAMIENTO="$D")
run 11 M "$SELLO"; t_ok "C5 un directorio no es un fichero legible: rc" 4 "$RC"
quitar_var TF_CONGELAMIENTO; ENVX+=(TF_CONGELAMIENTO="$D/vacio.txt"); : > "$D/vacio.txt"
run 11 M "$SELLO"; t_ok "C5 fichero vacío = sin congelamiento: rc" 0 "$RC"
printf '# comentario\n\n2026-10-12T00:00Z 2026-10-12T02:00Z Ayer\n' > "$D/vacio.txt"
run 11 M "$SELLO"; t_ok "C5 comentarios y líneas en blanco: rc" 0 "$RC"
printf 'basura x y\n' > "$D/vacio.txt"
run 11 M "$SELLO"; t_ok "C5 línea malformada: rc 4 fail-closed" 4 "$RC"
printf '2026-10-12T00:00Z 2026-10-12T02:00Z Ayer\n' > "$D/vacio.txt"; touch -d '3 hours ago' "$D/vacio.txt"
run 11 M "$SELLO"
t_ok "C5 fichero viejo: se usa" 0 "$RC"
t_contiene "C5 fichero viejo: AVISO con la edad" "$OUT" "AVISO: el fichero de congelamiento tiene 180 min de antigüedad"
# La última línea sin LF final se procesa igual (control con LF + negativo sin LF, mismo intervalo activo).
nuevo_caso mundoA 11 feat/once "$sha11"
ENVX+=(TF_CONGELAMIENTO="$D/cong-lf.txt")
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba\n' > "$D/cong-lf.txt"
run 11 M "$SELLO"; t_ok "C5 control: ventana activa con LF final: rc" 4 "$RC"
printf '2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba' > "$D/cong-lf.txt"
run 11 M "$SELLO"
t_ok "C5 ventana activa SIN LF final: rc 4" 4 "$RC"
t_contiene "C5 sin LF final: mensaje de congelamiento" "$OUT" "RECHAZO CONGELAMIENTO"
sin_sello "C5 sin LF final"
printf '2026-10-12T00:00Z 2026-10-12T02:00Z Ayer\n2026-10-13T00:00Z 2026-10-13T02:00Z Directo de prueba' > "$D/cong-lf.txt"
run 11 M "$SELLO"; t_ok "C5 varias líneas, la activa es la última sin LF: rc 4" 4 "$RC"
printf '2026-10-12T00:00Z 2026-10-12T02:00Z Ayer' > "$D/cong-lf.txt"
run 11 M "$SELLO"; t_ok "C5 única ventana pasada sin LF final: rc 0" 0 "$RC"
printf 'basura x y' > "$D/cong-lf.txt"
run 11 M "$SELLO"; t_ok "C5 última línea malformada sin LF final: rc 4 fail-closed" 4 "$RC"
printf '# comentario sin LF' > "$D/cong-lf.txt"
run 11 M "$SELLO"; t_ok "C5 comentario final sin LF: rc 0" 0 "$RC"

# ── C6: local-gates y mergeable_state; DRY=1 no cambia nada ─────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11" '"clean"' pending
run 11 M "$SELLO"
t_ok "C6 local-gates pendiente: rc" 4 "$RC"
t_contiene "C6 local-gates: mensaje" "$OUT" "RECHAZO: local-gates no es success"
sin_sello "C6 local-gates"
ENVX+=(DRY=1); run 11 M "$SELLO"; t_ok "C6 DRY=1 no salta local-gates" 4 "$RC"
for ms in '"unknown"' '"dirty"' '""' 'null'; do
  nuevo_caso mundoA 11 feat/once "$sha11" "$ms"
  run 11 M "$SELLO"
  t_ok "C6 mergeable_state=$ms: rc" 4 "$RC"
  sin_sello "C6 mergeable_state=$ms"
done
ENVX+=(DRY=1); run 11 M "$SELLO"; t_ok "C6 DRY=1 no salta mergeable_state" 4 "$RC"
t_contiene "C6 mergeable_state: mensaje" "$OUT" "RECHAZO: mergeable_state="

# ── C7: head local distinto del de la API; fetch que falla ─────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha8"
run 11 M "$SELLO"
t_ok "C7 head local != API: rc" 9 "$RC"
t_contiene "C7 mensaje" "$OUT" "head local != API"
sin_sello "C7 head"
nuevo_caso mundoA 11 feat/fantasma "$sha11"
run 11 M "$SELLO"
t_ok "C7 fetch que falla: rc" 9 "$RC"
sin_sello "C7 fetch"
# Plazo de IO externa: un doble colgado debe cortarse en TF_VENTANA_PLAZO (aquí 2 s) y dar rc 9 sin sellar.
cuelga() { # <descripción> <mensaje esperado> — usa BIN_PATH y ENVX ya preparados; mide el tiempo
  local t0=$SECONDS
  run 11 M "$SELLO"
  t_ok "$1: rc 9" 9 "$RC"
  t_contiene "$1: mensaje" "$OUT" "$2"
  sin_sello "$1"
  t_ok "$1: tiempo acotado (< 20 s con plazo de 2 s)" 1 "$(( SECONDS - t0 < 20 ? 1 : 0 ))"
}
nuevo_caso mundoA 11 feat/once "$sha11"
BIN_PATH="$W/bincuelga-git:$W/bin:$PATH"; ENVX+=(TF_VENTANA_PLAZO=2 GIT_COLGAR=fetch)
cuelga "C7 fetch colgado" "RECHAZO: no puedo traer feat/once"
nuevo_caso mundoA 7 feat/siete "$sha7"; fx_lista 1 7:feat/siete 8:feat/ocho
BIN_PATH="$W/bincuelga-git:$W/bin:$PATH"; ENVX+=(TF_VENTANA_PLAZO=2 GIT_COLGAR=refs/heads/feat/ocho:)
run 7 M "$SELLO"
t_ok "C7 fetch colgado en el censo L8: rc 9" 9 "$RC"
t_contiene "C7 censo: mensaje" "$OUT" "el fetch de #8 no terminó"
sin_sello "C7 censo colgado"
nuevo_caso mundoA 11 feat/once "$sha11"
BIN_PATH="$W/bincuelga-gh:$W/bin:$PATH"; ENVX+=(TF_VENTANA_PLAZO=2)
cuelga "C7 gh api colgado" "RECHAZO: la API no devolvió la PR #11"
nuevo_caso mundoA 11 feat/once "$sha11"; ENVX+=(TF_VENTANA_PLAZO=0)
run 11 M "$SELLO"; t_ok "C7 plazo inválido: rc 2" 2 "$RC"; t_contiene "C7 plazo inválido: nombra la variable" "$OUT" "TF_VENTANA_PLAZO"

# ── C8: el coste de caducidad se informa y NUNCA rechaza ────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
REC="$D/rec"; mkdir -p "$REC"
printf '%s\n' '{"gate_id":"docs","pr":12,"result":"PASS"}' > "$REC/r1.json"
printf '%s\n' '{"gate_id":"lint","pr":12,"result":"PASS"}' > "$REC/r2.json"
printf '%s\n' '{"gate_id":"docs","pr":13,"result":"FAIL"}' > "$REC/r3.json"
printf '%s\n' '{"gate_id":"docs","pr":11,"result":"PASS"}' > "$REC/r4.json"
ENVX+=(TF_EN_VUELO_DIR="$REC")
run 11 M "$SELLO"
t_ok "C8 con recibos ajenos que caducan: rc 0" 0 "$RC"
t_linea "C8 coste" "COSTE #12: 1 de 2 recibos caducan: docs"
t_no_contiene "C8 los recibos FAIL no cuentan" "$OUT" "COSTE #13"
t_no_contiene "C8 los recibos de la propia PR no cuentan" "$OUT" "COSTE #11"
t_contiene "C8 el coste va anexado al sello" "$(cat "$SELL.src.1")" "COSTE #12: 1 de 2 recibos caducan: docs"
t_ok "C8 se selló" 1 "$(n_sellos)"
quitar_var TF_EN_VUELO_DIR; ENVX+=(TF_EN_VUELO_DIR="$D/no-hay")
run 11 M "$SELLO"
t_ok "C8 directorio de recibos ausente: rc 0 con aviso" 0 "$RC"
t_contiene "C8 aviso" "$OUT" "AVISO: TF_EN_VUELO_DIR no es un directorio"

# ── C9: L8 contra otras PR y contra la propia ──────────────────────────────────────────────────────
nuevo_caso mundoA 7 feat/siete "$sha7"; fx_lista 1 7:feat/siete 8:feat/ocho
run 7 M "$SELLO"
t_ok "C9 conflicto con otra PR abierta: rc 3" 3 "$RC"
t_linea "C9 lista el conflicto" "L8 conflictos contra el árbol resultante: #8(src/app.ts)"
sin_sello "C9"
run 7 M "$SELLO" --acepto-conflictos
t_ok "C9 --acepto-conflictos: rc 0" 0 "$RC"
t_contiene "C9 la lista va al sello" "$(cat "$SELL.src.1")" "conflictan tras este merge: #8(src/app.ts)"
nuevo_caso mundoB 9 feat/nueve "$sha9"
run 9 M "$SELLO"
t_ok "C9 la propia PR conflicta con main: rc 3" 3 "$RC"
t_contiene "C9 mensaje de la propia pieza" "$OUT" "merge-tree de la propia pieza"
run 9 M "$SELLO" --acepto-conflictos
t_ok "C9 --acepto-conflictos no exime a la propia PR" 3 "$RC"
sin_sello "C9 propia"

# ── C10: paginación y PR no evaluable ──────────────────────────────────────────────────────────────
nuevo_caso mundoA 7 feat/siete "$sha7"; fx_lista 1 7:feat/siete; fx_lista 2 8:feat/ocho
run 7 M "$SELLO"
t_ok "C10 una PR conflictiva de la 2.ª página rechaza: rc" 3 "$RC"
t_contiene "C10 la lista incluye la 2.ª página" "$OUT" "#8(src/app.ts)"
t_contiene "C10 se pidió con --paginate" "$(cat "$LOGGH")" "--paginate"
nuevo_caso mundoA 11 feat/once "$sha11"; fx_lista 1 11:feat/once 30:feat/fantasma
run 11 M "$SELLO"
t_ok "C10 una PR que no se puede evaluar cuenta como conflicto: rc" 3 "$RC"
t_contiene "C10 la nombra" "$OUT" "#30(no-evaluable)"

# ── C11: hooks de instancia ────────────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
HK="$D/hooks"; mkdir -p "$HK"; HLOG="$D/hooks.log"
cat > "$HK/10-uno" <<'__FIN_HOOK__'
#!/usr/bin/env bash
n="${0##*/}"
printf '%s %s %s %s\n' "$n" "$1" "$(test -f "$3/docs/once.md" && echo arbol)" "$(basename "$4")" >> "$HOOK_LOG"
[ "$n" != "${HOOK_FALLA:-}" ]
__FIN_HOOK__
cp "$HK/10-uno" "$HK/20-dos"; chmod 755 "$HK" "$HK/10-uno" "$HK/20-dos"
ENVX+=(TF_VENTANA_CHECKS_DIR="$HK" HOOK_LOG="$HLOG")
run 11 M "$SELLO"
t_ok "C11 hooks ok: rc" 0 "$RC"
t_ok "C11 orden léxico, argumentos y árbol resultante" "$(printf '10-uno 11 arbol sello.txt\n20-dos 11 arbol sello.txt')" "$(cat "$HLOG")"
: > "$HLOG"
nuevo_caso mundoA 11 feat/once "$sha11"
ENVX+=(TF_VENTANA_CHECKS_DIR="$HK" HOOK_LOG="$HLOG" HOOK_FALLA=20-dos)
run 11 M "$SELLO"
t_ok "C11 un hook con rc distinto de 0: rc 5" 5 "$RC"
t_contiene "C11 nombra el hook" "$OUT" "RECHAZO hook 20-dos: rc=1"
sin_sello "C11 hook"
t_contiene "C11 el hook previo sí corrió" "$(cat "$HLOG")" "10-uno 11"
chmod 644 "$HK/20-dos"
nuevo_caso mundoA 11 feat/once "$sha11"; ENVX+=(TF_VENTANA_CHECKS_DIR="$HK" HOOK_LOG="$HLOG")
run 11 M "$SELLO"
t_ok "C11 hook no ejecutable: rc 2" 2 "$RC"
t_ok "C11 la precondición corta antes de la forja" 0 "$(n_gh)"
sin_sello "C11 no ejecutable"
chmod 775 "$HK/20-dos"; run 11 M "$SELLO"; t_ok "C11 hook escribible por el grupo: rc 2" 2 "$RC"
chmod 755 "$HK/20-dos"; chmod 775 "$HK"; run 11 M "$SELLO"; t_ok "C11 directorio de hooks escribible por el grupo: rc 2" 2 "$RC"
chmod 755 "$HK"; quitar_var TF_VENTANA_CHECKS_DIR; ENVX+=(TF_VENTANA_CHECKS_DIR="$D/no-hay-hooks")
run 11 M "$SELLO"; t_ok "C11 directorio de hooks ilegible: rc 2" 2 "$RC"
# Hooks ocultos (nombre con punto): se ejecutan, con las mismas validaciones y orden léxico.
nuevo_caso mundoA 11 feat/once "$sha11"
HK2="$D/hooks-ocultos"; mkdir -p "$HK2"; HLOG2="$D/hooks2.log"
cp "$HK/10-uno" "$HK2/.30-oculto"; cp "$HK/10-uno" "$HK2/20-visible"; chmod 755 "$HK2" "$HK2/.30-oculto" "$HK2/20-visible"
ENVX+=(TF_VENTANA_CHECKS_DIR="$HK2" HOOK_LOG="$HLOG2" HOOK_FALLA=.30-oculto)
run 11 M "$SELLO"
t_ok "C11 hook oculto que falla: rc 5" 5 "$RC"
t_contiene "C11 nombra el hook oculto" "$OUT" "RECHAZO hook .30-oculto: rc=1"
sin_sello "C11 hook oculto"
t_ok "C11 orden léxico (C): el oculto va primero y su fallo corta" ".30-oculto 11 arbol sello.txt" "$(cat "$HLOG2")"
quitar_var HOOK_FALLA; ENVX+=(HOOK_FALLA=ninguno); : > "$HLOG2"
run 11 M "$SELLO"; t_ok "C11 control: hook oculto que pasa: rc 0" 0 "$RC"
t_ok "C11 el oculto corrió, luego el visible" "$(printf '.30-oculto 11 arbol sello.txt\n20-visible 11 arbol sello.txt')" "$(cat "$HLOG2")"
chmod 644 "$HK2/.30-oculto"; run 11 M "$SELLO"; t_ok "C11 hook oculto no ejecutable: rc 2" 2 "$RC"
chmod 775 "$HK2/.30-oculto"; run 11 M "$SELLO"; t_ok "C11 hook oculto escribible por el grupo: rc 2" 2 "$RC"

# ── C12: SOLO_CHEQUEO ───────────────────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"; ENVX+=(SOLO_CHEQUEO=1)
run 11 M "$SELLO"
t_ok "C12 rc" 0 "$RC"
t_linea "C12 veredicto" "SOLO_CHEQUEO=1: cerrojo PASARÍA (no sello)"
sin_sello "C12"
nuevo_caso mundoA 11 feat/once "$sha11" '"clean"' failure; ENVX+=(SOLO_CHEQUEO=1)
run 11 M "$SELLO"
t_ok "C12 SOLO_CHEQUEO corre las comprobaciones: rechaza" 4 "$RC"
sin_sello "C12 rechazo"

# ── C13: parámetros sin default de casa y precedencia entorno > perfil ─────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"; quitar_var TF_SLUG
run 11 M "$SELLO"
t_ok "C13 sin TF_SLUG: rc 2" 2 "$RC"
t_contiene "C13 nombra TF_SLUG" "$OUT" "TF_SLUG"
t_ok "C13 sin llamadas a la forja" 0 "$(n_gh)"
quitar_var TF_SLUG; ENVX+=(TF_SLUG='a b'); run 11 M "$SELLO"; t_ok "C13 slug inválido: rc 2" 2 "$RC"
nuevo_caso mundoA 11 feat/once "$sha11"; quitar_var TF_VENTANA_CLON
run 11 M "$SELLO"
t_ok "C13 sin TF_VENTANA_CLON: rc 2" 2 "$RC"
t_contiene "C13 nombra TF_VENTANA_CLON" "$OUT" "TF_VENTANA_CLON"
nuevo_caso mundoA 11 feat/once "$sha11"; quitar_var TF_CLONE; ENVX+=(TF_CLONE="$D/clon")
run 11 M "$SELLO"
t_ok "C13 clon de la ventana igual al de las suites: rc 2" 2 "$RC"
t_contiene "C13 nombra TF_CLONE" "$OUT" "TF_CLONE"
nuevo_caso mundoA 11 feat/once "$sha11"; quitar_var TF_SLUG; quitar_var TF_VENTANA_CLON
{
  printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-a\tmaq-a\t-\t-\tacceso=local\n'
  printf 'estacion\test-a\tmaq-a\t-\t-\trepo=org-perfil/repo-perfil;clon=%s\n' "$D/clon"
} > "$D/perfil.tsv"
ENVX+=(TF_ESTACION=est-a TA_PERFIL="$D/perfil.tsv")
run 11 M "$SELLO"
t_contiene "C13 el repo sale del perfil" "$(cat "$LOGGH" 2>/dev/null)" "repos/org-perfil/repo-perfil/pulls/11"
ENVX+=(TF_SLUG=org-entorno/repo-entorno)
run 11 M "$SELLO"
t_contiene "C13 el entorno gana al perfil" "$(cat "$LOGGH")" "repos/org-entorno/repo-entorno/pulls/11"
nuevo_caso mundoA 11 feat/once "$sha11"; BIN_PATH="$W/bingit:$W/bin:$PATH"
run 11 M "$SELLO"
t_ok "C13 git anterior a 2.38: rc 2" 2 "$RC"
t_contiene "C13 git anterior: mensaje" "$OUT" "git >= 2.38"

# ── C14: fichero de sello ausente o vacío, antes de cualquier llamada a la forja ────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
run 11 M "$D/no-existe.txt"
t_ok "C14 sello inexistente: rc 4" 4 "$RC"
t_ok "C14 sin llamadas a la forja" 0 "$(n_gh)"
: > "$D/vacio.txt"; run 11 M "$D/vacio.txt"
t_ok "C14 sello vacío: rc 4" 4 "$RC"
t_ok "C14 vacío: sin llamadas a la forja" 0 "$(n_gh)"
sin_sello "C14"

# ── Argumentos y ayuda ──────────────────────────────────────────────────────────────────────────────
nuevo_caso mundoA 11 feat/once "$sha11"
run; t_ok "sin argumentos: rc 2" 2 "$RC"
run abc M "$SELLO"; t_ok "PR no numérica: rc 2" 2 "$RC"
run 11 M "$SELLO" --opcion-rara; t_ok "opción desconocida: rc 2" 2 "$RC"
run --help; t_ok "--help: rc 0" 0 "$RC"
t_contiene "--help: tabla de rc" "$OUT" "rc EXACTOS"

# ── Mutantes de los fail-closed ─────────────────────────────────────────────────────────────────────
if [ -z "${TF_SCRIPTS_DIR-}" ]; then
  P="$HERE/test-abrir-ventana.sh"
  t_mutante congelamiento-ausente-abre abrir-ventana.sh '|| fallo 4 "RECHAZO: falta o no es legible' '|| : "RECHAZO: falta o no es legible' "$P"
  t_mutante dry-salta-controles abrir-ventana.sh '[ "$lg" = "success" ] ||' '[ "${DRY:-0}" = 1 ] || [ "$lg" = "success" ] ||' "$P"
  t_mutante sellar-en-solo-chequeo abrir-ventana.sh '(no sello)"; exit 0; fi' '(no sello)"; fi' "$P"
  t_mutante congelamiento-sin-lf-final-ignorado abrir-ventana.sh 'read -r ini fin tit || [ -n "$ini" ]; do' 'read -r ini fin tit; do' "$P"
  t_mutante hooks-ocultos-omitidos abrir-ventana.sh '  shopt -s dotglob
' '  :
' "$P"
  t_mutante rechazo-por-caducidad abrir-ventana.sh 'echo "$coste_linea"' 'echo "$coste_linea"; exit 4' "$P"
fi

t_fin
