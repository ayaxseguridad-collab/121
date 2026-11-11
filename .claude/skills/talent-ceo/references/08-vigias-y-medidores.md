# 08 — Vigías y medidores del mando

Esta referencia reúne los instrumentos con los que el CEO comprueba el estado real de la fábrica antes
de actuar: cada uno es un script de **solo preparación y comprobación** que dice en voz alta lo que
midió y se niega a dar un verde que no ha verificado. Los apartados se añaden por pieza y ninguno
redefine a otro: cada apartado trae su ley, su comando, sus rc exactos y lo que NO hace.

| Apartado | Comando | Cuándo |
|---|---|---|
| Cuotas | `lector_cuotas.py eventos` | Cada 5 min para saber cuánto saldo queda y si la cuenta de Codex cambió |
| Canario | `canario-main.sh` | Tras cada fusión, para saber si `main` sigue verde |
| Sellador | `bus-sellar.sh` | Al sellar: avisa de una hora que el reloj desmiente |
| Runners al día | `runners-al-dia.sh` | Antes de lanzar cualquier prueba en un runner |
| Vigías | `vigias.sh` (y los cinco vigías que arma) | Al armar el monitor del mando, o al ver que un monitor calla |

## Cuotas

**Ley.** Con la ventana semanal de Codex al 100 %, lo que corre consume **saldo**, no cuota, y esa lectura sin
saldo era indistinguible de una cuenta agotada. El lector (`scripts/lector_cuotas.py`, en la raíz del paquete)
expone el saldo en un campo aditivo `credits` y un subcomando `eventos` avisa **por transición**, no por nivel:
cuando cambia la cuenta, cuando el saldo baja un tramo o cruza un umbral, cuando se agota y cuando la ventana se
libera. Los reinicios de ventana (`reset_credits`) solo se **cuentan**: este lector nunca los consume, es
decisión del lead en cada caso.

```bash
# Lectura (JSON normalizado, sin token): `credits` solo en una lectura viva de Codex; `null` en cualquier otra
python3 scripts/lector_cuotas.py read --provider codex --cred ~/.codex/auth.json

# Un tick de avisos: lee, compara con el estado y emite 0..n líneas; el estado va en un fichero (0600, atómico)
python3 scripts/lector_cuotas.py eventos --provider codex --estado /ruta/estado-codex.json [--cred F] [--tramo 5000] [--alerta 10000] [--alerta 5000]
```

### El campo `credits`

| Subcampo | Valor | Si no llega o llega raro |
|---|---|---|
| `has_credits` | `true` / `false` | `null` |
| `balance` | número decimal ≥ 0, **exacto**: se conserva con todos sus dígitos y se emite en el JSON sin alterarlo (acepta también una cadena decimal estricta, como `"61207.56"`) | `null`: bool, negativo, `NaN`, exponente, espacios o más de 15 dígitos enteros — jamás un número inventado |
| `overage_limit_reached` | `true` / `false` | `null` |
| `limit_reached` | `true` / `false` (de `rate_limit`) | `null` |
| `reset_credits` | reinicios de ventana disponibles (entero ≥ 0) | `null` |

Una respuesta sin bloque `credits` es una lectura **viva** con todos los subcampos de saldo en `null`. Las
ventanas (`session`, `weekly`) se leen como siempre; el saldo no las toca.

### Qué emite `eventos` (vocabulario cerrado)

| Línea | Cuándo |
|---|---|
| `CODEX-CUENTA-CAMBIADA <8> -> <8> balance=<n> pct=<p>` | la cuenta de la lectura difiere de la del estado; los avisos de nivel se rearman |
| `CODEX-CREDITOS-TRAMO balance=<n> (gastados <k>+ desde el tramo anterior)` | el saldo bajó de tramo (tramo de 5.000 por defecto) |
| `CODEX-CREDITOS-MENOS-<N>K balance=<n>` | cruza hacia abajo cada umbral `--alerta` (10.000 y 5.000 por defecto, múltiplos de 1.000); una vez, y se rearma cuando el saldo vuelve a subir |
| `CODEX-AGOTADA sin créditos y ventana al <p> % (avisar al lead)` | sin créditos (`has_credits` falso o saldo 0) **y** ventana al límite; una vez |
| `CODEX-RESET-DETECTADO pct=<p> balance=<n>` | la ventana estaba al límite y dejó de estarlo |
| `CODEX-NO-MEDIDO <motivo>` | endpoint caído, respuesta inservible o sin saldo utilizable; una vez por transición |

