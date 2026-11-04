# Núcleo y Despachabilidad — Referencia Completa

Doctrina central del skill: qué hace excelente una issue, el marcador de clasificación, los bloques del núcleo, el eje de madurez, los orígenes tipificados y los gates que separan una idea de una tarea despachable a un agente ejecutor.

## Table of Contents

1. [Los tres lectores de una issue](#1-los-tres-lectores-de-una-issue)
2. [El marcador issue-craft:v1 (autoridad de clasificación)](#2-el-marcador-issue-craftv1-autoridad-de-clasificación)
3. [La matriz type × variant](#3-la-matriz-type--variant)
4. [El núcleo: bloques obligatorios](#4-el-núcleo-bloques-obligatorios)
5. [Eje de madurez: placeholder vs despachable](#5-eje-de-madurez-placeholder-vs-despachable)
6. [Orígenes tipificados](#6-orígenes-tipificados)
7. [Gate de despachabilidad (Backlog → lista de trabajo)](#7-gate-de-despachabilidad-backlog--lista-de-trabajo)
8. [Elegibilidad del gate operativo: clasificación ≠ evidencia](#8-elegibilidad-del-gate-operativo-clasificación--evidencia)
9. [Loop post-rechazo (iteración de las plantillas)](#9-loop-post-rechazo-iteración-de-las-plantillas)
10. [Gotchas & Cross-References](#10-gotchas--cross-references)

---

## 1. Los tres lectores de una issue

Una issue estado-del-arte para ejecución agéntica tiene **tres lectores**, y se escribe para los tres a la vez:

```text
┌────────────────────┐   ┌──────────────────────┐   ┌───────────────────────┐
│ AGENTE EJECUTOR     │   │ REVISOR DE PLAN       │   │ REVISOR DE CÓDIGO      │
│ Necesita contexto   │   │ Necesita una rúbrica  │   │ Necesita una rúbrica   │
│ autosuficiente,     │   │ objetiva: qué debe    │   │ por dimensión + las    │
│ patrón a replicar,  │   │ DEMOSTRAR el plan     │   │ evidencias exigibles,  │
│ límites duros y     │   │ para merecer GO       │   │ para que el NO-GO sea  │
│ cero decisiones     │   │                       │   │ verificable, no opinión│
│ abiertas            │   │                       │   │                        │
└────────────────────┘   └──────────────────────┘   └───────────────────────┘
```

**Regla de oro**: si un criterio de calidad no está escrito en la issue (o referenciado a una rúbrica canónica del skill), el revisor no puede exigirlo objetivamente y el ejecutor no lo va a inferir. Todo lo auditable se declara.

**Regla de peso**: longitud ≠ calidad. En un corpus real de ~2000 issues, las issues más largas (13-30k caracteres) fueron rechazadas en revisión igual que las cortas. Lo que previene el rechazo son los campos duros (decisiones selladas, invariantes nombradas, DoD ejecutable acotado, artefactos tocados), no la prosa. La issue declara datos y triggers; la doctrina pesada vive en el skill y se referencia.

---

## 2. El marcador issue-craft:v1 (autoridad de clasificación)

Toda issue creada con este skill abre su descripción con una línea machine-readable:

```markdown
<!-- issue-craft:v1 type=feat variant=none madurez=despachable -->
```

**Sintaxis** (los tres campos son obligatorios):

| Campo | Valores | Notas |
|-------|---------|-------|
| `type` | uno de los 9 tokens de la matriz (§3) | fijo por plantilla |
| `variant` | token permitido para ese `type` según la matriz; `none` explícito cuando no hay variante | la AUSENCIA del campo = marcador malformado |
| `madurez` | `placeholder` \| `despachable` | ver §5 |

**Por qué un marcador en el body y no las etiquetas del tracker**: las etiquetas históricas de un equipo casi nunca son biyectivas con esta taxonomía (una issue de operación de datos puede llevar etiqueta "chore"; una de seguridad, etiqueta "fix" a secas). El marcador viaja con el body, es independiente de la configuración del tracker y de que existan plantillas nativas, y **persiste en sistemas que conservan comentarios Markdown/HTML** (comprobado en Linear; no se afirma para cualquier tracker). Las etiquetas quedan como cross-check 🟡: una discrepancia etiqueta↔marcador es señal para revisar, nunca autoridad.

**Semántica fail-closed**: para el auditor (`scripts/issue_craft_helper.ts`, acción `audit-issue`), el marcador es la ÚNICA autoridad de clasificación en modo operativo, y es **unívoca y posicional**: EXACTAMENTE UN marcador en todo el body, y debe ser la PRIMERA línea completa. Texto antes del marcador (tardío), dos marcadores (ambigüedad), ausente, malformado o con tokens fuera de la matriz → **exit ≠ 0**, sin evaluar nada más.

**Anti-esqueleto (duros de forma poblada)**: los headings del núcleo no bastan — el auditor exige forma machine-readable REAL en los campos duros: régimen de decisiones poblado (≥1 fila de datos en las tablas, o declaración explícita de ausencia), ≥1 artefacto/path real (con `/` o `.` entre caracteres de palabra), ≥1 invariante con su suite/comando ("lo prueba:" / "referencia:") y tabla de evidencias poblada. Los **valores centinela NO cuentan** como contenido real (lista cerrada del auditor: "N/A", "ninguno/a", "TBD", "todo", "pendiente", "ok", "sí/no", "x", "-", "true/false") — una carcasa con todos los headings y relleno centinela NO supera el gate, ni siquiera con evidencia remota completa. Para auditar issues históricas (anteriores al skill) existe el modo override (`--type`/`--variant`), que fija la clasificación de esa corrida y queda registrado en la salida como `classification_source=override` — el override sirve para calibración y auditoría histórica, nunca satisface el gate operativo (§8).

---

## 3. La matriz type × variant

Tokens ASCII literales, sin acentos. Toda combinación fuera de esta matriz es INVÁLIDA y el auditor la rechaza (fail-closed):

| `type` | `variant` permitidos | Combinaciones |
|--------|----------------------|---------------|
| `feat` | `none` · `db` | 2 |
| `fix` | `none` · `seguridad` · `sev1` · `seguridad+sev1` | 4 |
| `chore` | `none` · `doc-vivo` | 2 |
| `db-ops` | `none` | 1 |
| `refactor` | `none` | 1 |
| `test` | `none` | 1 |
| `docs-adr` | `none` | 1 |
| `spike-auditoria` | `none` | 1 |
| `contenido-datos` | `none` | 1 |

**Total: 14 combinaciones válidas.**

Semántica de las variantes:

- `feat/db` — la feature toca esquema o migraciones de base de datos: se activa el bloque DB de la plantilla `01-feat` y la matriz de superficie DB (`02-verificaciones.md`).
- `fix/seguridad` — el defecto toca autenticación, permisos, pagos, credenciales o datos personales: batería de exploit (cadena completa, severidad razonada, test negativo, referencia a debilidad estándar).
- `fix/sev1` — producción degradada o caída: forma compacta con forense del origen, fix mínimo con radio de impacto y smokes en tres capas (incluida producción post-despliegue).
- `fix/seguridad+sev1` — incidente urgente DE seguridad (solo en ese orden literal): aplica la **UNIÓN de ambas baterías**. La forma compacta de sev1 se permite en la prosa, pero NINGÚN duro de seguridad se omite.
- `chore/doc-vivo` — el artefacto es doctrina que otros ejecutarán (guías operativas, playbooks, skills): inventario con cifras, tabla Declarado|Vigente|Fuente|Impacto, "Qué NO tocar", DoD espejo y fuentes de verdad con fecha.

La tabla de routing de `SKILL.md` mapea las 14 combinaciones a su plantilla y trigger. `list-types` del helper imprime esta matriz.

---

## 4. El núcleo: bloques obligatorios

Los bloques comunes a los 9 tipos, en su orden canónico. La fuente normativa machine-readable de las cláusulas vive en `templates/00-nucleo.md` (bloque delimitado) y `templates/nucleo-manifest.txt`; el gate `scripts/check_nucleo_parity.sh` fuerza la paridad con las 9 plantillas.

### 4.1 Título

`{Imperativo} {qué} ({dónde})` — o la convención `tipo(área): …` si el repo la usa. Nunca "Bug en X" ni "problema con Y": el título describe el resultado, no el síntoma.

### 4.2 Contexto y origen

2-4 frases: por qué existe la tarea, a quién le duele, qué valor entrega. **Origen enlazado**: link (como adjunto del tracker, no solo texto) a lo que la parió — PR, hallazgo de revisión, propuesta de usuario, decisión con fecha. Si la decisión vino de una persona, el DETALLE se traslada al body — nunca "según lo acordado" con el acuerdo viviendo fuera.

### 4.3 Baseline verificado

```markdown
## Baseline verificado (AAAA-MM-DD)
- Rama/commit de referencia: `<sha>` [+ estado de la base de datos si aplica]
- Arranque verificado (correr ANTES de planificar):
  - `comando 1` → salida esperada
  - `comando 2` → salida esperada
```

El autor de la issue CORRIÓ esos comandos al escribirla; el ejecutor los re-corre al arrancar. Un baseline asumido y no verificado es la semilla clásica del "trabajé sobre una base que ya no existía".

### 4.4 Anclas de contexto

Paths:líneas exactos + extractos mínimos embebidos del código/config relevante:

```markdown
## Anclas de contexto
- `ruta/al/archivo.ext:120-134` — la función que valida X (extracto abajo)
  > [3-8 líneas literales del código relevante]
- `ruta/al/patron-a-replicar.ext` — el ejemplo canónico a imitar
```

El objetivo: que el ejecutor no gaste esfuerzo re-descubriendo contexto que el autor ya tenía delante. Un ancla desactualizada se detecta en el arranque (el extracto no coincide) → escalada con citas, no improvisación.

### 4.5 Alcance

```markdown
## Alcance
### Incluye
- [entregable 1, entregable 2 — lista cerrada]
### Fuera de alcance
- ❌ X → [issue destino] (cada exclusión con destino explícito, no "después")
```

### 4.6 Decisiones (régimen de 3 estados)

```markdown
## Decisiones
### Selladas (ya tomadas)
| Parámetro | Valor | Quién decidió | Fecha |

### Diferidas (se decidirán más tarde — deliberadamente)
| Decisión | Quién decidirá | Cuándo / trigger | ¿Bloquea? | Default mientras tanto |

### No se decidirá (cerradas sin decidir)
| Cuestión | Por qué no se decide | Registrado por |

GATE DE DESPACHO: cero decisiones abiertas sin régimen.
```

Lo prohibido no es diferir — es la **decisión huérfana** (sin dueño, sin trigger, sin régimen de bloqueo) que el ejecutor acaba resolviendo por su cuenta a mitad de vuelo. Reglas por columna `¿Bloquea?` de las diferidas:

| Valor | Consecuencia |
|-------|--------------|
| Bloquea TODO | La issue NO es despachable. Se crea una issue-decisión asignada a quien decide y esta queda relacionada como bloqueada por ella. La decisión tiene dueño que la empuja — nunca bloqueo silencioso. |
| Bloquea una PARTE | Esa parte SALE del alcance a una issue hija bloqueada; el resto despacha ya. El recorte queda en "Fuera de alcance → [hija]". |
| No bloquea | Despachable: el diseño aísla la decisión tras un **default seguro** (config/valor provisional fail-safe). El ejecutor implementa el default tal cual; cuando llegue la decisión, cambiarla es dato/config, no código. |

La tabla "No se decidirá" cierra explícitamente cuestiones que alguien podría reabrir ("¿y no deberíamos también…?" → "registrado: no, por Y") — es el "fuera de alcance" a nivel decisión.

### 4.7 Artefactos tocados

Lista de paths/recursos que el trabajo modifica. Doble función: (a) permite detectar colisiones con trabajo en vuelo ANTES de despachar en paralelo (dos issues activas tocando el mismo archivo se pisan en la fusión); (b) acota el diff-scope que el revisor de código verifica literalmente.

### 4.8 Invariantes que NO deben cambiar

```markdown
## Invariantes que NO deben cambiar
- [Comportamiento/contrato existente] — lo prueba: [suite/spec/test concreto]
- [Decisión ya integrada que esta tarea respeta] — referencia: [PR/commit]
```

En el corpus analizado, los dos rechazos más caros fueron regresiones de comportamiento que la rama principal tenía en verde — porque la issue nunca nombró la invariante ni la suite que la protege. Nombrarlas convierte "no romper nada" (inauditable) en "estas suites siguen verdes" (comando).

### 4.9 Criterios de aceptación / DoD + Evidencias

```markdown
## Criterios de aceptación / DoD
- [ ] `comando` → salida esperada   (ejecutable, acotado EXACTAMENTE al alcance)

## Evidencias de cierre exigidas
| Criterio | Evidencia requerida |
|----------|---------------------|
| [cada checkbox] | salida literal del comando sobre el commit final / captura / run de checks |
```

Dos reglas duras: **(a)** cada criterio es ejecutable por comando con salida esperada — "que funcione bien" no existe; **(b)** el DoD se acota EXACTAMENTE al alcance — un "grep global → 0" que contradice un alcance parcial hace la issue imposible de cumplir (caso real del corpus). Anti-autoreporte: la evidencia se produce sobre el commit exacto que se entrega, nunca se declara sin correr.

### 4.10 Brief del ejecutor

```markdown
## Brief del ejecutor
- Conocimiento previo a cargar: [guías/docs/skills según artefactos tocados]
- Patrón a REPLICAR: `ruta/al/ejemplo-existente` (prohibido inventar estructura nueva)
- Límites duros: NO tocar [X], NO añadir dependencias, NO resolver decisiones no selladas.
- Presupuesto de cambio: ~N archivos / ~M líneas. Si se excede 2×: replantear, no seguir.
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con
  citas verificables — nunca fabricar cumplimiento. Destinatario de la escalada: el
  declarado en el perfil del repo.
```

La cláusula de **escalada-con-citas** es el seguro contra el peor modo de fallo agéntico: un ejecutor que "hace pasar" una spec incorrecta fabricando la apariencia de cumplimiento. Escalar con citas (path:línea, salida de comando) convierte la contradicción en dato accionable para el autor de la issue.

### 4.11 Rúbricas de revisión

La issue declara qué baterías y matrices de `02-verificaciones.md` aplican (por el par type/variant + triggers de superficie) y cualquier check adicional específico de la tarea. Las definiciones canónicas viven en el skill — una sola vara para todos los revisores; la issue no las repite.

### 4.12 Protocolo de cierre

Checks requeridos (los del perfil del repo) · régimen de cierre (default: "PR + revisión + fusión"; cierre manual con evidencia para operaciones sin PR; **cierre por tren padre** — la issue de una pieza de tren se cierra vía el `closes` del PR padre, nunca en un PR propio, ver `talent-merger` ref 09) · pasos post-fusión si aplican · condiciones de PARAR-y-escalar.

---

## 5. Eje de madurez: placeholder vs despachable

| Grado | Cuándo | Contenido permitido |
|-------|--------|---------------------|
| `placeholder` | Trabajo de horizonte lejano | MÁXIMO 5 líneas: problema + valor + enlace al origen. PROHIBIDO el detalle caro (DoD, paths, criterios, plan) |
| `despachable` | Entra en ventana de ejecución | Plantilla completa del tipo, gate de despachabilidad superado |

**Evidencia que justifica el eje**: en el corpus analizado, ~78% de las issues canceladas fueron una purga en bloque de specs detalladísimas escritas meses antes para hitos que pivotaron. El detalle caro se escribe SOLO al entrar en ventana de despacho; antes, es inventario que caduca.

---

## 6. Orígenes tipificados

Los orígenes no son tipos — son entradas. Cada uno trae una regla anti-desperdicio medida en corpus real:

| Origen | Regla al crear | Evidencia |
|--------|----------------|-----------|
| **Propuesta de usuario** | Dedupe contra el backlog vivo OBLIGATORIO antes de crear (buscar por título, descripción y comentarios); luego convertir al tipo que corresponda. Si el tracker soporta solicitudes de cliente (p. ej. Customer Requests de Linear), la propuesta cruda vive ahí, enlazada | ~19% de las duplicadas de un corpus real nacieron de ingesta sin cruce |
| **Hallazgo de revisión/auditoría** | Agrupar por VEHÍCULO de implementación (mismos archivos = misma issue), nunca una issue por hallazgo | 77% de las duplicadas fueron hallazgos atomizados que luego hubo que consolidar |
| **Follow-up de rechazo** | Estructura mínima obligatoria aunque sea urgente: contexto con enlace al origen + alcance en paths + ≥1 criterio verificable | La franja más reciente del corpus degradó a stubs de ~500 caracteres con 3% de DoD |
| **Decisión de responsable / roadmap** | Las decisiones se TRASLADAN al body (tabla completa), nunca "condiciones 1-4 incorporadas" con el detalle viviendo en otra parte | 3 de 16 rechazos de fábrica fueron decisiones resueltas por comentario a mitad de vuelo |

---

## 7. Gate de despachabilidad (Backlog → lista de trabajo)

Checklist que la issue supera ANTES de entrar a la lista de trabajo (el mapeo a estados del tracker vive en `03-linear-nativo.md`; el momento exacto en que se corre lo declara el perfil del repo — ver escalera de enforcement):

```text
[ ] Marcador issue-craft:v1 presente y válido (type/variant/madurez en matriz)
[ ] Test de confianza del spec: ¿dos ingenieros distintos leerían esta issue y entregarían
    el MISMO comportamiento observable? Si un fork de interpretación sobrevive → sellarlo
    como decisión antes de despachar (paquete v1 · préstamo m1)
[ ] Baseline verificado con fecha + comandos corridos
[ ] Anclas de contexto presentes (paths:líneas + extractos)
[ ] Alcance IN cerrado; cada exclusión OUT con destino
[ ] CERO decisiones sin régimen; ninguna diferida con "Bloquea TODO" activa
[ ] Artefactos tocados poblados; sin colisión con trabajo en vuelo
[ ] Invariantes nombradas con sus suites
[ ] DoD ejecutable por comando, acotado al alcance; evidencias definidas
[ ] Estimate y prioridad puestos; estimate dentro del rango del tipo (si excede el
    tope del perfil → descomponer en sub-issues)
[ ] SIN bloqueos activos (toda relación "bloqueada por" resuelta — una issue puede estar
    perfectamente ESPECIFICADA y aun así no ser despachable)
[ ] Pre-flags evaluados (abajo)
```

**Pre-flags** (se evalúan siempre; si aplican, marcan la issue):

- ¿Superficie sensible (dinero, auth, credenciales, datos personales, migraciones)? → etiqueta de riesgo + rúbricas reforzadas.
- ¿Acción destructiva/irreversible? → GO explícito del responsable ANTES, documentado en la issue.
- ¿Contenido de cara al usuario final? → gate editorial APARTE del cierre técnico.
- ¿Crea recurso de numeración secuencial global (registro de decisiones, slots de migración)? → verificar el siguiente número libre contra la fuente de verdad viva JUSTO antes de crear.

---

## 8. Elegibilidad del gate operativo: clasificación ≠ evidencia

Dos contratos independientes que el auditor (`audit-issue`) reporta por separado:

```text
classification_source = marker | override   ← QUIÉN clasificó (autoridad)
input_source          = remote | file       ← QUÉ evidencia se pudo observar
operational_gate_eligible = true | false    ← ¿esta corrida PUEDE acreditar el gate?
```

**Solo una corrida `--issue` (evidencia remota completa: body + propiedades — estimate, prioridad, etiquetas, proyecto/hito — + relaciones) con `classification_source=marker` puede terminar `operational_gate_eligible=true`.** El éxito operativo exige conjuntamente: `input_source=remote` + `classification_source=marker` + `operational_gate_eligible=true` + exit 0.

`--file` (modo body-only) sirve para autoría y pre-check: parsea, clasifica y corre los checks verificables desde el body; falla cerrado (exit ≠ 0) ante duros body-verificables rotos, pero SIEMPRE reporta `operational_gate_eligible=false` — no puede observar propiedades ni relaciones, así que no acredita el gate. Todo override, igual: `false` permanente.

Respuesta remota parcial, error del API o campo no consultable → `operational_gate_eligible=false` + exit ≠ 0 (consecuencia natural del contrato de evidencia completa: lo inobservable no se aprueba).

---

## 9. Loop post-rechazo (iteración de las plantillas)

Cada rechazo en revisión — humana, de agente revisor o de CI — dispara UNA pregunta obligatoria:

> **¿La issue pudo haberlo prevenido?**

Si la respuesta es sí, el gap se registra (dónde lo declara el perfil del repo) con: qué campo/cláusula faltó o falló, y qué cambio de plantilla lo habría evitado. Los gaps acumulados alimentan la iteración de las plantillas (cambio de núcleo = canon + manifest + 9 plantillas en el MISMO cambio; el gate de paridad lo fuerza). Así las plantillas mejoran con datos del propio equipo, no con opinión.

Reglas de conteo honesto (heredadas de operar esto en un corpus real): un falso positivo del revisor NO es un gap de la issue; una ronda con varios NO-GO del revisor de plan es el sistema FUNCIONANDO (defectos parados antes de codificar), no un fallo de calidad del autor.

---

## 10. Gotchas & Cross-References

1. **Marcador sin `variant=` explícito** → malformado, fail-closed. `variant=none` se escribe siempre; la ausencia del campo no es "sin variante", es error.
2. **Clasificar por etiquetas del tracker** → las etiquetas históricas no son biyectivas con la taxonomía; son cross-check, nunca autoridad.
3. **Decisión huérfana** → el modo de fallo más caro del corpus: se resuelve por comentario a mitad de vuelo o el ejecutor la decide de facto. Las tres tablas de §4.6 con el gate "cero sin régimen" lo eliminan.
4. **DoD más amplio que el alcance** → issue imposible de cumplir (el gate global contradice el recorte parcial). Acotar SIEMPRE el comando al alcance declarado.
5. **Invariante sin suite nombrada** → "no romper nada" es inauditable; sin la suite, la regresión se descubre en producción.
6. **Placeholder con detalle caro** → inventario que caduca en bloque cuando el roadmap pivota. 5 líneas máximo.
7. **Issue-por-hallazgo** → atomizar hallazgos de auditoría en N issues genera consolidación masiva después; agrupar por vehículo.
8. **Bloqueo en prosa** → "depende de que alguien decida X" sin relación del tracker ni dueño = bloqueo silencioso indefinido. Relación + issue-decisión asignada.
9. **Anclas desactualizadas** → si el extracto embebido no coincide con el archivo real al arrancar, NO se improvisa: escalada con citas (la premisa de la issue está rota).
10. **Confundir clasificación con evidencia** → un body perfecto con marcador válido NO acredita el gate operativo si faltan propiedades/relaciones observables (§8). Son contratos separados a propósito.

**Related reference files:**

- Baterías de verificación, matrices por superficie y rúbricas de revisores → `02-verificaciones.md`
- Mapeo a capacidades nativas de Linear y flujo de plantillas → `03-linear-nativo.md`
- Catálogo de anti-patrones con evidencia y prevención → `04-antipatrones.md`
