#!/usr/bin/env npx tsx
/**
 * issue_craft_helper.ts — auditor y aprovisionador del skill talent-issue-craft.
 *
 * Acciones:
 *   list-types   (READ-ONLY, 100% local) Imprime la matriz sellada type × variant
 *                (14 combinaciones válidas). NUNCA exige credenciales.
 *   audit-issue  (READ-ONLY) Audita una issue contra la doctrina del skill (fail-closed):
 *                  --issue <id>   evidencia REMOTA completa (body + propiedades +
 *                                 relaciones) vía API GraphQL de Linear. Única entrada
 *                                 que puede acreditar el gate operativo.
 *                  --file <ruta>  modo BODY-ONLY (autoría/pre-check): parsea, clasifica
 *                                 y corre los checks verificables desde el body. NUNCA
 *                                 acredita el gate (operational_gate_eligible=false).
 *   provision-templates  Aprovisiona las 9 plantillas de tipo como Templates nativos
 *                del tracker (shape de templateData CONGELADO por sonda round-trip —
 *                ver references/03-linear-nativo.md §3.6). Ámbito: EXACTAMENTE uno de
 *                  --team <key>          Templates del equipo (visibles solo en él)
 *                  --global              Templates GLOBALES de workspace (sin teamId;
 *                                        visibles en TODOS los equipos)
 *                Modos:
 *                  --dry-run (DEFAULT)   imprime los payloads GraphQL exactos y corre el
 *                                        contract-check contra el shape congelado.
 *                                        SIN red, SIN credenciales, CERO mutaciones.
 *                  --apply               ÚNICA vía de escritura (templateCreate): exige
 *                                        credenciales, resuelve key→UUID si hay --team
 *                                        (la validación del API exige UUID), OMITE los
 *                                        templates cuyo nombre ya exista en ese ámbito
 *                                        (jamás pisa), y queda sujeta a la política de
 *                                        mutación del repo (GO del responsable ANTES).
 *
 * Contratos de salida (siempre presentes en el resumen):
 *   classification_source=marker|override   quién clasificó (autoridad)
 *     (estado de ERROR documentado: ante CLASIFICACION-FALLIDA la salida de error
 *      emite classification_source=n/a y exit != 0 — no hay resumen normal)
 *   input_source=remote|file                qué evidencia se pudo observar
 *   operational_gate_eligible=true|false    ¿esta corrida PUEDE acreditar el gate?
 *   Éxito del gate operativo = remote + marker + eligible=true + exit 0 (conjuntos).
 *   Cualquier check duro aplicable roto → exit != 0, independiente del score.
 *   Respuesta remota parcial / error del API → eligible=false + exit != 0.
 *
 * Uso CLI:
 *   npx tsx issue_craft_helper.ts --action list-types
 *   npx tsx issue_craft_helper.ts --action audit-issue --file examples/gold-fix.md
 *   npx tsx issue_craft_helper.ts --action audit-issue --issue ABC-123 --min-score 70
 *   npx tsx issue_craft_helper.ts --action audit-issue --issue ABC-9 --type db-ops   # override (calibración/histórico)
 *   npx tsx issue_craft_helper.ts --action provision-templates --team ABC             # dry-run (default)
 *   npx tsx issue_craft_helper.ts --action provision-templates --team ABC --apply     # escritura consciente
 *
 * Uso como módulo:
 *   import { auditBody, parseMarker, TYPE_MATRIX } from "./issue_craft_helper";
 *
 * Credenciales (PEREZOSAS — solo se cargan con --issue o con --apply): env
 * LINEAR_API_KEY, luego el fichero de TA_OPERATION_ENV si está definida (solo ese), y por
 * último un lector seguro de `.env.local` ascendiendo desde
 * el CWD (sin ejecutar el archivo; la key jamás pasa por argv ni se imprime). Sin
 * key cuando la acción la exige → error claro y exit 2.
 */

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import process from "node:process";

// ---------------------------------------------------------------------------
// Tipos y matriz sellada
// ---------------------------------------------------------------------------

export type TypeToken =
  | "feat" | "fix" | "db-ops" | "chore" | "refactor"
  | "test" | "docs-adr" | "spike-auditoria" | "contenido-datos";

export type VariantToken =
  | "none" | "db" | "seguridad" | "sev1" | "seguridad+sev1" | "doc-vivo";

export type Madurez = "placeholder" | "despachable";

export enum CircuitState { Closed = "closed", Open = "open", HalfOpen = "half-open" }

/** Matriz sellada: variantes permitidas por tipo. Toda otra combinación es INVÁLIDA. */
export const TYPE_MATRIX: Readonly<Record<TypeToken, readonly VariantToken[]>> = {
  feat: ["none", "db"],
  fix: ["none", "seguridad", "sev1", "seguridad+sev1"],
  chore: ["none", "doc-vivo"],
  "db-ops": ["none"],
  refactor: ["none"],
  test: ["none"],
  "docs-adr": ["none"],
  "spike-auditoria": ["none"],
  "contenido-datos": ["none"],
} as const;

export interface Marker { type: TypeToken; variant: VariantToken; madurez: Madurez }

export interface CheckResult {
  id: string;
  hard: boolean;
  passed: boolean;
  detail: string;
}

export interface RemoteEvidence {
  identifier: string;
  estimate: number | null;
  priority: number | null;
  labels: string[];
  project: string | null;
  stateName: string;
  activeBlockers: string[];
  complete: boolean;      // toda la evidencia consultada llegó sin huecos
  incompleteReason: string | null;
}

export interface AuditReport {
  checks: CheckResult[];
  classificationSource: "marker" | "override";
  inputSource: "remote" | "file";
  eligible: boolean;
  score: number;
  hardFailures: number;
  type: TypeToken;
  variant: VariantToken;
  madurez: Madurez;
  exitCode: number;
}

// ---------------------------------------------------------------------------
// CircuitBreaker + retry con backoff (para las llamadas remotas)
// ---------------------------------------------------------------------------

export class CircuitBreaker {
  private state: CircuitState = CircuitState.Closed;
  private failures = 0;
  private openedAt = 0;
  constructor(
    private readonly threshold = 4,
    private readonly cooldownMs = 15_000,
  ) {}
  canRequest(): boolean {
    if (this.state === CircuitState.Open) {
      if (Date.now() - this.openedAt >= this.cooldownMs) {
        this.state = CircuitState.HalfOpen;
        return true;
      }
      return false;
    }
    return true;
  }
  onSuccess(): void { this.state = CircuitState.Closed; this.failures = 0; }
  onFailure(): void {
    this.failures += 1;
    if (this.state === CircuitState.HalfOpen || this.failures >= this.threshold) {
      this.state = CircuitState.Open;
      this.openedAt = Date.now();
    }
  }
  get current(): CircuitState { return this.state; }
}

