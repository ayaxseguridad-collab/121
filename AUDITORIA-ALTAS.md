# Altas: avisos de los puntos 8 y 12

Cambio preparado para revisión el 31/10/2026 sobre `d65f5e1b2b6a73f5df6d0ea66759a09b7f58dfe0`, en la rama local `audit/altas-avisos-8-12`. Sin publicación, push, cambios de contactos ni modificaciones de Altas en producción. La única operación sobre producción fue ingresar, consultar Personas y Altas, y cerrar esa sesión.

La entrega inicial quedó en staging y en `cambio.patch`. El 31/10/2026 el usuario autorizó aplicar y publicar el cambio. La versión de publicación es **3.0.1**, con `package-lock.json` alineado. Para el commit se usa la identidad verificada de la cuenta de GitHub conectada, sin cambiar la configuración global de Git.

Actualización tras la reauditoría: se conserva `aviso_final` en `GET /api/altas` para las pestañas que siguen ejecutando el cliente anterior. Ese campo sólo mantiene la compatibilidad de lectura; Finalizar Alta sigue sin generar avisos. Se verificaron el renderizado y la finalización con el cliente anterior real, además del cliente actual. La validación previa a publicar pasó 25 pruebas de servidor y 10 controles de navegador, incluido el cliente anterior.

**Contacto pendiente:** la lectura de producción del 31/10 a las 11:43 ART confirma que no existe un usuario activo llamado exactamente **Gastón**, ni un nombre similar entre los usuarios activos consultados. El destinatario individual se resuelve por nombre de usuario; actualmente no tiene un teléfono al que enviar. Se solicitó ese dato al usuario; no se inventa ni se sustituye por otro contacto. AT Cliente, Monitoreo y Comercial sí tienen contactos. El faltante queda visible y no se presenta como entrega completa.

## Hallazgos y comportamiento preparado

| Caso | Antes | Cambio preparado |
| --- | --- | --- |
| Punto 8 completado o No aplica | Sin avisos | Conserva ese comportamiento, incluso si una solicitud incluye destinatarios |
| Punto 6 completado | Técnica y Comercial | Mismos destinatarios y disparador; No aplica sigue sin aviso |
| Punto 12 completado | No avisa | Registra y envía el aviso en esa confirmación |
| Destinatarios del punto 12 | Sólo figuraban en Finalizar Alta | AT Cliente, Monitoreo, Comercial y Gastón visibles en la fila y la confirmación; el servidor impone esos destinos |
| Mensaje | «Alta finalizada» al cerrar | «Paso 12 · Servicio operativo verificado — completado por…», con cliente y enlace; el Alta puede conservar pendientes |
| Finalizar Alta | Cierra y genera aviso final | Exige todos los pasos resueltos y registra el cierre en historial, sin generar otro aviso |
| Contrato `aviso_final` de la API | El cliente anterior consume esa lista al dibujar y confirmar el cierre | Conserva la lista original de cuatro destinatarios para evitar errores en pestañas anteriores, sin usarla para enviar al finalizar |
| Contacto parcialmente ausente | Podía figurar «mandado» si los demás envíos salían | Identifica a quién le falta teléfono y conserva el fallo hasta resolverlo |

La validación y el diagnóstico de contactos se comparten entre los avisos de Altas. No se modifican las reglas ni los destinatarios de los demás pasos. Se conserva la normalización argentina del transporte existente y se rechazan entradas con caracteres o longitud incompatibles con un número utilizable.

## Duplicados, reintentos y datos anteriores

- La confirmación del paso, su historial, la marca `alta_servicio_avisado` y el nuevo aviso se guardan en la misma transacción. El envío empieza después del commit.
- Una segunda confirmación se rechaza sin generar otro aviso. La pantalla también bloquea confirmaciones simultáneas.
- La marca tiene una clave única por Alta y sobrevive a desmarcar el paso, reiniciar y borrar registros de avisos. Volver a completar el paso no genera otro aviso; los fallos se gestionan desde el aviso original.
- Al arrancar, se reconocen como anteriores los pasos 12 ya completados y los avisos de verificación o finalización ya registrados. Sólo se guardan marcas: no se crean avisos ni se envían mensajes por esa migración. Un aviso de plazo del paso 12 no cuenta como verificación.
- Un Alta existente cuyo paso 12 siga pendiente sí avisa cuando alguien lo complete después del cambio. Eso es una confirmación nueva, no un envío retroactivo.
- Se conservan los registros, los teléfonos a los que ya salió, el máximo de cinco intentos y las esperas de 5, 10, 15 y 20 minutos. Los reintentos omiten los números normalizados ya enviados. Los teléfonos compartidos reciben un solo envío por aviso.
- Los contactos ausentes también tienen reintentos limitados. Después de agotarlos, «Reenviar» sigue disponible; corregir el teléfono no crea un aviso distinto.
- Los avisos anteriores ya pendientes conservan su texto y sus reintentos. Por eso un aviso final antiguo que ya estaba en cola puede terminar de enviarse; la migración no crea nuevos avisos de ese tipo.

## Verificación de contactos actuales

