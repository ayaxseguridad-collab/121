---
name: talent-prd
description: >
  Escribir un PRD de producto de principio a fin: pipeline de 7 fases (intake,
  interrogatorio con forcing questions, premisas y landscape, escalada de fidelidad,
  alcance, documento, review adversarial), 3 modos de entrada (greenfield,
  brownfield-reconversion de un repo, auditoria de un PRD ya escrito), plantillas de
  3 niveles por appetite (Lite 9 / Estandar 18 / Completo 27 secciones), wayfinder
  local de decisiones y backlog portable con trazabilidad. Sin tracker, sin red:
  todo en ficheros. Trigger (ES/EN): "PRD", "escribir un PRD", "documento de
  requisitos", "product requirements", "product spec", "spec de producto", "definir
  el producto", "validar mi idea", "idea a documento", "interrogatorio de producto",
  "forcing questions", "wedge", "appetite", "alcance del MVP", "scope the MVP",
  "user stories", "casos de uso", "walking skeleton", "backlog desde el PRD",
  "desglosar en issues", "review de mi PRD", "auditar un PRD", "documentar un repo
  existente", "wayfinder", "mapa de decisiones", "product discovery".
---

# De la idea al PRD aprobado — sin saltarte las preguntas incomodas

## Quick Orientation

| Que | Valor |
|---|---|
| Proposito | convertir una idea, un repo o un PRD viejo en un PRD aprobado + backlog |
| Pipeline | pipeline de 7 fases: intake → interrogatorio → premisas/landscape → fidelidad → alcance → documento → review adversarial |
| Modos de entrada | greenfield · brownfield-reconversion · PRD inicial existente |
| Niveles | lite (9 secciones) · estandar (18) · completo (27, superset) por appetite |
| Artefactos | `prd.md` versionado (DRAFT→APPROVED) · `wayfinder/` · `backlog.md` portable |
| Dependencias | bash + coreutils; cero tracker, cero servicios. Frontera de red: los scripts y probadores del skill NO tocan la red jamas; la busqueda de landscape (fase 3) la haces tu con tus herramientas y entra al doc como snapshot fechado |
| Idioma | Espanol, para alumnos de Vibecoder Academy — y para cualquiera |

## Patrones esenciales

```text
  idea / repo / PRD viejo
        |
   [modo de entrada]           greenfield: la entrevista es la fuente
        |                      brownfield: el codigo responde ANTES de preguntar
        v                      PRD viejo:  auditar gaps, cubrir huecos
   [7 fases del pipeline]      una pregunta por turno · evidencia antes de preguntar
        |                      la licencia para matar la idea existe y se usa
        v
   prd.md (DRAFT) ---review adversarial (5 dimensiones, 0-10, <=3 rondas)---> APPROVED
        |                                                     |
   wayfinder/ (decisiones abiertas)                    backlog.md (Surfaced by §N)
```

Tres reglas que no se negocian, en cualquier fase:

- UNA pregunta por turno: la entrevista avanza pregunta a pregunta; disparar seis
  preguntas juntas produce seis medias respuestas.
- Evidencia antes de preguntar: lo que el material ya responde se confirma, no se
  pregunta. En brownfield es ley — el as-is sale del codigo, la entrevista cubre
  solo el delta.
- Toda decision con audit trail: clase mechanical (una sola respuesta razonable),
  taste (eleccion de criterio, con su porque) o challenge (cuestiona una premisa
  del PRD — se escala, no se decide en silencio).

El documento es un artefacto versionado: nace DRAFT, la review lo aprueba, y un
APPROVED no se edita por encima — se supersede con un fichero nuevo. El appetite
(cuanto quieres gastar) se decide ANTES de escribir y elige la plantilla: lite,
estandar o completo.

## Reference Files (leer segun necesidad)

