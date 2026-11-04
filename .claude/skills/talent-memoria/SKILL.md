---
name: talent-memoria
description: >
  Establecer, limpiar y optimizar la memoria persistente de Claude Code: CLAUDE.md,
  .claude/memory/ del repo y la memoria general del harness (MEMORY.md). Pipeline de
  reparacion en 7 pasos sobre corpus append-only (nunca borrar: anular en su sitio),
  5 estados (ANULADA, ACOTADA, CADUCADA, SUPERSEDED, ALIAS-STUB), regla de autoridad
  (la recencia solo desempata iguales) y salvaguardas fail-closed con mundo cerrado.
  Para cualquiera con su Claude, en cualquier repo. Trigger (ES/EN): "limpiar memoria",
  "optimizar memoria", "reparar memoria", "memoria de Claude Code", "MEMORY.md",
  "memoria del proyecto", "notas de memoria", "memoria contradictoria", "instrucciones
  muertas", "duplicados en memoria", "consolidar notas", "anular nota", "nota caducada",
  "CLAUDE.md desactualizado", "indice de memoria", "corpus de notas", "establecer
  memoria", "alias stub", "snapshot de memoria", "memory cleanup", "memory hygiene",
  "stale memory", "prune memory", "auto memory", "memory index", "memory repair",
  "append-only", "superseded".
---

# Tu memoria de Claude Code, limpia y fiable — sin borrar nunca tu historico

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Que hace | Censa tu memoria (`diagnostico.sh`), la protege antes de tocarla (`salvaguarda.sh`), te guia para repararla (pipeline de 7 pasos) y comprueba que la reparacion no rompio nada (`verificar.sh`, mundo cerrado fail-closed) |
| Para quien | Cualquier persona con Claude Code: con un repo propio, con varios, o solo con la memoria general del harness. No requiere ninguna infraestructura |
| Requisitos | Bash + coreutils (`grep`, `diff`, `sha256sum`, `tar`); `git` solo si tu memoria vive en un repo. Linux y macOS; Windows via WSL o con el flujo manual de `references/03` |
| Variantes | **Dos, y las elige el script**: con-git (memoria dentro de un repo, rastreada y limpia) y sin-git (memoria del harness, CLAUDE.md global, o repo sucio). En la duda gana el snapshot |
| Dependencias externas | **Cero.** Sin red, sin credenciales, sin servidores. Todo local; los scripts solo ejecutan una allowlist declarada de comandos |
| Origen | Metodologia rodada sobre un corpus real de 379 notas (7 pasadas de reparacion completas, con auditoria); este skill es su primera codificacion durable |
| Idioma | Espanol, para alumnos de Vibecoder Academy — y para cualquiera |

**La regla que gobierna todo**: tu memoria es **append-only**. El historico nunca se
borra; lo que ya no vale se **anula en su sitio**, con fecha y con puntero a lo que lo
sustituye. Borrar parece mas limpio hoy y te deja sin la prueba de por que decidiste
algo — y sin proteccion cuando una copia vieja reaparezca.

## Patrones esenciales

El pipeline de reparacion, en orden. El orden no es decorativo (gotcha 12):

```text
  0. diagnostico.sh   (censo: NO toca nada)
  1. salvaguarda.sh   (snapshot + manifiesto de hashes, o rama git si TODO esta limpio)
  2. dedupe           duplicados → gana el superconjunto; el perdedor queda ALIAS-STUB (paso 1)
  3. contradicciones  la recencia desempata SOLO entre iguales (ver autoridad, abajo) (paso 2)
  4. superadas        normas que una decision posterior derogo → ANULADA / ACOTADA (paso 3)
  5. caducadas        regimenes con ventana vencida → CADUCADA · doctrina → SUPERSEDED (paso 4)
  6. pendientes       conflicto no adjudicable → placeholder + preguntar (NO tocar) (paso 5)
  7. sync realidad    instrucciones que apuntan a ficheros/procesos muertos → a pasado (paso 6)
  8. espejos          la misma nota en dos sitios → corregir el canonico, luego copiar (paso 7)
  9. indice           compactar MEMORY.md a one-liners con estado (SOLO al final)
 10. verificar.sh     mundo cerrado: cambio EXACTAMENTE lo declarado, nada mas
```

