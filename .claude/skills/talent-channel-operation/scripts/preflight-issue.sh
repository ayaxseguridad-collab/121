#!/usr/bin/env bash
# preflight-issue.sh — [B4] Gate OBLIGATORIO antes de despachar cualquier issue (regla 24).
# Verifica: (1) BD prod 100% sync con main; (2) el carril en 'main', working tree limpio y al día;
# (3) [TAL-2275] el ESTADO Linear del issue objetivo NO es terminal/en-review (gotcha TAL-1178:
#     el resume/compact rehidrata intenciones muertas — no re-despachar un issue Done/Canceled/In Review).
# Sale 0 = OK para arrancar; 1 = ESCALAR (no arrancar). Verify-only por defecto (NO aplica nada).
# [TAL-2276] EXCEPCIÓN opt-in: con el flag `--force-reset-git` (solo lo pasa dispatch --force-reset)
# resetea el git del carril a origin/main ENTRE el gate (1) y el (2) — SOLO si (1) quedó en verde
# (orden fail-closed: no se muta el carril si la BD no está sync). Sin ese flag, comportamiento idéntico.
# Uso: preflight-issue.sh <carril> [<TAL-id>] [--force-reset-git]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

CARRIL="${1:?uso: preflight-issue.sh <carril> [<TAL-id>] [--force-reset-git]}"
shift
# Args opcionales combinables (orden indiferente):
#   [TAL-2275] <TAL-id> posicional: si se pasa, se verifica su estado Linear (gate 3, gotcha TAL-1178).
#   [TAL-2276] --force-reset-git flag: resetea el git del carril a origin/main pre-preflight (solo dispatch --force-reset).
# Validación explícita: un flag desconocido o un 2º posicional es error de uso (fail-closed), jamás se ignora en silencio.
ISSUE=""
FORCE_RESET_GIT=""
for arg in "$@"; do
  case "$arg" in
    --force-reset-git) FORCE_RESET_GIT="--force-reset-git" ;;
    --*) tco_err "preflight-issue.sh: flag desconocido: '$arg' (esperado: --force-reset-git)"; exit 2;;
    *) if [ -z "$ISSUE" ]; then ISSUE="$arg"; else tco_err "preflight-issue.sh: argumento posicional extra: '$arg' (uso: <carril> [<TAL-id>] [--force-reset-git])"; exit 2; fi ;;
  esac
done
tco_load_tokens

rc=0

# (1) BD prod 100% sync con main (ledger Management API vs migraciones del repo del coordinador)
tco_say "Gate BD sync (regla 24)"
# [TAL-8037] Sin default de casa: el checkout del repo en el host es IDENTIDAD de la instancia (:? fail-closed).
# Stack «ninguno» (sin backend gestionado): no hay BD prod que sincronizar — el gate no aplica (no es un verde por omisión:
# el stack lo adjudicó la instancia y 00-config.sh lo valida contra el enum).
if [ "$TCO_REPO_STACK" = ninguno ]; then
  tco_info "stack=ninguno: sin backend gestionado — gate BD sync (regla 24) no aplica"
