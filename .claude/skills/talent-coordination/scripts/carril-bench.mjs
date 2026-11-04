#!/usr/bin/env node
// carril-bench.mjs — microbench de carril (DEV / ASR / OPS)
// Uso:  node carril-bench.mjs <ID>          (ej: node carril-bench.mjs E10)
// Cero dependencias, sin red. Corre igual en macOS / Linux / Windows con Node >=18.
// Mide tiempos crudos reales; el coordinador normaliza a 0-100 con las 15 muestras.
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

// ---------- workload CPU determinista (V8 puro, proxy de build/JIT) ----------
function cpuWork(units) {
  let acc = 0 >>> 0, s = 0;
  for (let u = 0; u < units; u++) {
    let x = (u ^ 0x9e3779b1) >>> 0;
    x ^= x << 13; x >>>= 0; x ^= x >> 17; x ^= x << 5; x >>>= 0;
    acc = (acc + x) >>> 0;
    s += Math.sqrt(u * 1.0000001) * Math.sin(u * 0.5);
    if ((u & 2047) === 0) acc ^= String(s).length;
  }
  return (acc >>> 0) ^ (s | 0);
}

// Cuerpo del worker: ejecuta cpuWork y termina.
if (!isMainThread) {
  const r = cpuWork(workerData.units);
  parentPort.postMessage(r);
} else {
  main().catch((e) => { console.error("bench error:", e); process.exit(1); });
}

// ---------- DSP numérico (proxy del coste de inferencia ASR en CPU) ----------
function dspWork(n, reps) {
  const a = new Float64Array(n);
  for (let i = 0; i < n; i++) a[i] = Math.sin(i * 0.01) + 0.5 * Math.cos(i * 0.003);
  let acc = 0;
  for (let r = 0; r < reps; r++) {
    for (let i = 2; i < n; i++) {
      a[i] = 0.25 * a[i] + 0.25 * a[i - 1] + 0.25 * a[i - 2] + 0.25 * Math.tanh(a[i]);
      acc += a[i];
    }
  }
  return acc;
}

function ms(t0) { return Math.round((performance.now() - t0) * 10) / 10; }
function which(bin) {
  const probe = process.platform === "win32"
    ? spawnSync("where", [bin], { encoding: "utf8" })
    : spawnSync("sh", ["-c", `command -v ${bin}`], { encoding: "utf8" });
  return probe.status === 0 ? (probe.stdout || "").trim().split(/\r?\n/)[0] : null;
}

// ---------- genera un WAV PCM 16kHz mono 60s (tono+ruido) para el test ASR ----------
function writeWav60(file) {
  const sr = 16000, secs = 60, N = sr * secs;
  const buf = Buffer.alloc(44 + N * 2);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + N * 2, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(sr, 24); buf.writeUInt32LE(sr * 2, 28);
  buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write("data", 36); buf.writeUInt32LE(N * 2, 40);
  let seed = 12345;
  for (let i = 0; i < N; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    const noise = (seed / 0x7fffffff - 0.5) * 0.15;
    const tone = Math.sin(2 * Math.PI * 180 * i / sr) * 0.35 + Math.sin(2 * Math.PI * 320 * i / sr) * 0.2;
    let v = Math.max(-1, Math.min(1, tone + noise));
    buf.writeInt16LE((v * 32767) | 0, 44 + i * 2);
  }
  fs.writeFileSync(file, buf);
}

