#!/usr/bin/env bash
# validate-package.sh — validador del paquete de skills de fábrica (plan v4 §4, sellado
# por 4 rondas de auditoría). Capa A (estructural del paquete) + Capa B (doctrina-como-test:
# asserts deterministas sobre el TEXTO de los skills vía <skill>/invariants.tsv).
#
# FRONTERA DECLARADA (R3): este validador NO verifica la paridad byte-a-byte motor↔producto;
# eso es de sync-package.sh --check. Aquí: completitud del paquete + invariantes doctrinales.
#
# rc: 0 = todo PASS con ≥1 invariante evaluada · 1 = alguna verificación FALLÓ (acumulativo)
#     2 = precondición/malformación (fail-fast; también anti-vacuo y trap ERR).
# Estados (TAL-8037): --estado instancia (DEFAULT, lo de siempre: exige los overlays por repo
#     — repo-identity.conf y anexos — presentes) | --estado distribucion (el ZIP: NINGÚN overlay
#     de casa; un overlay PRESENTE es FAIL, cada overlay exacto exige su `<ruta>.example` y las
#     filas de invariantes cuyo target es un overlay ausente salen como SKIP-OVERLAY, aparte de
#     PASS/FAIL y de las evaluadas).
# En instancia, la doctrina del anexo PROC-M13 exige stack supabase; ninguno/convex
# salen como SKIP declarado con motivo, separados de PASS y de las evaluadas.
# Uso: validate-package.sh [--root <dir-skills>] [--strict-set] [--estado instancia|distribucion]
#      validate-package.sh --self-test | --help
set -euo pipefail
trap 'printf "ERROR: fallo imprevisto del validador (línea %s)\n" "$LINENO" >&2; exit 2' ERR
SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-package.sh
. "$SC_DIR/lib-package.sh"

PASS_N=0; FAIL_N=0; SKIP_N=0; SKIP_STACK_N=0; TOTAL_EVAL=0; CHECKS_A=0
ESTADO=instancia
report() { # PASS|FAIL skill check detalle
  local st="$1" sk="$2" ck="$3" det="$4"
  printf '%s %s %s — %s\n' "$st" "$sk" "$ck" "$det"
  case "$st" in
    PASS) PASS_N=$((PASS_N+1)) ;;
    SKIP-OVERLAY) SKIP_N=$((SKIP_N+1)) ;;
    SKIP) SKIP_STACK_N=$((SKIP_STACK_N+1)) ;;
    *) FAIL_N=$((FAIL_N+1)) ;;
  esac
}

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}"; }

check_deps() {
  local d
  for d in grep awk realpath find tr wc head mktemp sort sed od; do
    command -v "$d" >/dev/null 2>&1 || pkg_die2 "dependencia ausente: $d"
  done
}

resolver_root() { # $1 = --root explícito o vacío
  if [ -n "$1" ]; then
    [ -d "$1" ] || pkg_die2 "--root no existe o no es dir: $1"
    ROOT="$(cd "$1" && pwd)"
    [ -f "$ROOT/skill-creator/assets/package.manifest" ] || pkg_die2 "sin manifiesto en $ROOT/skill-creator/assets/package.manifest"
  elif [ -f "./.claude/skills/skill-creator/assets/package.manifest" ]; then
    ROOT="$(cd ./.claude/skills && pwd)"
  elif [ -f "./skills/skill-creator/assets/package.manifest" ]; then
    ROOT="$(cd ./skills && pwd)"
  else
    pkg_die2 "raíz indeterminable: sin --root y sin ancla de manifiesto en ./.claude/skills ni ./skills"
  fi
}

# --- Capa A ---------------------------------------------------------------------------------
capa_a_member() { # $1 = member. Devuelve 0 siempre (acumula); setea MEMBER_OK_TSV=yes|no
  local m="$1" dir="$ROOT/$1" skillmd sec n name
  MEMBER_OK_TSV=no
  CHECKS_A=$((CHECKS_A+1))
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then report FAIL "$m" A1-dir "miembro ausente o symlink (la forma del árbol es contrato)"; return 0; fi
  report PASS "$m" A1-dir "directorio presente"
  skillmd="$dir/SKILL.md"
  if [ ! -f "$skillmd" ]; then report FAIL "$m" A2-skillmd "SKILL.md ausente"; return 0; fi
  report PASS "$m" A2-skillmd "SKILL.md presente"
  n="$(command grep -cE '^## Paquete de fábrica[[:space:]]*$' -- "$skillmd")" || n=0
  if [ "$n" -eq 0 ]; then report FAIL "$m" A3-marker "sección '## Paquete de fábrica' ausente"
  elif [ "$n" -gt 1 ]; then report FAIL "$m" A3-marker "marcador duplicado ($n) — concatenaría cuerpos"
  else
    report PASS "$m" A3-marker "marcador único"
    sec="$(awk '/^## Paquete de fábrica[[:space:]]*$/{f=1;next} /^## /{f=0} f' "$skillmd")"
    for name in "${PKG_MEMBERS[@]}"; do
      if command grep -Eq "(^|[^a-z0-9-])$name([^a-z0-9-]|\$)" <<< "$sec"; then
        report PASS "$m" "A4-name-$name" "nombre en la sección"
      else
        report FAIL "$m" "A4-name-$name" "nombre AUSENTE en la sección del paquete"
      fi
    done
  fi
  if [ -f "$dir/CHANGELOG.md" ]; then report PASS "$m" A5-changelog "CHANGELOG.md presente"
  else report FAIL "$m" A5-changelog "CHANGELOG.md ausente"; fi
  if [ -f "$dir/invariants.tsv" ]; then report PASS "$m" A6-tsv "invariants.tsv presente"; MEMBER_OK_TSV=yes
  else report FAIL "$m" A6-tsv "invariants.tsv ausente"; fi
  return 0
}

