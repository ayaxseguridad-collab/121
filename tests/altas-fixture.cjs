const { DatabaseSync } = require("node:sqlite");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// SQLite real y transporte completamente falso: no importa whatsapp.js,
// no lee credenciales y no usa la red. El reloj permite probar los reintentos.
function crear({ db = new DatabaseSync(":memory:"), source } = {}) {
  db.exec(`CREATE TABLE IF NOT EXISTS listas (id INTEGER PRIMARY KEY, tipo TEXT, valor TEXT, orden INTEGER);
    CREATE TABLE IF NOT EXISTS usuarios (nombre TEXT PRIMARY KEY, area TEXT, telefono TEXT, activo INTEGER DEFAULT 1);
    CREATE TABLE IF NOT EXISTS telefonos (id INTEGER PRIMARY KEY, area TEXT, numero TEXT, nombre TEXT);`);
  const f = { db, rutas: {}, timers: [], envios: [], ahora: Date.now(), real: true,
    config: { url_panel: "https://crm.example.invalid", altas_plazos: "0" },
    enviar: async () => "mensaje-ficticio" };
  class Reloj extends Date { static now() { return f.ahora; } }
  const sandbox = { module: { exports: {} }, Date: Reloj, console,
    setInterval: fn => { f.timers.push(fn); } };
  vm.runInNewContext(source || readFileSync(path.join(__dirname, "../altas.js"), "utf8"), sandbox);
  sandbox.module.exports({ db, rutas: f.rutas, cfg: k => f.config[k],
    pideIngreso: () => true, quien: () => ({ nombre: "Auditor ficticio", rol: "admin" }),
    mandaDeVerdad: () => f.real, SOLO_ADMIN: new Set(),
    telefonosDe: area => [
      ...db.prepare("SELECT telefono AS numero, nombre FROM usuarios WHERE area=? AND activo=1 AND telefono IS NOT NULL AND telefono<>''").all(area),
      ...db.prepare("SELECT numero, nombre FROM telefonos WHERE area=?").all(area)],
    wsp: { enviarMensaje: async (numero, texto) => {
      f.envios.push({ numero, texto }); return f.enviar(numero, texto);
    } } });
  f.call = (ruta, b = {}) => f.rutas[ruta](b);
  f.listar = () => f.call("GET /api/altas");
  f.crearAlta = () => f.call("POST /api/altas", { cliente: "Cliente ficticio", abonado: "FICT-001" });
  f.paso = (alta, paso, extra = {}) => f.call("POST /api/altas/paso", { alta, paso, estado: "completado", ...extra });
  f.avisos = alta => db.prepare("SELECT * FROM alta_avisos WHERE alta_id=? ORDER BY id").all(alta);
  f.drain = () => new Promise(resolve => setImmediate(resolve));
  f.tick = async (ms = 0) => { f.ahora += ms; for (const fn of f.timers) fn(); await f.drain(); };
  f.sembrar = () => {
    for (const [i, area] of ["AT Cliente", "Monitoreo", "Comercial", "Técnica", "Administración"].entries()) {
      db.prepare("INSERT OR IGNORE INTO listas(id,tipo,valor,orden) VALUES(?,'area',?,?)").run(i + 1, area, i);
      db.prepare("INSERT OR IGNORE INTO usuarios(nombre,area,telefono) VALUES(?,?,?)").run("Ficticio " + area, area, "357140000" + i);
    }
    db.prepare("INSERT OR IGNORE INTO usuarios(nombre,area,telefono) VALUES('Gastón','','3571400009')").run();
  };
  f.resolverResto = alta => {
    for (const p of f.listar().pasos) db.prepare(`INSERT INTO alta_pasos(alta_id,paso,estado) VALUES(?,?,'completado')
      ON CONFLICT(alta_id,paso) DO UPDATE SET estado='completado'`).run(alta, p.id);
  };
  return f;
}
module.exports = { crear };
