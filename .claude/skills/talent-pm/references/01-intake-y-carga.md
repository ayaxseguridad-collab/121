# 01 — Intake y carga: el PM entrega QUÉ construir, con evidencia

## Table of Contents

- [La cola es la carga](#la-cola-es-la-carga)
- [Higiene de la cola ANTES de entregarla](#higiene-de-la-cola-antes-de-entregarla)
- [El paquete de intake](#el-paquete-de-intake)
- [Criterios de aceptación por encargo](#criterios-de-aceptación-por-encargo)
- [Desbloqueos del lead](#desbloqueos-del-lead)

## La cola es la carga

La cola de Linear del proyecto ES la carga que la fábrica consume. Entregarla sucia siembra
falsos arranques: canales despachados contra issues ya resueltas, prioridades que mienten,
estados zombi que nadie verificó. El PM es responsable de que **lo que la fábrica inhala sea
verdad**: cada issue abierta representa trabajo real, priorizado con criterio explícito, con
su contexto completo dentro de la issue (la fábrica no puede leer la cabeza de nadie).

**El PM mantiene la cola por delante de la capacidad disponible que comunica el CEO**: encargos
listos ANTES de que los canales se vacíen. Canales parados por falta de carga lista, habiendo
trabajo prioritario ejecutable, son un fallo DEL PM — y jamás se inventa carga para mantener
utilización: cero ociosidad significa cero ociosidad POR FALTA DE CARGA LISTA, no actividad
artificial.

## Higiene de la cola ANTES de entregarla

Ritual completo antes de todo intake (y periódicamente durante la operación):

1. **Zombis**: toda issue `In Progress` se verifica contra repo/producción — ¿hay rama viva?,
   ¿el fix ya está en main?, ¿la entrega ya corre en producción? Lo entregado se cierra con
   evidencia (commit/PR/estado verificado en el comentario de cierre) y GO del lead cuando el
   cierre es decisión suya.
2. **Prioridades honestas**: cero issues sin prioridad. La escala se asigna por riesgo real
   (dinero/producción > operativa > producto > deudas), no por antigüedad.
3. **Duplicados y resueltas-por**: una issue cuya necesidad quedó cubierta por otra entrega se
   cierra como resuelta-por, con la referencia — no se deja «por si acaso».
4. **Estados que mienten**: `In Progress` sin canal trabajándola vuelve a Backlog con nota.
5. **Relaciones y consistencia eventual**: las relaciones de bloqueo/duplicado se curan como
   parte de la higiene — y en trackers de consistencia eventual, el efecto de una mutación de
   relación o de estado puede tardar o requerir un segundo intento: el flip
   **se verifica, no se asume** — tras mutar, se relee el estado final con consulta propia y
   reintentos acotados **hasta observar la transición esperada** (una única relectura
   inmediata puede devolver estado obsoleto y no prueba nada). Agotado el límite sin
   observarla: ALTO — la issue no se libera. Un flip asumido deja issues liberadas-que-no o
   bloqueadas-fantasma.

## El paquete de intake

El intake formal de un proyecto a la fábrica es UN documento por secciones, y el CEO lo acusa
**por secciones**. Contenido mínimo:

1. **Brief de producto**: qué es, qué vende/entrega, stack, dónde corre, qué NO se toca sin GO.
2. **La carga**: cola priorizada en fases con orden de ataque propuesto y el racional de cada fase.
3. **Doctrinas innegociables del producto**: las reglas que van al manifiesto y a los briefs
   (gates, gobernanza de push/merge, fronteras con terceros, recursos compartidos). No se
   debilitan sin ratificación del lead.
4. **Custodia por NOMBRES**: credenciales que la estación necesita, siempre por nombre de item —
   los valores los transfiere el lead por su canal, JAMÁS viajan en el intake.
5. **Desbloqueos del lead**: decisiones pendientes que solo el lead puede dar — enumeradas para
   que nadie planifique encima de ellas.
6. **Interfaz**: el PM como interlocutor de producto, el protocolo de entregas y evidencia.

La respuesta esperada del CEO: acuse por secciones + preguntas de manifiesto si las hay + su
**plan de arranque**, que el PM pre-revisa (ver `02`) antes del GO inaugural del lead. El acuse
del intake y el plan de arranque son actos ÚNICOS de apertura de la fábrica o de una fase —
JAMÁS permisos por-issue: abierto el flujo ordinario, el CEO despacha solo (ver `06`).

## Criterios de aceptación por encargo

Cada encargo que el PM entrega lleva sus criterios DENTRO de la issue:

- **Qué se acepta**: comportamiento observable, evidencia exigida (gates, salidas, capturas de
  estado), y qué constituye «hecho» — «¿un revisor senior lo aprobaría?» es el listón.
- **Qué NO entra**: el alcance negativo explícito evita que el canal «mejore» superficies ajenas.
- **Superficies sensibles**: si el encargo roza dinero, producción, recursos compartidos o
  fronteras con terceros, el encargo lo declara y remite al camino excepcional que aplique
  (ver `04` y `06`) — por defecto, nada de eso se toca sin la reserva escrita correspondiente.
- **Serialización**: si dos encargos comparten archivos calientes (módulos comunes, lockfiles),
  el reparto de superficie va en los briefs y las ediciones al terreno común se serializan.

## Desbloqueos del lead

Las decisiones que solo el lead puede dar (compras, licencias, matrices de negocio, elecciones
de diseño reservadas) se mantienen en una lista viva, visible en el intake y fuera de toda
planificación: la fábrica no espera bloqueada por ellas ni las asume. Cuando el lead decide,
el PM convierte la decisión en encargo con su criterio de aceptación.
