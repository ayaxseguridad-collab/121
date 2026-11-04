# 06 — Paso-0 y bancos de regreso

## El paso-0 canónico

Tras un relanzamiento, un compact o cualquier corte, **el paso-0 canónico** se hace **antes** de
retomar nada. No es ceremonia: un agente que reanuda sobre supuestos rehace trabajo hecho o pisa
trabajo vivo.

1. **Leer el banco de regreso entero** y **citar su hash** en la primera respuesta. Citarlo obliga
   a haberlo leído; sin eso, «lo recuerdo» y «lo he leído» son indistinguibles desde fuera.
2. **Verificar la configuración del canal**. Lo que no sea legible desde dentro **se pregunta**,
   no se supone.
3. **No relanzar nada.** Un relanzamiento mata los procesos en vuelo; se re-engancha **por sus
   logs**, no volviendo a lanzarlos. Relanzar duplica trabajo y, si el primero seguía vivo,
   produce resultados que no se pueden interpretar.
4. **Comprobar que no hay procesos propios vivos** antes de declararse esperando algo. Un bloqueo
   que murió con su proceso **no avisa**: un canal parado se ve; uno que *cree* que espera, no.
5. **Verificar el estado real de las ramas** y de lo entregado, por comando, no de memoria.

## El banco de regreso

Un fichero **fuera del árbol de trabajo** que permite a otro —o a uno mismo tras un corte— retomar
sin arqueología.

**Qué lleva, y por qué cada cosa:**

| Contenido | Por qué |
|---|---|
| **Estado ahora mismo**, en una lectura | Lo primero que se lee y lo que más envejece |
| **Rama y hash** de cada repo tocado | Un identificador de memoria es una foto del instante en que se escribió |
| **Qué queda vivo**, con su dueño | Distinguir «pendiente mío» de «pendiente de otro» evita esperas mutuas |
| **Lo NO verificado, dicho como tal** | Un banco que mezcla medido y supuesto contamina todo lo que afirma |
| **Las leyes de método** que costaron rondas | Es lo único que no se puede recuperar leyendo el repo |

**Reglas que hacen que un banco sirva:**

- **Se escribe en un checkpoint limpio**, no a mitad de trabajo fino.
- **Los identificadores se derivan de un comando**, nunca se teclean de memoria.
- **Coherencia interna**: si el encabezado dice una cosa y una sección dice otra, el banco es peor
  que no tener banco — la contradicción se descubre tarde y desde el lado equivocado.
- **Lo que ya está en el repositorio no va al banco.** El banco es para lo que no deja rastro:
  decisiones, adjudicaciones, callejones descartados y por qué.

## Higiene de contexto

Cuando la ventana de contexto se acerca al umbral, **se escribe el banco ANTES de compactar** y se
compacta en un checkpoint limpio. La doctrina completa vive en `talent-context`; aquí solo se
recoge lo que el mando necesita: **un canal no se autocompacta a mitad de una ronda**, y quien
coordina decide cuándo.

## Tras un `/clear`, un reinicio o una sesión nueva: NO ACREDITADO

El paso-0 reconstruye el estado; **no acredita al actor**. Un actor persistente que vuelve de un `/clear`,
de un reinicio o de una sesión nueva queda NO ACREDITADO hasta re-acreditar (`reacreditar.sh --iniciar`,
sellar `ACRED-<ROL>-<nonce>`, `--verificar`; ref 07). Hasta entonces no despacha, no relaya y no sella
hitos. `/clear` está prohibido en actores persistentes: pierde el contexto sin el ritual de relevo.
## Al volver

Reanudar es **continuar**, no reiniciar. Si un turno se cortó por transporte, se retoma **desde
donde cortó**: un corte de red no invalida lo que ya está en disco. Antes de rehacer algo, se
comprueba si ya está escrito — y si lo está, se verifica en vez de reescribirlo.
