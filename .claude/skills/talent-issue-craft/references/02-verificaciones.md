# Verificaciones — Baterías, Matrices, Rúbricas y Calibración

Rúbricas canónicas de verificación que las issues ACTIVAN (por type/variant y por superficie tocada) y los revisores aplican. Una sola vara para todos: la issue declara triggers y datos específicos; las definiciones viven aquí.

## Table of Contents

1. [Modelo de severidad y momentos de ejecución](#1-modelo-de-severidad-y-momentos-de-ejecución)
2. [Batería M — Mantenibilidad](#2-batería-m--mantenibilidad)
3. [Batería S — No-sobreingeniería](#3-batería-s--no-sobreingeniería)
4. [Batería O — Optimización y eficiencia](#4-batería-o--optimización-y-eficiencia)
5. [Batería Q — Calidad general](#5-batería-q--calidad-general)
6. [Matrices de verificación por superficie](#6-matrices-de-verificación-por-superficie)
7. [Rúbrica del revisor de plan](#7-rúbrica-del-revisor-de-plan)
8. [Rúbrica del revisor de código (5 dimensiones)](#8-rúbrica-del-revisor-de-código-5-dimensiones)
9. [Activación por tipo](#9-activación-por-tipo)
10. [Método de calibración del umbral](#10-método-de-calibración-del-umbral)
11. [Gotchas & Cross-References](#11-gotchas--cross-references)

---

## 1. Modelo de severidad y momentos de ejecución

Cada check es 🔴 **duro** (incumplido → NO-GO / exit ≠ 0 del auditor, independiente de cualquier puntuación) o 🟡 **señal** (incumplido → exige justificación escrita en la entrega; el revisor decide con ella a la vista).

Tres momentos de ejecución:

```text
AUTOR       → al escribir la issue: declara qué baterías/matrices aplican
EJECUTOR    → antes de entregar: auto-corre las baterías activas (pre-check)
REVISORES   → plan-gate: S sobre el plan · code-review: TODAS sobre el diff
```

El helper `audit-issue` verifica la CAPA ISSUE (que la issue declare y estructure lo exigible); las baterías sobre el CÓDIGO las aplican ejecutor y revisores usando este documento como vara.

---

## 2. Batería M — Mantenibilidad

| # | Check | Criterio verificable | Sev |
|---|-------|----------------------|-----|
| M1 | **Mimetismo** | El código nuevo es indistinguible del vecino: naming, estructura, idioma, densidad de comentarios. Verificación: comparar lado a lado con el patrón citado en la issue | 🔴 |
| M2 | **Cero duplicación nueva** | Antes de escribir, se buscó (grep por sinónimos del dominio) si ya existe la utilidad/componente/consulta. Lógica duplicada nueva = NO-GO con el path del original | 🔴 |
| M3 | **Ubicación correcta** | El código vive donde el próximo lector lo buscaría: UI sin lógica de negocio, capa de datos sin presentación — no "donde cayó" | 🔴 |
| M4 | **Acoplamiento no ampliado** | Sin imports cruzados nuevos entre módulos que antes no se conocían, salvo justificación escrita | 🟡 |
| M5 | **Nombres que revelan intención** | Sin abreviaturas inventadas; consistentes con el glosario del dominio del repo | 🟡 |
| M6 | **Comentarios solo-restricción** | Comentarios únicamente donde el código no puede decirlo (porqués, restricciones externas). Cero comentarios narrando el diff o dirigidos al revisor | 🔴 |
| M7 | **Unidades proporcionadas** | Función/componente nuevo dentro del rango del archivo; si supera ~2× la mediana local, justificar o partir | 🟡 |
| M8 | **Prueba de borrabilidad** | "Si esta feature se elimina mañana, ¿cuántos archivos se tocan?" — tentáculos por muchos archivos = mala cohesión; reagrupar antes de aprobar | 🟡 |
| M9 | **Nada hardcodeado** | Textos de usuario en el sistema de idiomas del repo, valores mágicos con nombre, config en la capa de config — verificable por grep | 🔴 |
| M10 | **Docs vivos sincronizados** | Si el cambio contradice un doc/guía existente, se actualiza en el MISMO cambio (grep de la afirmación obsoleta → 0) | 🔴 |

---

## 3. Batería S — No-sobreingeniería

| # | Check | Criterio verificable | Sev |
|---|-------|----------------------|-----|
| S1 | **Prueba de borrado** | El revisor responde OBLIGATORIAMENTE: "¿qué parte del diff se puede borrar y el DoD sigue verde?" Respuesta ≠ "nada" → NO-GO con la lista de lo sobrante | 🔴 |
| S2 | **Abstracción con ≥2 consumidores** | Toda interfaz/clase base/genérico nuevo tiene ≥2 consumidores REALES hoy. Con 1 consumidor se escribe inline; "lo usaremos después" no cuenta | 🔴 |
| S3 | **Config con dueño** | Cada flag/opción nueva tiene un caso de uso ACTUAL con dueño nombrado. Config "por si acaso" = NO | 🔴 |
| S4 | **Cero dependencias sin aprobar** | Dependencia nueva solo con aprobación explícita previa; para cada candidata: ¿lo resuelven ≤30 líneas propias?, ¿mantenida?, ¿qué superficie añade? | 🔴 |
| S5 | **Resolver 1, no N** | El diff resuelve el alcance de la issue, no "la clase general del problema". Generalizar es una decisión de issue futura, no del ejecutor | 🔴 |
| S6 | **Indirección justificada** | Cada capa nueva (wrapper, factory, bus, cola) justificada contra la llamada directa. Indirección sin segunda implementación real = deuda, no arquitectura | 🟡 |
| S7 | **Cero optimización especulativa** | Optimizar sin medición que lo pida es sobreingeniería (pareja de O7). "Por rendimiento" sin número = argumento rechazado | 🔴 |
| S8 | **Complejidad proporcional** | La complejidad de la solución es proporcional al problema declarado: un estimate bajo no justifica arquitectura nueva. Desproporción → replantear en el plan-gate | 🟡 |

Nota de alcance: S5 convive con el overlay **cierre-por-clase** del tipo `fix` — allí el DoD exige cubrir la clase completa DEL DEFECTO (con inventario por comando adjunto en la issue); eso es alcance DECLARADO, no generalización del ejecutor. La frontera la pone la issue, nunca el diff.

---

## 4. Batería O — Optimización y eficiencia

Dos caras: **no pesimizar** (O1-O6, O8) y **no optimizar sin datos** (O7).

| # | Check | Criterio verificable | Sev |
|---|-------|----------------------|-----|
| O1 | **Sin N+1** | Ningún bucle con IO/consulta dentro; listados resueltos en consulta agregada. Verificación: revisar cada iteración que contenga IO | 🔴 |
| O2 | **Índices para consultas nuevas** | Toda consulta que filtra/ordena por columnas de tablas que crecen: índice verificado, o plan de índice, o justificación de volumen escrita | 🔴 |
| O3 | **Payload acotado** | Consultas seleccionan las columnas necesarias (no `select *` en datos crecientes); todo listado con paginación o tope declarado | 🔴 |
| O4 | **Peso en cliente** (si UI) | Código/librería pesada nueva → carga diferida; nada de dependencia grande para una función; impacto en el bundle verificado si el repo lo mide | 🟡 |
| O5 | **Caché con invalidación** | Toda caché/memoización nueva: (a) evidencia de repetición costosa que la justifica, (b) plan de invalidación declarado. Caché sin invalidación = bug futuro | 🔴 |
| O6 | **Ruta caliente limpia** | Sin trabajo evitable en rutas calientes (render, camino de la petición): lo diferible va a build-time, background o lazy | 🟡 |
| O7 | **Optimización = medición** | Cambio vendido como optimización trae número antes/después del MISMO entorno/build, pegado como evidencia. Sin número, el claim se rechaza | 🔴 |
| O8 | **Recursos acotados** | Streams/conexiones/listeners nuevos se cierran o desuscriben; timeout en toda IO externa; reintentos con tope y backoff | 🔴 |

---

## 5. Batería Q — Calidad general

| # | Check | Criterio verificable | Sev |
|---|-------|----------------------|-----|
| Q1 | **Errores manejados con contexto** | Toda operación falible (red, IO, parseo) tiene rama de fallo que llega a usuario/log con contexto accionable. Catch vacío = NO-GO | 🔴 |
| Q2 | **Fail-closed en accesos** | Ante duda, config ausente o estado inesperado: denegar. Superficie anónima → comportamiento seguro por defecto. Verificación: simular la ausencia | 🔴 |
| Q3 | **Estados completos en UI** | Cargando / error / vacío / éxito — los cuatro renderizados y verificados; actualización optimista siempre con reversión en el fallo | 🔴 |
| Q4 | **Frontera validada** | Entradas externas validadas en el borde (tipos, tamaños, formatos); contenido de usuario que se renderiza, sanitizado | 🔴 |
| Q5 | **Idempotencia ante repetición** | Operaciones repetibles (doble clic, reintento, webhook duplicado) son idempotentes o están protegidas — verificable ejecutando dos veces | 🔴 |
| Q6 | **Sin breaking silencioso** | Cambio de contrato (API, esquema, evento) → migración de consumidores en el mismo cambio o secuencia declarada en la issue | 🔴 |
| Q7 | **Deja rastro** | Lo nuevo que puede fallar en producción emite log/métrica suficiente para diagnosticar sin re-desplegar | 🟡 |
| Q8 | **Checks reales sobre el commit final** | Los checks del repo corridos DE VERDAD sobre el commit exacto entregado, con evidencia — nunca declarados sin correr | 🔴 |

---

## 6. Matrices de verificación por superficie

Se activan por trigger OBJETIVO (qué toca el diff), no por criterio del autor. La issue las declara activas; el perfil del repo aporta los comandos concretos.

### 6.1 FRONT/UI (trigger: componentes, páginas, estilos)

- Navegador REAL: escritorio ≥1280px **y** móvil ~375px, con capturas — compilar y tipar NO validan experiencia.
- **Responsive**: sin overflow horizontal, targets táctiles adecuados, layout íntegro en ambos anchos.
- **Estados completos**: cargando/error/vacío/éxito renderizados (Q3), no solo el camino feliz.
- **Accesibilidad básica**: navegable por teclado, focus visible, labels en controles, contraste de tokens.
- **Idiomas**: la pantalla abierta en TODOS los idiomas del producto (textos largos rompen layouts) — si el producto es multi-idioma según el perfil.
- **Tema**: claro y oscuro sin flash ni tokens rotos, si el repo soporta ambos.
- **Interacción real**: e2e o recorrido manual del flujo nuevo, incluidos los casos negativos del contrato de la issue.
- **Sin regresión visual** de pantallas vecinas que comparten componentes tocados.

### 6.2 DB (trigger: esquema, migraciones, funciones de datos, políticas de acceso)

- Tests de base de datos incluyendo el **test negativo de acceso** ("como usuario B, leer datos de A → denegado") si el motor soporta seguridad a nivel de fila.
- Validaciones/advisors del motor sin hallazgos nuevos post-aplicación (si el proveedor los ofrece).
- Registro/ledger de migraciones al día; reconstrucción desde cero reproducible.
- Idempotencia de la migración de datos; reversibilidad declarada (o GO explícito si es irreversible).
- Permisos mínimos: funciones privilegiadas con revocación/concesión explícita; mutaciones sensibles nunca con credenciales administrativas desde contexto de usuario.

### 6.3 API/backend (trigger: handlers, endpoints, acciones de servidor)

- Autenticación verificada en CADA handler nuevo (no heredada por suposición).
- Contrato de errores: shapes de éxito y fallo definidos y probados.
- Rate-limit si es superficie pública.
- Smoke con cliente HTTP real y salida esperada.

### 6.4 Contenido/datos de producto (trigger: escrituras editoriales/operativas en producción)

- Verificación post-escritura: conteos poblados, URLs → 200.
- Prueba funcional del consumidor (la feature que usa el dato funciona con el dato nuevo).
- Snapshot previo confirmado; procedimiento canónico (nunca escritura directa); patrón añadir-luego-retirar con borrado diferido.

---

## 7. Rúbrica del revisor de plan

Para dar GO, el plan DEBE demostrar todo esto (checklist objetiva):

```text
[ ] Test de confianza: ¿dos ingenieros distintos leerían el spec+plan y entregarían el
    MISMO comportamiento observable? (dimensión de calidad del contrato — paquete v1 · m1)
[ ] Corrió los comandos del baseline de la issue (no los asume) y las anclas de
    contexto coinciden con el árbol real
[ ] Cubre el 100% del "Incluye" y NADA del "Fuera de alcance" (entrega completa —
    sin recorte silencioso de alcance)
[ ] Cita el patrón a replicar y explica cómo lo sigue
[ ] ANTI-SOBREINGENIERÍA (batería S aplicada al plan): presenta la alternativa MÁS
    SIMPLE considerada y justifica cada pieza extra sobre ella; cero abstracciones
    especulativas o config para futuros hipotéticos
[ ] Implementa los defaults de las decisiones diferidas TAL CUAL (no las resuelve);
    no introduce decisiones nuevas no listadas — si el plan revela una decisión que
    la issue no vio, SE DEVUELVE LA ISSUE, no se improvisa
[ ] Riesgos identificados con mitigación concreta (no "tener cuidado") y verificación
    por paso (cómo sé que el paso N quedó bien antes del N+1)
[ ] Si toca migraciones o superficie sensible: incluye reversión y orden de aplicación
```

---

## 8. Rúbrica del revisor de código (5 dimensiones)

1. **CORRECTITUD** — cada checkbox del DoD tiene evidencia REAL adjunta (salida de comando sobre el commit exacto, no "debería pasar"). Si el tipo exige **criterio por mutación**: mutación aplicada → check rojo → revertida → verde, con AMBAS salidas pegadas.
2. **SEGURIDAD** — la matriz de la superficie tocada (§6) al completo; en variante `seguridad`: cadena de exploit re-verificada cerrada + test negativo.
3. **REGRESIÓN** — las invariantes nombradas siguen verdes (suites corridas, no asumidas); el diff NO toca nada fuera de "Artefactos tocados" (diff-scope literal); ninguna decisión diferida quedó "decidida de facto" (valor hardcodeado en vez del default aislado).
4. **MANTENIBILIDAD** — batería M al completo sobre el diff.
5. **NO-SOBREINGENIERÍA** — batería S al completo; la pregunta S1 se responde por escrito en la revisión.

### El criterio por mutación (doctrina)

Un check que no falla ante la mutación no es red, es decoración. Donde el tipo lo exige (`fix`, `test`):

```text
1. Aplicar la condición del defecto (mutación/fixture)  → el check DEBE ponerse rojo
2. Revertir                                             → verde
3. Ambas salidas literales se adjuntan como evidencia
```

---

## 9. Activación por tipo

| type/variant | M | S | O | Q | Matrices | Extra del tipo |
|--------------|---|---|---|---|----------|----------------|
| feat/none | ✔ | ✔ | ✔ | ✔ | FRONT y/o API según superficie | contrato de comportamiento caso a caso |
| feat/db | ✔ | ✔ | ✔ | ✔ | + DB completa | slot de migración + post-aplicación |
| fix/none | ✔ | ✔ | O1, O8 | ✔ | según superficie | **mutación obligatoria** + cierre-por-clase; S5 reforzado: el fix no "aprovecha para mejorar" |
| fix/seguridad | ✔ | ✔ | O1, O8 | ✔ | + la de su superficie | + batería de exploit (cadena, mitigantes, test negativo, debilidad estándar) |
| fix/sev1 | M1, M2 | S5 | O8 | Q1, Q2, Q8 | según superficie | forma compacta; smokes 3 capas incl. producción; lo sistémico → follow-up |
| fix/seguridad+sev1 | ✔ | ✔ | O1, O8 | ✔ | + la de su superficie | **UNIÓN** de las dos anteriores; ningún duro de seguridad se omite |
| db-ops/none | M10 | ✔ | ✔ | Q2, Q5, Q6, Q8 | DB completa | evidencia medida + verificación-en-5-min + criterios como consultas post-aplicación + steelman |
| chore/none | ✔ | ✔ | 🟡 | Q1, Q8 | según superficie | S3/S4 reforzados (aquí nace la config zombi) |
| chore/doc-vivo | ✔ | ✔ | — | Q8 | — | inventario con cifras + Declarado\|Vigente\|Fuente + "Qué NO tocar" + DoD espejo + fuentes con fecha |
| refactor/none | ✔ | ✔ | O7 | Q8 | según superficie | caracterización PREVIA como gate; S1 al resultado: el refactor debe REDUCIR, no mover |
| test/none | M1, M2 | S5 | O8 | Q8 | — | red-que-detecta (mutación) + determinismo (2 corridas idénticas) + deslinde de suites |
| docs-adr/none | M10 | S5 | — | Q8 | — | doc-vs-código + aceptación por grep + inmutabilidad de decisiones |
| spike-auditoria/none | — | S5 | — | — | — | DIFF-CERO; las baterías aplican a sus issues hijas |
| contenido-datos/none | M9 | S5 | O3 | Q2, Q5, Q8 | Contenido/datos | idempotencia del write es Q5; cierre manual con evidencia |

---

## 10. Método de calibración del umbral

`audit-issue` emite un score 0-100 **además** de los duros (que mandan: cualquier 🔴 aplicable roto → exit ≠ 0 sin importar el score). El umbral de `--min-score` se calibra, no se inventa:

**Con historial** (el caso normal):

```text
1. Tomar ≥5 issues GOLD del corpus propio (cerradas limpio, sin rework)
   y ≥5 issues MALAS (rechazadas en revisión, rebotadas, stubs)
2. Correr audit-issue sobre las 10 (corpus pre-skill → modo override:
   --type/--variant fijan la clasificación de la corrida)
3. Ajustar el umbral hasta DISCRIMINACIÓN COMPLETA:
   todas las malas < umbral ≤ todas las gold
4. Fijar el umbral en el perfil del repo, con la tabla de scores como evidencia
```

**Sin historial** (repo nuevo): usar el default documentado en el perfil-plantilla y RE-CALIBRAR al acumular 10+ issues cerradas (el perfil registra la fecha de la última calibración).

El override existe EXACTAMENTE para esto (y para auditar issues manuales históricas); nunca acredita el gate operativo (`01-nucleo-y-despachabilidad.md` §8).

---

## 11. Gotchas & Cross-References

1. **Score alto con un duro roto** → exit ≠ 0 igualmente. El score es señal secundaria; los duros mandan. Probarlo es parte del contrato del auditor.
2. **"Optimicé de paso"** → S7+O7: sin número antes/después del mismo entorno, el claim se rechaza y el cambio se revierte del diff.
3. **Caché sin plan de invalidación** → O5 la bloquea aunque "funcione": es un bug futuro con fecha aleatoria.
4. **Mutación que no pone el check en rojo** → la red no detecta; el criterio por mutación existe para descubrir exactamente eso antes de la fusión.
5. **Matriz de superficie saltada porque "el cambio es pequeño"** → los triggers son objetivos (qué toca el diff), no proporcionales al tamaño.
6. **Batería S aplicada solo al código** → el plan también se audita con S (rúbrica §7); la sobreingeniería barata de matar es la que aún no se escribió.
7. **Calibrar con issues de otro equipo** → el umbral discrimina hábitos LOCALES de escritura; corpus propio o default documentado, nunca prestado.
8. **Justificación 🟡 ausente** → una señal sin justificación escrita escala a NO-GO; el mecanismo 🟡 es "explica o corrige", no "ignora".
9. **Evidencia sobre un commit distinto al entregado** → anti-autoreporte (Q8): la evidencia se re-produce sobre el commit final exacto tras cualquier rebase/cambio.
10. **Confundir cierre-por-clase con generalización** → la clase del DEFECTO la declara la issue con inventario por comando (overlay fix); "resolver la clase general del problema" sin declararlo es S5.

**Related reference files:**

- Núcleo, marcador, matriz type×variant y gates → `01-nucleo-y-despachabilidad.md`
- Anti-patrones que estas baterías previenen, con evidencia → `04-antipatrones.md`
- Comandos concretos por repo → plantilla `templates/perfil-de-repo.md`
