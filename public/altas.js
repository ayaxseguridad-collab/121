// Solapa «Altas» — checklist de altas. El servidor está en altas.js.
// Usa api() y esc() del script principal.

let altasDatos = null, altaSel = null, altaPaso = null, altaEstado = null;
// Qué listas están abiertas; se recuerda al volver a pintar.
const altasAbiertas = { curso: true, finalizadas: false };
// Lo escrito en las observaciones y todavía no guardado, por «alta:paso». Sobrevive
// a los repintados, así guardar una nota no borra lo que se escribía en otra.
const altasBorradores = {};

// El Alta del detalle que está en pantalla. Toda acción usa ESTE número y no
// altaSel, que cambia apenas se hace clic en otra Alta, antes de que llegue.
function altaVisible(el) {
  const c = (el && el.closest("[data-alta-detalle]")) || document.querySelector("[data-alta-detalle]");
  return c ? Number(c.dataset.altaDetalle) : null;
}

// Guarda como borrador lo que la persona cambió en pantalla. Cada caja recuerda
// en data-base la nota que el servidor tenía cuando se pintó: solo lo que difiere
// de ESO es una edición local. Así una nota cambiada desde otra ventana no se
// confunde con un borrador. Se puede llamar en cualquier momento.
function juntarBorradores() {
  const id = altaVisible();
  if (id == null) return;
  for (const t of document.querySelectorAll(`[data-alta-detalle="${id}"] [data-nota]`)) {
    const k = `${id}:${t.dataset.nota}`;
    const base = t.dataset.base ?? "";
    if (t.value.trim() !== base) altasBorradores[k] = { texto: t.value, base };
    else delete altasBorradores[k];
  }
}

// Un lapso en palabras cortas: 45m, 3h 10m, 2d 4h.
const lapso = (ms) => {
  const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60;
  return h >= 24 ? `${Math.floor(h / 24)}d ${h % 24}h` : h ? `${h}h ${m}m` : `${m}m`;
};

const fechaHora = (ts) => ts ? new Date(ts).toLocaleString("es-AR",
  { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }) : "";

// Se llama al arrancar, después de ingresar: si no tiene acceso, la solapa no aparece.
async function altasVerAcceso() {
  try { altasDatos = await api("/api/altas"); document.getElementById("tabAltas").classList.remove("oculta"); }
  catch { document.getElementById("tabAltas").classList.add("oculta"); }
  const id = Number(new URLSearchParams(location.search).get("alta"));
  if (id) altaSel = id;
}

let turnoPintar = 0;
async function pintarAltas() {
  const caja = document.getElementById("altas");
  const turno = ++turnoPintar;
  let nuevos;
  try { nuevos = await api("/api/altas"); }
  catch (e) {
    if (turno !== turnoPintar) return;
    // Sin conexión: lo escrito se guarda antes de sacar el formulario y vuelve
    // cuando se pueda leer de nuevo.
    juntarBorradores();
    caja.innerHTML = `<div class="vacio">${esc(e.message)}</div>`;
    return;
  }
  // Una respuesta que llega tarde no pisa a una más nueva.
  if (turno !== turnoPintar) return;
  // Justo antes de repintar: entra también lo que se escribió mientras se esperaba.
  juntarBorradores();
  altasDatos = nuevos;
  // Un borrador que ya es lo guardado (un guardado propio que llegó) deja de serlo.
  for (const x of nuevos.altas) for (const p of x.pasos) {
    const k = `${x.id}:${p.paso}`, b = altasBorradores[k];
    if (b && (p.estado !== "pendiente" || b.texto.trim() === (p.nota || ""))) delete altasBorradores[k];
  }
  const d = altasDatos;
  if (altaSel && !d.altas.some(a => a.id === altaSel)) altaSel = null;
  const a = d.altas.find(x => x.id === altaSel);

  caja.innerHTML = `
    ${d.manda ? "" : `<div class="aviso" style="background:#FBBF2422; border:1px solid #FBBF2466">
      Ahora no sale ningún WhatsApp: el CRM no está en modo real o esta no es la copia de la nube.</div>`}
    <div style="display:grid; grid-template-columns:minmax(220px,300px) minmax(0,1fr); gap:16px" class="altas-grilla">
      <div>
        <form class="conf" id="formAltaNueva" style="margin-bottom:12px">
          <h3>Nueva Alta</h3>
          <div class="campo"><label>Cliente</label><input name="cliente" required maxlength="160" placeholder="Nombre del cliente"></div>
          <div class="campo"><label>N.° de abonado (si ya está)</label><input name="abonado" placeholder="se carga en el paso 1"></div>
          <button class="accion primario" type="submit">Crear Alta</button>
        </form>
        ${listaAltas("curso", "EN CURSO", d.altas.filter(x => !x.cerrada_en))}
        ${listaAltas("finalizadas", "FINALIZADAS", d.altas.filter(x => x.cerrada_en))}
      </div>
      <div style="min-width:0">${a ? `<div data-alta-detalle="${a.id}">${detalleAlta(a, d)}</div>` : `<div class="vacio">Elegí un Alta de la lista o creá una nueva.</div>`}</div>
    </div>`;
}

