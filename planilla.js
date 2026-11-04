// La planilla de clientes de Atención («Ayax Atencion Cliente», pestaña
// Clientes): domicilio, localidad, vendedor, administrador y servicios de cada
// abonado. El CRM la lee directo de Google con una cuenta de servicio y la
// guarda en memoria; al cargar un pedido, esos datos quedan en el pedido.
//
// Pedido de Gastón (11/10): «desde un nuevo pedido, si cargan el número de
// abonado, completar los datos que faltan del cliente tomando la planilla».
//
// Sin dependencias, como el resto: el token de Google se firma con node:crypto.
// Variables (solo en Railway):
//   GOOGLE_CUENTA_SERVICIO  el JSON de la clave de la cuenta de servicio
//   PLANILLA_CLIENTES_ID    opcional; por defecto la planilla de Atención
// Sin la cuenta de servicio no lee nada y los pedidos se cargan como siempre.

const crypto = require("node:crypto");

const PLANILLA = process.env.PLANILLA_CLIENTES_ID || "107gt9QOEqaMcD9anmFm5F8EM47l2OibLGOjW1ItzkWQ";
const RANGO = "Clientes";           // la pestaña entera, sin tope de filas ni columnas
const CADA = 30 * 60 * 1000;          // se vuelve a leer cada media hora
const SERVICIOS = ["VV", "VF", "RV", "CA", "A", "SF", "360", "TELEPASE"];

let clientes = new Map();             // clave → ficha
let estado = { clientes: 0, leida: null, error: null, configurada: false, sin_leer: [], repetidos: [] };
let permiso = null;                   // el token de Google dura una hora: se reusa
let leyendo = null;                   // una lectura a la vez

// El mismo abonado se escribe distinto en cada lado: la planilla dice «D179/0»,
// «DD10/0» o «4097/0»; en el CRM se carga «d179», «ca/d420», «vv-d212» o
// «ay/1549». Se compara por la letra pegada al número y el número sin ceros:
// D179, D10, 4097 («DD10» es D010 con relleno). Lo de adelante («ca/», «vv-»,
// «ay/») es el servicio. La partición va en la clave si no es la /0.
// Tiene que tener forma de código: una dirección cargada como abonado («Av
// Cordoba 1807») no debe tomar los datos del cliente 1807.
function clave(codigo) {
  const t = String(codigo || "").toUpperCase().trim();
  // Primero sin servicio adelante («D17/1» es D17, partición 1); si no cierra,
  // con servicio («a1/1437» es 1437). La partición tiene uno o dos dígitos.
  const m = t.match(/^(?:[A-Z0-9]{1,3}[\s\-\/]+)??(?:([A-Z])\1{0,2})?0*(\d+)(?:\/(\d{1,2}))?$/);
  if (!m) return null;
  return (m[1] || "") + m[2] + (m[3] && m[3] !== "0" ? "/" + m[3] : "");
}

function cuenta() {
  const crudo = process.env.GOOGLE_CUENTA_SERVICIO;
  if (!crudo) return null;
  try {
    const c = JSON.parse(crudo);
    return c.client_email && c.private_key ? c : null;
  } catch { return null; }
}

const b64 = (x) => Buffer.from(typeof x === "string" ? x : JSON.stringify(x)).toString("base64url");

