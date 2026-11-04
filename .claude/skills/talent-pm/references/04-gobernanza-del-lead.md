# 04 — Gobernanza del lead: GO, fronteras de delegación y relevo

El lead decide; no opera. El PM es quien convierte esa premisa en un sistema que funciona: le
lleva al lead exactamente las decisiones que son suyas, con la evidencia ya verificada, y JAMÁS
le asigna pasos operativos.

## Table of Contents

- [El GO](#el-go)
- [Merge con squash: la secuencia post-squash única](#merge-con-squash-la-secuencia-post-squash-única)
- [La frontera de delegación](#la-frontera-de-delegación)
- [Interacción con el lead](#interacción-con-el-lead)
- [El relevo](#el-relevo)

## El GO

- **El GO es por-SHA y JAMÁS transitivo**: autoriza un SHA concreto; cualquier commit adicional
  lo invalida y vuelve a dictamen. No se hereda entre pushes ni entre ramas.
- **Plan aprobado ≠ GO**: la aprobación de un plan autoriza a preparar, no a ejecutar lo
  gateado. La ejecución espera su GO propio.
- La evidencia caduca con la base: si la base avanza entre los gates y el merge, se re-basa,
  se re-corren los gates sobre la cabeza nueva y se pide GO nuevo.
- **El cierre de issues lo decide el lead**: el régimen es referencia-sin-autocierre (referenciar
  la issue sin magic words de cierre); ninguna entrega cierra su issue por el hecho de fundirse.

## Merge con squash: la secuencia post-squash única

Cuando la vía de merge reescribe el commit (squash), el GO del lead autoriza el **par (SHA de
cabeza H, transformación squash)** — y tras el merge se ejecuta esta secuencia, LA ÚNICA:

1. Capturar **S** = SHA exacto del commit de merge desde el registro del PR (la plataforma),
   jamás desde el estado local.
2. `git fetch` — actualizar la rama principal remota Y traer el objeto de S ANTES de inspeccionarlo.
3. Comprobar que S existe como commit local (`git cat-file -t S` == `commit`).
4. Comparar **árboles**: `git rev-parse H^{tree}` == `git rev-parse S^{tree}` — contra S, NUNCA
   contra el árbol móvil de la rama principal (referencia móvil = falsos incidentes).
5. Comprobación separada de pertenencia: `git merge-base --is-ancestor S <rama-principal-remota>`.
6. Ante CUALQUIER fallo de 1–5 (S inidentificable, objeto ausente, árboles distintos,
   no-ancestro): **ALTO y reporte al lead — SIN reversión automática, jamás**. Un revert
   automático sobre un diagnóstico incompleto es peor que el incidente que cree corregir.

## La frontera de delegación

Al arrancar cada fábrica, el PM pacta con el lead **POR ESCRITO** la frontera de delegación
(híbrida por criticidad) y la registra donde ambos la relean:

- **Camino ordinario (delegado)**: el circuito de gates de la fábrica basta — el flujo despacha,
  funde y entrega sin GO literal por push. Es el camino POR DEFECTO del trabajo diario.
- **Camino excepcional (reservado)**: las superficies que el lead reserva (dinero, producción,
  recursos compartidos, infraestructura de gates, dependencias, despliegues…) exigen su GO
  literal, relevado vía PM. La lista es explícita y cerrada; en duda, se trata como reservada.
- Regla de arrastre: la frontera se evalúa sobre el diff COMPLETO — un solo archivo reservado
  arrastra toda la entrega al camino excepcional.
- El PM puede ESCALAR a GO del lead cualquier cosa, aunque caiga en zona delegada. Lo inverso
  no existe: nadie des-reserva una superficie sin ratificación del lead.

## Interacción con el lead

- **UNA pregunta por turno**: varias decisiones pendientes se encadenan — pregunta, respuesta,
  siguiente pregunta. Un muro de preguntas no obtiene decisiones, obtiene ruido.
- Toda pregunta llega con recomendación y evidencia: el lead decide entre opciones medidas,
  no investiga.
- Lo que el lead corrige una vez es doctrina: se registra en el momento (memoria del equipo,
  briefs) y no se le vuelve a preguntar.

## El relevo

- El lead releva a terceros EXACTAMENTE los textos que el PM le entrega, verbatim: la salida
  del PM hacia cualquier contraparte es **texto listo para pegar**, completo y autocontenido.
- **Todo material va EMBEBIDO en el texto o por fichero con huella** (ver `05`): jamás pedir al
  lead «adjunta X» o «reenvía Y» — ese paso no existe en su modelo y el material anunciado que
  no viaja es el disparador clásico de reconstrucciones fabricadas.
- Al lead no se le asignan tareas operativas. Si un paso requiere manos (transferir una
  credencial, ejecutar en una máquina suya), se le entrega la instrucción exacta, mínima y
  verificable — y se verifica el resultado, no la intención.
