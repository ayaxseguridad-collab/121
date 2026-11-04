// CRM Atención al Cliente — versión local para probar y ajustar.
//
// Server sin dependencias: Node + SQLite nativo (node:sqlite). Guarda los
// datos en datos/crm.db, al lado de este archivo.
//
// Arranca con:  node server.js     → http://localhost:3200

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const wsp = require("./whatsapp");
const planilla = require("./planilla");

// Cuántos reclamos devuelve el buscador. Eran 25 y los viejos quedaban afuera:
// alcanzaba con que un abonado tuviera 25 pedidos más nuevos para que el de hace
// un año no apareciera nunca. Con 300 entra cualquier historia real, y si aun así
// sobran, la lista avisa cuántos quedaron sin mostrar.
const TOPE_BUSQUEDA = 300;

// Cuántos pedidos muestra Seguimiento. Eran 60: con el ritmo de reclamos, eso es
// poco más de un mes y todo lo anterior quedaba fuera de la pantalla.
const TOPE_SEGUIMIENTO = 300;

const PUERTO = process.env.PORT || 3200;
const DIR = __dirname;

// Solo el CRM de la nube manda avisos de verdad. Toda copia —una prueba en /tmp,
// el proyecto abierto en la máquina de alguien, un respaldo restaurado— arranca
// con la base tal cual, o sea con "modo real" y con los teléfonos y correos que
// esa base tenía el día que se copió. Sin esta marca, una copia olvidada prendida
// sigue mandando WhatsApp y correos al personal, con datos viejos y links viejos,
// y nadie se entera de dónde salen. Ya pasó dos veces.
const ES_PRODUCCION = process.env.CRM_PRODUCCION === "1";
// La versión sale de package.json, que es el único lugar donde se toca.
const VERSION = require(path.join(DIR, "package.json")).version;
const DIR_DATOS = path.join(DIR, "datos");

const DIR_COPIAS = path.join(DIR_DATOS, "copias");
const ARCHIVO_DB = path.join(DIR_DATOS, "crm.db");
const PENDIENTE = path.join(DIR_DATOS, "pendiente-restaurar.db");

fs.mkdirSync(DIR_DATOS, { recursive: true });
fs.mkdirSync(DIR_COPIAS, { recursive: true });

// Para mudanzas: al estrenar un servidor, la base que vale quedó en la máquina
// vieja. Se la puede pasar por la variable CRM_BASE_INICIAL, comprimida y en
// texto, sin que los datos pasen nunca por el repositorio.
//
// Se aplica una sola vez por servidor: al hacerlo queda una marca en el disco,
// y mientras esa marca esté, ningún reinicio vuelve a tocar la base. Si había
// algo cargado, se guarda como copia antes de reemplazarlo.
const MARCA_MUDANZA = path.join(DIR_DATOS, ".base-inicial-aplicada");
if (process.env.CRM_BASE_INICIAL && !fs.existsSync(MARCA_MUDANZA)) {
  try {
    const zlib = require("node:zlib");
    if (fs.existsSync(ARCHIVO_DB))
      fs.copyFileSync(ARCHIVO_DB, path.join(DIR_COPIAS, `antes-de-la-mudanza-${sello()}.db`));
    fs.writeFileSync(ARCHIVO_DB, zlib.gunzipSync(Buffer.from(process.env.CRM_BASE_INICIAL, "base64")));
    fs.writeFileSync(MARCA_MUDANZA, new Date().toISOString());
    console.log("  base inicial cargada desde CRM_BASE_INICIAL");
  } catch (e) {
    console.error("  no pude cargar la base inicial:", e.message);
  }
}

// Si quedó una restauración pedida desde el panel, se aplica ahora, antes de
// abrir la base. La que estaba se guarda como copia por si acaso.
if (fs.existsSync(PENDIENTE)) {
  try {
    if (fs.existsSync(ARCHIVO_DB))
      fs.copyFileSync(ARCHIVO_DB, path.join(DIR_COPIAS, `antes-de-restaurar-${sello()}.db`));
    fs.copyFileSync(PENDIENTE, ARCHIVO_DB);
    fs.unlinkSync(PENDIENTE);
    console.log("  Se restauró la copia pedida desde el panel.");
  } catch (e) {
    console.error("  No se pudo restaurar:", e.message);
  }
}

