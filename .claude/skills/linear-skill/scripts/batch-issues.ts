#!/usr/bin/env -S npx tsx
/**
 * batch-issues.ts — Operaciones en lote sobre issues de Linear
 *
 * Para batches grandes (>20 issues) usa este script en lugar de llamadas GraphQL sueltas.
 * Soporta:
 * - Paginación automática (no se limita a 50)
 * - Mutación real por LOTES vía `issueBatchUpdate` (hasta 50 ids por llamada — tope confirmado
 *   del schema vivo de Linear, ver research/02-schema-vivo.md §4 y §6 comunidad #1/#2), en vez
 *   de N llamadas `issueUpdate` sueltas — mucha menos complejidad consumida, menos superficie de
 *   fallo parcial. Troceo en lotes con `chunkIds()` (≤50 por llamada) + `--concurrency` lotes en
 *   vuelo simultáneos.
 * - Add/remove labels vía los campos NATIVOS de `IssueUpdateInput` (`addedLabelIds`/
 *   `removedLabelIds`) — no hace falta leer y reenviar el array `labelIds` completo por issue
 *   (ese patrón read-then-write-completo es innecesario y propenso a condiciones de carrera
 *   frente a un write concurrente; `addedLabelIds`/`removedLabelIds` son operaciones ADITIVAS a
 *   nivel de servidor, ver research/02-schema-vivo.md hallazgo #7).
 * - Retry on rate limit (heredado de `LinearMinClient.queryWithRetry` — ver linear-client.ts)
 * - Dry run para validar antes de ejecutar
 *
 * NOTA — no confundir con `issueBatchCreate`: esa mutation SÍ exige un input-WRAPPER
 * (`IssueBatchCreateInput!` con campo `issues: [IssueCreateInput!]!`, es decir
 * `{"issues": [...]}` como objeto) — enviar el array pelado como variable produce un fallo
 * SILENCIOSO (`{ issues: [] }` vacío, sin errors[]). Este script no crea issues, solo actualiza
 * (`issueBatchUpdate`, que sí toma `ids`/`input` como argumentos sueltos, no un wrapper) — se deja
 * la nota porque son mutations hermanas y es fácil confundir sus formas de input.
 *
 * Uso:
 *   npx tsx batch-issues.ts --action batch-update \
 *     --filter '{"team":{"key":{"eq":"TAL"}},"state":{"type":{"eq":"backlog"}}}' \
 *     --add-labels "vertical/media" \
 *     --remove-labels "needs-triage" \
 *     --dry-run
 *
 *   npx tsx batch-issues.ts --action batch-update \
 *     --filter '{"team":{"key":{"eq":"TAL"}}}' \
 *     --set-priority 3 \
 *     --set-cycle current
 *
 * --action es opcional para batch-update (default, retrocompatible con callers que solo pasan
 * --filter sin --action). --help imprime esta ayuda y sale 0 sin tocar LINEAR_API_KEY/red.
 * --selftest corre fixtures offline (buildLabelIdMap + chunkIds + buildIssueBatchUpdateInput).
 */

import { LinearMinClient, IssueFilter, Priority, loadApiKey } from "./linear-client";

// ====================================================================
// Tipos
// ====================================================================

interface BatchOptions {
  filter: IssueFilter;
  dryRun: boolean;
  concurrency: number;

  // Operaciones soportadas (las que computeUpdate() aplica de verdad)
  addLabels?: string[];          // nombres de labels a añadir
  removeLabels?: string[];       // nombres de labels a quitar
  setPriority?: Priority;
  setCycle?: string | "current" | "next";
  // state/assignee NO se soportan aquí: el CLI rechaza --set-state/--set-assignee (fail-closed).
  // Para cambiarlos en lote, iterar issueUpdate(id, { stateId|assigneeId }) a mano.
}

interface IssueRecord {
  id: string;
  identifier: string;
  title: string;
  priority: number;
  estimate: number;
  state: { id: string; name: string; type: string };
  cycle: { id: string; number: number } | null;
  assignee: { id: string; displayName: string } | null;
  project: { id: string; name: string } | null;
  labels: { nodes: { id: string; name: string }[] };
}

