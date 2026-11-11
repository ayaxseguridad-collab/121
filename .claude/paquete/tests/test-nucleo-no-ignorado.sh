#!/usr/bin/env bash
# test-nucleo-no-ignorado.sh — la invariante A10 de validate-package.sh: con --estado instancia y la
# raíz dentro de un repo git, ningún fichero de la LISTA DECLARADA del núcleo (formato de
# instalacion/NUCLEO.sha256, trasladado a las rutas del clon) puede estar ignorado por el repo destino.
# Mide la lista, no el disco: un .pyc generado no es núcleo; un fichero de la lista con cualquier
# extensión ignorada es FAIL; uno de la lista ausente en disco también es FAIL. Fixtures: repo con `*.log`
# ignorado y un .log del núcleo (FAIL), repo sin esa regla (PASS), `__pycache__/` ignorado con un .pyc en
# disco fuera de la lista (PASS), fichero del núcleo ausente (FAIL), sin repo o sin lista o distribución
# (SKIP motivado, nunca PASS), sin excepciones por extensión ni ruta y un mutante con la comprobación
# desactivada que deja pasar la fixture roja. Se ejecuta desde la raíz del paquete.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
V_REAL="$ROOT/scripts/paquete/validate-package.sh"
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1: esperado=$2 real=$3"; fi; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git ausente en este entorno (motivo declarado, no PASS)"; echo "RESULTADO: PASS=0 FAIL=0 SKIP=1 TOTAL=1"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: sha256sum ausente en este entorno (motivo declarado, no PASS)"; echo "RESULTADO: PASS=0 FAIL=0 SKIP=1 TOTAL=1"; exit 0; }

