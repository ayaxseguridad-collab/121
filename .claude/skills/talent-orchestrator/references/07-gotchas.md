# 07 — Gotchas

## Table of Contents

- [Gotchas de construcción (cubiertas por tests)](#gotchas-de-construcción-cubiertas-por-tests)
- [Gotchas de operación en vivo (corrida F1, 2026-07-14)](#gotchas-de-operación-en-vivo-corrida-f1-2026-07-14)

Trampas reales encontradas al construir/operar este skill (cubiertas por tests donde aplica).

## Gotchas de construcción (cubiertas por tests)

```text
Bloqueo transitivo (torc_cascade_blocked) — sin esto, la arista se pierde

  batch candidato:  A ─(depende de)─► B ─(depende de)─► C (blocker EXTERNO, no resuelto)
                                                          │
  C se excluye (blocker externo no resuelto) ─────────────┘
                          │
                          ▼
  B pierde su parent (C) del set presente → B TAMBIÉN se excluye (cascada, punto fijo)
                          │
                          ▼
  A pierde su parent (B) → A TAMBIÉN se excluye
                          │
                          ▼
  resultado: {A, B, C} fuera del batch (sin cascada, A y B se despacharían SIN su prerequisito)
```

- **Prioridad Linear `0 = No priority`**, no la más alta. `1=Urgent, 2=High, 3=Medium, 4=Low`.
  Hay que remapear `0→99` para que Urgent quede primero. (Test: `orden de prioridad`.)
- **`FNR==NR` falla con archivo vacío**: el truco awk de "primer archivo = set" trata TODO el stdin
  como el set cuando el primer archivo tiene 0 líneas → se come todos los candidatos. `torc_exclude`
  lee la reserva en `BEGIN{getline}`. (Test: `exclude vacio`.)
- **Tipos GraphQL**: el filtro `project:{id:{eq:$pid}}` espera `$pid:ID!`, no `String!`. Con valor
  inline no se nota; con variable, Linear da 400. `project(id:)`/`issue(id:)` sí son `String!`.
- **`${2:-{} }` en bash está mal parseado**: el primer `}` cierra la expansión y, con `$2` presente,
  añade `" }"` al final → JSON inválido. Usar `${2:-}` + chequeo aparte.
- **Variables GraphQL siempre**: nunca interpolar valores en el cuerpo del query (inyección). Todo
  con `jq -n --arg/--argjson` y validación previa (UUID/`TAL-…`/`coord-…`/canal/repo).
- **Setup gated**: no auto-crear proyecto/labels/estados. El preflight valida y falla ruidoso; los
  IDs van en `agents.conf` del escrow.
- **CERO secretos en Linear**: la issue-registro mapea, no guarda creds (regla 18).
- **Idempotencia**: la reserva vive en Linear (órdenes abiertas), no en locks locales del coordinador.
- **Relations**: el shape real es `relations.nodes[].type` (`blocks`/`blockedBy`/`related`) +
  `relatedIssue.identifier`. Verificado contra API (el cheatsheet local solo documenta la creación).
- **Truncación de relaciones = fail-closed, condicionado a `pageInfo.hasNextPage`**:
  `relations(first:50)`; si una issue alcanza 50 nodos **y `hasNextPage=true`**, quedan páginas
  sin leer y se **aborta** la selección (un blocker omitido crearía una orden no accionable), no
  se avisa-y-sigue. Si alcanza exactamente 50 pero `hasNextPage=false`, esas 50 son el **total
  real** de relaciones de la issue — no hay truncación, no se aborta (tratarlo como fail-closed
  igualmente sería un falso positivo que descarta candidatas válidas sin motivo).
- **Bloqueo transitivo**: si un parent se excluye por blocker externo, sus children tampoco son
  accionables → `torc_cascade_blocked` los propaga a punto fijo ANTES del topo-sort (si no, la
  arista se pierde al faltar el nodo padre y el child se despacharía sin prerequisito).

## Gotchas de operación en vivo (corrida F1, 2026-07-14)

- **Estado REAL = múltiples señales, nunca una status-line**: diagnosticar idle/stall SOLO con
  git-commits + working tree dirty + captura del pane + spinner. Las status-lines quedan STALE
  (PR mergeado mostrado abierto; "Login expired" en scrollback tras relanzamiento exitoso →
  verificar el prompt fresco con `tail`, no el texto de error viejo). Falsa alarma cara: casi se
  reinicia un coordinador "en stall" cuyo checklist mostraba trabajo real — leer su turno ANTES
  de diagnosticar.
- **La narrativa del coordinador también se audita**: "8/8 productivos" puede convivir con canales
  parados en el menú de ExitPlanMode esperando su plan-gate. Sondear los PANES de los canales
  (menú arriba + veredicto del auditor ya emitido = el coordinador es el cuello), no solo su reporte.
- **No auto-inflingirse fuegos**: sobre-pollear `/oauth/usage` rate-limitea el endpoint para TODA
  la operación (los pozos dan ERR transitorio en cascada). Cachear lecturas (~35min) y throttlear.
  `pkill -f "<script>"` se AUTO-MATA por argv self-match (exit 144) → `pgrep -x` o matar por PID.
- **Gate oculto en la descripción del issue**: un issue "dispatchable" en el triage puede tener un
  gate del lead escondido en el body (p. ej. una credencial `sk_test_` que solo el lead provee).
  RELEER la descripción completa antes de asignar canal.
- **`state`+`labels` es INSUFICIENTE para decidir despacho — el bloqueo vive en la DESCRIPCIÓN**: un
  candidato Backlog/sin-blocked-by puede seguir muerto por señales que solo aparecen leyendo el body
  completo: un `BLOQUEADA por` / `depende de` / `descopado` en prosa (no modelado como relación), un
  artefacto requerido fuera del repo, un choque con un ADR ya `accepted`, o una sub-parte que toca PII
  y exige tratamiento aparte. Leer la descripción ENTERA de cada candidato antes de dispatch; picks
  muertos consecutivos son el síntoma de saltarse este paso.
- **Quoting hacia contenedores**: componer `incus exec … -c <script>` con `shlex.quote`/comillas
  simples, jamás `json.dumps` ni comillas dobles — el shell del HOST expande `$()`/`$vars` antes de
  entrar al contenedor y el monitor queda ciego en silencio (todos los canales "?").
- **El literal "git push" en mensajes a coordinadores** dispara el hook anti-compound del Bash
  aunque sea texto — parafrasear ("sube la rama").
