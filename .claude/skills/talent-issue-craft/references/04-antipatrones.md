# Anti-patrones — Catálogo Evidenciado

12 anti-patrones de issues medidos en un corpus real de ~2000 issues de una plataforma en producción operada con agentes ejecutores y revisores (16 rechazos de fusión analizados con sus hilos completos, 53 duplicadas, 179 canceladas, 27 bloqueadas, y una franja final degradada). Cada uno con su frecuencia, causa raíz y el elemento de plantilla que lo previene.

## Table of Contents

1. [Los 12 anti-patrones](#1-los-12-anti-patrones)
2. [El hallazgo contraintuitivo: longitud ≠ calidad](#2-el-hallazgo-contraintuitivo-longitud--calidad)
3. [La degradación por prisa (y su antídoto)](#3-la-degradación-por-prisa-y-su-antídoto)
4. [Gotchas & Cross-References](#4-gotchas--cross-references)

---

## 1. Los 12 anti-patrones

### AP-1 — Decisión abierta dentro de la issue

**Evidencia**: 3 de 16 rechazos de fusión: decisiones de producto/dominio (valores de parámetros, contratos de comportamiento, "re-aplicar o retirar") sin sellar, resueltas por comentario a mitad de vuelo o nunca — el trabajo entregado materializó una interpretación que nadie había decidido.
**Previene**: bloque Decisiones con régimen de 3 estados + gate "cero decisiones abiertas sin régimen" (`01` §4.6). Si hay una abierta que bloquea, la issue NO despacha; si está diferida con default, el ejecutor implementa el default y tiene PROHIBIDO resolverla.

### AP-2 — Invariantes existentes no enumeradas

**Evidencia**: los 2 rechazos MÁS CAROS del corpus: regresiones de comportamiento que la rama principal tenía en verde (una composición de datos heredada, y suites e2e que pasaban antes del cambio). La issue nunca dijo "esto no debe cambiar" ni qué suite lo protege.
**Previene**: bloque "Invariantes que NO deben cambiar" con la suite/spec nombrada por invariante. El revisor de código corre ESAS suites, no "los tests".

### AP-3 — Clase de cambio deshonesta

**Evidencia**: el rechazo más costoso en rondas (11+): un rediseño de modelo de datos en superficie de dinero disfrazado de "fix"; y un lote que mezclaba una parte dura con observabilidad cosmética. El revisor descubre a mitad de review que está auditando otra cosa.
**Previene**: el marcador `type=` honesto + regla de corte: cambio de modelo de datos o superficie de dinero = issue propia, jamás mezclada. El tipo lo declara el autor y lo verifica el gate de despachabilidad, no se descubre en review.

### AP-4 — DoD no verificable o contradictoria con el alcance

**Evidencia**: 2 de 16 rechazos: un "fail-closed" sin definición operacional (el revisor y el ejecutor entendieron cosas distintas), y un "grep global → 0" imposible porque el alcance difería 4 archivos a otra issue.
**Previene**: DoD como comandos con salida esperada, acotados EXACTAMENTE al alcance (`01` §4.9). El gate de despachabilidad rechaza el DoD-eslogan.

### AP-5 — Colisión con trabajo en paralelo

**Evidencia**: 3 de 16 rechazos: base obsoleta, trabajo ya superseded por otra rama fusionada, o dos issues en vuelo tocando el mismo archivo.
**Previene**: "Artefactos tocados" (permite detectar intersección ANTES de despachar en paralelo) + baseline verificado con fecha y commit + "decisiones ya integradas que respeto" con referencia.

### AP-6 — Checklist de seguridad no repetida por issue

**Evidencia**: los MISMOS hallazgos de seguridad rebotaron en issues distintas (función privilegiada sin revocación de permisos, test de acceso corrido con el rol equivocado, endpoint sin gate de administrador): cada issue re-descubrió la lección de la anterior.
**Previene**: variante `seguridad` con batería fija activada por trigger de superficie (auth/pagos/credenciales/datos personales) — la checklist vive en el skill y se activa sola, no depende de la memoria del autor.

### AP-7 — Una issue por hallazgo, sin vehículo

**Evidencia**: 41 de 53 duplicadas (77%): olas de auditoría que crearon N issues con el MISMO fix en los MISMOS archivos, deduplicadas después a mano hacia un canónico.
**Previene**: regla de origen "hallazgo de revisión": agrupar por VEHÍCULO de implementación (mismos archivos = misma issue). El overlay del tipo `spike-auditoria` la trae impresa en el formato del entregable.

### AP-8 — Ingesta externa sin cruce con el backlog vivo

**Evidencia**: 10 de 53 duplicadas: propuestas de usuarios ingestadas sin buscar si ya existía trabajo equivalente en curso.
**Previene**: regla de origen "propuesta de usuario": dedupe OBLIGATORIO (título + descripción + comentarios) antes de crear, y la propuesta cruda vive como solicitud de cliente enlazada, no como issue duplicada.

### AP-9 — Sobre-planificación en cascada

**Evidencia**: ~139 de 179 canceladas (78%): épicas enteras con specs detalladísimas escritas meses antes, purgadas en bloque cuando el roadmap pivotó. Todo ese detalle fue coste hundido.
**Previene**: eje de madurez — `placeholder` de 5 líneas máximo para horizonte lejano; la plantilla completa SOLO al entrar en ventana de despacho (`01` §5).

### AP-10 — Dependencia en prosa, sin dueño que la empuje

**Evidencia**: 27 issues bloqueadas, la mayoría con el bloqueo enterrado en prosa o en un comentario; el patrón más caro: "depende de un dato del responsable que nadie está pidiendo porque ninguna issue viva lo empuja" — bloqueo silencioso indefinido.
**Previene**: dependencias SIEMPRE como relación del tracker (bloqueada-por), y si el desbloqueador es una persona, issue-decisión asignada a ella con prioridad heredada (`01` §4.6). El gate de despachabilidad rechaza bloqueos activos.

### AP-11 — Afirmaciones de producto/versión sin fuente de verdad

**Evidencia**: 3-5 de 16 rechazos (los de mayor volumen de texto): issues sobre documentación viva con semántica de API, precios o versiones de terceros incorrectos — el detalle era abundante y estaba MAL.
**Previene**: overlay de vendor-claims verificados (variante `doc-vivo`, y tipos `docs-adr` y `contenido-datos`): cada afirmación factual lleva URL oficial + fecha de verificación, con instrucción de re-verificar al ejecutar; **lo no verificable se elimina**, no se hereda.

### AP-12 — Stub de follow-up sin estructura

**Evidencia**: la franja final del corpus degradó a stubs de ~500 caracteres de mediana con 3% de DoD y 8% de criterios — issues de seguimiento escritas "de memoria" tras un rechazo o hallazgo, que heredan el contexto de una conversación que el ejecutor no vio.
**Previene**: regla de origen "follow-up": estructura mínima obligatoria aunque sea urgente — contexto con enlace al origen + alcance en paths + ≥1 criterio verificable. Sin eso, no entra a la cola (`01` §6).

---

### Cómo se retroalimentan (y dónde corta el sistema)

```text
hallazgos atomizados (AP-7) ──> dedupe masivo ──> prisa ──> stubs (AP-12)
        │                                            │
        │ regla de VEHÍCULO                          │ estructura mínima + gate
        ▼                                            ▼
   una issue por fix                        audit-issue exit≠0 si falta
        │                                            │
        └────────> plantilla del tipo <──────────────┘
                   (campos duros: decisiones, invariantes, DoD, artefactos)
                              │
              rechazo en review ──> loop post-rechazo ──> iterar plantilla
```

## 2. El hallazgo contraintuitivo: longitud ≠ calidad

Las issues MÁS LARGAS del corpus (13-30k caracteres, con contexto, DoD y checkboxes) rebotaron igual que las cortas — por correctitud de dominio (AP-11) y DoD mal acotada (AP-4), no por falta de detalle. Y las issues gold más efectivas de tipo contenido eran las MÁS CORTAS del corpus (1.5-3k), porque el procedimiento pesado vivía en una guía canónica y la issue aportaba instancias + salvaguardas.

Conclusión de diseño (que este skill implementa): la calidad vive en **campos duros verificables** — decisiones selladas, invariantes nombradas, DoD ejecutable acotado, artefactos tocados — y en **referenciar doctrina canónica** en vez de repetirla. Un auditor automático puede verificar la presencia y forma de los campos duros; ningún auditor salva a una issue larga y equivocada.

---

## 3. La degradación por prisa (y su antídoto)

Medido por franjas temporales del corpus: la calidad estructural colapsó en la etapa de mayor velocidad del equipo —

| Franja | Longitud mediana | % con criterios | % con DoD |
|--------|------------------|-----------------|-----------|
| Era de plantilla madura | ~5.200 chars | 50% | 66% |
| Franja siguiente | ~1.300 chars | 39% | 13% |
| Franja final (máxima prisa) | ~500 chars | 8% | 3% |

La lección: la calidad de issues NO se sostiene por cultura cuando sube el ritmo; se sostiene por **plantillas con gate** (despachabilidad + auditor con exit-code). Ese es el enforcement mínimo que este skill trae de serie, y la escalera del perfil del repo decide cuándo se corre.

---

## 4. Gotchas & Cross-References

1. **Prevenir AP-1 no es sellarlo todo** → el régimen de 3 estados permite diferir deliberadamente; lo que elimina es la decisión huérfana.
2. **AP-7 y AP-12 se retroalimentan** → hallazgos atomizados generan stubs; la regla de vehículo corta la cadena en el origen.
3. **AP-9 no prohíbe planificar** → prohíbe pagar detalle caro ANTES de la ventana de despacho; el placeholder mantiene el horizonte visible a coste cero.
4. **AP-11 aplica también a este skill** → toda afirmación sobre el tracker en `03-linear-nativo.md` lleva fuente y fecha, y se re-verifica al ejecutar.
5. **La tabla de §3 es el argumento del enforcement** → si un equipo debate "¿hace falta el gate?", enseñarle su propia franja de prisa.

**Related reference files:**

- Los campos que previenen cada AP → `01-nucleo-y-despachabilidad.md`
- Las baterías que los revisores aplican → `02-verificaciones.md`
- El mapeo de dedupe/relaciones/solicitudes de cliente al tracker → `03-linear-nativo.md`