function listaAltas(clave, titulo, altas) {
  return `<details class="conf" data-lista-altas="${clave}" ${altasAbiertas[clave] ? "open" : ""} style="margin-bottom:12px; padding:10px 12px">
    <summary style="cursor:pointer; font-weight:600">${titulo} (${altas.length})</summary>
    <div style="max-height:50vh; overflow-y:auto; margin-top:8px">
    ${altas.length ? altas.map(x => `
      <button class="btnf ${x.id === altaSel ? "sel" : ""}" data-alta="${x.id}"
        style="display:block; width:100%; text-align:left; height:auto; padding:10px 12px; margin-bottom:6px">
        <b>${esc(x.numero)}</b> · ${esc(x.cliente)}<br>
        <span style="font-size:12px">${x.cerrada_en ? "🏁 Finalizada"
          : `${x.pendientes} pendiente${x.pendientes === 1 ? "" : "s"}${x.pasos.some(p => p.semaforo === "vencido") ? " · 🔴 vencido" : ""}`}</span>
        ${x.a_medio && !x.cerrada_en ? `<br><b style="font-size:12px; color:var(--rojo)">⚠ ${x.a_medio} a medio hacer</b>` : ""}
      </button>`).join("") : `<div class="vacio" style="padding:12px">Nada por acá.</div>`}
    </div></details>`;
}

// Cuánto tardó cada paso: desde el movimiento anterior (otro paso resuelto o la creación del Alta).
function tardanzas(a) {
  const marcas = [a.creada_en, ...a.pasos.filter(p => p.estado !== "pendiente" && p.ts).map(p => p.ts)].sort((x, y) => x - y);
  const r = {};
  for (const p of a.pasos) if (p.estado !== "pendiente" && p.ts) {
    const antes = marcas.filter(t => t < p.ts).pop() ?? a.creada_en;
    r[p.paso] = p.ts - antes;
  }
  return r;
}

