"use strict";
// Conductor PORTABLE de test-resolucion-clave.sh: ejecuta el código de producción de TypeScript con
// cualquier Node >= 18 (el de apt de Ubuntu 24.04 es 18.19.1), sin tsx, sin compilador, sin red.
//
// No es una copia reescrita: en cada ejecución LEE los .ts de producción, recorta por anclas el trozo
// que se prueba (el cargador de la clave de linear-client.ts, el bloque de dispatch que la carga, los
// casos «clave:» de su --action selftest y el loadApiKey de issue_craft_helper.ts), le BORRA las
// anotaciones de tipo con un borrador mínimo (solo la sintaxis que esos trozos usan) y lo evalúa. Si
// cambia el código de producción cambia lo que se mide; si una ancla desaparece, o el trozo ya no
// parsea tras el borrado, el conductor falla con rc 3 (fail-closed, nunca verde en silencio).
// Con un Node que ejecuta TypeScript de forma nativa, test-resolucion-clave.sh contrasta además el
// selftest real de linear-client.ts como equivalencia.
//
// Uso: node cargador-portable.cjs <modo> <linear-client.ts> <issue_craft_helper.ts> [args...]
//   cli       (cwd y entorno reales)  -> OK <fuente> | EXIT<rc> <mensaje de error>
//   issue     <startDir> <envJson>    -> OK <fuente> | ERR <mensaje>
//   selftest                          -> líneas PASS/FAIL de los casos «clave:» y SELFTEST: PASS=n FAIL=m

const fs = require("fs");
const os = require("os");
const path = require("path");
const childProcess = require("child_process");

function entre(texto, inicio, fin, incluirFin) {
  const i = texto.indexOf(inicio);
  if (i < 0) throw new Error("ancla de inicio no encontrada: " + JSON.stringify(inicio));
  const j = texto.indexOf(fin, i + inicio.length);
  if (j < 0) throw new Error("ancla de fin no encontrada: " + JSON.stringify(fin));
  return texto.slice(i, incluirFin ? j + fin.length : j);
}

function quitarParametros(parametros) {
  const partes = [];
  let profundidad = 0;
  let actual = "";
  for (const c of parametros) {
    if ("([{<".includes(c)) profundidad++;
    if (")]}>".includes(c)) profundidad--;
    if (c === "," && profundidad === 0) { partes.push(actual); actual = ""; } else actual += c;
  }
  if (actual.trim() !== "") partes.push(actual);
  return partes
    .map((p) => {
      const m = /^\s*(\w+)\??\s*:\s*([^=]+?)\s*(=[\s\S]*)?$/.exec(p);
      return m ? m[1] + (m[3] ? " " + m[3] : "") : p.trim();
    })
    .join(", ");
}

// Borrador mínimo de tipos: lo justo para los trozos recortados (parámetros y retorno de funciones,
// `let/const x: T`, parámetros de flechas, `(x as T)`, `export`). No es un compilador de TypeScript.
function quitarTipos(src) {
  let t = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^[ \t]*\/\/.*$/gm, "");
  t = t.replace(/^(\s*)export\s+/gm, "$1");
  t = t.replace(/function\s+(\w+)\s*\(((?:[^()]|\(\))*)\)\s*(?::\s*[^{]+?)?\s*\{/g,
    (m, nombre, parametros) => "function " + nombre + "(" + quitarParametros(parametros) + ") {");
  t = t.replace(/\b(let|const)\s+(\w+)\s*:\s*[^=;\n]+?(?=\s*[=;])/g, "$1 $2");
  t = t.replace(/\(\s*(\w+)\s*:\s*[\w\s|<>[\].]+\)\s*=>/g, "($1) =>");
  t = t.replace(/\((\w+)\s+as\s+\w+\)/g, "($1)");
  return t;
}

function compilar(parametros, cuerpo, etiqueta) {
  try {
    return new Function(...parametros, quitarTipos(cuerpo));
  } catch (e) {
    throw new Error("el trozo «" + etiqueta + "» no parsea tras borrar los tipos: " + e.message);
  }
}

function cargadorLinear(texto) {
  const trozo = entre(texto, "function readApiKeyFromFile(",
    "\n// ====================================================================\n// Helpers de uso común");
  const fabrica = compilar(["fs", "path", "childProcess"], trozo + "\nreturn { resolveApiKey, loadApiKey };", "cargador de linear-client");
  return fabrica(fs, path, childProcess);
}

function cargadorIssueCraft(texto) {
  const trozo = entre(texto, "export function loadApiKey(",
    "\n// ---------------------------------------------------------------------------\n// Parsing del body");
  const fabrica = compilar(["readFileSync", "existsSync", "statSync", "resolve", "dirname", "join", "process"],
    trozo + "\nreturn loadApiKey;", "loadApiKey de issue-craft");
  return fabrica(fs.readFileSync, fs.existsSync, fs.statSync, path.resolve, path.dirname, path.join, process);
}

function fuente(clave) {
  for (const n of ["repo", "op", "env"]) if (clave === "fake-" + n + "-key") return n;
  return "?";
}

const [, , modo, rutaLinear, rutaIssue, ...resto] = process.argv;
try {
  if (modo === "cli") {
    const textoLinear = fs.readFileSync(rutaLinear, "utf8");
    const { loadApiKey } = cargadorLinear(textoLinear);
    // El bloque de dispatch() que carga la clave y sale con 1 si falta, tal cual está en producción.
    const bloque = entre(textoLinear, "  let apiKey: string;", "  const client = new LinearMinClient({ apiKey });");
    const errores = [];
    const consola = { error: (...a) => errores.push(a.join(" ")), log: () => {} };
    const proceso = { exit: (c) => { throw { salida: c }; } };
    const ejecutar = compilar(["loadApiKey", "console", "process"], bloque + "\nreturn apiKey;", "dispatch: carga de la clave");
    try {
      console.log("OK " + fuente(ejecutar(loadApiKey, consola, proceso)));
    } catch (e) {
      if (e && typeof e === "object" && "salida" in e) console.log("EXIT" + e.salida + " " + errores.join(" | "));
      else throw e;
    }
  } else if (modo === "issue") {
    const loadApiKey = cargadorIssueCraft(fs.readFileSync(rutaIssue, "utf8"));
    try {
      console.log("OK " + fuente(loadApiKey(resto[0], JSON.parse(resto[1]))));
    } catch (e) {
      console.log("ERR " + e.message);
    }
  } else if (modo === "selftest") {
    const textoLinear = fs.readFileSync(rutaLinear, "utf8");
    const { resolveApiKey } = cargadorLinear(textoLinear);
    // Los casos «clave:» de --action selftest, tal cual están en producción.
    const bloque = entre(textoLinear, "  const claveTmp = fs.mkdtempSync(",
      "    fs.rmSync(claveTmp, { recursive: true, force: true });\n  }\n", true);
    let pass = 0;
    let fail = 0;
    const caso = (nombre, fn) => {
      try { fn(); pass++; console.log("PASS " + nombre); } catch (e) { fail++; console.log("FAIL " + nombre + ": " + e.message); }
    };
    const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
    compilar(["caso", "assert", "fs", "path", "os", "resolveApiKey"], bloque, "casos «clave:» del selftest")(caso, assert, fs, path, os, resolveApiKey);
    console.log("SELFTEST: PASS=" + pass + " FAIL=" + fail);
    process.exitCode = fail === 0 ? 0 : 1;
  } else {
    throw new Error("modo desconocido: " + modo);
  }
} catch (e) {
  console.log("CONDUCTOR-ERROR " + (e && e.message ? e.message : String(e)));
  process.exitCode = 3;
}