else
REPO_ROOT="${TCO_HOST_REPO:-${TCO_HOST_REPO_ROOT:?preflight-issue.sh: define TCO_HOST_REPO (o TCO_HOST_REPO_ROOT) — checkout del repo en el host; sin default de casa}}"
if [ -d "$REPO_ROOT/.git" ] && [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  lm="$(mktemp)"; pm="$(mktemp)"   # mktemp, no /tmp/<fijo>.$$ (anti symlink/tamper)
  # [regla 24 — FAIL-CLOSED] si el fetch falla, origin/main queda STALE y compararíamos contra un
  # estado viejo: NO se puede declarar sync (el `|| true` previo era fail-OPEN). Ver
  # talent-merger/references/anexo-<proyecto>.md, PROC-M13 "Paso 5" (verificación
  # post-apply: fetch fresco de origin/main + fail-closed antes de declarar sync) — PROC-13
  # se trasladó ahí entero (Fábrica v2, ADR-0043; ver CHANGELOG de este skill).
  if ! ( cd "$REPO_ROOT" && git fetch origin main --quiet ) 2>/dev/null; then
    tco_err "git fetch origin main falló — NO declaro sync BD (fail-closed, regla 24) — ESCALAR"; rc=1
  else
    # migraciones de origin/main (el remoto), NO del working tree local que puede estar stale
    ( cd "$REPO_ROOT" && git ls-tree -r --name-only origin/main -- supabase/migrations 2>/dev/null ) \
      | grep -E '\.sql$' | sed -E 's#.*/([0-9]+)_.*#\1#' | sort > "$lm"
    # El token NO va en argv (legible vía /proc/<pid>/cmdline): viaja por un --config temporal 0600.
    cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'header = "Authorization: Bearer %s"\n' "$SUPABASE_ACCESS_TOKEN" > "$cfg"
    curl -s --connect-timeout "${TCO_LINEAR_CONNECT_TIMEOUT:-10}" --max-time "${TCO_LINEAR_MAX_TIME:-60}" \
      -K "$cfg" -H "Content-Type: application/json" \
      -X POST "https://api.supabase.com/v1/projects/$TCO_SUPABASE_REF/database/query" \
      -d '{"query":"select version from supabase_migrations.schema_migrations order by version"}' \
      | jq -r '.[].version' 2>/dev/null | sort > "$pm" || true
    rm -f "$cfg"
    if ! [ -s "$lm" ]; then tco_err "no pude listar migraciones de origin/main — ESCALAR"; rc=1
    else
      # [regla 24 / talent-merger/references/anexo-<proyecto>.md, PROC-M13 "Paso 2"]
      # sync REAL = AMBAS direcciones vacías (comm -23 NO basta:
      # dos ledgers con mismo count y mismo máximo pueden divergir en versiones intermedias).
      gap="$(comm -23 "$lm" "$pm" 2>/dev/null || true)"   # en main y NO en prod (pendientes de aplicar)
      inv="$(comm -13 "$lm" "$pm" 2>/dev/null || true)"   # en prod y NO en main (divergencia grave)
      if [ -n "$gap" ]; then tco_err "GAP BD: migraciones en origin/main NO aplicadas a prod:"; printf '%s\n' "$gap" | sed 's/^/     /'; rc=1; fi
      if [ -n "$inv" ]; then tco_err "DIVERGENCIA BD: versiones en prod AUSENTES de origin/main (el ledger divergió por otra vía) — ESCALAR:"; printf '%s\n' "$inv" | sed 's/^/     /'; rc=1; fi
      [ -z "$gap" ] && [ -z "$inv" ] && tco_info "✅ prod 100% sync con origin/main (ambas direcciones)"
    fi
    rm -f "$lm" "$pm"
  fi
else
  tco_info "(no se pudo verificar BD sync: falta token o repo .git) — ESCALAR"; rc=1
fi
fi

# [TAL-2276] --force-reset: limpiar git del carril a origin/main SOLO tras el gate BD-sync en verde.
# Orden fail-closed: si la BD no está 100% sync (rc!=0), NO se toca el carril (se escala sin mutar);
# así el reset destructivo va SIEMPRE después de la garantía de sync de prod (regla 24).
if [ "$FORCE_RESET_GIT" = --force-reset-git ]; then
  if [ "$rc" -eq 0 ]; then
    tco_say "--force-reset: git del carril $CARRIL -> origin/main (tras gate BD-sync verde, pre-gate git)"
    tco_reset_repo_to_main "$CARRIL" \
      || { tco_err "$CARRIL: reset a origin/main FALLÓ (fetch/red/exec) — ESCALAR"; rc=1; }
  else
    tco_err "$CARRIL: gate BD-sync en ROJO -> NO reseteo git del carril (fail-closed: no mutar si la BD no está sync)"
  fi
fi

# (2) Carril en main, limpio y REALMENTE al día con origin/main (Mayor 2: no ignorar fallo de pull)
tco_say "Gate git del carril $CARRIL"
c="$(tco_container "$CARRIL")"; rp="$(tco_repo_path)"
st1="$(incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git fetch origin --quiet && git status --porcelain=2 --branch 2>/dev/null" 2>/dev/null || echo FAIL)"
if ! printf '%s' "$st1" | grep -q '^# branch.head main'; then
  tco_err "$CARRIL no está en 'main' — ESCALAR"; rc=1
elif printf '%s' "$st1" | grep -qE '^[12u] '; then
  tco_err "$CARRIL con working tree sucio (cambios sin commitear) — ESCALAR"
  # [M6] el reciclaje no toca git: reportar QUÉ está sucio + el comando EXACTO de arreglo (no solo 'escala').
  printf '%s' "$st1" | grep -E '^[12u] ' | sed -E 's/^/       /' | head -20 || true
  tco_info "arreglo (revísalo antes de ejecutar — DESTRUYE cambios locales del carril):"
  tco_info "  incus exec $c -- su - $TCO_CUSER -c \"cd '$rp' && git reset --hard origin/main && git clean -fd\""
  rc=1
elif ! incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git pull --rebase origin main" >/dev/null 2>&1; then
  tco_err "$CARRIL: 'git pull --rebase' falló (conflicto/red) — ESCALAR"; rc=1
else
  ab="$(incus exec "$c" -- su - "$TCO_CUSER" -c "cd '$rp' && git status --porcelain=2 --branch 2>/dev/null" 2>/dev/null | grep '^# branch.ab' || echo '?')"
  if printf '%s' "$ab" | grep -qE 'branch\.ab \+0 -0'; then
    tco_info "✅ $CARRIL en main, limpio y al día con origin/main"
  else
    tco_err "$CARRIL no quedó sincronizado con origin/main ($ab) — ESCALAR"; rc=1
  fi
