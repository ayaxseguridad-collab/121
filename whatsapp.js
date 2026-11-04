// Conexión a WhatsApp desde esta máquina, con el mismo mecanismo que
// WhatsApp Web: se escanea un QR una sola vez y la sesión queda guardada en
// datos/sesion-wsp/. Mientras el server esté andando, el bot puede mandar.
//
// Importante: es una conexión no oficial. Conviene usar un número dedicado y
// no mandar volumen alto, para no exponer el número de la empresa.

const path = require("node:path");
const fs = require("node:fs");

const DIR_SESION = path.join(__dirname, "datos", "sesion-wsp");

let sock = null;
let estado = "desconectado";   // desconectado | esperando_qr | conectado
let qrDataUrl = null;
let miNumero = null;
let ultimoError = null;
let reconectando = false;
let intentos = 0;          // para no reintentar para siempre cada 5 segundos

async function conectar() {
  if (sock || reconectando) return;
  reconectando = true;
  if (estado === "desconectado" && !qrDataUrl) intentos = intentos || 0;
  try {
    const { default: makeWASocket, useMultiFileAuthState, DisconnectReason } =
      await import("@whiskeysockets/baileys");
    const QR = require("qrcode");

    fs.mkdirSync(DIR_SESION, { recursive: true });
    const { state, saveCreds } = await useMultiFileAuthState(DIR_SESION);

    // El log de baileys es muy verboso: lo silenciamos. child() tiene que
    // devolver un logger igual, por eso se referencia a sí mismo.
    const silencioso = {
      level: "silent",
      trace() {}, debug() {}, info() {}, warn() {}, error() {}, fatal() {},
      child() { return silencioso; },
    };

    sock = makeWASocket({
      auth: state,
      logger: silencioso,
      browser: ["CRM Atencion", "Chrome", "1.0"],
      syncFullHistory: false,
      markOnlineOnConnect: false,   // no marca el teléfono como en línea
    });

    sock.ev.on("creds.update", saveCreds);
    _mirarEntregas(sock);

    sock.ev.on("connection.update", async (u) => {
      if (u.qr) {
        estado = "esperando_qr";
        qrDataUrl = await QR.toDataURL(u.qr, { margin: 1, width: 300 });
      }
      if (u.connection === "open") {
        estado = "conectado";
        qrDataUrl = null;
        ultimoError = null;
        intentos = 0;
        miNumero = sock.user?.id?.split(":")[0] || null;
        console.log("  WhatsApp conectado como", miNumero);
      }
      if (u.connection === "close") {
        const codigo = u.lastDisconnect?.error?.output?.statusCode;
        sock = null;
        if (codigo === DisconnectReason.loggedOut) {
          // Sesión cerrada desde el teléfono: hay que volver a escanear.
          estado = "desconectado";
          qrDataUrl = null;
          try { fs.rmSync(DIR_SESION, { recursive: true, force: true }); } catch {}
          ultimoError = "La sesión se cerró desde el teléfono. Hay que escanear el QR de nuevo.";
        } else if (++intentos <= 10) {
          // Espera cada vez un poco más, hasta un minuto.
          const espera = Math.min(5000 * intentos, 60000);
          estado = "desconectado";
          ultimoError = `Se cortó la conexión, reintentando (${intentos} de 10)…`;
          setTimeout(() => conectar().catch(() => {}), espera);
        } else {
          estado = "desconectado";
          ultimoError = "No se pudo reconectar. Probá con el botón Conectar WhatsApp.";
        }
      }
    });
  } catch (e) {
    ultimoError = e.message;
    estado = "desconectado";
    sock = null;
  } finally {
    reconectando = false;
  }
}

// Deja el número como lo espera WhatsApp: solo dígitos con código de país.
// Acepta 3571..., 03571..., +54 9 3571..., etc.
function normalizar(numero) {
  let n = String(numero).replace(/\D/g, "");
  if (!n) return null;
  if (n.startsWith("54")) {
    // 54 + 9 + área + número (móvil). Si no trae el 9, se lo agregamos.
    if (!n.startsWith("549")) n = "549" + n.slice(2);
  } else {
    if (n.startsWith("0")) n = n.slice(1);
    n = "549" + n;
  }
  return n;
}

async function enviarMensaje(numero, texto) {
  if (estado !== "conectado" || !sock) throw new Error("WhatsApp no está conectado");
  const n = normalizar(numero);
  if (!n) throw new Error("Número inválido");
  const res = await sock.sendMessage(n + "@s.whatsapp.net", { text: texto });
  // Devuelve el número de mensaje: es lo único que después permite saber si
  // el teléfono de la otra persona lo recibió de verdad. Que sendMessage
  // termine bien solo quiere decir que WhatsApp lo aceptó.
  return res?.key?.id || null;
}

// ── Si el mensaje llegó de verdad ─────────────────────────────────────────────
//
// WhatsApp avisa por etapas, y cada una dice algo distinto:
//   1 PENDING       ni salió
//   2 SERVER_ACK    el servidor de WhatsApp lo tiene. NO es que la persona lo tenga
//   3 DELIVERY_ACK  le llegó al teléfono   <- esto es "llegó"
//   4 READ  5 PLAYED  además lo abrió
//   0 ERROR         no se pudo entregar
//
// Los avisos llegan sueltos, cuando el otro teléfono se prende. Por eso esto es
// un aviso hacia afuera y no algo que se pueda preguntar.

const ETAPAS = { 0: "fallo", 1: "mandado", 2: "mandado", 3: "llego", 4: "llego", 5: "llego" };
let avisarEntrega = null;

function alCambiarEntrega(fn) { avisarEntrega = fn; }

function _mirarEntregas(sock) {
  sock.ev.on("messages.update", (cambios) => {
    for (const c of cambios || []) {
      const id = c?.key?.id;
      const st = c?.update?.status;
      if (!id || st === undefined || st === null || !avisarEntrega) continue;
      const cual = ETAPAS[typeof st === "number" ? st : Number(st)];
      if (cual) {
        try { avisarEntrega(id, cual, String(st)); } catch {}
      }
    }
  });
}

// Le pregunta a WhatsApp si esos números están registrados. No manda nada:
// sirve para saber si un número al que "se envió" existe de verdad.
async function verificar(numeros) {
  if (estado !== "conectado" || !sock) throw new Error("WhatsApp no está conectado");
  const salida = [];
  for (const n of numeros) {
    const limpio = String(n).replace(/\D/g, "");
    try {
      const r = await sock.onWhatsApp(limpio + "@s.whatsapp.net");
      const hay = Array.isArray(r) && r.length && r[0].exists;
      salida.push({ numero: limpio, tiene_whatsapp: !!hay, jid: hay ? r[0].jid : null });
    } catch (e) {
      salida.push({ numero: limpio, error: e.message });
    }
  }
  return salida;
}

async function salir() {
  try { await sock?.logout(); } catch {}
  try { fs.rmSync(DIR_SESION, { recursive: true, force: true }); } catch {}
  sock = null; estado = "desconectado"; qrDataUrl = null; miNumero = null;
}

const situacion = () => ({ estado, qr: qrDataUrl, numero: miNumero, error: ultimoError });
const hayCredenciales = () => fs.existsSync(path.join(DIR_SESION, "creds.json"));

module.exports = { conectar, enviarMensaje, salir, situacion, hayCredenciales,
                   normalizar, verificar, alCambiarEntrega };
