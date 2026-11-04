#!/usr/bin/env node
// Oraculo: TODO ejemplo de backoff de `references/` tiene que obedecer el contrato VIVO de
// `scripts/linear-client.ts`, no una version paralela.
//
// El contrato vivo clasifica por el CUERPO de la respuesta (`classifyGraphQLFailure` sobre
// `response.text()`): un body vacio o no-JSON llega como respuesta HTTP EXITOSA y no lanza nada.
// Clasificar por `err instanceof TypeError` deja fuera `EMPTY_BODY` e `INVALID_JSON`, que son los
// dos fallos transitorios mas frecuentes.
//
// EL UNIVERSO MANDA SOBRE LA LISTA. La primera version de este check media UN fichero, el que su
// autor tenia delante -- y habia DOS ejemplos con el mismo defecto. Un ratchet que engancha un
// sujeto mientras el autor dice haber mirado el resto da verde con el bug vivo al lado. Aqui los
// sujetos se ENUMERAN, y la enumeracion se contrasta contra un recuento independiente del ancla:
// si no cuadran, no se mide.
//
// De cada sujeto se EXTRAE el bloque y se EJECUTA. Un ejemplo que no se extrae no se verifica: se
// lee. Y uno que se extrae pero no se confronta con el cliente vivo, tampoco.
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname, resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";

const AQUI = dirname(fileURLToPath(import.meta.url));
const REFS = process.argv[2] ?? resolve(AQUI, "../references");
const CLIENTE = process.argv[3] ?? resolve(AQUI, "linear-client.ts");
const ANCLA = "async function withRetry<T>(";

const noMedible = (m) => { console.error("NO SE PUEDE MEDIR:", m); process.exit(2); };

let rojos = 0;
const chk = (nombre, ok, detalle) => { console.log(`  ${ok ? "ok   " : "ROJO "} ${nombre}: ${detalle}`); if (!ok) rojos++; };

// ── 1 · EL UNIVERSO ───────────────────────────────────────────────────────────────────────────
const ficheros = readdirSync(REFS).filter((f) => f.endsWith(".md")).sort();
if (ficheros.length === 0) noMedible(`no hay .md en ${REFS}`);

let ocurrencias = 0;
const sujetos = [];
for (const f of ficheros) {
  const ruta = join(REFS, f);
  const lineas = readFileSync(ruta, "utf8").split("\n");
  const anclas = lineas.map((l, i) => (l.startsWith(ANCLA) ? i : -1)).filter((i) => i >= 0);
  ocurrencias += anclas.length;
  for (const a of anclas) {
    let ini = -1;
    for (let i = a; i >= 0; i--) if (lineas[i].startsWith("```")) { ini = i + 1; break; }
    let fin = -1;
    for (let i = a; i < lineas.length; i++) if (lineas[i] === "```") { fin = i; break; }
    if (ini < 0 || fin < 0) noMedible(`no se pudo delimitar el bloque de ${f}:${a + 1}`);
    sujetos.push({ nombre: `${basename(f)}:${a + 1}`, bloque: lineas.slice(ini, fin).join("\n") });
  }
}
chk("[U0-control] la enumeracion cuadra con el recuento del ancla",
    sujetos.length === ocurrencias && sujetos.length > 0,
    `enumerados=${sujetos.length} ocurrencias=${ocurrencias} en ${ficheros.length} fichero(s)`);
console.log(`  universo: ${sujetos.map((s) => s.nombre).join(" · ")}`);

// ── 2 · el contrato vivo ──────────────────────────────────────────────────────────────────────
const cliente = readFileSync(CLIENTE, "utf8");
const mAmb = cliente.match(/const FALLOS_AMBIGUOS[^=]*=\s*new Set\(\[([\s\S]*?)\]\)/);
if (!mAmb) noMedible(`no se encontro FALLOS_AMBIGUOS en ${CLIENTE}`);
const ambiguosVivos = [...mAmb[1].matchAll(/LinearErrorCode\.([A-Z_]+)/g)].map((x) => x[1]).sort();
const mEnum = cliente.match(/export enum LinearErrorCode \{([\s\S]*?)\}/);
if (!mEnum) noMedible(`no se encontro el enum LinearErrorCode en ${CLIENTE}`);
const codigosVivos = [...mEnum[1].matchAll(/([A-Z_]+)\s*=/g)].map((x) => x[1]);
if (ambiguosVivos.length === 0 || codigosVivos.length === 0) noMedible("los conjuntos del cliente vivo salieron vacios");

const dir = mkdtempSync(join(tmpdir(), "retry-"));
if (!dir) noMedible("no se pudo crear el directorio temporal");

