# Incidentes y Fixes en Caliente — Complete Reference

## Table of Contents

1. [Triaje: ¿qué tan roto está?](#1-triaje-que-tan-roto-esta)
2. [La decisión de exposición es del lead](#2-la-decision-de-exposicion-es-del-lead)
3. [Fix en caliente: el ciclo comprimido SIN saltarse nada](#3-fix-en-caliente-el-ciclo-comprimido-sin-saltarse-nada)
4. [Diagnóstico antes de alarma](#4-diagnostico-antes-de-alarma)
5. [El bucle de gotchas](#5-el-bucle-de-gotchas)
6. [Gotchas & Cross-References](#6-gotchas--cross-references)

---

## 1. Triaje: ¿qué tan roto está?

```text
Reporte (lead con captura / carril / alumno vía lead)
  │
  ▼
Q: ¿Funcional o estético?
├── FUNCIONAL (datos mal, acción rota, seguridad) → severidad alta:
│   ¿hay flag que lo apague? → proponer OFF inmediato al lead + issue Urgent
└── ESTÉTICO/UX (layout, cortes, desbordes) → diagnóstico primero (§4),
    issue High/Urgent según exposición, decisión de exposición al lead (§2)
```

Verificar SIEMPRE antes de actuar: ¿es el bug nuevo del deploy o uno
PREEXISTENTE que la novedad hizo visible? (Caso real: el corte del tour a
anchos medios era un bug del shell de semanas atrás — separarlo evitó
"arreglar" lo que no estaba roto.)

## 2. La decisión de exposición es del lead

Con algo feo-pero-funcional VIVO para usuarios, el coordinador NO decide si
se apaga: presenta la disyuntiva en TEXTO PLANO (una pregunta, sin menú):

```text
"¿Lo dejamos encendido mientras se arregla o lo apagamos hasta el fix?"
├── Apagar hasta el fix (recomendada si es la primera impresión del usuario):
│     llave OFF en segundos, fix con calma, re-encendido validado
└── ON mientras se arregla: fix en caliente con prioridad Urgent,
      el coste de imagen lo asume el lead conscientemente
```

Sea cual sea la elección: registrarla en la issue de la ventana/feature
("Decisión del lead: mantener ON — el fix va en caliente").

## 3. Fix en caliente: el ciclo comprimido SIN saltarse nada

```text
issue Urgent (In Progress, spec con los fallos EXACTOS observados +
  los que la auditoría encuentre — "todo fallo encontrado se corrige")
  → prompt al carril más afín DISPONIBLE (el que está esperando algo, mejor)
  → fix acotado (CERO cambios de mecánica si el fallo es visual — explícito)
  → validación multi-viewport/escenario ANTES del STOP
  → gate EXPRESS (mismo rigor, menos líneas) → merge → deploy
  → validación final de QUIEN DETECTÓ el fallo (el ojo del lead cierra lo
    que el ojo del lead abrió)
```

"En caliente" comprime los TIEMPOS, no los PASOS. El tercer merge-sin-gate
del proyecto fue un fix en caliente — y la regla quedó: la urgencia no exime
el gate (un gate de CSS tarda minutos).

Feedback de producto durante el incidente ("no quiero scroll, prefiero dos
filas") = issue NUEVA con la cita textual, no un alcance que se infla en
silencio.

## 4. Diagnóstico antes de alarma

Con una captura del lead ("mira esto"), ANTES de crear issues:

1. **Reproducir la causa, no el síntoma**: ¿qué viewport/zoom/estado exacto?
   (El "no responsivo" del lead a pantalla completa era un mínimo de 1115px
   de shell con su pantalla en ~1000px efectivos.)
2. **Localizar el componente REAL** (grep/Read del código, no suposición) y
   citarlo en la issue con paths.
3. **¿Ya está capturado?** Un bug puede estar diagnosticado en una issue de
   Backlog de otra pieza (pasó: el corte era TAL ya documentada por otro
   carril) → subir prioridad y despachar, no duplicar.
4. Separar fallos independientes en issues independientes (un corte de shell
   + un roadmap con scroll no deseado = 2 issues, 2 carriles, paralelo).

## 5. El bucle de gotchas

Después de CUALQUIER error o sorpresa (del coordinador o de un carril):

```text
gotcha en .claude/memory/gotchas.md (fecha, categoría, qué pasó, causa raíz,
PREVENCIÓN accionable) → viaja en el siguiente PR del carril que lo vivió
→ el coordinador lo PROPAGA (los demás carriles lo reciben en su siguiente
  prompt si les aplica)
→ 3+ ocurrencias del mismo patrón = promover a regla del proyecto (CLAUDE.md)
→ las "ocurrencias" se actualizan: un gotcha con 2ª ocurrencia documentada
  vale el doble que dos gotchas sueltos
```

El coordinador alimenta el bucle también con SUS errores (una columna
asumida que no existía, un shape inventado) — la memoria es de todos.

## 6. Gotchas & Cross-References

1. **El rollback por flag es la red, no la vergüenza** → Se documenta en cada
   issue de ola y se ofrece sin dramatismo: "la misma llave a OFF, segundos".

2. **Quien detecta, cierra** → La validación final de un fix visual es de
   quien lo reportó (normalmente el lead). "A mí me se ve bien" del carril no
   cierra.

3. **Agrupar las revisiones del lead** → Tres fixes visuales en vuelo = UN
   vistazo único cuando los tres estén desplegados, no tres interrupciones.
   El coordinador orquesta los tiempos para eso.

4. **El incidente no detiene el tablero** → Mientras un carril arregla, los
   demás siguen su cola; el coordinador solo re-prioriza si el incidente lo
   exige (Urgent real).

Cross-references: ventanas y exposición → `04-trazabilidad-linear.md` §4 ·
gate express → `03-gates-pre-merge.md` · prompts de fix →
`../prompts/plantillas.md`.