`pct` sale de la ventana semanal; si no hay, de la de sesión; si ninguna, `?`. La cuenta se imprime **solo con sus 8
primeros caracteres** y el token no sale por ningún canal. Las líneas no llevan hora: quien las encadena a un log la
mide con `date -u`.

### rc y estado

| rc | Significa |
|---|---|
| `0` | tick completo (también cuando emite `CODEX-NO-MEDIDO`) |
| `2` | precondición: argumento inválido, **estado ilegible** (no se sobrescribe), symlink, candado ocupado más de 10 s, o **emisión fallida** (el estado no avanza y el tick siguiente reemite) |

El estado guarda el prefijo y la huella de la cuenta, nunca la cuenta completa. Se escribe con un temporal del mismo
directorio y `rename`, en modo `0600`, bajo un candado; **se emite antes de persistir**.

### Qué NO hace

- No agrega gasto ni dice «qué gasta qué»: eso es del medidor (`talent-medidor`), que puede **leer** `credits`.
- No gasta reinicios de ventana, no rota cuentas y no avisa por sí mismo: imprime líneas que alguien enruta.
- No existe modo créditos para Claude: su API de uso no trae saldo. Los vigías de pozos de Claude (agotamiento de la
  ventana de 5 h, renovación) no son scripts de este paquete sino **configuración del medidor**; siguen el mismo
  patrón de transición que `vigia-cuota.sh`.

### Gotchas

- **Ventana al 100 % no es cuenta agotada.** `limit_reached` verdadero con saldo disponible es el estado normal de
  «corre a saldo»; solo se agota sin créditos **y** con la ventana al límite. Un saldo **desconocido** no se
  interpreta como cero: sale `CODEX-NO-MEDIDO sin_saldo`.
- **El saldo nunca pasa por `float`.** Con 15 enteros y 6 decimales un `float` ya no distingue los dígitos y movía el
  saldo de tramo (`9999999999999.999999` se leía como `1e13`). Se lee como `Decimal` desde el texto del JSON, se
  compara y se divide en `Decimal` y `read` lo escribe como número con todos sus dígitos.
- **Un cambio de cuenta no es un reinicio de ventana:** no emite `CODEX-RESET-DETECTADO` ni cuenta como gasto de tramo.
- **Un estado corrupto no es un primer tick.** El primer tick calla por contrato; leer basura como «no hay estado»
  borraría la transición, así que se falla cerrado sin tocar el fichero.

## Canario

**Ley.** Tras cada fusión, el gate `unit` sellado corre sobre la `main` nueva. Dos PR verdes por separado pueden dejar
`main` roja juntas (un choque semántico que ningún gate por PR ve), y clasificarla una hora como «flake» cuesta una
hora de ventanas. Un ROJO para las ventanas hasta diagnosticarlo; **el sello lo pone una persona** tras leer el caso:
el canario no sella, no revierte y no bloquea.

```bash
S=skills/talent-ceo/scripts     # o .claude/skills/talent-ceo/scripts en un repo consumidor

# Un tick (cron) o un bucle; el runner, su repo y el manifiesto los pone quien instala
bash $S/canario-main.sh --repo /ruta/clon --estado /ruta/estado-canario --runner <runner> --runner-repo /ruta/en/el/runner --manifest /ruta/manifiesto.conf --una-vez
bash $S/canario-main.sh --repo /ruta/clon --estado /ruta/estado-canario --runner <runner> --runner-repo /ruta/en/el/runner --manifest /ruta/manifiesto.conf --cada 60
```

Un tick trae `origin/main`; si el sha es nuevo, lo prueba en un worktree **desechable** bajo `<estado>` con
el lanzador sellado del motor (gate `unit`, grupo `rgcan<sha9>`, `--sha` y `--base` iguales, `--pr 0`; tope de 3600 s; `--gate`, `--tope`,
`--runner-user`, `--repo-slug` y `--sellado` lo ajustan) y retira el worktree siempre.