async function token(c) {
  const ahora = Math.floor(Date.now() / 1000);
  if (permiso && permiso.vence > ahora + 60) return permiso.token;
  const cuerpo = b64({ alg: "RS256", typ: "JWT" }) + "." + b64({
    iss: c.client_email, scope: "https://www.googleapis.com/auth/spreadsheets.readonly",
    aud: "https://oauth2.googleapis.com/token", iat: ahora, exp: ahora + 3600,
  });
  const firma = crypto.sign("RSA-SHA256", Buffer.from(cuerpo), c.private_key).toString("base64url");
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${cuerpo}.${firma}` }),
    signal: AbortSignal.timeout(20000),
  });
  if (!r.ok) throw new Error(`Google no dio acceso (${r.status})`);
  const j = await r.json();
  permiso = { token: j.access_token, vence: ahora + (j.expires_in || 3600) };
  return permiso.token;
}

// Arma las fichas a partir de las filas. La fila de títulos es la que dice
// «CLIENTE» (arriba de ella hay una fila de conteos sueltos).
function fichas(filas) {
  const i = filas.findIndex(f => f.some(v => String(v).trim().toUpperCase() === "CLIENTE"));
  if (i < 0) throw new Error("La pestaña Clientes no tiene la columna CLIENTE");
  const titulos = filas[i].map(v => String(v).trim().toUpperCase());
  const col = (nombre) => titulos.indexOf(nombre);
  const [cCod, cDom, cLoc, cVen, cAdm] = ["CLIENTE", "DOMICILIO", "LOCALIDAD", "VENDEDOR", "ADMINISTRADOR"].map(col);
  // Las columnas de servicios son las primeras con ese título: más a la
  // derecha se repiten siglas en la tabla de referencias («Servicios»).
  const cServ = SERVICIOS.map(s => [s, col(s)]).filter(([, c]) => c >= 0);
  const dato = (f, c) => (c >= 0 ? String(f[c] ?? "").trim() : "");
  const salida = new Map(), sin_leer = [], vistas = new Map();
  for (const f of filas.slice(i + 1)) {
    const codigo = dato(f, cCod);
    if (!codigo) continue;
    const k = clave(codigo);
    if (!k) { sin_leer.push(codigo); continue; }
    vistas.set(k, (vistas.get(k) || []).concat(codigo));
    // Solo cantidades: hay celdas con #REF! que no son un servicio contratado.
    const servicios = cServ
      .map(([s, c]) => [s, dato(f, c)]).filter(([, v]) => /^[1-9]\d*$/.test(v))
      .map(([s, v]) => (v === "1" ? s : `${s} ×${v}`)).join(", ");
    salida.set(k, {
      codigo: dato(f, cCod), domicilio: dato(f, cDom), localidad: dato(f, cLoc),
      vendedor: dato(f, cVen), administrador: dato(f, cAdm), servicios,
    });
  }
  // Dos filas con la misma clave: no se sabe cuál es, así que ninguna. Mejor
  // un pedido sin domicilio que con el domicilio y el vendedor de otro cliente.
  const repetidos = [...vistas.values()].filter(v => v.length > 1);
  for (const v of repetidos) salida.delete(clave(v[0]));
  return { salida, sin_leer, repetidos };
}

function leer() {
  if (!leyendo) leyendo = leerUnaVez().finally(() => { leyendo = null; });
  return leyendo;
}

async function leerUnaVez() {
  const c = cuenta();
  estado.configurada = !!c;
  if (!c) return;
  try {
    const r = await fetch(`https://sheets.googleapis.com/v4/spreadsheets/${PLANILLA}/values/${encodeURIComponent(RANGO)}`,
      { headers: { Authorization: `Bearer ${await token(c)}` }, signal: AbortSignal.timeout(30000) });
    if (r.status === 403 || r.status === 404)
      throw new Error(`No puedo abrir la planilla: hay que compartirla con ${c.client_email}`);
    if (!r.ok) throw new Error(`Google contestó ${r.status} al leer la planilla`);
    const { salida: nuevas, sin_leer, repetidos } = fichas((await r.json()).values || []);
    if (!nuevas.size) throw new Error("La planilla no trajo ningún cliente");
    clientes = nuevas;
    estado = { clientes: nuevas.size, leida: Date.now(), error: null, configurada: true, sin_leer, repetidos };
    if (alLeer) alLeer();
  } catch (e) {
    // Se queda con lo último que leyó bien: un corte de Google no borra los datos.
    estado.error = e.message;
    console.error("  planilla de clientes:", e.message);
  }
}

// alLeer: lo que hace el servidor cada vez que la planilla se leyó bien
// (completar los pedidos abiertos que se cargaron sin sus datos).
let alLeer = null;
function arrancar(despues) {
  alLeer = despues;
  leer();
  setInterval(leer, CADA).unref();
}

const buscar = (codigo) => clientes.get(clave(codigo)) || null;

module.exports = { arrancar, leer, buscar, clave, fichas, situacion: () => ({ ...estado }) };
