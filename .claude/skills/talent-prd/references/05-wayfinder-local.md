# 05 · Wayfinder local

El wayfinder es el mapa de decisiones abiertas del producto: un directorio
`wayfinder/` junto al `prd.md`, con una ficha por decision y un indice. Todo en
ficheros locales — sin tracker, sin red, portable con un `cp -r`.

## Table of Contents

- [1. Que es y que no es](#1-que-es-y-que-no-es)
- [2. Estructura de ficheros](#2-estructura-de-ficheros)
- [3. La ficha de decision](#3-la-ficha-de-decision)
- [4. Los cuatro tipos](#4-los-cuatro-tipos)
- [5. El indice](#5-el-indice)
- [6. Ciclo de vida de una decision](#6-ciclo-de-vida-de-una-decision)
- [7. Verificacion mecanica](#7-verificacion-mecanica)

## 1. Que es y que no es

- ES: el mapa de lo que AUN NO esta decidido, con su niebla declarada (que
  sabemos, que no) y el camino para despejarla.
- NO ES una TODO-list. Las tareas ya decididas van al backlog (fase 7); al
  wayfinder solo van DECISIONES — cosas con mas de una respuesta posible que
  bloquean una seccion del PRD. La ficha `tipo=task` existe para el caso raro de
  trabajo-que-despeja (p. ej. "medir X"), no para trabajo de construccion.
- Sirve durante la fase 4 (escalada de fidelidad) y sigue vivo despues: un PRD
  APPROVED puede tener wayfinder con decisiones diferidas a proposito — lo
  importante es que esten mapeadas, no que esten todas cerradas.

## 2. Estructura de ficheros

```text
<producto>/
├── prd.md
├── backlog.md
└── wayfinder/
    ├── INDICE.md              <- el mapa: una linea por decision
    ├── eleccion-stack.md      <- una ficha por decision, slug en kebab-case
    └── modelo-de-precio.md
```

Una decision = un fichero. El nombre del fichero es el slug de la decision. Sin
subdirectorios: si el wayfinder crece tanto que pide carpetas, el producto pide
partirse en dos PRDs.

## 3. La ficha de decision

Plantilla en `assets/plantilla-decision.md`. Frontmatter obligatorio:

```text
---
decision: eleccion-stack
tipo: research | grilling | prototype | task
estado: abierta | en-curso | resuelta
bloqueos: []
---
```

- `decision`: el slug, igual que el nombre del fichero (sin `.md`).
- `tipo`: uno de los cuatro (seccion 4).
- `estado`: `abierta` -> `en-curso` -> `resuelta`. No hay "descartada": una
  decision que deja de importar se resuelve con "ya no aplica, porque X".
- `bloqueos`: lista YAML de flujo con los slugs de otras decisiones que esta
  espera — `[]` si no espera ninguna, `[eleccion-stack, modelo-de-precio]` si
  las hay. Un escalar suelto (`-`) no es una lista y el verificador lo rechaza.

Cuerpo: la pregunta como H1, el contexto, la seccion `## Frontera` (Sabemos /
Niebla — que evidencia hay y que falta), `## Como se resuelve` y `## Resolucion`
(vacia hasta que se resuelve; al resolverse: respuesta, fecha y que `§N` del PRD
cambia).

## 4. Los cuatro tipos

| tipo | La decision se despeja... | Ejemplo |
|---|---|---|
| research | leyendo/buscando evidencia que ya existe | ¿que limite de rate tiene la API de pagos? |
| grilling | respondiendo una pregunta incomoda con evidencia propia | ¿pagaria alguien 10/mes? pregunta a 5 personas |
| prototype | construyendo lo minimo que la responde | ¿aguanta la latencia? maqueta y medir |
| task | ejecutando trabajo ya decidido que la desbloquea | medir el volumen actual de datos |

Elegir el tipo es elegir el coste: research < grilling < prototype. Si un
prototype despeja lo mismo que una busqueda, el prototype es teatro caro.

## 5. El indice

`wayfinder/INDICE.md` — una linea por decision, formato fijo:

```text
# Wayfinder — <producto>

- [eleccion-stack](eleccion-stack.md) — research — abierta — bloquea §15
- [modelo-de-precio](modelo-de-precio.md) — grilling — resuelta — cambio §13
```

Reglas:

- Toda ficha del directorio esta en el indice; toda linea del indice tiene su
  ficha. Las dos direcciones — un indice que miente es peor que ninguno.
- La coletilla final dice que seccion del PRD bloquea (abierta) o cambio
  (resuelta): el wayfinder siempre apunta al documento, como el backlog.

## 6. Ciclo de vida de una decision

```text
  nace (fase 2-4: una pregunta sin respuesta unica)
    |            ficha con frontera declarada + linea en INDICE.md
  abierta ----> en-curso (alguien la esta despejando)
    |
  resuelta: Resolucion escrita + fecha + §N del PRD actualizado
             la ficha NO se borra — es el registro de por que se decidio
```

- Resolver = escribir la Resolucion Y actualizar la seccion del PRD que
  bloqueaba (con version nueva si el PRD estaba APPROVED).
- Las fichas resueltas se quedan: son la memoria de decision del producto. Quien
  pregunte "¿por que este stack?" dentro de seis meses tiene la respuesta con
  fecha y evidencia.
- Si una decision `abierta` bloquea el appetite entero, el PRD no deberia llegar
  a la review: despejala o recorta el alcance para que deje de bloquear.

## 7. Verificacion mecanica

`scripts/verificar-prd.sh <dir>` comprueba del wayfinder (si existe):

- `INDICE.md` presente.
- Consistencia bidireccional ficha↔indice.
- Frontmatter de cada ficha: `tipo` valido, `estado` valido.

Lo que NO comprueba (y es juicio de la review): que la frontera sea honesta, que
el tipo elegido sea el barato, que las resueltas hayan actualizado su `§N`.