function sello(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

const db = new DatabaseSync(ARCHIVO_DB);

// ── Esquema ────────────────────────────────────────────────────────────────
db.exec(`
CREATE TABLE IF NOT EXISTS abonados (
  codigo TEXT PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT
);
CREATE TABLE IF NOT EXISTS tickets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero TEXT NOT NULL,
  abonado TEXT NOT NULL,
  abierto INTEGER NOT NULL DEFAULT 1,
  creado_en INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket_id INTEGER NOT NULL,
  canal TEXT NOT NULL,
  tipo TEXT NOT NULL,
  descripcion TEXT NOT NULL,
  urgencia INTEGER NOT NULL,
  area TEXT NOT NULL,
  bykom TEXT,
  estado TEXT NOT NULL,
  creado_en INTEGER NOT NULL,
  vence_en INTEGER,
  cerrado_en INTEGER,
  motivo_cierre TEXT,
  causa_raiz TEXT
);
CREATE TABLE IF NOT EXISTS listas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tipo TEXT NOT NULL,
  valor TEXT NOT NULL,
  reloj INTEGER NOT NULL DEFAULT 1,
  orden INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS config (
  clave TEXT PRIMARY KEY,
  valor TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS movimientos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id INTEGER NOT NULL,
  texto TEXT NOT NULL,
  ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS contactos (
  area TEXT PRIMARY KEY,
  whatsapp TEXT,
  correo TEXT
);
-- Varios teléfonos y correos por área: el aviso les llega a todos.
CREATE TABLE IF NOT EXISTS telefonos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  area TEXT NOT NULL,
  numero TEXT NOT NULL,
  nombre TEXT,
  creado_en INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS correos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  area TEXT NOT NULL,
  direccion TEXT NOT NULL,
  nombre TEXT,
  creado_en INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS usuarios (
  nombre TEXT PRIMARY KEY,         -- la persona: es con esto que entra
  area TEXT NOT NULL DEFAULT '',   -- su sector. El administrador puede no tener
  telefono TEXT,                   -- para los avisos de su área
  correo TEXT,
  clave TEXT NOT NULL,             -- guardada cifrada, nunca en claro
  rol TEXT NOT NULL DEFAULT 'area',-- area | admin
  -- Si está en 1 solo ve los pedidos que su área pidió o recibió. Se elige por
  -- persona, no por rol: alguien de un área puede necesitar ver el conjunto sin
  -- que haya que darle además todos los permisos de administrador.
  solo_su_area INTEGER NOT NULL DEFAULT 1,
  -- Si recibe el resumen diario de su área. Los demás avisos le llegan igual.
  recibe_resumen INTEGER NOT NULL DEFAULT 1,
  activo INTEGER NOT NULL DEFAULT 1,
  creado_en INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sesiones (
  token TEXT PRIMARY KEY,
  usuario TEXT NOT NULL,           -- el nombre de la persona, no el área
  creada_en INTEGER NOT NULL,
  ultimo_uso INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS avisos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tipo TEXT NOT NULL,              -- nuevo | por_vencer | vencido | resumen
  item_id INTEGER,
  area TEXT NOT NULL,
  texto TEXT NOT NULL,
  ts INTEGER NOT NULL,
  enviado INTEGER NOT NULL DEFAULT 0,  -- 1 enviado · 0 pendiente · -1 enviando · 2 omitido
  detalle TEXT
);

-- Un renglón por cada mensaje de WhatsApp que sale, para saber si llegó.
-- Que WhatsApp acepte el mensaje no quiere decir que la persona lo reciba: si
-- el teléfono está apagado o el número no tiene WhatsApp, no llega nunca y el
-- aviso figuraba como enviado igual.
--   mandado -> salió, sin confirmar   llego -> le llegó al teléfono
--   fallo   -> no se pudo entregar
CREATE TABLE IF NOT EXISTS entregas_wsp (
  id_mensaje TEXT PRIMARY KEY,
  aviso_id INTEGER NOT NULL,
  numero TEXT NOT NULL,
  nombre TEXT,
  estado TEXT NOT NULL DEFAULT 'mandado',
  detalle TEXT,
  ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entregas_aviso ON entregas_wsp (aviso_id);

-- Lo mismo para el correo. Va en su propia tabla y no junto al WhatsApp porque
-- son distintos: el WhatsApp sale un mensaje por teléfono, y el correo sale uno
-- solo con todas las direcciones del área adentro. Un renglón por aviso.
--   mandado -> salió, sin confirmar   llego -> lo aceptaron
--   fallo   -> rebotó o está bloqueado
CREATE TABLE IF NOT EXISTS entregas_mail (
  id_envio TEXT PRIMARY KEY,
  aviso_id INTEGER NOT NULL,
  destinos TEXT NOT NULL,
  estado TEXT NOT NULL DEFAULT 'mandado',
  detalle TEXT,
  ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entregas_mail_aviso ON entregas_mail (aviso_id);
`);

// ── Valores iniciales (se cambian después desde Configuración) ─────────────
const SEMILLA = {
  area: ["Técnica", "Monitoreo", "Administración", "Comercial", "RRHH"],
  canal: ["WhatsApp", "Correo", "Teléfono"],
  tipo: ["Falla de alarma", "Falsa alarma", "Control de acceso", "Cámaras",
         "Facturación", "Alta / Baja", "Otro"],
  tipo_solicitud: ["Pedido", "Reclamo", "Consulta", "Solicitud técnica", "Otro"],
  tipo_cliente: ["RC", "Alarmas", "Totem"],
  motivo_cierre: ["Resuelto", "No era falla", "Error del usuario",
                  "El cliente desistió", "Pasó a presupuesto"],
  causa_raiz: ["Batería", "Comunicador", "Corte de línea", "Falla del equipo",
               "Mal uso", "Otro"],
};
// Las listas que existen. Un tipo inventado («__proto__») se guardaba y rompía
// la carga de las listas, y con eso el panel entero para todos.
// Por dónde se le avisó al cliente que su pedido quedó resuelto.
const AVISO_CLIENTE = ["Teléfono", "WhatsApp", "Correo"];
const TIPOS_LISTA = new Set([...Object.keys(SEMILLA), "estado"]);
// Estados: reloj=1 corre el tiempo, reloj=0 está frenado.
const SEMILLA_ESTADOS = [
  ["Nuevo", 1], ["En curso", 1], ["En espera del cliente", 0],
  ["En espera de repuesto", 0], ["Resuelto (a confirmar)", 0], ["Cerrado", 0],
];

const CONFIG_INICIAL = {
  horas_u1: "2", horas_u3: "24", horas_u4: "48",
  hora_fin_dia: "18",          // urgencia 2: vence a esta hora
  pct_preaviso: "75",
  // ── Avisos ──
  modo_envio: "simular",       // simular = solo muestra el mensaje, no lo manda
  avisar_nuevo: "1",           // al área, cuando entra un reclamo
  avisar_por_vencer: "1",      // preaviso cuando queda el 25% del plazo
  avisar_vencido: "1",         // al área y a ATCL
  area_atcl: "AT Cliente",     // área que recibe copia de los vencidos
  hora_resumen: "8",
  ultimo_resumen: "",
  pin_cierre: "6887",          // hace falta para cerrar un pedido
  // Estado en el que queda un pedido cuando el área lo da por terminado: sale
  // del tablero y pasa a la bandeja del auditor, que es quien cierra de verdad.
  estado_cierre: "Resuelto (a confirmar)",
  // Dirección con la que se arma el link de los avisos. Tiene que ser la de
  // afuera: el aviso se lee casi siempre desde el celular, fuera de la oficina.
  url_panel: "https://crm-production-c825.up.railway.app",
  pedir_ingreso: "0",          // el panel abre sin pedir nada hasta encenderlo
  silencio_desde: "22",
  silencio_hasta: "8",
};

// Columnas que se fueron agregando después de la primera versión.
function migrar() {
  const cols = db.prepare("PRAGMA table_info(items)").all().map(c => c.name);
  const nuevas = [
    ["pausa_ms", "INTEGER NOT NULL DEFAULT 0"],     // tiempo acumulado con el reloj frenado
    ["pausado_desde", "INTEGER"],                   // desde cuándo está frenado
    ["av_nuevo", "INTEGER NOT NULL DEFAULT 0"],
    ["av_por_vencer", "INTEGER NOT NULL DEFAULT 0"],
    ["av_vencido", "INTEGER NOT NULL DEFAULT 0"],
    ["primera_mano", "INTEGER"],   // cuándo el área lo tocó por primera vez
    ["nota", "TEXT"],              // la última nota de quien movió el pedido
    ["area_recibe", "TEXT"],       // quién atendió al cliente
    ["tipo_solicitud", "TEXT"],    // pedido, reclamo, consulta…
    ["tipo_cliente", "TEXT"],      // RC, alarmas, tótem
    // Desde cuándo corre el plazo que está vigente. Nace igual a creado_en y se
    // mueve cuando el pedido se deriva: el preaviso se calcula sobre el tramo
    // que tiene el área AHORA, no sobre el tiempo que el pedido lleva de vida.
    // Sin esto, un pedido viejo derivado con 24 horas por delante aparecía "por
    // vencer" a la hora de recibirlo, y no salía de ahí.
    ["plazo_desde", "INTEGER"],
    // Los datos del cliente según la planilla de Atención, tal como estaban al
    // cargar el pedido (ver planilla.js).
    ["cli_domicilio", "TEXT"], ["cli_localidad", "TEXT"], ["cli_vendedor", "TEXT"],
    ["cli_administrador", "TEXT"], ["cli_servicios", "TEXT"],
    ["persona", "TEXT"],           // a quién del área destino va, si se eligió
    ["aviso_cliente", "TEXT"],     // por dónde se le avisó al cliente al cerrar
    // Lo que propuso el área al pasarlo a CERRADO. Va aparte de motivo_cierre y
    // causa_raiz, que quedan para el cierre del auditor: si no, la estadística
    // contaba como cerrados pedidos que todavía nadie auditó.
    ["area_motivo", "TEXT"], ["area_causa", "TEXT"],
  ];
  const recienCreadas = [];
  for (const [nombre, tipo] of nuevas)
    if (!cols.includes(nombre)) { db.exec(`ALTER TABLE items ADD COLUMN ${nombre} ${tipo}`); recienCreadas.push(nombre); }

  // Los pedidos que ya existían no tienen que disparar una avalancha de avisos
  // "nuevo" la primera vez que arranca el módulo.
  if (recienCreadas.includes("av_nuevo"))
    db.exec("UPDATE items SET av_nuevo=1 WHERE estado <> 'Cerrado'");

  // Quién hizo el movimiento. Los que ya estaban quedan sin firma: se cargaron
  // cuando el panel era abierto y no hay manera de saberlo.
  // A quién va el aviso cuando el pedido tiene una persona elegida.
  const colsAv = db.prepare("PRAGMA table_info(avisos)").all().map(c => c.name);
  if (!colsAv.includes("persona")) db.exec("ALTER TABLE avisos ADD COLUMN persona TEXT");
  // A quiénes ya les salió, para que un reintento vaya solo a los que fallaron.
  if (!colsAv.includes("entregados")) db.exec("ALTER TABLE avisos ADD COLUMN entregados TEXT");

  const colsMov = db.prepare("PRAGMA table_info(movimientos)").all().map(c => c.name);
  if (!colsMov.includes("usuario")) db.exec("ALTER TABLE movimientos ADD COLUMN usuario TEXT");

  const colsUsr = db.prepare("PRAGMA table_info(usuarios)").all().map(c => c.name);
  if (!colsUsr.includes("rol")) db.exec("ALTER TABLE usuarios ADD COLUMN rol TEXT NOT NULL DEFAULT 'area'");

  // ── De un usuario por área a un usuario por persona ──
  // Los que vienen de la versión anterior quedan viendo TODO, como venían: el
  // día que se actualiza no puede cambiar lo que cada uno ve, o alguien busca un
  // pedido, no lo encuentra y cree que se perdió. El filtro por sector se
  // enciende después, persona por persona, cuando se decida.
  // Antes el área ERA el usuario: la clave la compartía todo el sector y no se
  // sabía quién había hecho cada cosa. Las filas viejas se conservan tal cual,
  // con el nombre del área como nombre de la persona, así nadie se queda afuera
  // el día que se actualiza: sigue entrando con la misma clave de siempre, y
  // desde ahí se dan de alta las personas de verdad.
  const colsPersona = db.prepare("PRAGMA table_info(usuarios)").all().map(c => c.name);
  if (!colsPersona.includes("nombre")) {
    db.exec(`
      ALTER TABLE usuarios RENAME TO usuarios_por_area;
      CREATE TABLE usuarios (
        nombre TEXT PRIMARY KEY, area TEXT NOT NULL DEFAULT '',
        telefono TEXT, correo TEXT, clave TEXT NOT NULL,
        rol TEXT NOT NULL DEFAULT 'area',
        solo_su_area INTEGER NOT NULL DEFAULT 1,
        activo INTEGER NOT NULL DEFAULT 1, creado_en INTEGER NOT NULL
      );
      INSERT INTO usuarios (nombre, area, clave, rol, solo_su_area, activo, creado_en)
        SELECT area,
               CASE WHEN rol='admin' THEN '' ELSE area END,
               clave, rol,
               0,
               activo, creado_en
        FROM usuarios_por_area;
      DROP TABLE usuarios_por_area;
    `);
    // Las sesiones abiertas guardaban el área. Se cierran todas: es un cambio de
    // identidad, y volver a entrar una vez es más barato que arrastrar sesiones
    // que apuntan a algo que ya no significa lo mismo.
    db.exec("DELETE FROM sesiones");
  }
  // El resumen diario se elige por persona. Todos lo siguen recibiendo hasta que
  // alguien lo destilde: el día que se actualiza nadie deja de recibir nada.
  const colsResumen = db.prepare("PRAGMA table_info(usuarios)").all().map(c => c.name);
  if (!colsResumen.includes("recibe_resumen"))
    db.exec("ALTER TABLE usuarios ADD COLUMN recibe_resumen INTEGER NOT NULL DEFAULT 1");
  // Los pedidos que ya existían nacieron con el plazo corriendo desde el alta.
  db.prepare("UPDATE items SET plazo_desde = creado_en WHERE plazo_desde IS NULL").run();

  const colsSes = db.prepare("PRAGMA table_info(sesiones)").all().map(c => c.name);
  if (!colsSes.includes("usuario")) {
    db.exec(`
      DROP TABLE sesiones;
      CREATE TABLE sesiones (
        token TEXT PRIMARY KEY, usuario TEXT NOT NULL,
        creada_en INTEGER NOT NULL, ultimo_uso INTEGER NOT NULL
      );
    `);
  }
}
migrar();

// El WhatsApp que cada área tenía cargado pasa a la lista nueva, para que nadie
// deje de recibir avisos por el cambio.
function pasarTelefonos() {
  if (!db.prepare("SELECT COUNT(*) c FROM telefonos").get().c) {
    const ins = db.prepare("INSERT INTO telefonos (area, numero, nombre, creado_en) VALUES (?,?,?,?)");
    for (const c of db.prepare("SELECT * FROM contactos WHERE whatsapp IS NOT NULL AND whatsapp<>''").all())
      ins.run(c.area, c.whatsapp, null, Date.now());
  }
  if (!db.prepare("SELECT COUNT(*) c FROM correos").get().c) {
    const ins = db.prepare("INSERT INTO correos (area, direccion, nombre, creado_en) VALUES (?,?,?,?)");
    for (const c of db.prepare("SELECT * FROM contactos WHERE correo IS NOT NULL AND correo<>''").all())
      ins.run(c.area, c.correo, null, Date.now());
  }
}

function sembrar() {
  const ins = db.prepare("INSERT INTO listas (tipo, valor, reloj, orden) VALUES (?,?,?,?)");
  // Por dónde se le avisó al cliente pasó a ser un campo propio del cierre. Los
  // tres motivos «Cerrado por…» que se habían sumado a la lista se sacan, una
  // sola vez. Los pedidos ya cerrados con alguno de ellos lo conservan. Va antes
  // de sembrar: si la lista tenía solo esos, queda vacía y se repone en este
  // mismo arranque, no en el siguiente; sin motivos no se puede cerrar nada.
  if (!cfg("cierre_por_canal_quitado")) {
    db.prepare("DELETE FROM listas WHERE tipo='motivo_cierre' AND valor IN "
      + "('Cerrado por teléfono','Cerrado por WhatsApp','Cerrado por correo')").run();
    db.prepare("INSERT OR REPLACE INTO config (clave, valor) VALUES ('cierre_por_canal_quitado','1')").run();
  }

  const hay = db.prepare("SELECT COUNT(*) c FROM listas").get().c;
  if (!hay) {
    for (const [tipo, valores] of Object.entries(SEMILLA))
      valores.forEach((v, i) => ins.run(tipo, v, 1, i));
    SEMILLA_ESTADOS.forEach(([v, reloj], i) => ins.run("estado", v, reloj, i));
  } else {
    // Listas que se agregaron después: se siembran solas, sin tocar las que ya
    // están armadas a mano. Una lista que el usuario vació queda vacía.
    for (const [tipo, valores] of Object.entries(SEMILLA)) {
      const tiene = db.prepare("SELECT COUNT(*) c FROM listas WHERE tipo=?").get(tipo).c;
      if (!tiene) valores.forEach((v, i) => ins.run(tipo, v, 1, i));
    }
  }
  const insC = db.prepare("INSERT OR IGNORE INTO config (clave, valor) VALUES (?,?)");
  for (const [k, v] of Object.entries(CONFIG_INICIAL)) insC.run(k, v);

  // El preaviso nació apagado, con un "a definir" al lado, y así quedó: el
  // primer aviso que recibía un área después del alta era el de vencido, o sea
  // cuando ya no había nada que prevenir. Se enciende, también donde ya estaba
  // guardado en cero. Una sola vez: si mañana alguien lo apaga a propósito, la
  // marca impide que el arranque se lo vuelva a encender.
  if (!cfg("preaviso_ya_encendido")) {
    db.prepare("UPDATE config SET valor='1' WHERE clave='avisar_por_vencer'").run();

    // Los que YA están dentro de la ventana se marcan como avisados. Si no,
    // encenderlo dispara de una vez un aviso por cada uno, y una andanada de
    // mensajes el día que se prende parece una falla del sistema: la próxima vez
    // ya nadie los lee. Es el mismo criterio con el que se recalcularon los
    // plazos de urgencia 2 sin volver a avisar. El preaviso empieza a servir con
    // los pedidos que crucen la línea a partir de ahora, que es para lo que es.
    const pct = Number(CONFIG_INICIAL.pct_preaviso) / 100;
    const ahora = Date.now();
    const yaDentro = db.prepare(`
      SELECT id FROM items
      WHERE estado <> 'Cerrado' AND vence_en IS NOT NULL AND av_por_vencer = 0
        AND (vence_en - ?) < (vence_en - creado_en) * ?
    `).all(ahora, 1 - pct);
    for (const it of yaDentro)
      db.prepare("UPDATE items SET av_por_vencer=1 WHERE id=?").run(it.id);
    if (yaDentro.length)
      console.log(`  preaviso encendido · ${yaDentro.length} pedidos ya estaban en la ventana y no se avisan`);

    insC.run("preaviso_ya_encendido", String(Date.now()));
  }
}
// Se define acá arriba, antes de sembrar(), porque la siembra ya lo necesita.
// Tener dos ayudantes que hacen lo mismo es lo que después se desincroniza.
const cfg = (clave) => db.prepare("SELECT valor FROM config WHERE clave=?").get(clave)?.valor;
sembrar();
pasarTelefonos();

// ── Usuarios: uno por área ─────────────────────────────────────────────────
// Sirven para saber QUIÉN hizo cada cosa. Por ahora no limitan lo que se puede
// hacer: cualquiera que entre puede trabajar cualquier pedido, pero su nombre
// queda pegado a cada movimiento.
const crypto = require("node:crypto");

const cifrar = (clave, sal = crypto.randomBytes(16).toString("hex")) =>
  sal + ":" + crypto.scryptSync(clave, sal, 32).toString("hex");

function claveCorrecta(clave, guardada) {
  const [sal, hash] = (guardada || "").split(":");
  if (!sal || !hash) return false;
  const calculado = crypto.scryptSync(clave, sal, 32);
  const esperado = Buffer.from(hash, "hex");
  return calculado.length === esperado.length && crypto.timingSafeEqual(calculado, esperado);
}

// El panel pide ingreso solo cuando el interruptor está encendido y hay al menos
// un usuario cargado. Así se pueden cargar las claves de todas las áreas con
// calma, probarlas, y recién después activarlo, sin dejar a nadie afuera en
// medio de la jornada.
const pideIngreso = () =>
  cfg("pedir_ingreso") === "1" &&
  db.prepare("SELECT COUNT(*) c FROM usuarios WHERE activo=1").get().c > 0;

const DIAS_SESION = 30;

// Devuelve { nombre, area, rol, solo_su_area } o null si no hay sesión válida.
function quienEs(req) {
  const cookie = (req.headers.cookie || "").split(";")
    .map(x => x.trim().split("=")).find(([k]) => k === "crm_sesion");
  if (!cookie) return null;
  const s = db.prepare("SELECT * FROM sesiones WHERE token=?").get(cookie[1]);
  if (!s) return null;
  if (Date.now() - s.ultimo_uso > DIAS_SESION * 24 * 3600 * 1000) {
    db.prepare("DELETE FROM sesiones WHERE token=?").run(cookie[1]);
    return null;
  }
  const u = db.prepare("SELECT * FROM usuarios WHERE nombre=? AND activo=1").get(s.usuario);
  if (!u) { db.prepare("DELETE FROM sesiones WHERE token=?").run(cookie[1]); return null; }
  db.prepare("UPDATE sesiones SET ultimo_uso=? WHERE token=?").run(Date.now(), cookie[1]);
  return { nombre: u.nombre, area: u.area, rol: u.rol, solo_su_area: u.solo_su_area };
}

// Quién está haciendo el pedido que se está atendiendo en este momento. Se
// carga al entrar cada consulta y todo lo que escribe en movimientos lo lee de
// acá, así no hay que ir pasando el usuario por cada función.
let usuarioEnCurso = null, esAdmin = false, esAtcl = false;
// Quién está mirando, con su sector y si está limitado a él. Se usa para no
// mostrarle pedidos de otras áreas.
let miraEnCurso = null;

// Los pedidos que le tocan a este usuario. Ojo con los dos campos, que se leen
// al revés de lo que parece:
//   area         = a quién se derivó, o sea quién lo tiene que resolver
//   area_recibe  = quién atendió al cliente y lo cargó
// Un área quiere ver las dos cosas: lo que le derivaron, que es su trabajo, y lo
// que ella misma originó, que es lo que está esperando de otro. Filtrar por una
// sola deja al área sin saber qué reclamó.
function esMio(it) {
  if (!miraEnCurso?.solo_su_area) return true;
  const mia = miraEnCurso.area;
  if (!mia) return true;                 // administrador sin sector: ve todo
  if (esVendedor(miraEnCurso)) return esDelVendedor(it, miraEnCurso.nombre);
  return it.area === mia || it.area_recibe === mia;
}

// Comercial no trabaja como área sino de a una persona: cada vendedor tiene sus
// clientes. Desde el 23/10/2026 un vendedor ve sólo los casos de Comercial que
// tiene asignados y los que él mismo cargó para otra área, y no puede derivar
// un caso que tiene otro vendedor. El administrador, y quien tenga apagado
// «solo su área» (un jefe de ventas), siguen viendo todo Comercial.
const AREA_VENDEDORES = "Comercial";
const esVendedor = (u) => !!u && u.rol !== "admin" && u.area === AREA_VENDEDORES && !!u.solo_su_area;
const cargadoPor = (itemId) =>
  db.prepare("SELECT usuario FROM movimientos WHERE item_id=? ORDER BY id LIMIT 1").get(itemId)?.usuario || null;
function esDelVendedor(it, yo) {
  if (it.area === AREA_VENDEDORES) return it.persona === yo;
  return it.area_recibe === AREA_VENDEDORES && cargadoPor(it.id) === yo;
}
// El caso es de Comercial y lo tiene otro vendedor: quien mira no lo puede derivar.
function deOtroVendedor(it) {
  return esVendedor(miraEnCurso) && it.area === AREA_VENDEDORES && !!it.persona && it.persona !== miraEnCurso.nombre;
}

// Lo mismo para una lista.
const soloMios = (items) => items.filter(esMio);

// Mientras el panel esté abierto no hay a quién exigirle nada: administra el
// que esté sentado. Con el ingreso encendido, solo el administrador.
function soloAdmin() {
  if (pideIngreso() && !esAdmin) throw new Error("Esto lo hace el administrador");
}

// Atención al Cliente también administra la configuración (pedido de Gastón,
// 27/10/2026): personas, listas, destinatarios, plazos y la planilla. Quedan
// sólo para el administrador las copias de la base, vincular el WhatsApp, los
// envíos de prueba, borrar el registro de avisos, el ingreso al panel, el modo
// de envío y todo lo que toque a un administrador.
const AREA_CONFIGURA = "AT Cliente";

// Valores de lista que el código usa por su nombre: no se pueden quitar ni
// renombrar. «En curso» es el estado al devolver desde la bandeja de auditoría;
// las áreas son las de permisos y los pasos de Altas.
const VALORES_FIJOS = {
  estado: ["Nuevo", "En curso", "Cerrado"],
  area: [AREA_VENDEDORES, AREA_CONFIGURA, "Técnica", "Monitoreo", "Administración"],
};
const esFijo = (v) => (VALORES_FIJOS[v.tipo] || []).includes(v.valor);
const esDeAtcl = (u) => !!u && u.rol !== "admin" && u.area === AREA_CONFIGURA;
// Las acciones de Atención que no puede hacer: se revisan dentro de cada ruta.
function soloAdminSi(condicion, que) {
  if (condicion && pideIngreso() && !esAdmin) throw new Error(`${que} lo hace el administrador`);
}

// Lo que se puede cambiar por «POST /api/config» (GAS-400). Las secretas no
// tienen pantalla: las carga el administrador. Las horas van de 0 a 23.
const CLAVES_CONFIG = new Set([
  "horas_u1", "horas_u3", "horas_u4", "hora_fin_dia", "pct_preaviso", "url_panel",
  "modo_envio", "pedir_ingreso", "avisar_nuevo", "avisar_por_vencer", "avisar_vencido",
  "area_atcl", "hora_resumen", "silencio_desde", "silencio_hasta",
]);
const CLAVES_SOLO_ADMIN = new Set(["pin_cierre", "resend_key", "correo_desde", "ultramsg_token", "ultramsg_instancia"]);
const CLAVES_HORA = new Set(["hora_resumen", "silencio_desde", "silencio_hasta"]);

const anotar = (itemId, texto, ts = Date.now()) =>
  db.prepare("INSERT INTO movimientos (item_id, texto, ts, usuario) VALUES (?,?,?,?)")
    .run(itemId, texto, ts, usuarioEnCurso);

// ── Copias de seguridad ────────────────────────────────────────────────────
// VACUUM INTO deja una copia consistente aunque el CRM esté en uso.
function respaldar(motivo = "automatica") {
  const destino = path.join(DIR_COPIAS, `crm-${sello()}-${motivo}.db`);
  if (fs.existsSync(destino)) return destino;
  db.exec(`VACUUM INTO '${destino.replace(/'/g, "''")}'`);
  // Se guardan las 15 más nuevas; las anteriores se van borrando.
  const copias = fs.readdirSync(DIR_COPIAS).filter(f => f.endsWith(".db")).sort().reverse();
  for (const vieja of copias.slice(15)) { try { fs.unlinkSync(path.join(DIR_COPIAS, vieja)); } catch {} }
  return destino;
}

function copiaDelDia() {
  const hoy = sello().slice(0, 8);
  const hay = fs.readdirSync(DIR_COPIAS).some(f => f.startsWith(`crm-${hoy}`));
  if (!hay) { try { respaldar("del-dia"); } catch (e) { console.error("copia:", e.message); } }
}

// ── Reglas de negocio ──────────────────────────────────────────────────────

// Número de ticket: abonado + fecha (AAMMDD). Si ese número ya existe para
// otro ticket del mismo día, se le agrega sufijo -B, -C, etc.
// Cuánto puede escribirse en una nota. Estaba en 300 y no alcanzaba para contar
// lo que pasó: una nota es lo que lee el área que recibe el pedido y lo que
// queda como explicación cuando alguien pregunta seis meses después. Dos mil
// caracteres son unas trescientas palabras. Lo que se manda por WhatsApp se
// recorta aparte: ahí un texto largo se vuelve ilegible.
const LARGO_NOTA = 2000;
const LARGO_NOTA_WSP = 220;

function numeroTicket(abonado, fecha) {
  const f = new Date(fecha);
  const base = `${abonado}-${String(f.getFullYear()).slice(2)}${String(f.getMonth() + 1).padStart(2, "0")}${String(f.getDate()).padStart(2, "0")}`;
  const previos = db.prepare("SELECT numero FROM tickets WHERE numero LIKE ?").all(base + "%");
  if (!previos.length) return base;
  const sufijos = "BCDEFGHIJKLMNOPQRSTUVWXYZ";
  return base + "-" + sufijos[previos.length - 1];
}

// Pedidos repetidos (criterio de Atención, 27/10/2026): si el abonado ya tiene
// un pedido abierto, se avisa antes de cargar otro, sea del tipo que sea. Antes
// se pedía el mismo tipo de solicitud o 3 palabras en común, y un pedido de otro
// tipo se cargaba sin avisar.
// La dirección no se compara: sale de la planilla por el código de abonado,
// así que mismo abonado ya es misma dirección.
function pedidosAbiertosDelAbonado(abonado) {
  const abiertos = db.prepare(`
    SELECT i.id, i.tipo_solicitud, i.tipo, i.area, i.area_recibe, i.persona, i.estado, i.descripcion, i.creado_en
    FROM items i JOIN tickets t ON t.id = i.ticket_id
    WHERE t.abonado = ? AND i.estado <> 'Cerrado'
    ORDER BY i.creado_en DESC`).all(abonado);
  return abiertos.map(p => {
    const aviso = { id: p.id, tipo_solicitud: p.tipo_solicitud, tipo: p.tipo, area: p.area, estado: p.estado, creado_en: p.creado_en };
    // Uno de otra área se muestra entero y con enlace: el historial también lo
    // deja abrir (GET /api/item). Lo que se protege es lo de otro vendedor: de
    // ese se entera de que existe, pero sin la descripción ni quién lo tiene.
    const mio = esMio(p);
    const deOtroVend = !mio && esVendedor(miraEnCurso) &&
      (p.area === AREA_VENDEDORES || p.area_recibe === AREA_VENDEDORES);
    if (deOtroVend) return { ...aviso, ajeno: true };
    return { ...aviso, persona: p.persona, descripcion: p.descripcion, otra_area: !mio };
  });
}

// Vencimiento según urgencia. La 5 usa la fecha comprometida que se elige.
function calcularVencimiento(urgencia, desde, fechaComprometida) {
  const h = 3600 * 1000;
  if (urgencia === 1) return desde + Number(cfg("horas_u1")) * h;
  if (urgencia === 3) return desde + Number(cfg("horas_u3")) * h;
  if (urgencia === 4) return desde + Number(cfg("horas_u4")) * h;
  if (urgencia === 2) {                      // fin del día
    const d = new Date(desde);
    d.setHours(Number(cfg("hora_fin_dia")), 0, 0, 0);
    return d.getTime() > desde ? d.getTime() : d.getTime() + 24 * h;
  }
  // La fecha puede venir sola ("2026-09-20", como la carga el alta) o con hora
  // ("2026-09-20T15:30", como la elige quien deriva). Sin esto, a la segunda se
  // le pegaba un "T18:00:00" encima y salía una fecha inválida: el pedido
  // quedaba sin plazo y el bot no lo avisaba nunca.
  if (!fechaComprometida) return null;
  const texto = String(fechaComprometida);
  const t = new Date(texto.includes("T") ? texto : texto + "T18:00:00").getTime();
  return isNaN(t) ? null : t;
}

// Arreglo puntual de la mudanza: mientras el servidor corrió en horario de
// Greenwich, el "fin del día" de la urgencia 2 caía tres horas antes de la hora
// configurada, y lo que se cargaba después de esa hora saltaba al día siguiente
// con 24 horas de plazo. Con CRM_RECALCULAR_U2 puesta, al arrancar se les rehace
// el plazo a los pedidos de urgencia 2 que sigan abiertos.
//
// No se tocan las marcas de aviso a propósito: esos pedidos ya recibieron su
// aviso, aunque fuera antes de tiempo, y volver a habilitarlos mandaría un
// segundo mensaje por lo mismo.
if (process.env.CRM_RECALCULAR_U2) {
  try {
    const abiertos = db.prepare(
      "SELECT id, creado_en, vence_en, pausa_ms FROM items WHERE urgencia=2 AND estado<>'Cerrado'").all();
    let tocados = 0;
    for (const it of abiertos) {
      const nuevo = calcularVencimiento(2, it.creado_en, null) + (it.pausa_ms || 0);
      if (!nuevo || nuevo === it.vence_en) continue;
      db.prepare("UPDATE items SET vence_en=? WHERE id=?").run(nuevo, it.id);
      const cuando = (ms) => new Date(ms).toLocaleString("es-AR", { hour12: false });
      anotar(it.id, `Plazo corregido — vencía ${cuando(it.vence_en)}, ahora ${cuando(nuevo)}`, Date.now());
      tocados++;
    }
    console.log(`  plazos de urgencia 2 recalculados: ${tocados} de ${abiertos.length}`);
  } catch (e) {
    console.error("  no pude recalcular los plazos:", e.message);
  }
}

const estadosConReloj = () =>
  db.prepare("SELECT valor FROM listas WHERE tipo='estado' AND reloj=1").all().map(r => r.valor);

// ── Avisos ─────────────────────────────────────────────────────────────────

function duracion(ms) {
  const h = Math.floor(Math.abs(ms) / 3600000), m = Math.floor(Math.abs(ms) / 60000) % 60;
  return h >= 24 ? `${Math.floor(h / 24)}d ${h % 24}h` : h ? `${h}h ${m}m` : `${m}m`;
}
const SEMAFORO = { vencido: "🔴", por_vencer: "🟡", en_plazo: "🟢", frenado: "⚪", sin_plazo: "⚪" };

// Estado de cada pedido abierto, con su semáforo y cuánto le falta.
function itemsAbiertos() {
  const corriendo = estadosConReloj();
  const ahora = Date.now();
  // Los que el área ya dio por terminados quedan afuera: esperan que el auditor
  // los cierre y el área no puede hacer nada más con ellos. Seguir avisándole
  // por algo que ya resolvió es lo que hace que se dejen de leer los avisos.
  // Es el mismo criterio con el que salen del tablero.
  return db.prepare(`
    SELECT i.*, t.numero, t.abonado, a.nombre AS abonado_nombre
    FROM items i JOIN tickets t ON t.id = i.ticket_id
    LEFT JOIN abonados a ON a.codigo = t.abonado
    WHERE i.estado <> 'Cerrado' AND i.estado <> ?
  `).all(cfg("estado_cierre") || "").map(i => {
    const corre = corriendo.includes(i.estado);
    const restante = i.vence_en ? i.vence_en - ahora : null;
    const umbral = i.vence_en
      ? (i.vence_en - (i.plazo_desde ?? i.creado_en)) * (1 - Number(cfg("pct_preaviso")) / 100) : 0;
    return {
      ...i, restante,
      semaforo: !corre ? "frenado" : restante === null ? "sin_plazo"
        : restante < 0 ? "vencido" : restante < umbral ? "por_vencer" : "en_plazo",
    };
  });
}

const enSilencio = () => {
  const h = new Date().getHours(), d = Number(cfg("silencio_desde")), a = Number(cfg("silencio_hasta"));
  return d > a ? (h >= d || h < a) : (h >= d && h < a);
};

// La marca de "ya avisé" va en el pedido, no en el historial de avisos: así
// borrar el historial no vuelve a disparar todo.
const COL_AVISO = { nuevo: "av_nuevo", por_vencer: "av_por_vencer", vencido: "av_vencido" };
const yaAvisado = (tipo, item) => item[COL_AVISO[tipo]] === 1;
const marcarAvisado = (tipo, itemId) =>
  db.prepare(`UPDATE items SET ${COL_AVISO[tipo]}=1 WHERE id=?`).run(itemId);

function crearAviso(tipo, area, texto, itemId = null, persona = null) {
  const r = db.prepare("INSERT INTO avisos (tipo, item_id, area, texto, ts, persona) VALUES (?,?,?,?,?,?)")
    .run(tipo, itemId, area, texto, Date.now(), persona);
  if (!mandaDeVerdad()) return;
  // Dentro de una operación sobre un pedido, el mensaje sale recién cuando la
  // operación quedó guardada entera: si después falla, no se avisó nada falso.
  if (enTransaccion) enviosPendientes.push([Number(r.lastInsertRowid), area, texto]);
  else enviar(Number(r.lastInsertRowid), area, texto);
}

// ── Operaciones enteras ────────────────────────────────────────────────────
// Una derivación o una corrección que se rechaza a mitad de camino dejaba
// guardado lo que ya había escrito: la pantalla decía «error» y el pedido
// igual había cambiado de área. Las rutas de ATOMICAS corren en una
// transacción: o queda todo, o no queda nada.
let enTransaccion = false, enviosPendientes = [];
function atomico(fn) {
  db.exec("BEGIN");
  enTransaccion = true;
  const envios = (enviosPendientes = []);
  try {
    const salida = fn();
    // Una ruta asíncrona seguiría escribiendo después del COMMIT, fuera de la transacción.
    if (salida && typeof salida.then === "function") throw new Error("Una operación entera no puede esperar");
    db.exec("COMMIT");
    enTransaccion = false;
    for (const e of envios) enviar(...e);
    return salida;
  } catch (e) {
    if (enTransaccion) db.exec("ROLLBACK");
    throw e;
  } finally {
    enTransaccion = false;
  }
}

// Un solo lugar decide si un aviso sale al mundo. Hacen falta las dos cosas: que
// el panel esté en modo real y que esto sea la nube, no una copia.
function mandaDeVerdad() { return ES_PRODUCCION && cfg("modo_envio") === "real"; }

// La dirección se guarda a mano y de ella cuelga el link de todos los avisos. Un
// campo mal escrito no rompe nada visible: los mensajes salen sin link o con uno
// que no abre, y así estuvimos días. Por eso se revisa antes de guardar.
function revisarDireccion(valor) {
  const texto = String(valor ?? "").trim().replace(/\/+$/, "");
  if (!texto) return "";                     // vacío es válido: avisos sin link
  let u;
  try { u = new URL(texto); }
  catch { throw new Error(`«${texto}» no es una dirección válida. Tiene que empezar con https:// y ser la dirección completa del panel`); }
  if (u.protocol !== "https:" && u.protocol !== "http:")
    throw new Error(`«${texto}» tiene que empezar con https://`);
  if (!u.hostname.includes("."))
    throw new Error(`«${texto}» no parece una dirección de internet: le falta el punto del dominio`);
  if (u.search || u.hash)
    throw new Error("Poné solo la dirección del panel, sin lo que viene después del signo de pregunta");
  return u.origin + (u.pathname === "/" ? "" : u.pathname.replace(/\/+$/, ""));
}

// El aviso llega al celular: el link abre el panel directamente en ese pedido,
// sin tener que buscarlo. Si no hay dirección cargada, el aviso sale igual.
function enlace(itemId) {
  const base = (cfg("url_panel") || "").replace(/\/+$/, "");
  return base ? `\n👉 ${base}/?p=${itemId}` : "";
}

// Dónde está y quién lo vendió, para el aviso: lo que la planilla sabía al cargarlo.
function lineaCliente(i) {
  const lugar = [i.cli_domicilio, i.cli_localidad].filter(Boolean).join(", ");
  const partes = [lugar && "📍 " + lugar, i.cli_vendedor && "Vendedor " + i.cli_vendedor,
                  i.cli_administrador && "Adm. " + i.cli_administrador].filter(Boolean);
  return partes.length ? "\n" + partes.join(" · ") : "";
}

// Línea corta para los listados: solo número y semáforo, como se definió.
const linea = (i) => `${SEMAFORO[i.semaforo]} ${i.numero} · ${i.restante === null ? "sin plazo"
  : i.restante < 0 ? "vencido hace " + duracion(i.restante) : "faltan " + duracion(i.restante)}`;

// El resumen de un área, agrupado por situación. Los que tienen el reloj frenado
// van aparte: si un pedido en espera de repuesto cae bajo "En plazo" pero su
// línea dice "vencido hace 5 días", el mensaje se contradice solo y deja de
// creerse. Lo arman igual el resumen que se manda y el que se mira en pantalla.
function resumenDeArea(items, area) {
  const del = items.filter(i => i.area === area);
  if (!del.length) return null;
  const g = (...cuales) => del.filter(i => cuales.includes(i.semaforo));
  const bloque = (rotulo, lista) =>
    lista.length ? `\n${rotulo} (${lista.length}):\n` + lista.map(linea).join("\n") : "";
  return [
    `📋 ${area} — ${del.length} pendiente${del.length > 1 ? "s" : ""}`,
    bloque("Vencidos", g("vencido")),
    bloque("Por vencer", g("por_vencer")),
    bloque("En plazo", g("en_plazo", "sin_plazo")),
    bloque("Con el reloj frenado", g("frenado")),
  ].filter(Boolean).join("\n");
}

function motorAvisos() {
  const items = itemsAbiertos();

  for (const i of items) {
    // En horario de silencio no sale nada, salvo urgencia 1. Vale para todos
    // los avisos, incluido el de pedido nuevo.
    if (enSilencio() && i.urgencia !== 1) continue;

    // Entra un reclamo nuevo → aviso al área. Lleva cliente, urgencia y área.
    if (cfg("avisar_nuevo") === "1" && !yaAvisado("nuevo", i)) {
      crearAviso("nuevo", i.area,
        `🆕 Nuevo pedido — ${i.area}\n${i.abonado_nombre || i.abonado} · Urgencia ${i.urgencia}${lineaCliente(i)}\n${i.numero}\n${i.descripcion}` + enlace(i.id),
        i.id, i.persona);
      marcarAvisado("nuevo", i.id);
    }

    if (cfg("avisar_por_vencer") === "1" && i.semaforo === "por_vencer" && !yaAvisado("por_vencer", i)) {
      crearAviso("por_vencer", i.area, `🟡 Por vencer — ${i.area}\n${linea(i)}` + enlace(i.id), i.id, i.persona);
      marcarAvisado("por_vencer", i.id);
    }

    // Vencido / el área no devolvió → al área y también a ATCL.
    if (cfg("avisar_vencido") === "1" && i.semaforo === "vencido" && !yaAvisado("vencido", i)) {
      crearAviso("vencido", i.area, `🔴 Vencido — ${i.area}\n${linea(i)}\n${i.abonado_nombre || i.abonado} · ${i.descripcion}` + enlace(i.id), i.id, i.persona);
      const atcl = cfg("area_atcl");
      if (atcl && atcl !== i.area)
        crearAviso("vencido", atcl, `🔴 Vencido en ${i.area}\n${linea(i)}\n${i.abonado_nombre || i.abonado} · ${i.descripcion}` + enlace(i.id), i.id);
      marcarAvisado("vencido", i.id);
    }
  }

  // Resumen diario, una vez por día. Solo dentro de una ventana de 3 horas
  // desde la hora configurada: si el CRM estuvo apagado toda la mañana, no
  // tiene sentido mandar el "resumen de las 8" a las 7 de la tarde.
  const hoy = new Date().toISOString().slice(0, 10);
  const h = new Date().getHours(), hr = Number(cfg("hora_resumen"));
  if (h >= hr && h < hr + 3 && cfg("ultimo_resumen") !== hoy) {
    for (const area of db.prepare("SELECT valor FROM listas WHERE tipo='area'").all().map(r => r.valor)) {
      const texto = resumenDeArea(items, area);
      if (!texto) continue;
      const base = (cfg("url_panel") || "").replace(/\/+$/, "");
      // Que se distinga de un aviso de pedido desde la primera línea, que en el
      // correo es también el asunto: «📋 RESUMEN DIARIO — Comercial — 1 pendiente».
      const titulado = texto.replace(/^📋 /, "📋 RESUMEN DIARIO — ");
      crearAviso("resumen", area, titulado + (base ? `\n\n👉 ${base}/` : ""));
    }
    db.prepare("UPDATE config SET valor=? WHERE clave='ultimo_resumen'").run(hoy);
  }
}

// Desde dónde viene un pedido, para el límite de ingreso. Solo en Railway se
// confía en el encabezado: ahí el borde público lo reemplaza con la dirección
// real del visitante. En una copia local o por acceso directo, el encabezado lo
// escribe cualquiera y cambiándolo se esquivaría el límite: vale la conexión.
const DETRAS_DE_RAILWAY = !!process.env.RAILWAY_SERVICE_ID;
function origenDe(req) {
  if (DETRAS_DE_RAILWAY) {
    const real = String(req.headers["x-real-ip"] || "").trim()
      || String(req.headers["x-forwarded-for"] || "").split(",").pop().trim();
    if (real) return real;
  }
  return req.socket.remoteAddress || "";
}

// ── Límite de intentos de ingreso ──
// Sin límite se podía probar claves sin fin. Se cuenta por persona y lugar desde
// donde se intenta: cinco errores frenan esa combinación un minuto, y cada error
// siguiente duplica la espera hasta un tope de 15 minutos. Así uno que se equivoca
// no deja afuera al resto de la oficina, que sale a internet por la misma dirección.
// Además, un tope amplio por lugar corta a quien prueba muchas personas distintas.
// Vive en memoria: reiniciar el servidor lo limpia, y eso también desbloquea.
const fallos = new Map();          // "origen|persona" o "origen|*" -> { n, hasta, ts }
const LIBRES = 5, TOPE_LUGAR = 50, MAX_ESPERA = 15 * 60000, VENTANA = 15 * 60000;
function frenarIngreso(origen, quien) {
  const ahora = Date.now();
  for (const clave of [origen + "|" + quien, origen + "|*"]) {
    const f = fallos.get(clave);
    if (f && f.hasta > ahora)
      throw new Error(`Demasiados intentos. Probá de nuevo en ${Math.ceil((f.hasta - ahora) / 60000)} min`);
  }
}
function fallaIngreso(origen, quien) {
  const ahora = Date.now();
  // Se limpian los que ya no frenan a nadie, para que el mapa no crezca sin fin.
  for (const [k, f] of fallos) if (ahora - f.ts > VENTANA && f.hasta < ahora) fallos.delete(k);
  const sumar = (clave, libres) => {
    const f = fallos.get(clave) || { n: 0, hasta: 0, ts: ahora };
    f.n++; f.ts = ahora;
    if (f.n >= libres) f.hasta = ahora + Math.min(60000 * 2 ** (f.n - libres), MAX_ESPERA);
    fallos.set(clave, f);
  };
  sumar(origen + "|" + quien, LIBRES);
  sumar(origen + "|*", TOPE_LUGAR);
}

// Cuando una persona cambia de sector o se da de baja, sus pedidos abiertos de
// otra área dejan de ser suyos: vuelven a toda el área, y queda dicho por qué.
function soltarPedidos(nombre, motivo, areaNueva = null) {
  const ahora = Date.now();
  const suyos = db.prepare(
    "SELECT id FROM items WHERE persona=? AND estado<>'Cerrado' AND area IS NOT ?").all(nombre, areaNueva);
  for (const { id } of suyos) {
    db.prepare("UPDATE items SET persona=NULL WHERE id=?").run(id);
    anotar(id, `${motivo}: el pedido vuelve a toda el área`, ahora);
  }
}

// Quién recibe los avisos de un área. Primero las personas del área: su teléfono
// y su correo son los que cargó el administrador al darlas de alta, así que no
// hay que mantener el dato en dos lugares. Después los destinatarios sueltos —un
// teléfono de guardia, el celular de alguien que nunca entra al panel—, que no
// son usuarios y por eso viven en su propia lista.
// `esResumen` deja afuera a los usuarios que destildaron el resumen diario. Los
// otros destinatarios del área (teléfonos y correos sueltos) no son usuarios y
// lo siguen recibiendo.
function telefonosDe(area, esResumen = false) {
  const de = db.prepare(
    "SELECT telefono AS numero, nombre FROM usuarios "
    + "WHERE area=? AND activo=1 AND telefono IS NOT NULL AND telefono<>'' AND (?=0 OR recibe_resumen=1) ORDER BY nombre")
    .all(area, esResumen ? 1 : 0);
  const otros = db.prepare("SELECT numero, nombre FROM telefonos WHERE area=? ORDER BY id").all(area);
  // Si el mismo número está en los dos lados, se manda una sola vez.
  const vistos = new Set(de.map(x => x.numero));
  return [...de, ...otros.filter(o => !vistos.has(o.numero))];
}

function correosDe(area, esResumen = false) {
  const de = db.prepare(
    "SELECT correo FROM usuarios WHERE area=? AND activo=1 AND correo IS NOT NULL AND correo<>'' "
    + "AND (?=0 OR recibe_resumen=1) ORDER BY nombre")
    .all(area, esResumen ? 1 : 0).map(x => x.correo);
  const otros = db.prepare("SELECT direccion FROM correos WHERE area=? ORDER BY id").all(area)
    .map(x => x.direccion);
  return [...new Set([...de, ...otros])];
}

// Envío real. Sin credenciales cargadas queda registrado como pendiente.
async function enviar(avisoId, area, texto, intento = 1) {
  // Se marca "en curso" (-1) antes de salir a mandar. El envío es asíncrono, así
  // que sin esta marca el reintento del mismo ciclo veía el aviso como pendiente
  // y lo mandaba una segunda vez: dos mensajes idénticos a la misma hora.
  db.prepare("UPDATE avisos SET enviado=-1 WHERE id=?").run(avisoId);
  const c = db.prepare("SELECT * FROM contactos WHERE area=?").get(area) || {};
  const notas = [];
  // Si el pedido va a una persona, el aviso le llega solo a ella. Si no tiene ni
  // teléfono ni correo cargado, va a toda el área: un aviso que no le llega a
  // nadie es peor que uno que le llega de más.
  const av = db.prepare("SELECT tipo, persona, entregados FROM avisos WHERE id=?").get(avisoId) || {};
  const esResumen = av.tipo === "resumen";
  let numeros = telefonosDe(area, esResumen), dirs = correosDe(area, esResumen);
  // Quién tiene que recibir cada correo: hace falta para saber si el WhatsApp ya
  // lo avisó cuando el correo no puede salir.
  let porCorreo = db.prepare(
    "SELECT correo, telefono FROM usuarios WHERE area=? AND activo=1 AND correo IS NOT NULL AND correo<>'' "
    + "AND (?=0 OR recibe_resumen=1)").all(area, esResumen ? 1 : 0)
    .concat(db.prepare("SELECT direccion AS correo, NULL AS telefono FROM correos WHERE area=?").all(area));
  // Un resumen que no le llega a nadie porque todo el sector lo destildó no es un
  // fallo: se marca omitido (2) y no entra en los reintentos. Si el área no tiene
  // a nadie cargado, en cambio, sigue siendo un problema y queda pendiente.
  if (esResumen && !numeros.length && !dirs.length && (telefonosDe(area).length || correosDe(area).length)) {
    db.prepare("UPDATE avisos SET enviado=2, detalle=? WHERE id=?")
      .run("Omitido: nadie del sector tiene tildado el resumen diario", avisoId);
    return;
  }
  const persona = av.persona;
  if (persona) {
    // Tiene que seguir siendo del área del aviso: si la pasaron a otro sector o
    // la dieron de baja, el aviso no puede irse con ella.
    const u = db.prepare("SELECT telefono, correo FROM usuarios WHERE nombre=? AND area=? AND activo=1").get(persona, area);
    if (!u) notas.push(`${persona} ya no está en ${area}: va a toda el área`);
    else if (u.telefono || u.correo) {
      numeros = u.telefono ? [{ numero: u.telefono, nombre: persona }] : [];
      dirs = u.correo ? [u.correo] : [];
      porCorreo = u.correo ? [{ correo: u.correo, telefono: u.telefono }] : [];
      notas.push(`Solo a ${persona}`);
    } else notas.push(`${persona} no tiene teléfono ni correo: va a toda el área`);
  }
  // Lo que ya salió en un intento anterior no se vuelve a mandar. El resultado se
  // cuenta por destinatario, no leyendo el texto del detalle: «enviado a 0 de 1»
  // dice «enviado» y daba por mandado un aviso que no le llegó a nadie.
  let hechos;
  try { hechos = new Set(JSON.parse(av.entregados || "[]")); } catch { hechos = new Set(); }
  // Se guarda apenas sale cada uno, no al final: si el servidor se reinicia a
  // mitad de un envío, el reintento no le vuelve a mandar al que ya lo tenía.
  const guardarAvance = () =>
    db.prepare("UPDATE avisos SET entregados=? WHERE id=?").run(JSON.stringify([...hechos]), avisoId);
  let pendientes = 0;
  try {
    // A todos los teléfonos del área. Si alguno falla, se sigue con los demás y se
    // anota cuál fue: un número mal cargado no puede dejar sin aviso al resto.
    if (numeros.length) {
      const fallaron = [];
      for (const t of numeros) {
        if (hechos.has("wsp:" + t.numero)) continue;
        try {
          const idMensaje = await wsp.enviarMensaje(t.numero, texto);
          hechos.add("wsp:" + t.numero);
          guardarAvance();
          // Se anota para poder decir después si llegó. Sin número de mensaje
          // no hay a quién preguntarle, así que ese caso queda sin seguimiento.
          if (idMensaje) {
            db.prepare(`INSERT OR REPLACE INTO entregas_wsp
              (id_mensaje, aviso_id, numero, nombre, estado, ts)
              VALUES (?,?,?,?, 'mandado', ?)`)
              .run(idMensaje, avisoId, t.numero, t.nombre || null, Date.now());
          }
        }
        catch (e) { pendientes++; fallaron.push((t.nombre || t.numero) + ": " + e.message); }
      }
      const bien = numeros.filter(t => hechos.has("wsp:" + t.numero)).length;
      notas.push(`WhatsApp: enviado a ${bien} de ${numeros.length}` +
                 (fallaron.length ? " · falló " + fallaron.join(" · ") : ""));
    }

    // El correo sale una sola vez, con todas las direcciones del área.
    const key = cfg("resend_key"), desde = cfg("correo_desde");
    // Por dirección, igual que el WhatsApp: el reintento manda solo a las que faltan.
    const faltan = dirs.filter(d => !hechos.has("correo:" + d));
    if (dirs.length && key && desde && !faltan.length) notas.push("Correo: ya enviado");
    else if (dirs.length && key && desde) {
      // Si el pedido a Resend se cae, cuenta como pendiente y se reintenta.
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: desde, to: faltan, subject: texto.split("\n")[0],
                               text: texto }),
      });
      notas.push(`Correo: ${r.ok ? "enviado a " + faltan.length : "error " + r.status}`);
      if (r.ok) { faltan.forEach(d => hechos.add("correo:" + d)); guardarAvance(); } else pendientes++;
      // El número de envío de Resend. Que acepte el pedido no quiere decir que
      // el correo llegue: puede rebotar o estar bloqueado, y sin este número no
      // hay a quién preguntarle después.
      if (r.ok) {
        try {
          const j = await r.json();
          if (j && j.id) {
            db.prepare(`INSERT OR REPLACE INTO entregas_mail
              (id_envio, aviso_id, destinos, estado, ts) VALUES (?,?,?, 'mandado', ?)`)
              .run(String(j.id), avisoId, faltan.join(", "), Date.now());
          }
        } catch {}
      }
    } else if (faltan.length) {
      // Sin correo configurado, quien recibió el WhatsApp ya está avisado. Pero el
      // que solo tiene correo no recibió nada: el aviso queda pendiente por él.
      // Se mira persona por persona: si Ana y Ema comparten la dirección y solo Ana
      // tiene teléfono, el WhatsApp de Ana no le avisa a Ema.
      const sinNada = faltan.filter(d => porCorreo.some(x =>
        x.correo === d && !(x.telefono && hechos.has("wsp:" + x.telefono))));
      if (sinNada.length) pendientes++;
      notas.push("Correo: falta la clave de envío" + (sinNada.length ? ` · sin recibir: ${sinNada.join(", ")}` : ""));
    }

    if (!c.whatsapp && !c.correo) notas.push("El área no tiene destinatario cargado");
  } catch (e) {
    pendientes++;
    notas.push("Error: " + e.message);
  }
  // Enviado solo si salió a alguien y no quedó nadie pendiente. Si a uno le llegó
  // y a otro no, queda pendiente y el reintento va solo al que falta.
  const ok = hechos.size > 0 && pendientes === 0;
  db.prepare("UPDATE avisos SET enviado=?, detalle=?, entregados=? WHERE id=?")
    .run(ok ? 1 : 0, notas.join(" · ") + (ok ? "" : ` · intento ${intento}`),
         JSON.stringify([...hechos]), avisoId);
}