### El veredicto sale del receipt

| Línea (stdout) | Cuándo | rc del tick |
|---|---|---|
| `CANARIO-MAIN-<sha9>-VERDE gate=unit rc=0 result=PASS` | rc 0 del gate **y** receipt de este sha, de este gate, con `finished_at >= T0` y `PASS` | `0` |
| `CANARIO-MAIN-<sha9>-ROJO gate=unit rc=1 result=FAIL` | rc 1 **y** el mismo receipt con `FAIL` | `1` |
| `CANARIO-MAIN-<sha9>-NO-MEDIDO … motivo=<m> rc=<n>` | cualquier otra cosa: rc ≥ 2 (precondición, NO MEDIDO sellado, tope 124), receipt ausente, ilegible, de otro sha/gate, anterior a `T0`, `SKIP`, o un rc que contradice al receipt | `3` |

`T0` se mide antes de lanzar. **Un fallo del instrumento nunca es un veredicto:** es `NO-MEDIDO`, y el sha **no** queda
hecho. Cada veredicto añade a `<estado>/canario.log` una línea `CANARIO-FIN <sha9> <HH:MM:SSZ> rc=<rc> result=<PASS|FAIL|NO-MEDIDO>`
(contrato para quien quiera parar ventanas con un ROJO). Si `fetch` falla: `CANARIO-MAIN-NO-MEDIDO fetch-fallo`, rc 3, sin sha.

### Ficheros del estado y candado

`canario-hechos.txt` (un sha por línea, solo tras VERDE o ROJO), `canario.log`, `rec/<sha9>.<aleatorio>/` (receipts
de UN intento), `gate-<sha9>.log` (salida del gate), `gate-activo` (grupo del gate en curso) y `canario.lock`. Un
**solo canario por estado**: el candado (`flock`) se toma al arrancar y un segundo canario sale rc 2. El gate corre
con el descriptor del candado cerrado, de modo que un canario muerto a mitad de la corrida libera el candado y el
tick siguiente **reintenta** ese sha.

### Un receipt vale solo para el intento que lo escribió

Cada intento lee los receipts de **su propio directorio** (`mktemp -d` bajo `rec/`). Un PASS que dejó un intento
anterior (por ejemplo uno que salió rc 2) o que escribe tarde un gate superviviente no está donde el intento nuevo
mira, ni siquiera si ambos comparten el segundo medido, que es donde `finished_at >= T0` no los distingue. Los
directorios de un `NO-MEDIDO` se borran; los de un VERDE o un ROJO quedan como evidencia.

### Ley de corte: el gate en su sesión, con el grupo registrado

El gate se lanza con `setsid` y su grupo (pid = pgid = sid) se registra al arrancar en `gate-activo`
(`<pgid> <sha9> rgcan<sha9>`). Antes de señalarlo se comprueba con `ps -o pid,pgid,sid,args`: que sea el grupo
registrado y, si tiene líder, que su línea de órdenes lleve el lanzador sellado y su `--run-group`. Si no coincide, no
se señala a nadie y el registro se descarta. Un TERM o INT al canario corta el gate registrado; un KILL lo deja vivo y
el tick siguiente lo retira **antes** de lanzar otro (si no puede, `CANARIO-MAIN-NO-MEDIDO gate-previo-vivo`, rc 3):
nunca hay dos gates propios a la vez. El `sleep` del modo `--cada` sigue la misma ley: va en su propia sesión, su grupo
se registra tras comprobarlo con `ps` y solo se señala ese grupo, si todos sus miembros son un `sleep <n>`. Necesita `setsid`, `ps`, `jq`, `flock`, `timeout` y `git` en el PATH.

### Qué NO hace

- No sella en el bus: el CEO sella con `bus-sellar.sh` (`CANARIO-MAIN-<sha9>-VERDE|ROJO`) tras leer el caso.
- No espera la barrera de carga ni decide si una ventana se abre: lanza el gate directamente en el runner indicado.
- No toma el último `unit rc=` de ningún journal.

### Gotchas