function detalleAlta(a, d) {
  const abierta = !a.cerrada_en;
  const sem = { vencido: "🔴", por_vencer: "🟡", en_plazo: "🟢" };
  const tardo = tardanzas(a);
  const fila = (p) => {
    const resuelto = p.estado !== "pendiente";
    const bor = altasBorradores[`${a.id}:${p.paso}`];
    const borrador = bor?.texto;
    // Mientras se escribía, otra persona cambió la observación guardada.
    const pisada = bor && bor.base !== (p.nota || "");
    // Con observación guardada pero sin confirmar: rojo, algo quedó a medio hacer.
    const aMedio = !resuelto && !!p.nota;
    const estado = p.estado === "completado" ? `<b style="color:var(--verde)">COMPLETADO</b>`
      : p.estado === "no_aplica" ? `<b style="color:var(--suave)">NO APLICA</b>`
      : aMedio ? `<b style="color:var(--rojo)">⚠ PENDIENTE</b><div style="font-size:11.5px; color:var(--rojo)">a medio hacer</div>`
        + (p.semaforo ? `<div style="font-size:11.5px">${sem[p.semaforo]} ${esc(tiempo(p.restante))}</div>` : "")
      : p.semaforo ? `${sem[p.semaforo]} ${esc(tiempo(p.restante))}` : `<span style="color:var(--tenue)">Pendiente</span>`;
    return `<tr ${aMedio ? `style="background:#EF444418; box-shadow:inset 3px 0 0 var(--rojo)"` : ""}>
      <td class="num">${esc(p.paso)}</td>
      <td>${esc(p.item)}${p.avisa ? ` <span title="Avisa a ${esc([...p.avisa, ...(p.usuarios_aviso || [])].join(", "))}">🔔</span>` : ""}
        ${p.aviso_fijo ? `<div style="font-size:11.5px; color:var(--suave)">Avisa a: ${esc([...p.avisa, ...p.usuarios_aviso].join(", "))}</div>` : ""}</td>
      <td>${esc(p.responsable)}</td>
      <td>${estado}${resuelto ? `<div style="font-size:11.5px; color:var(--tenue)">${esc(p.por || "")} · ${fechaHora(p.ts)}</div>`
        + (tardo[p.paso] != null ? `<div style="font-size:11.5px; color:var(--suave)" title="Desde el paso anterior">⏱ tardó ${lapso(tardo[p.paso])}</div>` : "") : ""}</td>
      <td style="min-width:200px">${resuelto
        ? `<div style="font-size:12.5px; white-space:pre-wrap">${esc(p.nota || "")}</div>`
        : `<textarea data-nota="${esc(p.paso)}" data-base="${esc(p.nota || "")}" rows="2" maxlength="2000" placeholder="Observación" ${abierta ? "" : "disabled"}
             style="width:100%">${esc(borrador ?? p.nota ?? "")}</textarea>
           ${pisada ? `<div style="font-size:11.5px; color:var(--amarillo); white-space:pre-wrap">Otra persona la cambió mientras escribías. Guardada ahora: «${esc(p.nota || "vacía")}»</div>` : ""}
           ${abierta ? `<button class="btnf ${borrador == null ? "oculta" : ""}" data-guardar-nota="${esc(p.paso)}" style="margin-top:4px">Guardar observación</button>` : ""}`}</td>
      <td style="white-space:nowrap">${!abierta ? "" : resuelto
        ? (d.es_admin ? `<button class="btnf" data-desmarcar="${esc(p.paso)}">Desmarcar</button>` : "")
        : `<button class="accion primario" data-marcar="${esc(p.paso)}" data-estado="completado">COMPLETADO</button>
           ${p.na ? `<button class="accion" data-marcar="${esc(p.paso)}" data-estado="no_aplica">NO APLICA</button>` : ""}`}</td>
    </tr>`;
  };
  return `
    <div class="conf">
      <div style="display:flex; justify-content:space-between; align-items:flex-start; gap:12px; flex-wrap:wrap">
        <div>
          <h3 style="margin-bottom:4px">${esc(a.numero)} · ${esc(a.cliente)}</h3>
          <div style="font-size:12.5px; color:var(--suave)">Abonado ${esc(a.abonado || "sin asignar")}
            · creada por ${esc(a.creada_por || "?")} el ${fechaHora(a.creada_en)}
            ${a.cerrada_en ? ` · 🏁 finalizada por ${esc(a.cerrada_por || "?")} el ${fechaHora(a.cerrada_en)} · tardó ${lapso(a.cerrada_en - a.creada_en)} en total`
              : ` · abierta hace ${lapso(Date.now() - a.creada_en)}`}</div>
        </div>
        ${abierta ? `<button class="accion primario" id="btnFinalizarAlta" ${a.pendientes ? "disabled" : ""}
            title="${a.pendientes ? "Faltan " + a.pendientes + " pasos" : "Cierra el Alta y registra el cierre en el historial"}">
            Finalizar Alta${a.pendientes ? ` (faltan ${a.pendientes})` : ""}</button>` : ""}
      </div>
      <div class="tabla-scroll" style="margin-top:12px; overflow-x:auto"><table>
        <thead><tr><th>#</th><th>Ítem</th><th>Responsable</th><th>Estado</th><th>Observación</th><th></th></tr></thead>
        <tbody>${a.pasos.map(fila).join("")}</tbody>
      </table></div>
    </div>
    <details class="conf" style="margin-top:12px"><summary style="cursor:pointer">Avisos (${a.avisos.length})</summary>
      ${a.avisos.map(v => `<div style="border-top:1px solid var(--borde); padding:8px 0; font-size:12.5px">
        <b>${v.estado === "mandado" ? "Enviado a WhatsApp (recepción sin confirmar)" : esc(v.estado)}</b> · ${fechaHora(v.ts)} · iba a ${esc(v.destinos)}
        <div style="white-space:pre-wrap; color:var(--suave)">${esc(v.texto)}</div>
        ${v.detalle ? `<div style="color:var(--tenue)">${esc(v.detalle)}</div>` : ""}
        ${v.reenviable ? `<button class="btnf" data-reenviar="${v.id}" style="margin-top:4px">Reenviar</button>` : ""}</div>`).join("") || "<div class='vacio'>Sin avisos</div>"}
    </details>
    <details class="conf" style="margin-top:12px"><summary style="cursor:pointer">Historial (${a.historial.length})</summary>
      ${a.historial.map(h => `<div style="border-top:1px solid var(--borde); padding:6px 0; font-size:12.5px">
        ${fechaHora(h.ts)} · <b>${esc(h.usuario || "?")}</b> · ${esc(h.texto)}</div>`).join("")}
    </details>`;
}

