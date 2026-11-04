<!-- issue-craft:v1 type=spike-auditoria variant=none madurez=despachable -->

# Auditar los 9 endpoints públicos del API de reservas: validación de entrada y límites de tasa

## Contexto y origen

Dos incidentes de julio en RoomFlow (payload malformado que tumbó el buscador; scraping sin freno sobre el listado de espacios) sugieren huecos de validación y de límite de tasa en la superficie pública del API; antes de endurecer nada se necesita el mapa completo: qué endpoint valida qué, cuál tiene límite y cuál no.
**Origen**: postmortem del incidente del 2026-07-08 (adjunto), acción 3; decisión del responsable de plataforma del 2026-07-11 trasladada a la tabla de Decisiones.

## Baseline verificado (2026-07-16)

- Rama/commit de referencia: `f2e7b9a` (rama principal)
- Arranque verificado (correr ANTES de planificar):
  - `grep -rln "publica: true" apps/api/src/routes | wc -l` → `9` (≈9 al planificar; el inventario es dinámico, verificar EN VIVO al arrancar)
  - `git status --porcelain | wc -l` → `0` (árbol limpio: contra esto se mide la frontera diff-cero)

## Anclas de contexto

- `apps/api/src/middleware/limite-tasa.ts:10-16` — middleware de límite existente, se aplica por ruta (extracto abajo)
  > export function conLimiteTasa(opciones: OpcionesLimite) {
  > return (handler: Handler) => envolver(handler, opciones)
  > }
  > }
- `docs/auditorias/2026-05-webhooks.md` — reporte del barrido previo: el formato de entregable a REPLICAR

## Alcance

### Incluye

- Responder las 4 preguntas del barrido con evidencia (path:línea por endpoint del inventario vivo)
- Crear las issues de remediación agrupadas por vehículo + reporte en el formato prescrito, como comentario de cierre en esta issue

### Fuera de alcance

- ❌ Corregir CUALQUIER hallazgo → issues hijas de esta auditoría
- ❌ Endpoints internos/autenticados → RF-802 (barrido aparte ya planificado)
- ❌ Auditar autenticación/autorización → cubierto por el barrido RF-771 (cerrado)

## Decisiones

### Selladas

| Parámetro | Valor | Quién decidió | Fecha |
|---|---|---|---|
| Umbral para crear issue hija | 🔴 siempre; 🟡 solo si cabe en un vehículo ya abierto | Responsable de plataforma | 2026-07-11 |
| Regla de agrupación | por VEHÍCULO de implementación: mismos archivos = misma issue | Responsable de plataforma | 2026-07-11 |

### Diferidas (deliberadamente)

| Decisión | Quién decidirá | Cuándo/trigger | ¿Bloquea? | Default mientras tanto |
|---|---|---|---|---|
| Prioridad de las issues de remediación | Responsable de plataforma | al leer el reporte | No | las hijas nacen sin prioridad final |

### No se decidirá

| Cuestión | Por qué | Registrado por |
|---|---|---|

GATE DE DESPACHO: cero decisiones abiertas sin régimen.

## Artefactos tocados

- ÚNICAMENTE el reporte (comentario de cierre en esta issue) + issues nuevas en el tracker; código/config/datos: NADA — ver Frontera DIFF-CERO

## Invariantes que NO deben cambiar

- TODO el árbol de trabajo — lo prueba: `git status --porcelain | wc -l` → `0` al entregar
- Producción intocada: si el barrido prueba endpoints, SOLO lecturas idempotentes contra staging

## Contratos cross-pieza (si va en tren)

- N/A — no va en tren

## Baseline: lo que YA se sabe

### Confirmado que funciona (NO re-implementar ni re-auditar)

- `POST /reservas` valida el cuerpo completo con esquema declarativo — evidencia: RF-771 + `apps/api/src/routes/reservas.ts:15-22`
- El middleware `conLimiteTasa` funciona donde se aplica — evidencia: `tests/unit/limite-tasa.test.ts` verde en la rama principal

### Lo que NO es hallazgo (deliberado)

- `GET /salud` sin límite de tasa — decisión registrada en RF-610 (lo consume el monitoreo cada 15 s); NO re-reportarlo

