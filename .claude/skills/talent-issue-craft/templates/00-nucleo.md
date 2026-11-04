# 00 — Núcleo Canónico

Canon narrativo del núcleo común a las 9 plantillas de tipo. Las plantillas `01`-`09` son AUTOSUFICIENTES: cada una integra este núcleo completo + su overlay. Este archivo es la referencia de autoría y mantenimiento; la doctrina extendida vive en `references/01-nucleo-y-despachabilidad.md`.

## Cláusulas obligatorias (fuente machine-readable)

El bloque siguiente define las cláusulas que DEBEN aparecer literalmente en las 9 plantillas (salvo excepción declarada en `nucleo-manifest.txt` con formato `EXCEPT <basename>:<cláusula>`). La paridad la fuerza `scripts/check_nucleo_parity.sh` en tres frentes: canon↔manifest (bidireccional) y manifest→plantillas. Cualquier deriva → exit ≠ 0.

<!-- nucleo-clausulas:begin -->

```text
<!-- issue-craft:v1
## Contexto y origen
## Baseline verificado
## Anclas de contexto
## Alcance
### Fuera de alcance
## Decisiones
GATE DE DESPACHO: cero decisiones abiertas sin régimen.
## Artefactos tocados
## Invariantes que NO deben cambiar
## Criterios de aceptación / DoD
## Evidencias de cierre exigidas
## Brief del ejecutor
Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
## Rúbricas de revisión aplicables
## Protocolo de cierre
```

<!-- nucleo-clausulas:end -->

## Esqueleto canónico completo

```markdown
<!-- issue-craft:v1 type=<tipo> variant=<token> madurez=despachable -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen
[2-4 frases: por qué, a quién le duele, qué valor entrega.]
**Origen**: [link adjunto — PR / hallazgo / propuesta de usuario / decisión con fecha.
El detalle de toda decisión de persona se traslada AQUÍ, nunca "según lo acordado".]

## Baseline verificado (AAAA-MM-DD)
- Rama/commit de referencia: `<sha>` [+ estado de la base de datos si aplica]
- Arranque verificado (correr ANTES de planificar):
  - `comando 1` → salida esperada

## Anclas de contexto
- `ruta/archivo.ext:L1-L2` — [qué es] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `ruta/patron-a-replicar.ext` — el ejemplo canónico a imitar

## Alcance
### Incluye
- [lista cerrada de entregables]
### Fuera de alcance
- ❌ X → [issue destino] (cada exclusión con destino explícito)

## Decisiones
### Selladas
| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
### Diferidas (deliberadamente)
| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|
### No se decidirá
| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados
- [paths/recursos que este trabajo modifica]

## Invariantes que NO deben cambiar
- [comportamiento/contrato] — lo prueba: [suite/spec concreta]
- [decisión ya integrada que se respeta] — referencia: [PR/commit]

## Contratos cross-pieza (si va en tren)
- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

═══ [OVERLAY DEL TIPO — ver plantilla 01-09 correspondiente] ═══

## Criterios de aceptación / DoD
- [ ] `comando` → salida esperada   (ejecutable, acotado EXACTAMENTE al alcance)

## Evidencias de cierre exigidas
| Criterio | Evidencia requerida |
|---|---|
| [cada checkbox] | salida literal sobre el commit final / captura / run de checks |

## Brief del ejecutor
- Conocimiento previo a cargar: [guías/docs según artefactos tocados]
- Patrón a REPLICAR: `ruta/ejemplo` (prohibido inventar estructura nueva)
- Límites duros: NO tocar [X]; NO añadir dependencias; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables
- Baterías activas: [M / S / O / Q según tipo] · Matrices: [FRONT / DB / API / Contenido según superficie]
- Revisor de plan: rúbrica canónica (`references/02-verificaciones.md` §7) [+ extras del tipo]
- Revisor de código: 5 dimensiones (`references/02-verificaciones.md` §8) [+ extras del tipo]
- Checks adicionales específicos de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre
- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: [PR + revisión + fusión (default) | cierre manual con evidencia]
- Post-fusión: [pasos si aplican]
- PARAR y escalar si: [condiciones]
```

## Forma `placeholder` (horizonte lejano)

```markdown
<!-- issue-craft:v1 type=<tipo> variant=<token> madurez=placeholder -->
[Problema en 1-2 líneas. Valor en 1 línea. Origen: link.]
<!-- PROHIBIDO detalle caro (DoD/paths/criterios/plan). Se completa la plantilla del tipo al entrar en ventana de despacho. -->
```

## Guía de mantenimiento del núcleo

Cambiar el núcleo = editar **en el MISMO cambio**: (1) este canon (bloque delimitado + esqueleto), (2) `nucleo-manifest.txt`, (3) las 9 plantillas `01`-`09`. El gate `scripts/check_nucleo_parity.sh` lo fuerza: deriva canon↔manifest o manifest→plantillas → exit ≠ 0. Las excepciones por tipo se declaran SOLO en el manifest (`EXCEPT <basename>:<cláusula>`) y deben ser deliberadas y pocas.
