<!-- issue-craft:v1 type=test variant=none madurez=despachable -->
<!-- Plantilla 06-test · variantes: none (único token admitido para este tipo) -->
<!-- Defaults del tracker: etiqueta de tipo "test" · estimate 2-4 · prioridad según ventana · calibre gold: 4-10k chars -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: qué comportamiento valioso está hoy sin red, qué regresión ya ocurrió o estuvo cerca, qué protege esta suite.]
**Origen**: [link adjunto — regresión / hallazgo de revisión / decisión con fecha. El detalle vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[comando de la suite vecina]` → [verde, N tests]
  - `[búsqueda de cobertura del símbolo/flujo en los directorios de tests]` → [0 — la red falta]

## Anclas de contexto

- `[ruta/al/codigo-a-cubrir:L1-L2]` — el comportamiento que se fija (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/al/spec-patron]` — el spec canónico a REPLICAR (estructura, helpers, naming)

## Alcance

### Incluye

- [casos T1-TN de la lista cerrada de abajo — nada más]
- [fixtures/dobles de prueba necesarios]
- [cableado de la suite al comando de checks del repo, si falta]

### Fuera de alcance

- ❌ [comportamiento vecino ya aseverado] → [suite dueña]
- ❌ [comportamiento sin red que no entra en esta pasada] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. nivel de la suite (unitaria/integración), ubicación] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [paths de specs nuevos + fixtures/dobles]
- El código de producción NO se toca: si cubrir un caso exige cambiarlo, es un hallazgo que se escala, no un edit.

## Invariantes que NO deben cambiar

- [suites existentes: verdes, sin renombres ni reordenaciones] — lo prueba: [comando de la suite completa]
- [el código bajo prueba queda intacto] — lo prueba: diff-scope de la PR (solo tests/fixtures)

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Prueba de que la red falta

- `[comando de búsqueda de cobertura]` → 0 resultados (corrido y pegado, no asumido)
- Distinguir el caso real: ¿NO EXISTE ningún test, o EXISTE pero no está cableado a la suite que corren los checks? [respuesta con evidencia — path del spec huérfano y comando que lo ignora, si aplica]

## Casos a cubrir (lista cerrada, anti-glob)

| # | Caso | Fixture/entrada concreta | Por qué este caso |
|---|---|---|---|
| T1 | [camino feliz del contrato] | [dato/estado concreto] | [fija el contrato principal] |
| T2 | [negativo: denegación/rechazo] | [dato concreto] | [protege el fail-closed] |
| T3 | [borde: vacío/límite/repetición] | [dato concreto] | [regresión ya vista u observada cerca] |

Por qué una lista CERRADA y no un glob/barrido genérico: [razón — un barrido no fija contratos: produce tests que pasan por casualidad, fallan por ruido y nadie sabe qué protegen. Cada caso de arriba tiene una razón nombrada.]

## Deslinde de suites vecinas

| Comportamiento excluido | Suite/issue dueña |
|---|---|
| [X, ya aseverado por la suite existente] | [path de la suite] |
| [Y, pendiente de red propia] | [issue destino] |

Sin solape declarado: ningún caso de la lista cerrada duplica aserciones de una suite vecina.

## Determinismo y hermeticidad

- Dobles de prueba para TODO servicio externo — nunca la API real (tampoco "solo en local").
- Sin red: la suite pasa desconectada; sin credenciales → skip limpio y explícito, nunca fallo.
- Sin dependencia de reloj, orden de ejecución ni estado compartido: [reloj fijo, datos propios por test, limpieza al cerrar]
- 2 corridas consecutivas → resultado idéntico (evidencia exigida en el DoD).

## Criterios de aceptación / DoD

- [ ] `[comando de la suite nueva]` → verde, [N] tests nuevos (cobertura 1:1 con la lista T1-TN)
- [ ] CRITERIO POR MUTACIÓN (obligatorio del tipo): mutación deliberada del código cubierto → el test nuevo en ROJO; revertida → verde. AMBAS salidas pegadas. Un test que no falla ante la mutación no es red, es decoración.
- [ ] 2 corridas consecutivas de la suite nueva → salida idéntica (determinismo)
- [ ] `[comando de las suites del repo]` → verde (cero regresión en suites vecinas)
- [ ] Diff toca SOLO tests/fixtures/dobles (verificado sobre la PR)

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Mutación | ambas salidas literales: ROJO con la mutación aplicada + verde tras revertirla |
| Determinismo | salidas de las 2 corridas consecutivas |
| [resto de checkboxes] | salida literal sobre el commit final / run de checks |

## Brief del ejecutor

- Conocimiento previo a cargar: [guía de tests del repo según artefactos tocados]
- Patrón a REPLICAR: `[ruta/al/spec-patron]` (prohibido inventar estructura nueva)
- Límites duros: NO tocar código de producción; NO añadir dependencias; NO ampliar la lista cerrada de casos; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M1, M2 + S5 + O8 + Q8 · Matrices: — (los tests no activan matriz de superficie: son la red, no el cambio)
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: la lista cerrada se cubre completa y NADA más; el plan de mutación nombra QUÉ se muta y qué test debe enrojecer
- Revisor de código: 5 dimensiones §8 — extra del tipo: criterio por mutación con ambas salidas + determinismo (2 corridas idénticas) + deslinde respetado (cero aserciones duplicadas)
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR) — (si esta pieza
  va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y
  `talent-merger` ref 09; nunca PR individual)
- Post-fusión: [pasos si aplican — p. ej. confirmar que la suite corre en el gate del repo]
- PARAR y escalar si: [cubrir un caso exige tocar código de producción / el doble no puede reproducir la condición]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Prueba de que la red falta (lo diferencial del tipo): búsqueda del módulo de
  reglas de acceso en los directorios de tests → 0; existía además un spec huérfano
  NO cableado al comando del gate — se cablea en esta issue y se declara en Incluye.
  Casos (lista cerrada): T1 concesión con datos válidos · T2 denegación a un usuario
  ajeno (fail-closed) · T3 doble ejecución con resultado idéntico (idempotencia).
  Mutación: se invierte la condición de denegación → T2 en ROJO; revertida → verde;
  ambas salidas pegadas en la entrega. 2 corridas consecutivas → salida idéntica.

  Por qué es gold: distingue "no existe" de "existe sin cablear", cada caso tiene
  razón nombrada (anti-glob), el deslinde evita duplicar aserciones vecinas y la
  mutación DEMUESTRA que la red detecta — sin eso, el test es decoración.
-->
