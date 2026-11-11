#!/usr/bin/env bash
# abrir-ventana.sh — Cerrojo de la ventana de merge: ÚNICA vía del paquete para sellar una ventana.
#
# Uso:
#   abrir-ventana.sh <PR> <MARCADOR> <fichero-sello> [--acepto-conflictos]
#   abrir-ventana.sh --help
#
# Comprueba, en este orden, y la primera que falla corta SIN sellar (el sellador no se llama):
#   1. parámetros de la estación y directorio de hooks (precondiciones, rc 2);
#   2. el fichero de sello existe y no está vacío (antes de cualquier llamada a la red);
#   3. congelamiento por agenda: ventanas `inicioZ finZ título` en un fichero; dentro de una ventana se
#      rechaza salvo (a) GO del lead: fichero con línea `CITA:` no vacía y línea `PRS:` que lista el PR, o
#      (b) exención por diff: TF_CONGELAMIENTO_EXENTO_RE definida y TODO el diff del PR casa con ella.
#      Congelamiento declarado con el fichero ausente, ilegible o malformado => rechazo (fail-closed);
#      fichero vacío o congelamiento no declarado => sin congelamiento;
#   4. la PR y el estado del head vía `gh api`: local-gates=success y mergeable_state=clean (sin reintentos);
#   5. el head local del clon de la ventana coincide con el de la API;
#   6. INFORMA del coste de caducidad en recibos de otras PR (TF_EN_VUELO_DIR): NUNCA rechaza por ello;
#   7. censo L8: `git merge-tree --write-tree` de la propia PR contra main y de TODAS las demás PR abiertas
#      (todas las páginas) contra el árbol resultante; conflicto => rechazo salvo --acepto-conflictos
#      (entonces la lista va al sello); una PR que no se puede evaluar cuenta como conflicto;
#   8. hooks de instancia (TF_VENTANA_CHECKS_DIR): cada ejecutable recibe `<pr> <head> <dir-árbol-resultante>
#      <fichero-sello>` en orden léxico, también los de nombre oculto (con punto); rc distinto de 0 => rechazo.
# Solo si todo pasa sella con el sellador declarado (TF_SELLAR; por defecto bus-sellar.sh del skill talent-ceo).
# El clon de la ventana es propio de la estación: solo se hace `fetch` a refs/remotes/vw/<pr>; jamás checkout
# ni ejecución de código de la cabeza.
#
# Entorno:
#   TF_SLUG                       owner/repo de la forja (o atributo `repo` de la fila estacion del perfil)
#   TF_VENTANA_CLON               clon propio de la ventana (o atributo `clon`); NO puede ser TF_CLONE
#   TF_CLONE                      clon con el que se corren las suites (solo para rechazar la coincidencia)
#   TF_CONGELAMIENTO              fichero de ventanas de congelamiento (o atributo `congelamiento`)
#   GO_LEAD_FREEZE                fichero del GO del lead (CITA: / PRS:)
#   TF_CONGELAMIENTO_EXENTO_RE    ERE de rutas exentas (p. ej. ^apps/); sin definir no hay exención
#   TF_EN_VUELO_DIR               directorio de recibos *.json (gate_id, pr, result) para informar del coste
#   TF_VENTANA_CHECKS_DIR         directorio de hooks de instancia
#   TF_SELLAR, TA_ROL             sellador y rol con el que sella (--marcador M --rol "$TA_ROL" --src F)
#   TF_VENTANA_PLAZO              plazo en segundos de cada `git fetch` y cada `gh api` (por defecto 120); si no
#                                 terminan, rc 9 y no se sella
#   TF_ESTACION, TA_PERFIL        fila `estacion` del perfil de instancia (fuente de menor precedencia)
#   SOLO_CHEQUEO=1                corre todas las comprobaciones, imprime el veredicto y JAMÁS sella
# No existen DRY ni CEO_APPS_SOLO: no saltan ningún control.
#
# ── rc EXACTOS ─────────────────────────────────────────────────────────────────────────────────
#   0 = ventana sellada (o SOLO_CHEQUEO=1: el cerrojo pasaría)
#   2 = uso o precondición: parámetro sin valor (se nombra la variable), clon igual a TF_CLONE, git < 2.38,
#       hook no ejecutable, escribible por grupo u otros o de otro usuario, directorio de hooks ilegible
#   3 = L8: conflictos (con la propia PR o con otras PR abiertas)
#   4 = rechazo de ventana: sello ausente o vacío, congelamiento, local-gates, mergeable_state
#   5 = una comprobación extra (hook de instancia) devolvió rc distinto de 0
#   9 = clon o API: no se pudo traer la rama, head local distinto del de la API, la API no responde o
#       el fetch / la llamada no terminó en TF_VENTANA_PLAZO
#   otro = si sella y el sellador falla, su rc (ver bus-sellar.sh)
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-estacion.sh
. "$HERE/lib-estacion.sh" || exit 2
# shellcheck source=cad-lib.sh
. "$HERE/cad-lib.sh" || exit 2

