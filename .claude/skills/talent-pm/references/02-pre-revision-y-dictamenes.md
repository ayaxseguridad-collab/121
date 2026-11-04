# 02 — Pre-revisión y dictámenes: ningún veredicto sin medida propia

## Table of Contents

- [Verificación independiente](#verificación-independiente)
- [Registro de hallazgos por rondas](#registro-de-hallazgos-por-rondas)
- [El dictamen](#el-dictamen)
- [Diseño antes que código](#diseño-antes-que-código)
- [Triage de expedientes de findings](#triage-de-expedientes-de-findings)

## Verificación independiente

El PM emite dictámenes, y un dictamen sin medida propia es una opinión. Regla dura: **verificación
independiente ANTES de todo dictamen** — se mide contra el catálogo vivo (repo, base de datos,
APIs, registros formales de PRs/reviews), jamás de memoria y jamás fiándose del reporte de la
contraparte, por competente que sea. El reporte se CONTRASTA, no se acepta:

- Un checkpoint que afirma «X está mergeado» se verifica con el registro remoto, no con el relato.
- Una cifra de una contraparte (conteos, versiones, huellas) se recalcula con comando propio.
- Una afirmación sobre producción se sondea contra producción (con acceso de solo lectura).
- Lo que no se puede verificar se declara como no verificado — nunca se presenta como comprobado.
- Un estado verde (check, badge, status) es una afirmación del sistema que lo emite, no una
  medida: donde un evento importa (una review ejecutada, un gate corrido), se verifica la
  **transición observada** del evento real en el registro de la plataforma — «skipped» o
  «success» sin el evento subyacente no constituye el evento. Y la transición sola tampoco
  basta: cuenta cuando termina en el **resultado aprobatorio de la autoridad requerida** —
  una review ejecutada que comenta o pide cambios es una transición observada SIN
  aprobación, y deja el material bloqueado.
- El evento verificado viaja LIGADO al material exacto: identifica el HEAD/huella de lo que
  se dictaminará o aplicará — cualquier cambio posterior del material **invalida la review**
  y exige una nueva transición observada (la misma caducidad que el GO por-SHA, ver `04`).

El costo de verificar es minutos; el costo de un dictamen sobre una premisa falsa es una fábrica
entera construyendo sobre arena. El historial de esta doctrina: las premisas invertidas, los
estados zombi y las entregas compuestas se cazaron TODAS midiendo, ninguna leyendo reportes.

## Registro de hallazgos por rondas

Las revisiones de planes/diseños se llevan por rondas con **registro estable**:

- Cada hallazgo se clasifica (Blocker / Major / Sugerencia media / baja) y recibe identidad
  estable entre rondas — un hallazgo aceptado y resuelto NO se reabre sin evidencia nueva.
- Cada hallazgo lleva: contrato violado, secuencia del fallo, impacto y corrección mínima.
- El descargo es legítimo cuando hay evidencia: se responde con la medida que lo refuta, no con
  argumentos. Aceptar un hallazgo correcto sin regatear es más barato que defender un error.
- El alcance se CONGELA cuando las rondas convergen: la ronda siguiente revisa solo lo abierto.

## El dictamen

Formato de salida del PM sobre un plan/diseño/entrega:

- **APTO / NO-GO** explícito, con los refinamientos VINCULANTES enumerados (numerados, cada uno
  con su qué y su porqué). «Apto con matices difusos» no es un dictamen.
- Lo verificado se cita con su medida (comando/valor); lo no verificable se declara.
- El dictamen del PM no sustituye el GO del lead donde el lead lo reservó (ver `04`): el PM
  pre-revisa y recomienda; el lead decide en su frontera.
- **Nota de método**: todo dictamen declara su método — qué se midió,
  **con qué comando/fuente**, y **qué NO se verificó** (con su porqué). Un dictamen sin nota
  de método no es auditable ni reproducible por un tercero.
- **Cierre con defecto conocido**: cerrar una entrega o un hallazgo con un defecto conocido
  es legítimo SOLO con **las tres condiciones juntas**: (1) el **radio medido** del defecto —
  su impacto acotado con medida propia, no estimado; (2) el registro trazable del defecto,
  con dueño y destino (follow-up); (3) la decisión de la autoridad que corresponda por la
  frontera (`04` — el lead, si la superficie es reservada). Sin las tres, el cierre es un
  defecto silenciado.

## Diseño antes que código

Todo encargo que toque **dinero, datos compartidos o fronteras con terceros** entrega primero
DISEÑO a pre-revisión del PM — antes de una sola línea de código: modelo de datos, invariantes
que debe respetar (idempotencia, atomicidad, autoridad única, claves estables persistidas antes
de efectos externos), cuántas migraciones parirá y qué contratos crea o modifica. El diseño es
barato en papel y carísimo en producción; la pre-revisión de diseño es el único gate previo que
el PM impone POR DEFECTO en el flujo ordinario, y solo en esas superficies.

## Triage de expedientes de findings

Cuando un encargo produce hallazgos (auditorías, revisiones), el PM triagea el expediente:
confirma cada hallazgo contra el código real (`archivo:línea`), lo clasifica por severidad y
decide destino — fix inmediato (nuevo encargo), follow-up trazado, o descarte con motivo
escrito. Un hallazgo descartado sin motivo registrado es un hallazgo perdido.