capa_a_strict_set() {
  local d base ok
  while IFS= read -r d; do
    base="$(basename "$d")"; ok=no
    local mm; for mm in "${PKG_MEMBERS[@]}"; do [ "$mm" = "$base" ] && ok=yes && break; done
    if [ "$ok" = no ]; then report FAIL "(raíz)" A8-extra "dir/symlink fuera del manifiesto: $base"; fi
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | sort)
  return 0
}

# ¿El overlay KEY=VALUE $1 trae algún valor marcador del .example (pkg_es_marcador_example)? rc 1 e imprime las claves si sí.
overlay_marcadores() {
  local line k v bad=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|"#"*) continue ;; *=*) k="${line%%=*}"; v="${line#*=}"; if pkg_es_marcador_example "$v"; then bad="$bad $k"; fi ;; esac
  done < "$1"
  [ -z "$bad" ] || { printf '%s' "${bad# }"; return 1; }
  return 0
}

capa_a_overlays() {
  local e m ruta hit f
  for e in ${PKG_OVERLAY_EXACT[@]+"${PKG_OVERLAY_EXACT[@]}"}; do
    m="${e%%:*}"; ruta="${e#*:}"
    if [ "$ESTADO" = distribucion ]; then
      # La distribución NO lleva identidad de casa: el overlay PRESENTE es una fuga; ausente es lo correcto.
      if [ -f "$ROOT/$m/$ruta" ]; then report FAIL "$m" A9-overlay "overlay de casa PRESENTE en la distribución: $ruta (la distribución no lleva identidad)"
      else report PASS "$m" A9-overlay "overlay ausente (distribución): $ruta"; fi
      if [ -f "$ROOT/$m/$ruta.example" ]; then report PASS "$m" A9-overlay-example "plantilla presente: $ruta.example"
      else report FAIL "$m" A9-overlay-example "plantilla AUSENTE: $ruta.example (la instancia nace de ella)"; fi
    else
      if [ -f "$ROOT/$m/$ruta" ]; then
        report PASS "$m" A9-overlay "overlay presente: $ruta"
        # [TAL-8037/M3] Una instancia NO puede conservar marcadores PENDIENTE-* (un placeholder no es un valor adjudicado).
        if marc="$(overlay_marcadores "$ROOT/$m/$ruta")"; then report PASS "$m" A9-overlay-marcador "sin marcadores de pendiente: $ruta"
        else report FAIL "$m" A9-overlay-marcador "el overlay conserva marcadores de pendiente ($marc): $ruta — adjudica los valores de la instancia"; fi
      else report FAIL "$m" A9-overlay "overlay declarado AUSENTE: $ruta (cada repo debe tener el suyo)"; fi
    fi
  done
  for e in ${PKG_OVERLAY_PREFIX[@]+"${PKG_OVERLAY_PREFIX[@]}"}; do
    m="${e%%:*}"; ruta="${e#*:}"; hit=no
    while IFS= read -r f; do hit=yes; break; done < <(find "$ROOT/$m" -path "$ROOT/$m/$ruta*" -type f 2>/dev/null)
    if [ "$ESTADO" = distribucion ]; then
      if [ "$hit" = yes ]; then report FAIL "$m" A9-overlay-prefix "familia de casa PRESENTE en la distribución: $ruta* (la distribución no lleva identidad)"
      else report PASS "$m" A9-overlay-prefix "familia ausente (distribución): $ruta*"; fi
    else
      if [ "$hit" = yes ]; then report PASS "$m" A9-overlay-prefix "familia presente: $ruta*"
      else report FAIL "$m" A9-overlay-prefix "familia SIN ningún archivo: $ruta*"; fi
    fi
  done
  return 0
}

# ¿El target $2 del miembro $1 cae en un overlay declarado (exacto o por prefijo)? rc 0 = sí.
es_target_overlay() {
  local m="$1" target="$2" e
  for e in ${PKG_OVERLAY_EXACT[@]+"${PKG_OVERLAY_EXACT[@]}"}; do
    [ "${e%%:*}" = "$m" ] && [ "${e#*:}" = "$target" ] && return 0
  done
  for e in ${PKG_OVERLAY_PREFIX[@]+"${PKG_OVERLAY_PREFIX[@]}"}; do
    [ "${e%%:*}" = "$m" ] && case "$target" in "${e#*:}"*) return 0 ;; esac
  done
  return 1
}

