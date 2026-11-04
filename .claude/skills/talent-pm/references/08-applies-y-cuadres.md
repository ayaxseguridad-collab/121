# 08 — Applies y cuadres: el circuito de entrega del lado PM

Fundir no es entregar. Entre el merge y el producto vivo hay un circuito — apply al registro
común, cuadre, promoción — y esta reference define QUÉ verifica y firma el PM en cada paso
cuando ese paso está reservado a su verificación. Delimitación con el resto del skill: la `07`
gobierna el CALENDARIO de estas verificaciones (precarga, parqueo, ráfagas); la `04`, el GO
por-SHA y la verificación del merge (secuencia post-squash); la `05`, la mecánica de huellas;
la `03`, el protocolo cuando el registro común es COMPARTIDO con una contraparte. Esta
reference aporta las restricciones de precedencia del circuito y el CONTENIDO de la medida en
cada paso.

## Table of Contents

- [El circuito: orden parcial, no secuencia total](#el-circuito-orden-parcial-no-secuencia-total)
- [La firma y su unidad atómica](#la-firma-y-su-unidad-atómica)
- [Review real antes del apply](#review-real-antes-del-apply)
- [Cuadre por conjuntos y por nombre](#cuadre-por-conjuntos-y-por-nombre)
- [Desviaciones: se reproducen, no se cotejan](#desviaciones-se-reproducen-no-se-cotejan)
- [Correcciones administrativas al registro común](#correcciones-administrativas-al-registro-común)
- [Merged ≠ desplegado: la promoción](#merged--desplegado-la-promoción)
- [Compatibilidad con el régimen de caudal](#compatibilidad-con-el-régimen-de-caudal)

## El circuito: orden parcial, no secuencia total

Esta reference NO prescribe una secuencia total: define un **orden parcial** — restricciones
de precedencia que toda concreción respeta, tenga la forma que tenga su circuito:

1. La review real ligada al material (ver abajo) precede a su merge y a su apply.
2. El apply al registro común va **antes de cualquier promoción que dependa de él** — el
   código jamás alcanza un entorno vivo cuyo registro aún no está preparado para él.
3. El cuadre precede a su firma.
4. La verificación de promoción cierra la entrega (fail-closed, ver la penúltima sección).

Cada fábrica declara su circuito concreto — incluida la declaración explícita de si su merge
**promociona automáticamente** al entorno vivo: en ese caso, los applies de los que esa
promoción dependa se sitúan ANTES del merge, o la promoción se retiene hasta completarlos.
Qué pasos son RESERVADOS a la verificación del PM lo define la frontera escrita de delegación
(`04`): esta reference define el contenido de la verificación cuando lo son y jamás añade
esperas no reservadas. La detención de parqueo en ausencia del PM (`07`) opera sobre
cualquier concreción del circuito.

## La firma y su unidad atómica

La **unidad de firma es cada ENTRADA aplicada del registro común**: la firma
**cita el par inmutable** (huella sha256 del material, identificador/versión sellado) de esa
entrada exacta. Una firma que cubra una entrega con varias entradas
**enumera todos los pares**, uno por entrada — jamás un par singular representa
implícitamente un lote: el material no citado por su par es material sin firma. La firma
hereda la caducidad del GO por-SHA (`04`): si la base o el material cambian, la firma
anterior no autoriza nada. Las huellas del par se reproducen con comando propio (`05`), nunca
se copian del reporte del productor.

## Review real antes del apply

Nada se aplica al registro común con su review pendiente, simulada, no aprobatoria o
caducada. Antes del apply se verifican TRES cosas: la **transición observada** del evento de
review real en el registro de la plataforma — no el badge (`02`, falsos verdes) —; que la
transición terminó en el resultado aprobatorio de la autoridad requerida (`02`) — una review
que comenta o pide cambios bloquea el gate: **sin resultado aprobatorio no hay apply** —; y
su ligadura al material exacto que se va a aplicar: si el material cambió después del
evento, la review está caducada y se exige una nueva transición antes de tocar el registro.

## Cuadre por conjuntos y por nombre

El registro común se cuadra contra la fuente de verdad **por CONJUNTOS y por NOMBRE** —
diferencia simétrica de identificadores completos — jamás solo por conteo ni solo por
versión: dos conjuntos del mismo tamaño pueden ocultar una entrada desviada con el nombre de
la vecina, y el conteo cuadrado la declara sana.

- La medida del cuadre se toma sobre **UNA instantánea consistente** del registro: un
  snapshot o token de versión que el propio medio ofrezca, o una ventana
  serializada/quiescente pactada en la que nadie más escribe.
- Dos lecturas iguales consecutivas **no constituyen una instantánea**: el conjunto puede
  haberse mezclado entre páginas o sufrido una secuencia ABA sin que ese estado haya existido
  atómicamente jamás.
- Tras la medida rige la barrera de vigencia (`07`): si el conjunto vivo avanzó antes de la
  firma, se relee y reconcilia esa unidad.
- **Huérfano-en-tránsito**: una entrada visible en un solo lado durante una ventana de
  propagación declarada se marca y se re-verifica al cierre de la ventana — ni se firma como
  cuadrada ni se declara incidente antes de tiempo. Si al cierre de la ventana no converge,
  **ALTO y expediente**: el huérfano-en-tránsito dejó de ser tránsito y es un incidente.

## Desviaciones: se reproducen, no se cotejan

Ante un delta detectado (un fichero distinto, una copia derivada, una cifra que no cuadra),
las desviaciones **se reproducen, no se cotejan**: se re-deriva el artefacto con comando
propio (la transformación, el hash del resultado, el diff) hasta atribuir el delta a su causa
exacta — comparar descripciones o metadatos no cierra una desviación. Y el sondeo de que un
cambio llegó a un sistema vivo se hace por el **literal del EFECTO** observable que el cambio
produce, jamás por el símbolo o nombre del cambio: el símbolo puede existir con el efecto sin
desplegar.

## Correcciones administrativas al registro común

Corregir el registro a mano (una entrada mal sellada, un estado zombi) exige, TODO junto:

1. **Dry-run**: ensayo previo de la MISMA sentencia en **transacción abortada**
   (BEGIN…ROLLBACK), leyendo el efecto que tendría sobre el estado real.
2. **Guarda atómica**: la sentencia es idempotente y su WHERE identifica las filas objetivo E
   incluye el valor/versión viejo esperado (**compare-and-set**). Releer el conjunto vivo
   antes de ejecutar (`07`) no sustituye esta guarda: el estado puede cambiar entre la
   relectura y la ejecución.
3. **Cardinalidad exacta**: la ejecución exige el **número exacto de filas** afectadas —
   cero o exceso es ALTO, jamás reintento a ciegas — acreditado por el recibo autoritativo de
   la MISMA mutación/transacción (RETURNING, row count del driver o mecanismo equivalente del
   medio). Una relectura posterior puede verificar la postcondición, pero
   **jamás sustituye ese recibo**: encontrar el valor final esperado no acredita que la
   sentencia propia lo produjera — otro actor pudo haberlo puesto antes, y «cero filas +
   postcondición cumplida» es un falso éxito que pierde la atribución de la mutación.
4. La **doble firma**: autor + la segunda autoridad que la frontera identifique (`04`); si la
   corrección toca superficie reservada al lead, la segunda firma es del lead.

## Merged ≠ desplegado: la promoción

Fundir no es entregar. La promoción a los entornos vivos se verifica contra el SHA inmutable
capturado del registro del merge — el S de la secuencia post-squash (`04`) —
**jamás la cabeza remota móvil**: la cabeza avanza por trenes ajenos y comparar contra ella
fabrica falsos verdes y falsos incidentes.

- La comprobación acepta S **o un commit desplegado que sea descendiente de S**, con la
  ancestría verificada con medida propia Y con el descendiente
  **contenido en la rama principal protegida** del circuito: la ancestría sola prueba que S
  está contenido, no que lo posterior esté autorizado — cada commit intermedio de esa rama es
  una entrega con su propio ciclo de review y autorización, y un descendiente fuera del
  circuito no vale. El registro vivo puede haber avanzado legítimamente después del merge, y
  exigir igualdad exacta fabrica falsos NO-VERIFICADA y convierte al PM en cuello. Una
  fábrica que exija exactamente S lo declara en su **contrato de promoción**.
- El contrato de promoción declara también el **censo de entornos** que forman el conjunto
  obligatorio: la entrega se declara completa solo cuando TODOS los entornos del censo
  verifican — verificar uno no acredita el resto.
- El estado por defecto es fail-closed: una promoción NO-VERIFICADA es una
  **entrega no terminada** — la unidad no se declara completada, su cadena dependiente no se
  libera, y el hueco se reporta como dato de circuito, jamás se asume.

## Compatibilidad con el régimen de caudal

Todo paso de esta reference es precargable, parqueable y ráfaga-compatible (`07`); nada aquí
re-introduce vigilancia: cada verificación es por evento — al caer la entrega, el apply, la
ventana o la promoción — con su checklist precargado y su firma individual.
