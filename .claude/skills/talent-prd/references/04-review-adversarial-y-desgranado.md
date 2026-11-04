# 04 · Review adversarial y desgranado

La fase 7 en detalle: quien revisa, con que rubrica, cuando se para, y como el
documento aprobado se convierte en backlog sin perder la trazabilidad.

## Table of Contents

- [1. El revisor fresco](#1-el-revisor-fresco)
- [2. La rubrica de 5 dimensiones](#2-la-rubrica-de-5-dimensiones)
- [3. Veredicto y rondas](#3-veredicto-y-rondas)
- [4. Plantilla de veredicto](#4-plantilla-de-veredicto)
- [5. Desgranado a backlog portable](#5-desgranado-a-backlog-portable)
- [6. Errores tipicos de la fase](#6-errores-tipicos-de-la-fase)

## 1. El revisor fresco

Fresco = sin el contexto de autoria. Vale otra persona, o una sesion nueva del
asistente SIN el historial de la escritura (solo el `prd.md` y esta rubrica sobre
la mesa). Lo que NO vale: el autor releyendose, o la misma sesion que escribio el
documento "cambiando de sombrero" — el sesgo de autoria no se quita con sombreros.

El revisor recibe exactamente dos cosas: el documento y la rubrica. Si necesita
mas contexto para entenderlo, eso YA es un hallazgo (claridad).

## 2. La rubrica de 5 dimensiones

Cada dimension se puntua 0-10 con evidencia citada por seccion (`§N`). Sin cita no
hay hallazgo: "me suena flojo" no es un hallazgo.

| # | Dimension | Pregunta que responde | 0 significa | 10 significa |
|---|---|---|---|---|
| 1 | Claridad | ¿Se entiende sin el autor delante? | jerga sin definir, secciones que hay que releer | cualquiera del publico objetivo lo lee del tiron |
| 2 | Completitud | ¿Estan las secciones exigibles del nivel, con contenido real? | huecos o relleno de plantilla | cada seccion responde su pregunta |
| 3 | Verificabilidad | ¿Los criterios son binarios y observables? | "que funcione bien" | todo criterio se puede marcar PASA/FALLA sin preguntar |
| 4 | Realismo | ¿Premisas verificables, landscape actual, estimaciones defendibles? | fe y memoria | cada premisa con plan, landscape con fecha |
| 5 | Cohesion | ¿Las secciones se sostienen entre si? | el flujo contradice las historias, metricas huerfanas | trazas limpias: historias↔criterios↔fases↔backlog |

Apoyo mecanico antes de puntuar: correr `verificar-prd.sh` y `auditar-gaps.sh`
le ahorra al revisor los hallazgos de forma — su tiempo va al contenido.

## 3. Veredicto y rondas

- Puntuacion: las 5 dimensiones, 0-10 cada una.
- APRUEBA si: media >= 8 y ninguna dimension < 6. En cuanto aprueba, el documento
  pasa a `estado=APPROVED`.
- DEVUELVE si no: lista de hallazgos accionables (cada uno con dimension, `§N` y
  que cambiar). El autor corrige y reenvia.
- Maximo tres rondas. Si a la tercera no aprueba, el problema no es de redaccion:
  se vuelve a la fase que el hallazgo dominante seniale (premisas rotas -> fase 3;
  alcance imposible -> fase 5) y se dice explicitamente. Iterar la redaccion una
  cuarta vez es pulir un documento sobre una base podrida.

## 4. Plantilla de veredicto

```text
REVIEW <producto> — ronda <1|2|3> — <fecha>
Claridad:       N/10 — <evidencia §N>
Completitud:    N/10 — <evidencia §N>
Verificabilidad:N/10 — <evidencia §N>
Realismo:       N/10 — <evidencia §N>
Cohesion:       N/10 — <evidencia §N>
Media: N.N -> APRUEBA | DEVUELVE
Hallazgos (si devuelve):
  H1 [dimension] §N — <que cambiar, accionable>
  H2 ...
```

El veredicto se guarda junto al PRD (`review-ronda-<n>.md`): es la evidencia de
que la aprobacion existio y de que costo.

## 5. Desgranado a backlog portable

Con el PRD en APPROVED (y solo entonces — desgranar un DRAFT es construir sobre
arena):

1. Recorre las fases del walking-skeleton (§8) y las historias (§5) como columna
   vertebral, y despues TODA seccion normativa restante del nivel (NFRs,
   seguridad, operacion, costes, entidades...): cada requisito que exija trabajo
   genera su issue trazable, y el que no lo exija se anota como "sin trabajo:
   <porque>" — nada queda sin adjudicar.
2. Cada issue en el formato de `assets/plantilla-backlog.md`: `## B<n> · titulo`,
   `Contexto:`, `DoD:` y `Surfaced by §<n>`.
3. Trazabilidad obligatoria: el `Surfaced by §N` apunta a la seccion del PRD de
   la que nace la issue. Una issue que no puede citar su seccion no sale de este
   PRD: o falta una seccion (vuelve al documento) o la issue sobra.
4. El DoD de cada issue cita, cuando existe, el criterio PASA de §6 que cierra.
   Asi el "terminado" del backlog y el "aprobado" del PRD son la misma vara.
5. El backlog es texto plano importable: cualquier tracker lo traga (o se pega a
   mano, una issue por bloque). El PRD sigue siendo la fuente; el backlog, su
   proyeccion ejecutable — si discrepan, gano el PRD y el backlog se regenera.

## 6. Errores tipicos de la fase

- Review del autor: la ronda "aprueba" en minutos y el documento sigue teniendo
  los huecos que el autor no ve. Fresco o no es review.
- Hallazgos sin `§N`: no son accionables; el autor corrige otra cosa.
- Cuarta ronda: si necesitas mas de tres, el documento no es el problema.
- Desgranar el DRAFT: issues nacidas de secciones que la review luego cambio.
- Issues sin `Surfaced by`: el backlog se independiza del PRD en una semana y ya
  tienes DOS fuentes de verdad — es decir, ninguna.