fi

# (3) [TAL-2275] Estado Linear del issue objetivo — gotcha TAL-1178: tras `claude --resume`/compact el
# TaskList del harness rehidrata intenciones muertas (mostró TAL-1178 in_progress cuando estaba Done y
# mergeado; casi se re-despacha). El TaskList NO es fuente de verdad; Linear sí. Abortar si el issue ya
# está en un estado no-dispatchable (Done/Canceled/Duplicate/In Review). Fail-closed: si no se resuelve
# el estado (token/red), ESCALAR — no se despacha sobre estado desconocido.
run_gate=no
if [ -z "$ISSUE" ]; then
  tco_info "(sin <TAL-id>: salto el gate (3) de estado Linear — solo checks de carril/BD)"
elif [ "${TCO_SMOKE_MODE:-}" = yes ]; then
  tco_info "(TCO_SMOKE_MODE=yes: salto el gate (3) de estado Linear para $ISSUE)"
else
  # [GO-code] el escape hatch desactiva SOLO con el literal 'no'; un valor desconocido (typo tipo
  # 'false'/'off') NO debe apagar un gate de seguridad en silencio → aviso y mantengo el gate ACTIVO.
  case "${TCO_PREFLIGHT_REQUIRE_LINEAR_STATE:-yes}" in
    yes) run_gate=yes ;;
    no)  tco_info "(TCO_PREFLIGHT_REQUIRE_LINEAR_STATE=no: gate (3) de estado Linear DESACTIVADO para $ISSUE)" ;;
    *)   tco_err "TCO_PREFLIGHT_REQUIRE_LINEAR_STATE='${TCO_PREFLIGHT_REQUIRE_LINEAR_STATE}' no reconocido (usa yes|no) — mantengo el gate ACTIVO (fail-closed)"; run_gate=yes ;;
  esac
fi

if [ "$run_gate" = yes ]; then
  tco_say "Gate estado Linear de $ISSUE (gotcha TAL-1178)"
  st="$(tco_linear_issue_state_type "$ISSUE" 2>/dev/null)" || st=""   # "<type> <name>" | vacío si no resoluble
  if [ -z "$st" ]; then
    tco_err "$ISSUE: no pude resolver el estado en Linear (¿token/red?) — NO despacho sobre estado desconocido (fail-closed) — ESCALAR"; rc=1
  else
    typ="${st%% *}"; nm="${st#* }"
    if tco_dispatch_state_blocked "$typ" "$nm"; then
      tco_err "$ISSUE está en '$nm' (no-dispatchable): el TaskList rehidratado NO es fuente de verdad, Linear sí — NO se re-despacha un issue Done/Canceled/In Review (gotcha TAL-1178) — ESCALAR"; rc=1
    else
      tco_info "✅ $ISSUE en '$nm' (type=$typ) — dispatchable"
    fi
  fi
fi

# (4) [TAL-3266] Gate audit-issue + contrato HOLD/RELEASE/SIN-AUDIT — loop issue-craft en la 1ª estación.
# Patrón ESPEJO del gate (3): misma estructura run_gate/escape, mismo case de 3 ramas.
# Sin <TAL-id>: se salta igual que el gate (3) (preflight-issue.sh:118).
# Escape hatch: TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE — SOLO el literal 'no' desactiva;
#   typo (false/off/…) → aviso + gate ACTIVO (no apagar seguridad por un typo, igual que gate (3)).
run_gate=no
if [ -z "$ISSUE" ]; then
  tco_info "(sin <TAL-id>: salto el gate (4) de audit-issue+control — solo checks de carril/BD/Linear)"
elif [ "${TCO_SMOKE_MODE:-}" = yes ]; then
  tco_info "(TCO_SMOKE_MODE=yes: salto el gate (4) de audit-issue+control para $ISSUE)"
else
  case "${TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE:-yes}" in
    yes) run_gate=yes ;;
    no)  tco_info "(TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE=no: gate (4) audit-issue+control DESACTIVADO para $ISSUE)" ;;
    *)   tco_err "TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE='${TCO_PREFLIGHT_REQUIRE_AUDIT_ISSUE}' no reconocido (usa yes|no) — mantengo gate (4) ACTIVO (fail-closed)"; run_gate=yes ;;
  esac
fi

if [ "$run_gate" = yes ]; then
  if ! tco_preflight_audit_gate "$ISSUE"; then
    rc=1
  fi
fi

[ "$rc" -eq 0 ] && tco_say "PREFLIGHT OK — $CARRIL listo para arrancar el issue" || tco_say "PREFLIGHT FALLA — ESCALAR, no arrancar"
exit "$rc"