const arnes = (bloque, forma, n) => `${bloque}

const N = ${n};
const llamar = async (fn: any, idem: boolean) =>
  ${forma === "opciones"
    ? "withRetry(fn, { maxRetries: N, baseDelayMs: 1, idempotent: idem })"
    : "withRetry(fn, N, idem)"};

async function main() {
  const casos: Array<[string, any, boolean, number]> = [
    ["RATELIMITED sin idempotencia -> se reintenta igual", { code: "RATELIMITED" }, false, N],
    ["EMPTY_BODY sin idempotencia -> NO se reintenta (fail-closed)", { code: "EMPTY_BODY" }, false, 1],
    ["EMPTY_BODY con idempotencia -> se reintenta", { code: "EMPTY_BODY" }, true, N],
    ["INVALID_JSON con idempotencia -> se reintenta", { code: "INVALID_JSON" }, true, N],
    ["INPUT_ERROR -> nunca", { code: "INPUT_ERROR" }, true, 1],
    ["codigo GraphQL crudo en extensions", { errors: [{ extensions: { code: "RATELIMITED" } }] }, false, N],
    ["error SIN codigo -> no se reintenta a ciegas", { message: "boom" }, false, 1],
  ];
  let rojos = 0;
  for (const [nombre, err, idem, esperado] of casos) {
    let llamadas = 0;
    try {
      await llamar(async () => { llamadas++; throw err; }, idem);
      console.log(\`  ROJO  \${nombre}: no lanzo\`); rojos++; continue;
    } catch { /* se espera que acabe lanzando */ }
    const ok = llamadas === esperado;
    if (!ok) rojos++;
    console.log(\`  \${ok ? "ok   " : "ROJO "} \${nombre}: llamadas=\${llamadas} (esperaba \${esperado})\`);
  }
  let k = 0;
  const v = await llamar(async () => { k++; if (k === 1) throw { code: "RATELIMITED" }; return "ok"; }, false);
  const okExito = v === "ok" && k === 2;
  if (!okExito) rojos++;
  console.log(\`  \${okExito ? "ok   " : "ROJO "} exito en el 2.o intento devuelve el valor: v=\${v} llamadas=\${k}\`);
${forma === "opciones" ? `
  // Regresion: con \`options\` entero como valor por defecto, pasar opciones PARCIALES dejaba
  // \`maxRetries\` en undefined y el bucle no corria ni una vez.
  let p = 0;
  try { await withRetry(async () => { p++; throw { code: "EMPTY_BODY" }; }, { idempotent: true, baseDelayMs: 1 }); } catch {}
  const okParcial = p === 5;
  if (!okParcial) rojos++;
  console.log(\`  \${okParcial ? "ok   " : "ROJO "} opciones PARCIALES: el bucle corre igual: llamadas=\${p} (esperaba 5)\`);
` : ""}
  console.log(JSON.stringify({ rojos }));
}
main();
`;

const conjuntoDel = (bloque, nombre) => {
  const m = bloque.match(new RegExp(`const ${nombre} = new Set\\(\\[([\\s\\S]*?)\\]\\)`));
  return m ? [...m[1].matchAll(/"([A-Z_]+)"/g)].map((x) => x[1]).sort() : null;
};

try {
  for (const s of sujetos) {
    console.log(`\n  --- sujeto: ${s.nombre}`);
    const ambiguosDoc = conjuntoDel(s.bloque, "AMBIGUOS");
    const noRetryDoc = conjuntoDel(s.bloque, "NO_RETRY");
    if (!ambiguosDoc || !noRetryDoc) noMedible(`no se encontraron los conjuntos AMBIGUOS/NO_RETRY en ${s.nombre}`);
    chk(`[P1 ${s.nombre}] AMBIGUOS == FALLOS_AMBIGUOS del cliente vivo`,
        JSON.stringify(ambiguosDoc) === JSON.stringify(ambiguosVivos), `doc=[${ambiguosDoc}] vivo=[${ambiguosVivos}]`);
    chk(`[P2 ${s.nombre}] ningun codigo inventado (existe en el enum vivo)`,
        [...ambiguosDoc, ...noRetryDoc].every((c) => codigosVivos.includes(c)), `enum=[${codigosVivos}]`);
    chk(`[P3 ${s.nombre}] RATELIMITED fuera de los dos conjuntos`,
        !ambiguosDoc.includes("RATELIMITED") && !noRetryDoc.includes("RATELIMITED"),
        `AMBIGUOS=[${ambiguosDoc}] NO_RETRY=[${noRetryDoc}]`);

    const forma = /options:\s*\{/.test(s.bloque) ? "opciones" : (/maxRetries\s*=\s*\d/.test(s.bloque) ? "posicional" : null);
    if (!forma) noMedible(`forma de firma desconocida en ${s.nombre}: no se sabe como invocarla sin adivinar`);
    const n = forma === "opciones" ? 3 : 2;
    console.log(`  forma=${forma} maxRetries=${n}`);

    const f = join(dir, s.nombre.replace(/[^a-zA-Z0-9]/g, "_") + ".ts");
    writeFileSync(f, arnes(s.bloque, forma, n));
    const salida = execFileSync("npx", ["--yes", "tsx", f], { encoding: "utf8" });
    process.stdout.write(salida.split("\n").filter((l) => !l.startsWith("{")).join("\n"));
    const medida = salida.trim().split("\n").filter((l) => l.startsWith("{")).pop();
    if (!medida) noMedible(`el arnes no emitio medida para ${s.nombre}`);
    rojos += JSON.parse(medida).rojos;
  }
} catch (e) {
  if (e?.status === 2) process.exit(2);
  noMedible(e?.message ?? String(e));
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\n  --- ambito: ${sujetos.length} sujeto(s) del universo, ${rojos} rojo(s) ---`);
process.exit(rojos === 0 ? 0 : 1);
