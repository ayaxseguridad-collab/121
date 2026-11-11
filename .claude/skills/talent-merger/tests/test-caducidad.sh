#!/usr/bin/env bash
# test-caducidad.sh — Pruebas de caducidad.sh y cad-lib.sh (casos C15-C19) con repos git sintéticos y un
# mapa de insumos de fixture (LG_INSUMOS_CONF). Sin red. Los esperados son LITERALES escritos a mano.
# Entorno del corredor de mutantes: TF_SCRIPTS_DIR (copia de scripts/ bajo prueba).
# Línea final: RESULTADO: PASS=<n> FAIL=<n>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-test.sh
. "$HERE/lib-test.sh" || exit 2
SD="${TF_SCRIPTS_DIR:-$T_SCRIPTS_REAL}"
for dep in git jq; do command -v "$dep" >/dev/null 2>&1 || { echo "falta $dep" >&2; exit 2; }; done
t_tmp || exit 2
trap t_limpiar EXIT
W="$T_W"; mkdir -p "$W/home"

# ── Fixtures ──────────────────────────────────────────────────────────────────────────────────────
MAPA="$W/mapa.conf"
{
  printf '%s\n' 'TF_INPUTS_UNIVERSAL="package.json"'
  printf '%s\n' 'TF_INPUTS_typecheck="src/** *.ts"'
  printf '%s\n' 'TF_INPUTS_docs="docs/**"'
  printf '%s\n' 'TF_INPUTS_e2e="src/** supabase/**"'
  printf '%s\n' 'TF_NOT_INPUTS_e2e="supabase/tests/**"'
  printf '%s\n' 'TF_ALWAYS_RERUN="siempre-x"'
} > "$MAPA"
MAN="$W/manifiesto.conf"
printf '%s\n' 'TF_GATE_IDS="typecheck docs gate-sin-mapa siempre-x"' > "$MAN"
MAN_VACIO="$W/manifiesto-vacio.conf"
printf '%s\n' 'TF_OTRA="x"' > "$MAN_VACIO"

R="$W/r"; t_repo_sintetico "$R" || { echo "no pude crear el repo sintético" >&2; exit 2; }
R2="$W/r2"; t_repo_sintetico "$R2" || exit 2
c0="$(git -C "$R" rev-parse HEAD)"
c1="$(t_commit "$R" src/a.ts 'x' c1)"
c2="$(t_commit "$R" docs/b.md 'x' c2)"
c3="$(t_commit "$R" package.json '{}' c3)"
c4="$(t_commit "$R" supabase/tests/x.sql 'x' c4)"
c5="$(t_commit "$R" supabase/migrations/001.sql 'x' c5)"

# Perfil sintético (V1-V9): la fila estacion declara repo y clon.
perfil() { # <ruta> <clon>
  {
    printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
    printf 'maquina\tmaq-a\tmaq-a\t-\t-\tacceso=local\n'
    printf 'estacion\test-a\tmaq-a\t-\t-\trepo=org-ejemplo/prod;clon=%s\n' "$2"
  } > "$1"
}
perfil "$W/perfil-r.tsv" "$R"
perfil "$W/perfil-r2.tsv" "$R2"

ENVX=()
cad() { env -i PATH="$PATH" HOME="$W/home" LC_ALL=C LG_INSUMOS_CONF="$MAPA" "${ENVX[@]}" bash "$SD/caducidad.sh" "$@"; }
run() { OUT="$("$@" 2>&1)"; RC=$?; }

# ── C15 / C16: caducan y conservan por insumos, exclusiones, universal, siempre, sin mapa ──────────
ENVX=(CAD_REPO="$R" TF_MANIFEST="$MAN")
run cad "$c0" "$c1"
t_ok "C15 src: rc" 0 "$RC"
t_linea "C15 src: avance" "avance $c0 -> $c1: 1 ficheros"
t_linea "C15 src: CADUCAN" "CADUCAN: typecheck gate-sin-mapa siempre-x e2e (+ carveout_check siempre)"
t_linea "C15 src: CONSERVAN" "CONSERVAN: docs"
t_linea "C16 src: SIN-MAPA nombrado" "SIN-MAPA(caduca): gate-sin-mapa"
t_no_contiene "C16 el gate sin mapa NUNCA en CONSERVAN" "$(printf '%s\n' "$OUT" | grep '^CONSERVAN')" "gate-sin-mapa"
t_no_contiene "C15 sin universal" "$OUT" "UNIVERSAL tocado"