- **Marcar el sha antes de correr lo pierde si el proceso muere** a mitad; y un journal con un `unit rc=1` viejo dio un
  falso rojo (05-oct): por eso solo cuenta el receipt de ESTA corrida.
- **`--cada` reintenta un `NO-MEDIDO` cada `<s>`** mientras el instrumento falle: léelo, no lo dejes repetirse.
- **El `finished_at` del receipt lo escribe el runner:** un reloj desfasado entre estación y runner se ve como
  `anterior-a-T0` (NO-MEDIDO), nunca como un verde.

## Sellador

**Ley.** La hora de un sello la **mide** el sellador; la hora que alguien teclea en el marcador es narrativa. Tres veces
se nombró un marcador con una hora extrapolada del relay y luego se midió otra: el marcador es lo que se cita, y uno con
una hora que el reloj desmiente contradice su propia estampa.

```bash
bash $S/bus-sellar.sh --rol CEO --marcador CANARIO-MAIN-<sha9>-ROJO --nota "leído el caso" --src /ruta/cuerpo.txt
```

- **Aviso de hora** (por **stderr**, sin bloquear, rc 0): si el marcador acaba en `-HHMM` válido (HH < 24, MM < 60) y
  difiere más de 5 minutos del reloj (diferencia circular), se avisa. `-8548` no es una hora y no avisa. La salida
  estándar (`bus: sellado <M> por <R> @ <ts>`) no cambia. Un marcador que acaba en un número de cuatro cifras que no es
  una hora (un identificador) avisa igual si coincide con una hora válida: el aviso es una pregunta, no un rechazo.
- **`--src` es una guarda de identidad:** debe ser un fichero regular, existente y **no vacío** (rc 2 con motivo si no),
  y se comprueba **después** de la identidad contra el bus, que conserva su mensaje. **Su contenido no se escribe:** el
  bus es una línea por sello; lo que se quiera decir va en `--nota`.

### Gotchas

- Un marcador rechazado por repetido (rc 3) no avisa de hora: el aviso solo sale cuando el sello va a escribirse.
- Si la hora del marcador es intencionada (un banco sellado más tarde), el aviso se ignora; si se extrapoló del relay, se
  corrige el marcador **antes** de citarlo.

## Runners al día

**Ley.** Antes de cualquier prueba en un runner, el `origin/main` de su repo ES el `main` real. Un gate
que lee `origin/main` de un runner atrasado da rojos que `main` puro no da, y el fallo se atribuye al
código en vez de al runner. Se pone con un bundle **sin credenciales**, se **comprueba** con `rev-parse`,
y si no coincide el gate **no se lanza**. El sello del gate cita el resultado.

```bash
S=skills/talent-ceo/scripts     # o .claude/skills/talent-ceo/scripts en un repo consumidor

# 1) Quien ejecuta fabrica el bundle (desde un clon que tenga la base) y mide el sha real de main
git bundle create /ruta/main.bundle main --not <commit-base-que-tienen-todos-los-runners>
ESP="$(git ls-remote origin refs/heads/main | cut -c1-12)"

# 2) Ver, sin tocar nada, los comandos EXACTOS que se ejecutarían
bash $S/runners-al-dia.sh --bundle /ruta/main.bundle --ref main --esperado "$ESP" --dry-run

# 3) Ponerlos al día y comprobarlos
bash $S/runners-al-dia.sh --bundle /ruta/main.bundle --ref main --esperado "$ESP"
```

### Qué comprueba ANTES de tocar nada (rc 2 si falla, con cero runners tocados)

- El bundle es un fichero regular, **no un symlink**, y `git bundle verify` lo acepta. Se verifica en el
  repo del directorio actual; sin repo, en uno vacío desechable, lo que sirve para bundles completos. Un
  bundle **incremental** (`--not <base>`) exige ejecutar el script desde un clon que tenga su base.
- `--ref` figura en `git bundle list-heads` (se acepta `main` o el nombre completo) y su sha **empieza
  por `--esperado`** (7 a 40 hex). Si no, el mensaje dice los dos sha.
