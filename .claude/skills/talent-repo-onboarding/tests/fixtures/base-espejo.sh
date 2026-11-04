#!/usr/bin/env bash
# base-espejo.sh — Constructor del repo espejo VÁLIDO para fixtures de test.
# Se sourcea desde cada fixture (.fixture.sh); el fixture luego muta el espejo
# para el caso negativo antes de llamar a run_check.
#
# Variables exportadas al fixture:
#   ESPEJO_DIR        Directorio raíz del repo sintético
#   ESPEJO_RECEIPTS   Directorio con receipts JSON para los 7 checks
#   ESPEJO_ATTEST     Directorio con stubs de atestación
#   ESPEJO_PROTECTION Archivo JSON del stub de branch protection (A2)
#   ESPEJO_REPO_JSON  Archivo JSON del stub de repo settings (A2b)
#   CANON_MODE        paquete (DEFECTO si el skill vive en un árbol de paquete: el canon sale del propio ZIP,
#                     vía assets/canon-paquete.tsv) | git (override: `git show` sobre CANON_DIR)
#   CANON_PKG_DIR     Raíz del paquete de fábrica (modo paquete)
#   CANON_DIR         Repo canónico (modo git; TA repo real)
#   CANON_REF         Ref del canónico en modo git (HEAD por defecto)
#   AUTH_UID          user.id autorizado para receipts
#   TEST_SLUG         owner/repo del repo espejo (ficticio)
#   CHECKER           Path absoluto al verify-repo-parity.sh

set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$SKILL_ROOT/scripts/verify-repo-parity.sh"
CANON_DIR="${CANON_DIR:-$(cd "$SKILL_ROOT/../.." && pwd)}"
CANON_REF="${CANON_REF:-HEAD}"
# TAL-8037: sin override explícito, si el skill vive en un árbol de PAQUETE el canon es el propio paquete.
CANON_MAP_FILE="$SKILL_ROOT/assets/canon-paquete.tsv"
if [ -z "${CANON_MODE:-}" ]; then
  CANON_MODE=git
  _pkg="$(cd "$SKILL_ROOT/../.." && pwd)"
  if [ -f "$_pkg/githooks/pre-push" ] && [ -f "$_pkg/scripts/verify-handoff.sh" ]; then CANON_MODE=paquete; CANON_PKG_DIR="$_pkg"; fi
fi
LINEAR_KEY_TEST="ABC"   # clave del team del arnés (C2: ≠ TAL)
AUTH_UID="${AUTH_UID:-99999999}"
TEST_SLUG="${TEST_SLUG:-test/espejo}"