fallo() { printf '%s\n' "$2"; exit "$1"; }
precond() { printf 'abrir-ventana.sh: PRECOND: %s\n' "$1" >&2; exit 2; }
uso() { echo "uso: abrir-ventana.sh <PR> <MARCADOR> <fichero-sello> [--acepto-conflictos]  (--help)" >&2; exit 2; }
ref_segura() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$1" != -* ]] && [[ "$1" != *..* ]] && git check-ref-format "refs/heads/$1" 2>/dev/null; }
# Seguro = de este usuario y sin permiso de escritura para grupo ni otros.
seguro() {
  local uid mode
  read -r uid mode < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
  [ "$uid" = "$(id -u)" ] && (( (8#$mode & 8#022) == 0 ))
}

acepto=0; pos=()
for a in "$@"; do
  case "$a" in
    --help | -h) est_ayuda "${BASH_SOURCE[0]}"; exit 0 ;;
    --acepto-conflictos) acepto=1 ;;
    -*) uso ;;
    *) pos+=("$a") ;;
  esac
done
[ "${#pos[@]}" -eq 3 ] || uso
pr="${pos[0]}"; marcador="${pos[1]}"; fichero="${pos[2]}"
[[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || precond "la PR debe ser un número: $pr"
[[ "$marcador" =~ ^[^[:space:][:cntrl:]]+$ ]] || precond "marcador vacío o con espacios"

# ── 1. Parámetros de la estación y hooks ───────────────────────────────────────────────────────────
slug="$(est_param '' TF_SLUG repo)" || slug=''
est_exige TF_SLUG "$slug" || exit 2
est_slug_ok "$slug" || precond "TF_SLUG no es owner/repo: $slug"
clon="$(est_param '' TF_VENTANA_CLON clon)" || clon=''
est_exige TF_VENTANA_CLON "$clon" || exit 2
[ -d "$clon" ] || precond "TF_VENTANA_CLON no es un directorio: $clon"
if [ -n "${TF_CLONE-}" ] && { [ "${clon%/}" = "${TF_CLONE%/}" ] || [ "$clon" -ef "$TF_CLONE" ]; }; then
  precond "TF_VENTANA_CLON no puede ser el clon con el que se corren las suites (TF_CLONE)"
fi
cf="$(est_param '' TF_CONGELAMIENTO congelamiento)" || cf=''
est_git_min || precond "git >= 2.38 requerido (git merge-tree --write-tree): $(git --version 2>&1)"
command -v jq >/dev/null 2>&1 || precond "falta jq"
command -v gh >/dev/null 2>&1 || precond "falta gh"
command -v timeout >/dev/null 2>&1 || precond "falta timeout (coreutils)"
plazo="${TF_VENTANA_PLAZO:-120}"
[[ "$plazo" =~ ^[1-9][0-9]{0,4}$ ]] || precond "TF_VENTANA_PLAZO debe ser un entero positivo de segundos: $plazo"
# Toda IO externa (git fetch, gh api) va acotada: si no termina en el plazo, se corta (rc 124/137) y se trata
# como fallo de clon o API (rc 9). GIT_TERMINAL_PROMPT=0: jamás se pregunta por credenciales.
export GIT_TERMINAL_PROMPT=0
con_plazo() { timeout -k 5 "$plazo" "$@"; }
if [ "${SOLO_CHEQUEO:-0}" != 1 ]; then
  est_exige TA_ROL "${TA_ROL-}" || exit 2
  est_sellador >/dev/null || precond "sellador no resoluble (TF_SELLAR ejecutable o bus-sellar.sh del skill talent-ceo)"
fi
hooks=()
if [ -n "${TF_VENTANA_CHECKS_DIR-}" ]; then
  hd="$TF_VENTANA_CHECKS_DIR"
  [ -d "$hd" ] && [ -r "$hd" ] && [ -x "$hd" ] || precond "directorio de hooks ilegible: $hd"
  seguro "$hd" || precond "directorio de hooks de otro usuario o escribible por grupo/otros: $hd"
  # dotglob: los nombres que empiezan por punto también son hooks (sin `.` ni `..`); orden léxico (LC_ALL=C).
  shopt -s dotglob
  for h in "$hd"/*; do
    case "${h##*/}" in . | ..) continue ;; esac
    [ -f "$h" ] || continue
    [ -x "$h" ] || precond "hook no ejecutable: $h"
    seguro "$h" || precond "hook de otro usuario o escribible por grupo/otros: $h"
    hooks+=("$h")
  done
  shopt -u dotglob
fi

# ── 2. Fichero de sello ─────────────────────────────────────────────────────────────────────────────
[ -f "$fichero" ] && [ -s "$fichero" ] || fallo 4 "RECHAZO: fichero de sello inexistente o vacío: $fichero (créalo ANTES del cerrojo)"

# ── 3. Congelamiento por agenda ─────────────────────────────────────────────────────────────────────
congel_en=''; pendiente_exencion=0; ahora=''
if [ -n "$cf" ]; then
  [ -f "$cf" ] && [ -r "$cf" ] || fallo 4 "RECHAZO: falta o no es legible el fichero de congelamiento $cf: no se abre ventana"
  mt="$(stat -c %Y -- "$cf" 2>/dev/null)" && ahora_s="$(date +%s)" || { mt=''; ahora_s=''; }
  if [[ "$mt" =~ ^[0-9]+$ ]] && [[ "$ahora_s" =~ ^[0-9]+$ ]] && [ $(( (ahora_s - mt) / 60 )) -gt 60 ]; then
    echo "AVISO: el fichero de congelamiento tiene $(( (ahora_s - mt) / 60 )) min de antigüedad; se usa tal cual"
  fi
  ahora="$(date -u +%Y-%m-%dT%H:%MZ)"
  # `|| [ -n "$ini" ]`: la última línea sin LF final también se procesa (read devuelve 1 pero rellena los campos).
  ini=''; fin=''; tit=''
  while read -r ini fin tit || [ -n "$ini" ]; do
    [ -n "$ini" ] || continue
    case "$ini" in '#'*) continue ;; esac
    [[ "$ini" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] && [[ "$fin" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] ||
      fallo 4 "RECHAZO: línea de congelamiento malformada en $cf: [$ini $fin]: no se abre ventana"
    if [[ "$ahora" > "$ini" || "$ahora" == "$ini" ]] && [[ "$ahora" < "$fin" ]]; then congel_en="$ini-$fin $tit"; fi
  done < "$cf"
fi
if [ -n "$congel_en" ]; then
  go="${GO_LEAD_FREEZE-}"
  if [ -n "$go" ] && [ -f "$go" ] && [ -s "$go" ] && grep -qE '^CITA:[[:space:]]*[^[:space:]]' "$go" && grep -qE "^PRS:(.*[ ,])?$pr([ ,]|\$)" "$go"; then
    echo "CONGELAMIENTO EXCEPTUADO por GO del lead ($go, md5 $(md5sum "$go" | cut -c1-8))"
  elif [ -n "${TF_CONGELAMIENTO_EXENTO_RE-}" ]; then
    pendiente_exencion=1
  else
    fallo 4 "RECHAZO CONGELAMIENTO: $ahora está dentro de la ventana del directo [$congel_en] (2 h desde la hora del live). Sin GO del lead (GO_LEAD_FREEZE) o exención por diff (TF_CONGELAMIENTO_EXENTO_RE) no se abre ventana."
  fi
fi

# ── 4-5. PR, estado del head y clon de la ventana ───────────────────────────────────────────────────
est_tmp_crear || precond "no pude crear el directorio temporal"
trap est_tmp_limpiar EXIT
j="$(con_plazo gh api "repos/$slug/pulls/$pr" 2>/dev/null)" || fallo 9 "RECHAZO: la API no devolvió la PR #$pr"
head="$(jq -r '.head.sha // ""' <<< "$j" 2>/dev/null)"; ref="$(jq -r '.head.ref // ""' <<< "$j" 2>/dev/null)"
ms="$(jq -r '.mergeable_state // ""' <<< "$j" 2>/dev/null)"
est_sha40_ok "$head" || fallo 9 "RECHAZO: la API no devolvió un head válido para #$pr"
ref_segura "$ref" || fallo 9 "RECHAZO: nombre de rama no admisible para #$pr: $ref"
git -C "$clon" rev-parse --git-dir >/dev/null 2>&1 || fallo 9 "RECHAZO: $clon no es un repo git"
con_plazo git -C "$clon" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/$ref:refs/remotes/vw/$pr" </dev/null 2>/dev/null || fallo 9 "RECHAZO: no puedo traer $ref (fallo o plazo de ${plazo} s agotado)"
[ "$(git -C "$clon" rev-parse "refs/remotes/vw/$pr" 2>/dev/null)" = "$head" ] || fallo 9 "RECHAZO: head local != API"
lg="$(con_plazo gh api "repos/$slug/commits/$head/status" --jq '[.statuses[]|select(.context=="local-gates")|.state]|first // "none"' 2>/dev/null)" || fallo 9 "RECHAZO: la API no devolvió el estado de $head"
echo "PR #$pr head=${head:0:9} mergeable_state=$ms local-gates=$lg"
[ "$lg" = "success" ] || fallo 4 "RECHAZO: local-gates no es success"
[ "$ms" = "clean" ] || fallo 4 "RECHAZO: mergeable_state=$ms (no clean)"
files="$(git -C "$clon" diff --name-only "origin/main...refs/remotes/vw/$pr")"
echo "ficheros=$(printf '%s\n' "$files" | grep -c . || true)"
if [ "$pendiente_exencion" = 1 ]; then
  re="$TF_CONGELAMIENTO_EXENTO_RE"; exento=1; n=0
  printf '' | grep -qE -e "$re" 2>/dev/null; [ $? -le 1 ] || exento=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    n=$((n + 1))
    printf '%s\n' "$l" | grep -qE -e "$re" || exento=0
  done <<< "$files"
  if [ "$exento" = 1 ] && [ "$n" -gt 0 ]; then
    echo "CONGELAMIENTO EXCEPTUADO: el diff de #$pr está 100 % dentro de $re"
  else
    fallo 4 "RECHAZO CONGELAMIENTO: $ahora está dentro de la ventana del directo [$congel_en] y el diff de #$pr no está 100 % dentro de $re. Sin GO del lead no se abre ventana."
  fi
fi
rutas="$EST_TMP/rutas"; printf '%s\n' "$files" > "$rutas"
anexos=''

# ── 6. Coste de caducidad (informativo; la ventana NUNCA se rechaza por esto) ───────────────────────
if [ -n "${TF_EN_VUELO_DIR-}" ]; then
  if [ ! -d "$TF_EN_VUELO_DIR" ]; then
    echo "AVISO: TF_EN_VUELO_DIR no es un directorio ($TF_EN_VUELO_DIR): no se informa del coste de caducidad"
  elif ! cad_cargar 2>/dev/null; then
    echo "AVISO: sin mapa de insumos: no se informa del coste de caducidad"
  else
    uni=0; cad_universal "$rutas" && uni=1
    recibos="$(for r in "$TF_EN_VUELO_DIR"/*.json; do
      [ -f "$r" ] || continue
      jq -r 'select(.result == "PASS" and .pr != null and ((.gate_id // .gate // "") != "")) | [(.pr | tostring), (.gate_id // .gate)] | @tsv' "$r" 2>/dev/null
    done | sort -u)"
    ult=''; tot=0; k=0; gk=''
    emitir_coste() {
      [ -n "$ult" ] && [ "$k" -gt 0 ] || return 0
      coste_linea="COSTE #$ult: $k de $tot recibos caducan:$gk"
      echo "$coste_linea"
      anexos+="$coste_linea"$'\n'
    }
    while IFS=$'\t' read -r p g; do
      [ -n "$p" ] || continue
      [ "$p" != "$pr" ] || continue
      if [ "$p" != "$ult" ]; then
        emitir_coste
        ult="$p"; tot=0; k=0; gk=''
      fi
      tot=$((tot + 1))
      cad_gate_caduca "$g" "$rutas" >/dev/null; crc=$?
      if [ "$uni" = 1 ] || [ "$crc" != 1 ]; then k=$((k + 1)); gk="$gk $g"; fi
    done <<< "$recibos"
    emitir_coste
  fi
fi

# ── 7. Censo L8 ─────────────────────────────────────────────────────────────────────────────────────
salida_mt="$(git -C "$clon" merge-tree --write-tree --name-only origin/main "refs/remotes/vw/$pr" 2>/dev/null)"; mt_rc=$?
if [ "$mt_rc" != 0 ]; then
  propios=''; primero=1
  while IFS= read -r l; do
    if [ "$primero" = 1 ]; then primero=0; continue; fi
    [ -n "$l" ] || break
    propios="${propios:+$propios,}$l"
  done <<< "$salida_mt"
  fallo 3 "RECHAZO L8: merge-tree de la propia pieza conflicta con main (rc=$mt_rc): ${propios:-sin detalle}"
fi
arbol="${salida_mt%%$'\n'*}"
at='@'
sim="$(GIT_AUTHOR_NAME=ventana GIT_AUTHOR_EMAIL="ventana${at}ejemplo.invalid" GIT_COMMITTER_NAME=ventana GIT_COMMITTER_EMAIL="ventana${at}ejemplo.invalid" \
  git -C "$clon" commit-tree "$arbol" -p origin/main -m "sim $pr" </dev/null)" || fallo 9 "RECHAZO: no pude crear el commit simulado"
lista="$(con_plazo gh api --paginate "repos/$slug/pulls?state=open&base=main&per_page=100" --jq '.[] | "\(.number) \(.head.ref)"' 2>/dev/null)" || fallo 9 "RECHAZO: la API no devolvió las PR abiertas"
conf=''
while read -r n r; do
  [ -n "$n" ] || continue
  [ "$n" != "$pr" ] || continue
  if ! [[ "$n" =~ ^[0-9]+$ ]] || ! ref_segura "$r"; then conf="$conf #$n(no-evaluable)"; continue; fi
  con_plazo git -C "$clon" fetch -q origin "+refs/heads/$r:refs/remotes/vw/$n" </dev/null 2>/dev/null; frc=$?
  # Un transporte que no termina (124 plazo, 137 cortado) es fallo de clon o API: rc 9, no una PR «no evaluable».
  if [ "$frc" = 124 ] || [ "$frc" = 137 ]; then fallo 9 "RECHAZO: el fetch de #$n no terminó en ${plazo} s"; fi
  if [ "$frc" != 0 ]; then conf="$conf #$n(no-evaluable)"; continue; fi
  out="$(git -C "$clon" merge-tree --write-tree --name-only "$sim" "refs/remotes/vw/$n" </dev/null 2>/dev/null)"; rc=$?
  if [ "$rc" = 1 ]; then
    nombres=''; primero=1
    while IFS= read -r l; do
      if [ "$primero" = 1 ]; then primero=0; continue; fi
      [ -n "$l" ] || break
      nombres="${nombres:+$nombres,}$l"
    done <<< "$out"
    conf="$conf #$n($nombres)"
  elif [ "$rc" != 0 ]; then
    conf="$conf #$n(no-evaluable)"
  fi
done <<< "$lista"
if [ -n "$conf" ]; then
  echo "L8 conflictos contra el árbol resultante:$conf"
  [ "$acepto" = 1 ] || fallo 3 "RECHAZO L8: pasa --acepto-conflictos solo si esos dueños ya tienen el aviso en el sello."
  anexos+="L8 (abrir-ventana): conflictan tras este merge:$conf → rebase en canal avisado en este mismo sello."$'\n'
fi

# ── 8. Hooks de instancia ───────────────────────────────────────────────────────────────────────────
if [ "${#hooks[@]}" -gt 0 ]; then
  dir_arbol="$EST_TMP/arbol"; mkdir -p "$dir_arbol"
  git -C "$clon" archive "$arbol" | tar -x --no-same-owner -C "$dir_arbol" || fallo 9 "RECHAZO: no pude extraer el árbol resultante"
  for h in "${hooks[@]}"; do
    ( cd "$dir_arbol" && "$h" "$pr" "$head" "$dir_arbol" "$fichero" ); hrc=$?
    [ "$hrc" = 0 ] || fallo 5 "RECHAZO hook ${h##*/}: rc=$hrc"
  done
fi

# ── Veredicto ───────────────────────────────────────────────────────────────────────────────────────
if [ "${SOLO_CHEQUEO:-0}" = 1 ]; then echo "SOLO_CHEQUEO=1: cerrojo PASARÍA (no sello)"; exit 0; fi
if [ -n "$anexos" ]; then printf '\n%s' "$anexos" >> "$fichero"; fi
echo "CERROJO OK: sello $marcador"
est_sellar "$marcador" "$fichero"
exit $?