// ── La ventana de confirmación ──
let altaPasoAlta = null;   // de qué Alta es la ventana abierta
function abrirPaso(altaId, paso, estado) {
  const a = altasDatos.altas.find(x => x.id === altaId);
  if (!a) return;
  const p = a.pasos.find(x => x.paso === paso);
  altaPaso = p; altaEstado = estado; altaPasoAlta = altaId;
  const nota = document.querySelector(`[data-alta-detalle="${altaId}"] [data-nota="${CSS.escape(paso)}"]`)?.value || "";
  const g = (id) => document.getElementById(id);
  g("apTitulo").textContent = estado === "completado"
    ? "¿Está seguro de que este ítem está completo?" : "¿Marcar este ítem como NO APLICA?";
  g("apItem").textContent = `${p.paso} · ${p.item}`;
  g("apNota").value = nota;
  g("apNotaRot").textContent = estado === "no_aplica" ? "Motivo (obligatorio)" : "Observación";
  g("apError").textContent = "";
  g("apCampoAbonado").classList.toggle("oculta", !(paso === "1" && estado === "completado"));
  g("apAbonado").value = a.abonado || "";

  // El aviso: solo con COMPLETADO, y en el chequeo doble cuando ya está la otra mitad.
  const grupoListo = !p.grupo || p.grupo.every(x => x === p.paso || a.pasos.find(y => y.paso === x)?.estado === "completado");
  const avisa = estado === "completado" && p.avisa && grupoListo;
  g("apAviso").classList.toggle("oculta", !avisa);
  if (avisa) {
    const areas = p.aviso_fijo ? p.avisa : altasDatos.areas;
    const usuarios = p.aviso_fijo ? p.usuarios_aviso.map(nombre => ({ nombre })) : altasDatos.usuarios;
    g("apAreas").innerHTML = areas.map(ar => `<label style="display:inline-flex; gap:5px; margin:0 12px 6px 0; text-transform:none; letter-spacing:0; font-size:13px">
      <input type="checkbox" style="width:auto; flex:none" value="${esc(ar)}" ${p.avisa.includes(ar) ? "checked" : ""} ${p.aviso_fijo ? "disabled" : ""}> ${esc(ar)}</label>`).join("");
    g("apUsuarios").innerHTML = usuarios.map(u => `<label style="display:flex; gap:6px; text-transform:none; letter-spacing:0; font-size:13px">
      <input type="checkbox" style="width:auto; flex:none" value="${esc(u.nombre)}" ${p.aviso_fijo ? "checked disabled" : ""}> ${esc(u.nombre)} <span style="color:var(--tenue)">${esc(u.area || "")}</span></label>`).join("");
    const personas = g("apUsuarios").closest("details");
    personas.open = !!p.aviso_fijo;
    personas.querySelector("summary").textContent = p.aviso_fijo ? "Persona destinataria" : "Sumar personas";
    const t = p.tarea && a.pasos.find(x => x.paso === p.tarea);
    const conPlazo = t && t.estado === "pendiente";
    g("apCampoPlazo").classList.toggle("oculta", !conPlazo);
    if (conPlazo) g("apTarea").textContent = `${t.paso} · ${t.item}`;
    g("apSinPlazo").textContent = p.aviso_fijo
      ? a.servicio_aviso_registrado
        ? "El aviso de este servicio ya fue registrado o corresponde a una confirmación anterior. No se genera otro; los envíos pendientes se siguen desde Avisos."
        : "Se avisa «Servicio operativo verificado» al confirmar. El Alta sigue abierta hasta completar los demás pasos y finalizarla."
      : t && !conPlazo ? `La tarea que sigue (${t.paso}) ya está resuelta: no se abre plazo.` : "";
    pintarResponsable(); actualizarAlcance();
  }
  g("dlgAltaPaso").showModal();
}

