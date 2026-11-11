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
# Uso: validate-package.sh [--root <dir-skills>] [--strict-set] [--estado instancia|distribucion] [--nucleo <NUCLEO.sha256>]
#      validate-package.sh --self-test | --help
set -euo pipefail
trap 'printf "ERROR: fallo imprevisto del validador (línea %s)\n" "$LINENO" >&2; exit 2' ERR
SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-package.sh
. "$SC_DIR/lib-package.sh"

PASS_N=0; FAIL_N=0; SKIP_N=0; SKIP_STACK_N=0; TOTAL_EVAL=0; CHECKS_A=0
ESTADO=instancia
NUCLEO_LISTA=""
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
  elif [ -f "./.claude/paquete/package.manifest" ]; then
    ROOT="$(cd ./.claude/skills && pwd)"
  elif [ -f "./scripts/paquete/package.manifest" ]; then
    ROOT="$(cd ./skills && pwd)"
  else
    pkg_die2 "raíz indeterminable: sin --root y sin ancla de manifiesto en ./.claude/paquete ni ./scripts/paquete"
  fi
  PAQUETE_DIR="$(pkg_dir_de "$ROOT")"
  if [ -L "$PAQUETE_DIR" ]; then
    report FAIL paquete A1-dir "directorio symlink (la forma del árbol es contrato)"
    exit 1
  fi
  [ -f "$PAQUETE_DIR/package.manifest" ] || pkg_die2 "sin manifiesto en $PAQUETE_DIR/package.manifest"
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

