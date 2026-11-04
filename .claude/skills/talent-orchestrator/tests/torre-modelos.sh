#!/usr/bin/env bash
# Resume real aislado: Opus del CEO, Sonnet del resto y retirada tardía.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/copia/talent-orchestrator" "$T/copia/talent-channel-operation" "$T/copia/talent-context/scripts" "$T/bin" "$T/repo" "$T/projects"
cp -R "$HERE/../scripts" "$T/copia/talent-orchestrator/scripts"
cp -R "$HERE/../../talent-channel-operation/scripts" "$T/copia/talent-channel-operation/scripts"
export HOST_HOME="$T/home" TORC_HOST_ENV="$T/neutral.conf" TORRE_CLAUDE_PROJECTS="$T/projects" TCO_MODELOS_REGISTRO="$T/modelos.conf" TOWER_LOG="$T/tmux.log"
: > "$TORC_HOST_ENV"
slug="$(printf '%s' "$T/repo" | sed -E 's/[\/._]/-/g')"; mkdir -p "$TORRE_CLAUDE_PROJECTS/$slug"
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TOWER_LOG"
if [ "$1" = new-session ] && [ "$STATE" = tmux-tardio ]; then rm -f "$TCO_MODELOS_REGISTRO"; fi
[ "$1" != has-session ]
EOF
cat > "$T/copia/talent-context/scripts/install-statusline.sh" <<'EOF'
#!/usr/bin/env bash
case "$STATE" in tardio) rm -f "$TCO_MODELOS_REGISTRO" ;; invalido-tardio) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;; esac
exit 0
EOF
chmod +x "$T/bin/tmux"; export PATH="$T/bin:$PATH"
pass=0; fail=0
for STATE in valido ausente invalido tardio invalido-tardio tmux-tardio; do
  export STATE
  for role in ceo coordinador merge otro orquestador ceo-implicito; do
    unset TCO_TORRE_ROL
    case "$role" in otro|ceo-implicito) : ;; *) export TCO_TORRE_ROL="$role" ;; esac
    actor="$role"; [ "$role" != ceo-implicito ] || actor=ceo
    rm -f "$TCO_MODELOS_REGISTRO"; : > "$TOWER_LOG"
    case "$STATE" in
      ausente) : ;;
      invalido) echo INVALIDO > "$TCO_MODELOS_REGISTRO" ;;
      *) printf 'OPUS_MODEL="claude-%s-%s"\nSONNET_MODEL="claude-%s-%s"\nRESOLVED_UTC="2026-10-04T00:00:00Z"\nCLI_VERSION="2.1.289"\n' opus 6.2 sonnet 6.2 > "$TCO_MODELOS_REGISTRO" ;;
    esac
    rc=0
    bash "$T/copia/talent-orchestrator/scripts/torre-resume.sh" "$actor" --cwd "$T/repo" --uuid 00000000-0000-4000-8000-000000000001 > "$T/out" 2>&1 || rc=$?
    family=sonnet; case "$role" in ceo|ceo-implicito) family=opus ;; esac
    good=0
    if [ "$STATE" = valido ]; then
      [ "$rc" = 0 ] && grep -Fq -- "--model claude-$family-6.2" "$TOWER_LOG" && good=1
    else
      [ "$rc" != 0 ] && ! grep -q 'claude --dangerously' "$TOWER_LOG" && grep -q 'resolver-modelos.sh' "$T/out" && good=1
    fi
    if [ "$good" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL torre $role $STATE rc=$rc"; fi
  done
done
printf 'RESULTADO torre PASS=%s FAIL=%s TOTAL=36\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$pass" = 36 ]