run cad "$c1" "$c2"
t_ok "C15 docs: rc" 0 "$RC"
t_linea "C15 docs: CADUCAN" "CADUCAN: docs gate-sin-mapa siempre-x (+ carveout_check siempre)"
t_linea "C15 docs: CONSERVAN" "CONSERVAN: typecheck e2e"

run cad "$c3" "$c4"
t_linea "C15 exclusión TF_NOT_INPUTS: e2e conserva" "CONSERVAN: typecheck docs e2e"
t_linea "C15 exclusión: CADUCAN" "CADUCAN: gate-sin-mapa siempre-x (+ carveout_check siempre)"

run cad "$c4" "$c5"
t_linea "C15 migración: e2e caduca (fuera de la exclusión)" "CADUCAN: gate-sin-mapa siempre-x e2e (+ carveout_check siempre)"
t_linea "C15 migración: CONSERVAN" "CONSERVAN: typecheck docs"

run cad "$c2" "$c3"
t_linea "C15 universal: aviso" "UNIVERSAL tocado -> CADUCAN TODOS"
t_linea "C15 universal: CADUCAN todos" "CADUCAN: typecheck docs gate-sin-mapa siempre-x e2e (+ carveout_check siempre)"
t_linea "C15 universal: CONSERVAN vacío" "CONSERVAN:"
t_linea "C16 universal: SIN-MAPA se sigue nombrando" "SIN-MAPA(caduca): gate-sin-mapa"

run cad --formato tsv "$c0" "$c1"
t_ok "C15 tsv" "$(printf 'typecheck\tCADUCA\tsrc/a.ts\ndocs\tCONSERVA\t-\ngate-sin-mapa\tSIN-MAPA(caduca)\tsin-mapa\nsiempre-x\tCADUCA\tsiempre-re-corre\ne2e\tCADUCA\tsrc/a.ts')" "$OUT"

# ── C17: repo, shas y manifiesto; precedencia --repo > CAD_REPO > perfil ───────────────────────────
ENVX=(TF_MANIFEST="$MAN")
run cad "$c0" "$c1"
t_ok "C17 sin repo: rc 2" 2 "$RC"
t_contiene "C17 sin repo: nombra la variable" "$OUT" "CAD_REPO"
ENVX=(CAD_REPO="$R" TF_MANIFEST="$MAN")
run cad "$c0" 0123456789abcdef0123456789abcdef01234567
t_ok "C17 sha ausente: rc 2" 2 "$RC"
t_contiene "C17 sha ausente: nombra el sha" "$OUT" "0123456789abcdef0123456789abcdef01234567"
t_contiene "C17 sha ausente: nombra el repo" "$OUT" "$R"
run cad "$c0" zz
t_ok "C17 sha malformado: rc 2" 2 "$RC"
run cad "$c0"
t_ok "C17 un solo sha: rc 2" 2 "$RC"
ENVX=(CAD_REPO="$R")
run cad "$c0" "$c1"
t_ok "C17 sin manifiesto: rc 2" 2 "$RC"
t_contiene "C17 sin manifiesto: nombra la variable" "$OUT" "TF_MANIFEST"
ENVX=(CAD_REPO="$R" TF_MANIFEST="$MAN_VACIO")
run cad "$c0" "$c1"
t_ok "C17 manifiesto sin TF_GATE_IDS: rc 2" 2 "$RC"
ENVX=(CAD_REPO="$R" TF_MANIFEST="$MAN")
run cad --formato xml "$c0" "$c1"
t_ok "C17 formato desconocido: rc 2" 2 "$RC"
ENVX=(CAD_REPO="$R2" TF_MANIFEST="$MAN")
run cad --repo "$R" "$c0" "$c1"
t_ok "C17 --repo gana a CAD_REPO" 0 "$RC"
ENVX=(CAD_REPO="$R" TF_ESTACION=est-a TA_PERFIL="$W/perfil-r2.tsv" TF_MANIFEST="$MAN")
run cad "$c0" "$c1"
t_ok "C17 CAD_REPO gana al perfil" 0 "$RC"
ENVX=(TF_ESTACION=est-a TA_PERFIL="$W/perfil-r.tsv" TF_MANIFEST="$MAN")
run cad "$c0" "$c1"
t_ok "C17 solo perfil: rc 0" 0 "$RC"
ENVX=(TF_ESTACION=est-a TA_PERFIL="$W/perfil-r2.tsv" TF_MANIFEST="$MAN")
run cad "$c0" "$c1"
t_ok "C17 el perfil se consulta (su clon no tiene los shas): rc 2" 2 "$RC"

