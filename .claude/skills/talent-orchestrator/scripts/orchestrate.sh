#!/usr/bin/env bash
# orchestrate.sh — Entry del Orquestador. Cura un batch de un proyecto de PRODUCTO y crea UNA
# orden de trabajo en el proyecto Linear "Coordinacion" que el coordinador LEE y despacha a mano
# (no hay consumidor automatico). NO maneja carriles ni paneles. Flujo:
#   preflight (valida TODO el setup por API, fail-closed) -> registro (repo+cuadrilla del coordinador,
#   exige >=1 canal dev) -> select-work -> resolver label coord-<x> por nombre -> pre-create fail-closed
#   (guard una-orden-por-coordinador + idempotencia + solape) -> crear orden (labels + prosa + JSON).
# Uso: orchestrate.sh --project <uuid> --coordinador coord-X [--milestones "uuid uuid"] [--cap N]
#      [--allow-multiple] [--dry-run]
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"; . "$HERE/registry.sh"

# [MAYOR 3] Preflight fail-closed del CONTRATO COMPLETO: vars + existencia por API de proyecto,
# issue-registro, los 4 estados (en el team) y los 4 labels obligatorios. strict=yes => devuelve 1 si falla.
torc_preflight() {
  local strict="$1" miss errs=0 states labels
  miss="$(torc_missing_setup | paste -sd' ' -)"
  if [ -n "$miss" ]; then
    torc_err "SETUP Linear incompleto (requiere OK del lead). Falta: $miss"
    [ "$strict" = yes ] && return 1; torc_info "(dry-run) preview pese al setup incompleto" >&2; return 0
  fi
  # [TAL-8037] Sin default de casa: team e initiative son IDENTIDAD de la instancia — `:?` ANTES de tocar la API.
  : "${TORC_TEAM_ID:?TORC_TEAM_ID sin definir (team Linear de la instancia; sin default de casa)}" "${TORC_INITIATIVE_ID:?TORC_INITIATIVE_ID sin definir (initiative meta de la instancia; sin default de casa)}"
  [ "$(linear_api 'query($id:String!){project(id:$id){id}}' "$(jq -n --arg id "$TORC_COORD_PROJECT_ID" '{id:$id}')" | jq -r '.data.project.id // empty')" = "$TORC_COORD_PROJECT_ID" ] \
    || { torc_err "proyecto Coordinacion no existe/visible"; errs=1; }
  # El proyecto Coordinacion debe pertenecer a la initiative meta TORC_INITIATIVE_ID (politica: excepcion meta-orquestacion).
  if [ -n "${TORC_INITIATIVE_ID:-}" ]; then
    linear_api 'query($id:String!){initiative(id:$id){projects(first:250){nodes{id}}}}' "$(jq -n --arg id "$TORC_INITIATIVE_ID" '{id:$id}')" \
      | jq -r '.data.initiative.projects.nodes[]?.id' | grep -qx "$TORC_COORD_PROJECT_ID" \
      || { torc_err "proyecto Coordinacion no pertenece a la initiative TORC_INITIATIVE_ID ($TORC_INITIATIVE_ID)"; errs=1; }
  fi
  [ -n "$(linear_api 'query($id:String!){issue(id:$id){id}}' "$(jq -n --arg id "$TORC_REGISTRY_ISSUE_ID" '{id:$id}')" | jq -r '.data.issue.id // empty')" ] \
    || { torc_err "issue-registro no existe"; errs=1; }
  states="$(linear_api 'query($id:String!){team(id:$id){states{nodes{id}}}}' "$(jq -n --arg id "$TORC_TEAM_ID" '{id:$id}')" | jq -r '.data.team.states.nodes[]?.id')"
  for s in "$TORC_STATE_TODO" "$TORC_STATE_WORKING" "$TORC_STATE_NEEDS_INPUT" "$TORC_STATE_DONE"; do
    printf '%s\n' "$states" | grep -qx "$s" || { torc_err "state inexistente en el team: $s"; errs=1; }
  done
  labels="$(linear_api 'query{issueLabels(first:250){nodes{id}}}' | jq -r '.data.issueLabels.nodes[]?.id')"
  for l in "$TORC_LABEL_AGENT_INSTR" "$TORC_LABEL_REGISTRY" "$TORC_LABEL_VERTICAL" "$TORC_LABEL_ACTOR_AI"; do
    printf '%s\n' "$labels" | grep -qx "$l" || { torc_err "label inexistente: $l"; errs=1; }
  done
  [ "$errs" -eq 0 ] || { [ "$strict" = yes ] && return 1; torc_info "(dry-run) preview pese a fallos de preflight" >&2; }
  return 0
}

