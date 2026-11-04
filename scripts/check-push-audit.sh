#!/usr/bin/env bash
# Hook PreToolUse Bash — Gate 1 del push. Permite `git push` si hay un GO vigente
# para el HEAD actual por UNA de dos rutas (TAL-2288, Fábrica v2 decisión 4 del CEO):
#   a) ENTREGA DRAFT: `.claude/.draft-handoff` (línea 1 == HEAD) — lo emite
#      draft-handoff.sh TRAS el GO de código del auditor + gates locales verdes.
#      NO se consume aquí: el consumo one-shot pertenece a .githooks/pre-push,
#      que valida los OIDs REALES del push y lo quema solo si TODAS las refs
#      validaron. Aceptarlo elimina el DOBLE SENTINEL que atascaba a los canales.
#   b) FLUJO CLÁSICO (fallback, fuera del sistema de canales): `.claude/.audit-go`
#      matching HEAD (lo emite scripts/audit-go.sh tras el GO del lead). Refuerza
#      regla 9 de CLAUDE.md + memoria feedback_pre_push_audit_stop REINFORCED 3x.
#
# Sentinel format (primera línea = SHA autorizado):
#   <sha>
#   <branch>
#   <timestamp ISO 8601>
#
# `.audit-go` es one-shot: se CONSUME (delete) tras allow para evitar reuse
# en pushes subsequentes. Cada push individual requiere su propio GO+sentinel.
#
# Defense-in-depth contra bypass via comandos compuestos (Cubic P1 PR #107):
# rechaza CUALQUIER comando compuesto que contenga `git push`. Razón: en
# comandos como `git commit --amend && git push`, los pasos previos al
# push REAL pueden cambiar HEAD entre el check del hook y la ejecución
# real, bypaseando el sentinel SHA check (autoriza un SHA, push envía otro).
# Solo se permite `git push [args...]` como comando ATÓMICO standalone.
#
# Hook input via stdin: JSON {tool_name, tool_input: {command, ...}}
# Hook output: JSON con hookSpecificOutput.permissionDecision (allow|deny)
set -euo pipefail

input="$(cat)"
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

# TAL-2288 (barrido de la clase de sentinels): `git -C <dir> push`, `git --git-dir=… push`
# y demás formas con OPCIONES GLOBALES entre `git` y `push` NO matchean el patrón atómico
# de abajo (hay palabras alfanuméricas en medio) y saltarían este gate ENTERO. Si la
# primera palabra es `git`, la segunda no es `push` y alguna palabra posterior sí lo es,
# se deniega: el push debe invocarse como `git push …` atómico desde el repo (cd aparte).
read -ra w0 <<< "$cmd" || true
# TAL-2288 (barrido reforzado — CR crítico): localizar `git` en CUALQUIER posición, no solo w0[0].
# La forma w0[0]=="git" dejaba pasar wrappers que anteponen palabras a git —`sudo git …`,
# `env git …`, `command git …`, `sudo -u x git …`— porque su primer token no es `git` y el grep
# de abajo tampoco casa (hay alfanuméricos -C, dir… entre git y push). Se busca el PRIMER token
# `git` exacto; si la palabra siguiente NO es `push` pero alguna posterior sí lo es, es la forma
# con opciones globales (-C, --git-dir, …) tras un wrapper → esquiva el patrón atómico → DENY.
gidx=-1
for i in "${!w0[@]}"; do
  if [ "${w0[$i]}" = "git" ]; then gidx=$i; break; fi
done
if [ "$gidx" -ge 0 ] && [ "${w0[$((gidx+1))]:-}" != "push" ]; then
  for tok in "${w0[@]:$((gidx+1))}"; do
    if [ "$tok" = "push" ]; then
      jq -nc '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "git push bloqueado: opciones globales entre git y push (-C, --git-dir, --work-tree, -c, …) o wrappers antes de git (sudo, env, command, …) PROHIBIDOS — esas formas esquivaban el patrón del gate (clase sentinel-bypass, TAL-2288). Ejecuta `git push [args]` como comando atómico desde el directorio del repo (haz el cd en una invocación separada). Si tu comando no era un push real (p.ej. `git log --grep push`), reformúlalo sin la palabra suelta push."
        }
      }'
      exit 0
    fi
  done
