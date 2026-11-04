<!-- issue-craft:v1 type=feat variant=db madurez=despachable -->

# Añadir límite de reservas activas por usuario configurable por espacio (API + panel del espacio)

## Contexto y origen

Los administradores de espacios en RoomFlow reportan acaparamiento: un mismo usuario mantiene 10+ reservas activas y bloquea salas para el resto del equipo. Esta capacidad permite a cada espacio fijar un tope de reservas activas por usuario; al alcanzarlo, la creación se bloquea con un mensaje claro.
**Origen**: propuesta de usuario RF-482 del portal de feedback (adjunta) + decisión de la responsable de producto del 2026-07-14 (detalle trasladado a la tabla de Decisiones, no "según lo acordado").

## Baseline verificado (2026-07-16)

- Rama/commit de referencia: `a3f92c1` (rama principal) + registro de migraciones de producción al día hasta `0141`
- Arranque verificado (correr ANTES de planificar):
  - `ls db/migrations/ | tail -1` → `0141_indices_agenda.sql` (re-verificar numeración libre JUSTO antes de crear la migración)
  - `./scripts/db-reset.sh && ./scripts/db-test.sh` → suite verde (estado actual: sin límite)
  - `grep -rn "max_reservas" apps/ db/ | wc -l` → `0` (la capacidad no existe todavía)

## Anclas de contexto

- `apps/api/src/routes/reservas.ts:88-96` — handler de creación donde entra la validación (extracto abajo)
  > const espacio = await repo.espacios.porId(input.espacioId)
  > if (!espacio) return respuesta.error("espacio_no_encontrado")
  > const reserva = await repo.reservas.crear({ ...input, estado: "activa" })
- `db/migrations/0137_espacios_horario_config.sql` — patrón canónico a REPLICAR: columna de config por espacio + política de escritura solo-admin + test negativo

## Alcance

### Incluye

- Columna `espacios.max_reservas_activas` (entero, `NULL` = sin límite, `CHECK > 0`) vía migración
- Validación del tope en el handler de creación de reservas (`apps/api`)
- Campo de configuración en el panel del espacio (`apps/web`, visible solo para rol admin del espacio)
- Test de base de datos con caso negativo de escritura + test e2e del bloqueo

### Fuera de alcance

- ❌ Límites por equipo u organización → RF-511
- ❌ Notificar al usuario cuando se acerca al tope → RF-512

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| Semántica de "activa" | reserva futura o en curso no cancelada | Responsable de producto | 2026-07-14 |
| Espacio sin valor configurado | sin límite (comportamiento actual) | Responsable de producto | 2026-07-14 |
| Reservas existentes al configurar el límite | se conservan; solo se bloquean creaciones nuevas | Responsable de producto | 2026-07-14 |
| Mensaje de bloqueo | "Alcanzaste el límite de reservas activas de este espacio" + código estable `limite_reservas_alcanzado` | Responsable de producto | 2026-07-14 |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|
| Valor recomendado sugerido en el panel | Responsable de producto | tras 2 semanas de datos de uso | No | campo sin sugerencia; solo placeholder numérico |

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|
| Tope global impuesto por la plataforma | cada espacio es dueño de su política; ningún caso de soporte lo pide | Responsable de producto |

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- `db/migrations/NNNN_limite_reservas_espacio.sql` (slot NNNN: verificar libre contra `ls db/migrations/` justo antes de crear)
- `db/tests/espacios_limite.sql` (nuevo)
- `apps/api/src/routes/reservas.ts` · `apps/api/src/repos/espacios.ts`
- `apps/web/src/paginas/espacio/configuracion.tsx`
- `tests/e2e/reservas-limite.spec.ts` (nuevo)

## Invariantes que NO deben cambiar

- Flujo de creación de reservas sin límite configurado — lo prueba: `tests/e2e/reservas-crear.spec.ts` (verde SIN cambios)
- Cancelación de reservas — lo prueba: `tests/e2e/reservas-cancelar.spec.ts`
- Políticas de acceso actuales de `espacios` y `reservas` — lo prueba: `db/tests/politicas_base.sql`
- Config de horario por espacio introducida en RF-390 — referencia: migración `0137`

## Contratos cross-pieza (si va en tren)

- N/A — no va en tren

## Contrato de comportamiento