// Si un aviso no se pudo mandar (WhatsApp desconectado, corte de internet),
// se reintenta en los ciclos siguientes hasta 5 veces, y después se deja
// registrado como no enviado.
function reintentarPendientes() {
  if (!mandaDeVerdad()) return;
  // Solo los que fallaron de verdad (enviado=0, nunca -1 que es "en curso") y
  // que además tienen más de dos minutos: si acaba de crearse, todavía puede
  // estar saliendo.
  const pendientes = db.prepare(`
    SELECT * FROM avisos
    WHERE enviado=0 AND (detalle IS NULL OR detalle NOT LIKE '%agotados%')
      AND ts > ? AND ts < ? ORDER BY ts LIMIT 20
  `).all(Date.now() - 12 * 3600 * 1000, Date.now() - 2 * 60 * 1000);
  for (const a of pendientes) {
    const intentos = (a.detalle?.match(/intento (\d+)/) || [])[1];
    const n = intentos ? Number(intentos) + 1 : 1;
    if (n > 5) {
      db.prepare("UPDATE avisos SET detalle=? WHERE id=?")
        .run(`${a.detalle || ""} · reintentos agotados`, a.id);
      continue;
    }
    enviar(a.id, a.area, a.texto, n);
  }
}

// El correo no avisa solo como el WhatsApp: hay que preguntarle a Resend.
//   delivered / opened / clicked          -> llegó
//   bounced / suppressed / complained     -> no llegó
//   sent / queued / delivery_delayed      -> todavía en camino
const LLEGO_MAIL = ["delivered", "opened", "clicked"];
const FALLO_MAIL = ["bounced", "suppressed", "complained", "failed", "canceled"];