fi

# Pass-through si el comando no contiene `git push`. Boundary char class
# usa `[^A-Za-z0-9_]` (cualquier no-alphanumeric/underscore) para que
# matchee separators NO clásicos: paréntesis `(git push)`, sin-espacio
# `git push&&foo`, quotes `'git' 'push'`, etc. (Cubic P1 round 2 PR #107).
# Mismo separator entre git y push para cubrir `'git' 'push'` quote-split.
# Mantiene boundary check: "git pushPull" o "gitpush" NO matchean.
if ! echo "$cmd" | grep -qE '(^|[^A-Za-z0-9_])git[^A-Za-z0-9_]+push([^A-Za-z0-9_]|$)'; then
  exit 0
fi

# Anti-bypass: rechazar comandos compuestos que contienen git push (Cubic
# P1 PR #107 + round 2). Detecta metacaracteres shell:
#   ; && || | &     → chain operators (compound execution)
#   ( )             → subshell grouping (Cubic round 2: `(git push)`)
#   ` $(...)        → subshell substitution (can mutate HEAD silently)
#   < > >> <<       → redirections (can mutate files including .git/HEAD)
#   newline         → multi-line commands (compound via \n)
# Razón: pasos previos a git push en compound pueden cambiar HEAD entre
# check del hook y push real → bypass sentinel SHA check.
if printf '%s' "$cmd" | grep -qE '[;&|`<>()]|\$\(' || [[ "$cmd" == *$'\n'* ]]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "git push bloqueado: comandos compuestos prohibidos (Cubic P1 fix). Detectado uno o más de: ; && || | & ( ) ` $(...) < > newline. Razón: pasos previos a git push pueden cambiar HEAD entre el check del hook y la ejecución real del push, bypaseando el sentinel SHA check (autoriza un SHA, push envía otro). Ejecuta git push como comando ATÓMICO standalone, sin otros comandos antes/después. Si necesitas correr audit-go.sh antes, hazlo en una invocación bash separada."
    }
  }'
  exit 0
fi

# Defense extra: parse primera palabra. Comando debe empezar con `git push`
# (no wrappers como `bash`, `env`, `sudo`, `xargs`, etc.).
read -ra words <<< "$cmd" || true
if [ "${words[0]:-}" != "git" ] || [ "${words[1]:-}" != "push" ]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "git push bloqueado: comando debe empezar exactamente con `git push`. Detectado prefix distinto (e.g., `bash`, `env`, `sudo`, otro wrapper). Ejecuta git push directo sin wrappers."
    }
  }'
  exit 0
fi

sentinel=".claude/.audit-go"
head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
branch=$(git branch --show-current 2>/dev/null || echo "detached")
branch="${branch:-detached}"

if [ -z "$head_sha" ]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "git push bloqueado: no estás en un repo git (rev-parse HEAD falló)."
    }
  }'
  exit 0
fi

# >>> TAL-2288 (Fábrica v2, decisión 4 del CEO): el sentinel de ENTREGA DRAFT vigente
# equivale al GO. NO se consume aquí — el consumo one-shot es del Gate 2
# (.githooks/pre-push) tras validar el push completo. Draft stale/ausente cae a la
# ruta clásica .audit-go y se informa su estado en los deny para diagnóstico.
draft_sentinel=".claude/.draft-handoff"
draft_state="no existe (ruta draft no emitida)"
if [ -f "$draft_sentinel" ]; then
  draft_sha=$(head -n1 "$draft_sentinel" | tr -d '[:space:]')
  if [ -n "$draft_sha" ] && [ "$draft_sha" = "$head_sha" ]; then
    jq -nc --arg sha "$head_sha" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: ("Gate 1 satisfecho por entrega DRAFT (Fábrica v2): .claude/.draft-handoff vigente para HEAD " + $sha + " (emitido por draft-handoff.sh tras GO de código + gates locales verdes). NO consumido aquí: lo consume .githooks/pre-push al validar el push completo (OID+ref). Flujo clásico: scripts/audit-go.sh sigue disponible como fallback.")
      }
    }'
    exit 0
  fi
  draft_state="STALE — autoriza ${draft_sha:-vacío} pero HEAD es $head_sha (re-ejecuta 'bash scripts/draft-handoff.sh')"