- El perfil es válido, declara una máquina con `acceso=local` y al menos una fila `runner` ejecutable.
- Los ids y contenedores seleccionados están en `[A-Za-z0-9._-]` y no empiezan por guion; el
  `usuario_contenedor` también.

### Qué runners, y cómo se llega

Las filas `runner` del perfil, o solo las pedidas con `--runner <ID>` (repetible; un id inexistente es
rc 2). Cada fila declara dónde vive el repo con los atributos que escribe el instalador:

```text
runner	<id>	<maquina>	<contenedor>	-	usuario_contenedor=<usuario>;repo=<ruta absoluta>
```

- **Sin `repo=` o sin `usuario_contenedor=`**: la fila sale `SIN-REPO` y rc 1. No se aplica ningún valor
  por defecto: se actualizaría un repo equivocado.
- **Sin contenedor** (`-`): `OMITIDO`. Los runners de otro transporte (Mac, `linux-kvm`) quedan así; su
  preparación es de otra pieza. Los omitidos no cuentan en el total.
- **Varios repos en un mismo runner**: una fila `runner` por repo (ids distintos, mismo contenedor).
- `contenedor` es un identificador opaco: nada se deduce de su forma.

La ruta sale de la máquina de la fila, nunca del nombre del equipo: máquina distinta de la que declara
`acceso=local` → `ssh -- <maquina>`; la local → directo; luego `incus exec <contenedor> -- …` como root
del contenedor y `su - <usuario_contenedor>` dentro. Nada se compone con el intérprete de cadenas del
shell: la orden remota se serializa con `_citar_posix` (como en `relay-ceo.sh`) y los valores del perfil
llegan al contenedor como argumentos y por stdin, **como datos**, nunca dentro del código.

### Qué se hace en cada runner

El bundle entra por stdin a un `mktemp` **dentro del contenedor** (nombre impredecible, nunca un nombre
fijo) y se borra **siempre**, también ante fallo. En el `repo=` de la fila:
`git fetch -q --no-tags --no-recurse-submodules <bundle> <ref>`,
`git update-ref refs/remotes/origin/main FETCH_HEAD` y `git rev-parse origin/main`. Después la estación
comprueba que ese sha empieza por `--esperado`. **Solo cambia `refs/remotes/origin/main`**: ni árbol de
trabajo, ni índice, ni otras refs, ni procesos. La actualización usa `update-ref --no-deref`, y si
`refs/remotes/origin/main` es una ref **simbólica** (seguirla cambiaría la rama local y HEAD) el runner
se rechaza ANTES de tocar nada: `FETCH-FALLO` con el runner nombrado y rc 1, nunca `OK`.

### Salida y rc

| Línea | Significa |
|---|---|
| `RUNNER <id> OK <sha9>` | `origin/main` quedó en el sha esperado |
| `RUNNER <id> DIFIERE <sha9> esperado=<sha>` | quedó en otro commit |
| `RUNNER <id> SIN-REPO <motivo>` | falta `repo=` o `usuario_contenedor=`, o `repo=` no es un repositorio git |
| `RUNNER <id> FETCH-FALLO <causa>` | falta un commit prerrequisito del bundle u otro fallo del fetch; su `origin/main` no cambia |
| `RUNNER <id> PUSH-FALLO <causa>` | no se pudo crear o escribir el bundle temporal en el contenedor |
| `RUNNER <id> SSH-FALLO <causa>` | la máquina no respondió |
| `RUNNER <id> OMITIDO <motivo>` | fila sin contenedor |

La última línea es el resumen que se pega en el sello del gate:
`RUNNERS-AL-DIA ok=<n>/<m> origin/main=<sha8> <HH:MM:SSZ>`.

| rc | Significa |
|---|---|
| `0` | **todos** los runners ejecutables quedaron al día (`ok=m/m`) |
| `1` | alguno no: el gate **no se lanza**. El rc es el AND de todos los runners |
| `2` | precondición: nada se ha tocado |

### Qué NO hace

- No fabrica el bundle ni conoce el sha real de `main`: no tiene credenciales ni red hacia el repositorio.
  Los aporta quien lo ejecuta (`git bundle create`, `git ls-remote`).