# [Invariante núcleo-no-ignorado] Con --estado instancia y la raíz dentro de un repo git, NINGÚN fichero de la
# LISTA DECLARADA del núcleo puede estar ignorado por el repo destino: un clon que sale de GitHub no lo tendría
# (el `git add` no versiona lo ignorado). La lista es la de instalacion/NUCLEO.sha256 que copia el instalador,
# trasladada a las rutas del clon: skills/<miembro>/… -> <raíz de skills>/<miembro>/… y scripts/paquete/… ->
# <directorio del paquete>/…. Lo que haya en disco NO cuenta (un .pyc generado no es núcleo); un fichero de la
# lista con cualquier extensión o ruta ignorada es FAIL, sin excepciones. Un fichero de la lista AUSENTE en disco
# también es FAIL (el núcleo está incompleto), nunca silencio. Mide el .gitignore REAL con `git check-ignore`.
# La lista sale de --nucleo <fichero> o, si falta, de <raíz del paquete>/instalacion/NUCLEO.sha256; sin lista, sin
# repo ACREDITADO (ninguna marca .git en la raíz ni en sus ancestros) o en distribución (aún no hay repo destino) es
# SKIP motivado, nunca PASS. Con marca de repo y git ausente o que no responde `true` es FAIL: no se puede medir.
# Lo ya versionado no se reporta.
capa_a_nucleo_no_ignorado() {
  local base m mm ok rel_root rel_pkg lst out n=0 rc=0 lista line p rest falta="" nfalta=0 malos=0 marca d dentro
  if [ "$ESTADO" = distribucion ]; then
    report SKIP paquete A10-no-ignorado "estado distribucion: aún no hay repo destino que mida"; return 0
  fi
  base="$(dirname "$ROOT")"
  # Ausencia ACREDITADA de repo = ninguna marca .git en la raíz ni en sus ancestros. Si hay marca de repo y
  # git no se puede ejecutar o no responde "true", NO se mide: FAIL (nunca SKIP, que dejaría pasar un núcleo ignorado).
  marca=""; d="$base"
  while :; do
    if [ -e "$d/.git" ] || [ -L "$d/.git" ]; then marca="$d"; break; fi   # un enlace roto también es marca
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
  if ! command -v git >/dev/null 2>&1; then
    if [ -n "$marca" ]; then report FAIL paquete A10-no-ignorado "hay repo ($marca/.git) pero git no está disponible: no se puede medir"
    else report SKIP paquete A10-no-ignorado "sin repo git en la raíz: no hay .gitignore destino que medir"; fi
    return 0
  fi
  dentro="$(git -C "$base" rev-parse --is-inside-work-tree 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$dentro" != true ]; then
    if [ -n "$marca" ]; then
      report FAIL paquete A10-no-ignorado "hay repo ($marca/.git) pero git rev-parse falló (rc=$rc, salida '${dentro:-vacía}'): no se puede medir"
    elif [ "$rc" -ne 0 ]; then
      report SKIP paquete A10-no-ignorado "sin repo git en la raíz: no hay .gitignore destino que medir"
    else
      report FAIL paquete A10-no-ignorado "git rev-parse respondió '$dentro' sin marca de repo: no se puede medir"
    fi
    return 0
  fi
  rc=0
  lista="$NUCLEO_LISTA"; [ -n "$lista" ] || lista="$base/instalacion/NUCLEO.sha256"
  if [ ! -f "$lista" ]; then
    report SKIP paquete A10-no-ignorado "lista declarada del núcleo no disponible ($lista): pasar --nucleo <NUCLEO.sha256>"; return 0
  fi
  rel_root="${ROOT#"$base"/}"; rel_pkg="${PAQUETE_DIR#"$base"/}"
  lst="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if ! [[ "$line" =~ ^[0-9a-f]{64}\ \ ([A-Za-z0-9_./@+-]+)$ ]]; then malos=$((malos+1)); continue; fi
    p="${BASH_REMATCH[1]}"; rest=""
    case "$p" in
      skills/*) rest="${p#skills/}"; m="${rest%%/*}"
        ok=no; for mm in "${PKG_MEMBERS[@]}"; do [ "$mm" = "$m" ] && ok=yes && break; done
        [ "$ok" = yes ] || continue
        rest="$rel_root/$rest" ;;
      scripts/paquete/*) rest="$rel_pkg/${p#scripts/paquete/}" ;;
      *) continue ;;
    esac
    case "$rest" in *..*) malos=$((malos+1)); continue ;; esac
    n=$((n+1)); printf '%s\0' "$rest" >> "$lst"
    if [ ! -f "$base/$rest" ]; then nfalta=$((nfalta+1)); [ "$nfalta" -gt 10 ] || falta="$falta $rest"; fi
  done < "$lista"
  if [ "$malos" -gt 0 ] || [ "$n" -eq 0 ]; then
    rm -f "$lst"
    report FAIL paquete A10-no-ignorado "lista declarada inválida o sin entradas del paquete ($lista): $malos línea(s) mal formadas, $n entradas"; return 0
  fi
  out="$(git -C "$base" check-ignore -z --stdin < "$lst" | tr '\0' '\n')" || rc=$?
  rm -f "$lst"
  if [ "$rc" -gt 1 ]; then report FAIL paquete A10-no-ignorado "git check-ignore falló (rc=$rc): no se pudo medir"; return 0; fi
  if [ -n "$out" ]; then
    report FAIL paquete A10-no-ignorado "$(printf '%s\n' "$out" | wc -l | tr -d ' ') fichero(s) del núcleo ignorados por el repo destino (no llegarían al clon): $(printf '%s\n' "$out" | head -n 10 | tr '\n' ' ')"
  else
    report PASS paquete A10-no-ignorado "$n ficheros de la lista del núcleo, ninguno ignorado por el repo destino"
  fi
  if [ "$nfalta" -gt 0 ]; then
    report FAIL paquete A10-no-ignorado-presencia "$nfalta fichero(s) de la lista del núcleo AUSENTES en disco (núcleo incompleto):$falta"
  fi
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
capa_b_member() { # $1 member/capa, $2 dir opcional. Parse COMPLETO → luego evalúa.
  local m="$1" dir="${2:-$ROOT/$1}" tsv t line ln=0 rows=0 seen_ids=":"
  tsv="$dir/invariants.tsv"
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
  dirreal="$(realpath -e -- "$dir")"
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
    f="$dir/$target"
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
    if hit="$(grep -nE 'claude-(opus|sonnet|fable)-[0-9]|gpt-[0-9]+(\.[0-9]+)*-sol' "$f")"; then
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
        if hit="$(printf '%s\n' "$norma" | grep -iE -- '(--model[=[:space:]]+|/model[[:space:]]+)[[:punct:]]*(opus|sonnet|haiku|fable)([^[:alnum:]_]|$)|tco_(set|ensure)_model[[:space:]]+[^`]*(Sonnet vigente|Opus vigente)|tco_(set|ensure)_model\((sonnet|opus)\)')"; then
          report FAIL '(paquete)' modelos-alias "$rel:$hit"
        fi
        ;;
    esac
  done < <(find "$base" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' -o -name '*.tsv' -o -name '*.resp' -o -name '*.txt' -o -name '*.json' -o -name '*.conf' -o -name '*.example' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' -o -name '*.tmpl' \) -not -path '*/.git/*' -print0)
}
main_validate() {
  local root_arg="" strict=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || pkg_die2 "--root sin valor"; root_arg="$2"; shift 2 ;;
      --strict-set) strict=yes; shift ;;
      --nucleo) [ $# -ge 2 ] || pkg_die2 "--nucleo sin valor"; NUCLEO_LISTA="$2"; shift 2 ;;
      --estado)
        [ $# -ge 2 ] || pkg_die2 "--estado sin valor"
        case "$2" in instancia|distribucion) ESTADO="$2" ;; *) pkg_die2 "--estado inválido ($2): instancia | distribucion" ;; esac
        shift 2 ;;
      *) pkg_die2 "flag desconocida: $1" ;;
    esac
  done
  check_deps
  resolver_root "$root_arg"
  pkg_parse_manifest "$PAQUETE_DIR/package.manifest"
  local modo=producto; [ "$strict" = yes ] && modo=motor
  printf '== validate-package v1 · root=%s · modo=%s · estado=%s · paquete=%s · min_invariants=%s ==\n' "$ROOT" "$modo" "$ESTADO" "$PKG_VERSION" "$PKG_MIN_INV"
  local m
  for m in "${PKG_MEMBERS[@]}"; do
    capa_a_member "$m"
    [ "$MEMBER_OK_TSV" = yes ] && capa_b_member "$m"
  done
  capa_b_member paquete "$PAQUETE_DIR"
  capa_modelos_rodantes
  capa_a_overlays
  capa_a_nucleo_no_ignorado
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
MIEMBROS_GOLD="linear-skill skill-creator talent-channel-operation talent-channels talent-context talent-pm talent-issue-craft talent-merger talent-orchestrator talent-ceo"

mk_gold() { # $1 = dir raíz del paquete a crear
  local R="$1/skills" P="$1/scripts/paquete" m t=$'\t'
  mkdir -p "$R"
  for m in $MIEMBROS_GOLD; do
    mkdir -p "$R/$m"
    { printf '# %s\n\n## Paquete de fábrica\n\nMiembros (10): %s.\nManifiesto: scripts/paquete/package.manifest. gold-token.\n\n## Otra sección\n\ncontenido\n' "$m" "$MIEMBROS_GOLD"; } > "$R/$m/SKILL.md"
    printf '# CHANGELOG\n\n## 1.0\n- alta\n' > "$R/$m/CHANGELOG.md"
    { printf 'INV-001%sSKILL.md%sMUST%s^## Paquete de fábrica%sgold\n' "$t" "$t" "$t" "$t"
      printf 'INV-002%sSKILL.md%sMUST%sgold-token%sgold\n' "$t" "$t" "$t" "$t"
      printf 'INV-003%sSKILL.md%sMUST_NOT%sTOKEN_PROHIBIDO_[0-9]+%sgold\n' "$t" "$t" "$t" "$t"; } > "$R/$m/invariants.tsv"
  done
  mkdir -p "$P"
  { printf '# manifiesto gold\nversion=1.0.0\nmin_invariants=3\n'
    for m in $MIEMBROS_GOLD; do printf 'member=%s\n' "$m"; done; } > "$P/package.manifest"
  { printf 'INV-PQ-001%spackage.manifest%sMUST%s^version=%sgold\n' "$t" "$t" "$t" "$t"
    printf 'INV-PQ-002%spackage.manifest%sMUST%s^min_invariants=%sgold\n' "$t" "$t" "$t" "$t"
    printf 'INV-PQ-003%spackage.manifest%sMUST%s^member=%sgold\n' "$t" "$t" "$t" "$t"; } > "$P/invariants.tsv"
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
  run_case 0 F01-gold-motor --root "$G/skills" --strict-set
  cp -R "$G" "$T/f02"; mkdir -p "$T/f02/skills/otra-skill"; printf 'x\n' > "$T/f02/skills/otra-skill/SKILL.md"
  run_case 0 F02-extra-sin-strict --root "$T/f02/skills"
  run_case 1 F03-extra-con-strict --root "$T/f02/skills" --strict-set
  cp -R "$G" "$T/f04"; rm -r "$T/f04/skills/talent-merger";                 run_case 1 F04-miembro-ausente --root "$T/f04/skills"
  cp -R "$G" "$T/f05"; mv "$T/f05/skills/talent-merger" "$T/f05/skills/tm-real"; ln -s tm-real "$T/f05/skills/talent-merger"
  run_case 1 F05-miembro-symlink --root "$T/f05/skills" ; rm "$T/f05/skills/talent-merger"; mv "$T/f05/skills/tm-real" "$T/f05/skills/talent-merger"
  cp -R "$G" "$T/f06"; sed -i 's/^## Paquete de fábrica$/## Paquete/' "$T/f06/skills/talent-merger/SKILL.md"
  run_case 1 F06-marcador-ausente --root "$T/f06/skills"
  cp -R "$G" "$T/f07"; printf '\n## Paquete de fábrica\n\ndup\n' >> "$T/f07/skills/talent-merger/SKILL.md"
  run_case 1 F07-marcador-duplicado --root "$T/f07/skills"
  cp -R "$G" "$T/f08"; sed -i 's/talent-issue-craft//' "$T/f08/skills/talent-merger/SKILL.md"
  run_case 1 F08-nombre-ausente --root "$T/f08/skills"
  cp -R "$G" "$T/f09"
  { printf '# x\n\n## Paquete de fábrica\n\nMiembros (7): %s.\ngold-token\n\n## Otra\n\ntalent-issue-craft\n' "${MIEMBROS_GOLD/talent-issue-craft/}"; } > "$T/f09/skills/talent-merger/SKILL.md"
  run_case 1 F09-nombre-fuera-de-seccion --root "$T/f09/skills"
  cp -R "$G" "$T/f10"; rm "$T/f10/skills/talent-merger/CHANGELOG.md";        run_case 1 F10-changelog-ausente --root "$T/f10/skills"
  cp -R "$G" "$T/f11"; rm "$T/f11/skills/talent-merger/invariants.tsv";      run_case 1 F11-tsv-ausente --root "$T/f11/skills"
  cp -R "$G" "$T/f12"; head -2 "$G/skills/talent-merger/invariants.tsv" > "$T/f12/skills/talent-merger/invariants.tsv"
  run_case 1 F12-menos-de-min --root "$T/f12/skills"
  cp -R "$G" "$T/f13"; printf 'INV-004%sSKILL.md%sMUST%sTOKEN_QUE_NO_EXISTE_[0-9]+X%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f13/skills/talent-merger/invariants.tsv"
  run_case 1 F13-must-violado --root "$T/f13/skills"
  cp -R "$G" "$T/f14"; printf 'TOKEN_PROHIBIDO_7\n' >> "$T/f14/skills/talent-merger/SKILL.md"
  run_case 1 F14-mustnot-violado --root "$T/f14/skills"
  cp -R "$G" "$T/f15"; printf 'INV-004%sreferences/borrado.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f15/skills/talent-merger/invariants.tsv"
  run_case 1 F15-target-inexistente --root "$T/f15/skills"
  cp -R "$G" "$T/f16"; printf 'INV-004%sSKILL.md%sMUST%sx\n' "$t" "$t" "$t" >> "$T/f16/skills/talent-merger/invariants.tsv"
  run_case 2 F16-cuatro-columnas --root "$T/f16/skills"
  cp -R "$G" "$T/f17"; printf 'INV-004%sSKILL.md%sMUST%sx%sgold%sextra\n' "$t" "$t" "$t" "$t" "$t" >> "$T/f17/skills/talent-merger/invariants.tsv"
  run_case 2 F17-seis-columnas --root "$T/f17/skills"
  cp -R "$G" "$T/f18"; printf 'INV-004%sSKILL.md%sMUST%sa(b%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f18/skills/talent-merger/invariants.tsv"
  run_case 2 F18-ere-invalida --root "$T/f18/skills"
  cp -R "$G" "$T/f19"; printf 'INV-001%sSKILL.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f19/skills/talent-merger/invariants.tsv"
  run_case 2 F19-id-duplicado --root "$T/f19/skills"
  cp -R "$G" "$T/f20"; printf 'INV-004%sSKILL.md%sSHOULD%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f20/skills/talent-merger/invariants.tsv"
  run_case 2 F20-tipo-invalido --root "$T/f20/skills"
  cp -R "$G" "$T/f21"; printf 'INV-004%s../skill-creator/SKILL.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f21/skills/talent-merger/invariants.tsv"
  run_case 2 F21-target-traversal --root "$T/f21/skills"
  cp -R "$G" "$T/f22"; printf 'INV-004%s/etc/hostname%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f22/skills/talent-merger/invariants.tsv"
  run_case 2 F22-target-absoluto --root "$T/f22/skills"
  cp -R "$G" "$T/f23"; ln -s ../../skill-creator/SKILL.md "$T/f23/skills/talent-merger/fuera.md"
  printf 'INV-004%sfuera.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f23/skills/talent-merger/invariants.tsv"
  run_case 2 F23-target-symlink --root "$T/f23/skills"
  cp -R "$G" "$T/f24"; printf 'a\0b' > "$T/f24/skills/talent-merger/bin.dat"
  printf 'INV-004%sbin.dat%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f24/skills/talent-merger/invariants.tsv"
  run_case 2 F24-target-binario --root "$T/f24/skills"
  cp -R "$G" "$T/f25"; sed -i 's/$/\r/' "$T/f25/skills/talent-merger/invariants.tsv"
  run_case 2 F25-tsv-crlf --root "$T/f25/skills"
  cp -R "$G" "$T/f26"; { printf '\xef\xbb\xbf'; cat "$G/skills/talent-merger/invariants.tsv"; } > "$T/f26/skills/talent-merger/invariants.tsv"
  run_case 2 F26-tsv-bom --root "$T/f26/skills"
  cp -R "$G" "$T/f27"; printf 'extra=1\n' >> "$T/f27/scripts/paquete/package.manifest"
  run_case 2 F27-manifiesto-clave-desconocida --root "$T/f27/skills"
  cp -R "$G" "$T/f28"; rm "$T/f28/scripts/paquete/package.manifest"
  run_case 2 F28-manifiesto-ausente --root "$T/f28/skills"
  cp -R "$G" "$T/f29"; printf 'member=talent-merger\n' >> "$T/f29/scripts/paquete/package.manifest"
  run_case 2 F29-member-duplicado --root "$T/f29/skills"
  cp -R "$G" "$T/f30"; sed -i 's/^version=1.0.0$/version=1.0/' "$T/f30/scripts/paquete/package.manifest"
  run_case 2 F30-version-malformada --root "$T/f30/skills"
  cp -R "$G" "$T/f31"; sed -i 's/^min_invariants=3$/min_invariants=0/' "$T/f31/scripts/paquete/package.manifest"
  run_case 2 F31-min-cero --root "$T/f31/skills"
  cp -R "$G" "$T/f32"; sed -i '/^member=/d' "$T/f32/scripts/paquete/package.manifest"
  run_case 2 F32-sin-miembros --root "$T/f32/skills"
  cp -R "$G" "$T/f33"; printf 'member=../evil\n' >> "$T/f33/scripts/paquete/package.manifest"
  run_case 2 F33-member-traversal --root "$T/f33/skills"
  cp -R "$G" "$T/f34"; local m2
  for m2 in $MIEMBROS_GOLD; do printf '# solo comentarios\n' > "$T/f34/skills/$m2/invariants.tsv"; done
  printf '# solo comentarios\n' > "$T/f34/scripts/paquete/invariants.tsv"
  run_case 2 F34-anti-vacuo --root "$T/f34/skills"
  mkdir -p "$T/f35/wd/.claude"; cp -R "$G/skills" "$T/f35/wd/.claude/skills"
  cp -R "$G/scripts/paquete" "$T/f35/wd/.claude/paquete"
  local rc35=0 rc36=0
  ( cd "$T/f35/wd" && bash "$ME_ABS" >/dev/null 2>&1 ) || rc35=$?
  if [ "$rc35" -eq 0 ]; then ST_PASS=$((ST_PASS+1)); printf 'ok F35-autodeteccion-ancla (rc=0)\n'; else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F35: rc=%s\n' "$rc35"; fi
  mkdir -p "$T/f36/vacio"
  ( cd "$T/f36/vacio" && bash "$ME_ABS" >/dev/null 2>&1 ) || rc36=$?
  if [ "$rc36" -eq 2 ]; then ST_PASS=$((ST_PASS+1)); printf 'ok F36-autodeteccion-vacia (rc=2)\n'; else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F36: rc=%s\n' "$rc36"; fi
  run_case 2 F37-flag-desconocida --root "$G/skills" --frobnicate
  cp -R "$G" "$T/f38"; printf 'overlay=talent-merger:scripts/repo-identity.conf\n' >> "$T/f38/scripts/paquete/package.manifest"
  mkdir -p "$T/f38/skills/talent-merger/scripts"; printf 'TCO_REPO_DIR=x\n' > "$T/f38/skills/talent-merger/scripts/repo-identity.conf"
  run_case 0 F38-overlay-presente --root "$T/f38/skills"
  cp -R "$G" "$T/f39"; printf 'overlay=talent-merger:scripts/repo-identity.conf\n' >> "$T/f39/scripts/paquete/package.manifest"
  run_case 1 F39-overlay-ausente --root "$T/f39/skills"
  cp -R "$G" "$T/f40"; printf 'overlay-prefix=talent-merger:references/anexo-\n' >> "$T/f40/scripts/paquete/package.manifest"
  run_case 1 F40-prefix-sin-match --root "$T/f40/skills"
  cp -R "$G" "$T/f41"; printf 'overlay=fantasma:x.conf\n' >> "$T/f41/scripts/paquete/package.manifest"
  run_case 2 F41-overlay-member-no-declarado --root "$T/f41/skills"
  cp -R "$G" "$T/f42"; printf 'overlay=talent-merger:../evil.conf\n' >> "$T/f42/scripts/paquete/package.manifest"
  run_case 2 F42-overlay-traversal --root "$T/f42/skills"
  cp -R "$G" "$T/f43"; printf 'overlay-prefix=talent-merger:*\n' >> "$T/f43/scripts/paquete/package.manifest"
  run_case 2 F43-overlay-metacaracter --root "$T/f43/skills"
  # ---- TAL-8037: estados distribucion | instancia (C1) ----
  # Gold con overlays DECLARADOS en el manifiesto: ausentes (+ plantilla .example) = distribución legítima.
  mk_gold_overlays() { # $1 = dir raíz del paquete ya creado con mk_gold
    printf 'overlay=talent-merger:scripts/repo-identity.conf\noverlay-prefix=talent-merger:references/anexo-\n' >> "$1/scripts/paquete/package.manifest"
    mkdir -p "$1/skills/talent-merger/scripts"; printf 'PKG_IDENTITY_PROJECT=PENDIENTE-X\n' > "$1/skills/talent-merger/scripts/repo-identity.conf.example"
  }
  cp -R "$G" "$T/f44"; mk_gold_overlays "$T/f44"
  run_case 0 F44-distribucion-sin-overlays-con-example --root "$T/f44/skills" --estado distribucion
  cp -R "$T/f44" "$T/f45"; printf 'TCO_REPO_DIR=casa\n' > "$T/f45/skills/talent-merger/scripts/repo-identity.conf"
  run_case 1 F45-distribucion-overlay-exacto-presente --root "$T/f45/skills" --estado distribucion
  cp -R "$T/f44" "$T/f46"; mkdir -p "$T/f46/skills/talent-merger/references"; printf 'anexo de casa\n' > "$T/f46/skills/talent-merger/references/anexo-casa.md"
  run_case 1 F46-distribucion-familia-presente --root "$T/f46/skills" --estado distribucion
  cp -R "$T/f44" "$T/f47"; rm "$T/f47/skills/talent-merger/scripts/repo-identity.conf.example"
  run_case 1 F47-distribucion-sin-example --root "$T/f47/skills" --estado distribucion
  run_case 1 F48-instancia-sin-overlays --root "$T/f44/skills" --estado instancia
  run_case 1 F49-instancia-es-el-default-sin-overlays --root "$T/f44/skills"
  cp -R "$T/f44" "$T/f50"; printf 'TCO_REPO_DIR=x\n' > "$T/f50/skills/talent-merger/scripts/repo-identity.conf"
  mkdir -p "$T/f50/skills/talent-merger/references"; printf 'anexo propio\n' > "$T/f50/skills/talent-merger/references/anexo-propio.md"
  run_case 0 F50-instancia-con-overlays --root "$T/f50/skills" --estado instancia
  run_case 2 F51-estado-invalido --root "$G/skills" --estado inventado
  # F52: fila de invariante con target = overlay AUSENTE → SKIP-OVERLAY en distribución (rc 0, no evaluada)…
  cp -R "$T/f44" "$T/f52"; printf 'INV-004%sreferences/anexo-casa.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f52/skills/talent-merger/invariants.tsv"
  run_case 0 F52-distribucion-fila-target-overlay-skip --root "$T/f52/skills" --estado distribucion
  # …y la MISMA fila en instancia (overlays presentes) es FAIL: target inexistente, «sin cambios» para instancia.
  cp -R "$T/f50" "$T/f53"; printf 'INV-004%sreferences/anexo-casa.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f53/skills/talent-merger/invariants.tsv"
  mkdir -p "$T/f53/skills/talent-channel-operation/scripts"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-ausente.md\n' > "$T/f53/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_case 1 F53-instancia-fila-target-overlay-falla --root "$T/f53/skills" --estado instancia
  # F54: fila con target NO-overlay inexistente en distribución → FAIL (SKIP-OVERLAY no se generaliza a cualquier ausente)
  cp -R "$T/f44" "$T/f54"; printf 'INV-004%sreferences/otro-que-no-existe.md%sMUST%sx%sgold\n' "$t" "$t" "$t" "$t" >> "$T/f54/skills/talent-merger/invariants.tsv"
  run_case 1 F54-distribucion-target-no-overlay-ausente-falla --root "$T/f54/skills" --estado distribucion
  # F55/F56 [M3]: instancia con el overlay conservando un marcador PENDIENTE-* → FAIL; con valor adjudicado → OK (F50)
  cp -R "$T/f50" "$T/f55"; printf 'TCO_REPO_DIR=PENDIENTE-TCO_REPO_DIR\n' > "$T/f55/skills/talent-merger/scripts/repo-identity.conf"
  run_case 1 F55-instancia-overlay-con-marcador --root "$T/f55/skills" --estado instancia
  # F56 [n2]: valores LEGÍTIMOS que parecen palabras de pendiente (repo `todo`, `pendiente-app`, `placeholder-site`) NO son marcadores
  cp -R "$T/f50" "$T/f56"; printf '# adjudicado\nTCO_REPO_DIR=todo\nTCO_POSTMERGE_CMD=todo\nTCO_REPO_SLUG=org/pendiente-app\nTCO_ANEXO_FILE=placeholder-site\n' > "$T/f56/skills/talent-merger/scripts/repo-identity.conf"
  run_case 0 F56-instancia-valores-legitimos-no-son-marcador --root "$T/f56/skills" --estado instancia
  # F57 [n2]: PKG_IDENTITY_PROJECT=PENDIENTE-X (cualquier clave) → FAIL
  cp -R "$T/f50" "$T/f57"; printf 'PKG_IDENTITY_PROJECT=PENDIENTE-PKG_IDENTITY_PROJECT\n' > "$T/f57/skills/talent-merger/scripts/repo-identity.conf"
  run_case 1 F57-instancia-pkg-identity-project-con-marcador --root "$T/f57/skills" --estado instancia
  # El mismo MUST se evalúa en el anexo adjudicado; borrar doctrina sigue siendo FAIL.
  cp -R "$T/f53" "$T/f58"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-propio.md\n' > "$T/f58/skills/talent-channel-operation/scripts/repo-identity.conf"
  printf 'x\n' > "$T/f58/skills/talent-merger/references/anexo-propio.md"
  run_case 0 F58-instancia-anexo-adjudicado --root "$T/f58/skills" --estado instancia
  cp -R "$T/f58" "$T/f59"; printf 'sin doctrina\n' > "$T/f59/skills/talent-merger/references/anexo-propio.md"
  run_case 1 F59-instancia-anexo-sin-match --root "$T/f59/skills" --estado instancia
  cp -R "$T/f58" "$T/f60"
  printf 'TCO_REPO_STACK=supabase\nTCO_ANEXO_FILE=references/anexo-../../escape.md\n' > "$T/f60/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F60-instancia-anexo-traversal --root "$T/f60/skills" --estado instancia
  cp -R "$T/f58" "$T/f61"; rm "$T/f61/skills/talent-merger/references/anexo-propio.md"
  ln -s "$T/f58/skills/talent-merger/references/anexo-propio.md" "$T/f61/skills/talent-merger/references/anexo-propio.md"
  run_case 2 F61-instancia-anexo-symlink --root "$T/f61/skills" --estado instancia
  for stack in ninguno convex; do
    cp -R "$T/f59" "$T/f62-$stack"
    sed -i "s/TCO_REPO_STACK=supabase/TCO_REPO_STACK=$stack/" "$T/f62-$stack/skills/talent-channel-operation/scripts/repo-identity.conf"
    local got=0
    bash "$ME_ABS" --root "$T/f62-$stack/skills" --estado instancia > "$T/skip-$stack.log" 2>&1 || got=$?
    if [ "$got" = 0 ] && grep -q "^SKIP talent-merger INV-004 — PROC-M13 no aplica al stack $stack$" "$T/skip-$stack.log" && ! grep -q '^PASS talent-merger INV-004 ' "$T/skip-$stack.log"; then
      ST_PASS=$((ST_PASS+1)); printf 'ok F62-instancia-%s-omision-declarada (rc=0)\n' "$stack"
    else ST_FAIL=$((ST_FAIL+1)); printf 'SELFTEST FAIL F62-instancia-%s-omision-declarada: rc=%s\n' "$stack" "$got"; fi
  done
  cp -R "$T/f58" "$T/f64"; sed -i 's/TCO_REPO_STACK=supabase/TCO_REPO_STACK=invalido/' "$T/f64/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F64-instancia-stack-invalido --root "$T/f64/skills" --estado instancia
  cp -R "$T/f58" "$T/f65"; rm "$T/f65/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F65-instancia-identidad-ausente --root "$T/f65/skills" --estado instancia
  cp -R "$T/f58" "$T/f66"; sed -i '/^TCO_REPO_STACK=/d' "$T/f66/skills/talent-channel-operation/scripts/repo-identity.conf"
  run_case 2 F66-instancia-stack-ausente --root "$T/f66/skills" --estado instancia
  # Gate normativo: mismo paquete, una mutación por caso, excepción nominal comprobada.
  mk_gold "$T/modelos"
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
  # El directorio portador también debe quedar confinado, antes del parser y Capa B.
  cp -R "$G" "$T/f78"
  mv "$T/f78/scripts/paquete" "$T/paquete-externo"
  ln -s "$T/paquete-externo" "$T/f78/scripts/paquete"
  run_case 1 F78-paquete-distribucion-symlink --root "$T/f78/skills"
  rm "$T/f78/scripts/paquete"
  cp -R "$T/paquete-externo" "$T/f78/scripts/paquete"
  run_case 0 F79-paquete-distribucion-copia-regular --root "$T/f78/skills"
  mkdir -p "$T/f80/.claude"
  cp -R "$G/skills" "$T/f80/.claude/skills"
  ln -s "$T/paquete-externo" "$T/f80/.claude/paquete"
  run_case 1 F80-paquete-producto-symlink --root "$T/f80/.claude/skills"
  rm "$T/f80/.claude/paquete"
  cp -R "$T/paquete-externo" "$T/f80/.claude/paquete"
  run_case 0 F81-paquete-producto-copia-regular --root "$T/f80/.claude/skills"
  mk_gold "$T/f82"
  printf 'model = "gpt-%s-%s"\n' 9.9 sol > "$T/f82/auditor.toml"
  run_case 1 F82-codex-id-fijo --root "$T/f82/skills"
  rm "$T/f82/auditor.toml"
  run_case 0 F82-codex-id-fijo-limpio --root "$T/f82/skills"
  mkdir -p "$T/f82/skills/talent-channels/assets"
  cp "$SC_DIR/../../skills/talent-channels/assets/launcher-v.tmpl" "$T/f82/skills/talent-channels/assets/launcher-v.tmpl"
  printf '\nmodel = "gpt-%s-%s"\n' 9.9 sol >> "$T/f82/skills/talent-channels/assets/launcher-v.tmpl"
  run_case 1 F82-codex-id-fijo-plantilla --root "$T/f82/skills"
  cp "$SC_DIR/../../skills/talent-channels/assets/launcher-v.tmpl" "$T/f82/skills/talent-channels/assets/launcher-v.tmpl"
  run_case 0 F82-codex-id-fijo-plantilla-limpia --root "$T/f82/skills"
  printf 'SELFTEST: PASS=%s FAIL=%s\n' "$ST_PASS" "$ST_FAIL"
  [ $((ST_PASS+ST_FAIL)) -ge 79 ] || { printf 'SELFTEST: guard anti-vacuo — corrieron %s casos (<79)\n' $((ST_PASS+ST_FAIL)) >&2; exit 1; }
  [ "$ST_FAIL" -eq 0 ] || exit 1
  exit 0
}

case "${1:-}" in
  --help) usage; exit 0 ;;
  --self-test) [ $# -eq 1 ] || pkg_die2 "--self-test no admite otras flags"; self_test ;;
  *) main_validate "$@" ;;
esac
