# 02 — El bus y los sellos

## Qué es el bus

Un fichero **append-only** donde los roles sellan hitos y del que cada lector consume con **su
propio cursor**. No es una cola: nadie "saca" un mensaje. Todos pueden leerlo entero; lo que cambia
por lector es hasta dónde ha leído.

Ventaja concreta: dos lectores no se pisan, y un lector que se cae y vuelve **no pierde** lo que
pasó mientras no estaba.

## Sellar

`bus-sellar.sh --rol <ID> --marcador <X>` escribe una línea con la hora **medida por el propio sellador**. La
hora no se recibe por parámetro: un sello con hora ajena es un sello que no acredita cuándo pasó
algo, sino cuándo alguien dijo que pasó.

**La estampa exacta del marcador** es `marcador: X]`, con el corchete de cierre. Nunca se busca el
nombre desnudo: `X` a secas casaría con cualquier mención en una nota — «pendiente de X», «X
falló»— y daría un «repetido» falso que impediría sellar el hito de verdad.

| rc | Significa |
|---|---|
| 0 | Sellado |
| 2 | Precondición: bus ausente/ilegible, `src` **es** el bus, lock no adquirible, **identidad del rol no verificable** |
| 3 | **Marcador repetido** — ya estaba sellado |

### La identidad del sellador se VERIFICA; no basta con declararla

La 01 promete que «cada rol sella con su identidad». Comprobar el **charset** de `--rol` no cumple
esa promesa: valida la FORMA del valor, no quién lo presenta, y con eso cualquiera podía sellar
como cualquiera. Ante esa brecha había dos salidas —subir el código hasta la promesa, o bajar la
promesa hasta el código— y **se sube el código**: la promesa era correcta.

El **perfil de instancia** es la autoridad sobre la topología, así que la identidad se deriva de él:

1. **Qué máquina es ésta**: la fila `maquina` que declara `acceso=local`. Si ninguna lo declara, no
   se asume que todo es local — **rc 2** (misma doctrina fail-closed que el relay).
2. **El rol debe existir** como fila `torre|estacion|canal|runner|ceo|pm` y estar **COLOCADO en esta
   máquina**. Un rol que el perfil sitúa en otro host **no puede sellar desde aquí**.
3. **Si esa fila declara `usuario=`**, el usuario real del proceso debe coincidir — identidad del
   sistema operativo, no una afirmación del que llama.

Un rol cuya columna `maquina` es `-` no tiene ubicación declarada y, por tanto, tampoco identidad
verificable: **rc 2**, con ese motivo.

### El separador de registro no viaja dentro del dato

El bus es **una línea por sello**, así que un `LF` (o `CR`) dentro de `--nota` o `--marcador` **no
rompe** la verificación de identidad de arriba: **la esquiva por debajo**. El atacante no discute el
control — escribe una línea NUEVA que ya nace del otro lado de él. Con eso, quien pueda sellar UNA
vez con su identidad real forja un sello atribuido a cualquier rol y **anula justo la comprobación
contra el perfil**.

Por eso ambos campos se **RECHAZAN** si contienen `LF` o `CR`, antes de construir la estampa y antes
del `grep` de duplicados. **No se escapa ni se sustituye**: escapar deja el dato dentro y traslada el
problema a cada lector; sustituir altera en silencio lo que alguien quiso sellar. Es la misma
disciplina de charset cerrado que ya se aplica a `--rol`.

**La ambigüedad en la MISMA máquina se cierra, no se declara.** Antes esto figuraba aquí como
«límite declarado», y declarar un agujero no lo cierra: sólo avisa de que está ahí. Si el perfil
coloca **otro rol en esta misma máquina** y no lo distingue del nuestro por `usuario=`, **no se
sella** (`rc 2`): un sello que pudo firmar cualquiera de los dos no acredita cuál fue. La vía de
arreglo para quien opera es **declarar `usuario=` distintos en el perfil**, no relajar el gate.

**Lo que esto NO promete, dicho aquí y no en una nota al pie.** Cierra la suplantación **entre
máquinas** y la ambigüedad dentro de una, pero **no** protege contra quien escriba el fichero del
bus directamente: quien puede
ejecutar el sellador suele poder escribir el fichero, y eso se detecta por formato, no por permisos.
Sellar exige ahora un perfil legible: **sin perfil no se sella**, porque un sello cuya identidad no
se puede comprobar no acredita nada.

### Dos decisiones que parecen detalle y no lo son

**Identidad, no comparación de rutas.** «¿Este fichero es el bus?» se decide con `-ef`
(dispositivo + inodo). Comparar cadenas deja **cuatro** puertas: ruta relativa, `..`, symlink y
hardlink. Las cuatro tienen test y las cuatro deben dar rc 2.