# ── C18: cad-lib.sh como CLI y como librería ───────────────────────────────────────────────────────
REC="$W/rec"; mkdir -p "$REC"
printf '%s\n' '{"gate_id":"typecheck","pr":5,"result":"PASS"}' > "$REC/a.json"
printf '%s\n' '{"gate_id":"gate-sin-mapa","pr":5,"result":"PASS"}' > "$REC/b.json"
printf '%s\n' '{"gate":"docs","pr":5,"result":"PASS"}' > "$REC/c.json"
printf '%s\n' '{"gate_id":"siempre-x","pr":5,"result":"PASS"}' > "$REC/d.json"
printf '%s\n' 'src/a.ts' > "$W/rutas.txt"
printf '%s\n' 'package.json' > "$W/rutas-univ.txt"
lib() { env -i PATH="$PATH" HOME="$W/home" LC_ALL=C LG_INSUMOS_CONF="$MAPA" bash "$SD/cad-lib.sh" "$@"; }
run lib "$W/rutas.txt" "$REC"
t_ok "C18 CLI: rc" 0 "$RC"
t_ok "C18 CLI: salida" "$(printf 'gate-sin-mapa SIN-MAPA(caduca)\nsiempre-x CADUCA (siempre re-corre)\ntypecheck CADUCA (src/a.ts)')" "$OUT"
run lib "$W/rutas-univ.txt" "$REC"
t_ok "C18 CLI universal" "UNIVERSAL: caducan TODOS" "$OUT"
run lib "$W/rutas.txt" "$W/no-existe"
t_ok "C18 CLI sin directorio de receipts: rc 2" 2 "$RC"
run lib "$W/rutas.txt"
t_ok "C18 CLI sin argumentos suficientes: rc 2" 2 "$RC"
OUT="$(env -i PATH="$PATH" HOME="$W/home" LC_ALL=C LG_INSUMOS_CONF="$MAPA" bash -c '
  set -euf
  antes="$(set +o)$-"
  . "$1"
  despues="$(set +o)$-"
  [ "$antes" = "$despues" ] && echo ESTADO-IGUAL
  type cad_gate_caduca >/dev/null && echo FUNCION-DEFINIDA
  set +e
  cad_cargar
  insumos_universales >/dev/null; insumos_de_gate typecheck >/dev/null; no_insumos_de_gate e2e >/dev/null
  case $- in *f*) echo NOGLOB-CONSERVADO;; esac
  set +f
  insumos_universales >/dev/null; insumos_de_gate typecheck >/dev/null; no_insumos_de_gate e2e >/dev/null
  case $- in *f*) ;; *) echo GLOB-CONSERVADO;; esac
' _ "$SD/cad-lib.sh" 2>&1)"
t_ok "C18 source no ejecuta nada ni cambia set -e/-u/-f" "$(printf 'ESTADO-IGUAL\nFUNCION-DEFINIDA\nNOGLOB-CONSERVADO\nGLOB-CONSERVADO')" "$OUT"

# ── C19: el set -f del mapa se respeta desde un directorio con src/ y supabase/ ────────────────────
mkdir -p "$W/con/src/x" "$W/con/supabase/migrations" "$W/vacio"
touch "$W/con/src/x/f.ts" "$W/con/supabase/migrations/m.sql"
ENVX=(CAD_REPO="$R" TF_MANIFEST="$MAN")
OUT_CON="$(cd "$W/con" && cad "$c4" "$c5" 2>&1)"
OUT_VACIO="$(cd "$W/vacio" && cad "$c4" "$c5" 2>&1)"
t_ok "C19 resultado idéntico con y sin src/ y supabase/ en el directorio actual" "$OUT_VACIO" "$OUT_CON"
t_contiene "C19 e2e caduca por supabase/** también desde el directorio con src/" "$OUT_CON" "CADUCAN: gate-sin-mapa siempre-x e2e (+ carveout_check siempre)"

# ── --help ────────────────────────────────────────────────────────────────────────────────────────
for s in caducidad.sh cad-lib.sh; do
  OUT="$(bash "$SD/$s" --help 2>&1)"; RC=$?
  t_ok "--help $s: rc" 0 "$RC"
  t_contiene "--help $s: tabla de rc" "$OUT" "rc EXACTOS"
done

# ── Mutante: un gate sin mapa que se CONSERVA ───────────────────────────────────────────────────────
if [ -z "${TF_SCRIPTS_DIR-}" ]; then
  t_mutante gate-sin-mapa-conserva cad-lib.sh "printf 'sin-mapa\\n'; return 3;" "printf 'sin-mapa\\n'; return 1;" "$HERE/test-caducidad.sh"
fi

t_fin