function elegidos(id) {
  return [...document.querySelectorAll(`#${id} input:checked`)].map(x => x.value);
}
function pintarResponsable() {
  const sel = document.getElementById("apResponsable");
  const areas = elegidos("apAreas");
  const t = altaPaso?.tarea && altasDatos.pasos.find(x => x.id === altaPaso.tarea);
  const lista = areas.length ? areas : (t ? [t.resp] : []);
  const antes = sel.value;
  // Por defecto, el responsable de la tabla si está entre las áreas elegidas.
  const pref = t && lista.includes(t.resp) ? t.resp : lista[0];
  sel.innerHTML = lista.map(x => `<option ${x === (lista.includes(antes) ? antes : pref) ? "selected" : ""}>${esc(x)}</option>`).join("");
}
let turnoAlcance = 0;
async function actualizarAlcance() {
  const turno = ++turnoAlcance;
  document.getElementById("apAlcance").textContent = "Comprobando contactos…";
  const r = await api("/api/altas/alcance", { paso: altaPaso?.paso, areas: elegidos("apAreas"), usuarios: elegidos("apUsuarios") }).catch(() => null);
  if (turno !== turnoAlcance) return;
  if (!r) { document.getElementById("apAlcance").textContent = "No se pudieron comprobar los contactos. Revisá los resultados del aviso después de confirmar."; return; }
  document.getElementById("apAlcance").innerHTML = r.contactos
    ? `Se intentará enviar a <b>${r.contactos}</b> contacto${r.contactos === 1 ? "" : "s"}, sin repetir.`
    : `<b>No hay teléfonos válidos</b> en Personas para los destinatarios.`;
  if (r.faltantes?.length) document.getElementById("apAlcance").innerHTML += `<br><b>Sin teléfono válido:</b> ${esc(r.faltantes.join(", "))}. Revisar en Personas.`;
  if (r.invalidos?.length) document.getElementById("apAlcance").innerHTML += `<br><b>Contactos inválidos:</b> ${esc(r.invalidos.join(", "))}.`;
}

async function confirmarPaso() {
  const g = (id) => document.getElementById(id);
  if (g("apConfirmar").disabled) return;
  const cuerpo = { alta: altaPasoAlta, paso: altaPaso.paso, estado: altaEstado, nota: g("apNota").value };
  if (!g("apCampoAbonado").classList.contains("oculta")) cuerpo.abonado = g("apAbonado").value;
  if (!g("apAviso").classList.contains("oculta")) {
    cuerpo.areas = elegidos("apAreas");
    cuerpo.usuarios = elegidos("apUsuarios");
    if (!cuerpo.areas.length && !cuerpo.usuarios.length) { g("apError").textContent = "Elegí al menos un área o una persona"; return; }
    // Por ahora sin plazo en horas: solo quién sigue.
    if (!g("apCampoPlazo").classList.contains("oculta")) cuerpo.responsable = g("apResponsable").value;
  }
  const b = g("apConfirmar");
  b.disabled = true;
  try {
    await api("/api/altas/paso", cuerpo);
    g("dlgAltaPaso").close();
    await pintarAltas();
  } catch (e) { g("apError").textContent = e.message; }
  finally { b.disabled = false; }
}