// Forma real de IssueUpdateInput usada por issueBatchUpdate — UN solo input compartido para
// TODOS los ids de una llamada (a diferencia del issueUpdate individual, aquí no hay diff
// por-issue: addedLabelIds/removedLabelIds son aditivos/resta a nivel de servidor, así que
// aplicarlos a un issue que ya está en el estado deseado es un no-op seguro).
interface UpdateInput {
  addedLabelIds?: string[];
  removedLabelIds?: string[];
  priority?: number;
  cycleId?: string;
}

// ====================================================================
// Queries
// ====================================================================

const ISSUES_QUERY = `
  query Issues($filter: IssueFilter, $first: Int!, $after: String) {
    issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
      nodes {
        id identifier title priority estimate
        state { id name type }
        cycle { id number }
        assignee { id displayName }
        project { id name }
        labels { nodes { id name } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
`;

// Tope confirmado del schema vivo: hasta 50 ids por llamada (research/02-schema-vivo.md §4,
// firma exacta `issueBatchUpdate(ids: [UUID!]!, input: IssueUpdateInput!): IssueBatchPayload!`).
// La variable GraphQL se tipa `[UUID!]!` (no `[String!]!`) — así viene confirmado en la firma
// exacta del brief de esta issue.
const BATCH_CHUNK_SIZE = 50;

const ISSUE_BATCH_UPDATE = `
  mutation IssueBatchUpdate($ids: [UUID!]!, $input: IssueUpdateInput!) {
    issueBatchUpdate(ids: $ids, input: $input) {
      success
      issues { id identifier }
    }
  }
`;

// Trocea un array de ids en lotes de a lo sumo `size` — puro y testeable offline (--selftest).
// Preserva el orden de entrada (no reordena, no dedup — eso es responsabilidad del caller).
export function chunkIds(ids: string[], size: number): string[][] {
  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += size) chunks.push(ids.slice(i, i + size));
  return chunks;
}

// Construye el ÚNICO IssueUpdateInput compartido por todos los lotes de esta corrida — puro y
// testeable offline (--selftest). Mapea los flags del CLI a los campos NATIVOS de
// IssueUpdateInput: --add-labels → addedLabelIds, --remove-labels → removedLabelIds (nunca
// labelIds completo — ver JSDoc de cabecera).
export function buildIssueBatchUpdateInput(opts: {
  addLabelIds: string[];
  removeLabelIds: string[];
  setPriority?: number;
  cycleId?: string;
}): UpdateInput {
  const input: UpdateInput = {};
  if (opts.addLabelIds.length > 0) input.addedLabelIds = opts.addLabelIds;
  if (opts.removeLabelIds.length > 0) input.removedLabelIds = opts.removeLabelIds;
  if (opts.setPriority !== undefined) input.priority = opts.setPriority;
  if (opts.cycleId !== undefined) input.cycleId = opts.cycleId;
  return input;
}

const LABELS_QUERY = `
  query Labels($filter: IssueLabelFilter) {
    issueLabels(filter: $filter, first: 250) {
      nodes { id name team { key } }
    }
  }
`;

// Resolución de labels FAIL-CLOSED (pura, testeable offline con --selftest): un nombre con
// más de un label vivo (duplicado por team, p.ej. vertical/fabrica en TAL y BUG) ABORTA antes
// de cualquier mutación — un Map name→id se quedaría con el último y aplicaría el UUID de un
// team arbitrario. La deduplicación material en Linear es decisión del workspace.
export function buildLabelIdMap(
  nodes: { id: string; name: string; team?: { key: string } | null }[],
  names: string[]
): Map<string, string> {
  const byName = new Map<string, { id: string; team: string }[]>();
  for (const l of nodes) {
    const sites = byName.get(l.name) ?? [];
    sites.push({ id: l.id, team: l.team?.key ?? "WORKSPACE" });
    byName.set(l.name, sites);
  }
  const missing = names.filter((n) => !byName.has(n));
  if (missing.length > 0) {
    throw new Error(`Labels not found: ${missing.join(", ")}`);
  }
  const dup = names.filter((n) => (byName.get(n)?.length ?? 0) > 1);
  if (dup.length > 0) {
    const detail = dup
      .map((n) => `"${n}" (${byName.get(n)!.map((s) => `${s.team}: ${s.id}`).join(" · ")})`)
      .join("; ");
    throw new Error(
      `resolución ambigua — ${detail}: el nombre tiene varios labels vivos por team y este batch ` +
        `no puede elegir uno sin autoridad. Abortado ANTES de cualquier mutación. ` +
        `Usa un label de nombre único o resuelve el duplicado en Linear (decisión del workspace).`
    );
  }
  const map = new Map<string, string>();
  for (const n of names) map.set(n, byName.get(n)![0].id);
  return map;
}

