const { spawn } = require("node:child_process");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os"), crypto = require("node:crypto");
const assert = require("node:assert/strict");
const { DatabaseSync } = require("node:sqlite");
// Proveer Playwright instalado en el equipo, sin agregar dependencias al CRM.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const repo = path.resolve(__dirname, ".."), out = process.env.AUDIT_OUT || fs.mkdtempSync(path.join(os.tmpdir(), "crm-evidencia-"));
fs.mkdirSync(out, { recursive: true });
const copia = fs.mkdtempSync(path.join(os.tmpdir(), "crm-altas-"));
for (const file of ["server.js", "altas.js", "package.json", "public"]) fs.cpSync(path.join(repo, file), path.join(copia, file), { recursive: true });
fs.writeFileSync(path.join(out, "transporte.json"), JSON.stringify({ fallar: [] }));
fs.writeFileSync(path.join(out, "envios.jsonl"), "");
const puertoFile = path.join(out, "puerto-" + path.basename(copia) + ".json");
const child = spawn(process.execPath, [path.join(__dirname, "servidor-simulado.cjs"), path.join(copia, "server.js")], {
  cwd: copia, env: { PATH: process.env.PATH, PORT: "0", CRM_PRODUCCION: "1", AUDIT_OUT: out, AUDIT_PORT_FILE: puertoFile, TZ: "America/Argentina/Buenos_Aires" },
  stdio: ["ignore", "pipe", "pipe"] });