| Necesito… | Reference File |
|---|---|
| Las 7 fases en detalle: forcing questions, landscape anti-cutoff, escalada, mecanica transversal | `references/01-pipeline-7-fases.md` |
| Elegir modo de entrada y su guia de entrevista (greenfield / brownfield / PRD viejo) | `references/02-modos-de-entrada.md` |
| El superset de 27 secciones, que exige cada nivel, formato hibrido y versionado | `references/03-documento-y-plantillas.md` |
| La rubrica de review (5 dimensiones, 0-10, 3 rondas) y el desgranado a backlog | `references/04-review-adversarial-y-desgranado.md` |
| Montar y mantener el wayfinder/ de decisiones | `references/05-wayfinder-local.md` |

## Quick Start

```bash
# 1) copia la plantilla de tu appetite (lite | estandar | completo)
mkdir -p mi-producto && cp assets/plantilla-prd-lite.md mi-producto/prd.md

# 2) sigue el pipeline (references/01) rellenando el documento por fases;
#    decisiones abiertas -> fichas en mi-producto/wayfinder/ (assets/plantilla-decision.md)

# 3) verifica la FORMA en cualquier momento (cabecera, numeracion, pass/fail, wayfinder, backlog)
bash scripts/verificar-prd.sh mi-producto

# 4) mide huecos contra tu nivel declarado (un Lite completo da cero gaps)
bash scripts/auditar-gaps.sh mi-producto/prd.md

# 5) review adversarial (references/04) -> APPROVED -> desgranado a backlog
cp assets/plantilla-backlog.md mi-producto/backlog.md   # una issue por bloque, con Surfaced by §N
```

Solo bash: los scripts son bash+coreutils a proposito — el skill debe funcionar
en la maquina de un alumno sin instalar nada (variacion aceptada de un solo
lenguaje: no hay SDK que envolver, solo texto que verificar).

## Critical Gotchas

1. **Saltarse el interrogatorio e ir directo a la plantilla** → el documento sale
   entero y hueco: secciones rellenas sobre una idea sin persona ni wedge. Las 6
   forcing questions van ANTES de escribir una linea del PRD.
2. **PRD-novela: prosa sin un solo criterio pass/fail** → nadie puede decir si el
   producto "esta bien". Cada criterio es `- PASA si:` / `- FALLA si:` observable;
   `verificar-prd.sh` lo exige mecanicamente.
3. **La review del propio autor no es review fresca** → aprueba en minutos y deja
   los huecos que el autor no ve. Revisor fresco = otra persona u otra sesion SIN
   el contexto de autoria, solo el doc y la rubrica.
4. **Elegir appetite al final** → escribiste 27 secciones para dos semanas de
   trabajo, o 9 para un sistema con pagos. El appetite se fija en la fase 5 y
   ELIGE la plantilla, no al reves.
5. **Backlog sin «Surfaced by §N»** → en una semana el backlog se independiza del
   PRD y tienes dos fuentes de verdad, o sea ninguna. Issue que no cita seccion,
   issue que no entra.
6. **Brownfield preguntando lo que el codigo ya responde** → gastas la paciencia
   del entrevistado en confirmar lo obvio. El as-is se extrae del repo primero y
   se cita con rutas verificables (`--codigo` lo comprueba).
7. **Varias preguntas por turno** → respuestas a medias y contexto perdido. UNA
   pregunta por turno, siempre — es la regla mas barata de romper y la que mas
   cuesta reparar.
8. **No-gos en negativo** → "no haremos X" sin alternativa es una discusion
   aplazada. El formato es "NO haremos X; en su lugar: Y".
9. **Wayfinder usado como TODO-list** → tareas decididas disfrazadas de
   decisiones. Al wayfinder van solo preguntas con mas de una respuesta posible;
   el trabajo decidido va al backlog.
10. **Ignorar la licencia para matar** → el interrogatorio tumbo la idea y el PRD
    siguio adelante por inercia. Si el hecho letal se demuestra, la idea se mata
    y se escribe por que: es el PRD barato mejor invertido.
11. **Editar un APPROVED por encima** → destruyes la evidencia de que se aprobo
    otra cosa. Reescritura = fichero/version nueva con `supersedes=`; la historia
    se lee por la cadena.
12. **Landscape desde la memoria** → "ya existe X que hace esto" recordado esta
    caducado por definicion (anti-cutoff). El landscape se busca HOY y se anota
    con fecha; sin busqueda fresca no hay seccion 10.

