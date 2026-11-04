#!/usr/bin/env bash
# select-work.sh — Cura el batch de un proyecto de PRODUCTO para un coordinador.
# Lee issues (multi-milestone), excluye Done/In-Progress/asignadas, EXCLUYE reserva (issue_ids de
# ordenes abiertas), aplica orden de prioridad (0->99) + topo-sort de dependencias (blocks/blockedBy)
# con deteccion de ciclos, excluye issues con blockers externos no resueltos, y aplica el cap.
# Salida: JSON { issue_ids:[ordenados], precedence:[[child,parent]], excluded:{reserved,blocked,cycle} }.
# Uso: select-work.sh --project <uuid> [--milestones "uuid uuid"] [--cap N] [--coord-project <uuid>]
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  PROJECT="" MILESTONES="" CAP="$TORC_DEFAULT_CAP" COORDPROJ="$TORC_COORD_PROJECT_ID"
  while [ $# -gt 0 ]; do case "$1" in
    --project)      PROJECT="$2"; shift 2;;
    --milestones)   MILESTONES="$2"; shift 2;;
    --cap)          CAP="$2"; shift 2;;
    --coord-project) COORDPROJ="$2"; shift 2;;
    *) torc_die "flag desconocido: $1";;
  esac; done
  torc_load_tokens
  torc_is_uuid "$PROJECT" || torc_die "--project debe ser UUID valido"
  for m in $MILESTONES; do torc_is_uuid "$m" || torc_die "--milestones: '$m' no es UUID"; done
  [ -n "$COORDPROJ" ] && { torc_is_uuid "$COORDPROJ" || torc_die "--coord-project debe ser UUID"; }
  printf '%s' "$CAP" | grep -qE '^[0-9]+$' || torc_die "--cap debe ser entero"

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  # 1) Issues del proyecto (paginado) con relaciones y estado del relacionado.
  # relations(first:50): cubre el caso comun. pageInfo{hasNextPage} DENTRO de relations es
  # obligatorio: sin el, no se puede distinguir "50 relaciones = el total real" de "50 = truncado,
  # hay mas paginas sin leer" (TAL-3265 r6 — el gap vivia aqui: la doc decia hasNextPage-gated,
  # el script solo miraba length).
  Q='query($pid:ID!,$after:String){issues(first:100,after:$after,filter:{project:{id:{eq:$pid}}}){pageInfo{hasNextPage endCursor} nodes{identifier priority state{type} assignee{id} projectMilestone{id sortOrder} relations(first:50){pageInfo{hasNextPage} nodes{type relatedIssue{identifier state{type}}}}}}}'
  : > "$tmp/nodes.jsonl"; after="null"
  for _ in $(seq 1 50); do
    vars="$(jq -n --arg pid "$PROJECT" --argjson after "$after" '{pid:$pid, after:$after}')"
    resp="$(linear_api "$Q" "$vars")"
    printf '%s' "$resp" | jq -e '.data.issues' >/dev/null 2>&1 \
      || torc_die "fallo Linear (issues): $(printf '%s' "$resp" | torc_redact | head -c 200)"
    printf '%s' "$resp" | jq -c '.data.issues.nodes[]?' >> "$tmp/nodes.jsonl"
    [ "$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.hasNextPage // false')" = true ] || break
    after="\"$(printf '%s' "$resp" | jq -r '.data.issues.pageInfo.endCursor')\""
  done

  # [CR #3 / TAL-3265 r6] Fail-closed ante truncacion REAL de relaciones (>=50 Y hasNextPage=true):
  # un blocker omitido crearia una orden no accionable. Abortar la seleccion (escalar) en vez de
  # avisar y seguir. Exactamente 50 CON hasNextPage=false es el total real, no truncacion — no abortar
  # (torc_relations_truncated en lib.sh, pura y testeada).
  if [ -s "$tmp/nodes.jsonl" ]; then
    _trunc="$(torc_relations_truncated < "$tmp/nodes.jsonl")"
    if [ -n "$_trunc" ]; then
      torc_die "issue(s) con relations truncadas (>=50 Y hasNextPage=true): $(printf '%s' "$_trunc" | tr '\n' ' ') — paginar/revisar antes de orquestar — ESCALAR"
    fi
  fi

  # 2) Filtro accionable: backlog/unstarted + sin assignee (+ milestones si se pasaron).
  msfilter='true'
  if [ -n "$MILESTONES" ]; then
    msjson="$(printf '%s\n' $MILESTONES | jq -R . | jq -s .)"
    msfilter='(.projectMilestone.id as $m | '"$msjson"' | index($m)) != null'
  fi
  jq -c "select((.state.type==\"backlog\" or .state.type==\"unstarted\") and (.assignee==null) and ($msfilter))" \
    "$tmp/nodes.jsonl" > "$tmp/actionable.jsonl"

  # 3) Reserva: issue_ids de ordenes ABIERTAS del proyecto Coordinacion.
  : > "$tmp/reserved"
  if [ -n "$COORDPROJ" ]; then
    # [CR #5] La reserva es fail-closed (igual de estricta que la query principal de arriba): si la
    # query de Linear falla, el label de reserva esta vacio, o la lista se trunca, una issue YA
    # reservada quedaria fuera del set y podria reasignarse. Cualquiera de esos tres casos -> ESCALAR.
    [ -n "${TORC_LABEL_AGENT_INSTR:-}" ] \
      || torc_die "TORC_LABEL_AGENT_INSTR vacio con --coord-project: la reserva no se puede calcular — ESCALAR"
    QR='query($pid:ID!,$lbl:ID!){issues(first:200,filter:{project:{id:{eq:$pid}},labels:{some:{id:{eq:$lbl}}},state:{type:{nin:["completed","canceled"]}}}){pageInfo{hasNextPage} nodes{description}}}'
    rresp="$(linear_api "$QR" "$(jq -n --arg pid "$COORDPROJ" --arg lbl "$TORC_LABEL_AGENT_INSTR" '{pid:$pid,lbl:$lbl}')")"
    printf '%s' "$rresp" | jq -e '.data.issues' >/dev/null 2>&1 \
      || torc_die "fallo Linear (reserva): $(printf '%s' "$rresp" | torc_redact | head -c 200)"
    if [ "$(printf '%s' "$rresp" | jq -r '.data.issues.pageInfo.hasNextPage // false')" = true ]; then
      torc_die ">200 ordenes abiertas en Coordinacion — reserva truncada; paginar/revisar antes de orquestar — ESCALAR"
    fi
    # [CR #6] Fail-fast al CONSTRUIR la reserva: si jq/extract/sort fallan a mitad de la tuberia
    # (con set -o pipefail activo), $tmp/reserved quedaria incompleto -> reasignacion silenciosa.
    # `if !` aborta (ESCALAR). Salida VACIA no es fallo (awk/jq/sort dan exit 0 sin issue_ids): la
    # reserva legitimamente vacia sigue siendo un caso valido y no dispara torc_die.
    if ! printf '%s' "$rresp" | jq -r '.data.issues.nodes[]?.description // empty' \
         | torc_extract_issue_ids | sort -u >> "$tmp/reserved"; then
      torc_die "fallo construyendo la reserva (jq/extract/sort) — ESCALAR"
    fi
  else
    torc_info "(aviso) sin --coord-project: no se puede excluir reserva (solo OK en dry-run pre-setup)" >&2
  fi

  # 4) Candidatos accionables = actionable - reserved, ordenados por prioridad y luego sortOrder.
  jq -r '[ (if .priority==0 then 99 else .priority end), (.projectMilestone.sortOrder // 99999), .identifier ] | @tsv' \
    "$tmp/actionable.jsonl" | sort -t$'\t' -k1,1n -k2,2n | cut -f3 \
    | torc_exclude "$tmp/reserved" > "$tmp/cand_ordered"
  : > "$tmp/cands"; cp "$tmp/cand_ordered" "$tmp/cands"

  # set de candidatos para pertenencia
  cands_json="$(jq -R . "$tmp/cands" | jq -s .)"

  # 5) Aristas + blockers externos no resueltos (desde relations, con estado del relacionado).
  #    edge "child<TAB>parent" = child depende de parent. blocked = candidato con blocker externo no completado.
  : > "$tmp/edges"; : > "$tmp/blocked"
  jq -rc --argjson C "$cands_json" '
    (.identifier) as $id
    | select($C|index($id))
    | .relations.nodes[]? as $r
    | ($r.relatedIssue.identifier) as $rid | ($r.relatedIssue.state.type) as $rst
    | if   $r.type=="blockedBy" then {child:$id, parent:$rid, pstate:$rst}
      elif $r.type=="blocks"    then {child:$rid, parent:$id, pstate:"_self_"}
      else empty end
    | [.child, .parent, .pstate] | @tsv' "$tmp/actionable.jsonl" > "$tmp/rel.tsv" || true

  while IFS=$'\t' read -r child parent pstate; do
    [ -n "$child" ] || continue
    in_child=$(printf '%s' "$cands_json" | jq --arg x "$child" 'index($x)!=null')
    in_parent=$(printf '%s' "$cands_json" | jq --arg x "$parent" 'index($x)!=null')
    if [ "$in_child" = true ] && [ "$in_parent" = true ]; then
      printf '%s\t%s\n' "$child" "$parent" >> "$tmp/edges"               # arista intra-batch
    elif [ "$in_child" = true ] && [ "$in_parent" = false ]; then
      # blocker externo: si NO esta completado, el child no puede arrancar -> blocked
      if [ "$pstate" != "completed" ] && [ "$pstate" != "_self_" ]; then
        printf '%s\n' "$child" >> "$tmp/blocked"
      fi
    fi
  done < "$tmp/rel.tsv"
  sort -u "$tmp/blocked" -o "$tmp/blocked" 2>/dev/null || true

  # quitar blocked de candidatos (preservando orden)
  torc_exclude "$tmp/blocked" < "$tmp/cands" > "$tmp/cands2"; mv "$tmp/cands2" "$tmp/cands"
  # [CR #4] Propagar bloqueo transitivo: si un parent se excluye, sus children tampoco son accionables.
  casc="$(torc_cascade_blocked "$tmp/cands" "$tmp/edges")"
  if [ -n "$casc" ]; then
    printf '%s\n' "$casc" >> "$tmp/blocked"; sort -u "$tmp/blocked" -o "$tmp/blocked"
    torc_exclude "$tmp/blocked" < "$tmp/cands" > "$tmp/cands2"; mv "$tmp/cands2" "$tmp/cands"
  fi

  # 6) Topo-sort (deteccion de ciclos). Aristas se filtran a nodos presentes dentro de torc_toposort.
  if ! torc_toposort "$tmp/cands" "$tmp/edges" > "$tmp/ordered" 2>/dev/null; then
    jq -n --argjson blocked "$(jq -R . "$tmp/blocked" 2>/dev/null | jq -s . 2>/dev/null || echo '[]')" \
      '{issue_ids:[], precedence:[], excluded:{reserved:[], blocked:$blocked, cycle:true}}'
    torc_err "CICLO de dependencias detectado en el batch — ESCALAR"; exit 3
  fi

  # 7) Cap.
  head -n "$CAP" "$tmp/ordered" > "$tmp/final"

  # 8) Precedencia (solo aristas cuyos dos extremos quedan en el batch final).
  prec="$(awk -F'\t' 'FNR==NR{f[$1]=1;next} ($1 in f)&&($2 in f){print}' "$tmp/final" "$tmp/edges" \
    | jq -R 'split("\t")' 2>/dev/null | jq -s . 2>/dev/null)"; [ -n "$prec" ] || prec='[]'

  ids_json="$(jq -R . "$tmp/final" | jq -s .)"
  reserved_json="$(jq -R . "$tmp/reserved" 2>/dev/null | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')"
  blocked_json="$(jq -R . "$tmp/blocked" 2>/dev/null | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')"
  jq -n --argjson ids "$ids_json" --argjson prec "$prec" --argjson res "$reserved_json" --argjson blk "$blocked_json" \
    '{issue_ids:$ids, precedence:$prec, excluded:{reserved:$res, blocked:$blk, cycle:false}}'
fi
