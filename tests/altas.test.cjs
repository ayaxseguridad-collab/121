const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path"), vm = require("node:vm");
const { crear } = require("./altas-fixture.cjs");
const plano = x => JSON.parse(JSON.stringify(x));
function fixture(t) { const f = crear(); f.sembrar(); t.after(() => f.db.close()); return f; }

for (const estado of ["completado", "no_aplica"]) test(`Punto 8: ${estado} no crea ni envía avisos, aunque el cliente pida destinos`, async t => {
  const f = fixture(t), a = f.crearAlta();
  f.paso(a.id, "8", { estado, nota: "Dato ficticio", areas: ["Comercial"], usuarios: ["Gastón"] });
  await f.tick(86400000);
  assert.equal(f.avisos(a.id).length, 0); assert.equal(f.envios.length, 0);
  assert.equal(f.listar().altas[0].pasos.find(p => p.paso === "8").estado, estado);
});

test("Punto 12: cuatro destinatarios fijos, texto correcto y Alta todavía abierta con pendientes", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.paso(a.id, "12", { areas: ["Técnica"], usuarios: ["Intruso"] });
  await f.drain();
  const [v] = f.avisos(a.id), alta = f.listar().altas[0];
  assert.equal(f.avisos(a.id).length, 1); assert.equal(f.envios.length, 4);
  assert.deepEqual(JSON.parse(v.para), { areas: ["AT Cliente", "Monitoreo", "Comercial"], usuarios: ["Gastón"] });
  assert.match(v.texto, /Servicio operativo verificado/); assert.doesNotMatch(v.texto, /Alta finalizada/);
  assert.match(v.texto, new RegExp("alta=" + a.id));
  assert.equal(v.estado, "mandado"); assert.equal(alta.cerrada_en, null); assert.ok(alta.pendientes > 0);
  assert.equal(alta.servicio_aviso_registrado, true);
  assert.throws(() => f.call("POST /api/altas/finalizar", { alta: a.id }), /faltan/);
});

test("Punto 12 no admite No aplica y una nota sola no avisa", t => {
  const f = fixture(t), a = f.crearAlta();
  assert.throws(() => f.paso(a.id, "12", { estado: "no_aplica", nota: "Prueba" }), /no puede/);
  f.call("POST /api/altas/nota", { alta: a.id, paso: "12", nota: "Aún falta verificar" });
  assert.equal(f.avisos(a.id).length, 0);
});

test("Doble confirmación durante un envío en curso no duplica registro ni destinatarios", async t => {
  const f = fixture(t), a = f.crearAlta(); let liberar;
  const espera = new Promise(resolve => { liberar = resolve; });
  f.enviar = () => espera;
  f.paso(a.id, "12");
  assert.throws(() => f.paso(a.id, "12"), /ya estaba resuelto/);
  await f.tick(180000); // Ni el motor simultáneo puede reenviar el aviso en vuelo.
  assert.equal(f.envios.length, 1); assert.equal(f.avisos(a.id).length, 1);
  liberar(); await f.drain();
  assert.equal(f.envios.length, 4);
});

test("Finalización posterior y doble finalización conservan un solo aviso del paso 12", async t => {
  const f = fixture(t), a = f.crearAlta(); f.paso(a.id, "12"); await f.drain();
  f.resolverResto(a.id);
  const cerrada = f.call("POST /api/altas/finalizar", { alta: a.id });
  assert.ok(cerrada.cerrada_en);
  assert.throws(() => f.call("POST /api/altas/finalizar", { alta: a.id }), /ya estaba finalizada/);
  await f.tick(86400000);
  assert.equal(f.envios.length, 4); assert.equal(f.avisos(a.id).length, 1);
});

