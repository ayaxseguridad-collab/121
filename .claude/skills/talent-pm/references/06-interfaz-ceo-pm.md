# 06 — Interfaz CEO ⇄ PM: contrapartes en la capa META

El PM y el CEO son **contrapartes**, no jerarquía: el PM optimiza que se construya LO CORRECTO;
el CEO, que la fábrica lo construya BIEN. Ninguno absorbe al otro. El lead conserva la
autoridad última sobre ambos.

## Table of Contents

- [Reparto de propiedad](#reparto-de-propiedad)
- [Doctrina del lead: el PM no puede ser un freno](#doctrina-del-lead-el-pm-no-puede-ser-un-freno)
- [Los dos modos de frenar](#los-dos-modos-de-frenar)
- [Triggers armados](#triggers-armados)
- [Los dos caminos](#los-dos-caminos)
- [Ciclo formal de apertura](#ciclo-formal-de-apertura)
- [Escalados](#escalados)
- [Artefactos del otro lado](#artefactos-del-otro-lado)

## Reparto de propiedad

| Del CEO (fábrica) | Del PM (producto) |
|---|---|
| Canales, estaciones, runners, despacho | La carga: cola priorizada y criterios de aceptación |
| Throughput, reciclaje, supervisión EN VUELO | Dictámenes de producto sobre planes/diseños/entregas |
| Gates del motor y su operación | Fronteras externas y contratos bilaterales |
| Asignación de encargos a canales | Interfaz de producto con el lead |
| Salud de la flota y de las cuentas | Intake, desbloqueos del lead, follow-ups del producto |

El PM no manda sobre canales ni estaciones; el CEO no define ni re-prioriza la carga. Cada uno
pregunta al otro lo del otro.

## Doctrina del lead: el PM no puede ser un freno

**El trabajo del PM es encargar los issues, atender las dudas del CEO cuando surjan, y revisar
que se entregan.** La supervisión de la ejecución en vuelo (canales, PRs en curso, estaciones)
es del CEO y su cadena — el anti-patrón **«PM-vigía»** (vigilar la ejecución ajena en vuelo)
está PROHIBIDO: duplica la supervisión del CEO, serializa lo paralelo y frena la fábrica.

- El PM mantiene la cola de encargos **por delante de la capacidad disponible que comunica el
  CEO** — sin cifras fijas: la capacidad es un dato VIVO del CEO, distinto en cada fábrica y en
  cada momento. Canales parados por falta de carga lista, habiendo trabajo prioritario
  ejecutable, son un fallo del PM.
- Cero ociosidad, cualificada: jamás inventar carga para mantener utilización — la ociosidad
  que se combate es la causada por falta de encargos LISTOS, no la ausencia de actividad.
- Mientras el PM revisa una entrega, **el CEO sigue ejecutando los demás encargos
  independientes sin esperar**: la revisión de una entrega jamás detiene el resto del flujo.
- Los puntos de contacto del PM con la ejecución son EXACTAMENTE: el encargo (antes), las dudas
  del CEO (durante, BAJO DEMANDA del CEO), la entrega (después), y los gates del camino
  excepcional (solo donde estén reservados por escrito).

## Los dos modos de frenar

La doctrina anterior tiene dos modos de violarse, y el PM debe gobernar ambos: **vigilando**
(el PM-vigía ya descrito) y **tardando** — reteniendo la línea con la latencia de sus propias
verificaciones, dictámenes y acuses. Adjudicación del lead (2026-07-30): el PM no puede
ralentizar la fábrica **ni vigilando ni tardando**. El primer modo se corrige no mirando; el
segundo, con régimen de caudal — disponibilidad declarada, checklist precargado, ráfagas y
parqueo (`07`, íntegra). El tiempo que la fábrica pasa esperando al PM es métrica de fallo del
PM, no coste natural del rigor.

## Triggers armados

El mecanismo que compatibiliza «no-freno» con la verificación del PM: el PM no vigila la
ejecución — **declara disparadores por evento** y queda pasivo hasta que el evento ocurre.
Forma canónica: «al fundir X → verifico Y» · «al entregarse una superficie reservada → dictamen
al-caer» · «al completarse la palanca → libero la cadena dependiente». El CEO releva el evento
cuando ocurre; el PM ejecuta el trigger en el turno, con su checklist ya precargado (`07`). La
lista de triggers armados es viva y visible para ambos.

Diferencia estructural con el PM-vigía: el vigía consume atención continua y serializa lo
paralelo; el trigger es pasivo hasta su evento, no retiene nada que no esté declarado, y su
coste de verificación se pagó por adelantado.

## Los dos caminos

- **Ordinario (el DEFAULT del trabajo diario)**: encargo por tanda → **ejecución AUTÓNOMA del
  CEO** (despacho, gates del motor, merge por su circuito) → dudas bajo demanda → entrega →
  **revisión del PM sobre lo entregado**. Sin permisos intermedios: el CEO no espera al PM para
  despachar, fundir ni encadenar encargos de la tanda.
- **Excepcional (reservado por escrito)**: gate previo del PM o del lead ÚNICAMENTE en las
  superficies que la frontera de delegación reserva (ver `04` — dinero, producción, recursos
  compartidos y las demás que el lead haya listado). La reserva vive por escrito; lo no
  reservado es ordinario. La única reserva por defecto del PM: diseño-antes-que-código en
  superficies de dinero, datos compartidos y fronteras con terceros (ver `02`).

## Ciclo formal de apertura

El ciclo intake → acuse por secciones → plan de arranque → pre-revisión → GO inaugural del lead
ocurre UNA vez por fábrica (o al abrir una fase mayor). **No es un patrón por-issue**: el acuse
del intake y la pre-revisión del plan de arranque abren el flujo ordinario, y desde ahí el CEO
opera en autonomía dentro de la frontera pactada. Reabrir el ciclo completo exige un cambio de
fase real (retarget, fase nueva del producto, cambio de frontera), no un encargo más.

## Escalados

- **CEO → PM**: dudas de producto, criterios ambiguos, hallazgos que exceden el encargo,
  bloqueos de material o decisión. El PM responde en el turno — una duda del CEO esperando es
  fábrica parada.
- **PM → CEO**: defectos sistémicos detectados en entregas (patrones, no casos), cambios de
  carga o prioridad, contratos nuevos que afecten encargos futuros.
- **Ambos → lead**: solo decisiones reservadas o conflictos de frontera que las contrapartes no
  resuelven — con recomendación conjunta cuando exista.

## Artefactos del otro lado

El PM puede LEER los artefactos de la fábrica (briefs, regímenes, expedientes del CEO) para
pre-revisión y contexto — en solo-lectura: JAMÁS los edita. Los cambios se piden al CEO por el
canal. Simétricamente, el CEO lee la carga y sus criterios pero no los reescribe: pide el
cambio al PM.