// PaginationOrderBy solo acepta "createdAt"/"updatedAt" — no existe orderBy: number. createdAt
// correlaciona con el numero de cycle (se crean secuencialmente), asi que sirve como proxy valido.
const TEAM_CYCLES_QUERY = `
  query TeamCycles($teamKey: String!) {
    teams(filter: { key: { eq: $teamKey } }, first: 1) {
      nodes {
        activeCycle { id number }
        cycles(filter: { number: { gt: 0 } }, first: 5, orderBy: createdAt) {
          nodes { id number startsAt }
        }
      }
    }
  }
`;

// ====================================================================
// Implementación
// ====================================================================

class BatchExecutor {
  constructor(
    private client: LinearMinClient,
    private opts: BatchOptions
  ) {}

  async run(): Promise<void> {
    console.log("\n=== Linear Batch Issues ===\n");

    // 1. Resolver IDs de labels para add/remove
    const addLabelIds = this.opts.addLabels
      ? await this.resolveLabelIds(this.opts.addLabels)
      : [];
    const removeLabelIds = this.opts.removeLabels
      ? await this.resolveLabelIds(this.opts.removeLabels)
      : [];

    // 2. Resolver cycle ID si setCycle
    let cycleId: string | undefined;
    if (this.opts.setCycle) {
      cycleId = await this.resolveCycleId(this.opts.setCycle);
    }

    // 3. Listar issues
    console.log("Fetching matching issues (paginated)...");
    const issues = await this.fetchAllIssues();
    console.log(`Found ${issues.length} issues matching filter.\n`);

    if (issues.length === 0) {
      console.log("Nothing to do.");
      return;
    }

    // 4. Mostrar sample
    console.log("Sample (first 5):");
    for (const issue of issues.slice(0, 5)) {
      console.log(`  ${issue.identifier} — ${issue.title}`);
    }
    if (issues.length > 5) console.log(`  ... and ${issues.length - 5} more`);
    console.log();

    // 5. Mostrar plan
    console.log("Plan:");
    if (this.opts.addLabels?.length) console.log(`  + add labels: ${this.opts.addLabels.join(", ")}`);
    if (this.opts.removeLabels?.length) console.log(`  - remove labels: ${this.opts.removeLabels.join(", ")}`);
    if (this.opts.setPriority !== undefined) console.log(`  > priority = ${this.opts.setPriority}`);
    if (this.opts.setCycle) console.log(`  > cycle = ${this.opts.setCycle}`);
    console.log();

    // El input de issueBatchUpdate es UNIFORME para todos los ids de una llamada (no hay diff
    // por-issue como en el loop antiguo de N issueUpdate) — se calcula UNA sola vez aquí.
    const input = buildIssueBatchUpdateInput({
      addLabelIds,
      removeLabelIds,
      setPriority: this.opts.setPriority,
      cycleId,
    });
    // Filtramos los issues que ya están en el estado deseado para no gastar complejidad en
    // updates vacíos — pero el `input` en sí es el mismo objeto para todo el lote.
    const targets = issues.filter((issue) => this.needsUpdate(issue, addLabelIds, removeLabelIds, cycleId));

    if (this.opts.dryRun) {
      console.log(
        `--dry-run set, not executing. ${targets.length}/${issues.length} issues need this update. Detailed diff:\n`
      );
      for (const issue of issues) {
        const summary = this.summarizePerIssue(issue, addLabelIds, removeLabelIds, cycleId);
        console.log(`  ${issue.identifier} ${summary || "(no change)"}`);
      }
      return;
    }

    if (targets.length === 0) {
      console.log("Nothing to do (all matching issues already in the desired state).");
      return;
    }

    // 6. Ejecutar en lotes de ≤50 ids (issueBatchUpdate), con --concurrency lotes en vuelo
    const chunks = chunkIds(
      targets.map((i) => i.id),
      BATCH_CHUNK_SIZE
    );
    console.log(
      `Executing ${targets.length} updates in ${chunks.length} batch(es) of up to ${BATCH_CHUNK_SIZE} ` +
        `(issueBatchUpdate), concurrency=${this.opts.concurrency}...\n`
    );

    let success = 0;
    let failed = 0;
    const errors: Array<{ chunk: number; error: any }> = [];

    for (let i = 0; i < chunks.length; i += this.opts.concurrency) {
      const window = chunks.slice(i, i + this.opts.concurrency);
      const results = await Promise.allSettled(
        // `idempotent: true` justificado, no por comodidad: `issueBatchUpdate` FIJA valores de campo
        // (stateId, cycleId, priority…) y aplica altas/bajas de labels con semántica de conjunto
        // (`addedLabelIds`/`removedLabelIds`). Re-aplicar el MISMO input deja el mismo estado y no
        // crea nada — a diferencia de un `issueCreate` o un `commentCreate`, que jamás deben ir así.
        window.map((ids) => this.client.queryWithRetry<{ issueBatchUpdate: { success: boolean; issues: { id: string; identifier: string }[] } }>(ISSUE_BATCH_UPDATE, { ids, input }, { idempotent: true }))
      );

      results.forEach((r, idx) => {
        const chunkIndex = i + idx;
        if (r.status === "fulfilled" && r.value?.issueBatchUpdate?.success === true) {
          const updated = r.value.issueBatchUpdate.issues ?? [];
          success += updated.length;
          for (const issue of updated) console.log(`  ✓ ${issue.identifier}`);
        } else if (r.status === "fulfilled") {
          // La API respondió sin errors[] pero con success=false: todo el lote cuenta como fallido.
          failed += window[idx].length;
          errors.push({ chunk: chunkIndex, error: new Error("issueBatchUpdate.success=false") });
          console.error(`  ✗ batch #${chunkIndex + 1} (${window[idx].length} issues): issueBatchUpdate.success=false`);
        } else {
          failed += window[idx].length;
          errors.push({ chunk: chunkIndex, error: r.reason });
          console.error(`  ✗ batch #${chunkIndex + 1} (${window[idx].length} issues): ${r.reason?.message ?? r.reason}`);
        }
      });

      // Pequeño throttle entre ventanas de lotes
      if (i + this.opts.concurrency < chunks.length) {
        await sleep(200);
      }
    }

    console.log(`\nResult: ${success} succeeded, ${failed} failed.`);
    if (errors.length > 0) {
      console.log("\nErrors:");
      for (const e of errors.slice(0, 10)) {
        console.log(`  - batch #${e.chunk + 1}:`, e.error?.message ?? e.error);
      }
    }
  }

