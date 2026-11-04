#!/usr/bin/env bash
# verify-repo-parity.sh — Verificador de paridad repo→fábrica (READ-ONLY, gobernado por el
# manifiesto assets/parity-manifest.tsv).
#
# USO:
#   bash .claude/skills/talent-repo-onboarding/scripts/verify-repo-parity.sh [REPO_DIR]
#
#   REPO_DIR  Directorio raiz del repo a auditar (default: cwd).
#
# SALIDAS (exits sellados):
#   0  Todos los checks DUROS pasan + CERO checks MANUAL pendientes.
#   1  FAIL — algún artefacto IDÉNTICO o EQUIVALENTE/ENTORNO no pasa el contrato.
#   2  ERROR — manifiesto inválido/duplicado, dep faltante, API caída, args inválidos,
#              receipt no parseable como JSON.
#   3  MANUAL-PENDING — los duros pasan pero quedan checks manuales sin receipt válido.
#
# VARIABLES DE ENTORNO (todas opcionales):
#   (canon)  Por DEFECTO el canon de los IDENTICOS sale del PROPIO paquete de fábrica (TAL-8037): la raíz
#            del paquete se deriva de este skill (`<skill>/../..`, el árbol del ZIP) y el mapa
#            assets/canon-paquete.tsv traduce producto→paquete. Sin checkout de casa ni git en el canon.
#   TRO_CANON_PACKAGE_DIR  Raíz del paquete de fábrica (override del derivado de la ubicación del skill).
#   TRO_CANON_REPO_DIR   OVERRIDE git: repo del que se leen los canónicos con `git show` (gana sobre el paquete).
#                        Sin paquete derivable ni override, el default histórico es el propio repo_dir.
#   TRO_CANON_REF        Ref del repo canónico en modo git (default: origin/main).
#   TRO_REPO_SLUG        owner/repo del repo a auditar (default: derivado de gh).
#   TRO_PROTECTION_JSON  Archivo JSON de branch protection (stub; default: gh api en vivo).
#   TRO_REPO_JSON        Archivo JSON de GET /repos (stub; default: gh api en vivo).
#   TF_LINEAR_TEAM_KEY   Clave del team Linear de la instancia (magic-word). SIN default de casa (fail-closed):
#                        env → línea TF_LINEAR_TEAM_KEY= del manifiesto (env TF_MANIFEST absoluto, o
#                        <repo>/.claude/tf-manifest.conf) → exit 2. TRO_LINEAR_KEY queda como alias heredado
#                        (si ambas están y difieren → exit 2).
#   TRO_RECEIPTS_DIR     Directorio con receipts JSON (<check_id>.json). Sin él: MANUAL-PENDING.
#   TRO_ATTEST_DIR       Directorio con stubs de readback (<comment_id>.json). Sin él: gh api.
#   TRO_RECEIPT_AUTHORITIES  CSV de user.id autorizados. Default vacío → todo receipt rechazado.
#   TRO_MANIFEST         Path del manifiesto TSV (override para tests; default: assets/parity-manifest.tsv).
#   LECTURA_ESTABLE_RELOJ  Solo pruebas: «simulado» avanza un reloj virtual en vez de dormir entre las lecturas
#                        en vivo de A2/A2b (scripts/lib/lectura_estable.py). No cambia el criterio.
#
# DEPENDENCIAS: bash 4+, git, command grep (ERE POSIX), jq, sha256sum (o shasum -a 256), gh;
#               python3 para la lectura estable en vivo de A2/A2b.
#
# NOTA (sugerencia plan-gate GO-r2): al emitir una atestación, attest_comment_id vive DENTRO
# de evidencia, creando una dependencia circular con evidencia_sha256. El protocolo correcto:
# (1) postear comentario placeholder para obtener el ID; (2) construir evidencia completa con
# ese ID; (3) calcular evidencia_sha256 = sha256(jq -S -c .evidencia); (4) editar el comentario
# con la línea final `attest v1 ...`. Ver references/03-verificacion-y-ensayo.md.

set -u

# ══════════════════════════════════════════════════════════════════════════════════════════
# HELPERS DE OUTPUT
# ══════════════════════════════════════════════════════════════════════════════════════════

_ok()      { printf '\033[0;32m[PASS]\033[0m %s\n'    "$*"; }
_fail()    { printf '\033[0;31m[FAIL]\033[0m %s\n'    "$*"; }
_pending() { printf '\033[1;33m[PENDING]\033[0m %s\n' "$*"; }
_err()     { printf '\033[0;31m[ERROR]\033[0m %s\n'   "$*" >&2; }

# ══════════════════════════════════════════════════════════════════════════════════════════
# ESTADO GLOBAL (acumulado)
# ══════════════════════════════════════════════════════════════════════════════════════════

HAS_FAIL=0      # 1 si algún check duro falló        → exit 1
HAS_ERROR=0     # 1 si hubo error de sistema/API    → exit 2
HAS_PENDING=0   # 1 si quedan receipts MANUAL        → exit 3
PENDING_COUNT=0

mark_fail()    { HAS_FAIL=1; }
mark_error()   { HAS_ERROR=1; }
mark_pending() { PENDING_COUNT=$(( PENDING_COUNT + 1 )); HAS_PENDING=1; }