# --- Capa B ---------------------------------------------------------------------------------
capa_b_member() { # $1 member (con TSV presente). Parse COMPLETO → luego evalúa.
  local m="$1" tsv="$ROOT/$1/invariants.tsv" t line ln=0 rows=0 seen_ids=":"
  local ids=() targets=() tipos=() patrones=() solo_tabs id target tipo patron fuente prc grc f det
  t=$'\t'
  pkg_reject_bom_crlf_nul "$tsv" "$m/invariants.tsv"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    case "$line" in ""|"#"*) continue ;; esac
    solo_tabs="${line//[^$t]/}"
    [ "${#solo_tabs}" -eq 4 ] || pkg_die2 "$m/invariants.tsv L$ln: columnas != 5 (TABs=${#solo_tabs})"
    IFS=$'\t' read -r id target tipo patron fuente <<< "$line"
    printf '%s' "$id" | command grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || pkg_die2 "$m/invariants.tsv L$ln: id malformado ($id)"
    case "$seen_ids" in *":$id:"*) pkg_die2 "$m/invariants.tsv L$ln: id duplicado ($id)";; esac
    seen_ids="$seen_ids$id:"
    [ -n "$target" ] || pkg_die2 "$m/invariants.tsv L$ln: target vacío"
    case "$target" in /*) pkg_die2 "$m/invariants.tsv L$ln: target absoluto";; *"\\"*) pkg_die2 "$m/invariants.tsv L$ln: target con backslash";; esac
    printf '%s' "$target" | command grep -Eq '(^|/)\.\.?(/|$)' && pkg_die2 "$m/invariants.tsv L$ln: componente ./.. en target"
    case "$tipo" in MUST|MUST_NOT) : ;; *) pkg_die2 "$m/invariants.tsv L$ln: tipo inválido ($tipo)";; esac
    [ -n "$patron" ] || pkg_die2 "$m/invariants.tsv L$ln: patrón vacío"
    if command grep -Eq -e "$patron" /dev/null; then prc=0; else prc=$?; fi
    [ "$prc" -ge 2 ] && pkg_die2 "$m/invariants.tsv L$ln: patrón ERE inválido ($patron)"
    [ -n "$fuente" ] || pkg_die2 "$m/invariants.tsv L$ln: fuente vacía (la trazabilidad es obligatoria)"
    ids+=("$id"); targets+=("$target"); tipos+=("$tipo"); patrones+=("$patron"); rows=$((rows+1))
  done < "$tsv"
  if [ "$rows" -lt "$PKG_MIN_INV" ]; then
    report FAIL "$m" A7-mincount "filas de datos=$rows < min_invariants=$PKG_MIN_INV (cobertura insuficiente)"
  else
    report PASS "$m" A7-mincount "$rows filas ≥ $PKG_MIN_INV"
  fi
  local i=0 dirreal freal anexo_adjudicado='' stack_adjudicado=''
  dirreal="$(realpath -e -- "$ROOT/$m")"
  while [ "$i" -lt "$rows" ]; do
    id="${ids[$i]}"; target="${targets[$i]}"; tipo="${tipos[$i]}"; patron="${patrones[$i]}"
    if [ "$ESTADO" = instancia ] && [ "$m" = talent-merger ] && es_target_overlay "$m" "$target"; then
      if [ -z "$stack_adjudicado" ]; then
        pkg_parse_identity_conf "$ROOT/talent-channel-operation/scripts/repo-identity.conf" || pkg_die2 "anexo sin identidad adjudicada"
        stack_adjudicado="$PKGID_TCO_REPO_STACK"
        case "$stack_adjudicado" in supabase|ninguno|convex) : ;; *) pkg_die2 "TCO_REPO_STACK fuera del enum supabase|convex|ninguno ($stack_adjudicado)" ;; esac
        anexo_adjudicado="$PKGID_TCO_ANEXO_FILE"
      fi
      if [ "$stack_adjudicado" != supabase ]; then
        report SKIP "$m" "$id" "PROC-M13 no aplica al stack $stack_adjudicado"
        i=$((i+1)); continue
      fi
      target="$anexo_adjudicado"
      case "$target" in references/anexo-*.md) : ;; *) pkg_die2 "anexo adjudicado fuera de references/anexo-*.md" ;; esac
      printf '%s' "$target" | command grep -Eq '(^|/)\.\.?(/|$)' && pkg_die2 "anexo adjudicado con componente ./.."
    fi
    f="$ROOT/$m/$target"
    if [ -L "$f" ]; then pkg_die2 "$m/$id: target es symlink ($target) — self-report por poder"; fi
    if [ ! -f "$f" ] && [ "$ESTADO" = distribucion ] && es_target_overlay "$m" "$target"; then
      # Distribución: el target es un overlay por repo (ausente por contrato). NO es PASS ni FAIL ni «evaluada».
      report SKIP-OVERLAY "$m" "$id" "target overlay ausente en la distribución ($target)"
      i=$((i+1)); continue
    fi
    if [ ! -f "$f" ]; then
      report FAIL "$m" "$id" "target INEXISTENTE ($target) — borrar el archivo que porta la doctrina ES la regresión"
      TOTAL_EVAL=$((TOTAL_EVAL+1)); i=$((i+1)); continue
    fi
    freal="$(realpath -e -- "$f")"
    case "$freal" in "$dirreal"/*) : ;; *) pkg_die2 "$m/$id: target fuera del dir del skill ($target)";; esac
    pkg_es_binario "$f" && pkg_die2 "$m/$id: target binario (NUL) — invariante mal definida"
    if command grep -Eq -e "$patron" -- "$f"; then grc=0; else grc=$?; fi
    [ "$grc" -ge 2 ] && pkg_die2 "$m/$id: grep rc=$grc sobre $target (I/O)"
    case "$tipo:$grc" in
      MUST:0)     report PASS "$m" "$id" "MUST match en $target" ;;
      MUST:1)     report FAIL "$m" "$id" "MUST sin match en $target" ;;
      MUST_NOT:1) report PASS "$m" "$id" "MUST_NOT limpio en $target" ;;
      MUST_NOT:0) det="$(command grep -nE -m1 -e "$patron" -- "$f" | head -c 120)"
                  report FAIL "$m" "$id" "MUST_NOT violado en $target (${det:-match})" ;;
    esac
    TOTAL_EVAL=$((TOTAL_EVAL+1)); i=$((i+1))
  done
  return 0
}

# Excepciones cerradas: datos de pruebas; nunca directorios completos.
capa_modelos_rodantes() {
  local base="${ROOT%/*}" f rel hit norma
  while IFS= read -r -d '' f; do
    rel="${f#"$base/"}"
    case "$rel" in
      skills/talent-channel-operation/tests/run-tests.sh|skills/talent-channel-operation/tests/modelos-rodantes.sh|skills/talent-channel-operation/tests/sonda-modelos.sh|skills/talent-channel-operation/tests/fixtures/modelos-cli-current.conf|skills/talent-channel-operation/tests/fixtures/pane/claude_2.1.289/composer-plan-own.txt|skills/talent-channel-operation/tests/fixtures/pane/claude_2.1.289/composer-plan-own.ansi.txt|skills/talent-channels/tests/run-tests.sh|skills/talent-channels/tests/modelos-consumidores.sh|skills/talent-channels/tests/fase-papel-json.sh|skills/talent-context/tests/run-tests.sh|skills/talent-orchestrator/tests/torre-modelos.sh|skills/talent-orchestrator/scripts/pozos-selftest.sh|instalacion/tests/fixtures/completa.resp) continue ;;
    esac
    if hit="$(grep -nE 'claude-(opus|sonnet)-[0-9]' "$f")"; then
      report FAIL '(paquete)' modelos-rodantes "$rel:$hit"
    fi
    # Superficies normativas: ninguna etiqueta fija ni alias ejecutable de fábrica.
    case "$rel" in
      *.md|*.example)
        # Conservar línea de origen y reconocer también órdenes partidas por formato Markdown.
        norma="$(awk '{print NR ":" $0; if (NR>1) print (NR-1) ":" prev " " $0; prev=$0}' "$f")"
        if hit="$(printf '%s\n' "$norma" | grep -iE '(opus|sonnet|haiku|fable)[[:space:]]+[0-9]+(\.[0-9]+)*')"; then
          report FAIL '(paquete)' modelos-etiquetas "$rel:$hit"
        fi
        # Excepción nominal: retorno personal del alumno desde su CLI local.
        case "$rel" in
          skills/talent-llm-local/references/04-puente-y-claude-code.md|skills/talent-llm-local/references/07-averias.md) continue ;;
        esac
        if hit="$(printf '%s\n' "$norma" | grep -iE -- '(--model[=[:space:]]+|/model[[:space:]]+)[[:punct:]]*(opus|sonnet|haiku|fable)([^[:alnum:]_]|$)|tco_(set|ensure)_model[[:space:]]+[^`]*(Sonnet vigente|Opus vigente)|tco_(set|ensure)_model\((sonnet|opus)\)')"; then
          report FAIL '(paquete)' modelos-alias "$rel:$hit"
        fi
        ;;
    esac
  done < <(find "$base" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' -o -name '*.tsv' -o -name '*.resp' -o -name '*.txt' -o -name '*.json' -o -name '*.conf' -o -name '*.example' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' \) -not -path '*/.git/*' -print0)
}
main_validate() {
  local root_arg="" strict=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || pkg_die2 "--root sin valor"; root_arg="$2"; shift 2 ;;
      --strict-set) strict=yes; shift ;;
      --estado)
        [ $# -ge 2 ] || pkg_die2 "--estado sin valor"
        case "$2" in instancia|distribucion) ESTADO="$2" ;; *) pkg_die2 "--estado inválido ($2): instancia | distribucion" ;; esac
        shift 2 ;;
      *) pkg_die2 "flag desconocida: $1" ;;
    esac
  done
  check_deps
  resolver_root "$root_arg"
  pkg_parse_manifest "$ROOT/skill-creator/assets/package.manifest"
  local modo=producto; [ "$strict" = yes ] && modo=motor
  printf '== validate-package v1 · root=%s · modo=%s · estado=%s · paquete=%s · min_invariants=%s ==\n' "$ROOT" "$modo" "$ESTADO" "$PKG_VERSION" "$PKG_MIN_INV"
  local m
  for m in "${PKG_MEMBERS[@]}"; do
    capa_a_member "$m"
    [ "$MEMBER_OK_TSV" = yes ] && capa_b_member "$m"
  done
  capa_modelos_rodantes
  capa_a_overlays
  [ "$strict" = yes ] && capa_a_strict_set
  if [ "$TOTAL_EVAL" -eq 0 ]; then
    printf 'ERROR: 0 invariantes evaluadas — un run que no evaluó nada no es evidencia de nada (anti-vacuo)\n' >&2
    exit 2
  fi
  printf '== resumen: miembros=%s · PASS=%s FAIL=%s · invariantes-evaluadas=%s · checks-A=%s · SKIP-STACK=%s · SKIP-OVERLAY=%s ==\n' "${#PKG_MEMBERS[@]}" "$PASS_N" "$FAIL_N" "$TOTAL_EVAL" "$CHECKS_A" "$SKIP_STACK_N" "$SKIP_N"
  if [ "$FAIL_N" -eq 0 ]; then printf 'VEREDICTO: PASS (rc=0)\n'; exit 0; fi
  printf 'VEREDICTO: FAIL (rc=1)\n'; exit 1
}

# --- Self-test (43 fixtures originales + F44-F57 de TAL-8037; cada negativo muta EXACTAMENTE UNA condición) ---
MIEMBROS_GOLD="linear-skill skill-creator talent-channel-operation talent-channels talent-context talent-coordination talent-issue-craft talent-merger talent-orchestrator talent-repo-onboarding"

mk_gold() { # $1 = dir raíz de skills a crear
  local R="$1" m t=$'\t'
  mkdir -p "$R"
  for m in $MIEMBROS_GOLD; do
    mkdir -p "$R/$m"
    { printf '# %s\n\n## Paquete de fábrica\n\nMiembros (10): %s.\nManifiesto: skill-creator/assets/package.manifest. gold-token.\n\n## Otra sección\n\ncontenido\n' "$m" "$MIEMBROS_GOLD"; } > "$R/$m/SKILL.md"
    printf '# CHANGELOG\n\n## 1.0\n- alta\n' > "$R/$m/CHANGELOG.md"
    { printf 'INV-001%sSKILL.md%sMUST%s^## Paquete de fábrica%sgold\n' "$t" "$t" "$t" "$t"
      printf 'INV-002%sSKILL.md%sMUST%sgold-token%sgold\n' "$t" "$t" "$t" "$t"
      printf 'INV-003%sSKILL.md%sMUST_NOT%sTOKEN_PROHIBIDO_[0-9]+%sgold\n' "$t" "$t" "$t" "$t"; } > "$R/$m/invariants.tsv"
  done
  mkdir -p "$R/skill-creator/assets"
  { printf '# manifiesto gold\nversion=1.0.0\nmin_invariants=3\n'
    for m in $MIEMBROS_GOLD; do printf 'member=%s\n' "$m"; done; } > "$R/skill-creator/assets/package.manifest"
}

# [Ronda P0-2, M1] Ruta ABSOLUTA del propio script: las reinvocaciones del self-test (y los
# fixtures F35/F36, que hacen cd) morían con rc=127 si el operador invocaba por ruta relativa
# — la suite declaraba verde o rojo según el cwd. Guard: ME debe ser absoluta.
ME_ABS="$SC_DIR/$(basename "${BASH_SOURCE[0]}")"
case "$ME_ABS" in /*) : ;; *) printf 'ERROR: no se pudo resolver ruta absoluta del script\n' >&2; exit 2 ;; esac

run_case() { # rc_esperado nombre [args...]
  local want="$1" name="$2"; shift 2
  local got=0
  bash "$ME_ABS" "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ST_PASS=$((ST_PASS+1)); printf 'ok %s (rc=%s)\n' "$name" "$got"
  else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL %s: esperado rc=%s obtenido rc=%s\n' "$name" "$want" "$got"; fi
}

self_test() {
  local T; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  ST_PASS=0; ST_FAIL=0
  local t=$'\t' G="$T/g"; mk_gold "$G"
  run_case 0 F01-gold-motor --root "$G" --strict-set
  cp -R "$G" "$T/f02"; mkdir -p "$T/f02/otra-skill"; printf 'x\n' > "$T/f02/otra-skill/SKILL.md"
  run_case 0 F02-extra-sin-strict --root "$T/f02"
  run_case 1 F03-extra-con-strict --root "$T/f02" --strict-set
  cp -R "$G" "$T/f04"; rm -r "$T/f04/talent-merger";                 run_case 1 F04-miembro-ausente --root "$T/f04"
  cp -R "$G" "$T/f05"; mv "$T/f05/talent-merger" "$T/f05/tm-real"; ln -s tm-real "$T/f05/talent-merger"
  run_case 1 F05-miembro-symlink --root "$T/f05" ; rm "$T/f05/talent-merger"; mv "$T/f05/tm-real" "$T/f05/talent-merger"
  cp -R "$G" "$T/f06"; sed -i 's/^## Paquete de fábrica$/## Paquete/' "$T/f06/talent-merger/SKILL.md"
  run_case 1 F06-marcador-ausente --root "$T/f06"
  cp -R "$G" "$T/f07"; printf '\n## Paquete de fábrica\n\ndup\n' >> "$T/f07/talent-merger/SKILL.md"
  run_case 1 F07-marcador-duplicado --root "$T/f07"
  cp -R "$G" "$T/f08"; sed -i 's/talent-issue-craft//' "$T/f08/talent-merger/SKILL.md"
  run_case 1 F08-nombre-ausente --root "$T/f08"
  cp -R "$G" "$T/f09"
  { printf '# x\n\n## Paquete de fábrica\n\nMiembros (7): %s.\ngold-token\n\n## Otra\n\ntalent-issue-craft\n' "${MIEMBROS_GOLD/talent-issue-craft/}"; } > "$T/f09/talent-merger/SKILL.md"
  run_case 1 F09-nombre-fuera-de-seccion --root "$T/f09"
  cp -R "$G" "$T/f10"; rm "$T/f10/talent-merger/CHANGELOG.md";        run_case 1 F10-changelog-ausente --root "$T/f10"
  cp -R "$G" "$T/f11"; rm "$T/f11/talent-merger/invariants.tsv";      run_case 1 F11-tsv-ausente --root "$T/f11"
  cp -R "$G" "$T/f12"; head -2 "$G/talent-merger/invariants.tsv" > "$T/f12/talent-merger/invariants.tsv"
  run_case 1 F12-menos-de-min --root "$T/f12"
  cp -R "$G" "$T/f13"; printf 'INV-004%sSKILL.md%sMUST%sTOKEN_QUE_NO_EXISTE_[0-9]+X%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f13/talent-merger/invariants.tsv"
  run_case 1 F13-must-violado --root "$T/f13"
  cp -R "$G" "$T/f14"; printf 'TOKEN_PROHIBIDO_7\n' >> "$T/f14/talent-merger/SKILL.md"
  run_case 1 F14-mustnot-violado --root "$T/f14"
  cp -R "$G" "$T/f15"; printf 'INV-004%sreferences/borrado.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f15/talent-merger/invariants.tsv"
  run_case 1 F15-target-inexistente --root "$T/f15"
  cp -R "$G" "$T/f16"; printf 'INV-004%sSKILL.md%sMUST%sx\n' "$t" "$t" "$t" >> "$T/f16/talent-merger/invariants.tsv"
  run_case 2 F16-cuatro-columnas --root "$T/f16"
  cp -R "$G" "$T/f17"; printf 'INV-004%sSKILL.md%sMUST%sx%sgold%sextra\n' "$t" "$t" "$t" "$t" "$t" >> "$T/f17/talent-merger/invariants.tsv"
  run_case 2 F17-seis-columnas --root "$T/f17"
  cp -R "$G" "$T/f18"; printf 'INV-004%sSKILL.md%sMUST%sa(b%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f18/talent-merger/invariants.tsv"
  run_case 2 F18-ere-invalida --root "$T/f18"
  cp -R "$G" "$T/f19"; printf 'INV-001%sSKILL.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f19/talent-merger/invariants.tsv"
  run_case 2 F19-id-duplicado --root "$T/f19"
  cp -R "$G" "$T/f20"; printf 'INV-004%sSKILL.md%sSHOULD%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f20/talent-merger/invariants.tsv"
  run_case 2 F20-tipo-invalido --root "$T/f20"
  cp -R "$G" "$T/f21"; printf 'INV-004%s../skill-creator/SKILL.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f21/talent-merger/invariants.tsv"
  run_case 2 F21-target-traversal --root "$T/f21"
  cp -R "$G" "$T/f22"; printf 'INV-004%s/etc/hostname%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f22/talent-merger/invariants.tsv"
  run_case 2 F22-target-absoluto --root "$T/f22"
  cp -R "$G" "$T/f23"; ln -s ../../skill-creator/SKILL.md "$T/f23/talent-merger/fuera.md"
  printf 'INV-004%sfuera.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f23/talent-merger/invariants.tsv"
  run_case 2 F23-target-symlink --root "$T/f23"
  cp -R "$G" "$T/f24"; printf 'a\0b' > "$T/f24/talent-merger/bin.dat"
  printf 'INV-004%sbin.dat%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f24/talent-merger/invariants.tsv"
  run_case 2 F24-target-binario --root "$T/f24"
  cp -R "$G" "$T/f25"; sed -i 's/$/\r/' "$T/f25/talent-merger/invariants.tsv"
  run_case 2 F25-tsv-crlf --root "$T/f25"
  cp -R "$G" "$T/f26"; { printf '\xef\xbb\xbf'; cat "$G/talent-merger/invariants.tsv"; } > "$T/f26/talent-merger/invariants.tsv"
  run_case 2 F26-tsv-bom --root "$T/f26"
  cp -R "$G" "$T/f27"; printf 'extra=1\n' >> "$T/f27/skill-creator/assets/package.manifest"
  run_case 2 F27-manifiesto-clave-desconocida --root "$T/f27"
  cp -R "$G" "$T/f28"; rm "$T/f28/skill-creator/assets/package.manifest"
  run_case 2 F28-manifiesto-ausente --root "$T/f28"
  cp -R "$G" "$T/f29"; printf 'member=talent-merger\n' >> "$T/f29/skill-creator/assets/package.manifest"
  run_case 2 F29-member-duplicado --root "$T/f29"
  cp -R "$G" "$T/f30"; sed -i 's/^version=1.0.0$/version=1.0/' "$T/f30/skill-creator/assets/package.manifest"
  run_case 2 F30-version-malformada --root "$T/f30"
  cp -R "$G" "$T/f31"; sed -i 's/^min_invariants=3$/min_invariants=0/' "$T/f31/skill-creator/assets/package.manifest"
  run_case 2 F31-min-cero --root "$T/f31"
  cp -R "$G" "$T/f32"; sed -i '/^member=skill-creator$/d' "$T/f32/skill-creator/assets/package.manifest"
  run_case 2 F32-sin-skill-creator --root "$T/f32"
  cp -R "$G" "$T/f33"; printf 'member=../evil\n' >> "$T/f33/skill-creator/assets/package.manifest"
  run_case 2 F33-member-traversal --root "$T/f33"
  cp -R "$G" "$T/f34"; local m2
  for m2 in $MIEMBROS_GOLD; do printf '# solo comentarios\n' > "$T/f34/$m2/invariants.tsv"; done
  run_case 2 F34-anti-vacuo --root "$T/f34"
  mkdir -p "$T/f35/wd/.claude"; cp -R "$G" "$T/f35/wd/.claude/skills"
  local rc35=0 rc36=0
  ( cd "$T/f35/wd" && bash "$ME_ABS" >/dev/null 2>&1 ) || rc35=$?
  if [ "$rc35" -eq 0 ]; then ST_PASS=$((ST_PASS+1)); printf 'ok F35-autodeteccion-ancla (rc=0)\n'; else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F35: rc=%s\n' "$rc35"; fi
  mkdir -p "$T/f36/vacio"
  ( cd "$T/f36/vacio" && bash "$ME_ABS" >/dev/null 2>&1 ) || rc36=$?
  if [ "$rc36" -eq 2 ]; then ST_PASS=$((ST_PASS+1)); printf 'ok F36-autodeteccion-vacia (rc=2)\n'; else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F36: rc=%s\n' "$rc36"; fi
  run_case 2 F37-flag-desconocida --root "$G" --frobnicate
  cp -R "$G" "$T/f38"; printf 'overlay=talent-merger:scripts/repo-identity.conf\n' >> "$T/f38/skill-creator/assets/package.manifest"
  mkdir -p "$T/f38/talent-merger/scripts"; printf 'TCO_REPO_DIR=x\n' > "$T/f38/talent-merger/scripts/repo-identity.conf"
  run_case 0 F38-overlay-presente --root "$T/f38"
  cp -R "$G" "$T/f39"; printf 'overlay=talent-merger:scripts/repo-identity.conf\n' >> "$T/f39/skill-creator/assets/package.manifest"
  run_case 1 F39-overlay-ausente --root "$T/f39"
  cp -R "$G" "$T/f40"; printf 'overlay-prefix=talent-merger:references/anexo-\n' >> "$T/f40/skill-creator/assets/package.manifest"
  run_case 1 F40-prefix-sin-match --root "$T/f40"
  cp -R "$G" "$T/f41"; printf 'overlay=fantasma:x.conf\n' >> "$T/f41/skill-creator/assets/package.manifest"
  run_case 2 F41-overlay-member-no-declarado --root "$T/f41"
  cp -R "$G" "$T/f42"; printf 'overlay=talent-merger:../evil.conf\n' >> "$T/f42/skill-creator/assets/package.manifest"
  run_case 2 F42-overlay-traversal --root "$T/f42"
  cp -R "$G" "$T/f43"; printf 'overlay-prefix=talent-merger:*\n' >> "$T/f43/skill-creator/assets/package.manifest"
  run_case 2 F43-overlay-metacaracter --root "$T/f43"
  # ---- TAL-8037: estados distribucion | instancia (C1) ----
  # Gold con overlays DECLARADOS en el manifiesto: ausentes (+ plantilla .example) = distribución legítima.
  mk_gold_overlays() { # $1 = dir raíz de skills ya creado con mk_gold
    printf 'overlay=talent-merger:scripts/repo-identity.conf\noverlay-prefix=talent-merger:references/anexo-\n' >> "$1/skill-creator/assets/package.manifest"
    mkdir -p "$1/talent-merger/scripts"; printf 'PKG_IDENTITY_PROJECT=PENDIENTE-X\n' > "$1/talent-merger/scripts/repo-identity.conf.example"
  }
  cp -R "$G" "$T/f44"; mk_gold_overlays "$T/f44"
  run_case 0 F44-distribucion-sin-overlays-con-example --root "$T/f44" --estado distribucion
  cp -R "$T/f44" "$T/f45"; printf 'TCO_REPO_DIR=casa\n' > "$T/f45/talent-merger/scripts/repo-identity.conf"
  run_case 1 F45-distribucion-overlay-exacto-presente --root "$T/f45" --estado distribucion
  cp -R "$T/f44" "$T/f46"; mkdir -p "$T/f46/talent-merger/references"; printf 'anexo de casa\n' > "$T/f46/talent-merger/references/anexo-casa.md"
  run_case 1 F46-distribucion-familia-presente --root "$T/f46" --estado distribucion
  cp -R "$T/f44" "$T/f47"; rm "$T/f47/talent-merger/scripts/repo-identity.conf.example"
  run_case 1 F47-distribucion-sin-example --root "$T/f47" --estado distribucion
  run_case 1 F48-instancia-sin-overlays --root "$T/f44" --estado instancia
  run_case 1 F49-instancia-es-el-default-sin-overlays --root "$T/f44"
  cp -R "$T/f44" "$T/f50"; printf 'TCO_REPO_DIR=x\n' > "$T/f50/talent-merger/scripts/repo-identity.conf"
  mkdir -p "$T/f50/talent-merger/references"; printf 'anexo propio\n' > "$T/f50/talent-merger/references/anexo-propio.md"
  run_case 0 F50-instancia-con-overlays --root "$T/f50" --estado instancia
  run_case 2 F51-estado-invalido --root "$G" --estado inventado
  # F52: fila de invariante con target = overlay AUSENTE → SKIP-OVERLAY en distribución (rc 0, no evaluada)…
  cp -R "$T/f44" "$T/f52"; printf 'INV-004%sreferences/anexo-casa.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f52/talent-merger/invariants.tsv"
  run_case 0 F52-distribucion-fila-target-overlay-skip --root "$T/f52" --estado distribucion
  # …y la MISMA fila en instancia (overlays presentes) es FAIL: target inexistente, «sin cambios» para instancia.
  cp -R "$T/f50" "$T/f53"; printf 'INV-004%sreferences/anexo-casa.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f53/talent-merger/invariants.tsv"
  mkdir -p "$T/f53/talent-channel-operation/scripts"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-ausente.md\n' > "$T/f53/talent-channel-operation/scripts/repo-identity.conf"
  run_case 1 F53-instancia-fila-target-overlay-falla --root "$T/f53" --estado instancia
  # F54: fila con target NO-overlay inexistente en distribución → FAIL (SKIP-OVERLAY no se generaliza a cualquier ausente)
  cp -R "$T/f44" "$T/f54"; printf 'INV-004%sreferences/otro-que-no-existe.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f54/talent-merger/invariants.tsv"
  run_case 1 F54-distribucion-target-no-overlay-ausente-falla --root "$T/f54" --estado distribucion
  # F55/F56 [M3]: instancia con el overlay conservando un marcador PENDIENTE-* → FAIL; con valor adjudicado → OK (F50)
  cp -R "$T/f50" "$T/f55"; printf 'TCO_REPO_DIR=PENDIENTE-TCO_REPO_DIR\n' > "$T/f55/talent-merger/scripts/repo-identity.conf"
  run_case 1 F55-instancia-overlay-con-marcador --root "$T/f55" --estado instancia
  # F56 [n2]: valores LEGÍTIMOS que parecen palabras de pendiente (repo `todo`, `pendiente-app`, `placeholder-site`) NO son marcadores
  cp -R "$T/f50" "$T/f56"; printf '# adjudicado\nTCO_REPO_DIR=todo\nTCO_POSTMERGE_CMD=todo\nTCO_REPO_SLUG=org/pendiente-app\nTCO_ANEXO_FILE=placeholder-site\n' > "$T/f56/talent-merger/scripts/repo-identity.conf"
  run_case 0 F56-instancia-valores-legitimos-no-son-marcador --root "$T/f56" --estado instancia
  # F57 [n2]: PKG_IDENTITY_PROJECT=PENDIENTE-X (cualquier clave) → FAIL
  cp -R "$T/f50" "$T/f57"; printf 'PKG_IDENTITY_PROJECT=PENDIENTE-PKG_IDENTITY_PROJECT\n' > "$T/f57/talent-merger/scripts/repo-identity.conf"
  run_case 1 F57-instancia-pkg-identity-project-con-marcador --root "$T/f57" --estado instancia
  # El mismo MUST se evalúa en el anexo adjudicado; borrar doctrina sigue siendo FAIL.
  cp -R "$T/f53" "$T/f58"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-propio.md\n' > "$T/f58/talent-channel-operation/scripts/repo-identity.conf"
  printf 'x\n' > "$T/f58/talent-merger/references/anexo-propio.md"
  run_case 0 F58-instancia-anexo-adjudicado --root "$T/f58" --estado instancia
  cp -R "$T/f58" "$T/f59"; printf 'sin doctrina\n' > "$T/f59/talent-merger/references/anexo-propio.md"
  run_case 1 F59-instancia-anexo-sin-match --root "$T/f59" --estado instancia
  cp -R "$T/f58" "$T/f60"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-../../escape.md\n' > "$T/f60/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F60-instancia-anexo-traversal --root "$T/f60" --estado instancia
  cp -R "$T/f58" "$T/f61"; rm "$T/f61/talent-merger/references/anexo-propio.md"
  ln -s "$T/f58/talent-merger/references/anexo-propio.md" "$T/f61/talent-merger/references/anexo-propio.md"
  run_case 2 F61-instancia-anexo-symlink --root "$T/f61" --estado instancia
  for stack in ninguno convex; do
    cp -R "$T/f59" "$T/f62-$stack"
    sed -i "s/TCO_REPO_STACK=supabase/TCO_REPO_STACK=$stack/" "$T/f62-$stack/talent-channel-operation/scripts/repo-identity.conf"
    local got=0
    bash "$ME_ABS" --root "$T/f62-$stack" --estado instancia > "$T/skip-$stack.log" 2>&1 || got=$?
    if [ "$got" = 0 ] && grep -q "^SKIP talent-merger INV-004 — PROC-M13 no aplica al stack $stack$" "$T/skip-$stack.log" && ! grep -q '^PASS talent-merger INV-004 ' "$T/skip-$stack.log"; then
      ST_PASS=$((ST_PASS+1)); printf 'ok F62-instancia-%s-omision-declarada (rc=0)\n' "$stack"
    else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F62-instancia-%s-omision-declarada: rc=%s\n' "$stack" "$got"; fi
  done
  cp -R "$T/f58" "$T/f64"; sed -i 's/TCO_REPO_STACK=supabase/TCO_REPO_STACK=invalido/' "$T/f64/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F64-instancia-stack-invalido --root "$T/f64" --estado instancia
  cp -R "$T/f58" "$T/f65"; rm "$T/f65/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F65-instancia-identidad-ausente --root "$T/f65" --estado instancia
  cp -R "$T/f58" "$T/f66"; sed -i '/^TCO_REPO_STACK=/d' "$T/f66/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F66-instancia-stack-ausente --root "$T/f66" --estado instancia
  # Gate normativo: mismo paquete, una mutación por caso, excepción nominal comprobada.
  mk_gold "$T/modelos/skills"
  printf 'CEO usa Opus vigente; código usa Sonnet vigente\n' > "$T/modelos/README.md"
  run_case 0 F67-politica-rodante --root "$T/modelos/skills"
  printf 'CEO usa Opus 5.5\n' > "$T/modelos/README.md"
  run_case 1 F68-reparto-con-version-fija --root "$T/modelos/skills"
  printf 'claude --model "sonnet"\n' > "$T/modelos/README.md"
  run_case 1 F69-alias-de-lanzamiento --root "$T/modelos/skills"
  printf '/model opus\n' > "$T/modelos/README.md"
  run_case 1 F70-alias-interactivo-de-fabrica --root "$T/modelos/skills"
  printf 'tco_set_model <carril> <pane> Sonnet vigente\n' > "$T/modelos/README.md"
  run_case 1 F71-etiqueta-como-argumento --root "$T/modelos/skills"
  printf 'Política rodante\n' > "$T/modelos/README.md"
  mkdir -p "$T/modelos/skills/talent-llm-local/references"
  printf '/model opus\n' > "$T/modelos/skills/talent-llm-local/references/04-puente-y-claude-code.md"
  run_case 0 F72-retorno-personal-nominal --root "$T/modelos/skills"
  cp "$T/modelos/skills/talent-llm-local/references/04-puente-y-claude-code.md" "$T/modelos/skills/talent-llm-local/references/otro.md"
  run_case 1 F73-excepcion-no-se-extiende-a-otro-fichero --root "$T/modelos/skills"
  rm "$T/modelos/skills/talent-llm-local/references/otro.md"
  printf 'tco_set_model <carril>\n<pane> Sonnet vigente\n' > "$T/modelos/README.md"
  run_case 1 F74-orden-partida-con-etiqueta --root "$T/modelos/skills"
  # Solo estas capturas históricas declaradas son datos; otra ruta sigue roja.
  printf 'Política rodante\n' > "$T/modelos/README.md"
  local capturas="$T/modelos/skills/talent-channel-operation/tests/fixtures/pane/claude_2.1.289"
  mkdir -p "$capturas"
  printf 'claude-%s-%s\n' sonnet 5-5 > "$capturas/composer-plan-own.txt"
  run_case 0 F75-captura-historica-nominal --root "$T/modelos/skills"
  printf '\033[39mclaude-%s-%s\n' sonnet 5-5 > "$capturas/composer-plan-own.ansi.txt"
  run_case 0 F76-captura-ansi-nominal --root "$T/modelos/skills"
  cp "$capturas/composer-plan-own.txt" "$capturas/captura-no-declarada.txt"
  run_case 1 F77-captura-no-declarada-roja --root "$T/modelos/skills"
  printf 'SELFTEST: PASS=%s FAIL=%s\n' "$ST_PASS" "$ST_FAIL"
  [ $((ST_PASS+ST_FAIL)) -ge 77 ] || { printf 'SELFTEST: guard anti-vacuo — corrieron %s casos (<77)\n' $((ST_PASS+ST_FAIL)) >&2; exit 1; }
  [ "$ST_FAIL" -eq 0 ] || exit 1
  exit 0
}

case "${1:-}" in
  --help) usage; exit 0 ;;
  --self-test) [ $# -eq 1 ] || pkg_die2 "--self-test no admite otras flags"; self_test ;;
  *) main_validate "$@" ;;
esac