test("Cliente anterior: dibuja el Alta lista y la finalización conserva un único aviso", async t => {
  const f = fixture(t), a = f.crearAlta(); f.paso(a.id, "12"); await f.drain();
  f.resolverResto(a.id);
  // Copia exacta del cliente de d65f5e1: no requiere Git ni red al ejecutar las pruebas.
  const cliente = readFileSync(path.join(__dirname, "fixtures/altas-cliente-d65f5e1.js"), "utf8");
  const ctx = { document: { addEventListener() {} }, esc: x => String(x ?? ""), tiempo: String };
  vm.createContext(ctx); vm.runInContext(cliente, ctx);
  const datos = f.listar(), alta = datos.altas.find(x => x.id === a.id);
  assert.deepEqual(plano(datos.aviso_final), ["AT Cliente", "Monitoreo", "Comercial", "Gastón"]);
  assert.match(ctx.detalleAlta(alta, datos), /Finalizar Alta/);
  // Control negativo: reproduce el defecto señalado por el auditor.
  const sinCompatibilidad = { ...datos }; delete sinCompatibilidad.aviso_final;
  assert.throws(() => ctx.detalleAlta(alta, sinCompatibilidad), /join/);
  const cerrada = f.call("POST /api/altas/finalizar", { alta: a.id }); await f.drain();
  assert.ok(cerrada.cerrada_en); assert.equal(f.envios.length, 4); assert.equal(f.avisos(a.id).length, 1);
});

test("Desmarcar, reiniciar y completar otra vez no crea otro aviso", async t => {
  const f = fixture(t), a = f.crearAlta(); f.paso(a.id, "12"); await f.drain();
  f.call("POST /api/altas/desmarcar", { alta: a.id, paso: "12" });
  const reinicio = crear({ db: f.db }); reinicio.paso(a.id, "12"); await reinicio.tick(86400000);
  assert.equal(reinicio.envios.length, 0); assert.equal(reinicio.avisos(a.id).length, 1);
});

test("La marca persiste aunque se borre el registro de avisos", async t => {
  const f = fixture(t), a = f.crearAlta(); f.paso(a.id, "12"); await f.drain();
  f.call("POST /api/altas/desmarcar", { alta: a.id, paso: "12" });
  f.db.exec("DELETE FROM alta_avisos"); f.paso(a.id, "12"); await f.drain();
  assert.equal(f.envios.length, 4); assert.equal(f.avisos(a.id).length, 0);
});

for (const modo of ["sin usuario", "sin teléfono", "inactivo", "inválido"]) test(`Gastón ${modo}: visible y nunca marcado como envío completo`, async t => {
  const f = fixture(t), a = f.crearAlta();
  if (modo === "sin usuario") f.db.exec("DELETE FROM usuarios WHERE nombre='Gastón'");
  if (modo === "sin teléfono") f.db.exec("UPDATE usuarios SET telefono='' WHERE nombre='Gastón'");
  if (modo === "inactivo") f.db.exec("UPDATE usuarios SET activo=0 WHERE nombre='Gastón'");
  if (modo === "inválido") f.db.exec("UPDATE usuarios SET telefono='123' WHERE nombre='Gastón'");
  const alcance = f.call("POST /api/altas/alcance", { paso: "12", areas: ["Técnica"] });
  assert.deepEqual(plano(alcance.faltantes), ["Gastón"]); assert.equal(alcance.contactos, 3);
  f.paso(a.id, "12"); await f.drain(); const [v] = f.avisos(a.id);
  assert.equal(v.estado, "fallo"); assert.match(v.detalle, /Sin teléfono válido en Personas: Gastón/);
  assert.ok(v.prox_intento); assert.equal(f.envios.length, 3);
  f.db.prepare("INSERT INTO usuarios(nombre,area,telefono,activo) VALUES('Gastón','','3571400009',1) ON CONFLICT(nombre) DO UPDATE SET telefono=excluded.telefono,activo=1").run();
  await f.tick(5 * 60000);
  assert.equal(f.avisos(a.id)[0].estado, "mandado"); assert.equal(f.envios.length, 4);
  assert.equal(f.envios.at(-1).numero, "3571400009");
});