| # | Caso | Comportamiento esperado |
|---|---|---|
| C1 | espacio con límite 3, usuario con 2 activas | crea la 3ª con normalidad; al intentar la 4ª → bloqueo con el mensaje sellado y código `limite_reservas_alcanzado` |
| C2 | usuario con rol miembro intenta configurar el límite | denegado con mensaje neutro — NUNCA error crudo del motor; el campo ni se muestra en su panel |
| C3 | reservas canceladas o ya pasadas | NO cuentan para el tope; el flujo de cancelación existente queda INTACTO |
| C4 | fallo al consultar el conteo de activas | la creación se DENIEGA con mensaje de reintento (fail-closed: nunca se supera el límite por error técnico) |

## Archivos y patrón

- Componente/módulo base a imitar: `db/migrations/0137_espacios_horario_config.sql` + su campo en `configuracion.tsx` (introducidos en RF-390)
- Puntos de integración: handler `crearReserva`, repo de espacios, panel de configuración del espacio

### Bloque DB (variant=db)

- Migración: `NNNN_limite_reservas_espacio.sql` — verificar numeración libre contra `db/migrations/` JUSTO antes de crear
- Patrón de referencia: `0137_espacios_horario_config.sql` (columna + política + test)
- Seguridad de datos: política de acceso a nivel de fila — `max_reservas_activas` solo la escribe el rol admin del espacio; test negativo obligatorio ("como miembro, actualizar el límite → denegado"); la validación del tope corre con las credenciales del usuario, nunca con credenciales administrativas
- Post-fusión: aplicar a producción + validaciones del motor según el protocolo del perfil del repo

## Criterios de aceptación / DoD

- [ ] `ls db/migrations/ | tail -1` → la migración nueva, con slot correcto y sin colisión
- [ ] `./scripts/db-reset.sh && ./scripts/db-test.sh db/tests/espacios_limite.sql` → verde, incluido el caso negativo de escritura
- [ ] `./scripts/e2e.sh tests/e2e/reservas-limite.spec.ts` → verde (cubre C1-C4 caso a caso, incluidos los negativos)
- [ ] `./scripts/e2e.sh tests/e2e/reservas-crear.spec.ts tests/e2e/reservas-cancelar.spec.ts` → verdes SIN cambios (invariantes)
- [ ] `./scripts/checks.sh` → verde sobre el commit final
- [ ] Matriz FRONT del panel: navegador real escritorio ≥1280px y móvil ~375px con capturas; estados cargando/error/vacío/éxito; teclado+focus; todos los idiomas del producto

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Migración + tests de BD | salida literal de `db-test.sh` sobre el commit final |
| Contrato C1-C4 | salida del spec `reservas-limite` + captura del bloqueo de C1 |
| Invariantes | salidas verdes de los dos specs vecinos, sin diff en ellos |
| Matriz FRONT | capturas escritorio/móvil en ambos estados (campo visible admin / oculto miembro) |

## Brief del ejecutor

- Conocimiento previo a cargar: guía de migraciones del repo + guía del panel de configuración
- Patrón a REPLICAR: `db/migrations/0137_espacios_horario_config.sql` y su campo en `configuracion.tsx` (prohibido inventar estructura nueva)
- Límites duros: NO tocar el modelo de reservas; NO añadir dependencias; NO resolver decisiones no selladas.
- Presupuesto de cambio: ~6 archivos / ~220 líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: responsable de plataforma (perfil del repo).

## Rúbricas de revisión aplicables

- Baterías activas: M + S + O + Q · Matrices: FRONT + DB completas
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan cubre C1-C4 caso a caso, incluidos negativos y fail-closed
- Revisor de código: 5 dimensiones §8 — extra: matriz DB al completo (test negativo incluido) + FRONT del panel
- Checks adicionales de ESTA issue: verificar que el conteo de activas usa consulta agregada (sin N+1 sobre reservas)

## Protocolo de cierre

- Checks requeridos: los del perfil del repo (`./scripts/checks.sh` + suites citadas en el DoD)
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR)
- (si esta pieza va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09; nunca PR individual) — N/A, esta issue no va en tren
- Post-fusión: aplicar la migración a producción + validaciones del motor; confirmar registro de migraciones al día
- PARAR y escalar si: el patrón `0137` ya no existe en la rama principal, o el slot de migración colisiona al crear