Leyenda de la numeracion: **2-8 = pasos 1-7** de `references/02-pipeline-de-reparacion.md`
seccion 5 (dedupe→espejos), mismo contenido con dos numeraciones — esta cuenta el flujo
COMPLETO (0-1 preparacion, 9-10 cierre); `references/02` solo cuenta los pasos de
reparacion propiamente dichos.

Quien gana un conflicto. La fecha solo decide en el ultimo escalon:

```text
  ¿Conflicto entre dos fuentes?
  ├── Distinto nivel de autoridad → se OBEDECE el superior mientras tanto, pero NO
  │   se reescribe NADA: placeholder + preguntar antes de anular/acotar la inferior.
  │     1º decision explicita tuya (dicha o sellada)
  │     2º CLAUDE.md vigente en su ambito (repo > global, cada uno en el suyo)
  │     3º notas de memoria
  ├── Mismo nivel + ambas con fecha → gana la mas reciente (y la vieja se ANULA citandola)
  └── Sin fecha, o autoridad ambigua → NO TOCAR: placeholder de decision pendiente
        y se lo preguntas a quien manda: tu
```

Anatomia de una anulacion (4 campos, SIEMPRE ANTES del texto muerto — el que lee con
`grep` encuentra primero la marca, no la norma derogada):

```text
  > ANULADA 2026-07-27 — [motivo en una frase]
  > Linea muerta: "[cita literal de lo que ya no vale]"
  > Linea vigente: [[nota-o-decision-que-la-sustituye]]
  > Autoridad: [quien y cuando lo decidio]
  [ ... aqui debajo queda el texto original, intacto ... ]
```

## Reference Files (leer segun necesidad)

| Necesito… | Reference File |
|---|---|
| Saber donde vive mi memoria y que tan degradada esta | `references/01-donde-vive-y-diagnostico.md` |
| Reparar: los 7 pasos, los 5 estados, autoridad, fusiones y stubs | `references/02-pipeline-de-reparacion.md` |
| Protegerme antes de tocar y verificar despues (con-git / sin-git) | `references/03-salvaguardas-y-verificacion.md` |
| Empezar de cero con buena estructura, u optimizar el indice | `references/04-establecer-y-optimizar.md` |

## Quick Start

```bash
cd <carpeta-del-skill>   # funciona copiada a cualquier maquina, sin este repo

# 1) ¿Que memoria tengo y en que estado? (solo lectura, no cambia nada)
bash scripts/diagnostico.sh                 # autodetecta; o: bash scripts/diagnostico.sh /ruta/a/mi/memoria

# 2) Protegerla ANTES de tocar nada (elige solo la variante git si TODO esta limpio)
bash scripts/salvaguarda.sh /ruta/a/mi/memoria

# 3) Reparar siguiendo references/02 (tu decides; los scripts no adjudican por ti)
#    ...y anotar cada cambio en cambios-declarados.tsv segun references/03

# 4) Comprobar que cambio EXACTAMENTE lo declarado, nada mas (fail-closed)
bash scripts/verificar.sh <snapshot-dir> /ruta/a/mi/memoria cambios-declarados.tsv
```

¿Sin corpus todavia? Empieza por `references/04-establecer-y-optimizar.md`: escribir
con buena estructura desde el primer dia hace la limpieza futura casi gratis.

## Critical Gotchas

1. **Borrar en vez de anular** → pierdes el historico y rompes los `[[enlaces]]` y greps
   que apuntaban a la nota; ademas, sin marca, la misma norma vieja reaparece desde una
   copia o de tu propia costumbre y nadie puede probar que quedo derogada. Append-only:
   se anula en su sitio.

2. **La marca de anulacion DESPUES del texto muerto** → quien lee con `grep` (tu o tu
   agente, que corta en la primera coincidencia) encuentra primero la norma derogada y
   la obedece con confianza. La marca va ANTES, pegada encima.

