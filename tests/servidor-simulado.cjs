// Sólo lo usa la auditoría de navegador con una copia temporal del CRM.
const fs = require("node:fs"), path = require("node:path"), Module = require("node:module");
const out = process.env.AUDIT_OUT;
if (!out || !process.argv[2]) throw Error("Se requiere una copia temporal y AUDIT_OUT");
const http = require("node:http"), listen = http.Server.prototype.listen;
http.Server.prototype.listen = function(...args) {
  this.once("listening", () => fs.writeFileSync(process.env.AUDIT_PORT_FILE, JSON.stringify(this.address().port)));
  return listen.apply(this, args);
};
globalThis.fetch = async () => { throw Error("Red exterior bloqueada en auditoría"); };
const wsp = { hayCredenciales: () => false, alCambiarEntrega() {},
  situacion: () => ({ estado: "conectado", numero: "FICTICIO" }),
  conectar: async () => {}, salir: async () => {}, verificar: async () => [],
  enviarMensaje: async (numero, texto) => {
    const estado = JSON.parse(fs.readFileSync(path.join(out, "transporte.json"), "utf8"));
    const fallo = (estado.fallar || []).includes(numero);
    fs.appendFileSync(path.join(out, "envios.jsonl"), JSON.stringify({ numero, texto, fallo }) + "\n");
    if (fallo) throw Error("WhatsApp desconectado (simulado)");
    return "ficticio-" + Date.now();
  } };
const planilla = { arrancar() {}, buscar: () => null, situacion: () => ({}), leer: async () => ({}) };
const load = Module._load;
Module._load = function(name, parent, isMain) {
  if (name === "./whatsapp") return wsp;
  if (name === "./planilla") return planilla;
  return load.call(this, name, parent, isMain);
};
require(process.argv[2]);
