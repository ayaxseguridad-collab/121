# CRM Atención al Cliente

Seguimiento de reclamos y pedidos de los abonados: qué está pendiente, quién lo tiene,
cuánto falta para que venza y a quién hay que avisarle.

**No reemplaza a Bykom** — ahí siguen viviendo los datos de los clientes y el detalle
técnico. Esto es la capa de seguimiento y aviso, que es donde se perdían las cosas.

## Dónde corre

En la nube, en Railway: **https://crm-production-c825.up.railway.app**, o con el ícono
**"CRM Atencion Cliente"** del Escritorio, que abre esa misma dirección.

Se actualiza solo con cada cambio que se sube a este repositorio. Anda desde cualquier
lado —la oficina, una casa, un celular— y ya no depende de que quede una máquina prendida.
Como contrapartida, ahora **sí necesita internet**: antes vivía en la red interna.

Para levantarlo en una máquina, por ejemplo para probar un cambio antes de subirlo:

    node server.js          # http://localhost:3200

Requiere Node 24 o más nuevo: usa `node:sqlite`, la base de datos que viene incluida.
La única dependencia externa es para WhatsApp (`npm install`).

## El circuito

1. Entra el pedido por WhatsApp, correo o teléfono y **Atención al Cliente lo carga**
2. Le pone la **urgencia** y lo deriva a un área
3. El área **recibe el aviso** y lo trabaja
4. El área lo **actualiza en el panel** (en curso, en espera, terminado)
5. Vuelve a Atención al Cliente para **cerrarlo o derivarlo**
6. Se cierra con **motivo y causa raíz**, y eso alimenta la estadística

### Decisiones que explican el diseño

- **Un ticket por cliente**, con ítems adentro: los reclamos de un abonado no se dispersan
  en cinco números distintos
- **Atención al Cliente es dueño del pedido** de punta a punta; el área ejecuta
- **Los avisos son de una sola vía**: nadie contesta el WhatsApp del bot, todo se informa
  en el panel
- **El tiempo en estados de espera no cuenta como demora del área**: esperar un repuesto
  no es culpa de nadie
- **Las reglas viven en el servidor**, no en la pantalla: valen aunque alguien tenga el
  panel abierto desde ayer o intente saltearlo

### Urgencias

| | Plazo | Cuándo |
|---|---|---|
| 1 | 2 horas | Cliente sin servicio, equipo sin comunicación, robo |
| 2 | Fin del día | Falla parcial: una zona, un sensor, control de acceso |
| 3 | 24 horas | Configuraciones, alta o baja de usuario |
| 4 | 48 horas | Consultas, presupuestos |
| 5 | Con fecha | Instalaciones y trabajos programados |

## Las solapas

- **Tablero** — lo abierto, con filtros por área y por situación
- **Nuevo pedido** — carga en seis campos, casi todo de listas
- **Para cerrar** — bandeja del auditor: cierra con clave o devuelve al área
- **Seguimiento** — la historia completa de cada pedido, movimiento por movimiento
- **Avisos** — WhatsApp, destinatarios por área y cuándo avisa
- **Estadística** — cumplimiento de plazos, causas raíz y reincidencias
- **Configuración** — listas y plazos, todo editable sin tocar el código

## Los avisos

Salen por **WhatsApp** (conexión propia con QR, como WhatsApp Web) y por **correo**.
Tres momentos: pedido nuevo → al área · preaviso al 75% del plazo · vencido → al área y
a Atención al Cliente. Entre las 22 y las 8 no sale nada, salvo urgencia 1.

Además, un resumen a la mañana con lo que cada área tiene abierto, agrupado en vencidos,
por vencer, en plazo y con el reloj frenado. Los frenados van aparte a propósito: un
pedido esperando un repuesto figuraba bajo "en plazo" y su renglón decía "vencido hace
5 días", y el mensaje se contradecía solo.

**Lo que está esperando cierre no genera avisos.** Cuando el área lo da por terminado sale
del tablero y queda en la bandeja del auditor: el área no puede hacer nada más con él, así
que seguir nombrándoselo es ruido. El motor usa el mismo criterio que el tablero.

## Los datos

Todo en `datos/crm.db` (SQLite), que **no está en el repositorio**. En la nube esa carpeta
es un disco aparte, que sobrevive a cada actualización: sin él, cada versión nueva empezaría
de cero. Se hacen copias automáticas al arrancar y una por día en `datos/copias/`, y se
guardan las últimas 15. Ahí también vive la sesión de WhatsApp: si se borra, hay que volver
a escanear el QR.

Corre **una sola instancia** a propósito: la base es un archivo suelto y dos copias
escribiendo encima se pisarían.

## Para empezar de cero

Borrar `datos/crm.db`. Las listas y los plazos se recrean con valores iniciales.
