// Copia temporal del CRM con el servidor simulado (sin WhatsApp, sin red), con un
// administrador y una persona de AT Cliente ficticios. Las sesiones se cargan
// directo en la base de la copia: «s-admin» y «s-atcl».
const { spawn } = require("node:child_process");
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const { DatabaseSync } = require("node:sqlite");

const repo = path.resolve(__dirname, "..");
const pausa = ms => new Promise(r => setTimeout(r, ms));

async function levantar(t, env = {}) {
  const copia = fs.mkdtempSync(path.join(os.tmpdir(), "crm-copia-"));
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "crm-copia-out-"));
  for (const f of ["server.js", "altas.js", "package.json", "public"]) fs.cpSync(path.join(repo, f), path.join(copia, f), { recursive: true });
  fs.writeFileSync(path.join(out, "transporte.json"), JSON.stringify({ fallar: [] }));
  const puertoFile = path.join(out, "puerto.json");
  const hijo = spawn(process.execPath, [path.join(__dirname, "servidor-simulado.cjs"), path.join(copia, "server.js")], {
    cwd: copia, stdio: "ignore",
    env: { PATH: process.env.PATH, PORT: "0", AUDIT_OUT: out, AUDIT_PORT_FILE: puertoFile, ...env } });
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
  const post = async (token, ruta, body) => {
    const r = await fetch(base + ruta, { method: "POST", body: JSON.stringify(body),
      headers: { Cookie: "crm_sesion=" + token, "Content-Type": "application/json" } });
    return { status: r.status, ...(await r.json()) };
  };
  const valor = k => db.prepare("SELECT valor FROM config WHERE clave=?").get(k)?.valor;
  // Un pedido abierto con datos ficticios, para las rutas que exigen uno.
  const pedido = () => {
    const tk = db.prepare("INSERT INTO tickets(numero,abonado,abierto,creado_en) VALUES('T-FICT','FICT-001',1,?)").run(ahora).lastInsertRowid;
    return Number(db.prepare(`INSERT INTO items(ticket_id,canal,tipo,descripcion,urgencia,area,estado,creado_en)
      VALUES(?,'Teléfono','Reclamo','Prueba ficticia',3,'Técnica','En curso',?)`).run(tk, ahora).lastInsertRowid);
  };
  return { post, valor, pedido, estado: id => db.prepare("SELECT estado FROM items WHERE id=?").get(id)?.estado,
           config: (token, body) => post(token, "/api/config", body) };
}

module.exports = { levantar, repo };