fi
# <<< TAL-2288

if [ ! -f "$sentinel" ]; then
  jq -nc --arg sha "$head_sha" --arg branch "$branch" --arg draft "$draft_state" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("STOP audit pre-push obligatorio (Gate 1; memoria feedback_pre_push_audit_stop REINFORCED 3x). Ruta DRAFT (canal de producción, Fábrica v2): `bash scripts/draft-handoff.sh` emite .claude/.draft-handoff, que este Gate 1 acepta como GO equivalente — estado actual: " + $draft + ". Ruta clásica (fallback): sentinel .claude/.audit-go — estado: NO EXISTE. Push pedido desde rama " + $branch + " @ HEAD " + $sha + ". Pasos exactos ruta clásica: 1) Presentar el informe STOP-AUDIT con evidencia (typecheck+lint+build+tests relevantes + git diff main..HEAD) declarando ese SHA. 2) Esperar el GO de código explícito del auditor del canal (Fábrica v2) o del lead (flujo clásico). 3) Tras el GO, ejecutar `bash scripts/audit-go.sh` para autorizar el push del SHA " + $sha + ". El sentinel audit-go es one-shot (se consume tras el allow); commit nuevo antes del push = re-emitir el sentinel de tu ruta. Aviso: superado este Gate 1, el push pasa además por el Gate 2 (.githooks/pre-push), que ata OID+ref y consume el draft.")
    }
  }'
  exit 0
fi

sentinel_sha=$(head -n1 "$sentinel" | tr -d '[:space:]')
if [ "$sentinel_sha" != "$head_sha" ]; then
  # Diagnóstico accionable (TAL-2277): exponer rama (L2) y timestamp (L3) del sentinel
  # + nº de commits nuevos desde el SHA autorizado (guarded: el SHA podría no existir local).
  sentinel_branch=$(sed -n '2p' "$sentinel" 2>/dev/null || true)
  sentinel_ts=$(sed -n '3p' "$sentinel" 2>/dev/null || true)
  new_commits="?"
  if [ -n "$sentinel_sha" ]; then
    new_commits=$(git rev-list --count "${sentinel_sha}..HEAD" 2>/dev/null || echo "?")
  fi
  jq -nc --arg auth "${sentinel_sha:-vacío}" --arg head "$head_sha" --arg branch "$branch" \
         --arg sbranch "${sentinel_branch:-?}" --arg sts "${sentinel_ts:-?}" --arg n "$new_commits" --arg draft "$draft_state" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("STOP audit pre-push obligatorio (Gate 1). Estado del sentinel .claude/.audit-go: STALE — autoriza SHA " + $auth + " (emitido en rama " + $sbranch + " @ " + $sts + ") pero HEAD actual es " + $head + " (rama " + $branch + "): " + $n + " commit(s) nuevos post-autorización. Ruta DRAFT (Fábrica v2, aceptada por este gate): " + $draft + ". El GO no se hereda entre commits. Pasos exactos ruta clásica: 1) Re-presentar el informe STOP-AUDIT sobre el HEAD nuevo. 2) Re-pedir GO de código explícito (auditor del canal en Fábrica v2 / lead en flujo clásico). 3) Re-ejecutar `bash scripts/audit-go.sh`. NO bypass — la regla aplica a TODO push independientemente de autorizaciones previas.")
    }
  }'
  exit 0
fi

# OK: sentinel matchea HEAD. Consumir (delete) para garantizar one-shot.
rm -f "$sentinel"
jq -nc --arg sha "$head_sha" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("audit-go sentinel matched SHA " + $sha + ". Sentinel consumido (one-shot). Próximo push requerirá nuevo GO + audit-go.sh.")
  }
}'
