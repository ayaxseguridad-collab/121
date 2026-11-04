// GAS-400 y GAS-402: qué se puede cambiar por «POST /api/config» y quién.
// Levanta una copia temporal del CRM con el servidor simulado (sin WhatsApp, sin red)
// y usuarios ficticios; las sesiones se cargan directo en la base de la copia.
const test = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const { DatabaseSync } = require("node:sqlite");

const repo = path.resolve(__dirname, "..");
const pausa = ms => new Promise(r => setTimeout(r, ms));

async function levantar(t) {
  const copia = fs.mkdtempSync(path.join(os.tmpdir(), "crm-config-"));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "crm-config-out-"));
  for (const f of ["server.js", "altas.js", "package.json", "public"]) fs.cpSync(path.join(repo, f), path.join(copia, f), { recursive: true });
  fs.writeFileSync(path.join(out, "transporte.json"), JSON.stringify({ fallar: [] }));
  const puertoFile = path.join(out, "puerto.json");
  const hijo = spawn(process.execPath, [path.join(__dirname, "servidor-simulado.cjs"), path.join(copia, "server.js")], {
    cwd: copia, stdio: "ignore",
    env: { PATH: process.env.PATH, PORT: "0", AUDIT_OUT: out, AUDIT_PORT_FILE: puertoFile } });
  t.after(() => { hijo.kill(); fs.rmSync(copia, { recursive: true, force: true }); fs.rmSync(out, { recursive: true, force: true }); });
  for (let n = 0; !fs.existsSync(puertoFile); n++) { if (n > 200 || hijo.exitCode !== null) throw Error("El CRM no arrancó"); await pausa(50); }
  const base = "http://127.0.0.1:" + JSON.parse(fs.readFileSync(puertoFile, "utf8"));
  const db = new DatabaseSync(path.join(copia, "datos/crm.db")); db.exec("PRAGMA busy_timeout=5000");
  t.after(() => db.close());
  const ahora = Date.now();
  for (const [nombre, area, rol, token] of [["Admin ficticio", "", "admin", "s-admin"], ["ATC ficticio", "AT Cliente", "area", "s-atcl"]]) {
    db.prepare("INSERT INTO usuarios(nombre,area,clave,rol,solo_su_area,activo,creado_en) VALUES(?,?,'x',?,0,1,?)").run(nombre, area, rol, ahora);
    db.prepare("INSERT INTO sesiones(token,usuario,creada_en,ultimo_uso) VALUES(?,?,?,?)").run(token, nombre, ahora, ahora);
  }
  db.prepare("UPDATE config SET valor='1' WHERE clave='pedir_ingreso'").run();
  const config = async (token, body) => {
    const r = await fetch(base + "/api/config", { method: "POST", body: JSON.stringify(body),
      headers: { Cookie: "crm_sesion=" + token, "Content-Type": "application/json" } });
    return { status: r.status, ...(await r.json()) };
  };
  const valor = k => db.prepare("SELECT valor FROM config WHERE clave=?").get(k)?.valor;
  return { config, valor };
}

test("GAS-400: /api/config solo guarda claves conocidas, las secretas son del administrador y las horas se validan", async t => {
  const { config, valor } = await levantar(t);
  const pin = valor("pin_cierre");

  // Atención cambia lo de su pantalla.
  assert.equal((await config("s-atcl", { hora_resumen: "9", silencio_desde: "21", area_atcl: "AT Cliente" })).status, 200);
  assert.equal(valor("hora_resumen"), "9");

  // Clave inventada: no entra y no arrastra a las demás.
  const inventada = await config("s-atcl", { hora_resumen: "10", algo_nuevo: "x" });
  assert.equal(inventada.status, 400); assert.doesNotMatch(inventada.error, /algo_nuevo/);
  assert.equal(valor("hora_resumen"), "9"); assert.equal(valor("algo_nuevo"), undefined);

  // Las secretas no las toca Atención.
  for (const k of ["pin_cierre", "resend_key", "correo_desde"]) {
    const r = await config("s-atcl", { [k]: "otra" });
    assert.equal(r.status, 400, k); assert.match(r.error, /administrador/);
  }
  assert.equal(valor("pin_cierre"), pin); assert.equal(valor("resend_key"), undefined);

  // Horas: enteros de 0 a 23, nada de HTML.
  for (const mala of ['8"><img src=x>', "24", "-1", "7.5", ""])
    assert.equal((await config("s-atcl", { silencio_hasta: mala })).status, 400, mala);
  assert.equal(valor("silencio_hasta"), "8");

  // Siguen los controles de antes y el administrador puede todo lo permitido.
  assert.equal((await config("s-atcl", { modo_envio: "real" })).status, 400);
  assert.equal((await config("s-admin", { pin_cierre: "clave-ficticia", hora_resumen: "0" })).status, 200);
  assert.equal(valor("pin_cierre"), "clave-ficticia"); assert.equal(valor("hora_resumen"), "0");
  assert.equal((await config("s-admin", { otra_cosa: "1" })).status, 400);
});

test("GAS-402: la pestaña Avisos escapa las horas guardadas", () => {
  const html = fs.readFileSync(path.join(repo, "public/index.html"), "utf8");
  for (const k of ["hora_resumen", "silencio_desde", "silencio_hasta"])
    assert.ok(html.includes(`data-regla-n="${k}" value="\${esc(c.${k})}"`), k);
});