async function revisarCorreos() {
  const pendientes = db.prepare(
    "SELECT id_envio FROM entregas_mail WHERE estado='mandado' LIMIT 200").all();
  if (!pendientes.length) return;
  const key = cfg("resend_key");
  if (!key) return;

  const faltan = new Set(pendientes.map(p => p.id_envio));
  let despues = null;
  const upd = db.prepare("UPDATE entregas_mail SET estado=?, detalle=? WHERE id_envio=?");
  for (let i = 0; i < 8 && faltan.size; i++) {
    let cuerpo;
    try {
      const r = await fetch(
        `https://api.resend.com/emails?limit=100${despues ? `&after=${despues}` : ""}`,
        { headers: { Authorization: `Bearer ${key}` } });
      cuerpo = await r.json();
    } catch { return; }        // sin respuesta se deja todo como estaba
    const datos = (cuerpo && cuerpo.data) || [];
    if (!datos.length) return;
    for (const m of datos) {
      const id = String(m.id || "");
      if (!faltan.has(id)) continue;
      faltan.delete(id);
      const ev = String(m.last_event || "");
      const cual = LLEGO_MAIL.includes(ev) ? "llego" : FALLO_MAIL.includes(ev) ? "fallo" : null;
      if (cual) upd.run(cual, ev, id);
    }
    if (!cuerpo.has_more) return;
    despues = datos[datos.length - 1].id;
  }
}

setInterval(() => {
  try { motorAvisos(); } catch (e) { console.error("motor:", e.message); }
  try { reintentarPendientes(); } catch (e) { console.error("reintentos:", e.message); }
  revisarCorreos().catch(e => console.error("correos:", e.message));
}, 60000);
setTimeout(() => { try { motorAvisos(); } catch {} }, 3000);