- No lanza ni reintenta el gate, no instala ningún cron y no corre en paralelo: va máquina a máquina.
- No toca nada fuera de `refs/remotes/origin/main` del repo declarado en cada fila.

### Gotchas

- **El bundle parte de un commit que tengan TODOS los destinos.** Un runner al que le falta ese
  prerrequisito sale `FETCH-FALLO`; no se arregla relajando la comprobación, sino fabricando el bundle
  desde una base común.
- **Un runner atrasado no es un error de la prueba.** Si un gate da rojo en un runner y verde en otro,
  mide primero `RUNNERS-AL-DIA`: la diferencia suele ser el `origin/main` de cada uno.
- **`--dry-run` imprime la orden completa, incluido el guion de varias líneas.** Lo impreso, ejecutado tal
  cual, hace lo mismo que la corrida real; sirve para leer los valores del perfil ya citados.

## Vigías

**Ley: una línea = un evento accionable, y el vigía va por cursor, no por cola en vivo.** Un monitor
del mando entrega cada línea de su salida como un evento que alguien tiene que atender. Por eso cada
vigía emite **solo** eventos accionables (una línea, una cosa que hacer), avisa por **transición** y,
cuando no puede medir, **lo dice**. Y por eso lee lo escrito con un **cursor propio**: un vigía que sigue
el bus «en vivo» (`tail -F -n0`) no reproduce nada de lo escrito mientras estuvo caducado, y los
monitores caducan. Lo que se escribe durante el hueco se entrega en el primer tick que vuelve.

Cada vigía es **un tick**: una pasada que emite 0..n líneas y sale con rc 0. El bucle vive solo en
`vigias.sh`, que es el único proceso que se arma como monitor.

```bash
S=skills/talent-ceo/scripts     # o .claude/skills/talent-ceo/scripts en un repo consumidor
export TA_BUS=/ruta/al/bus TA_PERFIL=/ruta/al/perfil.tsv

# Lo que se arma como monitor (UNA sesión, una sola salida):
bash $S/vigias.sh --excluir-rol <MI-ROL> --carpeta /ruta/a/vigilar=100 [--maquina <ID>]...

# Ver, sin armar nada, qué vigías y con qué periodo:
bash $S/vigias.sh --lista
# Un solo recorrido de todos (para probar la configuración):
bash $S/vigias.sh --una-vez --excluir-rol <MI-ROL>
```

### Los vigías y sus eventos

| Vigía | Evento (primera palabra) | Cuándo sale |
|---|---|---|
| `vigia-bus.sh --modo pedidos` | `PEDIDO <rol> <marcador> <texto>` | un sello nuevo, de un rol no excluido, cuyo texto casa con `--patron` (vocabulario inicial de pedidos al CEO) |
| `vigia-bus.sh --modo rojos` | `ROJO <rol> <marcador> <texto>` | ídem con el vocabulario inicial de fallos y urgencias |
| `vigia-silencio.sh` | `SILENCIO-BUS <min> min …` | el último sello de **otro** rol tiene `--minutos` (20) o más |
| `vigia-ociosa.sh` | `OCIOSA <máquina> carga5m …` | una máquina del perfil lleva `--minutos` (30) con carga a 5 min < `--umbral-nucleo` (0,3) por núcleo |
| `vigia-recursos.sh --modo inodos` | `INODOS <ruta> al <n> %` | los inodos de la ruta (por defecto la temporal) cruzan el 85 % |
| `vigia-recursos.sh --modo disco` | `DISCO <ruta> al <n> % …` | el disco cruza 90, 95 o 97 % (cada umbral su transición; una línea con el más alto) |
| `vigia-recursos.sh --modo carpeta` | `CARPETA <ruta> = <n> GB > tope <m> GB` | una carpeta declarada con `--carpeta RUTA=GB` supera su tope |
| `vigias.sh` | `VIGIAS-ARMADOS` · `VIGIAS-PARADOS rc=<n>` · `VIGIA-FALLO <vigía> …` | al arrancar · al salir · un tick terminó con rc distinto de 0 (una vez por transición) |

Toda línea acaba con la hora **medida** (`HH:MM:SSZ`), es UTF-8 válido, no lleva caracteres de control y
mide 220 bytes como máximo: el texto del bus se limpia y se recorta antes de emitirse.

