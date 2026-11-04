<!-- issue-craft:v1 type=fix variant=none madurez=despachable -->

# Corregir el filtro de disponibilidad que ignora la zona horaria del espacio (API de reservas)

## Contexto y origen

Usuarios de RoomFlow con espacios en zona horaria distinta a la del servidor ven salas "ocupadas" que están libres (y al revés) al filtrar por franja. Soporte acumula 7 tickets en dos semanas; el buscador de disponibilidad es la función más usada del producto y el defecto erosiona la confianza en él.
**Origen**: ticket de soporte RF-733 (adjunto) con reproducción del cliente afectado; triage del 2026-07-15.

## Baseline verificado (2026-07-15)

- Rama/commit de referencia: `c81d40e` (rama principal)
- Arranque verificado (correr ANTES de planificar):
  - `./scripts/e2e.sh tests/e2e/disponibilidad.spec.ts` → verde (la suite actual solo cubre espacios en la zona del servidor: por eso el defecto vive)
  - `grep -rnE 'new Date\([^)]*fecha[^)]*hora' apps/api/src` → 3 resultados (el inventario de la clase, abajo)

## Anclas de contexto

- `apps/api/src/lib/disponibilidad.ts:39-44` — construcción del rango defectuosa (extracto abajo)
  > const inicio = new Date(fecha + "T" + horaInicio)
  > const fin = new Date(fecha + "T" + horaFin)
  > return reservas.filter((r) => seSolapan(r, inicio, fin))
- `packages/core/src/tiempo.ts:12-18` — helper canónico `rangoEnZona(fecha, hora, zona)` ya usado por el módulo de agenda: el patrón a REPLICAR

## Alcance

### Incluye

- Migrar los 3 call-sites del inventario (abajo) a `rangoEnZona(fecha, hora, espacio.zonaHoraria)`
- Test e2e nuevo `tests/e2e/disponibilidad-zona.spec.ts` con espacio en zona ≠ servidor (offsets positivo y negativo)
- Caso unitario de `rangoEnZona` con offset negativo, si falta en `tests/unit/tiempo.test.ts`

### Fuera de alcance

- ❌ Selector de zona horaria en el perfil del USUARIO → RF-745
- ❌ Refactor general del módulo de tiempo → RF-746

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| Fuente de la zona | `espacios.zona_horaria` — nunca la del navegador ni la del servidor | Responsable de producto | 2026-07-15 |
| Espacio sin zona poblada | usar la zona por defecto de la organización + aviso en log | Responsable de plataforma | 2026-07-15 |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|
| Migrar el almacenamiento de reservas a hora local | el almacenamiento en UTC es correcto; el defecto es de interpretación en el borde | Responsable de plataforma |

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- `apps/api/src/lib/disponibilidad.ts` · `apps/api/src/routes/calendario.ts` · `apps/api/src/jobs/recordatorios.ts`
- `tests/e2e/disponibilidad-zona.spec.ts` (nuevo) · `tests/unit/tiempo.test.ts`

## Invariantes que NO deben cambiar

- Resultados del filtro para espacios en la MISMA zona del servidor — lo prueba: `tests/e2e/disponibilidad.spec.ts` (verde SIN cambios)
- Firma y semántica de `rangoEnZona()` (la consume agenda) — lo prueba: `tests/unit/tiempo.test.ts` + `tests/e2e/agenda.spec.ts`
- Almacenamiento de reservas en UTC — sin cambios de esquema en esta issue

## Contratos cross-pieza (si va en tren)

- N/A — no va en tren

## Esperado vs Observado

- **Esperado**: filtrar "2026-07-15 09:00-10:00" evalúa la franja en la zona del ESPACIO (`espacios.zona_horaria`).
- **Observado**: la franja se interpreta en la zona del proceso del servidor; con offset -6 h el filtro consulta la franja equivocada y devuelve disponibilidad incorrecta (reproducción literal en RF-733).