# [BLOQUEANTE 2] Resuelve el id del label coord-<x> POR NOMBRE (ligado a --coordinador). Falla si no existe.
torc_resolve_coord_label() {
  local coord="$1" id
  id="$(linear_api 'query{issueLabels(first:250){nodes{id name}}}' | jq -r --arg n "$coord" '.data.issueLabels.nodes[]?|select(.name==$n)|.id' | head -1)"
  [ -n "$id" ] || { torc_err "no existe el label de routing '$coord' (crea coord-<x> en el setup)"; return 1; }
  printf '%s' "$id"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  PROJECT="" COORD="" MILESTONES="" CAP="" DRY=no ALLOW_MULTIPLE=no
  while [ $# -gt 0 ]; do case "$1" in
    --project)        PROJECT="$2"; shift 2;;
    --coordinador)    COORD="$2"; shift 2;;
    --milestones)     MILESTONES="$2"; shift 2;;
    --cap)            CAP="$2"; shift 2;;
    --allow-multiple) ALLOW_MULTIPLE=yes; shift;;   # salta SOLO el guard de orden-abierta por coordinador
    --dry-run)        DRY=yes; shift;;
    *) torc_die "flag desconocido: $1";;
  esac; done
  torc_load_tokens
  torc_is_uuid "$PROJECT" || torc_die "--project debe ser UUID de un proyecto de producto"
  torc_is_coord "$COORD"  || torc_die "--coordinador debe ser coord-<nombre>"
  for m in $MILESTONES; do torc_is_uuid "$m" || torc_die "--milestones: '$m' no es UUID"; done

  torc_lock_acquire "orchestrate-$COORD" 3600 || torc_die "Ya hay un orquestador para $COORD (lock)."
  trap 'torc_lock_release "orchestrate-'"$COORD"'"' EXIT

  if [ "$DRY" = yes ]; then torc_preflight no; else torc_preflight yes || exit 1; fi

  # Cuadrilla + repo del coordinador desde la issue-registro. [BLOQUEANTE 1] exige cuadrilla valida.
  crew="$(torc_registry_print "$COORD" 2>/dev/null || true)"
  cr="$(printf '%s\n' "$crew" | torc_crew_repo)"; REPO="${cr%%$'\t'*}"; devcount="${cr##*$'\t'}"
  if [ "$DRY" != yes ]; then
    { [ -n "$REPO" ] && torc_is_repo "$REPO"; } || torc_die "coordinador $COORD sin repo valido en el registro — NO se crea orden"
    [ "${devcount:-0}" -ge 1 ] 2>/dev/null || torc_die "coordinador $COORD sin canales 'dev' en el registro — NO se crea orden"
  else
    { [ -n "$REPO" ] && torc_is_repo "$REPO"; } || { REPO="(desconocido)"; torc_info "(dry-run) $COORD sin repo en registro" >&2; }
  fi
  [ -n "$CAP" ] || CAP="${devcount:-$TORC_DEFAULT_CAP}"; [ "$CAP" -gt 0 ] 2>/dev/null || CAP="$TORC_DEFAULT_CAP"

  # Resolver el label coord-<x> por nombre (requerido en no-dry).
  if [ "$DRY" = yes ]; then COORD_LABEL="$(torc_resolve_coord_label "$COORD" 2>/dev/null || true)"
  else COORD_LABEL="$(torc_resolve_coord_label "$COORD")" || exit 1; fi

  # Curar el batch.
  torc_say "Curando batch para $COORD (proyecto $PROJECT, cap $CAP)"
  sw_args=(--project "$PROJECT" --cap "$CAP")
  [ -n "$MILESTONES" ] && sw_args+=(--milestones "$MILESTONES")
  [ -n "${TORC_COORD_PROJECT_ID:-}" ] && sw_args+=(--coord-project "$TORC_COORD_PROJECT_ID")
  work="$(bash "$HERE/select-work.sh" "${sw_args[@]}")" || torc_die "select-work fallo o ciclo de dependencias — ESCALAR"
  ids="$(printf '%s' "$work" | jq -r '.issue_ids[]?' | paste -sd' ' -)"
  prec="$(printf '%s' "$work" | jq -c '.precedence // []')"
  if [ -z "$ids" ]; then
    torc_info "No hay issues accionables para el batch (cola vacia tras filtros/reserva)."; exit 0
  fi
  torc_info "Batch ($COORD): $ids"
  printf '%s' "$work" | jq -r '"  excluidas -> reservadas:\(.excluded.reserved|length) blocked:\(.excluded.blocked|length)"'

  # Nombre REAL del estado de bloqueo (Needs Input) en Linear, para instruir al coordinador con el
  # nombre que existe (en el setup actual = "Blocked"). Fallback si no hay setup (dry-run pre-setup).
  NIN_NAME="Needs Input"
  if [ -n "${TORC_STATE_NEEDS_INPUT:-}" ]; then
    n="$(linear_api 'query($id:String!){workflowState(id:$id){name}}' "$(jq -n --arg id "$TORC_STATE_NEEDS_INPUT" '{id:$id}')" | jq -r '.data.workflowState.name // empty')"
    [ -n "$n" ] && NIN_NAME="$n"
  fi

  # Idempotency key + JSON machine-readable de la orden.
  key="$(torc_idem_key "$COORD" "$ids")"
  oj="$(torc_build_order_json "$COORD" "${TORC_COORD_PROJECT_ID:-pending}" "$REPO" "$ids" "$prec" \
        | jq --arg k "$key" '. + {idempotency_key:$k}')"
  # [TAL-1974] El body se renderiza desde la UNICA fuente de verdad (assets/work-order.tmpl) via
  # torc_render_order_body — ya NO hay printf inline duplicado (ver lib.sh y el guard estatico de
  # tests/run-tests.sh que impide que .tmpl y body vuelvan a divergir).
  issue_list="$(printf '%s\n' $ids | nl -w2 -s') ')"
  body="$(torc_render_order_body "$COORD" "$REPO" "$issue_list" "$NIN_NAME" "$oj")" \
    || torc_die "fallo renderizando el cuerpo de la orden ($TORC_SKILL_DIR/assets/work-order.tmpl)"
  title="Orquestar batch ($COORD): $(printf '%s' "$ids" | tr ' ' ',')"

  if [ "$DRY" = yes ]; then
    torc_say "DRY-RUN — orden que se crearia (no se escribe en Linear)"
    printf 'Titulo: %s\nProyecto: %s\nLabels: agent-instructions, %s(%s), vertical/*, actor/ai\nEstado: To Do\nIdempotency: %s\n\n%s\n' \
      "$title" "${TORC_COORD_PROJECT_ID:-<coord-project>}" "$COORD" "${COORD_LABEL:-NO-RESUELTO}" "$key" "$body"
    exit 0
  fi

  # [TAL-1568] Pre-create fail-closed en UN solo lugar (helpers testeables de lib.sh): guard de
  # una-orden-por-coordinador + idempotencia + solape, todos sobre el MISMO fetch fail-closed. El helper
  # NO llama exit (imprime un token TRI-STATE); el router puro mapea y el case explicito enruta con default
  # fail-closed. `dec=…; rc=$?` en linea separada: `x="$(...)"` en una sola asignacion enmascararia el rc.
  dec="$(torc_precreate_check "$TORC_COORD_PROJECT_ID" "$TORC_LABEL_AGENT_INSTR" "$COORD_LABEL" "$key" "$ids" "$ALLOW_MULTIPLE")"; rc=$?
  act="$(torc_route_precreate "$dec" "$rc")"
  case "$act" in
    PROCEED) : ;;
    SKIP)    torc_info "Ya existe orden abierta con la misma idempotency-key ($dec) — no se duplica."; exit 0 ;;
    *)       torc_die "pre-create ${act#ABORT:} ($dec) — cierra la orden previa (Done), resuelve el solape (ESCALAR), o pasa --allow-multiple" ;;
  esac

  # Crear la orden (state To Do, labels obligatorios + coord-<x> resuelto).
  labels="$(jq -n --arg a "$TORC_LABEL_AGENT_INSTR" --arg c "$COORD_LABEL" --arg v "$TORC_LABEL_VERTICAL" --arg ai "$TORC_LABEL_ACTOR_AI" '[$a,$c,$v,$ai]')"
  vars="$(jq -n --arg t "${TORC_TEAM_ID:?TORC_TEAM_ID sin definir}" --arg p "$TORC_COORD_PROJECT_ID" --arg s "$TORC_STATE_TODO" \
          --arg ti "$title" --arg b "$body" --argjson l "$labels" \
          '{i:{teamId:$t,projectId:$p,stateId:$s,title:$ti,description:$b,labelIds:$l}}')"
  res="$(linear_api 'mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier url}}}' "$vars")"
  ident="$(printf '%s' "$res" | jq -r '.data.issueCreate.issue.identifier // empty')"
  [ -n "$ident" ] || torc_die "fallo creando la orden: $(printf '%s' "$res" | torc_redact | head -c 200)"
  torc_say "Orden creada: $ident"
  printf '%s' "$res" | jq -r '.data.issueCreate.issue.url'
fi