### Periodos por defecto en `vigias.sh` (se cambian con flags, no con código)

Bus (pedidos y rojos) 15 s · silencio 60 s · ociosa 300 s · inodos 120 s · disco 120 s · carpeta 1800 s,
con `--cada-bus`, `--cada-silencio`, `--cada-ociosa`, `--cada-inodos`, `--cada-disco` y `--cada-carpeta`.
`--sin <vigía>` desactiva uno (`bus-pedidos`, `bus-rojos`, `silencio`, `ociosa`, `inodos`, `disco`,
`carpeta`). Son los de las fuentes vivas del CEO; el del bus (sin medida previa, porque la fuente viva
era en continuo) se ajusta tras el ensayo.

### Por transición, no por nivel

La transición la decide `vigia-cuota.sh` (no se reimplementa) con un estado por vigía en un directorio
`0700` bajo el de la fábrica. **Sin estado previo se parte de «bajo»**: un recurso o un silencio que ya
están en rojo avisan en el primer tick. Mientras siga alto no se repite, bajar no avisa, y subir otra vez
vuelve a avisar. **El orden es decidir → emitir → confirmar el estado.** El detector corre sobre una copia
del estado y solo cuando la línea ya salió la copia pasa a ser el estado real, todo bajo un candado por
clave. Si la emisión falla (stdout roto) o el proceso muere antes (un TERM), el estado real no cambió y el
tick siguiente repite el aviso: se prefiere repetir a perder.

### Lo que no se puede medir se dice

Un fallo de medición **no es calma**. Cada vigía emite su línea `…-NO-MEDIDO` (una vez por transición, con
rc 0 del tick) cuando: el bus falta, se truncó (cursor mayor que el bus) o no trae ninguna línea con el
formato del paquete; no hay ningún sello de otro rol o el último está fechado en el futuro; una máquina no
responde por ssh o devuelve algo ilegible; `df` no da dato o no cuenta inodos; `du` agota su tiempo (900 s) o
falla sin haber visto ya más que el tope. Volver a medir bien re-arma en silencio. Además: `SIN-ROL-EXCLUIDO`
(el silencio sin `--excluir-rol` mide los sellos propios como actividad), `CARPETA-SIN-TOPE` (carpeta sin tope
declarado, o ninguna carpeta declarada).

### Cómo se mide cada cosa

- **Bus.** El vigía lleva su **propio cursor de bytes** por `--lector` (`vigias.sh` usa dos: `<base>-pedidos` y
  `<base>-rojos`), en su directorio de estado: identidad del bus (dispositivo e inodo), desplazamiento y la suma
  de los últimos bytes entregados. `bus-leer.sh` solo sabe leer-sin-mover o leer-todo-y-avanzar, así que no
  sirve para confirmar hasta un byte. **El cursor avanza después de entregar y exactamente la longitud de lo
  entregado**: se toma una instantánea (solo líneas completas), se emiten sus eventos y solo si salieron todos
  se guarda el cursor. Lo que se selle mientras tanto no está en la instantánea y sale en el tick siguiente;
  si la emisión falla o el proceso muere, el tramo se repite. Un bus ausente, rotado o sustituido, un cursor
  mayor que el bus (truncado) y lo ya entregado que ha cambiado salen como `…-NO-MEDIDO` sin avanzar, nunca
  como calma; el cursor no se reescribe solo (lo decide quien opera, borrándolo para releer desde el principio).
  Un tick sin bytes nuevos no cambia el estado «no medido»: se re-arma al ver una línea con el formato del
  paquete. Un candado por `--lector` abarca todo el tick.
  **Contrato del bus (decisión del CEO): solo-añadir.** Quien sella escribe con `O_APPEND` y la identidad
  va por inodo, así que lo ya entregado no cambia nunca. Una diferencia en lo ya entregado es una
  **violación** del contrato, no un caso normal: da `…-NO-MEDIDO` y obliga a resincronizar, que decide quien
  opera. Antes de avanzar el cursor se **relee el tramo entero** `[off, off+L)` y se compara con lo entregado:
  si cambió, `…-NO-MEDIDO` sin avanzar (el tick siguiente lee el tramo como está ahora). Es la red de
  seguridad; la declaración no la sustituye. El cursor (formato `v2`) guarda además el **sha256 del último
  tramo entregado entero**, y el tick siguiente vuelve a leer ese tramo y lo compara: un cambio que ocurra
  entre la comparación y el guardado del cursor, o después, sale como `…-NO-MEDIDO` sin avanzar, nunca en
  silencio. Un cursor viejo (sin `v2`, con la suma de solo 64 bytes) NO se migra: es ilegible, falla cerrado y
  lo resincroniza quien opera (borrando el cursor). Solo queda sin vigilar lo anterior al último tramo
  entregado. Coste: cada tick relee ese último tramo.