// ── API ────────────────────────────────────────────────────────────────────
const rutas = {
  "GET /api/tablero": () => {
    const items = db.prepare(`
      SELECT i.*, t.numero, t.abonado, a.nombre AS abonado_nombre
      FROM items i
      JOIN tickets t ON t.id = i.ticket_id
      LEFT JOIN abonados a ON a.codigo = t.abonado
      WHERE i.estado <> 'Cerrado'
      ORDER BY i.vence_en IS NULL, i.vence_en ASC
    `).all().filter(esMio);   // antes de contar: si no, el contador miente
    const ahora = Date.now();
    const corriendo = estadosConReloj();
    for (const it of items) {
      it.corriendo = corriendo.includes(it.estado);
      it.restante = it.vence_en ? it.vence_en - ahora : null;
      it.semaforo = !it.corriendo ? "frenado"
        : it.restante === null ? "sin_plazo"
        : it.restante < 0 ? "vencido"
        : it.restante < (it.vence_en - (it.plazo_desde ?? it.creado_en)) * (1 - Number(cfg("pct_preaviso")) / 100) ? "por_vencer"
        : "en_plazo";
    }
    // Los que el área ya dio por terminados salen del tablero y esperan en la
    // bandeja del auditor, que es el único que puede cerrarlos.
    const esperaCierre = cfg("estado_cierre");
    const enTablero = items.filter(i => i.estado !== esperaCierre);
    // Desde cuándo espera revisión: el momento en que el área lo dio por
    // terminado. Sale del movimiento, no del reloj de pausa, porque un pedido
    // pudo estar frenado antes por otra espera y esa fecha diría otra cosa.
    const paraCerrar = items.filter(i => i.estado === esperaCierre).map(i => ({
      ...i,
      // Primero el movimiento del botón "CERRADO"; si el área lo dejó listo
      // cambiando el estado a mano, el movimiento de ese cambio. El reloj de
      // pausa queda último: si el pedido ya venía frenado esperando al cliente,
      // esa fecha es vieja y diría que espera revisión desde antes de tiempo.
      espera_desde:
        db.prepare("SELECT MAX(ts) t FROM movimientos WHERE item_id=? AND texto LIKE '%esperando cierre%'").get(i.id)?.t ||
        db.prepare("SELECT MAX(ts) t FROM movimientos WHERE item_id=? AND texto LIKE ?").get(i.id, `%→ ${esperaCierre}%`)?.t ||
        i.pausado_desde || null,
    }));

    return {
      items: enTablero,
      para_cerrar: paraCerrar,
      contadores: {
        vencidos: enTablero.filter(i => i.semaforo === "vencido").length,
        por_vencer: enTablero.filter(i => i.semaforo === "por_vencer").length,
        nuevos: enTablero.filter(i => i.estado === "Nuevo").length,
        abiertos: enTablero.length,
      },
    };
  },

  // El área marca el pedido como terminado: pasa a la bandeja del auditor.
  "POST /api/items/para-cerrar": (body) => {
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(body.id);
    if (!it) throw new Error("No existe el pedido");
    if (it.estado === cfg("estado_cierre"))
      throw new Error("Ese pedido ya está esperando el cierre");
    // Se acepta desde cualquier estado, incluido "Nuevo": el propio pase cambia
    // el estado, así que el pedido nunca queda como sin tomar. Exigir que antes
    // pasara por "En curso" solo obligaba a dar una vuelta de más.
    // La nota es la que se escribe al elegir CERRADO en «Pasar al área»: queda
    // en el pedido y en su historia, igual que al cambiar de estado.
    // El área dice cómo terminó (motivo y causa); el auditor después lo revisa.
    // Con «Otro» la nota es obligatoria: si no, nadie sabe qué fue.
    const motivo = String(body.motivo_cierre || "").trim(), causa = String(body.causa_raiz || "").trim();
    if (!motivo || !causa) throw new Error("Elegí el motivo de cierre y la causa raíz");
    const enLista = (tipo, v) => db.prepare("SELECT 1 FROM listas WHERE tipo=? AND valor=?").get(tipo, v);
    if (!enLista("motivo_cierre", motivo)) throw new Error("Ese motivo de cierre no existe");
    if (!enLista("causa_raiz", causa)) throw new Error("Esa causa raíz no existe");
    // «Otro», «Otros», «Otro (especificar)»…
    const esOtro = (v) => v.toLowerCase().startsWith("otro");
    if ((esOtro(motivo) || esOtro(causa)) && !String(body.nota || "").trim())
      throw new Error("Elegiste «Otro»: escribí en la nota qué pasó");
    rutas["POST /api/items/estado"]({ id: body.id, estado: cfg("estado_cierre"), nota: body.nota });
    db.prepare("UPDATE items SET area_motivo=?, area_causa=? WHERE id=?").run(motivo, causa, body.id);
    anotar(body.id, `${it.area} lo dio por terminado — ${motivo} / ${causa} — esperando cierre`, Date.now());
    return { ok: true };
  },

  "POST /api/items": (body) => {
    const { abonado, abonado_nombre, canal, tipo, descripcion, urgencia, area, bykom, fecha_comprometida,
            area_recibe, tipo_solicitud, tipo_cliente } = body;
    // La persona es opcional, pero si viene tiene que ser alguien activo del área destino.
    const persona = String(body.persona || "").trim() || null;
    if (persona && !db.prepare("SELECT 1 FROM usuarios WHERE nombre=? AND area=? AND activo=1").get(persona, area))
      throw new Error(`${persona} no es de ${area}`);
    if (!abonado || !descripcion || !urgencia || !area) throw new Error("Faltan datos obligatorios");
    if (!canal || !tipo) throw new Error("Falta el canal de ingreso o el tipo de pedido");
    // La urgencia 5 la define ATCL, pero con fecha: sin fecha el pedido queda
    // sin plazo y el bot nunca lo avisa.
    if (Number(urgencia) === 5 && !fecha_comprometida)
      throw new Error("La urgencia 5 necesita una fecha comprometida");
    // Antes de cargar, se avisa si el abonado ya tiene un pedido abierto.
    // Quien carga elige ir a ese o cargar igual (body.cargar_igual).
    // «Cargar igual» vale para los pedidos que se mostraron: si cambió algo y
    // aparece otro, se vuelve a avisar.
    const parecidos = pedidosAbiertosDelAbonado(abonado);
    const vistos = new Set(String(body.cargar_igual || "").split(",").map(Number));
    if (parecidos.some(p => !vistos.has(p.id))) return { duplicados: parecidos };
    const ahora = Date.now();

    if (abonado_nombre)
      db.prepare("INSERT INTO abonados (codigo, nombre) VALUES (?,?) ON CONFLICT(codigo) DO UPDATE SET nombre=excluded.nombre")
        .run(abonado, abonado_nombre);

    // Un solo ticket por cliente: si ya tiene uno abierto, el pedido se suma ahí.
    let ticket = db.prepare("SELECT * FROM tickets WHERE abonado=? AND abierto=1").get(abonado);
    if (!ticket) {
      const numero = numeroTicket(abonado, ahora);
      const r = db.prepare("INSERT INTO tickets (numero, abonado, abierto, creado_en) VALUES (?,?,1,?)").run(numero, abonado, ahora);
      ticket = { id: r.lastInsertRowid, numero };
    }

    const vence = calcularVencimiento(Number(urgencia), ahora, fecha_comprometida);
    // Lo que la planilla de clientes sabe de este abonado queda en el pedido.
    const cli = planilla.buscar(abonado) || {};
    const r = db.prepare(`INSERT INTO items
      (ticket_id, canal, tipo, descripcion, urgencia, area, bykom, estado, creado_en, vence_en,
       plazo_desde, area_recibe, tipo_solicitud, tipo_cliente,
       cli_domicilio, cli_localidad, cli_vendedor, cli_administrador, cli_servicios, persona)
      VALUES (?,?,?,?,?,?,?,'Nuevo',?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(ticket.id, canal, tipo, descripcion, Number(urgencia), area, bykom || null, ahora, vence,
           ahora, area_recibe || null, tipo_solicitud || null, tipo_cliente || null,
           cli.domicilio || null, cli.localidad || null, cli.vendedor || null,
           cli.administrador || null, cli.servicios || null, persona);
    // Queda registrado quién atendió al cliente: es el dato que después dice por
    // dónde entra el trabajo y quién lo derivó.
    anotar(r.lastInsertRowid,
      `Ingresa por ${canal}${area_recibe ? " en " + area_recibe : ""} — derivado a ${area}${persona ? " (" + persona + ")" : ""}, urgencia ${urgencia}`, ahora);
    if (parecidos.length)
      anotar(r.lastInsertRowid,
        `Cargado igual, aunque el abonado ya tenía un pedido abierto (${parecidos.map(p => "#" + p.id).join(", ")})`, ahora);
    return { ok: true, ticket: ticket.numero };
  },

  "POST /api/items/estado": (body) => {
    const { id, estado, nota } = body;
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(id);
    if (!it) throw new Error("No existe el pedido");
    // Cerrar tiene su propio camino, con clave, motivo y causa: por acá se
    // podía cerrar sin nada de eso y el pedido desaparecía sin rastro del porqué.
    if (!estado) throw new Error("Elegí un estado");
    if (estado === "Cerrado") throw new Error("Para cerrar un pedido hay que usar «Auditar», con la clave");
    if (it.estado === "Cerrado") throw new Error("El pedido ya está cerrado");
    // El de «esperando cierre» vale aunque lo hayan sacado de la lista: si no,
    // ningún área podría dar un pedido por terminado.
    if (estado !== cfg("estado_cierre") && !db.prepare("SELECT 1 FROM listas WHERE tipo='estado' AND valor=?").get(estado))
      throw new Error("Ese estado no existe");
    // "Nuevo" es el estado con el que entra: una vez que alguien lo trabajó no
    // se puede volver atrás, o se pierde el rastro de que ya fue tomado.
    if (estado === "Nuevo" && it.estado !== "Nuevo")
      throw new Error("El pedido ya fue tomado: no puede volver a Nuevo");
    const ahora = Date.now();
    const corriendo = estadosConReloj();
    const corriaAntes = corriendo.includes(it.estado);
    const correAhora = corriendo.includes(estado);

    // El tiempo con el reloj frenado (esperando al cliente o un repuesto) no
    // cuenta contra el área: al volver a correr, el vencimiento se corre otro
    // tanto y ese rato queda registrado aparte.
    if (corriaAntes && !correAhora) {
      db.prepare("UPDATE items SET pausado_desde=? WHERE id=?").run(ahora, id);
    } else if (!corriaAntes && correAhora && it.pausado_desde) {
      const frenado = ahora - it.pausado_desde;
      db.prepare("UPDATE items SET pausa_ms = pausa_ms + ?, pausado_desde = NULL, vence_en = vence_en + ? WHERE id=?")
        .run(frenado, frenado, id);
      anotar(id, `Estuvo ${Math.round(frenado / 60000)} min frenado — el vencimiento se corrió otro tanto`, ahora);
    }

    db.prepare("UPDATE items SET estado=? WHERE id=?").run(estado, id);
    // Primera vez que alguien lo mueve de "Nuevo": es la respuesta inicial.
    if (!it.primera_mano && it.estado === "Nuevo")
      db.prepare("UPDATE items SET primera_mano=? WHERE id=?").run(ahora, id);
    // Si vuelve a moverse, puede volver a avisar cuando venza de nuevo.
    if (correAhora) db.prepare("UPDATE items SET av_vencido=0, av_por_vencer=0 WHERE id=? AND estado<>'Cerrado'").run(id);
    // La nota explica POR QUÉ cambió el estado: es la mitad que faltaba del
    // historial, que hasta ahora decía qué pasó pero no por qué.
    const limpia = (nota || "").trim().slice(0, LARGO_NOTA);
    if (limpia !== "") db.prepare("UPDATE items SET nota=? WHERE id=?").run(limpia, id);
    anotar(id, `${it.estado} → ${estado}` + (limpia ? ` — ${limpia}` : ""), ahora);
    return { ok: true };
  },

  "POST /api/items/area": (body, url, self) => {
    const { id, area, estado, nota, plazo, plazo_fecha } = body;
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(id);
    if (!it) throw new Error("No existe el pedido");
    if (it.estado === "Cerrado") throw new Error("El pedido ya está cerrado");
    if (!area) throw new Error("Elegí un área");
    if (deOtroVendedor(it)) throw new Error(`Este caso lo tiene ${it.persona}: no lo podés derivar`);
    // Devolver al MISMO área es una acción legítima y hasta acá estaba prohibida:
    // el auditor mira un pedido que el área dio por terminado, ve que falta algo,
    // y necesita devolvérselo diciendo qué falta. No es una derivación vacía
    // porque el estado cambia — el pedido sale de "esperando cierre" y vuelve a
    // estar en curso. Lo único que sigue sin tener sentido es dejar todo igual.
    const mismaArea = area === it.area;
    const cambiaEstado = !!estado && estado !== it.estado;
    // Pasarlo a otra persona de la misma área: el área no cambia, cambia quién lo tiene.
    const reasigna = !!body.reasignar;
    if (reasigna && !mismaArea) throw new Error("Para pasarlo a otra área, derivalo");
    if (reasigna && body.persona === undefined) throw new Error("Elegí a quién se lo pasás");
    if (reasigna && (String(body.persona).trim() || null) === (it.persona || null))
      throw new Error(it.persona ? `Ya lo tiene ${it.persona}` : "Elegí a quién se lo pasás");
    if (mismaArea && !cambiaEstado && !reasigna)
      throw new Error("Es la misma área y el pedido queda en el mismo estado: no hay nada que devolver");
    // Si el pedido todavía está sin tomar, derivarlo obliga a decir en qué
    // estado queda: si no, se pasa de mano en mano y sigue figurando como nuevo.
    if (it.estado === "Nuevo" && !estado)
      throw new Error("Al derivar hay que indicar en qué estado queda el pedido");
    // El plazo se revisa antes de tocar nada: una fecha inválida se aceptaba,
    // el pedido se derivaba igual y quedaba con el plazo viejo sin decirlo.
    const elegido = String(plazo ?? "").trim();
    if (elegido && !["1", "2", "3", "4", "5"].includes(elegido))
      throw new Error("Ese plazo no existe");
    if (elegido === "5" && !plazo_fecha)
      throw new Error("Para una fecha a medida hace falta decir cuál");
    const ahora = Date.now();
    const aMedida = elegido === "5" ? calcularVencimiento(5, ahora, plazo_fecha) : null;
    if (elegido === "5" && !aMedida) throw new Error("Esa fecha no es válida");
    // Una fecha pasada dejaría el pedido vencido apenas llega al área nueva.
    if (aMedida && aMedida <= ahora) throw new Error("Esa fecha ya pasó");
    // A quién del área va. Sin elegir, la persona anterior se conserva solo si
    // el pedido vuelve a la misma área: en otra área no corresponde.
    const persona = body.persona !== undefined ? (String(body.persona).trim() || null)
      : mismaArea ? it.persona : null;
    if (persona && !db.prepare("SELECT 1 FROM usuarios WHERE nombre=? AND area=? AND activo=1").get(persona, area))
      throw new Error(`${persona} no es de ${area}`);

    db.prepare("UPDATE items SET area=? WHERE id=?").run(area, id);
    db.prepare("UPDATE items SET persona=? WHERE id=?").run(persona, id);
    // Si el auditor lo devuelve, lo que había propuesto el área ya no vale.
    db.prepare("UPDATE items SET area_motivo=NULL, area_causa=NULL WHERE id=?").run(id);
    // La nota dice por qué pasa de mano: es lo primero que necesita ver el área
    // que lo recibe. Reemplaza a la anterior y queda a la vista en el tablero.
    const limpia = (nota || "").trim().slice(0, LARGO_NOTA);
    if (limpia !== "") db.prepare("UPDATE items SET nota=? WHERE id=?").run(limpia, id);
    anotar(id, reasigna
      ? `Pasado a ${persona || "toda el área"} dentro de ${area}` + (it.persona ? ` (lo tenía ${it.persona})` : "")
        + (limpia ? ` — ${limpia}` : "")
      : mismaArea
      ? `Devuelto a ${area}${persona ? " (" + persona + ")" : ""} — no se dio por terminado` + (limpia ? `: ${limpia}` : "")
      : `Derivado de ${it.area} a ${area}${persona ? " (" + persona + ")" : ""}` + (limpia ? ` — ${limpia}` : ""), ahora);

    // El cambio de estado se hace con la misma lógica que el endpoint de estado
    // (reloj de las esperas, primera mano, avisos), reutilizándola. La nota ya
    // quedó anotada en la derivación: no se repite en el cambio de estado.
    //
    // Va ANTES de tocar el plazo: ese endpoint, si el pedido venía frenado y
    // vuelve a correr, le suma al vencimiento el rato que estuvo parado. Si el
    // plazo nuevo se escribiera primero, esa suma caería encima y regalaría una
    // espera que ocurrió antes de que este área lo tuviera.
    if (estado && estado !== it.estado) rutas["POST /api/items/estado"]({ id, estado });

    // El plazo arranca de nuevo para el área que lo recibe. Antes se heredaba el
    // que había empezado a correr cuando el pedido entró, y eso hacía que un
    // área pudiera recibir un pedido ya vencido y figurar como incumplidora por
    // una demora que fue de otra. Cada área responde por su tramo.
    //
    // Quien deriva puede elegir cuánto le da al área que recibe: es la persona
    // que sabe si eso es para hoy o puede esperar. Se elige el PLAZO, no la
    // urgencia: la urgencia es lo que se le prometió al cliente y cambiarla
    // haría que el pedido figure en las estadísticas como si hubiera entrado
    // con otra prioridad.
    //
    // Sin elegir nada se usa la urgencia que el pedido ya tiene, y la urgencia 5
    // no se toca: su fecha está comprometida con el cliente y no se corre porque
    // el pedido cambie de escritorio.
    // Dentro de la misma área el plazo sigue corriendo: el tramo es del área, no de
    // la persona. Solo cambia si quien lo pasa elige otro.
    if (elegido || (it.urgencia !== 5 && !reasigna)) {
      const escala = elegido ? Number(elegido) : it.urgencia;
      const nuevo = elegido === "5" ? aMedida : calcularVencimiento(escala, ahora, null);
      if (nuevo) {
        // Sin sumarle la pausa acumulada: el plazo se cuenta desde ahora, así
        // que las esperas de antes ya quedaron atrás.
        // plazo_desde se mueve con el vencimiento: el preaviso tiene que medirse
        // contra el tramo que arranca ahora, no contra la vida entera del pedido.
        db.prepare("UPDATE items SET vence_en=?, plazo_desde=?, av_por_vencer=0, av_vencido=0 WHERE id=?")
          .run(nuevo, ahora, id);

        // Si después de derivarlo sigue frenado, la espera se cuenta desde este
        // momento y no desde antes: lo que ya estuvo parado quedó del lado del
        // área anterior, y sumarlo al plazo nuevo lo estiraría dos veces.
        const ahoraIt = db.prepare("SELECT pausado_desde, pausa_ms FROM items WHERE id=?").get(id);
        if (ahoraIt.pausado_desde && ahoraIt.pausado_desde < ahora) {
          db.prepare("UPDATE items SET pausa_ms = pausa_ms + ?, pausado_desde = ? WHERE id=?")
            .run(ahora - ahoraIt.pausado_desde, ahora, id);
        }

        const cuando = (ms) => new Date(ms).toLocaleString("es-AR", { hour12: false });
        // Si el plazo se eligió a mano queda dicho, y si con eso se pisó una
        // fecha comprometida con el cliente, queda dicho más fuerte: es lo
        // primero que va a buscar quien mañana pregunte por qué cambió.
        const aMano = elegido && Number(elegido) !== it.urgencia
          ? ` (plazo elegido a mano, el pedido sigue en urgencia ${it.urgencia})` : "";
        const pisada = elegido && it.urgencia === 5 && it.vence_en
          ? ` — se reemplaza la fecha comprometida del ${cuando(it.vence_en)}` : "";
        anotar(id, `El plazo arranca de nuevo para ${area} — vence ${cuando(nuevo)}${aMano}${pisada}`, ahora);
      }
    }

    // Y se le avisa al área que lo recibe. Hasta acá no se enteraba de nada: el
    // aviso de "nuevo" sale una sola vez, al entrar el pedido, así que un pedido
    // derivado aterrizaba en su tablero en silencio. Con el plazo arrancando de
    // cero, no avisar sería peor todavía.
    // En silencio no sale, salvo urgencia 1: la misma regla que el motor. Lo que
    // no sale queda para el motor, que avisa como pedido nuevo al terminar el silencio.
    if (cfg("avisar_nuevo") === "1" && enSilencio() && it.urgencia !== 1)
      db.prepare("UPDATE items SET av_nuevo=0 WHERE id=?").run(id);
    else if (cfg("avisar_nuevo") === "1") {
      // El aviso de la derivación cuenta como el de pedido nuevo: si quedaba
      // pendiente, el motor mandaba otro al mismo destino en la vuelta siguiente.
      marcarAvisado("nuevo", id);
      const t = db.prepare(`SELECT t.numero, t.abonado, a.nombre AS abonado_nombre
                            FROM items i JOIN tickets t ON t.id=i.ticket_id
                            LEFT JOIN abonados a ON a.codigo=t.abonado WHERE i.id=?`).get(id);
      crearAviso("nuevo", area,
        `${reasigna ? "👤 Te pasaron un pedido" : mismaArea ? "↩️ Te devolvieron un pedido" : "↪️ Te derivaron un pedido"} — ${area}\n${t.abonado_nombre || t.abonado} · Urgencia ${it.urgencia}${lineaCliente(it)}\n`
        + `${t.numero}\n${it.descripcion}` + (limpia ? `\n\n"${limpia.slice(0, LARGO_NOTA_WSP)}${limpia.length > LARGO_NOTA_WSP ? "…" : ""}"` : "") + enlace(id),
        id, persona);
    }
    return { ok: true };
  },

  // Corregir un pedido mal cargado. No se toca el código del abonado: eso
  // define a qué ticket pertenece. Cada cambio queda anotado en el historial.
  "POST /api/items/editar": (body) => {
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(body.id);
    if (!it) throw new Error("No existe el pedido");
    if (it.estado === "Cerrado") throw new Error("El pedido ya está cerrado");

    const campos = {
      canal: "Entra por", tipo: "Motivo", descripcion: "Qué pide",
      urgencia: "Urgencia", area: "Área", bykom: "N° Bykom",
      area_recibe: "Área que recibe", tipo_solicitud: "Tipo de solicitud",
      tipo_cliente: "Tipo de cliente",
    };
    // Corregir el área es otra forma de derivarlo.
    if (body.area !== undefined && (body.area || null) !== it.area && deOtroVendedor(it))
      throw new Error(`Este caso lo tiene ${it.persona}: no le podés cambiar el área`);
    const cambios = [];
    for (const [campo, etiqueta] of Object.entries(campos)) {
      if (body[campo] === undefined) continue;
      const antes = it[campo] ?? "";
      const ahora = campo === "urgencia" ? Number(body[campo]) : (body[campo] || null);
      if (String(antes) === String(ahora ?? "")) continue;
      if (campo === "descripcion" && !ahora) throw new Error("La descripción no puede quedar vacía");
      db.prepare(`UPDATE items SET ${campo}=? WHERE id=?`).run(ahora, body.id);
      cambios.push(`${etiqueta}: ${antes || "—"} → ${ahora ?? "—"}`);
    }
    // La persona era del área anterior: si el área se corrigió, deja de corresponder
    // y el aviso vuelve a ir a toda el área nueva.
    if (it.persona && body.area !== undefined && (body.area || null) !== it.area) {
      db.prepare("UPDATE items SET persona=NULL WHERE id=?").run(body.id);
      cambios.push(`Persona: ${it.persona} → —`);
    }

    // Cambiar la urgencia cambia el plazo: se recalcula desde que entró,
    // sumándole el tiempo que estuvo frenado para no castigar esas esperas.
    if (body.urgencia !== undefined && Number(body.urgencia) !== it.urgencia) {
      const base = calcularVencimiento(Number(body.urgencia), it.creado_en, body.fecha_comprometida);
      if (Number(body.urgencia) === 5 && !base)
        throw new Error("La urgencia 5 necesita una fecha comprometida");
      db.prepare("UPDATE items SET vence_en=?, av_por_vencer=0, av_vencido=0 WHERE id=?")
        .run(base === null ? null : base + (it.pausa_ms || 0), body.id);
      cambios.push("vencimiento recalculado");
    }

    if (body.abonado_nombre)
      db.prepare("UPDATE abonados SET nombre=? WHERE codigo=(SELECT abonado FROM tickets WHERE id=?)")
        .run(body.abonado_nombre, it.ticket_id);

    if (!cambios.length) return { ok: true, sin_cambios: true };
    anotar(body.id, "Corregido — " + cambios.join(" · "), Date.now());
    return { ok: true, cambios };
  },

  // Se cargó un pedido que no correspondía: sale del tablero sin ensuciar la
  // estadística, y queda el rastro de que existió.
  // Una nota suelta, sin tocar nada del pedido. Hasta ahora lo único que dejaba
  // algo escrito era mover el pedido: si había que agregar un dato y el pedido
  // seguía igual, no había dónde ponerlo y terminaba en un WhatsApp aparte.
  "POST /api/items/nota": (body) => {
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(body.id);
    if (!it) throw new Error("No encuentro ese pedido");
    const limpia = (body.texto || "").trim().slice(0, LARGO_NOTA);
    if (!limpia) throw new Error("La nota está vacía");
    anotar(body.id, limpia, Date.now());
    // Queda además como la última nota: es la que se ve sin abrir el historial.
    db.prepare("UPDATE items SET nota=? WHERE id=?").run(limpia, body.id);
    return { ok: true };
  },

  "POST /api/items/anular": (body) => {
    const it = db.prepare("SELECT * FROM items WHERE id=?").get(body.id);
    if (!it) throw new Error("No existe el pedido");
    if (String(body.pin || "") !== cfg("pin_cierre")) throw new Error("Clave incorrecta");
    const ahora = Date.now();
    db.prepare(`UPDATE items SET estado='Cerrado', cerrado_en=?, motivo_cierre='Anulado',
                causa_raiz=? WHERE id=?`).run(ahora, body.motivo || "Cargado por error", body.id);
    anotar(body.id, `Anulado — ${body.motivo || "cargado por error"}`, ahora);
    const abiertos = db.prepare("SELECT COUNT(*) c FROM items WHERE ticket_id=? AND estado<>'Cerrado'").get(it.ticket_id).c;
    if (!abiertos) db.prepare("UPDATE tickets SET abierto=0 WHERE id=?").run(it.ticket_id);
    return { ok: true };
  },

  "POST /api/items/cerrar": (body) => {
    const { id, aviso_cliente, pin } = body;
    // Cerrar un pedido necesita la clave: es la única acción que borra el
    // pedido del tablero, así que no puede quedar al alcance de cualquiera.
    const esperado = cfg("pin_cierre");
    if (esperado && String(pin || "") !== esperado) throw new Error("Clave incorrecta");
    if (!AVISO_CLIENTE.includes(aviso_cliente)) throw new Error("Falta decir por dónde se le avisó al cliente");
    const previo = db.prepare("SELECT estado, area_motivo, area_causa FROM items WHERE id=?").get(id);
    if (!previo) throw new Error("No existe el pedido");
    // El motivo y la causa son los que eligió el área, leídos de la base (la
    // pantalla del auditor puede estar vieja). Solo si no hay elección del área
    // que siga en la lista se usan los que manda el auditor.
    const enLista = (tipo, v) => !!v && !!db.prepare("SELECT 1 FROM listas WHERE tipo=? AND valor=?").get(tipo, v);
    const delArea = enLista("motivo_cierre", previo.area_motivo) && enLista("causa_raiz", previo.area_causa);
    const motivo_cierre = delArea ? previo.area_motivo : String(body.motivo_cierre || "").trim();
    const causa_raiz = delArea ? previo.area_causa : String(body.causa_raiz || "").trim();
    if (!motivo_cierre || !causa_raiz) throw new Error("Falta el motivo de cierre o la causa raíz");
    if (!delArea && (!enLista("motivo_cierre", motivo_cierre) || !enLista("causa_raiz", causa_raiz)))
      throw new Error("Ese motivo de cierre o causa raíz no está en la lista");
    // Cerrarlo otra vez pisaba la fecha, el motivo y la causa del primer cierre.
    if (previo.estado === "Cerrado") throw new Error("El pedido ya está cerrado");
    const ahora = Date.now();
    db.prepare("UPDATE items SET estado='Cerrado', cerrado_en=?, motivo_cierre=?, causa_raiz=?, aviso_cliente=? WHERE id=?")
      .run(ahora, motivo_cierre, causa_raiz, aviso_cliente, id);
    anotar(id, `Cerrado — ${motivo_cierre} / ${causa_raiz} · se avisó al cliente por ${aviso_cliente}`, ahora);
    // El ticket se cierra cuando no le queda ningún pedido abierto.
    const it = db.prepare("SELECT ticket_id FROM items WHERE id=?").get(id);
    const abiertos = db.prepare("SELECT COUNT(*) c FROM items WHERE ticket_id=? AND estado<>'Cerrado'").get(it.ticket_id).c;
    if (!abiertos) db.prepare("UPDATE tickets SET abierto=0 WHERE id=?").run(it.ticket_id);
    return { ok: true, ticket_cerrado: !abiertos };
  },

  "GET /api/item": (_b, url) => {
    const id = url.searchParams.get("id");
    const item = db.prepare(`SELECT i.*, t.numero, t.abonado FROM items i JOIN tickets t ON t.id=i.ticket_id WHERE i.id=?`).get(id);
    const movs = db.prepare("SELECT * FROM movimientos WHERE item_id=? ORDER BY ts").all(id);
    // Un pedido de otra área se puede abrir si alguien pasa el número: lo que se
    // esconde es el ruido del tablero, no la información. Negarlo solo lograría
    // que se pregunte por WhatsApp y el registro se pierda. Se avisa que es ajeno.
    return { item, movimientos: movs, de_otra_area: item ? !esMio(item) : false,
             de_otro_vendedor: item ? deOtroVendedor(item) : false };
  },

  // Buscar un reclamo por lo que uno tiene a mano cuando llama el cliente: el
  // número del ticket, el código de abonado, el nombre, el número de Bykom.
  //
  // Busca en TODOS los pedidos, no en los del tablero: el que llama pregunta por
  // uno que muchas veces ya se cerró, y hasta acá había que ir a Seguimiento y
  // recorrer. Devuelve el id, que es con lo que la pantalla salta al pedido esté
  // donde esté.
  "GET /api/buscar": (_b, url, self) => {
    const q = (url.searchParams.get("q") || "").trim();
    if (q.length < 2) return { resultados: [] };

    // Se compara sin guiones ni espacios: el número se dicta por teléfono y cada
    // uno lo escribe distinto —"AY 1249", "ay-1249"—. Buscar literal no encuentra.
    const suelto = q.toLowerCase().replace(/[\s\-\/.]/g, "");
    const like = `%${q.toLowerCase()}%`;
    const sueltoLike = `%${suelto}%`;

    // El WHERE, escrito una vez y usado dos: para traer la página y para contar
    // cuántos hay en total. Antes se buscaba solo por número, abonado, nombre y
    // Bykom; ahora también por lo que dice el reclamo, que es lo que uno tiene
    // en la cabeza cuando el cliente cuenta de nuevo su problema.
    const DONDE = `
      WHERE REPLACE(REPLACE(REPLACE(LOWER(t.numero), '-', ''), ' ', ''), '/', '') LIKE ?
         OR REPLACE(REPLACE(LOWER(t.abonado), '-', ''), ' ', '') LIKE ?
         OR LOWER(a.nombre) LIKE ?
         OR LOWER(COALESCE(i.bykom, '')) LIKE ?
         OR LOWER(COALESCE(i.descripcion, '')) LIKE ?
         OR CAST(i.id AS TEXT) = ?`;
    const args = [sueltoLike, sueltoLike, like, like, like, q];

    // Cuántos hay de verdad. Sin esto, el que busca un reclamo viejo ve una
    // lista cortada y cree que no está: es exactamente lo que pasaba con el
    // tope de 25, que dejaba afuera todo lo anterior a los 25 más nuevos.
    const total = db.prepare(`
      SELECT COUNT(*) AS n FROM items i
      JOIN tickets t ON t.id = i.ticket_id
      LEFT JOIN abonados a ON a.codigo = t.abonado
      ${DONDE}`).get(...args).n;

    // Primero lo que coincide exacto —el número de ticket que te dictaron, el
    // código de abonado, el número de Bykom—, después el resto por fecha. Así
    // el de arriba es casi siempre el que se buscaba, aunque sea de hace un año.
    const filas = db.prepare(`
      SELECT i.*, t.numero, t.abonado, a.nombre AS abonado_nombre,
             CASE
               WHEN REPLACE(REPLACE(REPLACE(LOWER(t.numero), '-', ''), ' ', ''), '/', '') = ? THEN 0
               WHEN REPLACE(REPLACE(LOWER(t.abonado), '-', ''), ' ', '') = ? THEN 1
               WHEN LOWER(COALESCE(i.bykom, '')) = ? THEN 1
               WHEN CAST(i.id AS TEXT) = ? THEN 1
               ELSE 2
             END AS cerca
      FROM items i
      JOIN tickets t ON t.id = i.ticket_id
      LEFT JOIN abonados a ON a.codigo = t.abonado
      ${DONDE}
      ORDER BY cerca, i.creado_en DESC
      LIMIT ${TOPE_BUSQUEDA}
    `).all(suelto, suelto, q.toLowerCase(), q, ...args);

    // Se ven los de cualquier área: el buscador existe para llegar rápido a un
    // pedido del que alguien te pasó el número, y esconderlo obligaría a
    // preguntar por WhatsApp. Se marca cuál no es tuyo, como en la ficha.
    return {
      total,
      hay_mas: total > filas.length,
      resultados: filas.map(i => ({
        id: i.id, numero: i.numero,
        abonado: i.abonado_nombre || i.abonado,
        descripcion: (i.descripcion || "").slice(0, 70),
        area: i.area, estado: i.estado, creado_en: i.creado_en,
        ajeno: !esMio(i),
        lo_tiene_otro: deOtroVendedor(i) ? i.persona : null,
      })),
    };
  },

  // Lo que se manda al panel no incluye claves ni tokens: quedan solo en el
  // servidor. Del PIN de cierre solo se informa si está puesto o no.
  "GET /api/listas": () => {
    const filas = db.prepare("SELECT * FROM listas ORDER BY tipo, orden, id").all();
    // Sin prototipo y solo los tipos conocidos: si ya quedó guardado uno
    // inválido, se saltea en vez de trabar el panel.
    const out = Object.create(null);
    for (const f of filas) if (TIPOS_LISTA.has(f.tipo)) (out[f.tipo] ||= []).push(f);
    const SECRETAS = ["resend_key", "pin_cierre", "ultramsg_token", "ultramsg_instancia"];
    const todo = Object.fromEntries(db.prepare("SELECT clave, valor FROM config").all().map(r => [r.clave, r.valor]));
    out._config = Object.fromEntries(Object.entries(todo).filter(([k]) => !SECRETAS.includes(k)));
    out._config.pide_pin = todo.pin_cierre ? "1" : "0";
    // Quiénes hay en cada área, para elegir a quién va el pedido. Solo los nombres.
    // Se dejan afuera los usuarios viejos que se llaman igual que su área.
    out._personas = Object.create(null);
    for (const u of db.prepare("SELECT nombre, area FROM usuarios WHERE activo=1 AND area<>'' AND nombre<>area ORDER BY nombre").all())
      (out._personas[u.area] ||= []).push(u.nombre);
    return out;
  },

  "POST /api/listas": (body) => {
    const { tipo, valor, reloj } = body;
    if (!tipo || !valor) throw new Error("Falta el valor");
    if (!TIPOS_LISTA.has(tipo)) throw new Error("Esa lista no existe");
    db.prepare("INSERT INTO listas (tipo, valor, reloj, orden) VALUES (?,?,?,999)")
      .run(tipo, valor, reloj ? 1 : 0);
    return { ok: true };
  },

  "POST /api/listas/borrar": (body) => {
    const v = db.prepare("SELECT * FROM listas WHERE id=?").get(body.id);
    if (!v) return { ok: true };
    if (esFijo(v)) throw new Error(`"${v.valor}" lo usa el sistema y no se puede quitar`);
    // Tampoco conviene dejar sin valores una lista que es obligatoria al cargar.
    const quedan = db.prepare("SELECT COUNT(*) c FROM listas WHERE tipo=?").get(v.tipo).c;
    if (quedan <= 1) throw new Error("Tiene que quedar al menos un valor en la lista");
    // Si el valor está en uso, se avisa en vez de dejar pedidos huérfanos.
    const campo = { area: "area", estado: "estado", tipo: "tipo", canal: "canal" }[v.tipo];
    if (campo) {
      const usos = db.prepare(`SELECT COUNT(*) c FROM items WHERE ${campo}=? AND estado<>'Cerrado'`).get(v.valor).c;
      if (usos) throw new Error(`Hay ${usos} pedido(s) abierto(s) con "${v.valor}". Cambialos antes de quitarlo.`);
    }
    db.prepare("DELETE FROM listas WHERE id=?").run(body.id);
    return { ok: true };
  },

  // Cambiar el nombre de un valor. Los pedidos guardan el texto, no el id, así
  // que el nombre nuevo se pasa también a todo lo que lo usa: si no, los
  // pedidos viejos quedarían con un valor que ya no existe en la lista.
  "POST /api/listas/editar": (body) => {
    const v = db.prepare("SELECT * FROM listas WHERE id=?").get(body.id);
    if (!v) throw new Error("Ese valor ya no existe");
    const nuevo = String(body.valor ?? "").trim();
    if (!nuevo) throw new Error("Falta el nombre nuevo");
    if (nuevo === v.valor) return { ok: true };
    if (db.prepare("SELECT 1 FROM listas WHERE tipo=? AND valor=? AND id<>?").get(v.tipo, nuevo, v.id))
      throw new Error(`Ya hay un "${nuevo}" en esta lista`);
    // El estado de «Para auditar» puede no estar en la lista: igual está tomado.
    if (v.tipo === "estado" && nuevo === cfg("estado_cierre"))
      throw new Error(`"${nuevo}" es el estado de «Para auditar»`);
    if (esFijo(v))
      throw new Error(`"${v.valor}" lo usa el sistema y no se le puede cambiar el nombre`);

    const pasar = (tabla, col) =>
      db.prepare(`UPDATE ${tabla} SET ${col}=? WHERE ${col}=?`).run(nuevo, v.valor);
    const COLUMNA = { estado: "estado", tipo: "tipo", canal: "canal", tipo_solicitud: "tipo_solicitud",
                      tipo_cliente: "tipo_cliente", motivo_cierre: "motivo_cierre", causa_raiz: "causa_raiz" };
    if (v.tipo === "area") {
      for (const col of ["area", "area_recibe"]) pasar("items", col);
      for (const t of ["usuarios", "telefonos", "correos", "avisos"]) pasar(t, "area");
      // contactos.area es clave: si quedó un renglón huérfano con el nombre nuevo, se reemplaza.
      db.prepare("UPDATE OR REPLACE contactos SET area=? WHERE area=?").run(nuevo, v.valor);
      // Pasos de Altas que se derivaron a esta área.
      db.prepare("UPDATE alta_pasos SET responsable=? WHERE responsable=?").run(nuevo, v.valor);
      db.prepare("UPDATE config SET valor=? WHERE clave='area_atcl' AND valor=?").run(nuevo, v.valor);
    } else if (COLUMNA[v.tipo]) pasar("items", COLUMNA[v.tipo]);
    // La configuración que apunta a un valor de lista (el estado de «Para auditar»).
    if (v.tipo === "estado")
      db.prepare("UPDATE config SET valor=? WHERE clave='estado_cierre' AND valor=?").run(nuevo, v.valor);
    db.prepare("UPDATE listas SET valor=? WHERE id=?").run(nuevo, v.id);
    return { ok: true };
  },

  "POST /api/listas/reloj": (body) => {
    db.prepare("UPDATE listas SET reloj=? WHERE id=?").run(body.reloj ? 1 : 0, body.id);
    return { ok: true };
  },

  "POST /api/config": (body) => {
    // Solo se guardan las claves conocidas (GAS-400): antes entraba cualquiera,
    // y Atención podía cambiar la clave de cierre o la del correo. Se revisa
    // todo antes de guardar nada: o va el cambio entero o no va.
    for (const k of Object.keys(body)) {
      if (!CLAVES_CONFIG.has(k) && !CLAVES_SOLO_ADMIN.has(k)) throw new Error("Ese ajuste no se puede cambiar desde acá");
      soloAdminSi(CLAVES_SOLO_ADMIN.has(k), "Cambiar las claves y el correo de envío");
      if (CLAVES_HORA.has(k) && !/^(1?\d|2[0-3])$/.test(String(body[k])))
        throw new Error("La hora tiene que ser un número entero de 0 a 23");
    }
    soloAdminSi("pedir_ingreso" in body, "Encender o apagar el ingreso");
    soloAdminSi("modo_envio" in body, "Cambiar el modo de envío");
    if (body.pedir_ingreso === "1" &&
        !db.prepare("SELECT COUNT(*) c FROM usuarios WHERE rol='admin' AND activo=1").get().c)
      throw new Error("Cargá primero un administrador: si no, nadie va a poder administrar el panel");
    if ("url_panel" in body) body.url_panel = revisarDireccion(body.url_panel);
    const up = db.prepare("INSERT INTO config (clave, valor) VALUES (?,?) ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor");
    for (const [k, v] of Object.entries(body)) up.run(k, String(v));
    return { ok: true };
  },

  "GET /api/abonados": () => db.prepare("SELECT * FROM abonados ORDER BY nombre").all(),

  "GET /api/avisos": () => {
    const avisos = db.prepare("SELECT * FROM avisos ORDER BY ts DESC LIMIT 100").all();
    // Cómo le fue a cada mensaje de cada aviso. Se manda aparte y no pegado al
    // aviso porque un aviso puede salir a varios teléfonos de la misma área, y
    // que le llegue a uno no quiere decir que les haya llegado a todos.
    const entregas = avisos.length
      ? db.prepare(`SELECT aviso_id, numero, nombre, estado, detalle FROM entregas_wsp
                    WHERE aviso_id IN (${avisos.map(() => "?").join(",")})`)
          .all(...avisos.map(a => a.id))
      : [];
    return { avisos, entregas, contactos: db.prepare("SELECT * FROM contactos").all() };
  },

  // Todo lo de una persona en un solo lugar: quiénes son, y a quién le llega el
  // aviso de cada área. Antes había que mirar dos pantallas y adivinar cuál manda.
  "GET /api/personas": () => {
    const areas = db.prepare("SELECT valor FROM listas WHERE tipo='area' ORDER BY orden, id")
      .all().map(r => r.valor);
    return {
      personas: db.prepare(
        "SELECT nombre, area, telefono, correo, rol, solo_su_area, recibe_resumen FROM usuarios WHERE activo=1 "
        + "ORDER BY area, rol DESC, nombre").all(),
      // Los que reciben avisos sin ser usuarios del panel.
      otros_telefonos: db.prepare("SELECT * FROM telefonos ORDER BY area, id").all(),
      otros_correos: db.prepare("SELECT * FROM correos ORDER BY area, id").all(),
      // Lo que de verdad va a salir por cada área, ya juntado y sin repetidos.
      alcance: Object.fromEntries(areas.map(a => [a, {
        telefonos: telefonosDe(a).length,
        correos: correosDe(a).length,
      }])),
      areas,
    };
  },

  "GET /api/telefonos": () =>
    db.prepare("SELECT id, area, numero, nombre FROM telefonos ORDER BY area, id").all(),

  "POST /api/telefonos": (body) => {
    const area = String(body.area || "").trim();
    // Se guarda solo lo que es número: el WhatsApp no entiende paréntesis ni guiones.
    const numero = String(body.numero || "").replace(/\D/g, "");
    if (!area || !numero) throw new Error("Falta el área o el número");
    if (numero.length < 8) throw new Error("El número parece incompleto");
    const ya = db.prepare("SELECT id FROM telefonos WHERE area=? AND numero=?").get(area, numero);
    if (ya) throw new Error("Ese número ya está cargado en " + area);
    db.prepare("INSERT INTO telefonos (area, numero, nombre, creado_en) VALUES (?,?,?,?)")
      .run(area, numero, String(body.nombre || "").trim() || null, Date.now());
    return { ok: true };
  },

  "GET /api/correos": () =>
    db.prepare("SELECT id, area, direccion, nombre FROM correos ORDER BY area, id").all(),

  "POST /api/correos": (body) => {
    const area = String(body.area || "").trim();
    const direccion = String(body.direccion || "").trim().toLowerCase();
    if (!area || !direccion) throw new Error("Falta el área o la dirección");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(direccion)) throw new Error("Esa dirección no parece un correo");
    const ya = db.prepare("SELECT id FROM correos WHERE area=? AND direccion=?").get(area, direccion);
    if (ya) throw new Error("Ese correo ya está cargado en " + area);
    db.prepare("INSERT INTO correos (area, direccion, nombre, creado_en) VALUES (?,?,?,?)")
      .run(area, direccion, String(body.nombre || "").trim() || null, Date.now());
    return { ok: true };
  },

  "POST /api/correos/borrar": (body) => {
    db.prepare("DELETE FROM correos WHERE id=?").run(Number(body.id));
    return { ok: true };
  },

  "POST /api/telefonos/borrar": (body) => {
    db.prepare("DELETE FROM telefonos WHERE id=?").run(Number(body.id));
    return { ok: true };
  },

  "POST /api/contactos": (body) => {
    db.prepare(`INSERT INTO contactos (area, whatsapp, correo) VALUES (?,?,?)
                ON CONFLICT(area) DO UPDATE SET whatsapp=excluded.whatsapp, correo=excluded.correo`)
      .run(body.area, body.whatsapp || null, body.correo || null);
    return { ok: true };
  },

  // Corre el motor en el momento, para ver qué avisaría sin esperar al minuto.
  "POST /api/avisos/revisar": () => { motorAvisos(); return { ok: true }; },

  // Arma el resumen de cada área tal como saldría, sin registrarlo ni mandarlo.
  "GET /api/avisos/resumen": () => {
    const items = itemsAbiertos();
    return db.prepare("SELECT valor FROM listas WHERE tipo='area'").all().map(r => r.valor)
      .map(area => {
        const texto = resumenDeArea(items, area);
        if (!texto) return null;
        return { area, texto };
      }).filter(Boolean);
  },

  "POST /api/avisos/borrar": () => { db.exec("DELETE FROM avisos"); return { ok: true }; },

  // Auditoría: toda la vida de cada pedido en una sola línea de tiempo, con
  // los movimientos y los avisos mezclados en orden, desde que entra hasta que
  // se cierra.
  "GET /api/auditoria": (_b, url) => {
    const filtro = url.searchParams.get("filtro") || "todos";   // abiertos | cerrados | todos
    const cond = filtro === "abiertos" ? "AND i.estado <> 'Cerrado'"
               : filtro === "cerrados" ? "AND i.estado = 'Cerrado'" : "";
    // ?id= trae un solo pedido, el del link del aviso: sin el tope de los últimos
    // y aunque sea de otra área, igual que /api/item. Si no, un pedido viejo o
    // ajeno aparecía como «no encontrado» aunque existe.
    const id = Number(url.searchParams.get("id")) || 0;
    const items = db.prepare(`
      SELECT i.*, t.numero, t.abonado, a.nombre AS abonado_nombre
      FROM items i JOIN tickets t ON t.id=i.ticket_id
      LEFT JOIN abonados a ON a.codigo=t.abonado
      WHERE ${id ? "i.id = ?" : "1=1 " + cond}
      ORDER BY i.creado_en DESC LIMIT ${TOPE_SEGUIMIENTO}
    `).all(...(id ? [id] : [])).filter(i => id || esMio(i));

    const movs = db.prepare("SELECT * FROM movimientos ORDER BY ts").all();
    const avs = db.prepare("SELECT * FROM avisos WHERE item_id IS NOT NULL ORDER BY ts").all();
    // Cómo le fue a cada mensaje. Un aviso sale a varios teléfonos del área, y
    // que le llegue a uno no quiere decir que les haya llegado a todos: por eso
    // se cuenta cuántos llegaron, cuántos siguen en camino y cuántos fallaron.
    const entregas = {};
    for (const e of db.prepare("SELECT * FROM entregas_wsp").all()) {
      const x = entregas[e.aviso_id] || (entregas[e.aviso_id] = { llego: 0, mandado: 0, fallo: 0, quienes: [] });
      if (x[e.estado] !== undefined) x[e.estado]++;
      x.quienes.push({ nombre: e.nombre || e.numero, estado: e.estado });
    }
    // El correo va aparte: es uno solo por aviso, con todas las direcciones
    // adentro, así que no se cuenta igual que los WhatsApp.
    const correos = {};
    for (const e of db.prepare("SELECT * FROM entregas_mail").all()) {
      correos[e.aviso_id] = { estado: e.estado, detalle: e.detalle, destinos: e.destinos };
    }

    return items.map(i => {
      const linea = [
        ...movs.filter(m => m.item_id === i.id)
               .map(m => ({ ts: m.ts, tipo: "movimiento", texto: m.texto, usuario: m.usuario })),
        ...avs.filter(a => a.item_id === i.id)
              .map(a => ({ ts: a.ts, tipo: "aviso", clase: a.tipo, area: a.area,
                           enviado: a.enviado, detalle: a.detalle, texto: a.texto,
                           entrega: entregas[a.id] || null,
                           correo: correos[a.id] || null })),
      ].sort((x, y) => x.ts - y.ts);
      return {
        id: i.id, numero: i.numero, abonado: i.abonado_nombre || i.abonado,
        area: i.area, urgencia: i.urgencia, estado: i.estado, tipo: i.tipo,
        descripcion: i.descripcion, bykom: i.bykom,
        tipo_solicitud: i.tipo_solicitud, tipo_cliente: i.tipo_cliente, area_recibe: i.area_recibe,
        creado_en: i.creado_en, cerrado_en: i.cerrado_en,
        motivo_cierre: i.motivo_cierre, causa_raiz: i.causa_raiz, aviso_cliente: i.aviso_cliente,
        pausa_ms: i.pausa_ms, vence_en: i.vence_en,
        de_otra_area: !esMio(i),
        lo_tiene_otro: deOtroVendedor(i) ? i.persona : null,
        avisos: linea.filter(x => x.tipo === "aviso").length,
        linea,
      };
    });
  },

  // ── Ingreso ──
  "GET /api/quien": (_b, _u, req) => {
    const q = quienEs(req);
    return {
      version: VERSION,
      pide_ingreso: pideIngreso(),
      area: q?.area || null,
      rol: q?.rol || null,
      // Mientras el panel esté abierto cualquiera administra; una vez encendido
      // el ingreso, solo el administrador.
      manda: !pideIngreso() || q?.rol === "admin" || esDeAtcl(q),
      es_admin: !pideIngreso() || q?.rol === "admin",
      es_produccion: ES_PRODUCCION,
      usuario: q?.nombre || null,
      solo_su_area: q?.solo_su_area ?? null,
      // La pantalla de ingreso solo necesita nombre y sector. Teléfonos y correos
      // se ven únicamente con permiso de administrar: antes salían a cualquiera,
      // sin haber ingresado.
      usuarios: (!pideIngreso() || q?.rol === "admin" || esDeAtcl(q))
        ? db.prepare("SELECT nombre, area, telefono, correo, rol, solo_su_area, recibe_resumen FROM usuarios WHERE activo=1 "
                     + "ORDER BY rol DESC, area, nombre").all()
        : db.prepare("SELECT nombre, area FROM usuarios WHERE activo=1 ORDER BY rol DESC, area, nombre").all(),
      // Nombre viejo del campo: lo sigue leyendo cualquier pestaña que quedó
      // abierta desde antes del cambio, y sin él se traba en el ingreso.
      areas: db.prepare("SELECT nombre FROM usuarios WHERE activo=1 ORDER BY nombre").all().map(r => r.nombre),
    };
  },

  "POST /api/ingresar": (body, _u, req, res) => {
    // Se entra con el nombre de la persona. Se acepta también el área por
    // compatibilidad: hasta que se den de alta las personas, el usuario que
    // existe se llama como el área y la gente va a escribir eso.
    const quien = (body.usuario || body.area || "").trim();
    const origen = origenDe(req);
    frenarIngreso(origen, quien);
    const u = db.prepare("SELECT * FROM usuarios WHERE nombre=? AND activo=1").get(quien);
    if (!u || !claveCorrecta(body.clave || "", u.clave)) {
      fallaIngreso(origen, quien);
      throw new Error("Usuario o clave incorrecta");
    }
    fallos.delete(origen + "|" + quien);
    const token = crypto.randomBytes(32).toString("hex");
    const ahora = Date.now();
    db.prepare("INSERT INTO sesiones (token, usuario, creada_en, ultimo_uso) VALUES (?,?,?,?)")
      .run(token, u.nombre, ahora, ahora);
    res.setHeader("Set-Cookie",
      `crm_sesion=${token}; Path=/; Max-Age=${DIAS_SESION * 24 * 3600}; HttpOnly; SameSite=Lax`);
    return { ok: true, usuario: u.nombre, area: u.area };
  },

  "POST /api/salir": (_b, _u, req, res) => {
    const cookie = (req.headers.cookie || "").split(";").map(x => x.trim().split("="))
      .find(([k]) => k === "crm_sesion");
    if (cookie) db.prepare("DELETE FROM sesiones WHERE token=?").run(cookie[1]);
    res.setHeader("Set-Cookie", "crm_sesion=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax");
    return { ok: true };
  },

  // Alta y baja de usuarios, desde Configuración.
  // Alta y modificación de una persona. Si ya existe, se actualiza lo que venga:
  // la clave solo si la mandaron, así se puede corregir un teléfono sin tener
  // que volver a escribirle la clave a alguien.
  "POST /api/usuarios": (body) => {
    const nombre = String(body.nombre ?? body.area ?? "").trim();
    if (!nombre) throw new Error("Falta el nombre");
    const existe = db.prepare("SELECT * FROM usuarios WHERE nombre=?").get(nombre);
    if (!existe && !body.clave) throw new Error("Falta la clave");
    // Desde el alta, un nombre que ya existe pisaría a esa persona sin avisar:
    // basta un homónimo o un error de tipeo para dejar a alguien afuera. El
    // lápiz manda `modificando`, así que solo por ahí se puede sobrescribir.
    // Si está dado de baja, el alta lo reactiva: es lo que uno espera al volver
    // a cargar a alguien que se había ido y volvió.
    if (existe?.activo && !body.modificando)
      throw new Error(`Ya hay alguien cargado como «${nombre}». Usá el lápiz para modificarlo`);
    if (body.clave && String(body.clave).length < 4)
      throw new Error("La clave tiene que tener al menos 4 caracteres");

    const area = String(body.sector ?? body.area_usuario ?? existe?.area ?? "").trim();
    const rol = body.rol === "admin" ? "admin" : "area";
    soloAdminSi(rol === "admin" || existe?.rol === "admin", "Cargar o cambiar un administrador");
    // Un sector que no está en la lista deja a la persona viendo un tablero
    // vacío: ningún pedido puede pertenecer a un área que no existe. Se rechaza
    // acá porque el error aparece días después, cuando alguien dice "no veo nada".
    if (area) {
      const hay = db.prepare("SELECT 1 FROM listas WHERE tipo='area' AND valor=?").get(area);
      if (!hay) throw new Error(`«${area}» no es un área del sistema. Cargala primero en Configuración`);
    }
    // El teléfono se guarda solo con los números: el WhatsApp no entiende
    // paréntesis ni guiones, igual que en la lista de destinatarios.
    let telefono = existe?.telefono ?? null;
    if (body.telefono !== undefined) {
      const crudo = String(body.telefono).trim();
      const soloNumeros = crudo.replace(/\D/g, "");
      // Se guarda solo lo numérico —el WhatsApp no entiende paréntesis ni
      // guiones—, pero si de lo que escribieron no queda ningún número, es un
      // error de carga y no un campo vacío: avisarlo, no guardar nada en silencio.
      if (crudo && !soloNumeros) throw new Error(`«${crudo}» no tiene ningún número de teléfono`);
      if (soloNumeros && soloNumeros.length < 8)
        throw new Error(`«${crudo}» es muy corto para un teléfono`);
      telefono = soloNumeros || null;
    }
    const correo = body.correo === undefined
      ? (existe?.correo ?? null)
      : (String(body.correo).trim() || null);
    if (correo && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo))
      throw new Error(`«${correo}» no parece un correo`);
    // Un administrador sin área no puede quedar limitado a «su sector»: no tiene.
    const solo = rol === "admin" && !area ? 0
      : body.solo_su_area === undefined ? (existe?.solo_su_area ?? 1)
      : (body.solo_su_area ? 1 : 0);
    // Quitarle el rol al último administrador deja el panel sin nadie que pueda
    // administrarlo, y con el ingreso encendido no hay forma de salir de ahí sin
    // tocar la base a mano. La baja ya estaba protegida; esto era la puerta de al lado.
    if (existe?.rol === "admin" && rol !== "admin") {
      const otros = db.prepare(
        "SELECT COUNT(*) c FROM usuarios WHERE rol='admin' AND activo=1 AND nombre<>?").get(nombre).c;
      if (!otros) throw new Error(
        "Es el único administrador: nombrá otro antes de quitarle el rol");
    }
    const resumen = body.recibe_resumen === undefined ? (existe?.recibe_resumen ?? 1)
      : (body.recibe_resumen ? 1 : 0);
    const clave = body.clave ? cifrar(String(body.clave)) : existe.clave;

    db.prepare(`INSERT INTO usuarios (nombre, area, telefono, correo, clave, rol, solo_su_area, recibe_resumen, activo, creado_en)
                VALUES (?,?,?,?,?,?,?,?,1,?)
                ON CONFLICT(nombre) DO UPDATE SET
                  area=excluded.area, telefono=excluded.telefono, correo=excluded.correo,
                  clave=excluded.clave, rol=excluded.rol, solo_su_area=excluded.solo_su_area,
                  recibe_resumen=excluded.recibe_resumen, activo=1`)
      .run(nombre, area, telefono, correo, clave, rol, solo, resumen, existe?.creado_en || Date.now());
    if (existe && existe.area !== area) soltarPedidos(nombre, `${nombre} pasó a ${area || "sin sector"}`, area);
    return { ok: true };
  },

  "POST /api/usuarios/baja": (body) => {
    // Sin ningún administrador no habría quién vuelva a administrar el panel.
    const nombre = String(body.nombre ?? body.area ?? "").trim();
    const u = db.prepare("SELECT rol FROM usuarios WHERE nombre=? AND activo=1").get(nombre);
    soloAdminSi(u?.rol === "admin", "Dar de baja a un administrador");
    if (u?.rol === "admin") {
      const admins = db.prepare("SELECT COUNT(*) c FROM usuarios WHERE rol='admin' AND activo=1").get().c;
      if (admins <= 1) throw new Error("Es el único administrador: cargá otro antes de darlo de baja");
    }
    db.prepare("UPDATE usuarios SET activo=0 WHERE nombre=?").run(nombre);
    db.prepare("DELETE FROM sesiones WHERE usuario=?").run(nombre);
    soltarPedidos(nombre, `${nombre} se dio de baja`);
    return { ok: true };
  },

  // ── WhatsApp ──
  "GET /api/wsp": () => wsp.situacion(),
  "GET /api/planilla": () => planilla.situacion(),
  "POST /api/planilla/leer": async () => { await planilla.leer(); return planilla.situacion(); },
  "POST /api/wsp/conectar": () => { wsp.conectar(); return { ok: true }; },
  "POST /api/wsp/salir": () => { wsp.salir(); return { ok: true }; },
  // ── Estadística ──
  // Se mide por ítem (cada pedido), no por ticket: un ticket puede tener
  // varios pedidos y contarlos como uno deformaría todos los promedios.
  "GET /api/estadistica": (_b, url) => {
    const periodo = url.searchParams.get("periodo") || "mes";
    const ahora = new Date();
    let desde = 0, hasta = Date.now(), titulo = "Todo";
    if (periodo === "mes") {
      desde = new Date(ahora.getFullYear(), ahora.getMonth(), 1).getTime();
      titulo = "Este mes";
    } else if (periodo === "mes_anterior") {
      desde = new Date(ahora.getFullYear(), ahora.getMonth() - 1, 1).getTime();
      hasta = new Date(ahora.getFullYear(), ahora.getMonth(), 1).getTime();
      titulo = "Mes anterior";
    } else if (periodo === "30") {
      desde = Date.now() - 30 * 24 * 3600 * 1000;
      titulo = "Últimos 30 días";
    }

    const items = db.prepare(`
      SELECT i.*, t.numero, t.abonado, a.nombre AS abonado_nombre
      FROM items i JOIN tickets t ON t.id=i.ticket_id
      LEFT JOIN abonados a ON a.codigo=t.abonado
      WHERE i.creado_en >= ? AND i.creado_en < ?
        AND (i.motivo_cierre IS NULL OR i.motivo_cierre <> 'Anulado')
    `).all(desde, hasta)    // los anulados no son trabajo: no deforman los promedios
      .filter(esMio);

    const cerrados = items.filter(i => i.cerrado_en);
    // El tiempo con el reloj frenado no se le cuenta a nadie.
    const horas = (i) => (i.cerrado_en - i.creado_en - (i.pausa_ms || 0)) / 3600000;
    const enPlazo = cerrados.filter(i => i.vence_en && i.cerrado_en <= i.vence_en);
    const prom = (xs) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;

    const contarPor = (campo) => {
      const m = {};
      for (const i of items) {
        const k = i[campo] ?? "—";
        m[k] ||= { total: 0, cerrados: 0, en_plazo: 0, horas: [] };
        m[k].total++;
        if (i.cerrado_en) {
          m[k].cerrados++;
          if (i.vence_en && i.cerrado_en <= i.vence_en) m[k].en_plazo++;
          m[k].horas.push(horas(i));
        }
      }
      return Object.entries(m).map(([valor, v]) => ({
        valor, total: v.total, cerrados: v.cerrados,
        pct_plazo: v.cerrados ? Math.round(v.en_plazo * 100 / v.cerrados) : null,
        horas_prom: v.horas.length ? Math.round(prom(v.horas) * 10) / 10 : null,
      })).sort((a, b) => b.total - a.total);
    };

    // Reincidencia: el mismo abonado con el mismo tipo de pedido más de una vez
    // dentro de 30 días. Es el número que más plata ahorra.
    const reinc = {};
    const orden = [...items].sort((a, b) => a.creado_en - b.creado_en);
    for (let x = 0; x < orden.length; x++)
      for (let y = x + 1; y < orden.length; y++)
        if (orden[x].abonado === orden[y].abonado && orden[x].tipo === orden[y].tipo &&
            orden[y].creado_en - orden[x].creado_en <= 30 * 24 * 3600 * 1000) {
          const k = `${orden[x].abonado}|${orden[x].tipo}`;
          reinc[k] ||= { abonado: orden[x].abonado,
                         nombre: orden[x].abonado_nombre || orden[x].abonado,
                         tipo: orden[x].tipo, veces: 1 };
          reinc[k].veces++;
          break;
        }

    const respuestas = items.filter(i => i.primera_mano)
      .map(i => (i.primera_mano - i.creado_en) / 3600000);

    return {
      titulo,
      totales: {
        cargados: items.length,
        cerrados: cerrados.length,
        abiertos: items.length - cerrados.length,
        pct_plazo: cerrados.length ? Math.round(enPlazo.length * 100 / cerrados.length) : null,
        horas_resolucion: prom(cerrados.map(horas)) !== null ? Math.round(prom(cerrados.map(horas)) * 10) / 10 : null,
        horas_respuesta: prom(respuestas) !== null ? Math.round(prom(respuestas) * 10) / 10 : null,
      },
      por_area: contarPor("area"),
      por_urgencia: contarPor("urgencia"),
      por_tipo: contarPor("tipo"),
      por_canal: contarPor("canal"),
      causas: contarPor("causa_raiz").filter(x => x.valor !== "—"),
      motivos: contarPor("motivo_cierre").filter(x => x.valor !== "—"),
      reincidencia: Object.values(reinc).sort((a, b) => b.veces - a.veces),
    };
  },

  // ── Copias de seguridad ──
  "GET /api/copias": () => ({
    copias: fs.readdirSync(DIR_COPIAS).filter(f => f.endsWith(".db")).sort().reverse()
      .map(f => {
        const st = fs.statSync(path.join(DIR_COPIAS, f));
        return { archivo: f, kb: Math.round(st.size / 1024), ts: st.mtimeMs };
      }),
  }),

  "POST /api/copias/nueva": () => ({ ok: true, archivo: path.basename(respaldar("a-mano")) }),

  // Deja la copia marcada y el CRM la aplica al reiniciar: es la forma segura,
  // sin tocar la base mientras está abierta.
  "POST /api/copias/restaurar": (body) => {
    const origen = path.join(DIR_COPIAS, path.basename(body.archivo || ""));
    if (!fs.existsSync(origen)) throw new Error("No encuentro esa copia");
    fs.copyFileSync(origen, PENDIENTE);
    return { ok: true, aviso: "Cerrá y volvé a abrir el CRM para que la copia se aplique." };
  },

  // Consulta si unos números están registrados en WhatsApp. No envía nada.
  "POST /api/wsp/verificar": (body) => wsp.verificar(body.numeros || []),

  // El mensaje de prueba también se sigue: si el botón dijera "listo" sin
  // saber si llegó, sería la misma mentira que se acaba de arreglar en los
  // avisos. El aviso_id 0 quiere decir "esto fue una prueba, no un aviso".
  "POST /api/wsp/probar": async (body) => {
    if (!body.numero) throw new Error("Falta el número");
    const idMensaje = await wsp.enviarMensaje(
      body.numero, body.texto || "Prueba del CRM de Atención al Cliente ✅");
    if (idMensaje) {
      db.prepare(`INSERT OR REPLACE INTO entregas_wsp
        (id_mensaje, aviso_id, numero, nombre, estado, ts)
        VALUES (?, 0, ?, 'prueba', 'mandado', ?)`)
        .run(idMensaje, String(body.numero), Date.now());
    }
    return { ok: true, id_mensaje: idMensaje };
  },

  // Lo mismo para el correo, que no tenía forma de probarse. Igual que el
  // WhatsApp, se sigue: decir "listo" apenas Resend acepta el pedido sería la
  // misma mentira. aviso_id 0 quiere decir "prueba, no aviso".
  "POST /api/correo/probar": async (body) => {
    if (!body.correo) throw new Error("Falta el correo");
    const key = cfg("resend_key"), desde = cfg("correo_desde");
    if (!key || !desde) throw new Error("Falta la clave de envío o la dirección de salida");
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: desde, to: [body.correo],
        subject: body.asunto || "Prueba del CRM de Atención al Cliente",
        text: body.texto || "Prueba del CRM. Si llegó, el envío por correo está funcionando.",
      }),
    });
    if (!r.ok) throw new Error("Resend contestó " + r.status);
    const j = await r.json();
    if (j && j.id) {
      db.prepare(`INSERT OR REPLACE INTO entregas_mail
        (id_envio, aviso_id, destinos, estado, ts) VALUES (?, 0, ?, 'mandado', ?)`)
        .run(String(j.id), String(body.correo), Date.now());
    }
    return { ok: true, id_envio: j && j.id };
  },

  // Cómo le fue a las pruebas de correo.
  "GET /api/correo/pruebas": () => ({
    pruebas: db.prepare(`SELECT id_envio, destinos, estado, detalle, ts
                         FROM entregas_mail WHERE aviso_id=0
                         ORDER BY ts DESC LIMIT 10`).all(),
  }),

  // Cómo le fue a los mensajes de prueba. Sirve para ver, sin molestar a nadie,
  // que el circuito de confirmación esté funcionando.
  "GET /api/wsp/pruebas": () => ({
    pruebas: db.prepare(`SELECT id_mensaje, numero, estado, detalle, ts
                         FROM entregas_wsp WHERE aviso_id=0
                         ORDER BY ts DESC LIMIT 10`).all(),
  }),
};

// ── Server ─────────────────────────────────────────────────────────────────
// Lo que configura el sistema y no los pedidos: con el ingreso encendido, solo
// el administrador. Es la única lista: una ruta nueva que toque esto va acá.
// Un usuario de área podía dejar programada la vuelta a una copia vieja de la
// base, desvincular el WhatsApp de los avisos o cambiar a quién le llegan.
const SOLO_ADMIN = new Set([
  "POST /api/config", "POST /api/usuarios", "POST /api/usuarios/baja",
  // Agregar a una lista queda abierto: se hace desde el alta, con «+ Agregar a la lista…».
  "POST /api/listas/borrar", "POST /api/listas/editar", "POST /api/listas/reloj",
  "POST /api/telefonos", "POST /api/telefonos/borrar", "POST /api/correos", "POST /api/correos/borrar",
  "POST /api/contactos",
  "GET /api/copias", "POST /api/copias/nueva", "POST /api/copias/restaurar",
  "POST /api/wsp/conectar", "POST /api/wsp/salir", "POST /api/wsp/verificar", "POST /api/wsp/probar",
  "POST /api/correo/probar", "POST /api/avisos/borrar", "GET /api/planilla", "POST /api/planilla/leer",
]);

// De SOLO_ADMIN, lo que también puede hacer Atención al Cliente (ver AREA_CONFIGURA).
const ABIERTAS_A_ATCL = new Set([
  "POST /api/config", "POST /api/usuarios", "POST /api/usuarios/baja",
  "POST /api/listas/borrar", "POST /api/listas/editar", "POST /api/listas/reloj",
  "POST /api/telefonos", "POST /api/telefonos/borrar", "POST /api/correos", "POST /api/correos/borrar",
  "POST /api/contactos", "POST /api/wsp/verificar", "GET /api/planilla", "POST /api/planilla/leer",
]);

// Las que escriben un pedido: van enteras o no van (ver `atomico`).
const ATOMICAS = new Set([
  "POST /api/items", "POST /api/items/para-cerrar", "POST /api/items/estado", "POST /api/items/area",
  "POST /api/items/editar", "POST /api/items/nota", "POST /api/items/anular", "POST /api/items/cerrar",
  // Renombrar un valor de lista toca pedidos, usuarios y avisos a la vez.
  "POST /api/listas/editar",
  // Trasladar o dar de baja a alguien también suelta sus pedidos: va todo junto.
  "POST /api/usuarios", "POST /api/usuarios/baja",
]);

// Checklist de Altas: sus rutas viven en altas.js.
require("./altas")({ db, cfg, rutas, wsp, telefonosDe, mandaDeVerdad, pideIngreso,
                     quien: () => miraEnCurso, SOLO_ADMIN });

// Lo único que se puede tocar sin haber ingresado.
const SIN_INGRESO = new Set(["GET /api/quien", "POST /api/ingresar", "POST /api/salir"]);

// Sin el tipo correcto el navegador no dibuja el logo ni aplica la tipografía:
// los recibe como archivo suelto y los ignora, sin decir nada.
const TIPOS = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".ttf": "font/ttf",
  ".woff2": "font/woff2", ".png": "image/png", ".jpg": "image/jpeg", ".ico": "image/x-icon",
};

// Cabeceras de seguridad. Van en TODAS las respuestas (panel, API y 404), por
// eso se ponen acá arriba y no en cada writeHead: lo que se fija con setHeader
// se manda igual, salvo que un writeHead posterior repita esa misma cabecera.
function cabecerasDeSeguridad(req, res) {
  // Que nadie pueda meter el CRM en un iframe y robar los clics del que entra
  // (clickjacking). frame-ancestors es lo mismo pero para navegadores nuevos.
  res.setHeader("X-Frame-Options", "DENY");
  // Que el navegador no adivine el tipo de archivo y termine ejecutando algo.
  res.setHeader("X-Content-Type-Options", "nosniff");
  // Que la URL del CRM no viaje a sitios de afuera al hacer clic en un enlace.
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Content-Security-Policy", [
    "default-src 'self'",
    // El panel es un solo archivo con el script y los estilos adentro, así que
    // 'unsafe-inline' es obligatorio mientras siga siendo así.
    "script-src 'self' 'unsafe-inline'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "form-action 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'none'",
  ].join("; "));
  // HSTS SOLO si se entró por HTTPS. Railway corta el TLS y nos habla por HTTP,
  // por eso se mira x-forwarded-proto. Mandarlo siempre dejaría afuera a quien
  // abre el CRM por la red interna (http://192.168.5.178), porque el navegador
  // se acordaría del dominio y forzaría HTTPS donde no hay certificado.
  const proto = req.headers["x-forwarded-proto"] || (req.socket.encrypted ? "https" : "http");
  if (proto === "https")
    res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
}

const server = http.createServer((req, res) => {
  // Base fija: con el Host que manda el cliente, uno inválido («[») tiraba una
  // excepción fuera de todo try y se caía el CRM entero.
  let url;
  try { url = new URL(req.url, "http://crm.local"); }
  catch { res.writeHead(400); res.end("Pedido inválido"); return; }
  const clave = `${req.method} ${url.pathname}`;
  cabecerasDeSeguridad(req, res);

  if (rutas[clave]) {
    let cuerpo = "";
    req.on("data", (c) => (cuerpo += c));
    req.on("end", () => {
      try {
        const body = cuerpo ? JSON.parse(cuerpo) : {};
        const quien = quienEs(req);
        usuarioEnCurso = quien?.nombre || null;
        miraEnCurso = quien;
        esAdmin = quien?.rol === "admin";
        esAtcl = esDeAtcl(quien);
        // Quién entra y qué se le contesta. Sirve para entender desde acá qué
        // ve alguien que abre el panel desde otra máquina.
        if (clave === "GET /api/quien" || (pideIngreso() && !usuarioEnCurso))
          console.log(`  ${new Date().toLocaleTimeString("es-AR", { hour12: false })}  ${req.socket.remoteAddress}` +
            `  ${clave}  pide_ingreso=${pideIngreso() ? "SI" : "no"}` +
            `  sesion=${usuarioEnCurso || "-"}  agente=${(req.headers["user-agent"] || "").slice(0, 40)}`);

        if (pideIngreso() && !usuarioEnCurso && !SIN_INGRESO.has(clave)) {
          res.writeHead(401, { "Content-Type": "application/json; charset=utf-8" });
          res.end(JSON.stringify({ error: "Hay que ingresar" }));
          return;
        }
        // Algunas rutas son asíncronas (las que hablan con WhatsApp): se espera
        // el resultado antes de contestar, si no se devolvía la promesa vacía.
        if (SOLO_ADMIN.has(clave) && !(esAtcl && ABIERTAS_A_ATCL.has(clave))) soloAdmin();
        const correr = () => rutas[clave](body, url, req, res);
        Promise.resolve(ATOMICAS.has(clave) ? atomico(correr) : correr()).then((salida) => {
          if (clave === "POST /api/items" && salida?.ok)
            console.log(`  alta OK  ${new Date().toLocaleTimeString("es-AR", { hour12: false })}  ${body.abonado} · ${body.area} · u${body.urgencia}`);
          res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
          res.end(JSON.stringify(salida));
        }).catch((e) => {
          console.log(`  ✗ ${clave} rechazado: ${e.message}`);
          res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
          res.end(JSON.stringify({ error: e.message }));
        });
      } catch (e) {
        console.log(`  ✗ ${clave} rechazado: ${e.message}`);
        res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  const archivo = url.pathname === "/" ? "/index.html" : url.pathname;
  const ruta = path.join(DIR, "public", path.normalize(archivo).replace(/^(\.\.[/\\])+/, ""));
  fs.readFile(ruta, (err, data) => {
    if (err) { res.writeHead(404); res.end("No encontrado"); return; }
    // Sin esto el navegador se queda con el panel viejo guardado y, cuando el
    // panel y el servidor no hablan el mismo idioma, la pantalla se traba.
    res.writeHead(200, {
      "Content-Type": TIPOS[path.extname(ruta)] || "application/octet-stream",
      // no-store: que no lo guarde ni un minuto. El panel es un archivo chico y
      // cambia seguido; una copia vieja en el navegador se traba y no hay forma
      // de arreglarla desde acá. La tipografía y el logo son la excepción: no
      // cambian nunca y la letra pesa 786 KB, que no tiene sentido bajar en
      // cada pantalla.
      "Cache-Control": /\.(ttf|woff2|svg|png|ico)$/.test(ruta)
        ? "public, max-age=604800"
        : "no-store, must-revalidate",
      "Pragma": "no-cache",
      "Expires": "0",
    });
    res.end(data);
  });
});

// Si el CRM se cerró justo mientras mandaba un aviso, quedó marcado "en curso"
// para siempre. Al arrancar se devuelven a pendiente para que se reintenten.
db.prepare("UPDATE avisos SET enviado=0 WHERE enviado=-1").run();

// ── El mismo puerto atiende HTTP y HTTPS ───────────────────────────────────
// El router publica este puerto hacia afuera, y hay gente entrando por http://
// desde la red interna. En vez de partir en dos puertos, se mira el primer byte
// de cada conexión: 0x16 es el saludo de TLS, cualquier otra cosa es HTTP a
// secas. Así conviven las dos formas sin que nadie tenga que cambiar nada.
function escucharAmbos(servidorHttp) {
  const tls = require("node:tls");
  const net = require("node:net");
  const ARCHIVO_CERT = path.join(DIR_DATOS, "cert", "certificado.pem");
  const ARCHIVO_CLAVE = path.join(DIR_DATOS, "cert", "clave.pem");

  if (!fs.existsSync(ARCHIVO_CERT)) {
    servidorHttp.listen(PUERTO, avisar);
    return;
  }

  const servidorTls = new tls.Server({
    cert: fs.readFileSync(ARCHIVO_CERT),
    key: fs.readFileSync(ARCHIVO_CLAVE),
  });
  // Las conexiones cifradas se le pasan al mismo servidor HTTP ya descifradas.
  servidorTls.on("secureConnection", (s) => servidorHttp.emit("connection", s));

  net.createServer((conexion) => {
    conexion.once("data", (primero) => {
      conexion.pause();
      conexion.unshift(primero);
      if (primero[0] === 0x16) servidorTls.emit("connection", conexion);
      else servidorHttp.emit("connection", conexion);
      process.nextTick(() => conexion.resume());
    });
    conexion.on("error", () => {});
  }).listen(PUERTO, avisar);
}

function avisar() {
  console.log(`\n  CRM Atención al Cliente`);
  console.log(`     http://localhost:${PUERTO}   ·   https://localhost:${PUERTO}\n`);
  if (!ES_PRODUCCION)
    console.log("     COPIA: no manda WhatsApp ni correos. Solo el CRM de la nube envía.\n");
}

setInterval(copiaDelDia, 3600 * 1000);   // chequea una vez por hora
// Los pedidos abiertos que se cargaron sin los datos de la planilla (el CRM
// recién arrancaba, Google no contestó o el cliente se agregó después) se
// completan cuando la planilla se lee bien. Los que ya tienen datos no se tocan.
planilla.arrancar(() => {
  const faltan = db.prepare(`SELECT i.id, t.abonado FROM items i JOIN tickets t ON t.id=i.ticket_id
    WHERE i.estado <> 'Cerrado' AND i.cli_domicilio IS NULL AND i.cli_vendedor IS NULL`).all();
  const poner = db.prepare(`UPDATE items SET cli_domicilio=?, cli_localidad=?, cli_vendedor=?,
    cli_administrador=?, cli_servicios=? WHERE id=?`);
  for (const f of faltan) {
    const c = planilla.buscar(f.abonado);
    if (c) poner.run(c.domicilio || null, c.localidad || null, c.vendedor || null,
                     c.administrador || null, c.servicios || null, f.id);
  }
});

escucharAmbos(server);
try { console.log("  copia de seguridad:", path.basename(respaldar("al-arrancar"))); } catch (e) { console.error("  copia:", e.message); }
// Una sola vez, el 23/10/2026: desde que cada vendedor ve sólo lo suyo, los casos
// de Comercial sin vendedor no los vería nadie del área. Gastón pidió dárselos
// todos a Facundo. Corre después de la copia de arranque y queda anotado en
// cada pedido; la marca en config impide que se repita en otro arranque.
if (cfg("comercial_sin_asignar_a_facundo") !== "hecho") {
  if (db.prepare("SELECT 1 FROM usuarios WHERE nombre='Facundo' AND area=? AND activo=1").get(AREA_VENDEDORES)) {
    const sueltos = db.prepare("SELECT id FROM items WHERE area=? AND estado<>'Cerrado' AND (persona IS NULL OR persona='')").all(AREA_VENDEDORES);
    db.exec("BEGIN");
    for (const { id } of sueltos) {
      db.prepare("UPDATE items SET persona='Facundo' WHERE id=?").run(id);
      anotar(id, "Pasado a Facundo dentro de Comercial — estaba sin vendedor asignado");
    }
    db.prepare("INSERT INTO config (clave, valor) VALUES ('comercial_sin_asignar_a_facundo','hecho') ON CONFLICT(clave) DO UPDATE SET valor='hecho'").run();
    db.exec("COMMIT");
    console.log(`  Comercial: ${sueltos.length} pedidos sin vendedor pasados a Facundo`);
  } else console.error("  Comercial: Facundo no está activo en Comercial; los pedidos sin vendedor quedan como estaban");
}
// Si ya se escaneó el QR alguna vez, la sesión se retoma sola al arrancar.
// WhatsApp avisa por su cuenta cuando un mensaje le llega al otro teléfono, y
// puede tardar horas si estaba apagado. No se le puede preguntar: hay que estar
// escuchando. Por eso se engancha antes de conectar.
wsp.alCambiarEntrega((idMensaje, estado, detalle) => {
  try {
    // Nunca se retrocede: si ya está en "llego", un aviso viejo que llegue
    // después no puede devolverlo a "mandado".
    db.prepare(`UPDATE entregas_wsp SET estado=?, detalle=?
                WHERE id_mensaje=? AND estado!='llego'`)
      .run(estado, detalle, idMensaje);
  } catch {}
});

if (wsp.hayCredenciales()) wsp.conectar().catch(() => {});
