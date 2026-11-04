// GAS-400 y GAS-402: qué se puede cambiar por «POST /api/config» y quién.
// Usa una copia temporal del CRM (ver crm-copia.cjs).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path");
const { levantar, repo } = require("./crm-copia.cjs");

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