## Cross-Skill Integration

- **`talent-memoria`** — comparte molde (scripts sourceables, probadores con
  corpus fake, gate standalone): si mantienes tu memoria con ese skill, guarda
  alli las decisiones taste/challenge selladas de tus PRDs.
- **`talent-llm-local`** — el revisor fresco de la fase 7 puede ser una sesion
  contra tu modelo local: mismo doc, misma rubrica, cero coste por ronda.
- Cualquier tracker de issues — `backlog.md` es texto plano a proposito: se
  importa o se pega, una issue por bloque `## B<n>`, sin adaptador.

## Verificacion

```bash
bash scripts/verificar-prd.sh <dir-producto>      # forma del artefacto (rc 0/1/2)
bash scripts/auditar-gaps.sh <dir>/prd.md         # huecos contra el nivel declarado
bash tests/probar-verificar.sh                    # 26 casos rojo/verde del verificador
bash tests/probar-escenarios.sh                   # E1/E2/E3: procedimiento vs naive
bash tests/probar-invariants.sh                   # las invariantes muerden (+ mutacion)
bash tests/probar-standalone.sh                   # HOME limpio con espacios, sin repo
```

Suite completa: 4 probadores, 47 casos en verde (medido, no estimado).
`verificar-prd.sh` distingue tres estados a proposito: OK, FALLO (con el motivo
exacto) y OMIT para lo opcional que no esta (wayfinder, backlog, as-is).

## Estado de verificacion — lo que esta probado y lo que no

| Punto | Estado | Evidencia |
|---|---|---|
| La forma del artefacto se verifica mecanicamente | **Verificado** | `tests/probar-verificar.sh`: 26 casos rojo/verde, motivo ademas de rc |
| Los 3 modos de entrada tienen camino probado | **Verificado** | `tests/probar-escenarios.sh`: E1 greenfield, E2 brownfield con as-is contra repo fixture, E3 auditoria de gaps |
| La auditoria de gaps es consciente del appetite | **Verificado** | E3: Lite completo = 0 gaps en su nivel; el mismo fichero como completo = 18 gaps |
| Las invariantes muerden | **Verificado** | `tests/probar-invariants.sh`: mutacion (NO VERIFICADA borrado), target ausente, patron roto y MUST_NOT violado dan ROJO |
| El skill funciona copiado suelto, sin repo y con espacios en la ruta | **Verificado** | `tests/probar-standalone.sh`: agnosticismo case-insensitive sobre toda la superficie publicable + ciclo funcional |
| **Pasada end-to-end con un producto real** | **NO VERIFICADA** | El pipeline completo (entrevista incluida) no se ha rodado aun con un alumno y un producto reales; los escenarios usan fixtures deterministas. Cuando se ruede, esta tabla se actualiza con lo que salga |
| **La rubrica de review discrimina en la practica** | **NO VERIFICADA** | Los umbrales (media >=8, ninguna <6, 3 rondas) vienen del diseno sellado, no de rondas reales medidas |

Un «no verificado» honesto vale mas que un «funciona» sin comprobar.

## Fuera de alcance

- Integracion con trackers (crear issues via API): el backlog es portable a
  proposito; el adaptador a cada tracker es problema del tracker.
- Estimacion de esfuerzo, priorizacion de backlog y planificacion de sprints: el
  PRD define el QUE; el cuanto-cuesta-cuando es otra disciplina.
- Diseno visual (wireframes, mockups): la escalada de fidelidad los menciona como
  peldanio, no los produce.
- Espejos del documento en otras herramientas: un solo fichero fuente, siempre.

## Next Steps

- ¿Empiezo de cero, de un repo o de un PRD viejo? → `references/02-modos-de-entrada.md`
- ¿Que fase toca y que produce cada una? → `references/01-pipeline-7-fases.md`
- ¿Que nivel de plantilla me corresponde? → `references/03-documento-y-plantillas.md`
- Tengo el borrador: ¿quien y como lo revisa? → `references/04-review-adversarial-y-desgranado.md`
- Tengo decisiones abiertas que bloquean → `references/05-wayfinder-local.md`

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
