// GAS-403: tope de 1 MB al cuerpo de los pedidos. GAS-404: horas, plazos y preaviso validados.
// Usa una copia temporal del CRM (ver crm-copia.cjs).
const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { levantar } = require("./crm-copia.cjs");

// Pedido por partes, sin Content-Length: el tope tiene que cortar igual. Sin `completo`,
// deja de escribir en cuanto llega la respuesta y nunca cierra el pedido (un cliente que
// queda colgado). Con `completo`, manda todo y cierra el pedido.
function porPartes(base, ruta, partes, tam, { agent = new http.Agent({ keepAlive: true }), completo = false } = {}) {
  return new Promise((resolve, reject) => {
    let respuesta = null;
    // Con keep-alive el cliente no cierra solo: si la conexión se cierra, la cerró el servidor.
    const req = http.request(base + ruta, { method: "POST", agent, headers: { "Content-Type": "application/json" } }, res => {
      respuesta = { status: res.statusCode, txt: "", socket: req.socket, cerrada: new Promise(r => req.socket.once("close", () => r(true))) };
      res.on("data", c => (respuesta.txt += c));
      res.on("end", () => resolve(respuesta)); res.on("error", reject);
    });
    req.on("error", e => (respuesta ? resolve(respuesta) : reject(e)));
    const trozo = "x".repeat(tam);
    let n = 0;
    const seguir = () => {
      const parar = () => req.destroyed || (respuesta && !completo);
      while (n < partes && !parar()) { n++; if (!req.write(trozo)) return req.once("drain", seguir); }
      if (completo && !req.destroyed) req.end();
    };
    seguir();
  });
}

test("GAS-403: un pedido de más de 1 MB recibe 413 y el CRM sigue atendiendo", async t => {
  const { base, post, valor } = await levantar(t);
  const grande = await post("s-admin", "/api/config", { hora_resumen: "9", relleno: "x".repeat(1100 * 1024) });
  assert.equal(grande.status, 413); assert.match(grande.error, /demasiado grande/);
  assert.notEqual(valor("hora_resumen"), "9");

  const partes = await porPartes(base, "/api/ingresar", 40, 64 * 1024); // 2,5 MB sin Content-Length
  assert.equal(partes.status, 413); assert.match(partes.txt, /demasiado grande/);
  // Quien sigue mandando después del 413 queda cortado a los 2 s.
  const plazo = ms => new Promise(r => setTimeout(() => r(false), ms));
  assert.equal(await Promise.race([partes.cerrada, plazo(4000)]), true, "cerró mientras seguía mandando");

  // Quien terminó de mandar (1,1 MB) conserva la conexión: un pedido válido por esa
  // misma conexión, pasados los 2 s, se atiende entero.
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  const terminado = await porPartes(base, "/api/ingresar", 18, 64 * 1024, { agent, completo: true });
  assert.equal(terminado.status, 413);
  const otro = new Promise((resolve, reject) => {
    const req = http.request(base + "/api/quien", { agent }, res => {
      let txt = ""; res.on("data", c => (txt += c)); res.on("end", () => resolve({ status: res.statusCode, socket: req.socket }));
      res.on("error", reject);
    });
    req.on("error", reject); setTimeout(() => req.end(), 2500);
  });
  const segundo = await otro;
  assert.equal(segundo.status, 200); assert.equal(segundo.socket, terminado.socket, "reusó la misma conexión");
  agent.destroy();

  // Un pedido normal sigue funcionando.
  assert.equal((await post("s-admin", "/api/config", { hora_resumen: "9" })).status, 200);
  assert.equal(valor("hora_resumen"), "9");
});

test("GAS-404: hora_fin_dia, plazos y preaviso se validan antes de guardar", async t => {
  const { config, valor } = await levantar(t);
  for (const mala of ["24", "-1", "7.5", "abc", ""])
    assert.equal((await config("s-admin", { hora_fin_dia: mala })).status, 400, `hora_fin_dia=${mala}`);
  for (const mala of ["0", "-1", "abc", "", "9000", "1.555"])
    assert.equal((await config("s-admin", { horas_u3: mala })).status, 400, `horas_u3=${mala}`);
  for (const mala of ["0", "100", "7.5", "abc", ""])
    assert.equal((await config("s-admin", { pct_preaviso: mala })).status, 400, `pct_preaviso=${mala}`);
  assert.equal(valor("hora_fin_dia"), "18"); assert.equal(valor("horas_u3"), "24"); assert.equal(valor("pct_preaviso"), "75");

  // Lo que manda «Guardar» de la pantalla de plazos sigue entrando.
  const r = await config("s-atcl", { horas_u1: "1.5", horas_u3: "24", horas_u4: "48", hora_fin_dia: "17", pct_preaviso: "80",
    url_panel: valor("url_panel") });
  assert.equal(r.status, 200, r.error);
  assert.equal(valor("horas_u1"), "1.5"); assert.equal(valor("hora_fin_dia"), "17"); assert.equal(valor("pct_preaviso"), "80");
  assert.equal((await config("s-atcl", { horas_u4: ".5" })).status, 200);
});
