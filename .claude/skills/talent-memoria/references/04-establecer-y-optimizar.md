# 04 · Establecer el sistema y optimizar el indice

Dos momentos de la misma disciplina: como EMPEZAR una memoria que no degenere (si
aun no tienes corpus, empieza aqui — no en el pipeline), y como OPTIMIZAR el indice
de un corpus ya reparado. La regla comun: escribir barato hoy lo que hara la
limpieza casi gratis manana.

## Table of Contents

- [1. Si empiezas de cero](#1-si-empiezas-de-cero)
- [2. Las reglas de escritura que evitan la degradacion](#2-las-reglas-de-escritura-que-evitan-la-degradacion)
- [3. Que NO va a la memoria](#3-que-no-va-a-la-memoria)
- [4. El indice: MEMORY.md compacto](#4-el-indice-memorymd-compacto)
- [5. Indices tematicos](#5-indices-tematicos)
- [6. Mantenimiento periodico](#6-mantenimiento-periodico)

## 1. Si empiezas de cero

No inventes un framework: Claude Code ya siembra una estructura (MEMORY.md como
indice + un fichero por nota) en la memoria general del harness. Este skill la
formaliza y la ordena — la misma estructura sirve para `.claude/memory/` en tu repo:

```text
  memoria/
  ├── MEMORY.md            el indice: UNA linea por nota, con estado embebido.
  │                        Es lo que se carga en contexto cada sesion: cada
  │                        linea de mas aqui es contexto que pagas siempre
  └── <una-nota>.md        una nota = un tema, con frontmatter minimo
```

La nota minima que no da problemas despues:

```text
---
name: decision-gestor-paquetes
description: usamos pnpm, no npm — decidido 2026-07-27 por los workspaces
---
2026-07-27. Elegimos pnpm sobre npm: workspaces nativos y menos disco.
Si algun dia cambia: anular ESTA nota con el patron de 4 campos, no borrarla.
```

Tres cosas y solo tres: **fecha** (sin ella no hay adjudicacion futura), **un tema**
(las notas multi-tema no se pueden anular por partes limpiamente), **description que
resume de verdad** (es lo unico que veran los indices y previews).

## 2. Las reglas de escritura que evitan la degradacion

Cada regla de escritura existe porque su ausencia es uno de los defectos que el
pipeline repara. Escribir bien es reparar por adelantado:

| Al escribir... | ...evitas |
|---|---|
| fecha en toda nota | conflictos in-adjudicables (paso 5 del pipeline) |
| un tema por nota | fusiones dolorosas y anulaciones parciales |
| buscar antes de crear (¿ya hay nota de esto?) | duplicados (paso 1) |
| si cambias de opinion: anular la vieja EN el mismo momento | contradicciones (paso 2) |
| ordenes en imperativo SOLO si son atemporales; lo temporal, con ventana ("hasta X") | normas zombis (pasos 3-4); lo con ventana caduca solo |
| una linea nueva en el indice por nota nueva | indice desincronizado (S6) |
| decidir el canonico ANTES de copiar informacion a otro sitio | espejos divergentes (paso 7) |

La mas rentable de todas: **anular en caliente**. En el momento en que decides
distinto, la nota vieja recibe su bloque de 4 campos (`references/02` seccion 4).
Cuesta 30 segundos con el contexto fresco; en la proxima pasada de limpieza costaria
una adjudicacion entera reconstruyendo el porque.

## 3. Que NO va a la memoria

- **Secretos** (claves, tokens, credenciales): jamas. La memoria se copia, se
  respalda y se comparte con mas facilidad que un gestor de secretos.
- **Lo que el repo ya registra**: estructura del codigo, historial de git, lo que
  dice el CLAUDE.md. La memoria que duplica al repo diverge de el (paso 7 del
  pipeline, pero autoinfligido).
- **Instrucciones de comportamiento estables**: eso es material de CLAUDE.md (nivel
  de autoridad 2), no de una nota (nivel 3). Si te descubres escribiendo la misma
  orden en notas una y otra vez, es que quiere ser CLAUDE.md.
- **Detalle de lujo para un futuro incierto**: una spec enorme escrita meses antes de
  usarla caduca en bloque. Nota corta ahora; el detalle, cuando este en ventana.

## 4. El indice: MEMORY.md compacto

El indice se carga en contexto en cada sesion: optimizarlo es optimizar lo que pagas
siempre. Formato de linea que funciona:

```text
- [Etiqueta corta](fichero-de-la-nota.md) — resumen en media linea, CON estado si lo hay
```

Ejemplos:

```text
- [Gestor de paquetes](decision-gestor-paquetes.md) — pnpm por workspaces (27-jul)
- [Politica vieja de tests](politica-tests-v1.md) — SUPERSEDED 27-jul → v2
```

- El estado va EMBEBIDO en el one-liner: quien lee el indice sabe que esta vivo y que
  no, sin abrir nada.
- Una linea por nota. Si necesitas dos lineas para resumirla, la nota tiene dos temas
  (seccion 2).
- Compactar el indice es el ULTIMO paso de una reparacion, nunca el primero (gotcha
  11: compactar con el corpus sucio es indexar basura con formato bonito).
- Todo cambio de indice se verifica por contenido, no por nombre de fichero — S6,
  `references/03` seccion 8.

## 5. Indices tematicos

Cuando el indice pasa de unas ~40-50 lineas, dividir por tema y cargar bajo demanda:

```text
  MEMORY.md                    <- lo SIEMPRE cargado: estado vivo + punteros
  ├── "## Estado vivo"            5-15 lineas de lo que importa esta semana
  └── "## Indices tematicos"      - [Tema A](indice-tema-a.md) — que cubre
                                  - [Tema B](indice-tema-b.md) — que cubre
  indice-tema-a.md             <- one-liners de todas las notas del tema A
```

El criterio de corte es de USO, no de tamano: lo que consultas cada sesion se queda
en MEMORY.md; lo que consultas cuando trabajas en el tema X se va al indice de X. Un
indice tematico que nunca abres es una senal de que ese tema entero es candidato a
archivo historico.

## 6. Mantenimiento periodico

La reparacion completa (`references/02`) es para corpus degradados; el mantenimiento
evita volver a necesitarla:

- **Al cerrar cada sesion de trabajo intensa**: ¿decidi algo distinto de lo que dice
  alguna nota? → anular en caliente (seccion 2). ¿Nota nueva? → su linea de indice.
- **Cada pocas semanas**: `diagnostico.sh` y mirar SOLO dos numeros: notas sin fecha
  nuevas (deberian ser 0) y rutas muertas nuevas (idem). Si crecen, para y repara —
  esos dos son los que mas caro cuesta reparar tarde.
- **Cuando el indice moleste**: compactar (seccion 4) o dividir (seccion 5). Con el
  corpus limpio, esto es un cambio de indice puro: declarable con filas INDEX y
  verificable con S6 en minutos.

El objetivo del mantenimiento no es una memoria "bonita": es que la proxima vez que
tu agente lea tu memoria, TODO lo que lea sea verdad vigente o historico marcado como
tal. Ese es el estado que este skill llama limpio.