let log = "", browser, db, base;
child.stdout.on("data", b => { log += b; }); child.stderr.on("data", b => { log += b; });
const results = [], errors = [], exteriores = [];
const check = (nombre, evidencia) => { results.push({ nombre, ok: true, evidencia }); console.log("PASS " + nombre); };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const envios = () => fs.readFileSync(path.join(out, "envios.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
async function esperar(fn) { for (let n = 0; n < 120; n++) { if (await fn()) return; await pause(50); } throw Error("Tiempo agotado esperando condición"); }

(async () => {
  try {
    // El servidor simulado informa el puerto efímero que obtuvo al escuchar.
    await esperar(() => {
      if (child.exitCode !== null) throw Error(log);
      if (!fs.existsSync(puertoFile)) return false;
      base = "http://127.0.0.1:" + JSON.parse(fs.readFileSync(puertoFile, "utf8"));
      return true;
    });
    await esperar(async () => { try { return (await fetch(base + "/api/quien")).ok; } catch { return false; } });
    db = new DatabaseSync(path.join(copia, "datos/crm.db")); db.exec("PRAGMA busy_timeout=5000");
    const ahora = Date.now(), hash = "ficticio:" + crypto.scryptSync("clave-ficticia", "ficticio", 32).toString("hex");
    for (const [nombre, area, telefono, rol] of [
      ["Auditor ficticio", "", null, "admin"], ["ATC ficticio", "AT Cliente", "3571400000", "area"],
      ["Monitoreo ficticio", "Monitoreo", "3571400001", "area"], ["Comercial ficticio", "Comercial", "3571400002", "area"],
      ["Técnica ficticia", "Técnica", "3571400003", "area"], ["Gastón", "", "3571400009", "area"]]) {
      db.prepare("INSERT INTO usuarios(nombre,area,telefono,clave,rol,solo_su_area,activo,creado_en) VALUES(?,?,?,?,?,0,1,?)")
        .run(nombre, area, telefono, hash, rol, ahora);
    }
    db.prepare("INSERT INTO sesiones(token,usuario,creada_en,ultimo_uso) VALUES('auditoria-ficticia','Auditor ficticio',?,?)").run(ahora, ahora);
    for (const [k,v] of Object.entries({ pedir_ingreso: "1", modo_envio: "real", altas_plazos: "0", avisar_nuevo: "0", avisar_por_vencer: "0", avisar_vencido: "0" })) {
      db.prepare("INSERT INTO config(clave,valor) VALUES(?,?) ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor").run(k, v);
    }
    const api = async (ruta, body) => {
      const r = await fetch(base + ruta, { method: body ? "POST" : "GET", headers: { Cookie: "crm_sesion=auditoria-ficticia", "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
      const data = await r.json(); if (!r.ok) throw Error(data.error); return data;
    };
    browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1100 } });
    await context.addCookies([{ name: "crm_sesion", value: "auditoria-ficticia", url: base }]);
    await context.route("**/*", route => {
      if (route.request().url().startsWith(base + "/")) return route.continue();
      exteriores.push(route.request().url()); return route.abort();
    });
    const page = await context.newPage(); page.on("pageerror", e => errors.push(String(e)));
    const dialogs = []; page.on("dialog", async d => { dialogs.push(d.message()); await d.accept(); });
    const abrir = async a => { await page.goto(base + "/?tab=altas&alta=" + a.id); await page.waitForSelector(`[data-alta-detalle="${a.id}"]`); };
    const boton = (paso, estado = "completado") => `[data-marcar="${paso}"][data-estado="${estado}"]`;
    const confirmar = async () => { await page.click("#apConfirmar"); await page.waitForSelector("#dlgAltaPaso", { state: "hidden" }); };
    const a = await api("/api/altas", { cliente: "Auditoría ficticia — PAGAR completado", abonado: "FICT-001" }); await abrir(a);
    await page.click(boton("8")); assert.equal(await page.locator("#apAviso").isVisible(), false);
    await page.screenshot({ path: path.join(out, "01-pagar-sin-aviso.png"), fullPage: true });
    await confirmar(); assert.equal(envios().length, 0);
    check("B1 Punto 8 completado: pantalla y servidor sin aviso");
    const b = await api("/api/altas", { cliente: "Auditoría ficticia — PAGAR no aplica" }); await abrir(b);
    await page.click(boton("8", "no_aplica")); assert.equal(await page.locator("#apAviso").isVisible(), false);
    await page.fill("#apNota", "Servicio ficticio que no corresponde cargar"); await confirmar(); assert.equal(envios().length, 0);
    check("B2 Punto 8 No aplica: sin aviso");
    await page.click(boton("6"));
    assert.deepEqual(await page.locator("#apAreas input:checked").evaluateAll(xs => xs.map(x => x.value)), ["Técnica", "Comercial"]);
    await page.click("#apCancelar"); check("B3 Punto 6 conserva Técnica y Comercial");
    await page.click(boton("12")); await page.waitForFunction(() => document.getElementById("apAlcance").textContent.includes("4"));
    assert.equal(await page.locator("#apUsuarios").isVisible(), true);
    assert.match(await page.locator("#apUsuarios").innerText(), /Gastón/);
    assert.equal(await page.locator("#apAviso input:checked:disabled").count(), 4);
    await page.screenshot({ path: path.join(out, "02-servicio-cuatro-destinatarios.png"), fullPage: true });
    await page.evaluate(() => { confirmarPaso(); confirmarPaso(); });
    await page.waitForSelector("#dlgAltaPaso", { state: "hidden" }); await esperar(() => envios().length === 4);
    assert.equal(db.prepare("SELECT COUNT(*) n FROM alta_avisos WHERE alta_id=?").get(b.id).n, 1);
    assert.ok(envios().every(e => e.texto.includes("Servicio operativo verificado") && !e.texto.includes("Alta finalizada")));
    check("B4 Punto 12: cuatro destinatarios visibles, mensaje correcto y doble confirmación sin duplicados");
    await page.getByText("Avisos (1)", { exact: true }).click();
    assert.match(await page.locator("#altas").innerText(), /recepción sin confirmar/);
    await page.screenshot({ path: path.join(out, "03-servicio-aviso-registrado.png"), fullPage: true });
    const listado = await api("/api/altas");
    for (const p of listado.pasos) db.prepare("INSERT INTO alta_pasos(alta_id,paso,estado) VALUES(?,?,'completado') ON CONFLICT(alta_id,paso) DO UPDATE SET estado='completado'").run(b.id, p.id);
    await abrir(b); await page.click("#btnFinalizarAlta");
    await page.waitForFunction(() => document.querySelector("[data-alta-detalle]")?.textContent.includes("finalizada por"));
    assert.equal(envios().length, 4); assert.match(dialogs.at(-1), /no se repite/);
    check("B5 Finalizar Alta registra cierre sin otro WhatsApp");
    db.exec("UPDATE usuarios SET activo=0 WHERE nombre='Gastón'");
    const c = await api("/api/altas", { cliente: "Auditoría ficticia — falta Gastón" }); await abrir(c); await page.click(boton("12"));
    await page.waitForFunction(() => document.getElementById("apAlcance").textContent.includes("Sin teléfono válido: Gastón"));
    await page.screenshot({ path: path.join(out, "04-falta-contacto-gaston.png"), fullPage: true });
    await confirmar(); await esperar(() => envios().length === 7);
    assert.equal(db.prepare("SELECT estado FROM alta_avisos WHERE alta_id=?").get(c.id).estado, "fallo");
    await page.getByText("Avisos (1)", { exact: true }).click();
    assert.match(await page.locator("#altas").innerText(), /Sin teléfono válido en Personas: Gastón/);
    await page.screenshot({ path: path.join(out, "05-falta-contacto-no-entregado.png"), fullPage: true });
    check("B6 Gastón ausente: advertencia previa y fallo visible después");
    db.exec("UPDATE usuarios SET activo=1 WHERE nombre='Gastón'");
    db.prepare("UPDATE alta_avisos SET prox_intento=NULL,intentos=5 WHERE alta_id=?").run(c.id);
    await abrir(c); await page.getByText("Avisos (1)", { exact: true }).click(); await page.click("[data-reenviar]");
    await esperar(() => envios().length === 8);
    assert.equal(envios().at(-1).numero, "3571400009");
    check("B7 Corregir y Reenviar sólo envía a Gastón");
    fs.writeFileSync(path.join(out, "transporte.json"), JSON.stringify({ fallar: ["3571400009"] }));
    const d = await api("/api/altas", { cliente: "Auditoría ficticia — falla WhatsApp" }); await abrir(d); await page.click(boton("12")); await confirmar();
    await esperar(() => envios().length === 12); await page.getByText("Avisos (1)", { exact: true }).click();
    assert.match(await page.locator("#altas").innerText(), /WhatsApp desconectado \(simulado\)/);
    assert.equal(db.prepare("SELECT estado FROM alta_avisos WHERE alta_id=?").get(d.id).estado, "fallo");
    await page.screenshot({ path: path.join(out, "06-fallo-whatsapp-visible.png"), fullPage: true });
    check("B8 Fallo de WhatsApp visible y sin marcar envío completo");
    // Simula una pestaña que conserva el JavaScript anterior al despliegue.
    fs.writeFileSync(path.join(out, "transporte.json"), JSON.stringify({ fallar: [] }));
    const anterior = await api("/api/altas", { cliente: "Auditoría ficticia — cliente anterior" });
    await api("/api/altas/paso", { alta: anterior.id, paso: "12", estado: "completado" });
    await esperar(() => envios().length === 16);
    for (const p of listado.pasos) db.prepare("INSERT INTO alta_pasos(alta_id,paso,estado) VALUES(?,?,'completado') ON CONFLICT(alta_id,paso) DO UPDATE SET estado='completado'").run(anterior.id, p.id);
    const vieja = await context.newPage(); vieja.on("pageerror", e => errors.push(String(e)));
    vieja.on("dialog", dialog => dialog.accept());
    await vieja.route(base + "/altas.js", route => route.fulfill({ contentType: "text/javascript", body: fs.readFileSync(path.join(__dirname, "fixtures/altas-cliente-d65f5e1.js"), "utf8") }));
    await vieja.goto(base + "/?tab=altas&alta=" + anterior.id);
    await vieja.waitForSelector(`[data-alta-detalle="${anterior.id}"]`);
    assert.equal(await vieja.locator("#btnFinalizarAlta").isEnabled(), true);
    await vieja.screenshot({ path: path.join(out, "07-cliente-anterior-listo-para-finalizar.png"), fullPage: true });
    await vieja.click("#btnFinalizarAlta");
    await vieja.waitForFunction(() => document.querySelector("[data-alta-detalle]")?.textContent.includes("finalizada por"));
    assert.equal(envios().length, 16);
    assert.equal(db.prepare("SELECT COUNT(*) n FROM alta_avisos WHERE alta_id=?").get(anterior.id).n, 1);
    check("B10 Cliente anterior con API nueva dibuja y finaliza sin duplicar avisos");
    assert.deepEqual(errors, []); assert.deepEqual(exteriores, []);
    check("B9 Sin errores JavaScript ni peticiones exteriores", { errores: errors.length, peticiones_exteriores: exteriores.length });
  } finally {
    await browser?.close(); db?.close(); child.kill("SIGTERM");
    fs.writeFileSync(path.join(out, "servidor.log"), log);
    fs.writeFileSync(path.join(out, "navegador-resultados.json"), JSON.stringify({ copia_temporal: copia, results, errors, exteriores }, null, 2));
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
