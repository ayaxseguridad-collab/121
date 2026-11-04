// Checklist de Altas — en producción desde el 22/10/2026.
//
// La idea completa está en ALTA-CRM.md (carpeta CLOUDE) y las respuestas a la
// auditoría del 20/10.
//   - La solapa la ve todo el que entra al CRM.
//   - Los WhatsApp les llegan a las áreas y personas elegidas, como los avisos
//     de los pedidos. Las copias no mandan (mandaDeVerdad).
//   - Cualquiera puede marcar cualquier paso (Gastón, 22/10); desmarcar, solo el
//     administrador.
//
// No toca los pedidos del CRM: tiene sus propias tablas.

const AREAS_SERVICIO = ["AT Cliente", "Monitoreo", "Comercial"];
const USUARIOS_SERVICIO = ["Gastón"];
const PASOS = [
  // id, ítem, responsable, avisa a, abre el plazo de, admite NO APLICA
  { id: "1",  item: "N.° de abonado asignado", resp: "Administración", avisa: ["AT Cliente"], tarea: "2", na: false },
  { id: "2",  item: "Datos del cliente completos", resp: "AT Cliente", na: true },
  { id: "3",  item: "Bienvenida enviada + coordinación para relevamiento", resp: "AT Cliente", na: true },
  { id: "4",  item: "OT generada", resp: "AT Cliente", avisa: ["Técnica"], tarea: "5", na: false },
  { id: "5",  item: "Relevamiento realizado", resp: "Técnica", avisa: ["AT Cliente"], tarea: "6", na: false },
  // Actúa Técnica (instala, paso 9). Comercial solo se entera.
  { id: "6",  item: "Internet + instalación coordinados", resp: "AT Cliente", avisa: ["Técnica", "Comercial"], tarea: "9", na: true },
  { id: "7a", item: "Formulario de Control de Acceso enviado (si corresponde)", resp: "AT Cliente", na: true },
  { id: "7b", item: "Grupo de WhatsApp creado/enviado", resp: "AT Cliente", na: true },
  { id: "8",  item: "Carga del servicio en planilla PAGAR", resp: "AT Cliente", na: true },
  { id: "9",  item: "Instalación realizada", resp: "Técnica", avisa: ["AT Cliente"], na: false },
  // El chequeo lo confirman las dos áreas, cada una por su lado. El aviso a ATC
  // sale cuando está la segunda confirmación, sea cual sea.
  { id: "10a", item: "Chequeo de funcionamiento — confirma Técnica", resp: "Técnica", avisa: ["AT Cliente"], tarea: "11", grupo: ["10a", "10b"], na: false },
  { id: "10b", item: "Chequeo de funcionamiento — confirma Monitoreo", resp: "Monitoreo", avisa: ["AT Cliente"], tarea: "11", grupo: ["10a", "10b"], na: false },
  { id: "11", item: "Mail de bienvenida final con datos y accesos a cámaras + Control de Acceso, si corresponde", resp: "AT Cliente", na: true },
  { id: "12", item: "Servicio operativo verificado", resp: "AT Cliente", na: false,
    avisa: AREAS_SERVICIO, usuarios_aviso: USUARIOS_SERVICIO, aviso_fijo: true },
];
const PASO = Object.fromEntries(PASOS.map(p => [p.id, p]));
const LARGO_NOTA = 2000;
// Un aviso que falla se reintenta cada 5, 10, 15… minutos, hasta 5 intentos.
const MAX_INTENTOS = 5;

