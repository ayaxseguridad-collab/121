# 01 · Pipeline de 7 fases

De una idea (o un repo, o un PRD viejo) a un PRD aprobado con backlog. Las fases van
en orden y cada una tiene una salida concreta; no se salta ninguna, pero en appetite
Lite algunas duran 10 minutos. La mecanica transversal (una pregunta por turno,
clasificacion de decisiones, versionado) esta al final.

## Table of Contents

- [0. Mapa del pipeline](#0-mapa-del-pipeline)
- [1. Intake](#1-intake)
- [2. Interrogatorio de producto](#2-interrogatorio-de-producto)
- [3. Premisas y landscape](#3-premisas-y-landscape)
- [4. Escalada de fidelidad](#4-escalada-de-fidelidad)
- [5. Alcance y alternativas](#5-alcance-y-alternativas)
- [6. Documento](#6-documento)
- [7. Review adversarial y desgranado](#7-review-adversarial-y-desgranado)
- [8. Mecanica transversal](#8-mecanica-transversal)

## 0. Mapa del pipeline

```text
  idea / repo / PRD viejo
        |
  [1 Intake] --modo de entrada--> greenfield · brownfield · PRD-existente (02-modos)
        |
  [2 Interrogatorio]  6 forcing questions · persona nombrada · wedge · licencia para matar
        |
  [3 Premisas+Landscape]  evidencia ACTUAL, anti-cutoff
        |
  [4 Escalada de fidelidad]  charla -> boceto -> prototipo -> wayfinder/ (05-wayfinder)
        |
  [5 Alcance]  appetite -> nivel de plantilla · alternativas A/B/C · 10-estrellas opt-in
        |
  [6 Documento]  plantilla del nivel · pass/fail · no-gos en positivo · walking-skeleton
        |
  [7 Review adversarial]  revisor fresco · 5 dimensiones 0-10 · <=3 rondas   (04-review)
        |
        +--> desgranado: backlog portable con "Surfaced by §N"
```

## 1. Intake

Salida: el modo de entrada elegido y el material sobre la mesa.

- Pregunta que responde: ¿de que partimos? Una idea en la cabeza (greenfield), un
  repo que ya existe sin PRD (brownfield), o un PRD inicial ya escrito (auditoria).
- Recoge el material SIN evaluarlo todavia: notas, capturas, el repo, el doc viejo.
- Elige el modo con la tabla de `02-modos-de-entrada.md` y sigue su guia de
  entrevista. Los tres modos convergen en la fase 2 con distinta cantidad de
  trabajo ya hecho.
- Si en el intake ya se ve que el producto son en realidad DOS productos, dilo
  ahora: un PRD por producto, no un PRD-paraguas.

## 2. Interrogatorio de producto

Salida: las 6 respuestas selladas + la persona con nombre + el wedge — o la idea
muerta a tiempo.

Las 6 forcing questions (estilo YC: incomodas a proposito, no admiten respuesta
de folleto):

1. ¿Quien lo necesita tanto que lo usaria aunque estuviera roto? — la persona
   tiene NOMBRE (real o arquetipo bautizado). "Los usuarios" no es una persona.
2. ¿Que hace esa persona HOY sin tu producto? — si la respuesta es "nada", el
   dolor no existe o no lo has encontrado.
3. ¿Por que ahora y no hace dos anios? — que cambio (tecnologia, mercado, tu).
4. ¿Cual es el wedge? — la cunia minima que YA cambia algo para esa persona.
   No la vision: la primera muesca.
5. ¿Como sabras en 2 semanas que NO funciona? — la senial de muerte, definida
   antes de empezar.
6. ¿Que tendria que ser cierto para matar la idea? — y la licencia para matarla:
   si el interrogatorio demuestra ese hecho, la idea SE MATA y se dice con esas
   palabras. Un pipeline que nunca mata ideas es un tramite.

Reglas del interrogatorio:

- UNA pregunta por turno. Se hace la pregunta, se espera la respuesta, se anota.
  Disparar las seis a la vez produce seis medias respuestas.
- Evidencia antes de preguntar: si el material del intake ya responde una
  pregunta, no se pregunta — se confirma ("el repo ya hace X, ¿sigue siendo
  cierto?").
- Las respuestas se sellan: van a la seccion "Interrogatorio sellado" del PRD
  (nivel Estandar+) y no se reescriben en silencio.

## 3. Premisas y landscape

Salida: la lista de premisas con plan de verificacion + el landscape con evidencia
actual.

- Premisas: todo lo que el producto asume y nadie ha comprobado ("la gente pagara
  por esto", "la API aguanta el volumen"). Cada premisa lleva su plan: que
  experimento de <=2 semanas la tumbaria.
- Landscape ANTI-CUTOFF: lo que existe se busca HOY, no se recuerda. La memoria
  de un asistente (o la tuya) tiene fecha de caducidad; un landscape sin busquedas
  frescas es un landscape caducado por definicion. Anota que existe, que hace bien
  y donde se queda corto — ahi vive tu wedge. Frontera de red del skill: la
  busqueda la haces TU con tus herramientas (navegador, buscador, tu asistente);
  los scripts del skill no tocan la red nunca — al documento entra el resultado
  como snapshot con fecha.
- Si una premisa gorda no se puede verificar barato, es una decision para el
  wayfinder (fase 4), no un parrafo optimista.

## 4. Escalada de fidelidad

Salida: la decision de cuanta realidad necesitas antes de escribir el documento,
y el `wayfinder/` montado si hay decisiones abiertas.

La escalera, de menos a mas coste:

1. Conversacion (ya la tienes: fases 1-3).
2. Boceto/guion: pantallas dibujadas o el flujo escrito paso a paso.
3. Prototipo desechable: lo minimo que una persona real puede tocar.
4. Wayfinder: cuando lo que falta no es fidelidad sino DECISIONES — montas el
   directorio `wayfinder/` con una ficha por decision abierta (tipo research /
   grilling / prototype / task, con su frontera de niebla) y el indice. Formato y
   ciclo de vida en `05-wayfinder-local.md`.

Sube un peldanio solo si la pregunta que te frena lo exige. Un prototipo para una
decision que era mechanical es coste sin informacion.

## 5. Alcance y alternativas

Salida: appetite fijado -> nivel de plantilla, y el recorte de alcance elegido.

- Appetite primero: ¿cuanto estas dispuesto a gastar en esto — 1-2 semanas (lite),
  1-3 meses (estandar), mas o con varios actores/dinero (completo)? El appetite se
  decide ANTES de escribir el documento; decidirlo despues obliga a reescribir.
- Alternativas A/B/C: tres recortes del alcance sobre la mesa — A minimo
  defendible, B equilibrio, C ambicioso. Se elige uno y se documenta por que
  (seccion 12 del PRD en Estandar+).
- 10-estrellas (opt-in): describe la version de 10 estrellas — tan buena que es
  absurda — y recorta hacia atras. Lo que sobrevive al recorte es lo esencial.
  Es opcional; si se hace, va a la seccion 22 (nivel Completo).

## 6. Documento

Salida: el `prd.md` en DRAFT, sobre la plantilla del nivel elegido.

- Copia la plantilla del nivel (`assets/plantilla-prd-<nivel>.md`) y rellena TODAS
  sus secciones. "No aplica" con su porque tambien es rellenar.
- Secciones direccionables: H2 numerados (`## N. Titulo`). El backlog y la review
  citan secciones por numero — si los numeros bailan, la trazabilidad muere.
- Criterios pass/fail: cada criterio de aceptacion es binario y observable
  (`- PASA si:` / `- FALLA si:`). Un criterio que necesita interpretacion no es
  un criterio.
- No-gos en positivo: "NO haremos X; en su lugar: Y". El no-go sin alternativa
  es una promesa de discusion futura.
- Fases walking-skeleton: la fase 1 es el recorrido entero feo; las siguientes lo
  engordan. Nunca "primero el modulo A entero, luego el B".
- Versionado: el documento nace `estado=DRAFT`. Cuando se aprueba (tras la fase
  7), pasa a `estado=APPROVED`. Una reescritura posterior es un fichero NUEVO con
  `supersedes=<version anterior>` — un APPROVED no se edita por encima.
- Detalle de plantillas, superset de 27 secciones y formato hibrido:
  `03-documento-y-plantillas.md`.

## 7. Review adversarial y desgranado

Salida: el PRD APPROVED con su backlog portable — o, si la ronda devuelve, la
lista de hallazgos accionables (sin backlog: el desgranado SOLO ocurre sobre un
documento aprobado, 04 seccion 5).

- Revisor FRESCO: alguien (o una sesion nueva sin el contexto de autoria) que no
  escribio el documento. El autor releyendose a si mismo aprueba su propio sesgo.
- Rubrica de 5 dimensiones, cada una 0-10, con umbral y maximo tres rondas —
  rubrica completa, plantilla de veredicto y reglas de parada en
  `04-review-adversarial-y-desgranado.md`.
- Desgranado: con el PRD aprobado, cada bloque de trabajo se convierte en una
  issue del backlog portable (`assets/plantilla-backlog.md`): titulo, contexto,
  DoD y su `Surfaced by §N` apuntando a la seccion del PRD de la que nace.
- El backlog es texto plano importable por cualquier tracker; el PRD queda como
  fuente de verdad y el backlog como su proyeccion ejecutable.

## 8. Mecanica transversal

Valida en TODAS las fases:

- UNA pregunta por turno. La entrevista avanza pregunta a pregunta; el
  interrogado responde a lo que le preguntaron, no a un cuestionario.
- Evidencia antes de preguntar. Lo que el material ya responde no se pregunta:
  se confirma. En brownfield esto es ley (el codigo responde primero).
- Clasificacion de decisiones con audit trail. Toda decision relevante se anota
  con su clase: mechanical (habia una sola respuesta razonable), taste (eleccion
  de criterio — se documenta el porque), challenge (cuestiona una premisa del
  propio PRD — se escala, no se decide en silencio). La tabla vive en la seccion
  17 del PRD (Estandar+); en Lite, como lista breve en la seccion 9.
- Artefacto versionado. DRAFT -> APPROVED -> (supersedes) fichero nuevo. La
  historia de un PRD se lee por su cadena de `supersedes=`, no por un diff.
- Verificacion mecanica: `scripts/verificar-prd.sh <dir>` comprueba la forma del
  artefacto (cabecera, numeracion, pass/fail, wayfinder, backlog) en cualquier
  momento; `scripts/auditar-gaps.sh <prd.md>` mide gaps contra el nivel declarado.