# sha256 portátil (Linux: sha256sum, macOS: shasum -a 256)
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# iso timestamp portátil
_iso_ts() {
  local epoch="$1"
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

# Inicializar dirs temporales
ESPEJO_DIR="$(mktemp -d)"
ESPEJO_RECEIPTS="$(mktemp -d)"
ESPEJO_ATTEST="$(mktemp -d)"
ESPEJO_PROTECTION="$(mktemp).json"
ESPEJO_REPO_JSON="$(mktemp).json"

cleanup_espejo() {
  rm -rf "$ESPEJO_DIR" "$ESPEJO_RECEIPTS" "$ESPEJO_ATTEST" \
         "$ESPEJO_PROTECTION" "$ESPEJO_REPO_JSON"
}
# El fixture registra el trap
trap cleanup_espejo EXIT

# ─── Inicializar git repo espejo ────────────────────────────────────────────
git -C "$ESPEJO_DIR" init -q
git -C "$ESPEJO_DIR" config user.name "test"
git -C "$ESPEJO_DIR" config user.email "test@test.local"

# ─── Copiar IDÉNTICOS desde el canónico ─────────────────────────────────────
_canon_rel() { awk -F'\t' -v p="$1" '$0 !~ /^#/ && $1==p {print $2; exit}' "$CANON_MAP_FILE"; }   # producto → paquete
_copy_canon() {
  local path="$1" mode="${2:-100644}"
  local dest="$ESPEJO_DIR/$path"
  mkdir -p "$(dirname "$dest")"
  if [ "$CANON_MODE" = paquete ]; then
    cp -- "$CANON_PKG_DIR/$(_canon_rel "$path")" "$dest"
  else
    git -C "$CANON_DIR" show "${CANON_REF}:${path}" > "$dest"
  fi
  if [ "$mode" = "100755" ]; then chmod +x "$dest"; fi
}

_copy_canon ".githooks/pre-push"                    "100755"
_copy_canon "scripts/verify-handoff.sh"             "100755"
_copy_canon "scripts/cr-review.sh"                  "100755"
_copy_canon "scripts/audit-go.sh"                   "100755"
_copy_canon "scripts/check-push-audit.sh"           "100755"
_copy_canon "scripts/setup-githooks.sh"             "100755"
_copy_canon "docs/templates/handoff-pr-draft.md"    "100644"
_copy_canon "scripts/github/validar-rama-pr.sh"     "100755"
_copy_canon "scripts/lib/handoff.sh"                "100755"
_copy_canon "scripts/lib/cr-finding-normalize.jq"   "100644"

# ─── EQUIVALENTES ────────────────────────────────────────────────────────────
mkdir -p "$ESPEJO_DIR/scripts/github" "$ESPEJO_DIR/scripts/lib"

cat > "$ESPEJO_DIR/scripts/draft-handoff.sh" << 'DHDEOF'
#!/usr/bin/env bash
# Entrega draft: gates locales + sentinel (EQUIVALENTE)
bash scripts/github/validar-rama-pr.sh
npm run typecheck && npm run lint && npm run build
touch .claude/.draft-handoff
DHDEOF
chmod +x "$ESPEJO_DIR/scripts/draft-handoff.sh"

cat > "$ESPEJO_DIR/.coderabbit.yaml" << 'CRYAML'
language: "es"
reviews:
  profile: "chill"
  request_changes_workflow: true
  auto_review:
    enabled: true
    drafts: false
CRYAML

cat > "$ESPEJO_DIR/CLAUDE.md" << 'CLDEOF'
# CLAUDE.md
Reglas de la fábrica: usar draft-handoff, gate local-gates, cr-review y coderabbit.
CLDEOF

cat > "$ESPEJO_DIR/AGENTS.md" << 'AGEOF'
# AGENTS.md
Reglas: draft-handoff obligatorio, local-gates, coderabbit para review bloqueante.
AGEOF

mkdir -p "$ESPEJO_DIR/.github"
cat > "$ESPEJO_DIR/.github/PULL_REQUEST_TEMPLATE.md" << 'PRTEOF'
## Descripción

Closes ABC-N
PRTEOF

cat > "$ESPEJO_DIR/.gitignore" << 'GIEOF'
.env.local
.claude/.cr-review-ok
.claude/.draft-handoff
.claude/.audit-go
.claude/tf-manifest.conf
.claude/.motor-go
.claude/.cr-review-*
GIEOF

mkdir -p "$ESPEJO_DIR/.claude/hooks"
cat > "$ESPEJO_DIR/.claude/settings.json" << 'STEOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "bash .claude/hooks/check-skill.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash scripts/check-push-audit.sh"}]}
    ]
  }
}
STEOF

cat > "$ESPEJO_DIR/.claude/hooks/check-skill.sh" << 'CSEOF'
#!/usr/bin/env bash
file_path="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$file_path" ] && exit 0
exit 0
CSEOF
chmod +x "$ESPEJO_DIR/.claude/hooks/check-skill.sh"

# ─── ENTORNO ─────────────────────────────────────────────────────────────────
git -C "$ESPEJO_DIR" config core.hooksPath .githooks
mkdir -p "$ESPEJO_DIR/.claude/skills/talent-issue-craft"
touch "$ESPEJO_DIR/.claude/skills/talent-issue-craft/SKILL.md"
mkdir -p "$ESPEJO_DIR/docs/reference"
cat > "$ESPEJO_DIR/docs/reference/issue-craft-perfil-espejo.md" << 'PREOF'
# Perfil issue-craft — repo espejo
PREOF

# ─── Commit inicial ───────────────────────────────────────────────────────────
git -C "$ESPEJO_DIR" add -A
git -C "$ESPEJO_DIR" commit -q -m "espejo-base"

# ─── Stubs de API ────────────────────────────────────────────────────────────
cat > "$ESPEJO_PROTECTION" << 'PJSON'
{
  "required_status_checks": {
    "checks": [{"context": "local-gates"}],
    "strict": true
  },
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": {"enabled": true},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "block_creations": {"enabled": false},
  "required_conversation_resolution": {"enabled": true}
}
PJSON

cat > "$ESPEJO_REPO_JSON" << 'RJSON'
{
  "allow_squash_merge": true,
  "allow_merge_commit": true,
  "allow_rebase_merge": true,
  "delete_branch_on_merge": false
}
RJSON

# ─── Receipts válidos para los 7 checks ─────────────────────────────────────
# Convención: comment_id = 1001+N (índice del check en CHECK_IDS)
if [ "$CANON_MODE" = paquete ]; then
  CANON_SHA_TEST="paquete"
else
  CANON_SHA_TEST="$(git -C "$CANON_DIR" rev-parse "$CANON_REF" 2>/dev/null || printf 'deadbeef0000000000000000000000000000000000')"
fi