# Fixture: copia del paquete (skills + directorio del paquete) bajo $1 y SU lista declarada, calculada del
# árbol copiado (hermética: no depende del sello vigente). Sin repo hasta que se pida.
mk_fixture() { # $1 = destino
  mkdir -p "$1/scripts" "$1/instalacion"
  cp -a "$ROOT/skills" "$1/skills"
  cp -a "$ROOT/scripts/paquete" "$1/scripts/paquete"
  # Hermética frente a lo que dejen las suites Python en el árbol: ni __pycache__/ ni *.pyc entran en la copia ni en la lista.
  find "$1/skills" "$1/scripts/paquete" -name __pycache__ -type d -prune -exec rm -rf {} +
  find "$1/skills" "$1/scripts/paquete" -name '*.pyc' -type f -delete
  (cd "$1" && find skills scripts/paquete -type f | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$1/instalacion/NUCLEO.sha256"
  adjudicar "$1/skills"
}
# Añade a la lista declarada de la fixture $1 el fichero $2 (ruta relativa a la fixture) ya existente.
a_la_lista() { (cd "$1" && sha256sum "$2" >> instalacion/NUCLEO.sha256); }
# Instancia neutral adjudicada (anexos e identidad de ejemplo): sin ella el validador corta antes de A10.
adjudicar() { # $1 = raíz skills
  local R="$1" sk
  for sk in talent-channel-operation talent-merger talent-ceo; do
    printf 'Anexo propio de ejemplo\n' > "$R/$sk/references/anexo-neutral.md"
  done
  cat > "$R/talent-channel-operation/scripts/repo-identity.conf" <<'EOF'
PKG_IDENTITY_PROJECT=ejemplo
TCO_REPO_DIR=Repo-Ejemplo
TCO_REPO_SLUG=example/Repo-Ejemplo
TCO_REPO_STACK=supabase
TCO_ANEXO_FILE=references/anexo-neutral.md
TCO_LINEAR_INPROGRESS_STATE=00000000-0000-4000-8000-000000000007
TCO_LINEAR_INREVIEW_STATE=00000000-0000-4000-8000-000000000008
TCO_POSTMERGE_CMD=true
TCO_HOST_ENV_REL=Repo-Ejemplo/entorno.conf
TCO_TF_MANIFEST=/tmp/instancia-neutral/manifiestos/ejemplo.conf
EOF
  printf 'PKG_IDENTITY_PROJECT=ejemplo\n' > "$R/talent-orchestrator/scripts/repo-identity.conf"
  cat > "$R/talent-merger/references/anexo-neutral.md" <<'EOF'
repinear
lock table supabase_migrations.schema_migrations in exclusive mode;
class() { printf
: "${PROC_M13_CLASS_FILE:=/dev/null}"
if exists (select 1 from supabase_migrations.schema_migrations where version
GUARDA DE FORMA
no se interpola en SQL
TM_FLOCK_CANONICO_TRUSTED
PROCEDENCIA INDEPENDIENTE: NO MEDIDA, NO GARANTIZABLE DESDE ESTE ARTEFACTO
Se declara NO MEDIDO, no cerrado, y así se mantiene
preflight-issue.sh
EOF
}
a10() { # $1 = fixture, $2 = estado, $3 = validador (opcional), resto = flags extra -> solo las líneas A10
  local f="$1" e="$2" v="${3:-$1/scripts/paquete/validate-package.sh}"
  shift 3 2>/dev/null || shift $#
  bash "$v" --root "$f/skills" --estado "$e" "$@" 2>&1 | grep ' A10-no-ignorado' || true
}
tiene() { printf '%s\n' "$1" | grep -q "^$2 paquete $3 "; } # $1 salida, $2 estado, $3 nombre del check
rc_de() { if "$@"; then echo 0; else echo 1; fi; }

# 1. Repo con `*.log` ignorado y un .log DEL NÚCLEO (en la lista) -> FAIL con la lista.
F1="$T/f1"; mk_fixture "$F1"; git -C "$F1" init -q
printf '*.log\n' > "$F1/.gitignore"
mkdir -p "$F1/skills/coderabbit-talent/evals/corrida"
printf 'dato\n' > "$F1/skills/coderabbit-talent/evals/corrida/tools.log"
a_la_lista "$F1" skills/coderabbit-talent/evals/corrida/tools.log
L1="$(a10 "$F1" instancia)"
check 'repo con *.log ignorado y un .log del núcleo -> FAIL' 0 "$(rc_de tiene "$L1" FAIL A10-no-ignorado)"
check 'el FAIL lista el fichero ignorado' 0 "$(rc_de grep -q 'evals/corrida/tools.log' <<< "$L1")"

# 2. Repo sin esa regla, mismo .log -> PASS.
F2="$T/f2"; mk_fixture "$F2"; git -C "$F2" init -q
mkdir -p "$F2/skills/coderabbit-talent/evals/corrida"
printf 'dato\n' > "$F2/skills/coderabbit-talent/evals/corrida/tools.log"
a_la_lista "$F2" skills/coderabbit-talent/evals/corrida/tools.log
check 'repo sin la regla -> PASS' 0 "$(rc_de tiene "$(a10 "$F2" instancia)" PASS A10-no-ignorado)"

# 3. El árbol real, con un destino que ignora *.log -> PASS (la lista no lleva ningún .log).
F3="$T/f3"; mk_fixture "$F3"; git -C "$F3" init -q; printf '*.log\n' > "$F3/.gitignore"
check 'paquete real frente a un destino que ignora *.log -> PASS' 0 "$(rc_de tiene "$(a10 "$F3" instancia)" PASS A10-no-ignorado)"
check 'ningún *.log bajo skills/*/evals' 0 "$([ -z "$(find "$ROOT"/skills/*/evals -name '*.log' -print -quit 2>/dev/null)" ] && echo 0 || echo 1)"

# 4. __pycache__/ ignorado y un .pyc en disco dentro de un miembro (fuera de la lista) -> PASS: no es núcleo.
F4="$T/f4"; mk_fixture "$F4"; git -C "$F4" init -q; printf '__pycache__/\n*.pyc\n' > "$F4/.gitignore"
mkdir -p "$F4/skills/talent-pm/__pycache__"; printf 'x\n' > "$F4/skills/talent-pm/__pycache__/m.cpython-312.pyc"
L4="$(a10 "$F4" instancia)"
check '__pycache__ ignorado y .pyc generado en disco (no es núcleo) -> PASS' 0 "$(rc_de tiene "$L4" PASS A10-no-ignorado)"
check '... y sin FAIL de presencia' 1 "$(rc_de tiene "$L4" FAIL A10-no-ignorado-presencia)"

# 5. Sin excepción por extensión: un .pyc QUE ESTÁ en la lista y el destino ignora -> FAIL.
F5="$T/f5"; mk_fixture "$F5"; git -C "$F5" init -q; printf '*.pyc\n' > "$F5/.gitignore"
printf 'x\n' > "$F5/skills/talent-pm/declarado.pyc"; a_la_lista "$F5" skills/talent-pm/declarado.pyc
check 'un .pyc de la lista ignorado por el destino -> FAIL (sin excepción por extensión)' 0 "$(rc_de tiene "$(a10 "$F5" instancia)" FAIL A10-no-ignorado)"
F5b="$T/f5b"; mk_fixture "$F5b"; git -C "$F5b" init -q; printf '*.txt\n' > "$F5b/.gitignore"
check 'destino que ignora *.txt -> FAIL' 0 "$(rc_de tiene "$(a10 "$F5b" instancia)" FAIL A10-no-ignorado)"
F5c="$T/f5c"; mk_fixture "$F5c"; git -C "$F5c" init -q; printf 'skills/talent-pm/\n' > "$F5c/.gitignore"
check 'destino que ignora un directorio del paquete -> FAIL (sin excepción por ruta)' 0 "$(rc_de tiene "$(a10 "$F5c" instancia)" FAIL A10-no-ignorado)"

# 6. Fichero del núcleo (en la lista) que NO existe en disco -> FAIL de presencia, nunca silencio.
F6="$T/f6"; mk_fixture "$F6"; git -C "$F6" init -q
rm "$F6/skills/talent-pm/CHANGELOG.md"
L6="$(a10 "$F6" instancia)"
check 'fichero del núcleo ausente en disco -> FAIL A10-no-ignorado-presencia' 0 "$(rc_de tiene "$L6" FAIL A10-no-ignorado-presencia)"
check '... y la línea nombra el fichero ausente' 0 "$(rc_de grep -q 'talent-pm/CHANGELOG.md' <<< "$L6")"

# 7. SKIP motivado, nunca PASS: sin repo git, sin lista declarada, distribución.
F7="$T/f7"; mk_fixture "$F7"
L7="$(a10 "$F7" instancia)"
check 'sin repo git -> SKIP motivado' 0 "$(rc_de tiene "$L7" SKIP A10-no-ignorado)"
check 'el SKIP sin repo declara su motivo' 0 "$(rc_de grep -q 'sin repo git' <<< "$L7")"
check 'sin repo git NO sale PASS' 1 "$(rc_de tiene "$L7" PASS A10-no-ignorado)"
F7b="$T/f7b"; mk_fixture "$F7b"; git -C "$F7b" init -q; rm "$F7b/instalacion/NUCLEO.sha256"
L7b="$(a10 "$F7b" instancia)"
check 'repo sin lista declarada -> SKIP motivado (no PASS)' 0 "$(rc_de tiene "$L7b" SKIP A10-no-ignorado)"
check 'el SKIP sin lista declara su motivo' 0 "$(rc_de grep -q 'lista declarada del núcleo no disponible' <<< "$L7b")"
check 'sin lista NO sale PASS' 1 "$(rc_de tiene "$L7b" PASS A10-no-ignorado)"
check 'distribución -> SKIP' 0 "$(rc_de tiene "$(a10 "$F1" distribucion)" SKIP A10-no-ignorado)"

# 8. --nucleo apunta a una lista fuera del árbol (así la recibe un clon, que no lleva instalacion/).
F8="$T/f8"; mk_fixture "$F8"; git -C "$F8" init -q; printf '*.txt\n' > "$F8/.gitignore"
mv "$F8/instalacion/NUCLEO.sha256" "$T/lista-externa"
check '--nucleo con la lista fuera del árbol mide igual (FAIL por *.txt)' 0 "$(rc_de tiene "$(a10 "$F8" instancia "" --nucleo "$T/lista-externa")" FAIL A10-no-ignorado)"
printf 'no es una lista\n' > "$T/lista-mala"
check 'lista malformada -> FAIL, no silencio' 0 "$(rc_de tiene "$(a10 "$F8" instancia "" --nucleo "$T/lista-mala")" FAIL A10-no-ignorado)"

# 9. Lo ya versionado aunque case con el .gitignore llega al clon: no se reporta.
F9="$T/f9"; mk_fixture "$F9"; git -C "$F9" init -q
mkdir -p "$F9/skills/coderabbit-talent/evals/corrida"; printf 'dato\n' > "$F9/skills/coderabbit-talent/evals/corrida/tools.log"
a_la_lista "$F9" skills/coderabbit-talent/evals/corrida/tools.log
git -C "$F9" add skills/coderabbit-talent/evals/corrida/tools.log   # versionado ANTES de existir la regla
printf '*.log\n' > "$F9/.gitignore"
check 'fichero ya versionado no se reporta como ignorado -> PASS' 0 "$(rc_de tiene "$(a10 "$F9" instancia)" PASS A10-no-ignorado)"

# 9b. Repo REAL, fichero de la lista ignorado y la detección de git falla (rev-parse con rc 128): no es «sin repo».
# Debe salir rc distinto de 0 y nunca PASS ni SKIP de A10; el doble solo sustituye rev-parse y delega lo demás.
mkdir -p "$T/doble"
REAL_GIT="$(command -v git)"; export REAL_GIT
cat > "$T/doble/git" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = rev-parse ] && exit 128; done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$T/doble/git"
F9b="$T/f9b"; mk_fixture "$F9b"; git -C "$F9b" init -q; printf '*.txt\n' > "$F9b/.gitignore"
LD="$(PATH="$T/doble:$PATH" a10 "$F9b" instancia)"
PATH="$T/doble:$PATH" bash "$F9b/scripts/paquete/validate-package.sh" --root "$F9b/skills" --estado instancia >/dev/null 2>&1; RCD=$?
check 'rev-parse con rc 128 en un repo real: FAIL de A10 (no se puede medir)' 0 "$(rc_de tiene "$LD" FAIL A10-no-ignorado)"
check '... ni SKIP ni PASS de A10' 11 "$(rc_de tiene "$LD" SKIP A10-no-ignorado)$(rc_de tiene "$LD" PASS A10-no-ignorado)"
check '... y el validador sale con rc distinto de 0' 1 "$([ "$RCD" -ne 0 ] && echo 1 || echo 0)"
# Sin ninguna marca de repo, rev-parse con rc 128 sigue siendo la ausencia acreditada: SKIP (el caso de la sección 7).
LD2="$(PATH="$T/doble:$PATH" a10 "$F7" instancia)"
check 'sin marca de repo y rev-parse 128 -> SKIP motivado (ausencia acreditada)' 0 "$(rc_de tiene "$LD2" SKIP A10-no-ignorado)"

# 9c. Una marca .git que es un enlace ROTO también es marca de repo: A10 no se puede medir -> FAIL, nunca SKIP.
F9c="$T/f9c"; mk_fixture "$F9c"; git -C "$F9c" init -q; printf '*.txt\n' > "$F9c/.gitignore"
mv "$F9c/.git" "$F9c/.git-guardado"; ln -s "$T/destino-inexistente" "$F9c/.git"
L9c="$(a10 "$F9c" instancia)"
bash "$F9c/scripts/paquete/validate-package.sh" --root "$F9c/skills" --estado instancia >/dev/null 2>&1; RC9C=$?
check '.git como enlace roto: FAIL de A10 (no se puede medir)' 0 "$(rc_de tiene "$L9c" FAIL A10-no-ignorado)"
check '... ni SKIP ni PASS de A10' 11 "$(rc_de tiene "$L9c" SKIP A10-no-ignorado)$(rc_de tiene "$L9c" PASS A10-no-ignorado)"
check '... y el validador sale con rc distinto de 0' 1 "$([ "$RC9C" -ne 0 ] && echo 1 || echo 0)"
rm "$F9c/.git"; mv "$F9c/.git-guardado" "$F9c/.git"
check '.git restaurado: FAIL por el fichero ignorado' 0 "$(rc_de grep -q 'ignorados por el repo destino' <<< "$(a10 "$F9c" instancia)")"

# 10. Mutación: con la comprobación desactivada la fixture roja deja de dar FAIL.
MUT="$F1/scripts/paquete/validate-package.sh"
cp "$V_REAL" "$MUT"
sed -i 's/^  capa_a_nucleo_no_ignorado$/  :/' "$MUT"
check 'mutante: la comprobación desactivada ya no aparece' 1 "$(rc_de tiene "$(a10 "$F1" instancia "$MUT")" FAIL A10-no-ignorado)"
cp "$V_REAL" "$MUT"
check 'restaurado: la fixture roja vuelve a dar FAIL' 0 "$(rc_de tiene "$(a10 "$F1" instancia "$MUT")" FAIL A10-no-ignorado)"

echo "RESULTADO: PASS=$PASS FAIL=$FAIL SKIP=0 TOTAL=$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
