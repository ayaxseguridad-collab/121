<!-- issue-craft:v1 type=feat variant=none madurez=despachable -->
<!-- Plantilla 01-feat · variantes: none | db (si toca esquema/migraciones: variant=db y completar el Bloque DB) -->
<!-- Defaults del tracker: etiqueta de tipo "feat" · estimate 2-5 · prioridad según ventana · calibre gold: 3-9k chars -->

# {Imperativo} {qué} ({dónde})

## Contexto y origen

[2-4 frases: por qué existe esta capacidad, a quién le sirve, qué valor entrega.]
**Origen**: [link adjunto — propuesta de usuario / decisión con fecha / roadmap. El detalle de la decisión vive AQUÍ.]

## Baseline verificado (AAAA-MM-DD)

- Rama/commit de referencia: `<sha>`
- Arranque verificado (correr ANTES de planificar):
  - `[comando que demuestra el estado actual]` → [salida esperada]

## Anclas de contexto

- `[ruta/al/punto-de-integracion:L1-L2]` — [qué es] (extracto mínimo abajo)
  > [3-8 líneas literales]
- `[ruta/al/componente-o-modulo-patron]` — el ejemplo canónico a REPLICAR

## Alcance

### Incluye

- [entregable 1 — lista cerrada]

### Fuera de alcance

- ❌ [X] → [issue destino]

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| [p. ej. texto del CTA, regla de visibilidad] | [valor] | [persona] | [fecha] |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- [paths de UI/lógica/config que se modifican]

## Invariantes que NO deben cambiar

- [flujo vecino que queda INTACTO] — lo prueba: [suite/spec concreta]
- [decisión ya integrada que se respeta] — referencia: [PR/commit]

## Contratos cross-pieza (si va en tren)

- [SI_VA_EN_TREN: dueño de símbolo compartido — UNA pieza dueña, las demás consumen; qué SELLA
  y qué SUPERSEDE; slot propuesto a renumerar contra ledger∪main∪drafts. Si NO va en tren:
  "N/A — no va en tren".]

## Contrato de comportamiento

| # | Caso | Comportamiento esperado |
|---|---|---|
| C1 | [caso principal] | [qué ve/puede hacer el usuario] |
| C2 | [caso negativo] | [p. ej. "sin permiso → mensaje neutro, NUNCA error crudo"] |
| C3 | [interacción con features vecinas] | [p. ej. "el bloqueo existente por prerequisito queda INTACTO"] |
| C4 | [fail-closed] | [sin config/flag → comportamiento seguro por defecto] |

## Archivos y patrón

- Componente/módulo base a imitar: `[ruta]` (introducido en [PR/issue])
- Puntos de integración: [rutas, endpoints, tablas]

### Bloque DB (SOLO variant=db — si no aplica, eliminar esta subsección)

- Migración: `[slot/timestamp]_nombre_descriptivo.sql` — verificar numeración libre contra la fuente de verdad viva JUSTO antes de crear
- Patrón de función/procedimiento de referencia: [migración ejemplo del repo]
- Seguridad de datos: [políticas de acceso a nivel de fila en tablas nuevas; permisos mínimos con revocación/concesión explícita; mutaciones sensibles nunca con credenciales administrativas desde contexto de usuario]
- Post-fusión: aplicar a producción + validaciones del motor, según el protocolo del perfil del repo

## Criterios de aceptación / DoD

- [ ] `[comando]` → [salida esperada] (uno por entregable del alcance — cobertura 1:1)
- [ ] Contrato C1-C4 verificado caso a caso (incluidos los negativos)
- [ ] [Si toca UI] Matriz FRONT completa: navegador real escritorio ≥1280px y móvil ~375px con capturas; estados cargando/error/vacío/éxito; teclado+focus; todos los idiomas del producto; tema claro/oscuro si existe
- [ ] [Si variant=db] Matriz DB completa: tests de BD (incl. negativo de acceso), validaciones post-aplicación, registro de migraciones al día

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| [cada checkbox] | salida literal sobre el commit final / capturas / run de checks |

## Brief del ejecutor

- Conocimiento previo a cargar: [guías del repo según artefactos tocados]
- Patrón a REPLICAR: `[ruta]` (prohibido inventar estructura nueva)
- Límites duros: NO tocar [X]; NO añadir dependencias; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: [el declarado en el perfil del repo].

## Rúbricas de revisión aplicables

- Baterías activas: M + S + O + Q · Matrices: FRONT y/o API según superficie [+ DB si variant=db]
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan cubre el contrato C1-C4 caso a caso, incluidos negativos y fail-closed
- Revisor de código: 5 dimensiones §8 — extra del tipo: matriz FRONT/DB al completo según superficie
- Checks adicionales de ESTA issue: [lista o "ninguno"]

## Protocolo de cierre

- Checks requeridos: [los del perfil del repo]
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR) — (si esta pieza
  va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y
  `talent-merger` ref 09; nunca PR individual)
- Post-fusión: [pasos si aplican — p. ej. aplicar migración según perfil]
- PARAR y escalar si: [condiciones — p. ej. el contrato exige un dato que no existe]

---

<!-- EJEMPLO GOLD CONDENSADO (anatomía real anonimizada; borrar al usar la plantilla):

  Contrato de comportamiento (lo diferencial del tipo):
  | C1 | usuario con plan básico visita una sección premium | CTA con el texto del gap
       ("Esta sección es del plan Pro") + link con tracking `?from=` |
  | C2 | usuario sin sesión | redirección al login actual — INTACTA, sin CTA |
  | C3 | bloqueo por prerequisito pedagógico existente | comportamiento actual INTACTO
       (no ofrecer compra de lo que se desbloquea solo) |
  | C4 | venta desactivada por config | SIN CTA de compra, mensaje neutro (fail-closed) |

  Por qué es gold: cada caso es verificable en navegador; los negativos protegen los
  flujos vecinos (invariantes) y el fail-closed evita vender en estados inválidos.
-->