3. **Fusionar casi-duplicados a ciegas** → dos notas "casi iguales" nunca lo son del
   todo: las clausulas exclusivas del perdedor desaparecen en silencio. Antes de fundir,
   lista las clausulas que solo estan en el perdedor; despues de fundir, `grep` de CADA
   una en el superviviente. Lo que no aparezca, se perdio.

4. **El estado solo en el cuerpo, no en el frontmatter** → los indices y previews solo
   ensenian el `description:`; una nota anulada con description intacto se sigue
   vendiendo como viva. El estado va TAMBIEN ahi: `[ANULADA 2026-07-27] → sucesora:
   <slug> — resumen historico`.

5. **Verificar el indice por nombre de fichero** → el nombre ya estaba antes de tu
   cambio: ese grep da verde SIEMPRE (verde falso). Se verifica por contenido: grep
   positivo del one-liner nuevo exacto Y grep negativo del texto viejo.

6. **Reparar sin salvaguarda previa** → una fusion mal hecha sin snapshot no tiene
   vuelta atras. Primero `salvaguarda.sh`, siempre. Con git valida SOLO si todos los
   ficheros estan rastreados y limpios — un fichero untracked no esta en ningun commit
   y `git checkout` no te lo devuelve.

7. **Un diff con lineas `<` tras una pasada "solo-adicion"** → se borro algo que
   declaraste intocable. No se "arregla a mano sobre la marcha": se restaura del
   snapshot y se repite la pasada. El hash no distingue adicion de sustitucion; el
   diff dirigido si.

8. **Instrucciones ejecutables muertas** → un gotcha en imperativo que ordena aplicar
   un fichero que ya no existe es un mapa operativo falso: tu agente lo ejecuta con
   confianza y falla (o algo peor). Se reescribe a pasado ("se resolvio con X") con
   puntero a la solucion vigente.

9. **Corregir el espejo antes que el canonico** → si la misma nota vive en dos sitios,
   arreglar la copia dura hasta la proxima sincronizacion, que la pisa. Primero el
   canonico, despues propagar; si no sabes cual es el canonico, esa ES la primera
   contradiccion a adjudicar.

10. **Notas sin fecha no se pueden adjudicar** → "la mas reciente gana" exige saber cual
    es mas reciente. Sin fecha (ni en el frontmatter, ni en git) el conflicto va a
    placeholder de decision pendiente — inventarse la antiguedad es fabricar historia.
    Y hacia adelante: TODA nota nueva lleva fecha (references/04).

11. **Optimizar el indice antes de reparar** → compactar MEMORY.md con el corpus sucio
    es indexar basura con formato bonito, dos veces trabajo. El indice es el ULTIMO
    paso.

12. **Correr el pipeline en desorden** → adjudicar contradicciones antes del dedupe
    obliga a adjudicar la misma contradiccion una vez por copia; caducar regimenes
    antes de adjudicar puede caducar al ganador legitimo. El orden de los pasos existe
    porque cada uno reduce el trabajo del siguiente.

## Cross-Skill Integration

- **`talent-context`** (si tu instalacion lo tiene) — hermano conceptual, cero solape:
  aquel gestiona la VENTANA de contexto de la sesion en vuelo; este sanea la memoria
  PERSISTENTE en disco. Ninguno sustituye al otro.
- **`skill-creator`** (si tu instalacion lo tiene) — este skill sigue su Gold Standard;
  en el repo de origen se valida con `validate_skill.py talent-memoria`.
- **Sin ninguno de los dos**: este skill funciona igual — es standalone por contrato
  (lo prueba `tests/probar-standalone.sh`).

Este skill **no** toca trackers, ni bases de datos, ni ningun producto: sanea ficheros
de memoria en tu disco.

## Verificacion

```bash
bash tests/probar-lib.sh             # helpers compartidos: S3 estricto + tabla de verdad de fecha
bash tests/probar-diagnostico.sh     # el censo es inofensivo: HOME hermetico + canarios, delta cero
bash tests/probar-salvaguarda.sh     # el snapshot restaura: extraccion + hashes == manifiesto
bash tests/probar-verificar.sh       # 52 casos rojo/verde, mundo cerrado incluido
bash tests/probar-invariants.sh      # las invariantes del skill se consumen fail-closed (+ mutacion)
bash tests/probar-escenarios.sh      # 3 escenarios extremo a extremo (procedimiento vs naive)
bash tests/probar-standalone.sh      # copiado a un HOME limpio sin repo: funciona igual
```