Consulta de lectura del 31/10/2026 a las 11:07 ART, sin mostrar ni guardar teléfonos reales en las evidencias:

| Destinatario | Resultado |
| --- | --- |
| AT Cliente | 1 teléfono con formato utilizable |
| Monitoreo | 2 teléfonos con formato utilizable |
| Comercial | 4 teléfonos con formato utilizable |
| Gastón | Sin usuario activo exacto ni nombre similar activo; sin teléfono individual resoluble |

La API devolvió tres Altas, una con el paso 12 ya completado. No se probó completando pasos reales. Los números de las áreas se comprobaron por formato y disponibilidad en la configuración; no se verificó su registro en WhatsApp ni su recepción real.

## Pruebas y evidencias

**25 pruebas de servidor aprobadas y 10 controles de navegador aprobados.** SQLite real, datos ficticios y transporte de WhatsApp simulado. El navegador ejecutó el `server.js`, la página y el JavaScript reales desde una copia temporal, con sesión de un administrador ficticio. Las solicitudes exteriores del navegador y el transporte real del servidor quedaron bloqueados.

La regresión nueva carga una copia exacta de `public/altas.js` de `d65f5e1` contra la respuesta del servidor corregido para un Alta abierta sin pendientes. El renderizado funciona; el control que quita `aviso_final` reproduce el error de `.join()`. En Chromium, ese cliente anterior dibuja y finaliza el Alta, y conserva un único aviso del paso 12. La copia anterior tiene SHA-256 `17fb04ed08e3e51673e151ea1e4a6b3f7f4dc6e0f542ac6d31bf52fc329a77b7`.

Se cubrieron ambos estados del punto 8; destinos fijos aunque se intente alterarlos desde la API; mensaje del punto 12 con pendientes; nota sin confirmación; rechazo de No aplica en el 12; doble confirmación durante el envío; cierre posterior; desmarcado, reinicio y borrado del registro; rollback de la transacción; teléfonos compartidos; Gastón ausente, inactivo, sin teléfono o inválido; área ausente; fallos parciales de WhatsApp; reintentos automáticos; agotamiento y doble reenvío manual; Altas anteriores; cola antigua; modo copia; y regresión del punto 6.

La comparación con el código base reprodujo: punto 12 antes **0 avisos / 0 envíos**, después **1 aviso / 4 envíos ficticios**; finalizar después mantuvo **1 aviso / 4 envíos**, sin sumar otro. El punto 8 conservó **0 / 0** en ambos estados y versiones.

Evidencias actualizadas en `/home/gaston/auditorias/crm/2026-10-31/altas-8-12-compatibilidad/`. Se conserva intacta la carpeta de la entrega anterior y el informe independiente del auditor.

- [Comparación antes/después](../../auditorias/crm/2026-10-31/altas-8-12/comparacion-base.json).
- [Resultados de servidor](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/pruebas-servidor.txt).
- [Resultados de Chromium](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/navegador-resultados.json).
- [Contactos de producción, sin números](../../auditorias/crm/2026-10-31/altas-8-12/contactos-produccion.json).
- [Confirmación con los cuatro destinatarios](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/02-servicio-cuatro-destinatarios.png).
- [Advertencia por falta de Gastón](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/04-falta-contacto-gaston.png).
- [Fallo de WhatsApp visible](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/06-fallo-whatsapp-visible.png).
- [Cliente anterior con Alta lista para finalizar](../../auditorias/crm/2026-10-31/altas-8-12-compatibilidad/07-cliente-anterior-listo-para-finalizar.png).

Reproducción de servidor con Node 24:

```sh
npm test
```

Reproducción de navegador con Playwright instalado fuera del proyecto:

```sh
PLAYWRIGHT_MODULE=/ruta/a/node_modules/playwright AUDIT_OUT=/tmp/crm-evidencias node tests/altas-navegador.cjs
```

## Límites y revisión antes de publicar

«Mandado» significa aceptado por el transporte; la pantalla lo presenta como **«Enviado a WhatsApp (recepción sin confirmar)»**. La columna histórica `entregados` conserva su nombre interno para compatibilidad: se usa para evitar reenvíos a números ya aceptados, no como prueba de recepción en un teléfono.

Las pruebas verifican ausencia de duplicados en doble clic, reenvío y finalización posterior. Se conserva una limitación del transporte existente: si el proceso cae después de que WhatsApp acepta un mensaje pero antes de persistir ese éxito, un reintento podría repetir ese envío. No hay una garantía de entrega exactamente una vez frente a esa interrupción ni se probó ejecutar dos servidores simultáneamente sobre la misma base.

El usuario autorizó publicar el cambio, incluido que Finalizar Alta sólo registre el cierre. Queda pendiente completar el contacto de Gastón en Personas o acordar explícitamente otro vínculo de destinatario. No se activaron plazos ni se cambiaron credenciales, contactos o modo de envío de producción.

Si después de publicar se decidiera volver a la versión anterior, revisar primero las Altas que ya emitieron el aviso en el paso 12: la versión anterior vuelve a avisar al finalizar. Revertir sólo el código puede reintroducir ese duplicado.