# Prioridad de salida: ERROR(2) > FAIL(1) > PENDING(3) > OK(0)
# Los valores numéricos NO siguen orden de severidad, de ahí los flags separados.
final_rc() {
  if   [ "$HAS_ERROR"   -eq 1 ]; then printf '2'
  elif [ "$HAS_FAIL"    -eq 1 ]; then printf '1'
  elif [ "$HAS_PENDING" -eq 1 ]; then printf '3'
  else printf '0'; fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# FUNCIONES DE ACCESO A ARCHIVOS
# ══════════════════════════════════════════════════════════════════════════════════════════

# Ruta absoluta de un path relativo en el repo AUDITADO
target_path() { printf '%s/%s' "$REPO_DIR" "$1"; }

# Hash SHA-256 de un archivo del repo AUDITADO
target_hash() {
  local f; f="$(target_path "$1")"
  [ -f "$f" ] || { printf 'MISSING'; return 1; }
  "${SHA256_ARR[@]}" < "$f" | awk '{print $1}'
}

# Mode del índice del repo AUDITADO para un path
target_mode() {
  git -C "$REPO_DIR" ls-files -s -- "$1" 2>/dev/null | awk '{print $1}'
}

# Bytes del canónico: modo git (`git show`, NUNCA el working tree) o modo paquete (ficheros del propio paquete
# de fábrica, vía assets/canon-paquete.tsv — TAL-8037).
canon_map_lookup() { # <path_producto> → imprime la ruta del paquete; rc 1 si el mapa no la cubre
  awk -F'\t' -v p="$1" '$0 !~ /^#/ && $1==p {print $2; f=1; exit} END{exit !f}' "$CANON_MAP"
}
canon_bytes() {
  if [ "$CANON_MODE" = paquete ]; then
    local rel; rel="$(canon_map_lookup "$1")" || return 1
    cat -- "$CANON_PKG_DIR/$rel" 2>/dev/null
  else
    git -C "$CANON_DIR" show "${CANON_SHA}:${1}" 2>/dev/null
  fi
}
# Modo paquete: cada fichero del mapa debe existir en el paquete (paquete incompleto → rc 1).
canon_pkg_completo() {
  local prod rel
  while IFS=$'\t' read -r prod rel; do
    case "$prod" in '#'*|'') continue ;; esac
    [ -f "$CANON_PKG_DIR/$rel" ] || { _err "paquete incompleto: falta $rel (mapa canon-paquete.tsv)"; return 1; }
  done < "$CANON_MAP"
}
# Clave del team Linear: sin default de casa (TAL-8037). rc 2 (exit) si no resuelve o es inválida.
resolve_linear_key() {
  local key="${TF_LINEAR_TEAM_KEY:-}" legacy="${TRO_LINEAR_KEY:-}" mf="${TF_MANIFEST:-}"
  if [ -n "$key" ] && [ -n "$legacy" ] && [ "$key" != "$legacy" ]; then
    _err "TF_LINEAR_TEAM_KEY ($key) y TRO_LINEAR_KEY ($legacy) difieren — una sola clave (fail-closed)"; exit 2
  fi
  [ -n "$key" ] || key="$legacy"
  if [ -z "$key" ]; then
    [ -n "$mf" ] || { [ -f "$REPO_DIR/.claude/tf-manifest.conf" ] && mf="$REPO_DIR/.claude/tf-manifest.conf"; }
    if [ -n "$mf" ]; then
      case "$mf" in /*) : ;; *) _err "TF_MANIFEST debe ser ruta ABSOLUTA ($mf)"; exit 2 ;; esac
      [ -f "$mf" ] && key="$(sed -n -E 's/^TF_LINEAR_TEAM_KEY=("([^"]*)"|([^[:space:]"#]*)).*$/\2\3/p' "$mf" | tail -1)"
    fi
  fi
  [ -n "$key" ] || { _err "TF_LINEAR_TEAM_KEY sin resolver: ni la variable de entorno ni la línea TF_LINEAR_TEAM_KEY= del manifiesto (TF_MANIFEST o .claude/tf-manifest.conf) — fail-closed, jamás se asume una clave"; exit 2; }
  [[ $key =~ ^[A-Z][A-Z0-9]{0,9}$ ]] || { _err "TF_LINEAR_TEAM_KEY inválida ('$key'): se espera ^[A-Z][A-Z0-9]{0,9}$"; exit 2; }
  LINEAR_KEY="$key"
}

# Hash SHA-256 del canónico. `pipefail` en el subshell propaga el exit de
# `git show` (canon_bytes): si el path no existe en CANON_SHA la tubería falla
# (return 1) en vez de enmascararlo y hashear el string vacío como si fuera el
# contenido canónico. El contenido sigue fluyendo byte-a-byte por la tubería (no
# se captura en variable → sin pérdida de newline final).
canon_hash() {
  local h; h="$( set -o pipefail; canon_bytes "$1" | "${SHA256_ARR[@]}" )" || return 1
  printf '%s' "$h" | awk '{print $1}'
}

# ¿El archivo comienza con shebang?
is_script() {
  local f; f="$(target_path "$1")"
  [ -f "$f" ] && command grep -qm1 '^#!' "$f"
}

# ¿El archivo es texto (sin bytes NUL)?
is_text() {
  local f; f="$(target_path "$1")"
  [ -f "$f" ] || return 1
  # Intentar grep -P; si no disponible, asumir texto (LC_ALL=C lo detectaría con NUL)
  if command grep -qPm1 '\x00' "$f" 2>/dev/null; then return 1; fi
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# VERIFICADORES DE ARTEFACTOS
# ══════════════════════════════════════════════════════════════════════════════════════════

verificar_identico() {
  local artefacto="$1" path_canonico="$2" expected_mode="$3" verificaciones="$4"
  local local_file; local_file="$(target_path "$path_canonico")"
  local IFS='|'
  local tok
  read -ra tok <<< "$verificaciones"
  local t
  for t in "${tok[@]}"; do
    case "$t" in
    hash)
      local ch; ch="$(canon_hash "$path_canonico" 2>/dev/null)" || {
        _err "$artefacto: no se puede leer canónico $path_canonico"
        mark_error; continue
      }
      local th; th="$(target_hash "$path_canonico" 2>/dev/null)" || {
        _fail "$artefacto: archivo ausente en repo destino ($path_canonico)"
        mark_fail; continue
      }
      if [ "$ch" = "$th" ]; then
        _ok "$artefacto: hash OK"
      else
        _fail "$artefacto: hash DIFIERE — canónico=$ch destino=$th"
        mark_fail
      fi
      ;;
    tipo)
      if [ -f "$local_file" ]; then
        case "$path_canonico" in
        *.sh)
          # Los scripts .sh deben tener shebang
          if is_script "$path_canonico"; then
            _ok "$artefacto: tipo OK (shebang)"
          else
            _fail "$artefacto: falta shebang en $path_canonico"
            mark_fail
          fi
          ;;
        *)
          # .jq, .md y otros artefactos deben ser texto (no binario)
          if is_text "$path_canonico"; then
            _ok "$artefacto: tipo OK (texto)"
          else
            _fail "$artefacto: archivo binario inesperado ($path_canonico)"
            mark_fail
          fi
          ;;
        esac
      fi
      ;;
    modo)
      local actual; actual="$(target_mode "$path_canonico")"
      if [ -z "$actual" ]; then
        _fail "$artefacto: archivo no en el índice del repo destino ($path_canonico)"
        mark_fail
      elif [ "$actual" = "$expected_mode" ]; then
        _ok "$artefacto: modo OK ($actual)"
      else
        _fail "$artefacto: modo DIFIERE — esperado=$expected_mode actual=$actual"
        mark_fail
      fi
      ;;
    exec)
      if [ -x "$local_file" ]; then
        _ok "$artefacto: exec OK"
      else
        _fail "$artefacto: no ejecutable ($path_canonico)"
        mark_fail
      fi
      ;;
    esac
  done
}

# [TAL-8040] ¿el .gitignore (texto ya normalizado, arg 1) trae el patrón LITERAL (arg 2) en una línea
# propia? Los comentarios (`# patrón`) no son la línea literal. Las NEGACIONES no se razonan aquí con
# grep: las decide git (_gitignore_ignora, «gana la última regla que casa»).
_gitignore_tiene() { # texto patrón
  command grep -qxF -- "$2" <<<"$1"
}

# [TAL-8040] ¿git IGNORA de verdad la ruta (arg 2) con ese .gitignore (texto en arg 1)? Repo temporal
# desechable con SOLO ese .gitignore (sin plantillas ni excludesFile global): semántica real de git, p. ej.
# `.claude/.cr-review-*` + `!.claude/.cr-review-ok` NO ignora .cr-review-ok; una negación ANTERIOR a la regla
# no la anula. rc 0 = ignorada · 1 = no ignorada o no se pudo evaluar (fail-closed).
_gitignore_ignora() { # texto ruta
  local d rc=1
  d="$(mktemp -d)" || return 1
  if command git init -q --template= "$d" >/dev/null 2>&1; then
    printf '%s\n' "$1" > "$d/.gitignore"
    command git -c core.excludesFile=/dev/null -C "$d" check-ignore -q -- "$2" >/dev/null 2>&1 && rc=0
  fi
  rm -rf "$d"
  return "$rc"
}

verificar_equivalente() {
  local artefacto="$1" path_canonico="$2" check_id="$3"
  local f; f="$(target_path "$path_canonico")"
  case "$check_id" in

  draft_handoff)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    local n=0
    command grep -qm1 '^#!' "$f"                           && n=$(( n+1 ))
    command grep -qm1 'validar-rama-pr' "$f"               && n=$(( n+1 ))
    command grep -qm1 'draft-handoff' "$f"                 && n=$(( n+1 ))
    command grep -qEm1 'typecheck|lint|build' "$f"         && n=$(( n+1 ))
    if [ "$n" -ge 4 ]; then
      _ok "$artefacto: draft-handoff estructura OK ($n/4)"
    else
      _fail "$artefacto: draft-handoff estructura INCOMPLETA ($n/4: shebang+validador-ramas+sentinel+gate)"
      mark_fail
    fi
    ;;

  coderabbit)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    local n=0
    command grep -qEm1 'drafts:[[:space:]]*false' "$f"           && n=$(( n+1 ))
    command grep -qEm1 'request_changes_workflow:[[:space:]]*true' "$f" && n=$(( n+1 ))
    command grep -qm1 'auto_review' "$f"                         && n=$(( n+1 ))
    if [ "$n" -ge 2 ]; then
      _ok "$artefacto: .coderabbit.yaml OK ($n/3)"
    else
      _fail "$artefacto: .coderabbit.yaml incompleto ($n/3: drafts:false, request_changes_workflow:true, auto_review)"
      mark_fail
    fi
    ;;

  reglas_md)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    local n=0
    command grep -qEm1 'draft-handoff|draft_handoff' "$f"   && n=$(( n+1 ))
    command grep -qm1 'local-gates' "$f"                    && n=$(( n+1 ))
    command grep -qEm1 'cr-review|coderabbit' "$f"          && n=$(( n+1 ))
    if [ "$n" -ge 2 ]; then
      _ok "$artefacto: bloque reglas fábrica OK ($n/3)"
    else
      _fail "$artefacto: bloque reglas fábrica INCOMPLETO ($n/3: draft-handoff, local-gates, cr-review)"
      mark_fail
    fi
    ;;

  pr_template)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    # Gramática template: literal `Closes <KEY>-N` (N = letra placeholder, no dígito)
    if command grep -qFm1 "Closes ${LINEAR_KEY}-N" "$f"; then
      _ok "$artefacto: magic-word template OK (Closes ${LINEAR_KEY}-N)"
    else
      _fail "$artefacto: template NO contiene 'Closes ${LINEAR_KEY}-N' (key=$LINEAR_KEY)"
      mark_fail
    fi
    ;;

  gitignore_sentinels)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    # [TAL-8040] LOS 6 patrones (antes: umbral 2 de 3 con grep laxo → un .gitignore sin tf-manifest daba verde).
    # Cada patrón exige (1) la línea LITERAL (sin espacios finales/CR, no comentada; `.claude/.cr-review-ok` vale
    # también cubierto por el comodín `.claude/.cr-review-*`) Y (2) que git IGNORE de verdad la ruta con ese
    # .gitignore — así una negación posterior (`!patrón`) falla y una anterior no da falso FAIL.
    local n=0 faltan="" pat probe gi_lines
    gi_lines="$(command sed 's/\r$//; s/[[:space:]]*$//' "$f")"
    for pat in .claude/.cr-review-ok .claude/.draft-handoff .claude/.audit-go \
               .claude/tf-manifest.conf .claude/.motor-go '.claude/.cr-review-*'; do
      probe="$pat"; [ "$pat" = '.claude/.cr-review-*' ] && probe=.claude/.cr-review-probe
      if { _gitignore_tiene "$gi_lines" "$pat" \
           || { [ "$pat" = .claude/.cr-review-ok ] && _gitignore_tiene "$gi_lines" '.claude/.cr-review-*'; }; } \
         && _gitignore_ignora "$gi_lines" "$probe"; then
        n=$(( n+1 ))
      else
        faltan="$faltan $pat"
      fi
    done
    if [ "$n" -eq 6 ]; then
      _ok "$artefacto: sentinels ignorados OK ($n/6)"
    else
      _fail "$artefacto: .gitignore no ignora los 6 patrones de fábrica ($n/6; faltan:$faltan)"
      mark_fail
    fi
    ;;

  settings_hooks)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    if ! jq -s -e 'length == 1 and (.[0] | type == "object")' "$f" 2>/dev/null; then
      _fail "$artefacto: .claude/settings.json no es JSON válido"
      mark_fail; return
    fi
    local n=0
    command grep -qm1 'check-skill'                         "$f" && n=$(( n+1 ))
    command grep -qEm1 'check-push-audit|push.audit'        "$f" && n=$(( n+1 ))
    if [ "$n" -ge 2 ]; then
      _ok "$artefacto: settings.json hooks OK ($n/2)"
    else
      _fail "$artefacto: settings.json no registra ambos hooks ($n/2: check-skill, check-push-audit)"
      mark_fail
    fi
    ;;

  check_skill)
    [ -f "$f" ] || { _fail "$artefacto: $path_canonico ausente"; mark_fail; return; }
    [ -x "$f" ] || { _fail "$artefacto: check-skill.sh no ejecutable"; mark_fail; return; }
    if command grep -qm1 'tool_input' "$f" && command grep -qm1 'file_path' "$f"; then
      _ok "$artefacto: check-skill.sh OK (presente, ejecutable, lee tool_input.file_path)"
    else
      _fail "$artefacto: check-skill.sh no lee tool_input.file_path"
      mark_fail
    fi
    # Verificar que está cableado en settings.json
    local sf; sf="$(target_path ".claude/settings.json")"
    if [ -f "$sf" ] && command grep -qm1 'check-skill' "$sf"; then
      _ok "$artefacto: check-skill.sh cableado en settings.json"
    else
      _fail "$artefacto: check-skill.sh presente pero NO cableado en .claude/settings.json"
      mark_fail
    fi
    ;;

  *)
    _err "Matcher estructura desconocido: '$check_id' (artefacto '$artefacto')"
    mark_error
    ;;
  esac
}

verificar_entorno() {
  local artefacto="$1" _config_key="$2" check_id="$3"
  case "$check_id" in

  hookspath)
    local val; val="$(git -C "$REPO_DIR" config --local core.hooksPath 2>/dev/null)"
    if [ "$val" = ".githooks" ]; then
      _ok "$artefacto: core.hooksPath=.githooks OK"
    else
      _fail "$artefacto: core.hooksPath='$val' (esperado .githooks) — correr setup-githooks.sh"
      mark_fail
    fi
    ;;

  skill_issue_craft)
    local d; d="$(target_path ".claude/skills/talent-issue-craft")"
    if [ -d "$d" ]; then
      _ok "$artefacto: skill talent-issue-craft presente"
    else
      _fail "$artefacto: skill talent-issue-craft AUSENTE"
      mark_fail
    fi
    ;;

  perfil)
    local ref_dir; ref_dir="$(target_path "docs/reference")"
    local found=0
    if [ -d "$ref_dir" ]; then
      while IFS= read -r -d '' _pf; do found=1; break; done \
        < <(find "$ref_dir" -maxdepth 1 -name "issue-craft-perfil*.md" -print0 2>/dev/null)
    fi
    if [ "$found" -eq 1 ]; then
      _ok "$artefacto: perfil issue-craft-perfil*.md presente en docs/reference/"
    else
      _fail "$artefacto: perfil AUSENTE (docs/reference/issue-craft-perfil*.md)"
      mark_fail
    fi
    ;;

  *)
    _err "Matcher entorno desconocido: '$check_id' (artefacto '$artefacto')"
    mark_error
    ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# HELPER: comparar un valor escalar contra el esperado (evita A&&B||C)
# ══════════════════════════════════════════════════════════════════════════════════════════

# Uso: check_scalar "PREFIX(N/M)" "nombre" "actual" "esperado" [contador_var]
# Incrementa RC y contador si falla; devuelve 0 si OK, 1 si falla.
check_scalar() {
  local prefix="$1" name="$2" actual="$3" expected="$4"
  if [ "$actual" = "$expected" ]; then
    _ok "${prefix}: ${name}=${expected}"
    return 0
  else
    _fail "${prefix}: ${name}='${actual}' (esperado ${expected})"
    mark_fail
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# LECTURA ESTABLE EN VIVO (A2/A2b)
# ══════════════════════════════════════════════════════════════════════════════════════════

# Tras escribir, GitHub puede alternar nuevo → viejo → nuevo durante unos segundos: una lectura única
# puede caer en la réplica vieja. En vivo, A2 y A2b leen con scripts/lib/lectura_estable.py (el mismo
# helper que f4-proteccion): 3 lecturas SEGUIDAS iguales a lo que el bloque exige, separadas 5 s; una
# distinta pone la cuenta a cero; tope 60 s. Las comprobaciones check_scalar NO cambian: evalúan la
# ÚLTIMA respuesta. Si no se estabiliza, el bloque falla aunque la última respuesta fuera buena.
# Con los stubs TRO_PROTECTION_JSON/TRO_REPO_JSON no se usa.
RC_LECTURA_GH=3            # gh falló: su salida va en stdout, como el `gh api … 2>&1` de antes
RC_LECTURA_NO_PARSEABLE=4  # respuesta no JSON: se evalúa tal cual (FAIL, como antes)
RC_LECTURA_INESTABLE=5     # sin estabilizar en el tope: FAIL; el motivo va por stderr
# Lo que exige cada bloque, como subconjunto JSON (semántica `matches` del helper).
A2_ESPERADO='{"required_status_checks":{"strict":true,"checks":[{"context":"local-gates"}]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0,"dismiss_stale_reviews":true,"require_code_owner_reviews":false,"require_last_push_approval":false},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false,"block_creations":false,"required_conversation_resolution":true}'
A2B_ESPERADO='{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"delete_branch_on_merge":false}'

# Uso: raw="$(lectura_estable ENDPOINT ESPERADO)" || rc=$?
lectura_estable() {
  python3 -B -I "$SKILL_DIR/scripts/lib/lectura_estable.py" "$1" "$2"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# BLOQUE A2: Branch protection
# ══════════════════════════════════════════════════════════════════════════════════════════

bloque_a2() {
  local prot_json
  if [ -n "${TRO_PROTECTION_JSON:-}" ] && [ -f "$TRO_PROTECTION_JSON" ]; then
    prot_json="$(cat "$TRO_PROTECTION_JSON")"
  else
    local slug; slug="$(repo_slug)"
    local raw gh_rc=0
    raw="$(lectura_estable "repos/${slug}/branches/main/protection" "$A2_ESPERADO")" || gh_rc=$?
    case "$gh_rc" in
    0) : ;;
    "$RC_LECTURA_GH")
      if printf '%s' "$raw" | command grep -qi "Upgrade to GitHub Pro"; then
        _pending "A2: plan FREE — protección no enforced vía API (procedural, exit 3)"
        mark_pending
      else
        _err "A2: gh api falló: $raw"
        mark_error
      fi
      return
      ;;
    "$RC_LECTURA_INESTABLE")
      _fail "A2: lectura de GitHub sin estabilizar en el tope (motivo arriba); se evalúa la última respuesta"
      mark_fail
      ;;
    "$RC_LECTURA_NO_PARSEABLE")
      _fail "A2: respuesta de GitHub no parseable; se evalúa tal cual"
      mark_fail
      ;;
    *)
      _err "A2: lectura estable no ejecutable o mal invocada (rc=$gh_rc; requiere python3 y scripts/lib/lectura_estable.py; motivo arriba)"
      mark_error
      return
      ;;
    esac
    prot_json="$raw"
  fi

  local n=0

  local ctx; ctx="$(printf '%s' "$prot_json" | jq -r \
    '.required_status_checks.checks // [] | map(.context) | join(",")' 2>/dev/null)"
  check_scalar "A2(1/12)" "required_checks" "$ctx" "local-gates" && n=$(( n+1 ))

  local strict; strict="$(printf '%s' "$prot_json" | \
    jq -r '.required_status_checks.strict // false' 2>/dev/null)"
  check_scalar "A2(2/12)" "strict" "$strict" "true" && n=$(( n+1 ))

  # Nota: jq `// true` falla para booleanos-false (false es falsy en jq, lo sustituye el default).
  # Patrón correcto para "expected=false": `if . == null then true else . end | tostring`
  local ea; ea="$(printf '%s' "$prot_json" | \
    jq -r '.enforce_admins.enabled | if . == null then true else . end | tostring' 2>/dev/null)"
  check_scalar "A2(3/12)" "enforce_admins" "$ea" "false" && n=$(( n+1 ))

  local approving; approving="$(printf '%s' "$prot_json" | \
    jq -r '.required_pull_request_reviews.required_approving_review_count // -1' 2>/dev/null)"
  check_scalar "A2(4/12)" "approving_count" "$approving" "0" && n=$(( n+1 ))

  local ds; ds="$(printf '%s' "$prot_json" | \
    jq -r '.required_pull_request_reviews.dismiss_stale_reviews // false' 2>/dev/null)"
  check_scalar "A2(5/12)" "dismiss_stale" "$ds" "true" && n=$(( n+1 ))

  local co; co="$(printf '%s' "$prot_json" | \
    jq -r '.required_pull_request_reviews.require_code_owner_reviews | if . == null then true else . end | tostring' 2>/dev/null)"
  check_scalar "A2(6/12)" "code_owner_reviews" "$co" "false" && n=$(( n+1 ))

  local lp; lp="$(printf '%s' "$prot_json" | \
    jq -r '.required_pull_request_reviews.require_last_push_approval | if . == null then true else . end | tostring' 2>/dev/null)"
  check_scalar "A2(7/12)" "last_push_approval" "$lp" "false" && n=$(( n+1 ))

  local restr; restr="$(printf '%s' "$prot_json" | jq '.restrictions' 2>/dev/null)"
  check_scalar "A2(8/12)" "restrictions" "$restr" "null" && n=$(( n+1 ))

  local lh; lh="$(printf '%s' "$prot_json" | \
    jq -r '.required_linear_history.enabled // false' 2>/dev/null)"
  check_scalar "A2(9/12)" "linear_history" "$lh" "true" && n=$(( n+1 ))

  local fp; fp="$(printf '%s' "$prot_json" | \
    jq -r '.allow_force_pushes.enabled | if . == null then true else . end | tostring' 2>/dev/null)"
  check_scalar "A2(10/12)" "force_pushes" "$fp" "false" && n=$(( n+1 ))

  local del; del="$(printf '%s' "$prot_json" | \
    jq -r '.allow_deletions.enabled | if . == null then true else . end | tostring' 2>/dev/null)"
  local bc; bc="$(printf '%s' "$prot_json" | \
    jq -r '.block_creations.enabled | if . == null then true else . end | tostring' 2>/dev/null)"
  if [ "$del" = "false" ] && [ "$bc" = "false" ]; then
    _ok "A2(11/12): deletions=false, block_creations=false"
    n=$(( n+1 ))
  else
    _fail "A2(11/12): deletions='$del' block_creations='$bc' (esperados false)"
    mark_fail
  fi

  local cr; cr="$(printf '%s' "$prot_json" | \
    jq -r '.required_conversation_resolution.enabled // false' 2>/dev/null)"
  check_scalar "A2(12/12)" "conversation_resolution" "$cr" "true" && n=$(( n+1 ))

  printf 'A2: %d/12 valores correctos\n' "$n"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# BLOQUE A2b: Repo settings
# ══════════════════════════════════════════════════════════════════════════════════════════

bloque_a2b() {
  local repo_json
  if [ -n "${TRO_REPO_JSON:-}" ] && [ -f "$TRO_REPO_JSON" ]; then
    repo_json="$(cat "$TRO_REPO_JSON")"
  else
    local slug; slug="$(repo_slug)"
    local raw gh_rc=0
    raw="$(lectura_estable "repos/${slug}" "$A2B_ESPERADO")" || gh_rc=$?
    case "$gh_rc" in
    0) : ;;
    "$RC_LECTURA_GH")
      _err "A2b: gh api repos/$slug falló: $raw"
      mark_error; return
      ;;
    "$RC_LECTURA_INESTABLE")
      _fail "A2b: lectura de GitHub sin estabilizar en el tope (motivo arriba); se evalúa la última respuesta"
      mark_fail
      ;;
    "$RC_LECTURA_NO_PARSEABLE")
      _fail "A2b: respuesta de GitHub no parseable; se evalúa tal cual"
      mark_fail
      ;;
    *)
      _err "A2b: lectura estable no ejecutable o mal invocada (rc=$gh_rc; requiere python3 y scripts/lib/lectura_estable.py; motivo arriba)"
      mark_error; return
      ;;
    esac
    repo_json="$raw"
  fi

  local n=0

  local sq; sq="$(printf '%s' "$repo_json" | jq -r '.allow_squash_merge // false' 2>/dev/null)"
  check_scalar "A2b(1/4)" "allow_squash_merge" "$sq" "true" && n=$(( n+1 ))

  local mc; mc="$(printf '%s' "$repo_json" | jq -r '.allow_merge_commit // false' 2>/dev/null)"
  check_scalar "A2b(2/4)" "allow_merge_commit" "$mc" "true" && n=$(( n+1 ))

  local rb; rb="$(printf '%s' "$repo_json" | jq -r '.allow_rebase_merge // false' 2>/dev/null)"
  check_scalar "A2b(3/4)" "allow_rebase_merge" "$rb" "true" && n=$(( n+1 ))

  local db; db="$(printf '%s' "$repo_json" | \
    jq -r '.delete_branch_on_merge | if . == null then true else . end | tostring' 2>/dev/null)"
  check_scalar "A2b(4/4)" "delete_branch_on_merge" "$db" "false" && n=$(( n+1 ))

  printf 'A2b: %d/4 valores correctos\n' "$n"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# BLOQUE Magic word
# ══════════════════════════════════════════════════════════════════════════════════════════

bloque_magic_word() {
  local f; f="$(target_path ".github/PULL_REQUEST_TEMPLATE.md")"
  [ -f "$f" ] || { _fail "Magic word: PULL_REQUEST_TEMPLATE.md ausente"; mark_fail; return; }
  # Gramática 1 — literal `Closes <KEY>-N` (template-check; N = letra placeholder, no dígito)
  if command grep -qFm1 "Closes ${LINEAR_KEY}-N" "$f"; then
    _ok "Magic word: template OK (Closes ${LINEAR_KEY}-N)"
  else
    _fail "Magic word: template NO contiene 'Closes ${LINEAR_KEY}-N' (key=$LINEAR_KEY)"
    mark_fail
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# BLOQUE Receipts / MANUAL-PENDING
# ══════════════════════════════════════════════════════════════════════════════════════════

# Readback inyectable de la atestación: produce JSON {user:{id,login}, body}.
# Exit codes: 0=ok · 1=recurso no encontrado (404/stub ausente) · 2=error de sistema.
attest_readback() {
  local comment_id="$1"
  local attest_dir="${TRO_ATTEST_DIR:-}"
  if [ -n "$attest_dir" ] && [ -d "$attest_dir" ]; then
    local stub="$attest_dir/${comment_id}.json"
    if [ -f "$stub" ]; then cat "$stub"; return 0; fi
    return 1  # stub dir configurado pero archivo ausente → recurso no existe
  fi
  local slug; slug="$(repo_slug)"
  [ -n "$slug" ] || return 2
  local gh_out gh_rc
  gh_out="$(gh api "repos/${slug}/issues/comments/${comment_id}" 2>&1)"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    # 404 → recurso no existe (exit 1); otro error → error de sistema (exit 2)
    if printf '%s' "$gh_out" | command grep -qEi "404|not found"; then
      return 1
    fi
    return 2
  fi
  printf '%s' "$gh_out"
  return 0
}

# sha256 de una cadena
sha256_str() { printf '%s' "$1" | "${SHA256_ARR[@]}" | awk '{print $1}'; }

process_receipt() {
  local check_id="$1"
  local receipt_file=""
  local receipts_dir="${TRO_RECEIPTS_DIR:-}"

  if [ -n "$receipts_dir" ] && [ -d "$receipts_dir" ]; then
    receipt_file="${receipts_dir}/${check_id}.json"
  fi

  if [ -z "$receipt_file" ] || [ ! -f "$receipt_file" ]; then
    _pending "MANUAL [$check_id]: sin receipt — pendiente"
    mark_pending
    return
  fi

  # 1. Parsear JSON
  local rj; rj="$(cat "$receipt_file")" || { _err "receipt $check_id: no se puede leer"; mark_error; return; }
  if ! printf '%s' "$rj" | jq empty 2>/dev/null; then
    _err "receipt $check_id: JSON no parseable (exit 2)"
    mark_error; return
  fi

  # 2. Campo check_id debe coincidir
  local rid; rid="$(printf '%s' "$rj" | jq -r '.check_id // empty')"
  [ "$rid" = "$check_id" ] || { _fail "receipt $check_id: check_id='$rid' no coincide"; mark_pending; return; }

  # 3. Repo debe coincidir
  local r_repo; r_repo="$(printf '%s' "$rj" | jq -r '.repo // empty')"
  local slug; slug="$(repo_slug)"
  [ -n "$slug" ] && [ "$r_repo" != "$slug" ] && {
    _fail "receipt $check_id: repo='$r_repo' != auditado='$slug'"
    mark_pending; return
  }

  # 4. TTL exacto: expires_at - issued_at = 604800
  local issued expires issued_ep expires_ep
  issued="$(printf '%s' "$rj"  | jq -r '.issued_at  // empty')"
  expires="$(printf '%s' "$rj" | jq -r '.expires_at // empty')"
  issued_ep="$(date -d  "$issued"  +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issued"  +%s 2>/dev/null)" || {
    _err "receipt $check_id: issued_at no parseable"; mark_error; return
  }
  expires_ep="$(date -d "$expires" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null)" || {
    _err "receipt $check_id: expires_at no parseable"; mark_error; return
  }
  local ttl=$(( expires_ep - issued_ep ))
  if [ "$ttl" -ne 604800 ]; then
    _fail "receipt $check_id: TTL=$ttl (debe ser exactamente 604800 s)"
    mark_pending; return
  fi

  # 5. Reloj: issued_at no puede ser > now+300s
  local now; now="$(date +%s)"
  if [ "$issued_ep" -gt $(( now + 300 )) ]; then
    _fail "receipt $check_id: issued_at en el futuro (issued=$issued_ep now=$now)"
    mark_pending; return
  fi

  # 6. No expirado
  if [ "$expires_ep" -lt "$now" ]; then
    _fail "receipt $check_id: EXPIRADO (expires=$expires_ep < now=$now)"
    mark_pending; return
  fi

  # 7. evidencia: campos obligatorios por check_id (forma sellada en 03-verificacion-y-ensayo.md)
  local evid_required
  case "$check_id" in
    linear-integration)        evid_required="pr_url issue_id attest_comment_id" ;;
    cr-app-instalada)          evid_required="pr_url review_id attest_comment_id" ;;
    cr-app-draft-silencio)     evid_required="pr_url attest_comment_id" ;;
    push-sentinel-block)       evid_required="commit_sha branch attest_comment_id" ;;
    audit-issue-maquina-limpia) evid_required="issue_id salida_sha256 attest_comment_id" ;;
    ensayo-e2e)                evid_required="pr_url status_context issue_id attest_comment_id" ;;
    accesos-y-deploy)          evid_required="smoke_urls_codes anexo_ref attest_comment_id" ;;
    *)                         evid_required="attest_comment_id" ;;
  esac
  local ef
  for ef in $evid_required; do
    local ev_val; ev_val="$(printf '%s' "$rj" | jq -r --arg f "$ef" '.evidencia[$f] // empty')"
    [ -n "$ev_val" ] || { _fail "receipt $check_id: evidencia.$ef faltante (check_id=$check_id)"; mark_pending; return; }
  done
  local attest_id; attest_id="$(printf '%s' "$rj" | jq -r '.evidencia.attest_comment_id // empty')"

  # 8. Readback remoto de la atestación (0=ok · 1=no encontrado · 2=error sistema)
  local cj cj_rc
  cj="$(attest_readback "$attest_id" 2>/dev/null)"
  cj_rc=$?
  if [ "$cj_rc" -eq 1 ]; then
    _fail "receipt $check_id: atestación no encontrada (comment_id=$attest_id)"
    mark_pending; return
  elif [ "$cj_rc" -ne 0 ]; then
    _err "receipt $check_id: readback falló — error del sistema (comment_id=$attest_id)"
    mark_error; return
  fi
  if ! printf '%s' "$cj" | jq empty 2>/dev/null; then
    _err "receipt $check_id: readback JSON inválido"
    mark_error; return
  fi

  # 9. Identidad: user.id ∈ lista autorizada (JAMÁS el actor del JSON)
  local author_id; author_id="$(printf '%s' "$cj" | jq -r '.user.id // empty')"
  [ -n "$author_id" ] || { _fail "receipt $check_id: atestación sin user.id"; mark_pending; return; }
  local authorities="${TRO_RECEIPT_AUTHORITIES:-}"
  # Fallback a assets/receipt-authorities.txt del repo auditado (doc 03-verificacion-y-ensayo.md)
  if [ -z "$authorities" ] && [ -f "$REPO_DIR/assets/receipt-authorities.txt" ]; then
    authorities="$(command grep -v '^\s*#' "$REPO_DIR/assets/receipt-authorities.txt" \
      | tr '\n' ',' | sed 's/,$//')"
  fi
  local is_auth=0
  if [ -n "$authorities" ]; then
    local old_ifs="$IFS"
    IFS=',' read -ra auth_list <<< "$authorities"
    IFS="$old_ifs"
    local a
    for a in "${auth_list[@]}"; do
      [ "$a" = "$author_id" ] && { is_auth=1; break; }
    done
  fi
  [ "$is_auth" -eq 1 ] || {
    _fail "receipt $check_id: author_id='$author_id' no autorizado"
    mark_pending; return
  }

  # 10. Binding: primera línea del body
  local body; body="$(printf '%s' "$cj" | jq -r '.body // empty')"
  local first_line; first_line="$(printf '%s\n' "$body" | head -n1)"
  case "$first_line" in
  'attest v1 '*) ;;
  *) _fail "receipt $check_id: primera línea no es 'attest v1 ...'"; mark_pending; return ;;
  esac

  # Extraer campos del binding con command grep -oE
  local b_cid b_repo b_branch b_sha_p b_sha_c b_actor b_evid
  b_cid="$(    printf '%s' "$first_line" | command grep -oE 'check_id=[^ ]+'     | cut -d= -f2)"
  b_repo="$(   printf '%s' "$first_line" | command grep -oE 'repo=[^ ]+'         | cut -d= -f2)"
  b_branch="$( printf '%s' "$first_line" | command grep -oE 'branch=[^ ]+'       | cut -d= -f2)"
  b_sha_p="$(  printf '%s' "$first_line" | command grep -oE 'sha_probado=[^ ]+'  | cut -d= -f2)"
  b_sha_c="$(  printf '%s' "$first_line" | command grep -oE 'sha_canonico=[^ ]+' | cut -d= -f2)"
  b_actor="$(  printf '%s' "$first_line" | command grep -oE 'actor=[^ ]+'        | cut -d= -f2)"
  b_evid="$(   printf '%s' "$first_line" | command grep -oE 'evidencia_sha256=[^ ]+' | cut -d= -f2)"

  # Comparación literal campo a campo contra el receipt
  local mismatch=0
  local r_check_id; r_check_id="$(printf '%s' "$rj" | jq -r '.check_id    // empty')"
  local r_repo_v;   r_repo_v="$(  printf '%s' "$rj" | jq -r '.repo        // empty')"
  local r_branch;   r_branch="$(  printf '%s' "$rj" | jq -r '.branch      // empty')"
  local r_sha_p;    r_sha_p="$(   printf '%s' "$rj" | jq -r '.sha_probado // empty')"
  local r_sha_c;    r_sha_c="$(   printf '%s' "$rj" | jq -r '.sha_canonico// empty')"

  [ "$b_cid"    = "$r_check_id" ] || { _fail "receipt $check_id: binding check_id '$b_cid' != '$r_check_id'"; mismatch=1; }
  [ "$b_repo"   = "$r_repo_v"   ] || { _fail "receipt $check_id: binding repo '$b_repo' != '$r_repo_v'"; mismatch=1; }
  [ "$b_branch" = "$r_branch"   ] || { _fail "receipt $check_id: binding branch '$b_branch' != '$r_branch'"; mismatch=1; }
  [ "$b_sha_p"  = "$r_sha_p"    ] || { _fail "receipt $check_id: binding sha_probado '$b_sha_p' != '$r_sha_p'"; mismatch=1; }
  [ "$b_sha_c"  = "$r_sha_c"    ] || { _fail "receipt $check_id: binding sha_canonico '$b_sha_c' != '$r_sha_c'"; mismatch=1; }
  [ "$b_actor"  = "$author_id"  ] || { _fail "receipt $check_id: binding actor '$b_actor' != user.id '$author_id'"; mismatch=1; }

  # evidencia_sha256 = sha256(jq -S -c .evidencia)
  local evid_canonical; evid_canonical="$(printf '%s' "$rj" | jq -S -c '.evidencia' 2>/dev/null)"
  local computed; computed="$(sha256_str "$evid_canonical")"
  [ "$b_evid" = "$computed" ] || { _fail "receipt $check_id: evidencia_sha256 binding '$b_evid' != computado '$computed'"; mismatch=1; }

  if [ "$mismatch" -eq 0 ]; then
    _ok "receipt [$check_id]: VÁLIDO (author=$author_id)"
  else
    mark_pending
  fi
}

bloque_receipts() {
  local CHECK_IDS=(
    linear-integration
    cr-app-instalada
    cr-app-draft-silencio
    push-sentinel-block
    audit-issue-maquina-limpia
    ensayo-e2e
    accesos-y-deploy
  )
  local cid
  for cid in "${CHECK_IDS[@]}"; do
    process_receipt "$cid"
  done
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# UTILIDAD: slug del repo
# ══════════════════════════════════════════════════════════════════════════════════════════

REPO_SLUG_CACHE=""
repo_slug() {
  if [ -n "$REPO_SLUG_CACHE" ]; then
    printf '%s' "$REPO_SLUG_CACHE"; return 0
  fi
  local slug="${TRO_REPO_SLUG:-}"
  [ -z "$slug" ] && slug="$(cd "$REPO_DIR" && gh repo view --json nameWithOwner \
    -q '.nameWithOwner' 2>/dev/null)"
  REPO_SLUG_CACHE="$slug"
  printf '%s' "$slug"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════════════════

main() {
  # ── Ancla al skill root ──────────────────────────────────────────────────────────────
  SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  MANIFEST="${TRO_MANIFEST:-$SKILL_DIR/assets/parity-manifest.tsv}"

  REPO_DIR="${1:-$(pwd)}"
  REPO_DIR="$(cd "$REPO_DIR" && pwd)" || { _err "No se puede entrar a $REPO_DIR"; exit 2; }

  CANON_MAP="$SKILL_DIR/assets/canon-paquete.tsv"
  CANON_REF="${TRO_CANON_REF:-origin/main}"
  # Origen del canon (TAL-8037): override git explícito > paquete (TRO_CANON_PACKAGE_DIR o el derivado de la
  # ubicación del skill, si es un árbol de paquete) > default histórico (el propio repo_dir en modo git).
  CANON_MODE=git; CANON_DIR=""; CANON_PKG_DIR=""
  if [ -n "${TRO_CANON_REPO_DIR:-}" ]; then
    CANON_DIR="$TRO_CANON_REPO_DIR"
  else
    CANON_PKG_DIR="${TRO_CANON_PACKAGE_DIR:-}"
    if [ -z "$CANON_PKG_DIR" ] && [ -f "$SKILL_DIR/../../githooks/pre-push" ] && [ -f "$SKILL_DIR/../../scripts/verify-handoff.sh" ]; then
      CANON_PKG_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
    fi
    if [ -n "$CANON_PKG_DIR" ]; then
      [ -d "$CANON_PKG_DIR" ] || { _err "TRO_CANON_PACKAGE_DIR no es un directorio: $CANON_PKG_DIR"; exit 2; }
      [ -f "$CANON_MAP" ] || { _err "Mapa del canon no encontrado: $CANON_MAP"; exit 2; }
      CANON_MODE=paquete; CANON_PKG_DIR="$(cd "$CANON_PKG_DIR" && pwd)"
    else
      CANON_DIR="$REPO_DIR"
    fi
  fi
  resolve_linear_key

  # ── Dependencias (fail-closed) ───────────────────────────────────────────────────────
  local dep
  for dep in git jq gh; do
    command -v "$dep" >/dev/null 2>&1 || { _err "dep faltante: $dep"; exit 2; }
  done
  SHA256_ARR=()
  if command -v sha256sum >/dev/null 2>&1; then SHA256_ARR=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then  SHA256_ARR=(shasum -a 256)
  else _err "dep faltante: sha256sum / shasum"; exit 2; fi

  # ── Manifiesto: existencia ────────────────────────────────────────────────────────────
  [ -f "$MANIFEST" ] || { _err "Manifiesto no encontrado: $MANIFEST"; exit 2; }

  # ── Resolución del SHA canónico ───────────────────────────────────────────────────────
  if [ "$CANON_MODE" = paquete ]; then
    canon_pkg_completo || exit 2
    CANON_SHA="paquete"   # sin SHA git: el canon son los ficheros del paquete (los receipts llevan su propio binding)
    printf '── Canon: paquete %s\n' "$CANON_PKG_DIR"
  else
    CANON_SHA="$(git -C "$CANON_DIR" rev-parse "$CANON_REF" 2>/dev/null)" || {
      _err "No se puede resolver $CANON_REF en $CANON_DIR"
      exit 2
    }
    printf '── SHA canónico (%s @ %s): %s\n' "$CANON_REF" "$CANON_DIR" "$CANON_SHA"
  fi
  printf '── Repo auditado: %s\n\n' "$REPO_DIR"

  # ── Parse del manifiesto con detección de duplicados ─────────────────────────────────
  declare -A SEEN_IDS
  local MANIFEST_ROWS=()
  local artefacto clase path_canonico expected_mode verificaciones
  while IFS=$'\t' read -r artefacto clase path_canonico expected_mode verificaciones; do
    case "$artefacto" in '#'*|'') continue ;; esac
    if [ "${SEEN_IDS[$artefacto]+_}" ]; then
      _err "Manifiesto: fila duplicada '$artefacto' (exit 2)"
      exit 2
    fi
    SEEN_IDS["$artefacto"]=1
    MANIFEST_ROWS+=("${artefacto}	${clase}	${path_canonico}	${expected_mode}	${verificaciones}")
  done < "$MANIFEST"

  [ "${#MANIFEST_ROWS[@]}" -gt 0 ] || { _err "Manifiesto vacío"; exit 2; }
  # Modo paquete: el mapa debe CUBRIR todas las filas IDENTICO del manifiesto (fail-closed, exit 2).
  if [ "$CANON_MODE" = paquete ]; then
    local mrow m_art m_cl m_path
    for mrow in "${MANIFEST_ROWS[@]}"; do
      IFS=$'\t' read -r m_art m_cl m_path _ _ <<< "$mrow"
      [ "$m_cl" = IDENTICO ] || continue
      canon_map_lookup "$m_path" >/dev/null || { _err "canon-paquete.tsv no cubre el IDENTICO '$m_art' ($m_path) — mapa incompleto (exit 2)"; exit 2; }
    done
  fi

  # ── BLOQUE 1: Artefactos ──────────────────────────────────────────────────────────────
  printf '=== BLOQUE 1: Artefactos del manifiesto ===\n'
  local row
  for row in "${MANIFEST_ROWS[@]}"; do
    IFS=$'\t' read -r artefacto clase path_canonico expected_mode verificaciones <<< "$row"
    case "$clase" in
    IDENTICO)
      verificar_identico "$artefacto" "$path_canonico" "$expected_mode" "$verificaciones"
      ;;
    EQUIVALENTE)
      # tokens: estructura:<id>
      local IFS_bak="$IFS"
      IFS='|'; local toks; read -ra toks <<< "$verificaciones"; IFS="$IFS_bak"
      local tok
      for tok in "${toks[@]}"; do
        case "$tok" in estructura:*) verificar_equivalente "$artefacto" "$path_canonico" "${tok#estructura:}" ;; esac
      done
      ;;
    ENTORNO)
      local IFS_bak2="$IFS"
      IFS='|'; local toks2; read -ra toks2 <<< "$verificaciones"; IFS="$IFS_bak2"
      local tok2
      for tok2 in "${toks2[@]}"; do
        case "$tok2" in entorno:*) verificar_entorno "$artefacto" "$path_canonico" "${tok2#entorno:}" ;; esac
      done
      ;;
    esac
  done

  # ── BLOQUE 2: A2 ─────────────────────────────────────────────────────────────────────
  printf '\n=== BLOQUE 2: A2 — Branch protection ===\n'
  bloque_a2

  # ── BLOQUE 3: A2b ────────────────────────────────────────────────────────────────────
  printf '\n=== BLOQUE 3: A2b — Repo settings ===\n'
  bloque_a2b

  # ── BLOQUE 4: Magic word ─────────────────────────────────────────────────────────────
  printf '\n=== BLOQUE 4: Magic word (key=%s) ===\n' "$LINEAR_KEY"
  bloque_magic_word

  # ── BLOQUE 5: Receipts ───────────────────────────────────────────────────────────────
  printf '\n=== BLOQUE 5: Receipts MANUAL ===\n'
  bloque_receipts

  # ── Resultado final ───────────────────────────────────────────────────────────────────
  local frc; frc="$(final_rc)"
  printf '\n'
  case "$frc" in
  0) _ok  "PARIDAD OK — todos los checks DUROS pasan, CERO manual-pending." ;;
  1) _fail "PARIDAD FAIL — uno o más artefactos no pasan el contrato." ;;
  2) _err  "ERROR — manifiesto/dep/API. Ver mensajes anteriores." ;;
  3) _ok  "PARIDAD DURA OK — $PENDING_COUNT check(s) MANUAL pendiente(s). Proveer receipts para exit 0." ;;
  esac
  exit "$frc"
}

main "$@"