// ---------- intenta una transcripción REAL si hay binario Whisper ----------
function asrReal(wav, tmp) {
  // candidatos en orden de preferencia por aceleración
  const cands = [
    { bin: "mlx_whisper", args: (w) => [w, "--model", "mlx-community/whisper-tiny", "--output-dir", tmp] },
    { bin: "whisper-cli", args: (w) => ["-m", "models/ggml-tiny.bin", "-f", w] }, // whisper.cpp (necesita modelo local)
    { bin: "faster-whisper", args: (w) => [w, "--model", "tiny", "--output_dir", tmp] },
    { bin: "whisper", args: (w) => [w, "--model", "tiny", "--output_dir", tmp, "--fp16", "False"] }, // whisper CLI (pip)
  ];
  let lastFail = null;
  for (const c of cands) {
    const found = which(c.bin);
    if (!found) continue;
    const t0 = performance.now();
    const r = spawnSync(c.bin, c.args(wav), { encoding: "utf8", timeout: 900000 });
    const wall = ms(t0) / 1000;
    if (r.status === 0) {
      return { tool: c.bin, wall_s: Math.round(wall * 100) / 100, rtf: Math.round((60 / wall) * 100) / 100 };
    }
    // encontrado pero falló (p.ej. modelo ausente) → lo registro y SIGO probando los demás candidatos
    lastFail = { tool: c.bin, wall_s: null, rtf: null, note: "binario presente pero la transcripción falló (¿modelo no descargado?)" };
  }
  return lastFail; // el último fallo registrado, o null si no había ningún toolchain
}

async function runMulti(units, nWorkers) {
  const __file = fileURLToPath(import.meta.url);
  const t0 = performance.now();
  await Promise.all(Array.from({ length: nWorkers }, () =>
    new Promise((res, rej) => {
      const w = new Worker(__file, { workerData: { units } });
      w.on("message", () => res());
      w.on("error", rej);
    })
  ));
  return ms(t0);
}

function opsBench(tmp) {
  // FS: 3000 ficheros pequeños
  const dir = path.join(tmp, "ops-fs");
  fs.mkdirSync(dir, { recursive: true });
  const K = 3000, payload = Buffer.from("x".repeat(256));
  let t0 = performance.now();
  for (let i = 0; i < K; i++) fs.writeFileSync(path.join(dir, `f${i}.txt`), payload);
  let sum = 0;
  for (let i = 0; i < K; i++) sum += fs.readFileSync(path.join(dir, `f${i}.txt`)).length;
  for (let i = 0; i < K; i++) fs.statSync(path.join(dir, `f${i}.txt`));
  for (let i = 0; i < K; i++) fs.unlinkSync(path.join(dir, `f${i}.txt`));
  const fsMs = ms(t0);
  // JSON: parse+stringify de un objeto mediano
  const obj = { items: Array.from({ length: 500 }, (_, i) => ({ id: i, name: "lane-" + i, vals: [i, i * 2, i * 3], meta: { a: true, b: "z".repeat(20) } })) };
  t0 = performance.now();
  let acc = 0;
  for (let i = 0; i < 2000; i++) { const s = JSON.stringify(obj); acc += JSON.parse(s).items.length; }
  const jsonMs = ms(t0);
  // SPAWN: latencia de proceso (proxy de orquestar git/tooling)
  const M = 30;
  t0 = performance.now();
  for (let i = 0; i < M; i++) spawnSync(process.execPath, ["-e", "0"], { stdio: "ignore" });
  const spawnMs = ms(t0);
  return { ops_fs_ms: fsMs, ops_json_ms: jsonMs, ops_spawn_ms: spawnMs, _k: acc };
}

function printUsage() {
  console.log(`Uso: node carril-bench.mjs <ID>   (ej: node carril-bench.mjs E10)

Microbench de carril (DEV / ASR / OPS). Cero dependencias, sin red.
Imprime un bloque JSON de resultados en stdout para pegar al coordinador.

Opciones:
  -h, --help    Muestra esta ayuda y sale`);
}