## Preguntas a responder / alcance del barrido

Inventario dinámico: `grep -rln "publica: true" apps/api/src/routes | sort` → ≈9 al planificar; re-correr al arrancar y auditar la lista VIVA, nunca un conteo fijo.

1. ¿Cada endpoint del inventario valida TODOS sus parámetros de entrada (cuerpo, query, path) en el borde, con esquema declarativo?
2. ¿Cada endpoint del inventario pasa por `conLimiteTasa` con opciones explícitas (no default heredado)?
3. ¿Algún endpoint devuelve errores crudos del motor ante entrada inválida (fuga de detalle interno)?
4. ¿Hay endpoints públicos FUERA del inventario (marcados a mano)? Contraste: `grep -rln "sinSesion" apps/api/src/routes`

## Frontera DIFF-CERO

Esta issue produce hallazgos y CREA issues de remediación; NO se corrige nada aquí — el único diff permitido es el reporte (que en este repo va como comentario del tracker: diff de código = CERO). Un fix "de paso" invalida la entrega.

## Formato del entregable (prescrito)

- Resumen ejecutivo: ≤5 líneas.
- Tabla de hallazgos, una fila por hallazgo:

| # | Severidad | Ubicación | Hallazgo | Issue creada |
|---|---|---|---|---|
| 1 | 🔴/🟡 | path:línea | una línea por hallazgo | link — o "descartado: razón" |

- Cada issue hija usa la plantilla de SU tipo y es AUTOSUFICIENTE (baseline, anclas y DoD propios — nunca "ver el reporte").
- Anti-atomización: agrupar por VEHÍCULO de implementación — mismos archivos = misma issue; nunca una issue por hallazgo.

## Criterios de aceptación / DoD

- [ ] Las 4 preguntas respondidas con evidencia path:línea por endpoint del inventario VIVO
- [ ] Diff-cero verificado literalmente: `git status --porcelain | wc -l` → `0` al entregar
- [ ] La fase de endurecimiento puede configurarse SIN decisiones nuevas: cada hallazgo tiene issue hija o descarte razonado en el reporte
- [ ] Cada issue hija pasa el gate de despachabilidad de su plantilla

## Evidencias de cierre exigidas

| Criterio | Evidencia requerida |
|---|---|
| Preguntas respondidas | reporte con la tabla completa y citas por fila |
| Diff-cero | salida literal del comando de estado al momento de entregar |
| Issues hijas | links en la columna "Issue creada" + marcador de tipo válido en cada una |

## Brief del ejecutor

- Conocimiento previo a cargar: `docs/guias/api-publica.md` + el reporte previo `docs/auditorias/2026-05-webhooks.md`
- Patrón a REPLICAR: el formato del reporte previo (prohibido inventar formato nuevo)
- Límites duros: NO corregir hallazgos; NO tocar código/config/datos; NO probar contra producción; NO resolver decisiones no selladas.
- Presupuesto de cambio: 0 archivos — cualquier diff es violación de la frontera.
- Si la premisa de esta issue contradice el código/docs/tests reales: PARAR y escalar con citas verificables — nunca fabricar cumplimiento.
  Destinatario de la escalada: responsable de plataforma (perfil del repo).

## Rúbricas de revisión aplicables

- Baterías activas: S5 sobre el reporte (responder lo preguntado, no ampliar el barrido) · M/S/O/Q aplican a las issues HIJAS
- Revisor de plan: rúbrica canónica §7 de `02-verificaciones.md` — extra del tipo: el plan lista el inventario por comando y el orden del barrido
- Revisor del entregable: formato prescrito completo + frontera diff-cero verificada + hijas despachables · Checks adicionales de ESTA issue: ninguno

## Protocolo de cierre

- Checks requeridos: `git status --porcelain | wc -l` → `0` (no hay build: no hay diff de código)
- Régimen de cierre: cierre manual con evidencia — reporte como comentario + issues hijas enlazadas; confirma el responsable de plataforma, que se queda la priorización de las hijas (decisión diferida, no bloquea); N/A el régimen de tren (esta issue no va en tren)
- PARAR y escalar si: el barrido revela un hueco explotable ACTIVO en producción — se escala AL MOMENTO, sin esperar al reporte completo
