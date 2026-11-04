/**
 * Oraculo: la condicion de exito de LinearMinClient.query() no puede aceptar un rechazo.
 *
 * Un 401/403 de Linear llega SIN `errors[]` (el rechazo es de transporte, no de GraphQL). Si la
 * condicion de exito solo mira que el status este por debajo de 500, ese rechazo entra por la
 * rama buena y devuelve `parsed.data`, que ahi es `undefined`: un token caducado se lee como una
 * consulta que no encontro nada, y ningun caller se entera. Este check existe para que esa
 * regresion no pueda volver en silencio.
 *
 * Uso:  npx tsx .claude/skills/linear-skill/scripts/check-fail-open-auth.ts
 * rc 0 = verde. rc 1 = rojo, con el caso que falla.
 *
 * El mock usa `Response` NATIVO a proposito: unas cabeceras falsas de objeto plano no tienen
 * `.get` ni `.forEach`, y el cliente las recorre — el check pasaria por la razon equivocada.
 */
import { LinearMinClient } from "./linear-client";

// ORACULO DE LA 5.a RONDA (estacion de merge). El mock construye la `Response` AQUI, al armarse,
// y NO dentro del `fetch`. La razon es un fallo medido: `new Response("", { status: 204 })` LANZA
// —la especificacion prohibe cuerpo en un 204— y, construyendola dentro del `fetch`, esa excepcion
// viajaba hasta el `catch` del caso y lo daba por «lanza» SIN QUE `query()` hubiera llegado a
// evaluar su condicion de exito. El caso pasaba en verde acreditando NADA: un verde por crash.
// Construyendola al armar, un status/cuerpo imposible revienta AQUI, en el marco del arnes, y no
// se puede confundir con el veredicto del sujeto.
function mockFetch(status: number, body: string | null) {
  const resp = new Response(body, { status, headers: { "content-type": "application/json" } });
  (globalThis as any).fetch = async () => resp.clone();
}

async function main() {
  let rojos = 0;
  let total = 0;

  async function caso(
    nombre: string,
    status: number,
    body: string | null,
    espera: "LANZA" | "DEVUELVE",
    valor?: unknown
  ) {
    total++;
    mockFetch(status, body);
    const c = new LinearMinClient({ apiKey: "no-usada-el-fetch-esta-mockeado", circuitBreaker: false });
    let lanzo = false;
    let ret: unknown = "___";
    try {
      ret = await c.query("{ viewer { id } }");
    } catch {
      lanzo = true;
    }
    const ok =
      espera === "LANZA" ? lanzo : !lanzo && JSON.stringify(ret) === JSON.stringify(valor);
    if (!ok) {
      rojos++;
      console.log(`  ROJO  ${nombre}: lanzo=${lanzo} ret=${JSON.stringify(ret)} (esperaba ${espera})`);
    } else {
      console.log(`  ok    ${nombre}`);
    }
  }

  // El defecto: rechazos de autenticacion SIN errors[] en el cuerpo.
  await caso("401 sin errors[] -> lanza", 401, '{"error":"unauthorized"}', "LANZA");
  await caso("403 sin errors[] -> lanza", 403, '{"error":"forbidden"}', "LANZA");
  // Vecinos de la misma clase: nada por debajo de 500 puede colarse como exito.
  await caso("400 sin errors[] -> lanza", 400, '{"error":"bad request"}', "LANZA");
  await caso("429 sin errors[] -> lanza", 429, '{"error":"rate limited"}', "LANZA");
  // 204 = SIN CUERPO de verdad (`null`), no una cadena vacia. Con `""` la `Response` ni siquiera se
  // puede construir, asi que este caso nunca probo la condicion de exito de `query()`.
  await caso("204 sin cuerpo   -> lanza", 204, null, "LANZA");
  await caso("200 con data:null -> lanza", 200, '{"data":null}', "LANZA");
  // CONTROL POSITIVO: sin esto, un `throw` incondicional pasaria el check entero.
  await caso("200 con data -> devuelve data", 200, '{"data":{"viewer":{"id":"u1"}}}', "DEVUELVE", {
    viewer: { id: "u1" },
  });

  // CONTROL DEL ARNES: que el mock se pueda ARMAR para cada combinacion que este check usa. Si
  // alguna `Response` no se puede construir, el caso correspondiente estaria pasando por crash y no
  // por veredicto — que es exactamente el defecto que este bloque cierra. Se comprueba aqui, en el
  // marco del arnes, donde un fallo NO se puede confundir con «el sujeto lanzo».
  total++;
  let armado_ok = true;
  let armado_err = "";
  try {
    mockFetch(204, null);
    mockFetch(200, '{"data":{}}');
    mockFetch(401, '{"error":"x"}');
  } catch (e) {
    armado_ok = false;
    armado_err = e instanceof Error ? e.message : String(e);
  }
  if (armado_ok) {
    console.log("  ok    CONTROL: el mock se ARMA para los tres status usados (nada pasa por crash)");
  } else {
    rojos++;
    console.log(`  ROJO  CONTROL: el mock NO se puede armar: ${armado_err}`);
  }

  // CONTROL NEGATIVO DEL CONTROL: la combinacion imposible tiene que seguir siendo imposible. Si
  // algun dia `new Response("", {status:204})` dejara de lanzar, el control de arriba pasaria a ser
  // vacuo y nadie se enteraria: aqui se afirma que el arnes SABE distinguir las dos formas.
  total++;
  let imposible_lanza = false;
  try {
    new Response("", { status: 204 });
  } catch {
    imposible_lanza = true;
  }
  if (imposible_lanza) {
    console.log('  ok    CONTROL NEGATIVO: `new Response("", {status:204})` sigue siendo imposible');
  } else {
    rojos++;
    console.log('  ROJO  CONTROL NEGATIVO: `new Response("", {status:204})` ya NO lanza — el control de armado quedo vacuo');
  }

  console.log(`  --- ambito: ${total} casos, ${rojos} rojo(s) ---`);
  process.exit(rojos === 0 ? 0 : 1);
}

main();