test("Un área ausente no se interpreta como persona ni se oculta con las demás", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.db.exec("DELETE FROM listas WHERE valor='Monitoreo'; DELETE FROM usuarios WHERE area='Monitoreo'");
  f.paso(a.id, "12"); await f.drain(); const [v] = f.avisos(a.id);
  assert.match(v.detalle, /Monitoreo/); assert.equal(v.estado, "fallo");
  assert.ok(JSON.parse(v.para).areas.includes("Monitoreo"));
});

test("Sin contactos: reintentos limitados y recuperación manual visible", async t => {
  const f = fixture(t), a = f.crearAlta(); f.db.exec("UPDATE usuarios SET telefono=NULL");
  f.paso(a.id, "12"); await f.drain();
  assert.equal(f.avisos(a.id)[0].estado, "sin_destino");
  for (let i = 1; i < 5; i++) await f.tick(i * 5 * 60000);
  const [v] = f.avisos(a.id);
  assert.equal(v.intentos, 5); assert.equal(v.prox_intento, null); assert.equal(f.envios.length, 0);
  assert.equal(f.listar().altas[0].avisos[0].reenviable, true);
  f.db.exec("UPDATE usuarios SET telefono='3571400009' WHERE nombre='Gastón'");
  await f.call("POST /api/altas/reenviar", { aviso: v.id });
  assert.equal(f.envios.length, 1); assert.equal(f.avisos(a.id)[0].estado, "fallo");
});

test("Fallo parcial: el motor reintenta sólo el teléfono fallido, incluso después de finalizar", async t => {
  const f = fixture(t), a = f.crearAlta(); let falla = true;
  f.enviar = async n => { if (falla && n === "3571400009") throw Error("WhatsApp desconectado (simulado)"); };
  f.paso(a.id, "12"); await f.drain();
  const [v] = f.avisos(a.id);
  assert.equal(v.estado, "fallo"); assert.equal(JSON.parse(v.entregados).length, 3);
  assert.match(v.detalle, /WhatsApp desconectado/);
  f.resolverResto(a.id); f.call("POST /api/altas/finalizar", { alta: a.id });
  falla = false; await f.tick(5 * 60000);
  assert.equal(f.envios.length, 5); assert.equal(f.envios.at(-1).numero, "3571400009");
  assert.equal(f.avisos(a.id).length, 1); assert.equal(f.avisos(a.id)[0].estado, "mandado");
});

test("Reintentos agotados: Reenviar conserva éxitos previos; doble reenvío no duplica", async t => {
  const f = fixture(t), a = f.crearAlta(); let falla = true;
  f.enviar = async n => { if (falla && n === "3571400009") throw Error("Fallo simulado"); };
  f.paso(a.id, "12"); await f.drain();
  for (let i = 1; i < 5; i++) await f.tick(i * 5 * 60000);
  const [v] = f.avisos(a.id);
  assert.equal(v.intentos, 5); assert.equal(v.prox_intento, null); assert.equal(f.envios.length, 8);
  assert.match(v.detalle, /reintentos agotados/);
  falla = false;
  const envio = f.call("POST /api/altas/reenviar", { aviso: v.id });
  await assert.rejects(f.call("POST /api/altas/reenviar", { aviso: v.id }), /no se puede reenviar/);
  await envio;
  assert.equal(f.envios.length, 9); assert.equal(f.avisos(a.id)[0].estado, "mandado");
});

test("Teléfono compartido y distinto formato: un solo envío por número normalizado", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.db.exec("UPDATE usuarios SET telefono='+54 9 3571 400000' WHERE nombre='Gastón'");
  const alcance = f.call("POST /api/altas/alcance", { paso: "12" });
  assert.equal(alcance.contactos, 3); assert.equal(alcance.faltantes.length, 0);
  f.paso(a.id, "12"); await f.drain(); assert.equal(f.envios.length, 3);
});

