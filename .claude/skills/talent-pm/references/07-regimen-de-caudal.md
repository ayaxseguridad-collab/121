# 07 — Régimen de caudal: la fábrica jamás espera al PM

Adjudicación del lead (2026-07-30): **el PM no puede ralentizar NUNCA la fábrica.** El rigor de
las verificaciones del PM es innegociable (`02`, `05`); su LATENCIA es un defecto del PM tan
grave como la cola sucia. Esta reference existe porque el modo dominante de frenar una fábrica
no es vigilarla — es hacerla esperar: cada verificación del PM que llega tarde retiene merges,
applies y cadenas enteras aguas abajo. El régimen se diseña para que la espera sea de minutos —
y para que ni eso.

## Table of Contents

- [Los dos modos de frenar](#los-dos-modos-de-frenar)
- [Qué espera al PM y qué no](#qué-espera-al-pm-y-qué-no)
- [Checklist precargado](#checklist-precargado)
- [Regímenes de disponibilidad declarados](#regímenes-de-disponibilidad-declarados)
- [Parquear-no-forzar: la máquina de estados](#parquear-no-forzar-la-máquina-de-estados)
- [Ráfagas, no goteo](#ráfagas-no-goteo)
- [Baseline precapturado: referencia, no autoridad](#baseline-precapturado-referencia-no-autoridad)
- [Presencia pactada en ventanas](#presencia-pactada-en-ventanas)

## Los dos modos de frenar

La doctrina «no-freno» (`06`) se viola de dos maneras: **vigilando** (el PM-vigía, prohibido) y
**tardando**. El segundo es el empíricamente dominante: en operación real, el circuito de
verificaciones del PM llega a ser el cuello reconocido de todo el sistema si no se gobierna. El
**tiempo-en-espera-de-PM es una métrica de fallo DEL PM**: el CEO lo reporta como cualquier otro
dato de caudal, y el PM lo corrige **con régimen** (las secciones siguientes), jamás con
promesas de estar más atento — la atención no escala; el régimen sí.

## Qué espera al PM y qué no

NADA espera al PM salvo lo que la **frontera escrita y cerrada de delegación** (`04`) reserve a
su verificación o firma. Consecuencias:

- El PM **no se auto-asigna gates**: cada punto de espera nuevo requiere constar en esa
  frontera. Cada verificación que el PM se añade por celo es caudal que se resta a la fábrica —
  la lista de lo que espera es explícita, pactada y mínima.
- Lo no reservado fluye por los gates del motor **sin tocar al PM**: ni informarle es requisito.
- Cuando una verificación reservada exige segunda autoridad, esa autoridad es **la que la
  frontera identifique** — una contraparte de la capa META
  **jamás sustituye un GO reservado al lead**, por urgente que sea el trámite. En duda sobre
  quién firma, la respuesta está escrita en la frontera; si no lo está, se trata como
  reservada al lead (`04`).

## Checklist precargado

La verificación de un evento se prepara **ANTES** del evento: todo lo verificable con el
material ya disponible **se verifica antes** — el material sellado contra su rama, las
precondiciones, el contenido, las huellas del estado previo. Al caer el evento, el PM solo mide
el **delta** (lo que el evento cambió). Heurística de diseño — no criterio de aceptación: la
mayor parte del coste de verificar se paga fuera del camino crítico, y la verificación al caer
se resuelve en minutos porque casi todo estaba hecho.

## Regímenes de disponibilidad declarados

Antes de cada tramo (noche, ausencia, ventana de presencia limitada), el PM
**declara su régimen** por adelantado y el CEO programa CONTRA él — jamás descubre el hueco en
vivo: un tramo programado contra una ausencia no declarada pierde caudal sin que nadie lo haya
decidido. Menú de regímenes probados (elegibles por tramo, combinables):

- **Front-load**: lo que exige verificación del PM se agrupa al INICIO de su ventana de
  presencia; el resto del tramo corre sin él.
- **Relevo-al-caer**: presencia continua del PM; cada unidad se le releva al completarse y la
  verifica en serie, sin que la línea espere más que esa verificación. **Elegible SOLO cuando
  la capacidad observada del PM en el tramo
  sostiene el caudal entrante sin formar cola** — sin cifras universales: la capacidad es un
  dato vivo, por fábrica y por tramo. Si la cola crece, o el caudal previsto excede lo que el
  PM sostiene, este régimen DEJA de ser elegible en el tramo y se pasa a front-load o a
  parqueo: detectar la espera a posteriori (la métrica) no la excusa — el régimen correcto la
  PREVIENE.
- **Parquear-no-forzar**: el PM no está — ver la máquina de estados siguiente.

## Parquear-no-forzar: la máquina de estados

En ausencia del PM, la regla es única y vale para cualquier circuito:

1. Todo ítem que alcance un paso **reservado** a la verificación del PM se DETIENE
   inmediatamente **ANTES de ese paso** — nunca después — y queda **parqueado** en el último
   estado seguro que el circuito de la fábrica defina.
2. Todos los pasos previos no reservados del ítem **se completan** (el ítem llega al parque con
   su trabajo hecho, listo para la verificación).
3. Todo ítem SIN paso reservado **fluye a caudal completo** — la ausencia del PM le es invisible.
4. Al volver, el PM **drena el parque en ráfaga**, en el orden del circuito.

Lo que se pierde en este régimen es velocidad de UNA clase de trabajo (la reservada); jamás
seguridad — nada reservado se ejecuta sin su verificación — ni caudal del resto. Esta reference
no prescribe el orden interno del circuito de cada fábrica (qué pasos existen y en qué
secuencia es doctrina del circuito, no de este régimen): prescribe solo la regla de detención.

## Ráfagas, no goteo

Verificaciones pendientes acumuladas se ejecutan en **una ráfaga ordenada** — cuadre, firma,
siguiente — no una por intercambio de mensajes. Tres reglas:

- Se lanzan en paralelo SOLO las medidas independientes entre sí o tomadas sobre una
  instantánea inmutable; las medidas dependientes de estado mutable **se serializan** en el
  orden del circuito.
- **Barrera de vigencia**: inmediatamente antes de CADA firma se comprueba que la
  versión/instantánea que sostiene su medida
  **sigue vigente en el conjunto vivo**; si cambió, se relee y reconcilia ESA unidad antes de
  firmarla. Un refresh al inicio de la ráfaga NO es autoridad para las firmas posteriores: el
  registro avanza por trenes ajenos también entre firma y firma.
- La ráfaga agrupa **la ejecución del trabajo, jamás las firmas**: cada unidad firmable
  conserva su verificación y su firma individual, con su correspondencia unidad↔firma
  inequívoca. Lo que la ráfaga elimina es la latencia ENTRE unidades, no la granularidad de
  la responsabilidad.

## Baseline precapturado: referencia, no autoridad

Antes de un tramo sin presencia, el PM captura su baseline (conteos, máximos, invariantes del
producto) para ACELERAR el cuadre posterior. Pero el baseline es
**referencia histórica, nunca autoridad final**: en un registro que avanza por trenes ajenos
(recursos compartidos, `03`),
cuadrar contra la foto vieja atribuye a una tanda los deltas de otra — fabrica falsos
incidentes o, peor, firmas falsas. Antes de CADA firma — no solo al abrir la ráfaga —:
**refrescar el conjunto vivo** y **reconciliar toda entrada intermedia**, atribuyendo cada
delta a su procedencia (es la misma barrera de vigencia de la sección anterior). El baseline
dice dónde mirar; el conjunto vivo dice qué es verdad.

## Presencia pactada en ventanas

En ventanas bilaterales (`03`) rige «la ventana espera a las personas, nunca al revés» — pero
esa regla obliga al PM, no lo excusa: el compromiso de teclado se da con **hora explícita y
colchón**, y el PM llega ANTES del ETA del material que verificará, con el checklist
precargado. La verificación del PM **jamás es la causa de un deslizamiento** de ventana: si el
calendario del PM no alcanza el corte pactado, se declara al pactar la ventana — no se descubre
dentro de ella.