Suite completa: 7 probadores, **127 casos en verde** (medido, no estimado).

Todos corren **sin entorno real**: `tests/corpus-fake/` es un corpus de memoria con los
defectos sembrados (duplicados, contradiccion fechada, norma caducada, instruccion
muerta, indice desactualizado, nota sin fecha). Cada probador comprueba el veredicto
**y el motivo**, no solo el codigo de salida.

## Estado de verificacion — lo que esta probado y lo que no

| Punto | Estado | Evidencia |
|---|---|---|
| El diagnostico no escribe jamas | **Verificado** | `tests/probar-diagnostico.sh`: ejecucion hermetica con canarios, comparacion antes/despues de lista de ficheros + hashes |
| El snapshot restaura de verdad | **Verificado** | `tests/probar-salvaguarda.sh`: extraccion a destino temporal y hashes restaurados identicos al manifiesto |
| El verificador rechaza lo que debe | **Verificado** | `tests/probar-verificar.sh`: 52 casos, incluidos sustitucion, borrado, adicion extra, fichero NO declarado (mundo cerrado), marca de anulacion estructural (bloque completo + fecha valida/delimitada), altas declaradas + anti-circularidad, y caso mixto |
| S3 estricto y la fecha son fuente unica | **Verificado** | `tests/probar-lib.sh`: `tm_s3_estado` por 4 formatos con asercion de VALOR + tabla de verdad de fecha (rangos y delimitacion, positivos y negativos) |
| El pipeline documentado es verificable extremo a extremo | **Verificado** | `tests/probar-escenarios.sh`: 3 escenarios (conflicto sin fecha, contradiccion fechada, duplicado+indice) con su contra-variante naive en ROJO |
| Las invariantes se consumen fail-closed | **Verificado** | `tests/probar-invariants.sh`: target ausente/patron invalido/MUST ausente/MUST_NOT presente → ROJO, con prueba de mutacion |
| Funciona fuera del repo de origen | **Verificado** | `tests/probar-standalone.sh`: solo la carpeta del skill, HOME limpio, 3 layouts, cero referencias a rutas internas |
| La metodologia repara corpus reales | **Verificado (en el corpus de origen)** | 7 pasadas completas sobre 379 notas reales, con auditoria y receipts |
| **Pasada completa sobre la memoria de un alumno real** | **NO VERIFICADA** | Los scripts se probaron contra `corpus-fake/`; nadie ha corrido aun el ciclo entero sobre una memoria ajena degradada. Cuando alguien lo haga, esta tabla se actualiza con lo que salga |
| **Compatibilidad efectiva en macOS** | **NO VERIFICADA** | Escrito contra bash + coreutils sin GNU-ismos a proposito, pero no se ha ejercitado en un macOS real |

## Fuera de alcance

Gestion de la ventana de contexto de la sesion (eso es `talent-context`, si lo tienes) ·
edicion del contenido tecnico de tus notas (el skill repara la ESTRUCTURA y la vigencia,
no reescribe tu conocimiento) · trackers e issues · shells que no sean bash (v1; el
flujo manual de `references/03` cubre el resto) · Windows nativo (via WSL si) ·
sincronizacion automatica entre maquinas · memoria de otros agentes que no sean Claude
Code (los patrones sirven, los layouts autodetectados no).

## Next Steps

- ¿Donde vive mi memoria y cuanto se degrado? → `references/01-donde-vive-y-diagnostico.md`
- ¿Como reparo sin perder nada? → `references/02-pipeline-de-reparacion.md`
- ¿Como me protejo antes y compruebo despues? → `references/03-salvaguardas-y-verificacion.md`
- ¿Como empiezo de cero, o compacto mi indice? → `references/04-establecer-y-optimizar.md`

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