document.addEventListener("click", async (e) => {
  const sel = e.target.closest("[data-alta]");
  if (sel) {
    altaSel = Number(sel.dataset.alta);
    const u = new URL(location.href); u.searchParams.set("tab", "altas"); u.searchParams.set("alta", altaSel);
    history.replaceState(null, "", u);
    // Hasta que llegue la nueva, la anterior queda a la vista pero sin poder tocarse.
    const viejo = document.querySelector("[data-alta-detalle]");
    if (viejo && Number(viejo.dataset.altaDetalle) !== altaSel) { viejo.inert = true; viejo.style.opacity = ".45"; }
    return pintarAltas();
  }
  const m = e.target.closest("[data-marcar]");
  if (m) return abrirPaso(altaVisible(m), m.dataset.marcar, m.dataset.estado);
  const gn = e.target.closest("[data-guardar-nota]");
  if (gn) {
    const alta = altaVisible(gn), paso = gn.dataset.guardarNota;
    const caja = document.querySelector(`[data-alta-detalle="${alta}"] [data-nota="${CSS.escape(paso)}"]`);
    const nota = caja?.value || "";
    gn.disabled = true;
    try { await api("/api/altas/nota", { alta, paso, nota }); } catch (er) { alert(er.message); gn.disabled = false; return; }
    // Lo guardado pasa a ser la base de la caja: lo que se escriba después es borrador
    // propio, no un cambio de otra persona.
    // (Se busca de nuevo: si se repintó mientras se guardaba, la caja es otra.)
    const ahora = document.querySelector(`[data-alta-detalle="${alta}"] [data-nota="${CSS.escape(paso)}"]`);
    if (ahora) ahora.dataset.base = nota.trim();
    const bor = altasBorradores[`${alta}:${paso}`];
    if (bor) bor.base = nota.trim();
    return pintarAltas();
  }
  const rv = e.target.closest("[data-reenviar]");
  if (rv) {
    if (!confirm("¿Volver a mandar este aviso? Sale el mismo mensaje, solo a quien todavía no le llegó.")) return;
    try { await api("/api/altas/reenviar", { aviso: Number(rv.dataset.reenviar) }); } catch (er) { alert(er.message); }
    return pintarAltas();
  }
  const dm = e.target.closest("[data-desmarcar]");
  if (dm) {
    if (!confirm(`¿Desmarcar el paso ${dm.dataset.desmarcar}? Vuelve a pendiente y queda anotado en el historial. No se manda ningún aviso.`)) return;
    try { await api("/api/altas/desmarcar", { alta: altaVisible(dm), paso: dm.dataset.desmarcar }); } catch (er) { alert(er.message); }
    return pintarAltas();
  }
  if (e.target.id === "btnFinalizarAlta") {
    const alta = altaVisible(e.target);
    if (!confirm("¿Finalizar el Alta? Se registra el cierre en el historial. El aviso de Servicio operativo verificado corresponde al paso 12 y no se repite al finalizar.")) return;
    try { await api("/api/altas/finalizar", { alta }); } catch (er) { alert(er.message); }
    return pintarAltas();
  }
  if (e.target.id === "apCancelar") document.getElementById("dlgAltaPaso").close();
  if (e.target.id === "apConfirmar") confirmarPaso();
});

// Recordar qué lista (en curso / finalizadas) quedó abierta.
document.addEventListener("toggle", (e) => {
  const l = e.target.dataset?.listaAltas;
  if (l) altasAbiertas[l] = e.target.open;
}, true);

// El botón «Guardar observación» aparece solo cuando el texto cambió.
document.addEventListener("input", (e) => {
  const paso = e.target.dataset?.nota;
  if (paso == null || !altasDatos) return;
  const alta = altaVisible(e.target);
  document.querySelector(`[data-alta-detalle="${alta}"] [data-guardar-nota="${CSS.escape(paso)}"]`)
    ?.classList.toggle("oculta", e.target.value.trim() === (e.target.dataset.base ?? ""));
});

document.addEventListener("change", (e) => {
  if (e.target.closest("#apAreas")) { pintarResponsable(); actualizarAlcance(); }
  if (e.target.closest("#apUsuarios")) actualizarAlcance();
});

document.addEventListener("submit", async (e) => {
  if (e.target.id !== "formAltaNueva") return;
  e.preventDefault();
  const f = new FormData(e.target);
  try {
    const a = await api("/api/altas", { cliente: f.get("cliente"), abonado: f.get("abonado") });
    altaSel = a.id;
    await pintarAltas();
  } catch (er) { alert(er.message); }
});