- **Silencio.** La edad es `ahora − hora ISO completa del propio sello`: sin reconstruir la fecha de hoy
  a partir de `HH:MM:SS`, de modo que 30 h son 1800 min y no 360.
- **Ociosa.** Carga y umbral pasan a **centésimas enteras** y se compara `carga < umbral × núcleos`; no hay
  decimales en `awk` y la coma decimal vale igual que el punto. La racha se mide en **tiempo**: una carga
  alta, una máquina que no responde o un hueco de más de `--hueco-max` segundos entre ticks la reinicia (no
  se afirma «ociosa 30 min» de un rato que nadie vio). Las máquinas salen de las filas `maquina` del perfil,
  nunca de una lista fija: la que declara `acceso=local` se lee por `/proc`; las demás por `ssh -- <maquina>`.
- **Recursos.** Inodos y disco de una ruta (`--ruta`) y carpetas con tope (`--carpeta RUTA=GB`, repetible; el
  último `=` separa). **Los topes son dato, nunca código**: el paquete no trae ninguna ruta ni ningún tope.

### Qué NO hacen

- **No actúan.** Matar, limpiar, reasignar es del CEO: los vigías solo informan.
- **No heredan exclusiones de una instancia.** El vocabulario inicial de pedidos y rojos es el de las fuentes
  vivas; lo propio de cada instancia entra por `--patron` y `--excluir-rol`.
- **No señalan grupos ni padres.** Nada de `kill 0`, `pkill`, `pgrep` ni `kill -- -<grupo>`. `vigias.sh`
  termina SOLO los PID que él lanzó, tras verificar que siguen vivos, que son hijos directos suyos y que
  ejecutan un vigía de este directorio. Un proceso de otro dueño que comparta grupo sobrevive. Un tick que
  esté dentro de una herramienta externa larga (`du`) la deja terminar sola por su tiempo máximo.
- **No miden carpetas ni inodos de otras máquinas** (solo la ociosidad mira varias).
- **No vigilan Sentry, la cuota de Codex, PR en GitHub ni el re-armado del monitor del arnés**: son de otras
  piezas o del plan siguiente.

### Límite declarado

Un tick que muere tras emitir y antes de guardar el cursor repite ese tramo (puede duplicar eventos; no
pierde ninguno). Un hijo que sobreviva a su vigía hereda el candado del ciclo y lo retiene
hasta terminar: el tick siguiente espera hasta 10 s y, si no lo consigue, sale con rc 2 sin decidir.

### Gotchas

- **Un monitor mudo no es un monitor sano.** Si un vigía lleva horas sin una línea, mide primero con
  `vigias.sh --una-vez`: debe imprimir `VIGIAS-ARMADOS` y `VIGIAS-PARADOS`. Sin `VIGIAS-ARMADOS` en la sesión
  del monitor, el monitor caducó y hay que re-armarlo; lo escrito entretanto saldrá al volver.
- **Dos monitores con el mismo `--lector` se reparten el bus.** Cada uno es dueño de su cursor: usa un
  `--lector` por instancia armada.
- **`--excluir-rol` es el propio rol del que vigila.** Sin él, sus sellos cuentan como actividad y esconden
  un silencio real; el vigía lo avisa una vez como `SIN-ROL-EXCLUIDO`.
- **Los patrones son ERE.** `--patron` sustituye al vocabulario inicial entero; uno inválido es rc 2 antes de
  leer, para que el cursor no avance en vano.