async function main() {
  const arg = process.argv[2];
  if (arg === "-h" || arg === "--help") {
    printUsage();
    process.exit(0);
  }
  const lane = arg || "UNKNOWN";
  const cpus = os.cpus() || [];
  const nCpu = cpus.length || 1;
  const ramGB = Math.round(os.totalmem() / 1073741824);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "carril-bench-"));

  console.error(`[${lane}] corriendo bench… (puede tardar 1-3 min en máquinas modestas)`);

  // DEV single
  console.error("  · DEV single-thread…");
  let t0 = performance.now();
  cpuWork(40_000_000);
  const devSingle = ms(t0);

  // DEV multi (1 worker por núcleo)
  console.error(`  · DEV multi-core (${nCpu} workers)…`);
  const devMulti = await runMulti(40_000_000, nCpu);

  // ASR proxy CPU
  console.error("  · ASR proxy (DSP CPU)…");
  t0 = performance.now();
  dspWork(200_000, 600);
  const asrProxy = ms(t0);

  // ASR ruta + real opcional
  const gpu = (() => {
    if (!which("nvidia-smi")) return null;
    // timeout acotado: nvidia-smi puede colgarse y bloquearía todo el bench
    const r = spawnSync("nvidia-smi", ["--query-gpu=name", "--format=csv,noheader"], { encoding: "utf8", timeout: 5000 });
    if (r.status !== 0 || !r.stdout) return null; // fallo o timeout → sin GPU
    return r.stdout.trim().split(/\r?\n/)[0] || null;
  })();
  const asrRoute = gpu ? "cuda" : (process.platform === "darwin" && process.arch === "arm64" ? "mlx" : "cpu");
  console.error(`  · ASR ruta detectada: ${asrRoute}${gpu ? " (" + gpu + ")" : ""}`);
  console.error("  · ASR real (si hay Whisper instalado)…");
  let asrRealRes = null;
  try { writeWav60(path.join(tmp, "sample60.wav")); asrRealRes = asrReal(path.join(tmp, "sample60.wav"), tmp); } catch (e) { asrRealRes = { error: String(e) }; }

  // OPS
  console.error("  · OPS (FS + JSON + spawn)…");
  const ops = opsBench(tmp);

  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}

  const UNITS = 40_000_000;
  const round1 = (x) => Math.round(x * 10) / 10;
  const report = {
    lane,
    host: {
      os: `${process.platform} ${os.release()}`,
      arch: process.arch,
      cpu: cpus[0]?.model?.trim() || "?",
      cores_logical: nCpu,
      ram_gb: ramGB,
      node: process.version,
    },
    asr_route: asrRoute,
    gpu: gpu || null,
    // throughput = millones de units/seg (MAYOR = mejor; comparable entre nº de cores distinto)
    throughput_mups: {
      dev_single: round1(UNITS / 1e6 / (devSingle / 1000)),
      dev_multi: round1((nCpu * UNITS) / 1e6 / (devMulti / 1000)),
      cores: nCpu,
    },
    raw_ms: {
      dev_single: devSingle,
      dev_multi: devMulti,
      asr_proxy_cpu: asrProxy,
      ops_fs: ops.ops_fs_ms,
      ops_json: ops.ops_json_ms,
      ops_spawn: ops.ops_spawn_ms,
    },
    asr_real: asrRealRes, // {tool, wall_s, rtf} | {tool, note} | null(sin toolchain)
  };

  console.error("\n────────── PÉGAME ESTE BLOQUE ──────────");
  console.log(JSON.stringify(report));
  console.error("────────────────────────────────────────");
  // resumen humano (a stderr, no contamina el JSON)
  console.error(`\n[${lane}] DEV single ${report.throughput_mups.dev_single} Mu/s · DEV multi ${report.throughput_mups.dev_multi} Mu/s (${nCpu} hilos) · ASR-proxy ${asrProxy}ms · ruta ${asrRoute}` +
    (asrRealRes?.rtf ? ` · ASR real RTF ${asrRealRes.rtf}x (${asrRealRes.tool})` : asrRealRes?.tool ? ` · ASR ${asrRealRes.tool}: ${asrRealRes.note}` : " · ASR real: sin toolchain") +
    ` · OPS fs ${ops.ops_fs_ms}/json ${ops.ops_json_ms}/spawn ${ops.ops_spawn_ms}ms`);
}