test("Transacción fallida no consume la marca ni deja el paso confirmado", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.db.exec("CREATE TRIGGER romper BEFORE INSERT ON alta_avisos BEGIN SELECT RAISE(ABORT,'fallo ficticio'); END");
  assert.throws(() => f.paso(a.id, "12"), /fallo ficticio/);
  assert.equal(f.db.prepare("SELECT COUNT(*) n FROM alta_servicio_avisado").get().n, 0);
  assert.equal(f.listar().altas[0].pasos.find(p => p.paso === "12").estado, "pendiente");
  f.db.exec("DROP TRIGGER romper"); f.paso(a.id, "12"); await f.drain(); assert.equal(f.avisos(a.id).length, 1);
});

test("Altas anteriores completas: arranque, motor, finalización y nueva confirmación no avisan retroactivamente", async t => {
  const f = fixture(t), a = f.crearAlta(); f.resolverResto(a.id);
  const reinicio = crear({ db: f.db }); await reinicio.tick(86400000);
  assert.equal(reinicio.envios.length, 0); assert.equal(reinicio.avisos(a.id).length, 0);
  reinicio.call("POST /api/altas/desmarcar", { alta: a.id, paso: "12" });
  reinicio.paso(a.id, "12"); reinicio.call("POST /api/altas/finalizar", { alta: a.id });
  await reinicio.drain(); assert.equal(reinicio.envios.length, 0);
});

test("Alta existente con paso 12 pendiente: una confirmación nueva sí avisa", async t => {
  const f = fixture(t), a = f.crearAlta(); const reinicio = crear({ db: f.db });
  reinicio.paso(a.id, "12"); await reinicio.drain();
  assert.equal(reinicio.avisos(a.id).length, 1); assert.equal(reinicio.envios.length, 4);
});

test("Un aviso de plazo anterior del paso 12 no cuenta como verificación del servicio", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.db.prepare("INSERT INTO alta_avisos(alta_id,paso,tipo,texto,ts,estado) VALUES(?,'12','vencido','Plazo anterior',?,'simulado')").run(a.id, f.ahora);
  const reinicio = crear({ db: f.db }); reinicio.paso(a.id, "12"); await reinicio.drain();
  assert.equal(reinicio.envios.length, 4); assert.equal(reinicio.avisos(a.id).length, 2);
});

test("Cola anterior: conserva reintentos y texto; un aviso final previo también impide otro del paso 12", async t => {
  const f = fixture(t), a = f.crearAlta();
  f.db.prepare(`INSERT INTO alta_avisos(alta_id,tipo,texto,ts,estado,intentos,entregados,prox_intento,para)
    VALUES(?,'final','Mensaje final anterior',?,'fallo',1,?, ?,?)`).run(a.id, f.ahora, JSON.stringify(["5493571400000"]), f.ahora - 1,
      JSON.stringify({ areas: ["AT Cliente", "Monitoreo", "Comercial"], usuarios: ["Gastón"] }));
  const reinicio = crear({ db: f.db }); await reinicio.tick();
  assert.equal(reinicio.envios.length, 3); assert.ok(reinicio.envios.every(e => e.texto === "Mensaje final anterior"));
  reinicio.paso(a.id, "12"); await reinicio.drain(); assert.equal(reinicio.envios.length, 3);
  assert.equal(reinicio.avisos(a.id).length, 1);
});

test("Modo copia: registra simulación sin llamar al transporte", async t => {
  const f = fixture(t), a = f.crearAlta(); f.real = false; f.paso(a.id, "12"); await f.tick(86400000);
  assert.equal(f.envios.length, 0); assert.equal(f.avisos(a.id)[0].estado, "simulado");
});

test("Regresión del punto 6: conserva Técnica y Comercial; No aplica no avisa", async t => {
  const f = fixture(t), a = f.crearAlta(), b = f.crearAlta();
  f.paso(a.id, "6"); f.paso(b.id, "6", { estado: "no_aplica", nota: "Ficticio" }); await f.drain();
  assert.deepEqual(JSON.parse(f.avisos(a.id)[0].para).areas, ["Técnica", "Comercial"]);
  assert.equal(f.envios.length, 2); assert.equal(f.avisos(b.id).length, 0);
});