export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  breaker: CircuitBreaker,
  maxRetries = 3,
): Promise<T> {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < maxRetries; attempt += 1) {
    if (!breaker.canRequest()) {
      throw new Error(`circuito abierto (${breaker.current}): demasiados fallos consecutivos contra el API`);
    }
    try {
      const out = await fn();
      breaker.onSuccess();
      return out;
    } catch (err) {
      breaker.onFailure();
      lastError = err;
      const delay = 750 * 2 ** attempt;
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

// ---------------------------------------------------------------------------
// Credenciales perezosas (solo --issue y --apply)
// ---------------------------------------------------------------------------

/**
 * Lee LINEAR_API_KEY (sin ejecutar nada), por este orden: la variable exportada; si TA_OPERATION_ENV
 * está definida y no vacía, el fichero al que apunta y SOLO ese (si falta o no trae la clave es un
 * error con la ruta y la variable, nunca una caída en silencio al cwd); si no, un .env.local
 * ascendiendo desde cwd. Los mensajes nombran rutas y variables, jamás la clave.
 */
export function loadApiKey(startDir = process.cwd(), env: NodeJS.ProcessEnv = process.env): string {
  const fromEnv = env.LINEAR_API_KEY;
  if (fromEnv && fromEnv.trim() !== "") return fromEnv.trim();
  const operationEnv = env.TA_OPERATION_ENV;
  if (operationEnv !== undefined && operationEnv !== "") {
    let isFile = false;
    try {
      isFile = statSync(operationEnv).isFile();
    } catch {
      isFile = false;
    }
    if (!isFile) {
      throw new Error(
        `TA_OPERATION_ENV apunta a ${operationEnv}, que no existe o no es un fichero: ahí debe estar LINEAR_API_KEY=<clave>`,
      );
    }
    let operationText: string;
    try {
      operationText = readFileSync(operationEnv, "utf8");
    } catch {
      throw new Error(`no se pudo leer ${operationEnv} (apuntado por TA_OPERATION_ENV)`);
    }
    const operationLine = operationText.split("\n").find((l) => /^LINEAR_API_KEY=.+/.test(l));
    const operationKey = operationLine ? operationLine.slice(operationLine.indexOf("=") + 1).trim() : "";
    if (operationKey === "") {
      throw new Error(`${operationEnv} (apuntado por TA_OPERATION_ENV) no tiene LINEAR_API_KEY=<clave>`);
    }
    return operationKey;
  }
  let dir = resolve(startDir);
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = join(dir, ".env.local");
    if (existsSync(candidate)) {
      const line = readFileSync(candidate, "utf8")
        .split("\n")
        .find((l) => /^LINEAR_API_KEY=.+/.test(l));
      if (line) return line.slice(line.indexOf("=") + 1).trim();
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(
    "LINEAR_API_KEY no disponible: exporta la variable, apunta TA_OPERATION_ENV a un fichero que la " +
    "declare o declárala en un .env.local " +
    "alcanzable desde el directorio actual. (Solo se exige para --issue y --apply; " +
    "list-types, --file y --dry-run son 100% locales.)",
  );
}

// ---------------------------------------------------------------------------
// Parsing del body
// ---------------------------------------------------------------------------

const MARKER_RE =
  /<!--\s*issue-craft:v1\s+type=([^\s]+)\s+variant=([^\s]+)\s+madurez=([^\s]+)\s*-->/;

/**
 * Autoridad UNÍVOCA y POSICIONAL (fail-closed):
 *  - exactamente UN marcador en todo el body (dos marcadores = ambigüedad → error);
 *  - el marcador es la PRIMERA línea completa del body (texto antes = error).
 */
export function parseMarker(body: string): Marker | { error: string } {
  const occurrences = body.match(new RegExp(MARKER_RE.source, "g")) ?? [];
  if (occurrences.length === 0) return { error: "marcador issue-craft:v1 ausente o malformado" };
  if (occurrences.length > 1) {
    return { error: `marcadores issue-craft:v1 MULTIPLES (${occurrences.length}): la autoridad debe ser unívoca` };
  }
  const firstLine = (body.split("\n", 1)[0] ?? "").replace(/^﻿/, "").trim();
  const anchored = new RegExp(`^${MARKER_RE.source}$`);
  if (!anchored.test(firstLine)) {
    return { error: "el marcador issue-craft:v1 debe ser la PRIMERA línea completa del body (marcador tardío = malformado)" };
  }
  const m = MARKER_RE.exec(firstLine);
  if (!m) return { error: "marcador issue-craft:v1 ausente o malformado" };
  const [, t, v, mad] = m;
  if (!(t in TYPE_MATRIX)) return { error: `type desconocido: ${t}` };
  const type = t as TypeToken;
  const allowed = TYPE_MATRIX[type];
  if (!allowed.includes(v as VariantToken)) {
    return { error: `variant inválida para ${type}: ${v} (permitidas: ${allowed.join(" | ")})` };
  }
  if (mad !== "placeholder" && mad !== "despachable") {
    return { error: `madurez desconocida: ${mad}` };
  }
  return { type, variant: v as VariantToken, madurez: mad };
}

function sectionPresent(body: string, heading: string): boolean {
  return body.includes(heading);
}

/** Cuerpo de una sección `## X` hasta el siguiente `## ` (o fin de body). */
export function sectionBody(body: string, heading: string): string {
  const at = body.startsWith(heading) ? 0 : body.indexOf(`\n${heading}`);
  if (at === -1) return "";
  const from = (at === 0 ? 0 : at + 1) + heading.length;
  const next = body.indexOf("\n## ", from);
  return next === -1 ? body.slice(from) : body.slice(from, next);
}

/**
 * Valores CENTINELA que no cuentan como contenido real en los duros de forma
 * poblada (B9-B12). Lista CERRADA y documentada — validación de forma, no
 * interpretación semántica: "N/A", "ninguno", "ok", "tbd"… son huecos con disfraz.
 */
const SENTINEL_VALUES: ReadonlySet<string> = new Set([
  "ninguno", "ninguna", "na", "n/a", "tbd", "todo", "pendiente", "ok",
  "x", "-", "—", "si", "sí", "no", "true", "false",
]);

function normalizeCell(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[`*_.,;:!¡¿?()[\]{}]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** ¿El contenido es vacío o un valor centinela (sin valor informativo real)? */
export function isSentinel(raw: string): boolean {
  const n = normalizeCell(raw);
  return n === "" || SENTINEL_VALUES.has(n);
}

/**
 * Filas de DATOS reales en tablas markdown de una sección: descarta separadores
 * (`|---|`), cabeceras conocidas, filas-placeholder cuya primera celda abre con `[`
 * y filas cuya primera celda es un valor centinela ("N/A", "-", "TBD"…).
 * Validación de FORMA machine-readable — no interpreta semántica.
 */
export function tableDataRows(section: string, headerFirstCells: readonly string[]): number {
  return section.split("\n").filter((line) => {
    const t = line.trim();
    if (!t.startsWith("|")) return false;
    if (/^\|[\s\-:|]+\|?$/.test(t)) return false;
    const first = (t.split("|")[1] ?? "").trim();
    if (first === "" || first.startsWith("[")) return false;
    if (headerFirstCells.includes(first)) return false;
    if (isSentinel(first)) return false;
    return true;
  }).length;
}

// Cláusulas del núcleo verificables en el body (las 15 textuales; el marcador va aparte).
// DERIVADAS de templates/nucleo-manifest.txt (fuente de verdad única) para cerrar el
// drift de 3ª copia: mismo conjunto que consume check_nucleo_parity.sh.
// Fail-closed: manifest ausente/vacío/sin cláusulas -> throw (nunca audita contra un
// núcleo vacío). Anclado por import.meta.url (no process.argv[1]) para resolver
// correctamente tanto en direct-run como al importarse como módulo.
const NUCLEO_MANIFEST_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "templates",
  "nucleo-manifest.txt",
);

function loadNucleoClauses(manifestPath: string): readonly string[] {
  if (!existsSync(manifestPath)) {
    throw new Error(`nucleo-manifest ausente: ${manifestPath}`);
  }
  // Espeja el conjunto B de check_nucleo_parity.sh (excluye comentarios "#"/"# " —
  // un heading "## ..." NO es comentario— y líneas EXCEPT/vacías) y además excluye
  // el marcador <!-- issue-craft:v1, que el helper trata aparte (parseMarker).
  const clauses = readFileSync(manifestPath, "utf8")
    .split("\n")
    .map((line) => line.replace(/\r$/, ""))
    .filter((line) => {
      if (line.trim() === "") return false;
      if (line === "#" || line.startsWith("# ")) return false;
      if (line.startsWith("EXCEPT ")) return false;
      if (line.startsWith("<!-- issue-craft:v1")) return false;
      return true;
    });
  if (clauses.length === 0) {
    throw new Error(`nucleo-manifest sin cláusulas: ${manifestPath}`);
  }
  return clauses;
}

// Lazy + memoizado: el manifiesto NO se lee al importar el módulo — parseMarker y demás
// utilidades deben poder importarse sin él. El load fail-closed (throw si ausente/vacío/sin
// cláusulas) ocurre en el PRIMER uso (auditBody), no en import-time.
let nucleoClausesCache: readonly string[] | undefined;
function getNucleoClauses(): readonly string[] {
  if (nucleoClausesCache === undefined) {
    nucleoClausesCache = loadNucleoClauses(NUCLEO_MANIFEST_PATH);
  }
  return nucleoClausesCache;
}

// Secciones-clave del overlay por (type, variant) — presencia = duro.
const OVERLAY_KEYS: Readonly<Record<string, readonly string[]>> = {
  "feat": ["## Contrato de comportamiento"],
  "feat+db": ["## Contrato de comportamiento", "Bloque DB"],
  "fix": ["Esperado", "Observado", "Causa raíz", "Inventario de la clase"],
  "fix+seguridad": ["Esperado", "Observado", "Causa raíz", "Inventario de la clase", "exploit"],
  "fix+sev1": ["Esperado", "Observado", "Causa raíz", "producción"],
  "fix+seguridad+sev1": ["Esperado", "Observado", "Causa raíz", "exploit", "producción"],
  "db-ops": ["Verificación en 5 minutos", "Contraargumento", "Qué NO tocar"],
  "chore": ["## Cambios por archivo", "Qué se conserva"],
  "chore+doc-vivo": ["## Cambios por archivo", "Qué NO tocar", "Fuentes de verdad"],
  "refactor": ["Caracterización previa", "Métrica antes/después"],
  "test": ["Prueba de que la red falta", "Deslinde de suites", "mutación"],
  "docs-adr": ["Doc contra código real", "Régimen de cierre"],
  "spike-auditoria": ["DIFF-CERO", "Formato del entregable"],
  "contenido-datos": ["## Destino", "idempotente", "Verificación post-escritura"],
};

// Tipos que exigen criterio por mutación en el DoD.
const MUTATION_TYPES: ReadonlySet<string> = new Set(["fix", "test"]);

// Residuo de plantilla sin rellenar (duro: la issue no está terminada de escribir).
const PLACEHOLDER_RESIDUE: readonly string[] = [
  "{Imperativo}", "[comando]", "[salida esperada]", "(AAAA-MM-DD)", "`<sha>`",
];

function overlayKeyFor(type: TypeToken, variant: VariantToken): string {
  return variant === "none" ? type : `${type}+${variant}`;
}

// ---------------------------------------------------------------------------
// Motor de auditoría (capa issue)
// ---------------------------------------------------------------------------

export function auditBody(
  body: string,
  marker: Marker,
  classificationSource: "marker" | "override",
): CheckResult[] {
  const checks: CheckResult[] = [];
  const push = (id: string, hard: boolean, passed: boolean, detail: string): void => {
    checks.push({ id, hard, passed, detail });
  };

  if (marker.madurez === "placeholder") {
    // Forma placeholder: mínima a propósito; NUNCA despachable.
    const lines = body.split("\n").filter((l) => l.trim() !== "").length;
    push("PH1-forma-minima", true, lines <= 8, `placeholder con ${lines} líneas no vacías (máx 8)`);
    push("PH2-sin-detalle-caro", true, !body.includes("- [ ]"), "placeholder no lleva DoD/checkboxes");
    push("PH3-origen", false, /https?:\/\//.test(body), "placeholder enlaza su origen");
    push("PH4-no-despachable", true, false, "madurez=placeholder NUNCA supera el gate de despacho (completar la plantilla del tipo)");
    return checks;
  }

  // B2 — cláusulas del núcleo
  for (const clause of getNucleoClauses()) {
    push(`B2-clausula`, true, sectionPresent(body, clause), `cláusula presente: ${clause}`);
  }

  // B4 — ninguna decisión diferida con "Bloquea TODO" activa
  const bloqueaTodo = /\|\s*bloquea todo\s*\|/i.test(body);
  push("B4-bloquea-todo", true, !bloqueaTodo, "sin decisiones diferidas que bloquean TODO (si la hay, la issue no despacha)");

  // B5 — DoD ejecutable: al menos un checkbox con comando
  const dodExecutable = /- \[ \][^\n]*`[^`]+`/.test(body);
  push("B5-dod-ejecutable", true, dodExecutable, "el DoD tiene ≥1 checkbox con comando ejecutable");

  // B6 — sin residuo de plantilla
  const residue = PLACEHOLDER_RESIDUE.filter((p) => body.includes(p));
  push("B6-sin-residuo", true, residue.length === 0,
    residue.length === 0 ? "sin huecos de plantilla sin rellenar" : `residuo de plantilla: ${residue.join(", ")}`);

  // B7 — overlay del tipo/variante
  const keys = OVERLAY_KEYS[overlayKeyFor(marker.type, marker.variant)] ?? [];
  for (const k of keys) {
    push("B7-overlay", true, body.includes(k), `sección/señal del overlay presente: ${k}`);
  }

  // B8 — criterio por mutación donde aplica
  if (MUTATION_TYPES.has(marker.type)) {
    push("B8-mutacion", true, /mutaci/i.test(body), "el DoD exige el criterio por mutación (rojo→revertir→verde)");
  }

  // B9-B12 — DUROS de forma poblada (anti-esqueleto): headings presentes con
  // contenido machine-readable real, no carcasas. Sin interpretar semántica libre.
  const decSec = sectionBody(body, "## Decisiones");
  const decRows = tableDataRows(decSec, ["Parámetro", "Decisión", "Cuestión"]);
  const decNone = /\bninguna\b/i.test(decSec);
  push("B9-decisiones-pobladas", true, decRows > 0 || decNone,
    decRows > 0
      ? `régimen de decisiones poblado (${decRows} fila(s) de datos)`
      : decNone
        ? "ausencia de decisiones declarada explícitamente"
        : "las tres tablas de Decisiones están VACÍAS y no hay declaración explícita de ausencia");

  // Bullets `-`/`*`/`+`: los trackers normalizan el estilo al round-trip (p. ej.
  // Linear devuelve `*` donde se escribió `-`) — el check tolera los tres.
  // Path REAL = `/` o `.` ENTRE caracteres de palabra (extensión/ruta), nunca la
  // puntuación final de un centinela ("Ninguno." no es un artefacto).
  const artSec = sectionBody(body, "## Artefactos tocados");
  const artOk = artSec.split("\n").some((l) => {
    const t = l.trim();
    if (!/^[-*+]\s+/.test(t)) return false;
    const content = t.replace(/^[-*+]\s+/, "");
    if (content.startsWith("[") || isSentinel(content)) return false;
    return /\w\/\w|\w\.\w/.test(content);
  });
  push("B10-artefactos-poblados", true, artOk, "Artefactos tocados contiene ≥1 path/recurso real (no placeholder ni centinela)");

  const invSec = sectionBody(body, "## Invariantes que NO deben cambiar");
  const invMentions = invSec.match(/(?:lo prueba|referencia):[^\n]*/gi) ?? [];
  const invOk = invMentions.some((m) => {
    const content = m.replace(/^(?:lo prueba|referencia):\s*/i, "").trim();
    if (content.startsWith("[") || isSentinel(content)) return false;
    return normalizeCell(content).length >= 4;
  });
  push("B11-invariante-con-suite", true, invOk, "≥1 invariante nombra su suite/comando/referencia real (\"lo prueba:\" / \"referencia:\" — sin centinelas)");

  const evSec = sectionBody(body, "## Evidencias de cierre exigidas");
  const evRows = tableDataRows(evSec, ["Criterio"]);
  push("B12-evidencias-pobladas", true, evRows > 0, `tabla de evidencias con ${evRows} fila(s) de datos reales`);

  // Señales (🟡 → cuentan para el score, no vetan)
  push("S1-anclas-con-extracto", false, /##\s*Anclas de contexto[\s\S]*?>\s/.test(body), "las anclas incluyen extracto literal");
  push("S3-fuera-con-destino", false, /###\s*Fuera de alcance[\s\S]*?→/.test(body), "cada exclusión tiene destino");
  push("S4-origen-enlazado", false, /https?:\/\//.test(body), "el origen está enlazado");
  push("S6-decisiones-selladas", false, /###\s*Selladas[\s\S]*?\|\s*\S+[\s\S]*?\|/.test(body), "hay al menos una decisión sellada registrada");

  // Clasificación por override = señal informativa (nunca acredita el gate).
  if (classificationSource === "override") {
    push("S7-override", false, false, "clasificación por override: solo calibración/auditoría histórica");
  }
  return checks;
}

export function auditRemoteEvidence(marker: Marker, ev: RemoteEvidence): CheckResult[] {
  const checks: CheckResult[] = [];
  const push = (id: string, hard: boolean, passed: boolean, detail: string): void => {
    checks.push({ id, hard, passed, detail });
  };
  push("R0-evidencia-completa", true, ev.complete,
    ev.complete ? "respuesta remota completa" : `evidencia remota INCOMPLETA: ${ev.incompleteReason ?? "desconocido"}`);
  if (!ev.complete) return checks; // fail-closed: sin evidencia completa no se evalúa el resto como fiable

  if (marker.type !== "contenido-datos") {
    push("R1-estimate", true, ev.estimate !== null && ev.estimate > 0, `estimate=${String(ev.estimate)}`);
  }
  push("R2-prioridad", true, ev.priority !== null && ev.priority > 0, `priority=${String(ev.priority)} (0=None no vale)`);
  push("R3-etiquetas", true, ev.labels.length > 0, `etiquetas=${ev.labels.length}`);
  push("R4-proyecto", true, ev.project !== null, `proyecto=${ev.project ?? "(ninguno)"}`);
  push("R5-sin-bloqueos-activos", true, ev.activeBlockers.length === 0,
    ev.activeBlockers.length === 0 ? "sin bloqueos activos" : `bloqueada por: ${ev.activeBlockers.join(", ")} (issue bien escrita ≠ despachable)`);
  return checks;
}

export function summarize(
  checks: CheckResult[],
  classificationSource: "marker" | "override",
  inputSource: "remote" | "file",
  remoteComplete: boolean,
  minScore: number,
  marker: Marker,
): AuditReport {
  const applicable = checks.length;
  const passed = checks.filter((c) => c.passed).length;
  const hardFailures = checks.filter((c) => c.hard && !c.passed).length;
  const score = applicable === 0 ? 0 : Math.round((passed / applicable) * 100);
  const eligible = inputSource === "remote" && classificationSource === "marker" && remoteComplete;
  const gateOk = hardFailures === 0 && score >= minScore && (inputSource === "file" || remoteComplete);
  return {
    checks,
    classificationSource,
    inputSource,
    eligible,
    score,
    hardFailures,
    type: marker.type,
    variant: marker.variant,
    madurez: marker.madurez,
    exitCode: gateOk ? 0 : 1,
  };
}

// ---------------------------------------------------------------------------
// Evidencia remota (GraphQL de Linear)
// ---------------------------------------------------------------------------

const AUDIT_QUERY = `query Audit($id: String!) {
  issue(id: $id) {
    identifier title description estimate priority
    state { name type }
    project { name } projectMilestone { name }
    labels { nodes { name } }
    relations { nodes { type relatedIssue { identifier state { type } } } }
    inverseRelations { nodes { type issue { identifier state { type } } } }
  }
}`;

interface GqlRelationNode { type: string; issue?: { identifier: string; state: { type: string } } | null; relatedIssue?: { identifier: string; state: { type: string } } | null }
interface GqlIssue {
  identifier: string; title: string; description: string | null;
  estimate: number | null; priority: number | null;
  state: { name: string; type: string } | null;
  project: { name: string } | null;
  labels: { nodes: Array<{ name: string }> } | null;
  relations: { nodes: GqlRelationNode[] } | null;
  inverseRelations: { nodes: GqlRelationNode[] } | null;
}

export async function fetchRemoteIssue(
  issueId: string,
  apiKey: string,
  breaker = new CircuitBreaker(),
): Promise<{ body: string; evidence: RemoteEvidence }> {
  const doFetch = async (): Promise<{ body: string; evidence: RemoteEvidence }> => {
    const res = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: apiKey },
      body: JSON.stringify({ query: AUDIT_QUERY, variables: { id: issueId } }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} del API`);
    const parsed = (await res.json()) as { data?: { issue?: GqlIssue | null }; errors?: Array<{ message: string }> };
    if (parsed.errors && parsed.errors.length > 0) {
      // Error GraphQL → evidencia NO fiable → fail-closed aguas arriba.
      return {
        body: "",
        evidence: {
          identifier: issueId, estimate: null, priority: null, labels: [], project: null,
          stateName: "", activeBlockers: [], complete: false,
          incompleteReason: `errores GraphQL: ${parsed.errors.map((e) => e.message).join("; ")}`,
        },
      };
    }
    const issue = parsed.data?.issue ?? null;
    if (issue === null) {
      return {
        body: "",
        evidence: {
          identifier: issueId, estimate: null, priority: null, labels: [], project: null,
          stateName: "", activeBlockers: [], complete: false,
          incompleteReason: "la issue no existe o el token no puede leerla",
        },
      };
    }
    const missing: string[] = [];
    if (issue.description === null || issue.description === "") missing.push("description");
    if (issue.state === null) missing.push("state");
    if (issue.labels === null) missing.push("labels");
    if (issue.inverseRelations === null) missing.push("inverseRelations");
    const blockers = (issue.inverseRelations?.nodes ?? [])
      .filter((n) => n.type === "blocks" && n.issue != null)
      .filter((n) => {
        const st = n.issue?.state.type ?? "";
        return st !== "completed" && st !== "canceled";
      })
      .map((n) => n.issue?.identifier ?? "?");
    return {
      body: issue.description ?? "",
      evidence: {
        identifier: issue.identifier,
        estimate: issue.estimate,
        priority: issue.priority,
        labels: (issue.labels?.nodes ?? []).map((l) => l.name),
        project: issue.project?.name ?? null,
        stateName: issue.state?.name ?? "",
        activeBlockers: blockers,
        complete: missing.length === 0,
        incompleteReason: missing.length > 0 ? `campos ausentes en la respuesta: ${missing.join(", ")}` : null,
      },
    };
  };
  return retryWithBackoff(doFetch, breaker);
}

// ---------------------------------------------------------------------------
// Aprovisionamiento de Templates nativos (shape congelado por sonda — 03 §3.6)
// ---------------------------------------------------------------------------

/**
 * Contrato de ESCRITURA congelado de `templateData` (sonda round-trip
 * create→read→delete). El API acepta un OBJETO JSON con EXACTAMENTE estas
 * claves; `description` es markdown plano que el servidor normaliza a
 * rich-text (`descriptionData`) — el round-trip es semántico, NO textual.
 */
export const TEMPLATE_DATA_WRITE_KEYS: readonly string[] = ["title", "description"];

export const TEMPLATE_CREATE_MUTATION =
  "mutation ProvisionTemplate($input: TemplateCreateInput!) { templateCreate(input: $input) { success template { id name } } }";
export const TEAM_RESOLVE_QUERY =
  "query ResolveTeam($key: String!) { teams(filter: { key: { eq: $key } }) { nodes { id key } } }";
export const TEMPLATE_CENSUS_QUERY =
  "query TemplateCensus { templates { id name team { key } } }";

// La validación del API exige UUID en teamId (rechaza el key del equipo).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Mapa canónico filename → type. El conjunto de plantillas aprovisionables es
 * EXACTAMENTE este (cardinalidad 9, una por tipo); el contract-check exige
 * además que el marcador del cuerpo coincida con el tipo del archivo.
 */
export const TEMPLATE_FILE_TYPE_MAP: Readonly<Record<string, TypeToken>> = {
  "01-feat.md": "feat",
  "02-fix.md": "fix",
  "03-db-ops.md": "db-ops",
  "04-chore.md": "chore",
  "05-refactor.md": "refactor",
  "06-test.md": "test",
  "07-docs-adr.md": "docs-adr",
  "08-spike-auditoria.md": "spike-auditoria",
  "09-contenido-datos.md": "contenido-datos",
} as const;

/** Desviaciones de CONJUNTO contra el mapa canónico: faltantes y extras. */
export function checkTemplateSet(templatesDir: string): string[] {
  const found = readdirSync(templatesDir)
    .filter((f) => /^0[1-9]-[a-z-]+\.md$/.test(f))
    .sort();
  const expected = Object.keys(TEMPLATE_FILE_TYPE_MAP).sort();
  const dev: string[] = [];
  for (const e of expected) {
    if (!found.includes(e)) dev.push(`falta la plantilla canónica: ${e}`);
  }
  for (const f of found) {
    if (!(f in TEMPLATE_FILE_TYPE_MAP)) dev.push(`archivo fuera del conjunto canónico de 9: ${f}`);
  }
  return dev;
}

export interface TemplateProvisionPayload {
  sourceFile: string;
  input: {
    type: "issue";
    // Ausente = template GLOBAL de workspace (visible en todos los equipos).
    // Por equipo: "<uuid-de:KEY>" en dry-run; UUID real en --apply.
    teamId?: string;
    name: string;
    description: string;
    templateData: { title: string; description: string };
    sortOrder: number;
  };
}

export interface ProvisionResult {
  mode: "dry-run" | "apply";
  teamKey: string | null; // null = ámbito global de workspace
  payloads: TemplateProvisionPayload[];
  deviations: Array<{ file: string; issues: string[] }>;
  created: string[];
  skipped: string[];
  failed: Array<{ file: string; error: string }>;
  exitCode: number;
}

/**
 * Construye un payload `templateCreate` por cada `templates/0N-*.md` (9 plantillas
 * de tipo). El primer heading `# …` del archivo pasa al `templateData.title`
 * (patrón de título del tipo) y se retira del cuerpo — el marcador issue-craft:v1
 * queda como PRIMERA línea del cuerpo, que es lo que hereda toda issue creada
 * desde el template.
 */
export function buildTemplatePayloads(templatesDir: string, teamRef: string | null): TemplateProvisionPayload[] {
  const files = readdirSync(templatesDir)
    .filter((f) => /^0[1-9]-[a-z-]+\.md$/.test(f))
    .sort();
  return files.map((file) => {
    const raw = readFileSync(join(templatesDir, file), "utf8");
    const lines = raw.split("\n");
    const titleIdx = lines.findIndex((l) => l.startsWith("# "));
    const title = titleIdx >= 0 ? lines[titleIdx].slice(2).trim() : "{Imperativo} {qué} ({dónde})";
    const bodyLines = [...lines];
    if (titleIdx >= 0) {
      bodyLines.splice(titleIdx, 1);
      if ((bodyLines[titleIdx] ?? "") === "" && (bodyLines[titleIdx - 1] ?? "") === "") {
        bodyLines.splice(titleIdx, 1); // colapsa la doble línea vacía que deja el heading
      }
    }
    const body = `${bodyLines.join("\n").trimEnd()}\n`;
    const meta = (lines[1] ?? "").replace(/^<!--\s*/, "").replace(/\s*-->\s*$/, "").trim();
    const typeToken = file.slice(3).replace(/\.md$/, "");
    return {
      sourceFile: file,
      input: {
        type: "issue" as const,
        // Sin teamId el API crea el template GLOBAL de workspace (§3.6).
        ...(teamRef !== null ? { teamId: teamRef } : {}),
        name: `issue-craft: ${typeToken}`,
        description: meta !== "" ? meta : `Plantilla ${file} del sistema issue-craft`,
        templateData: { title, description: body },
        sortOrder: Number(file.slice(0, 2)),
      },
    };
  });
}

/**
 * Contract-check fail-closed contra el shape congelado (03 §3.6). Devuelve la
 * lista de desviaciones (vacía = payload conforme). Con `requireUuid` (modo
 * --apply) exige además teamId UUID — la trampa verificada del API.
 */
export function checkTemplateContract(p: TemplateProvisionPayload, requireUuid: boolean): string[] {
  const dev: string[] = [];
  const i = p.input;
  if (i.type !== "issue") dev.push(`type debe ser "issue" (recibido: ${String(i.type)})`);
  if (typeof i.name !== "string" || i.name.trim() === "") dev.push("name vacío");
  if (typeof i.description !== "string" || i.description.trim() === "") dev.push("description (metadato del template) vacía");
  if (!Number.isFinite(i.sortOrder)) dev.push("sortOrder no numérico");
  const td = i.templateData as unknown as Record<string, unknown>;
  const keys = Object.keys(td).sort();
  const expected = [...TEMPLATE_DATA_WRITE_KEYS].sort();
  if (keys.join(",") !== expected.join(",")) {
    dev.push(`templateData debe tener EXACTAMENTE las claves {${expected.join(", ")}} (recibidas: {${keys.join(", ")}})`);
  }
  if (typeof td.title !== "string" || td.title.trim() === "") dev.push("templateData.title vacío");
  const bodyTd = typeof td.description === "string" ? td.description : "";
  if (bodyTd.trim() === "") {
    dev.push("templateData.description vacío");
  } else {
    const m = parseMarker(bodyTd);
    if ("error" in m) {
      dev.push(`el cuerpo no abre con marcador issue-craft:v1 válido: ${m.error}`);
    } else {
      // Vínculo archivo↔tipo↔marcador: un marcador VÁLIDO de OTRO tipo bajo el
      // nombre de este archivo clasificaría mal toda issue creada del template.
      const expectedType = TEMPLATE_FILE_TYPE_MAP[p.sourceFile];
      if (expectedType === undefined) {
        dev.push(`archivo fuera del mapa canónico filename→type: ${p.sourceFile}`);
      } else if (m.type !== expectedType) {
        dev.push(`marcador type=${m.type} ≠ tipo esperado "${expectedType}" para ${p.sourceFile} (vínculo archivo↔marcador roto)`);
      }
      if (m.madurez !== "despachable") {
        dev.push(`el template debe nacer con madurez=despachable (recibida: ${m.madurez})`);
      }
    }
  }
  // teamId ausente = template global de workspace (válido). Presente en --apply → UUID.
  if (requireUuid && i.teamId !== undefined && !UUID_RE.test(i.teamId)) {
    dev.push(`teamId debe ser UUID en --apply (recibido: ${i.teamId}); resolver el key con la query ResolveTeam`);
  }
  return dev;
}

/**
 * POST GraphQL para el aprovisionamiento. Las QUERIES (idempotentes) usan
 * retry+breaker. Las MUTACIONES NO idempotentes (templateCreate) van con
 * `retry: false`: UNA sola llamada — ante un fallo de transporte AMBIGUO
 * (respuesta perdida/timeout tras un create aceptado) un reintento automático
 * duplicaría el template. La reconciliación es la siguiente ejecución: el
 * censo detecta lo ya creado y lo omite.
 */
async function gqlRequest<T>(
  apiKey: string,
  query: string,
  variables: Record<string, unknown>,
  breaker: CircuitBreaker,
  opts: { retry?: boolean } = {},
): Promise<T> {
  const doFetch = async (): Promise<T> => {
    const res = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: apiKey },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} del API`);
    const parsed = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
    if (parsed.errors && parsed.errors.length > 0) {
      throw new Error(`errores GraphQL: ${parsed.errors.map((e) => e.message).join("; ")}`);
    }
    if (parsed.data === undefined) throw new Error("respuesta GraphQL sin data");
    return parsed.data;
  };
  if (opts.retry === false) {
    if (!breaker.canRequest()) {
      throw new Error(`circuito abierto (${breaker.current}): demasiados fallos consecutivos contra el API`);
    }
    try {
      const out = await doFetch();
      breaker.onSuccess();
      return out;
    } catch (err) {
      breaker.onFailure();
      throw err instanceof Error ? err : new Error(String(err));
    }
  }
  return retryWithBackoff(doFetch, breaker);
}

/**
 * Orquesta el aprovisionamiento. dry-run: genera + contract-check + payloads
 * exactos, sin tocar la red. apply: contract-check ANTES de cualquier mutación
 * (una sola desviación → cero escrituras), censo previo y SKIP de los nombres
 * ya existentes en el equipo — nunca update/delete, solo create.
 */
export async function provisionTemplates(opts: {
  templatesDir: string;
  teamKey: string | null; // null = Templates GLOBALES de workspace
  apply: boolean;
}): Promise<ProvisionResult> {
  const mode: ProvisionResult["mode"] = opts.apply ? "apply" : "dry-run";
  const base: Omit<ProvisionResult, "payloads" | "deviations" | "exitCode"> = {
    mode, teamKey: opts.teamKey, created: [], skipped: [], failed: [],
  };

  const setIssues = checkTemplateSet(opts.templatesDir);
  const setDeviation = setIssues.length > 0
    ? [{ file: "(conjunto de plantillas)", issues: setIssues }]
    : [];

  if (!opts.apply) {
    const teamRef = opts.teamKey !== null ? `<uuid-de:${opts.teamKey}>` : null;
    const payloads = buildTemplatePayloads(opts.templatesDir, teamRef);
    const deviations = [
      ...setDeviation,
      ...payloads
        .map((p) => ({ file: p.sourceFile, issues: checkTemplateContract(p, false) }))
        .filter((d) => d.issues.length > 0),
    ];
    return { ...base, payloads, deviations, exitCode: deviations.length === 0 ? 0 : 1 };
  }

  const apiKey = loadApiKey();
  const breaker = new CircuitBreaker();
  let teamId: string | null = null;
  if (opts.teamKey !== null) {
    const teamData = await gqlRequest<{ teams: { nodes: Array<{ id: string; key: string }> } }>(
      apiKey, TEAM_RESOLVE_QUERY, { key: opts.teamKey }, breaker,
    );
    teamId = teamData.teams.nodes[0]?.id ?? null;
    if (teamId === null) {
      throw new Error(`el equipo con key "${opts.teamKey}" no existe o el token no puede verlo`);
    }
  }
  const payloads = buildTemplatePayloads(opts.templatesDir, teamId);
  const deviations = [
    ...setDeviation,
    ...payloads
      .map((p) => ({ file: p.sourceFile, issues: checkTemplateContract(p, true) }))
      .filter((d) => d.issues.length > 0),
  ];
  if (deviations.length > 0) {
    // Fail-closed: cualquier desviación del contrato o del conjunto → CERO mutaciones.
    return { ...base, payloads, deviations, exitCode: 1 };
  }
  const census = await gqlRequest<{ templates: Array<{ id: string; name: string; team: { key: string } | null }> }>(
    apiKey, TEMPLATE_CENSUS_QUERY, {}, breaker,
  );
  // Skip por nombre dentro del MISMO ámbito: el team pedido, o los globales (team null).
  const existing = new Set(
    census.templates
      .filter((t) => (opts.teamKey !== null ? t.team?.key === opts.teamKey : t.team === null))
      .map((t) => t.name),
  );
  const created: string[] = [];
  const skipped: string[] = [];
  const failed: Array<{ file: string; error: string }> = [];
  for (const p of payloads) {
    if (existing.has(p.input.name)) {
      skipped.push(p.input.name);
      continue;
    }
    try {
      // retry:false — templateCreate NO es idempotente: un fallo ambiguo de
      // transporte jamás debe re-enviar la mutación (duplicaría el template).
      const out = await gqlRequest<{ templateCreate: { success: boolean; template: { id: string; name: string } } }>(
        apiKey, TEMPLATE_CREATE_MUTATION, { input: p.input }, breaker, { retry: false },
      );
      if (out.templateCreate.success) {
        created.push(`${out.templateCreate.template.name} (${out.templateCreate.template.id})`);
      } else {
        failed.push({ file: p.sourceFile, error: "templateCreate.success=false" });
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      failed.push({
        file: p.sourceFile,
        error: `${msg} — templateCreate NO se reintenta (mutación no idempotente): verificar en el tracker y re-ejecutar; el censo omitirá lo ya creado`,
      });
    }
  }
  return {
    ...base, payloads, deviations, created, skipped, failed,
    exitCode: failed.length === 0 ? 0 : 1,
  };
}

function printProvision(r: ProvisionResult): void {
  if (r.mode === "dry-run" && r.teamKey !== null) {
    process.stdout.write("# Paso previo que --apply ejecuta (resolución key→UUID; la validación del API exige UUID):\n");
    process.stdout.write(`${JSON.stringify({ query: TEAM_RESOLVE_QUERY, variables: { key: r.teamKey } })}\n\n`);
  }
  if (r.mode === "dry-run" && r.teamKey === null) {
    process.stdout.write("# Ámbito GLOBAL de workspace: los payloads van SIN teamId (visibles en todos los equipos).\n\n");
  }
  for (const p of r.payloads) {
    process.stdout.write(`# ${p.sourceFile} → ${p.input.name}\n`);
    process.stdout.write(`${JSON.stringify({ query: TEMPLATE_CREATE_MUTATION, variables: { input: p.input } }, null, 2)}\n\n`);
  }
  for (const d of r.deviations) {
    for (const issue of d.issues) {
      process.stdout.write(`[DURO ] [FAIL] CT-contrato — ${d.file}: ${issue}\n`);
    }
  }
  process.stdout.write("--- resumen ---\n");
  process.stdout.write("action=provision-templates\n");
  process.stdout.write(`mode=${r.mode}\n`);
  process.stdout.write(`team=${r.teamKey ?? "(global-workspace)"}\n`);
  process.stdout.write(`plantillas=${r.payloads.length} contract_deviations=${r.deviations.length}\n`);
  if (r.mode === "dry-run") {
    process.stdout.write("mutaciones=0 (dry-run: sin red, sin credenciales)\n");
  } else {
    process.stdout.write(`creadas=${r.created.length} omitidas=${r.skipped.length} fallidas=${r.failed.length}\n`);
    for (const c of r.created) process.stdout.write(`  creada: ${c}\n`);
    for (const s of r.skipped) process.stdout.write(`  omitida (ya existía): ${s}\n`);
    for (const f of r.failed) process.stdout.write(`  fallida: ${f.file} — ${f.error}\n`);
  }
  const verdict = r.exitCode === 0
    ? (r.mode === "dry-run" ? "DRY-RUN-OK" : "APPLY-OK")
    : (r.deviations.length > 0 ? "CONTRACT-FAIL (cero mutaciones)" : "APPLY-PARCIAL");
  process.stdout.write(`verdict=${verdict}\n`);
}

// ---------------------------------------------------------------------------
// Presentación
// ---------------------------------------------------------------------------

function printReport(report: AuditReport, minScore: number): void {
  for (const c of report.checks) {
    const kind = c.hard ? "DURO " : "señal";
    const mark = c.passed ? "PASS" : "FAIL";
    process.stdout.write(`[${kind}] [${mark}] ${c.id} — ${c.detail}\n`);
  }
  process.stdout.write("\n--- resumen ---\n");
  process.stdout.write(`type=${report.type} variant=${report.variant} madurez=${report.madurez}\n`);
  process.stdout.write(`classification_source=${report.classificationSource}\n`);
  process.stdout.write(`input_source=${report.inputSource}\n`);
  process.stdout.write(`operational_gate_eligible=${report.eligible ? "true" : "false"}\n`);
  process.stdout.write(`score=${report.score} min_score=${minScore} hard_failures=${report.hardFailures}\n`);
  const verdict = report.exitCode === 0
    ? (report.eligible ? "GATE-OPERATIVO-OK" : "PRE-CHECK-OK (no acredita el gate)")
    : "NO-DESPACHABLE";
  process.stdout.write(`verdict=${verdict}\n`);
}

function printMatrix(): void {
  process.stdout.write("Matriz sellada type × variant (14 combinaciones válidas):\n\n");
  for (const [t, variants] of Object.entries(TYPE_MATRIX)) {
    process.stdout.write(`  ${t.padEnd(16)} → ${variants.join(" | ")}\n`);
  }
  process.stdout.write(
    "\nToda otra combinación es INVÁLIDA (fail-closed). `variant=none` es explícito y\n" +
    "obligatorio. `seguridad+sev1` (solo en ese orden) aplica la UNIÓN de ambas baterías.\n" +
    "Plantillas: templates/NN-<type>.md · doctrina: references/01 §2-§3.\n",
  );
}

const HELP = `issue_craft_helper — auditor y aprovisionador del skill talent-issue-craft

  --action list-types                      matriz sellada (local, sin credenciales)
  --action audit-issue --file <ruta.md>    pre-check body-only (local, sin credenciales)
  --action audit-issue --issue <id>        auditoría con evidencia remota completa
  --type <t> --variant <v>                 override de clasificación (calibración/histórico;
                                           nunca acredita el gate operativo)
  --min-score <n>                          umbral adicional del score (default 70; los checks
                                           duros vetan SIEMPRE, independiente del score)
  --action provision-templates             aprovisiona las 9 plantillas de tipo como
                                           Templates nativos (shape congelado: 03 §3.6).
                                           Ámbito: EXACTAMENTE uno de --team | --global
      --team <k>                           Templates del equipo <k> (visibles solo en él)
      --global                             Templates GLOBALES de workspace (sin teamId;
                                           visibles en TODOS los equipos)
      --dry-run                            DEFAULT: payloads GraphQL exactos + contract-check;
                                           sin red, sin credenciales, cero mutaciones
      --apply                              ÚNICA vía de escritura (templateCreate): resuelve
                                           key→UUID si hay --team, OMITE nombres ya existentes
                                           en el ámbito, exige credenciales y el GO que dicte
                                           la política del repo. Excluyente con --dry-run.
  --help                                   esta ayuda

Éxito del gate operativo = --issue + classification_source=marker +
operational_gate_eligible=true + exit 0 (los cuatro a la vez).
`;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export async function main(argv: string[]): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      action: { type: "string" },
      issue: { type: "string" },
      file: { type: "string" },
      type: { type: "string" },
      variant: { type: "string" },
      "min-score": { type: "string" },
      team: { type: "string" },
      global: { type: "boolean" },
      "dry-run": { type: "boolean" },
      apply: { type: "boolean" },
      help: { type: "boolean" },
    },
    strict: true,
  });

  if (values.help === true || values.action === undefined) {
    process.stdout.write(HELP);
    return values.help === true ? 0 : 2;
  }

  if (values.action === "list-types") {
    printMatrix();
    return 0;
  }

  if (values.action === "provision-templates") {
    if (values.apply === true && values["dry-run"] === true) {
      process.stderr.write("--apply y --dry-run son excluyentes\n");
      return 2;
    }
    const hasTeam = values.team !== undefined && values.team.trim() !== "";
    const isGlobal = values.global === true;
    if (hasTeam === isGlobal) {
      process.stderr.write(
        "provision-templates exige EXACTAMENTE un ámbito: --team <key> (por equipo) O --global (workspace)\n",
      );
      return 2;
    }
    // El directorio de plantillas vive junto al script (raíz del skill), no al CWD.
    const templatesDir = resolve(dirname(process.argv[1] ?? "."), "..", "templates");
    if (!existsSync(templatesDir)) {
      process.stderr.write(`no existe el directorio de plantillas: ${templatesDir}\n`);
      return 2;
    }
    try {
      const result = await provisionTemplates({
        templatesDir,
        teamKey: hasTeam ? String(values.team).trim() : null,
        apply: values.apply === true,
      });
      printProvision(result);
      return result.exitCode;
    } catch (err) {
      process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
      return 2;
    }
  }

  if (values.action !== "audit-issue") {
    process.stderr.write(`acción desconocida: ${values.action}\n${HELP}`);
    return 2;
  }

  const minScore = values["min-score"] !== undefined ? Number(values["min-score"]) : 70;
  if (Number.isNaN(minScore) || minScore < 0 || minScore > 100) {
    process.stderr.write("--min-score debe ser un número 0-100\n");
    return 2;
  }
  const hasFile = values.file !== undefined;
  const hasIssue = values.issue !== undefined;
  if (hasFile === hasIssue) {
    process.stderr.write("audit-issue exige EXACTAMENTE una entrada: --file <ruta.md> O --issue <id>\n");
    return 2;
  }

  // Entrada: body (+ evidencia remota si --issue)
  let body = "";
  let evidence: RemoteEvidence | null = null;
  const inputSource: "remote" | "file" = hasIssue ? "remote" : "file";
  if (hasFile) {
    const path = resolve(String(values.file));
    if (!existsSync(path)) {
      process.stderr.write(`no existe el archivo: ${path}\n`);
      return 2;
    }
    body = readFileSync(path, "utf8");
  } else {
    let apiKey: string;
    try {
      apiKey = loadApiKey();
    } catch (err) {
      process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
      return 2;
    }
    const fetched = await fetchRemoteIssue(String(values.issue), apiKey);
    body = fetched.body;
    evidence = fetched.evidence;
  }

  // Clasificación: marcador (autoridad) u override explícito
  let classificationSource: "marker" | "override" = "marker";
  let marker: Marker;
  const parsedMarker = parseMarker(body);
  if (values.type !== undefined) {
    classificationSource = "override";
    const t = values.type;
    if (!(t in TYPE_MATRIX)) {
      process.stderr.write(`override inválido: type desconocido ${t}\n`);
      return 1;
    }
    const type = t as TypeToken;
    const v = (values.variant ?? "none");
    if (!TYPE_MATRIX[type].includes(v as VariantToken)) {
      process.stderr.write(`override inválido: variant ${v} no permitida para ${type}\n`);
      return 1;
    }
    marker = { type, variant: v as VariantToken, madurez: "despachable" };
  } else if ("error" in parsedMarker) {
    // Fail-closed: sin marcador válido y sin override no hay clasificación.
    process.stderr.write(
      `CLASIFICACION-FALLIDA (fail-closed): ${parsedMarker.error}\n` +
      "classification_source=n/a\n" +
      `input_source=${inputSource}\n` +
      "operational_gate_eligible=false\n" +
      "Usa el marcador issue-craft:v1 (plantillas del skill) o, para corpus histórico, --type/--variant.\n",
    );
    return 1;
  } else {
    marker = parsedMarker;
  }

  // Checks
  const checks = auditBody(body, marker, classificationSource);
  let remoteComplete = false;
  if (evidence !== null) {
    checks.push(...auditRemoteEvidence(marker, evidence));
    remoteComplete = evidence.complete;
  }
  const report = summarize(checks, classificationSource, inputSource, remoteComplete, minScore, marker);
  printReport(report, minScore);
  return report.exitCode;
}

// Dual export: módulo importable + ejecución directa por CLI.
const isDirectRun = process.argv[1] !== undefined &&
  (process.argv[1].endsWith("issue_craft_helper.ts") || process.argv[1].endsWith("issue_craft_helper.js"));
if (isDirectRun) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err: unknown) => {
      process.stderr.write(`error inesperado: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(2);
    });
}