_make_valid_receipt() {
  local check_id="$1"
  local comment_id="$2"
  local extra_evid="$3"   # JSON extra fields además de attest_comment_id

  local now issued expires
  now="$(date +%s)"
  issued="$(_iso_ts "$now")"
  expires="$(_iso_ts "$(( now + 604800 ))")"

  # Construir evidencia completa
  local evidencia
  evidencia="$(printf '%s' "$extra_evid" | jq --argjson atid "$comment_id" \
    '. + {attest_comment_id: $atid}')"

  # Construir receipt
  local receipt
  receipt="$(jq -n \
    --arg cid "$check_id" \
    --arg repo "$TEST_SLUG" \
    --arg sha_p "abc1234567890123456789012345678901234" \
    --arg sha_c "$CANON_SHA_TEST" \
    --arg actor "test-user" \
    --arg issued "$issued" \
    --arg expires "$expires" \
    --argjson evid "$evidencia" \
    '{
      receipt_version: "1",
      check_id: $cid,
      repo: $repo,
      branch: "main",
      sha_probado: $sha_p,
      sha_canonico: $sha_c,
      actor: $actor,
      issued_at: $issued,
      expires_at: $expires,
      evidencia: $evid
    }')"

  printf '%s' "$receipt" > "$ESPEJO_RECEIPTS/${check_id}.json"

  # Calcular evidencia_sha256 = sha256(jq -S -c .evidencia)
  local evid_canon evid_hash
  evid_canon="$(printf '%s' "$receipt" | jq -S -c '.evidencia')"
  evid_hash="$(printf '%s' "$evid_canon" | _sha256)"

  # Construir binding (primera línea del comentario)
  local binding
  binding="attest v1 check_id=${check_id} repo=${TEST_SLUG} branch=main sha_probado=abc1234567890123456789012345678901234 sha_canonico=${CANON_SHA_TEST} actor=${AUTH_UID} evidencia_sha256=${evid_hash}"

  # Stub del comentario
  jq -n \
    --argjson uid "$AUTH_UID" \
    --arg body "$binding" \
    '{user: {id: $uid, login: "test-user"}, body: $body}' \
    > "$ESPEJO_ATTEST/${comment_id}.json"
}

_make_valid_receipt "linear-integration"        "1001" '{"pr_url":"https://github.com/test/espejo/pull/1","issue_id":"TST-1"}'
_make_valid_receipt "cr-app-instalada"          "1002" '{"pr_url":"https://github.com/test/espejo/pull/1","review_id":"rev001"}'
_make_valid_receipt "cr-app-draft-silencio"     "1003" '{"pr_url":"https://github.com/test/espejo/pull/1"}'
_make_valid_receipt "push-sentinel-block"       "1004" '{"commit_sha":"abc1234","branch":"main"}'
_make_valid_receipt "audit-issue-maquina-limpia" "1005" '{"issue_id":"TST-2","salida_sha256":"abc000"}'
_make_valid_receipt "ensayo-e2e"                "1006" '{"pr_url":"https://github.com/test/espejo/pull/2","status_context":"local-gates","issue_id":"TST-3"}'
_make_valid_receipt "accesos-y-deploy"          "1007" '{"smoke_urls_codes":"200","anexo_ref":"onboarding-anexo-espejo.md"}'

# Entorno del canon y de la clave Linear, EXPORTADO para todo el fixture (run_check y los fixtures que invocan el checker
# a mano): modo paquete → TRO_CANON_PACKAGE_DIR; modo git → TRO_CANON_REPO_DIR/REF (override). Clave de la instancia: ABC.
if [ "$CANON_MODE" = paquete ]; then
  export TRO_CANON_PACKAGE_DIR="$CANON_PKG_DIR"; unset TRO_CANON_REPO_DIR
else
  export TRO_CANON_REPO_DIR="$CANON_DIR" TRO_CANON_REF="$CANON_REF"
fi
export TF_LINEAR_TEAM_KEY="$LINEAR_KEY_TEST"

# ─── run_check: ejecutar el checker y verificar el exit code esperado ─────────
run_check() {
  local expected="$1"
  local actual=0
  # `|| actual=$?` captura el exit code bajo `set -e` sin disparar el exit temprano
  TRO_REPO_SLUG="$TEST_SLUG" \
  TRO_PROTECTION_JSON="$ESPEJO_PROTECTION" \
  TRO_REPO_JSON="$ESPEJO_REPO_JSON" \
  TRO_RECEIPTS_DIR="$ESPEJO_RECEIPTS" \
  TRO_ATTEST_DIR="$ESPEJO_ATTEST" \
  TRO_RECEIPT_AUTHORITIES="$AUTH_UID" \
    bash "$CHECKER" "$ESPEJO_DIR" > /dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf 'PASS: exit=%d (esperado=%d)\n' "$actual" "$expected"
    return 0
  else
    printf 'FAIL: exit=%d (esperado=%d)\n' "$actual" "$expected"
    return 1
  fi
}

# espejo_commit: re-commit los cambios del fixture al índice del espejo
espejo_commit() {
  git -C "$ESPEJO_DIR" add -A 2>/dev/null || true
  git -C "$ESPEJO_DIR" commit -q -m "fixture-mutation" --allow-empty 2>/dev/null || true
}