module.exports = function montar(c) {
  const { db, cfg, rutas, wsp, telefonosDe, mandaDeVerdad, pideIngreso, quien, SOLO_ADMIN } = c;

  db.exec(`
  CREATE TABLE IF NOT EXISTS altas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cliente TEXT NOT NULL,
    abonado TEXT,                    -- se carga en el paso 1; puede no estar todavía
    creada_en INTEGER NOT NULL,
    creada_por TEXT,
    cerrada_en INTEGER,
    cerrada_por TEXT
  );
  CREATE TABLE IF NOT EXISTS alta_pasos (
    alta_id INTEGER NOT NULL,
    paso TEXT NOT NULL,
    estado TEXT NOT NULL DEFAULT 'pendiente',   -- pendiente | completado | no_aplica
    nota TEXT,                                  -- se puede guardar sin confirmar el paso
    por TEXT, ts INTEGER,                       -- quién lo resolvió y cuándo
    responsable TEXT,                           -- si se cambió al derivar
    plazo_desde INTEGER, vence_en INTEGER,      -- el plazo de ESTE paso, si se abrió
    av_por_vencer INTEGER NOT NULL DEFAULT 0,
    av_vencido INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (alta_id, paso)
  );
  CREATE TABLE IF NOT EXISTS alta_historial (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    alta_id INTEGER NOT NULL, paso TEXT, texto TEXT NOT NULL, usuario TEXT, ts INTEGER NOT NULL
  );
  -- Un renglón por aviso. «destinos» es el texto que se muestra; «para» (JSON)
  -- dice a qué áreas y personas se manda.
  CREATE TABLE IF NOT EXISTS alta_avisos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    alta_id INTEGER NOT NULL, paso TEXT, tipo TEXT NOT NULL,
    destinos TEXT, texto TEXT NOT NULL, ts INTEGER NOT NULL,
    estado TEXT NOT NULL DEFAULT 'pendiente',   -- pendiente | mandado | simulado | fallo | sin_destino
    detalle TEXT
  );
  -- Marca permanente: desmarcar el paso o limpiar el historial no habilita otro aviso.
  CREATE TABLE IF NOT EXISTS alta_servicio_avisado (
    alta_id INTEGER PRIMARY KEY,
    origen TEXT NOT NULL
  );
  -- Sin envíos retroactivos: las confirmaciones anteriores quedan reconocidas.
  INSERT OR IGNORE INTO alta_servicio_avisado (alta_id, origen)
    SELECT alta_id, 'anterior' FROM alta_pasos WHERE paso='12' AND estado='completado';
  INSERT OR IGNORE INTO alta_servicio_avisado (alta_id, origen)
    SELECT alta_id, 'anterior' FROM alta_avisos WHERE (paso='12' AND tipo='paso') OR tipo='final';
  `);
  // A quiénes ya les salió y cuántas veces se intentó, para reintentar solo lo que falta.
  const colsAv = db.prepare("PRAGMA table_info(alta_avisos)").all().map(c => c.name);
  if (!colsAv.includes("intentos")) db.exec("ALTER TABLE alta_avisos ADD COLUMN intentos INTEGER NOT NULL DEFAULT 0");
  if (!colsAv.includes("entregados")) db.exec("ALTER TABLE alta_avisos ADD COLUMN entregados TEXT");
  if (!colsAv.includes("prox_intento")) db.exec("ALTER TABLE alta_avisos ADD COLUMN prox_intento INTEGER");
  if (!colsAv.includes("para")) db.exec("ALTER TABLE alta_avisos ADD COLUMN para TEXT");
  // Los avisos de la prueba (sin «para») que no salieron no se mandan en
  // producción: llevan el texto de prueba y le llegarían a gente real.
  db.prepare(`UPDATE alta_avisos SET estado='descartado', prox_intento=NULL,
      detalle='Aviso de la prueba: no se manda en producción'
    WHERE para IS NULL AND estado IN ('pendiente', 'fallo', 'sin_destino')`).run();

  // Plazos apagados por ahora (Gastón, 21/10). Con altas_plazos=1 vuelven: el
  // servidor acepta horas, hay semáforo y el motor avisa. Los plazos que ya
  // tenían las Altas quedan guardados pero no cuentan mientras esté apagado;
  // antes de prenderlo hay que revisarlos, o saldrían vencidos atrasados.
  const plazosActivos = () => cfg("altas_plazos") === "1";

  const ATC = () => cfg("area_atcl") || "AT Cliente";
  function acceso() {
    if (pideIngreso() && !quien()) throw new Error("Hay que ingresar");
  }
  const yo = () => quien()?.nombre || null;
  const historia = (altaId, paso, texto) =>
    db.prepare("INSERT INTO alta_historial (alta_id, paso, texto, usuario, ts) VALUES (?,?,?,?,?)")
      .run(altaId, paso, texto, yo(), Date.now());
  const numeroAlta = (id) => "ALTA-" + String(id).padStart(4, "0");

  const esArea = (n) => !!db.prepare("SELECT 1 FROM listas WHERE tipo='area' AND valor=?").get(n);
  const telefonoDe = (usuario) => db.prepare(
    "SELECT telefono AS numero, nombre FROM usuarios WHERE nombre=? AND activo=1 "
    + "AND telefono IS NOT NULL AND telefono<>''").all(usuario);

  // Normaliza como whatsapp.js y descarta números sin un formato utilizable.
  const clave = (n) => {
    if (!/^[+\d\s().-]+$/.test(String(n || ""))) return "";
    let d = String(n || "").replace(/\D/g, "");
    if (!d) return "";
    if (d.startsWith("54")) d = d.startsWith("549") ? d : "549" + d.slice(2);
    else d = "549" + d.replace(/^0/, "");
    return /^\d{10,15}$/.test(d) ? d : "";
  };
  // Resolver cada destinatario por separado: un área con teléfono no oculta
  // que falte Gastón u otra área. Un número compartido sale una sola vez.
  function contactos(areas, usuarios) {
    const vistos = new Map(), faltantes = [], invalidos = [];
    const agregar = (nombre, filas) => {
      const validos = filas.filter(t => clave(t.numero));
      if (!validos.length) faltantes.push(nombre);
      for (const t of filas) {
        const k = clave(t.numero);
        if (!k) invalidos.push(`${nombre}: ${t.nombre || "contacto"}`);
        else if (!vistos.has(k)) vistos.set(k, t);
      }
    };
    for (const a of new Set(areas)) agregar(a, telefonosDe(a));
    for (const u of new Set(usuarios)) agregar(u, telefonoDe(u));
    return { numeros: [...vistos.values()], faltantes, invalidos };
  }

  const enVuelo = new Set();   // avisos que se están mandando ahora: el reintento no los toca
  async function mandar(avisoId, texto) {
    if (enVuelo.has(avisoId)) return;
    enVuelo.add(avisoId);
    try { await mandarUno(avisoId, texto); } finally { enVuelo.delete(avisoId); }
  }
  async function mandarUno(avisoId, texto) {
    if (!mandaDeVerdad()) {
      db.prepare("UPDATE alta_avisos SET estado='simulado', detalle=? WHERE id=?")
        .run("No salió: el CRM no está en modo real o esta no es la copia de la nube", avisoId);
      return;
    }
    const av = db.prepare("SELECT intentos, entregados, para FROM alta_avisos WHERE id=?").get(avisoId) || {};
    let para;
    try { para = JSON.parse(av.para); } catch { para = null; }
    if (!para) {
      db.prepare("UPDATE alta_avisos SET estado='descartado', prox_intento=NULL, detalle=? WHERE id=?")
        .run("Aviso de la prueba: no se manda en producción", avisoId);
      return;
    }
    const { numeros: nums, faltantes, invalidos } = contactos(para.areas || [], para.usuarios || []);
    const intento = (av.intentos || 0) + 1;
    let hechos;
    try { hechos = new Set(JSON.parse(av.entregados || "[]")); } catch { hechos = new Set(); }
    db.prepare("UPDATE alta_avisos SET intentos=? WHERE id=?").run(intento, avisoId);
    const notas = [];
    if (faltantes.length) notas.push(`Sin teléfono válido en Personas: ${faltantes.join(", ")}`);
    if (invalidos.length) notas.push(`Contactos inválidos: ${invalidos.join(", ")}`);
    for (const t of nums) {
      // Al que ya le salió en un intento anterior no se le vuelve a mandar.
      if (hechos.has(clave(t.numero))) { notas.push(`a ${t.nombre}: ya había salido`); continue; }
      try {
        await wsp.enviarMensaje(t.numero, texto);
        hechos.add(clave(t.numero));
        db.prepare("UPDATE alta_avisos SET entregados=? WHERE id=?").run(JSON.stringify([...hechos]), avisoId);
        notas.push(`a ${t.nombre}: salió`);
      } catch (e) { notas.push(`a ${t.nombre}: ${e.message}`); }
    }
    const todos = nums.length > 0 && !faltantes.length && !invalidos.length
      && nums.every(t => hechos.has(clave(t.numero)));
    const agotado = !todos && intento >= MAX_INTENTOS;
    db.prepare("UPDATE alta_avisos SET estado=?, detalle=?, prox_intento=? WHERE id=?")
      .run(todos ? "mandado" : nums.length ? "fallo" : "sin_destino",
           `intento ${intento}: ${notas.join(" · ")}${agotado ? " · reintentos agotados" : ""}`,
           todos || agotado ? null : Date.now() + intento * 5 * 60000, avisoId);
  }

  // Los avisos de plazo (por vencer, vencido) no salen mientras los plazos están
  // apagados, tampoco los que ya estaban en cola: quedan guardados como estaban.
  const DE_PLAZO = ["por_vencer", "vencido"];
  const tipoPermitido = (tipo) => plazosActivos() || !DE_PLAZO.includes(tipo);

  // Reintento de avisos fallidos, y de los que quedaron a medio camino si el
  // servidor se reinició mientras salían. Se manda el mismo texto, sin tocar el paso.
  // Los fallos de antes de este arreglo no tienen fecha de reintento: no se mandan
  // solos (podría salir historia vieja); se reenvían a mano con «Reenviar».
  function reintentar() {
    const ahora = Date.now();
    const filas = db.prepare(`SELECT id, tipo, texto FROM alta_avisos WHERE intentos < ? AND (
        (estado IN ('fallo', 'sin_destino') AND prox_intento IS NOT NULL AND prox_intento <= ?)
        OR (estado='pendiente' AND ts < ?))`).all(MAX_INTENTOS, ahora, ahora - 120000);
    for (const f of filas) if (!enVuelo.has(f.id) && tipoPermitido(f.tipo)) mandar(f.id, f.texto).catch(() => {});
  }
  // Se puede reenviar a mano un aviso que falló y ya no se va a reintentar solo:
  // porque se agotaron los intentos, porque es de antes del arreglo, o porque
  // faltaba el teléfono (sin_destino).
  const reenviable = (v) => ["fallo", "sin_destino"].includes(v.estado) && v.prox_intento == null
    && !enVuelo.has(v.id) && tipoPermitido(v.tipo);

  // «nombres» son áreas; si alguno no es un área (Gastón en el aviso final), se
  // busca como persona. «usuarios» son personas elegidas en la ventana.
  function avisar(altaId, paso, tipo, nombres, texto, usuarios = []) {
    const base = (cfg("url_panel") || "").replace(/\/+$/, "");
    const completo = texto + (base ? `\n👉 ${base}/?tab=altas&alta=${altaId}` : "");
    const para = paso === "12" && tipo === "paso"
      ? { areas: AREAS_SERVICIO, usuarios: USUARIOS_SERVICIO }
      : { areas: nombres.filter(esArea), usuarios: [...nombres.filter(n => !esArea(n)), ...usuarios] };
    const destinos = [...nombres, ...usuarios.map(u => u + " (persona)")];
    const r = db.prepare("INSERT INTO alta_avisos (alta_id, paso, tipo, destinos, texto, ts, para) VALUES (?,?,?,?,?,?,?)")
      .run(altaId, paso, tipo, destinos.join(", "), completo, Date.now(), JSON.stringify(para));
    // Se devuelve para mandarlo DESPUÉS de guardar: el reloj y el registro no
    // dependen de que WhatsApp conteste.
    return () => mandar(Number(r.lastInsertRowid), completo).catch(() => {});
  }

  function leerAlta(id) {
    const a = db.prepare("SELECT * FROM altas WHERE id=?").get(id);
    if (!a) throw new Error("No existe esa Alta");
    const filas = Object.fromEntries(db.prepare("SELECT * FROM alta_pasos WHERE alta_id=?").all(id).map(p => [p.paso, p]));
    const ahora = Date.now(), pct = Number(cfg("pct_preaviso") || 75) / 100;
    const pasos = PASOS.map(p => {
      const f = filas[p.id] || { estado: "pendiente" };
      let semaforo = null, restante = null;
      if (f.estado === "pendiente" && f.vence_en && plazosActivos()) {
        restante = f.vence_en - ahora;
        semaforo = restante < 0 ? "vencido"
          : restante < (f.vence_en - f.plazo_desde) * (1 - pct) ? "por_vencer" : "en_plazo";
      }
      return { ...p, ...f, paso: p.id, responsable: f.responsable || p.resp, semaforo, restante };
    });
    return { ...a, numero: numeroAlta(a.id), pasos,
             servicio_aviso_registrado: !!db.prepare("SELECT 1 FROM alta_servicio_avisado WHERE alta_id=?").get(id),
             pendientes: pasos.filter(p => p.estado === "pendiente").length,
             a_medio: pasos.filter(p => p.estado === "pendiente" && p.nota).length,
             historial: db.prepare("SELECT * FROM alta_historial WHERE alta_id=? ORDER BY ts DESC, id DESC").all(id),
             avisos: db.prepare("SELECT * FROM alta_avisos WHERE alta_id=? ORDER BY ts DESC, id DESC").all(id)
               .map(v => ({ ...v, reenviable: reenviable(v) })) };
  }

  function enTransaccion(fn) {
    db.exec("BEGIN");
    try { const r = fn(); db.exec("COMMIT"); return r; }
    catch (e) { db.exec("ROLLBACK"); throw e; }
  }

  rutas["GET /api/altas"] = () => {
    acceso();
    return {
      altas: db.prepare("SELECT id FROM altas ORDER BY cerrada_en IS NOT NULL, id DESC LIMIT 200").all().map(r => leerAlta(r.id)),
      pasos: PASOS,
      // Las pestañas anteriores leen este campo al dibujar y confirmar el cierre.
      // Se conserva el contrato de lectura; finalizar no genera avisos.
      aviso_final: [...AREAS_SERVICIO, ...USUARIOS_SERVICIO],
      areas: db.prepare("SELECT valor FROM listas WHERE tipo='area' ORDER BY orden, id").all().map(r => r.valor),
      usuarios: db.prepare("SELECT nombre, area FROM usuarios WHERE activo=1 ORDER BY area, nombre").all(),
      manda: mandaDeVerdad(), es_admin: quien()?.rol === "admin",
    };
  };

  // Cuántos contactos de verdad tendría el aviso, para mostrarlo en la ventana.
  rutas["POST /api/altas/alcance"] = (b) => {
    acceso();
    const fijo = String(b.paso) === "12";
    const areas = fijo ? AREAS_SERVICIO : (Array.isArray(b.areas) ? b.areas : []).map(String);
    const usuarios = fijo ? USUARIOS_SERVICIO : (Array.isArray(b.usuarios) ? b.usuarios : []).map(String);
    const { numeros, faltantes, invalidos } = contactos(areas, usuarios);
    return { contactos: numeros.length, faltantes, invalidos };
  };

  rutas["POST /api/altas"] = (b) => {
    acceso();
    const cliente = String(b.cliente || "").trim();
    if (!cliente) throw new Error("Falta el nombre del cliente");
    if (cliente.length > 160) throw new Error("El nombre es demasiado largo");
    const abonado = String(b.abonado || "").trim() || null;
    return enTransaccion(() => {
      const r = db.prepare("INSERT INTO altas (cliente, abonado, creada_en, creada_por) VALUES (?,?,?,?)")
        .run(cliente, abonado, Date.now(), yo());
      const id = Number(r.lastInsertRowid);
      historia(id, null, `Alta creada — ${cliente}${abonado ? " · abonado " + abonado : ""}`);
      return leerAlta(id);
    });
  };

  // Marcar un paso: completado o no_aplica.
  rutas["POST /api/altas/paso"] = (b) => {
    acceso();
    const id = Number(b.alta), p = PASO[String(b.paso)];
    if (!p) throw new Error("Paso inexistente");
    const estado = String(b.estado);
    if (!["completado", "no_aplica"].includes(estado)) throw new Error("Estado inválido");
    const nota = String(b.nota || "").trim();
    if (nota.length > LARGO_NOTA) throw new Error(`La observación supera los ${LARGO_NOTA} caracteres`);
    if (estado === "no_aplica" && !p.na) throw new Error(`El paso ${p.id} no puede ser NO APLICA`);
    if (estado === "no_aplica" && !nota) throw new Error("Para NO APLICA hay que escribir el motivo en la observación");

    let envio = null;
    const salida = enTransaccion(() => {
      const a = db.prepare("SELECT * FROM altas WHERE id=?").get(id);
      if (!a) throw new Error("No existe esa Alta");
      if (a.cerrada_en) throw new Error("El Alta ya está finalizada");
      const fila = db.prepare("SELECT * FROM alta_pasos WHERE alta_id=? AND paso=?").get(id, p.id);
      // Doble clic o reintento: si ya está resuelto, no se hace nada de nuevo.
      if (fila && fila.estado !== "pendiente") throw new Error("Ese paso ya estaba resuelto. Recargá la pantalla");

      if (p.id === "1" && estado === "completado") {
        const abonado = String(b.abonado || a.abonado || "").trim();
        if (!abonado) throw new Error("Para completar el paso 1 hay que cargar el N.° de abonado");
        db.prepare("UPDATE altas SET abonado=? WHERE id=?").run(abonado, id);
      }
      const ahora = Date.now();
      db.prepare(`INSERT INTO alta_pasos (alta_id, paso, estado, nota, por, ts) VALUES (?,?,?,?,?,?)
        ON CONFLICT(alta_id, paso) DO UPDATE SET estado=excluded.estado, nota=excluded.nota, por=excluded.por, ts=excluded.ts`)
        .run(id, p.id, estado, nota || null, yo(), ahora);
      historia(id, p.id, `${p.id} · ${p.item} → ${estado === "completado" ? "COMPLETADO" : "NO APLICA"}${nota ? " — " + nota : ""}`);

      // El aviso y el plazo: solo con COMPLETADO, y en el chequeo doble recién
      // cuando las dos áreas confirmaron.
      if (estado === "completado" && p.avisa) {
        const grupoListo = !p.grupo || p.grupo.every(g =>
          g === p.id || db.prepare("SELECT estado FROM alta_pasos WHERE alta_id=? AND paso=?").get(id, g)?.estado === "completado");
        if (grupoListo) {
          if (p.id === "12") {
            const marca = db.prepare("INSERT OR IGNORE INTO alta_servicio_avisado (alta_id, origen) VALUES (?, 'paso12')").run(id);
            if (!marca.changes) return leerAlta(id);
          }
          const areas = p.aviso_fijo ? AREAS_SERVICIO
            : (Array.isArray(b.areas) && b.areas.length ? b.areas : p.avisa).map(String);
          const usuarios = p.aviso_fijo ? USUARIOS_SERVICIO : (Array.isArray(b.usuarios) ? b.usuarios : []).map(String);
          const t = PASO[p.tarea];
          const sigue = t && db.prepare("SELECT estado FROM alta_pasos WHERE alta_id=? AND paso=?").get(id, t.id);
          let lineaPlazo = "";
          // El plazo es de la tarea que sigue, y solo si todavía está pendiente.
          // Por ahora el plazo es optativo (Gastón, 21/10): sin horas, solo queda
          // quién la tiene que hacer y se ve cuánto tarda cada etapa.
          if (t && (!sigue || sigue.estado === "pendiente")) {
            // Con los plazos apagados, unas horas que manden (una pantalla vieja) no cuentan.
            const horas = !plazosActivos() || b.plazo_horas == null || b.plazo_horas === "" ? null : Number(b.plazo_horas);
            if (horas !== null && !(horas > 0 && horas <= 24 * 60)) throw new Error("El plazo va en horas, entre 1 y 1440");
            // Cambiar el área en la ventana cambia también quién la tiene que hacer.
            // Si no viene, el de la tabla, mientras siga entre las áreas elegidas.
            const responsable = String(b.responsable || (areas.includes(t.resp) ? t.resp : areas[0]) || t.resp);
            db.prepare(`INSERT INTO alta_pasos (alta_id, paso, responsable, plazo_desde, vence_en) VALUES (?,?,?,?,?)
              ON CONFLICT(alta_id, paso) DO UPDATE SET responsable=excluded.responsable, plazo_desde=excluded.plazo_desde,
                vence_en=excluded.vence_en, av_por_vencer=0, av_vencido=0`)
              .run(id, t.id, responsable, horas ? ahora : null, horas ? ahora + horas * 3600000 : null);
            lineaPlazo = horas ? `\n⏱ ${responsable} tiene ${horas} h para: ${t.id} · ${t.item}`
                               : `\n➡ Sigue ${responsable}: ${t.id} · ${t.item}`;
            historia(id, t.id, horas ? `Plazo de ${horas} h para ${responsable}` : `Lo sigue ${responsable}`);
          }
          envio = avisar(id, p.id, "paso", areas,
            `✅ ${numeroAlta(id)} · ${a.cliente}\nPaso ${p.id} · ${p.item} — completado por ${yo() || "sin usuario"}`
            + (nota ? `\n📝 ${nota}` : "") + lineaPlazo, usuarios);
        }
      }
      return leerAlta(id);
    });
    if (envio) envio();
    return salida;
  };

  // Guardar la observación de un paso sin confirmarlo. El paso sigue pendiente
  // (se ve en rojo: algo a medio hacer) y no se avisa a nadie.
  rutas["POST /api/altas/nota"] = (b) => {
    acceso();
    const id = Number(b.alta), p = PASO[String(b.paso)];
    if (!p) throw new Error("Paso inexistente");
    const nota = String(b.nota || "").trim();
    if (nota.length > LARGO_NOTA) throw new Error(`La observación supera los ${LARGO_NOTA} caracteres`);
    return enTransaccion(() => {
      const a = db.prepare("SELECT * FROM altas WHERE id=?").get(id);
      if (!a) throw new Error("No existe esa Alta");
      if (a.cerrada_en) throw new Error("El Alta ya está finalizada");
      const f = db.prepare("SELECT * FROM alta_pasos WHERE alta_id=? AND paso=?").get(id, p.id);
      if (f && f.estado !== "pendiente") throw new Error("Ese paso ya estaba resuelto. Recargá la pantalla");
      if ((f?.nota || "") === nota) return leerAlta(id);
      db.prepare(`INSERT INTO alta_pasos (alta_id, paso, nota) VALUES (?,?,?)
        ON CONFLICT(alta_id, paso) DO UPDATE SET nota=excluded.nota`).run(id, p.id, nota || null);
      historia(id, p.id, nota ? `${p.id} · observación guardada (sin confirmar) — ${nota}` : `${p.id} · observación borrada`);
      return leerAlta(id);
    });
  };

  // Reenviar a mano un aviso que falló. El mismo texto, solo a quien le falta, y
  // con una tanda nueva de reintentos. No toca el paso ni sus tiempos.
  rutas["POST /api/altas/reenviar"] = async (b) => {
    acceso();
    const v = db.prepare("SELECT * FROM alta_avisos WHERE id=?").get(Number(b.aviso));
    if (!v) throw new Error("No existe ese aviso");
    if (!reenviable(v)) throw new Error(DE_PLAZO.includes(v.tipo) && !plazosActivos()
      ? "Los plazos de Altas están apagados: los avisos de vencimiento no se reenvían"
      : "Ese aviso no se puede reenviar (ya salió o se está reintentando solo)");
    db.prepare("UPDATE alta_avisos SET intentos=0 WHERE id=?").run(v.id);
    historia(v.alta_id, v.paso, `Aviso reenviado a mano (estaba «${v.estado}»)`);
    await mandar(v.id, v.texto);
    return leerAlta(v.alta_id);
  };

  // Corregir: solo el administrador. Queda el estado anterior en el historial y
  // no se vuelve a mandar nada.
  rutas["POST /api/altas/desmarcar"] = (b) => {
    acceso();
    const id = Number(b.alta), p = PASO[String(b.paso)];
    if (!p) throw new Error("Paso inexistente");
    return enTransaccion(() => {
      const a = db.prepare("SELECT * FROM altas WHERE id=?").get(id);
      if (!a) throw new Error("No existe esa Alta");
      if (a.cerrada_en) throw new Error("El Alta ya está finalizada");
      const f = db.prepare("SELECT * FROM alta_pasos WHERE alta_id=? AND paso=?").get(id, p.id);
      if (!f || f.estado === "pendiente") throw new Error("Ese paso está pendiente: no hay nada que desmarcar");
      db.prepare("UPDATE alta_pasos SET estado='pendiente', nota=NULL, por=NULL, ts=NULL WHERE alta_id=? AND paso=?").run(id, p.id);
      historia(id, p.id, `Desmarcado por el administrador. Estaba ${f.estado === "completado" ? "COMPLETADO" : "NO APLICA"}`
        + ` por ${f.por || "?"} el ${new Date(f.ts).toLocaleString("es-AR")}${f.nota ? " — " + f.nota : ""}`);
      return leerAlta(id);
    });
  };
  SOLO_ADMIN.add("POST /api/altas/desmarcar");

  rutas["POST /api/altas/finalizar"] = (b) => {
    acceso();
    const id = Number(b.alta);
    return enTransaccion(() => {
      const a = leerAlta(id);
      if (a.cerrada_en) throw new Error("El Alta ya estaba finalizada");
      const faltan = a.pasos.filter(p => p.estado === "pendiente");
      if (faltan.length) throw new Error(`No se puede finalizar: faltan ${faltan.map(p => p.paso).join(", ")}`);
      db.prepare("UPDATE altas SET cerrada_en=?, cerrada_por=? WHERE id=?").run(Date.now(), yo(), id);
      historia(id, null, "Alta finalizada");
      return leerAlta(id);
    });
  };

  // Plazos: preaviso y vencido, igual que los pedidos.
  function motor() {
    if (!plazosActivos()) return;
    const ahora = Date.now(), pct = Number(cfg("pct_preaviso") || 75) / 100;
    const filas = db.prepare(`SELECT p.*, a.cliente FROM alta_pasos p JOIN altas a ON a.id=p.alta_id
      WHERE p.estado='pendiente' AND p.vence_en IS NOT NULL AND a.cerrada_en IS NULL`).all();
    for (const f of filas) {
      const t = PASO[f.paso];
      if (!t) continue;
      if (ahora > f.vence_en && !f.av_vencido) {
        db.prepare("UPDATE alta_pasos SET av_vencido=1, av_por_vencer=1 WHERE alta_id=? AND paso=?").run(f.alta_id, f.paso);
        avisar(f.alta_id, f.paso, "vencido", [f.responsable || t.resp, ATC()],
          `🔴 Vencido — ${numeroAlta(f.alta_id)} · ${f.cliente}\n${t.id} · ${t.item} (${f.responsable || t.resp})`)();
      } else if (ahora <= f.vence_en && !f.av_por_vencer
                 && f.vence_en - ahora < (f.vence_en - f.plazo_desde) * (1 - pct)) {
        db.prepare("UPDATE alta_pasos SET av_por_vencer=1 WHERE alta_id=? AND paso=?").run(f.alta_id, f.paso);
        avisar(f.alta_id, f.paso, "por_vencer", [f.responsable || t.resp],
          `🟡 Por vencer — ${numeroAlta(f.alta_id)} · ${f.cliente}\n${t.id} · ${t.item} (${f.responsable || t.resp})`)();
      }
    }
  }
  setInterval(() => {
    try { motor(); } catch (e) { console.error("altas:", e.message); }
    try { reintentar(); } catch (e) { console.error("altas, reintentos:", e.message); }
  }, 60000);
};