  private async fetchAllIssues(): Promise<IssueRecord[]> {
    return this.client.paginate(
      ISSUES_QUERY,
      { filter: this.opts.filter },
      (data) => data.issues,
      { batchSize: 50 }
    );
  }

  private async resolveLabelIds(names: string[]): Promise<string[]> {
    const data = await this.client.query(LABELS_QUERY, {
      filter: { name: { in: names } },
    });
    const map = buildLabelIdMap(data.issueLabels.nodes, names);
    return names.map((n) => map.get(n)!);
  }

  private async resolveCycleId(value: string): Promise<string> {
    // Si es UUID, devolver tal cual
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/.test(value)) return value;

    // current / next / número
    const teamKey = this.opts.filter?.team?.key?.eq;
    if (!teamKey) throw new Error("Cannot resolve cycle without team filter");

    const data = await this.client.query(TEAM_CYCLES_QUERY, { teamKey });
    const team = data.teams.nodes[0];
    if (!team) throw new Error(`Team ${teamKey} not found`);

    if (value === "current") {
      if (!team.activeCycle) throw new Error("No active cycle");
      return team.activeCycle.id;
    }

    if (value === "next") {
      const activeNum = team.activeCycle?.number ?? 0;
      const next = team.cycles.nodes.find((c: any) => c.number === activeNum + 1);
      if (!next) throw new Error("No next cycle");
      return next.id;
    }