## Causa raíz (probada)

`new Date("AAAA-MM-DDTHH:mm")` sin designador de zona se interpreta en la zona LOCAL del proceso. Probado en staging: la misma expresión produce instantes distintos según la máquina donde corre — el rango depende del entorno, no del espacio. El campo `espacios.zona_horaria` existe y está poblado desde RF-201; este camino nunca lo leyó.

## Inventario de la clase (cierre al 100%)

`grep -rnE 'new Date\([^)]*fecha[^)]*hora' apps/api/src` → 3 call-sites con el MISMO patrón defectuoso:

| Call-site | Síntoma |
|---|---|
| `apps/api/src/lib/disponibilidad.ts:39` | el reportado — filtro del buscador |
| `apps/api/src/routes/calendario.ts:57` | el export de calendario desplaza eventos |
| `apps/api/src/jobs/recordatorios.ts:23` | recordatorios llegan a deshora |

Regla clase-cubierta-100%: los 3 call-sites migran en ESTA issue. Cerrar solo el reportado deja la misma bomba en dos rutas más — y no es generalizar (S5): es el alcance DECLARADO por este inventario.

## Criterios de aceptación / DoD

- [ ] `grep -rnE 'new Date\([^)]*fecha[^)]*hora' apps/api/src` → 0 resultados (clase cerrada al 100%)
- [ ] `./scripts/e2e.sh tests/e2e/disponibilidad-zona.spec.ts` → verde (offset positivo y negativo)
- [ ] Criterio por mutación: re-aplicar el patrón viejo SOLO en `disponibilidad.ts:39` → el spec nuevo en ROJO; revertir → verde (ambas salidas pegadas)
- [ ] `./scripts/e2e.sh tests/e2e/disponibilidad.spec.ts tests/e2e/agenda.spec.ts` → verdes SIN cambios (invariantes)
- [ ] `./scripts/checks.sh` → verde sobre el commit final

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Clase cerrada | salida literal del grep → 0 sobre el commit final |
| Mutación | AMBAS salidas: spec en rojo con la mutación aplicada + verde tras revertirla |
| Invariantes | salidas verdes de los specs vecinos, sin diff en ellos |

## Brief del ejecutor

- Conocimiento previo a cargar: `docs/guias/tiempo.md` (manejo de fechas del repo)
- Patrón a REPLICAR: uso de `rangoEnZona()` en `apps/api/src/routes/agenda.ts:31-36` (prohibido inventar helper nuevo)
- Límites duros: NO tocar esquema; NO "aprovechar para mejorar" nada fuera del inventario (S5 reforzado); NO añadir dependencias de fechas.
- Presupuesto de cambio: ~5 archivos / ~120 líneas (exceso 2× → replantear, no seguir).
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: responsable de plataforma (perfil del repo).

## Rúbricas de revisión aplicables

- Baterías activas: M + S (S5 reforzado: el fix no "aprovecha para mejorar") + O1/O8 + Q · Matriz: API (contrato de errores del filtro intacto)
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan cubre los 3 call-sites del inventario, no solo el reportado
- Revisor de código: 5 dimensiones §8 — extra: criterio por mutación con ambas salidas adjuntas
- Checks adicionales de ESTA issue: ninguno

## Protocolo de cierre

- Checks requeridos: `./scripts/checks.sh` + suites citadas en el DoD
- Régimen de cierre: PR + revisión + fusión (magic word de cierre en el PR)
- (si esta pieza va en tren: cierre vía `closes` del PR padre, ver `## Contratos cross-pieza` arriba y `talent-merger` ref 09; nunca PR individual) — N/A, esta issue no va en tren
- Rollback: revertir el commit de fusión restaura el comportamiento previo (sin migraciones involucradas)
- PARAR y escalar si: el grep del inventario devuelve MÁS de 3 call-sites al arrancar — la clase creció: re-inventariar antes de codificar
