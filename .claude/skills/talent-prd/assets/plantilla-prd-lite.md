<!-- prd: estado=DRAFT version=0.1 supersedes=- appetite=lite -->

# PRD — <nombre del producto>

| Campo | Valor |
|---|---|
| Estado | DRAFT |
| Version | 0.1 |
| Supersedes | — |
| Appetite | lite |

> Nivel Lite: 9 secciones. Para un producto que cabe en 1-2 semanas de trabajo.
> Rellena TODAS las secciones; si una no aplica, escribe por que no aplica (una linea).
> Cuando el documento este aprobado, cambia `estado=DRAFT` a `estado=APPROVED` en la
> primera linea Y actualiza la tabla de abajo para que diga lo mismo (la linea de
> comentario es la fuente de verdad; la tabla es su espejo humano). Si lo reescribes
> despues, crea un fichero nuevo con `supersedes=<version anterior>` — nunca edites
> un APPROVED por encima.

## 1. Resumen y pitch

<2-4 frases: que es, para quien, que cambia cuando existe. Si no cabe en 4 frases, no
esta claro todavia — vuelve al interrogatorio.>

## 2. Problema y persona

<La persona tiene NOMBRE (real o arquetipo con nombre propio). Que hace hoy sin tu
producto y que le cuesta. Evidencia de que el problema existe, no intuicion.>

## 3. Wedge

<La cunia minima: el caso de uso mas pequenio que YA cambia algo para la persona.
Por que ahora y no hace dos anios. Por que tu.>

## 4. Alcance del appetite

<Que entra en este appetite y que se queda fuera A PROPOSITO. Modo de alcance elegido
(A/B/C si evaluaste alternativas) y por que.>

## 5. Historias de usuario

<Formato: Como <persona>, quiero <accion>, para <resultado>. 3-7 historias, ordenadas
por el recorrido del walking-skeleton, no por modulos.>

- Como ..., quiero ..., para ...

## 6. Criterios de aceptacion

<Cada criterio es OBSERVABLE y binario. Un revisor externo debe poder marcarlo sin
preguntarte nada. Minimo un par PASA/FALLA por historia critica.>

- PASA si: <condicion observable>
- FALLA si: <condicion observable>

## 7. No-gos

<En positivo: no digas solo lo que NO haras — di que haras EN SU LUGAR.>

- NO haremos <X>; en su lugar: <Y>.

## 8. Fases walking-skeleton

<Fase 1 = el esqueleto que camina: el recorrido completo extremo a extremo, feo pero
entero. Cada fase posterior engorda el esqueleto, nunca anade un miembro suelto.>

1. Esqueleto: <recorrido minimo completo>
2. <fase 2>
3. <fase 3>

## 9. Riesgos y premisas

<Cada premisa con su plan de verificacion: que harias en 2 semanas para descubrir que
NO funciona. Los riesgos que decidiste aceptar, dichos con esas palabras.>

- Premisa: <...> · Como se verifica: <...>
- Riesgo aceptado: <...>