    const num = parseInt(value, 10);
    if (!isNaN(num)) {
      const cycle = team.cycles.nodes.find((c: any) => c.number === num);
      if (!cycle) throw new Error(`Cycle ${num} not found`);
      return cycle.id;
    }

    throw new Error(`Cannot resolve cycle: ${value}`);
  }

  // Con addedLabelIds/removedLabelIds ya NO hace falta computar un array de labels completo por
  // issue (el servidor aplica el add/remove de forma nativa) — solo hace falta decidir si ESTE
  // issue necesita el update compartido o ya está en el estado deseado (no-op, se filtra antes
  // de la mutación para no gastar complejidad).
  private needsUpdate(
    issue: IssueRecord,
    addLabelIds: string[],
    removeLabelIds: string[],
    cycleId?: string
  ): boolean {
    const current = new Set(issue.labels.nodes.map((l) => l.id));
    const wouldAddSomething = addLabelIds.some((id) => !current.has(id));
    const wouldRemoveSomething = removeLabelIds.some((id) => current.has(id));
    const wouldChangePriority = this.opts.setPriority !== undefined && this.opts.setPriority !== issue.priority;
    const wouldChangeCycle = cycleId !== undefined && cycleId !== issue.cycle?.id;
    return wouldAddSomething || wouldRemoveSomething || wouldChangePriority || wouldChangeCycle;
  }

  private summarizePerIssue(
    issue: IssueRecord,
    addLabelIds: string[],
    removeLabelIds: string[],
    cycleId?: string
  ): string {
    const parts: string[] = [];
    const current = new Set(issue.labels.nodes.map((l) => l.id));

    const addCount = addLabelIds.filter((id) => !current.has(id)).length;
    if (addCount > 0) parts.push(`+${addCount} label(s)`);

    const removeCount = removeLabelIds.filter((id) => current.has(id)).length;
    if (removeCount > 0) parts.push(`-${removeCount} label(s)`);

    if (this.opts.setPriority !== undefined && this.opts.setPriority !== issue.priority) {
      parts.push(`priority ${issue.priority}→${this.opts.setPriority}`);
    }
    if (cycleId && cycleId !== issue.cycle?.id) parts.push(`cycle change`);

    return parts.length ? `(${parts.join(", ")})` : "";
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

// ====================================================================
// CLI
// ====================================================================

function printHelp(): void {
  console.log(`Uso: npx tsx batch-issues.ts [--action batch-update] --filter <json> [opciones]

Acciones:
  batch-update (default)   Único action soportado — aplicado si se omite --action, siempre que
                            haya flags accionables (retrocompatible con callers existentes).
                            Ejecuta vía issueBatchUpdate (lotes de hasta 50 ids/llamada) — no
                            N llamadas issueUpdate sueltas.

Opciones:
  --filter <json>           IssueFilter GraphQL, requerido (p.ej. '{"team":{"key":{"eq":"TAL"}}}')
  --add-labels a,b          Nombres de labels a añadir (→ addedLabelIds nativo, no labelIds completo)
  --remove-labels a,b       Nombres de labels a quitar (→ removedLabelIds nativo)
  --set-priority <0-4>      Priority nueva (0=None..4=Low)
  --set-cycle <id|current|next>
  --concurrency <n>         Entero 1-50. Lotes de issueBatchUpdate (≤50 ids c/u) en vuelo
                            simultáneamente. Default 5
  --dry-run                 Muestra el diff sin ejecutar
  --selftest                Corre los fixtures offline (resolución de labels fail-closed,
                            chunkIds, buildIssueBatchUpdateInput) y sale 0/1. No toca red ni
                            LINEAR_API_KEY
  --help, -h                Muestra esta ayuda y sale (no toca red ni LINEAR_API_KEY)

--set-state/--set-assignee NO están soportados (fail-closed) — usa issueUpdate directo por issue.`);
}

function parseArgs(argv: string[]): {
  help: boolean;
  selftest: boolean;
  action?: string;
  opts: BatchOptions;
} {
  const opts: any = {
    filter: null,
    dryRun: false,
    concurrency: 5,
  };
  let help = false;
  // selftest es un MODO del CLI (como --help), no una opción del batch: vive fuera de
  // BatchOptions para no contaminar el contrato operacional (y su typecheck).
  let selftest = false;
  let action: string | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];

    if (arg === "--help" || arg === "-h") {
      help = true;
    } else if (arg === "--selftest") {
      selftest = true;
    } else if (arg === "--action") {
      action = next;
      i++;
    } else if (arg === "--filter") {
      opts.filter = JSON.parse(next);
      i++;
    } else if (arg === "--dry-run") {
      opts.dryRun = true;
    } else if (arg === "--concurrency") {
      // Fail-closed ANTES de credenciales/red: parseInt tolera sufijos ("1x"→1) y 0/negativo
      // cuelga el loop de run() (i += concurrency). Solo se acepta un entero decimal entre
      // 1 y 50 (cap operacional: por encima solo se golpea el rate limit de la API).
      if (next === undefined || !/^[1-9][0-9]*$/.test(next) || parseInt(next, 10) > 50) {
        throw new Error(
          `--concurrency debe ser un entero decimal entre 1 y 50 (recibido: ${next === undefined ? "<ausente>" : `"${next}"`})`
        );
      }
      opts.concurrency = parseInt(next, 10);
      i++;
    } else if (arg === "--add-labels") {
      opts.addLabels = next.split(",");
      i++;
    } else if (arg === "--remove-labels") {
      opts.removeLabels = next.split(",");
      i++;
    } else if (arg === "--set-priority") {
      opts.setPriority = parseInt(next, 10);
      i++;
    } else if (arg === "--set-cycle") {
      opts.setCycle = next;
      i++;
    } else if (arg === "--set-state" || arg === "--set-assignee") {
      // computeUpdate() solo aplica labels/priority/cycle. Aceptar estos flags en silencio dejaría
      // un no-op invisible (el operador cree que cambió state/assignee y no cambió nada). Fail-closed:
      // para cambiar estado o assignee en lote, iterar `issueUpdate(id, { stateId|assigneeId })` a mano.
      throw new Error(
        `${arg} no está implementado en este script (solo aplica labels/priority/cycle). ` +
          `Para state/assignee usa issueUpdate directo por issue.`
      );
    } else if (arg.startsWith("--")) {
      // Fail-closed: un flag desconocido (p.ej. --set-project) NO debe pasar como éxito silencioso
      // sin aplicarse. Aborta con error en vez de ignorarlo.
      throw new Error(`flag desconocido: ${arg} (no reconocido por parseArgs)`);
    }
  }

  if (help || selftest) return { help, selftest, action, opts };

  // --action es opcional (retrocompatibilidad): si se omite, se asume "batch-update" — el único
  // action soportado — SIN imprimir ayuda-y-salir-0, para no convertir un caller existente que
  // pasa --filter sin --action en un no-op silencioso con exit 0.
  if (action !== undefined && action !== "batch-update") {
    throw new Error(`action desconocida: "${action}" (solo se soporta "batch-update")`);
  }

  if (!opts.filter) {
    throw new Error("--filter is required");
  }

  return { help, selftest, action: action ?? "batch-update", opts };
}

