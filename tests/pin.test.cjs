// GAS-401: la clave de cierre no viene fija en el código y sus intentos fallidos se frenan.
// Usa una copia temporal del CRM (ver crm-copia.cjs).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const { levantar, repo } = require("./crm-copia.cjs");

test("GAS-401: la siembra no trae una clave fija; una base nueva toma CRM_PIN_CIERRE o una al azar", async t => {
  const src = fs.readFileSync(path.join(repo, "server.js"), "utf8");
  const siembra = src.slice(src.indexOf("const CONFIG_INICIAL"), src.indexOf("function migrar"));
  assert.doesNotMatch(siembra, /pin_cierre/);

  const azar = await levantar(t);
  assert.match(azar.valor("pin_cierre"), /^\d{4}$/);

  const delEntorno = await levantar(t, { CRM_PIN_CIERRE: "4321" });
  assert.equal(delEntorno.valor("pin_cierre"), "4321");
});

test("GAS-401: cerrar con clave errada se frena tras 5 intentos, y acertar antes limpia el contador", async t => {
  const { post, pedido, estado } = await levantar(t, { CRM_PIN_CIERRE: "4321" });
  const id = pedido();
  const cerrar = pin => post("s-atcl", "/api/items/cerrar", { id: 999999, pin });

  for (let n = 0; n < 4; n++) assert.match((await cerrar("0000")).error, /Clave incorrecta/);
  // Con la clave buena pasa el control de la clave (y se queja de lo que sigue).
  assert.doesNotMatch((await cerrar("4321")).error, /Clave incorrecta|Demasiados/);

  for (let n = 0; n < 5; n++) assert.match((await cerrar("0000")).error, /Clave incorrecta/);
  assert.match((await cerrar("4321")).error, /Demasiados intentos/);
  // Anular un pedido que existe, con la clave buena, también queda frenado para esa persona.
  assert.match((await post("s-atcl", "/api/items/anular", { id, pin: "4321" })).error, /Demasiados intentos/);
  assert.equal(estado(id), "En curso");
  // Otra persona no queda frenada por los errores de la primera.
  assert.doesNotMatch((await post("s-admin", "/api/items/cerrar", { id: 999999, pin: "4321" })).error, /Clave incorrecta|Demasiados/);
  // Y anular exige la clave: errada no anula, buena sí.
  assert.match((await post("s-admin", "/api/items/anular", { id, pin: "0000" })).error, /Clave incorrecta/);
  assert.equal(estado(id), "En curso");
  assert.equal((await post("s-admin", "/api/items/anular", { id, pin: "4321" })).status, 200);
  assert.equal(estado(id), "Cerrado");
});