**Atomicidad real.** La búsqueda del marcador **y** el append ocurren dentro de la **misma** sección
crítica. Si se busca fuera del candado, dos escritores concurrentes del mismo marcador pueden ver
ambos «no está» y sellar los dos: el rc 3 dejaría de significar nada. Hay test con dos escritores
simultáneos: exactamente uno sella y el otro recibe 3.

## Leer

`bus-leer.sh --lector <ID>` emite lo pendiente y avanza el **cursor propio del lector**. Cada lector
tiene el suyo, así que nadie consume el bus para otro.

- **`<ID>` es un charset cerrado** `[A-Za-z0-9_-]{1,32}`. Se acepta una lista blanca en vez de
  rechazar una negra, porque una negra siempre olvida un caso. Un ID fuera del charset es
  precondición (rc 2), no un error de escritura a medias.
- **El cursor se persiste de forma atómica** (temporal en el mismo directorio + `mv`). Escribir en
  sitio deja un cursor a medias si el proceso muere justo ahí.
- **«Leído» significa emitido con éxito.** Si la salida se rompe (tubería cerrada, proceso muerto),
  **no se avanza nada**: el lector volverá a ver ese tramo. Es una decisión conservadora y
  declarada — se prefiere repetir a perder, y no se afirma medir el byte exacto donde se rompió.
- **Cursor mayor que el bus ⇒ rc 2**, sin tocar el cursor. Pasa cuando el bus se trunca o rota;
  emitir desde ahí daría vacío y el lector se creería al día: fail-open. El diagnóstico imprime
  cursor y tamaño **pero no vuelca el bus** — un mensaje de error no es un canal de fuga.
  La comprobación acota además la **magnitud** del cursor, no sólo su charset: un valor de todos
  dígitos que no quepa en un entero de 64 bits hacía que la comparación **errase** en vez de
  comparar, y el cursor se colaba hasta un `$((pos + 1))` que desbordaba a 1 — se re-emitía **el bus
  entero con rc 0** y se reescribía el cursor. Un rebobinado silencioso por la puerta de al lado de
  la guarda que existe para impedirlo. Corrupto ⇒ mismo cubo que «supera el tamaño».
- **Emisión interrumpida ⇒ rc 2**, y el cursor tampoco se toca. Antes devolvía **0**: el consumidor
  recibía «te entregué el tramo» cuando el lector no sabe cuánto llegó al otro lado. Repetir el
  tramo es seguro; decir «bien» sin saberlo, no. Un `bus-leer | head` da ahora rc 2, y eso es la
  respuesta correcta: la lectura no se completó.

## Escalar al bus y re-acreditar: el rastro durable de un bloqueo

El bus es el único canal que ve la capa superior: lo que vive solo en un pane **no existe** para ella. Dos
consecuencias, desarrolladas en la ref 07:

- **Escalado obligatorio al bus.** Todo bloqueo que requiera autoridad superior se sella ANTES de esperar:
  marcador `ESCALA-<ROL>-<ref>`, nota `BLOQUEO-AUTORIDAD · espera:<rol> · decisión · default`; el ruling se
  acusa con `ACK-<ROL>-<ref>`. Esperar en silencio en un menú es el fallo que este protocolo existe para
  impedir.
- **Un «SELLO …» escrito en un pane NO es un sello.** Sellar es ejecutar `bus-sellar.sh`. Tras un `/clear`, un
  reinicio o una sesión nueva, un actor persistente queda NO ACREDITADO hasta re-acreditar con
  `reacreditar.sh` (sello `ACRED-<ROL>-<nonce>` posterior a un cebado). `/clear` está prohibido en actores
  persistentes.
## Precreaciones: qué se comprueba y qué NO se promete

Antes de escribir, se rechaza (rc 2) que el directorio de cursores, el cursor o el lock **ya
existan** siendo symlink o no regulares, y se exige que el directorio sea del UID actual y `0700`.
**`-L` se pregunta antes que `-d` o `-f`**: un symlink a un directorio satisface `-d`, así que
preguntar primero por directorio deja pasar justo el ataque que se quiere impedir.

**Modelo de amenaza, declarado sin adornos**: frente a un proceso del **mismo UID** con permiso de
escritura **no hay garantía criptográfica posible**. El contrato es, literalmente, *«no seguimos
symlinks preexistentes y fallamos si el destino no es regular»*. Una carrera entre la comprobación
y la escritura, ganada por un proceso del mismo UID, **queda fuera del claim**. Se dice aquí para
que nadie lea en estas guardas una promesa que no hacen.

Los locks viven **fuera de `/tmp`**: `/tmp` es mundo-escribible y compartido, y un lock ahí es un
punto de precreación para cualquier proceso de la máquina.