if (require.main === module) {
  // Los errores de parseArgs son ERRORES DE USO: se reportan limpios y con exit 2 ANTES de
  // consultar LINEAR_API_KEY o tocar red (un argv inválido jamás llega a credenciales).
  let parsed: ReturnType<typeof parseArgs>;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`Error de uso: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(2);
  }
  const { help, selftest, opts } = parsed;
  if (help) {
    printHelp();
    process.exit(0);
  }

  if (selftest) {
    // Fixtures offline de buildLabelIdMap (cero red, cero credenciales).
    const NODES = [
      { id: "u-1", name: "kind:fix", team: null },
      { id: "u-2", name: "vertical/fabrica", team: { key: "TAL" } },
      { id: "u-3", name: "vertical/fabrica", team: { key: "BUG" } },
    ];
    let pass = 0;
    let failCount = 0;
    const caso = (nombre: string, fn: () => void) => {
      try {
        fn();
        pass++;
        console.log(`PASS ${nombre}`);
      } catch (e) {
        failCount++;
        console.error(`FAIL ${nombre}: ${e instanceof Error ? e.message : e}`);
      }
    };
    const debeLanzar = (fn: () => void, fragmento: string) => {
      try {
        fn();
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (msg.includes(fragmento)) return;
        throw new Error(`lanzó, pero sin "${fragmento}": ${msg}`);
      }
      throw new Error("no lanzó y debía");
    };
    caso("nombre único → UUID correcto", () => {
      const m = buildLabelIdMap(NODES, ["kind:fix"]);
      if (m.get("kind:fix") !== "u-1") throw new Error(`id inesperado: ${m.get("kind:fix")}`);
    });
    caso("nombre duplicado por team → aborta con sites y sin mutación", () => {
      debeLanzar(() => buildLabelIdMap(NODES, ["vertical/fabrica"]), "resolución ambigua");
    });
    caso("nombre inexistente → aborta", () => {
      debeLanzar(() => buildLabelIdMap(NODES, ["kind:noexiste"]), "not found");
    });
    caso("duplicado NO pedido no contamina la resolución del resto", () => {
      const m = buildLabelIdMap(NODES, ["kind:fix"]);
      if (m.size !== 1) throw new Error(`map size ${m.size}`);
    });
    caso("chunkIds trocea en lotes de 50 (tope de issueBatchUpdate), preserva orden", () => {
      const ids = Array.from({ length: 120 }, (_, i) => `id-${i}`);
      const chunks = chunkIds(ids, 50);
      if (chunks.length !== 3) throw new Error(`chunks=${chunks.length} (esperado 3)`);
      if (chunks[0].length !== 50 || chunks[1].length !== 50 || chunks[2].length !== 20) {
        throw new Error(`tamaños: ${chunks.map((c) => c.length).join(",")} (esperado 50,50,20)`);
      }
      if (chunks.flat().join(",") !== ids.join(",")) {
        throw new Error("chunkIds alteró el orden/contenido de los ids");
      }
    });
    caso("buildIssueBatchUpdateInput mapea a addedLabelIds/removedLabelIds nativos", () => {
      const input = buildIssueBatchUpdateInput({
        addLabelIds: ["lbl-a"],
        removeLabelIds: ["lbl-b"],
        setPriority: 2,
        cycleId: "cyc-1",
      });
      if (JSON.stringify(input.addedLabelIds) !== JSON.stringify(["lbl-a"])) {
        throw new Error(`addedLabelIds incorrecto: ${JSON.stringify(input.addedLabelIds)}`);
      }
      if (JSON.stringify(input.removedLabelIds) !== JSON.stringify(["lbl-b"])) {
        throw new Error(`removedLabelIds incorrecto: ${JSON.stringify(input.removedLabelIds)}`);
      }
      if (input.priority !== 2) throw new Error(`priority incorrecto: ${input.priority}`);
      if (input.cycleId !== "cyc-1") throw new Error(`cycleId incorrecto: ${input.cycleId}`);
      // labelIds NUNCA debe aparecer — buildIssueBatchUpdateInput solo produce campos nativos.
      if ("labelIds" in input) throw new Error("no debe incluir labelIds (solo addedLabelIds/removedLabelIds)");
    });
    caso("buildIssueBatchUpdateInput sin labels/priority/cycle → objeto vacío (no-op)", () => {
      const input = buildIssueBatchUpdateInput({ addLabelIds: [], removeLabelIds: [] });
      if (Object.keys(input).length !== 0) throw new Error(`esperado {} , obtuvo ${JSON.stringify(input)}`);
    });
    console.log(`SELFTEST: PASS=${pass} FAIL=${failCount}`);
    process.exit(failCount === 0 ? 0 : 1);
  }

  // Misma resolución que linear-client.ts: LINEAR_API_KEY > fichero de TA_OPERATION_ENV > .env.local de la raíz.
  let apiKey: string;
  try {
    apiKey = loadApiKey();
  } catch (err) {
    console.error(`Sin clave de Linear: ${(err as Error).message}`);
    process.exit(1);
  }

  const client = new LinearMinClient({ apiKey });
  const executor = new BatchExecutor(client, opts);

  executor.run().catch((err) => {
    console.error("Fatal error:", err);
    process.exit(1);
  });
}
