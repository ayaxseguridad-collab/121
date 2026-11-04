# 07 — El doctor de instancia y la acreditación de actores

Un perfil válido (`lib-perfil.sh --check`) acredita la ESTRUCTURA de lo que se declara, y nada más. No
dice que la torre exista, que el cron esté instalado ni que el cursor del lector se haya movido nunca.
Esta referencia cubre lo que cierra esa distancia: el **doctor** (contrasta lo declarado con lo que
corre), el **escalado obligatorio al bus** (un bloqueo deja rastro durable) y la **re-acreditación** (un
actor que perdió su contexto no actúa como el de antes hasta demostrarlo).

## El doctor: lo declarado contra lo que corre

```bash
bash $S/doctor.sh        # SOLO LECTURA · una línea por comprobación · rc 0 | 1 | 2
```

Cada línea es `OK|FALLA|NOVERIF <categoría> <id>: detalle`; al final, `RESUMEN` y `PUERTA ABIERTA|CERRADA`.
No hay opción, variable ni «skip» que apague una comprobación: para cerrar la puerta basta UN `FALLA` o UN
`NOVERIF`. **«No he podido comprobarlo» NO es «está bien»**, y por eso un `NOVERIF` cuenta como fallo.

| Categoría | Qué se contrasta | `FALLA` cuando |
|---|---|---|
| `torre` | cada fila `torre`, `estacion` y `ceo` con `sesion` | la sesión tmux no existe, o está viva sin un proceso `claude` **descendiente del pane** |
| `renderer` | `alternate_on` del pane | vale `1` (el pane corre el renderer de pantalla alternativa: sin scrollback ni barra legible) |
| `ctx` | la barra de estado | no hay `ctx: NN%` legible — **nunca se asume 0** |
| `menu` · `escalado` · `menu-reciente` · `bloqueo-sin-escalar` | menú de selección abierto (ver «Escalado») | hay menú, el último sello del rol es más viejo que `TA_ESCALADO_MIN` y no es `ESCALA-<ROL>-*` |
| `acreditacion` | sello propio posterior al `session_created` de la sesión | no hay tal sello, o el estado del rol es `NO_ACREDITADO` |
| `cron` | cada fila `cron` contra `crontab -l` | falta la tabla, o ninguna línea trae los minutos de `tablas-cron.sh --minutos <id>` y el `id` en el comando |
| `bus` · `cursor` | fichero del bus, directorio de estado y de cursores (700, propios, sin symlink), y por lector: cursor entero, ≤ bus, marca `.bus` == inodo | cualquier guarda de `bus-leer.sh` que **fallaría**, o falta `<lector>.cursor` |
| `canal` · `auditor` | contenedor de cada `canal`/`runner` RUNNING; el pane `.1` de cada canal ejecuta el binario `TCO_AUDIT_CLI` | contenedor ausente o parado; el pane de auditoría ejecuta otro binario |
| `identidad` | lectura restringida de `repo-identity.conf` y `agents.conf`, campos adjudicados y válidos, procedencia contra manifiesto de instancia y mismo proyecto en ambos skills; tokens modo 600 | cualquiera falla; tokens: **solo `stat`**, jamás su contenido |
| `sellado` · `sellado-imposible` | cada actor que sella (`torre`, `estacion`, `ceo`) frente a todo actor de su máquina | otro actor de la MISMA máquina no se distingue por `usuario=` (es el rc 2 real de `bus-sellar.sh`) |

**El ejecutable decide, no el nombre.** El proceso del agente se busca por su ejecutable (`ps -o comm=`)
entre los descendientes del pane — nunca por un patrón sobre la línea de comandos, que casa con quien
MENCIONA al agente y no con quien lo ES. Para el auditor se reutiliza `_tco_pane_agent_exes`
del despacho mediante `leer-auditor.sh`: ruta real de `/proc/PID/exe` contra el lanzador
resuelto, incluyendo los intérpretes admitidos; una lectura parcial es `NOVERIF`.

### rc, y qué NO se evalúa

| rc | Significa |
|---|---|
| `0` | todo `OK`: puerta abierta |
| `1` | algún `FALLA` o `NOVERIF`: puerta cerrada |
| `2` | **no puede evaluar** y no emite ninguna línea: sin `tmux` o sin `crontab`, perfil ausente/ilegible/inválido, ninguna máquina `acceso=local`, sin ruta del bus (ni `TA_BUS` ni fila `bus` con `path=`), `TA_ESCALADO_MIN` no numérico |

Un perfil válido y una máquina vacía dan `1`, no `0`: la estructura nunca basta para el verde.

### Alcance: la máquina y el usuario locales

Los modelos esperados de auditor y desarrollo Claude del canal se leen del registro propio del mando, con rc comprobado y valor no vacío; el operador solo captura los paneles con `incus`. Sin registro válido del mando, ambas comprobaciones dan `NOVERIF` con «registro del mando ausente o inválido».

- Una fila cuya `maquina` no es la `acceso=local` sale `NOVERIF`: la verificación remota no existe todavía.
- tmux es **por usuario**. Cuando una fila declara `usuario=` distinto del que ejecuta el doctor, se consulta
  con `sudo -n -u <usuario> …`, y SOLO si sudo lo permite **sin contraseña**; si lo rechaza, `NOVERIF`. Si el
  usuario ni siquiera existe en el SO, `FALLA`: su sesión no puede existir.
- Para dejar al doctor consultar a otro usuario, hace falta una regla de sudoers sin contraseña que permita a
  quien lo ejecuta correr las consultas de `tmux`, `crontab` e `incus` como ese usuario, y la invocación
  exacta `env -u XDG_RUNTIME_DIR bash /ruta/instalada/leer-acreditacion.sh <ROL>` (lector limitado,
  sin ruta configurable). No se autoriza un shell arbitrario. Se usa `sudo -n -H -u`: HOME es
  del usuario objetivo; se retira el XDG del llamante y se consulta su estado en HOME/.cache.
  Para actores ajenos con estado en un XDG personalizado, esa ubicación requiere adjudicación
  explícita en el perfil (`estado_runtime=/ruta/absoluta`); nunca se hereda el XDG del llamante.
  El atributo `estado_bus=/ruta/absoluta` manda para el estado persistente de otro
  usuario: se consulta con `env TA_BUS_STATE_DIR=/ruta/absoluta bash …/leer-acreditacion.sh ROL`.
  Una ruta relativa da NOVERIF. Sin atributo, cuando el llamante fija TA_BUS_STATE_DIR,
  se conserva la convención HOME/.local/state/talent-ceo del usuario objetivo;
  en otro caso se usa estado_runtime o HOME/.cache como arriba. Autoriza únicamente
  la invocación exacta para la ruta adjudicada, sin shell arbitrario.
  Sin permiso o con rc distinto de cero, `NOVERIF`. No se interpreta salida de una consulta fallida.

La identidad requiere autoridad legible en `TCO_TF_MANIFEST` (o `TF_MANIFEST`): `TF_PROJECT` y
`TF_REPO_URL` deben coincidir con el proyecto, slug y directorio adjudicados. La igualdad entre
dos restos del proyecto de origen no acredita procedencia. No se ejecutan configuraciones:
solo asignaciones literales `CLAVE=valor`, sin expansiones; instrucciones, duplicados y datos
no comprobables cierran la puerta. Solo en `agents.conf` se admite el prefijo opcional `export `:
exactamente la palabra `export` seguida de un espacio, delante de `CLAVE=valor`.
Esto incluye `export AM_LEDGER="…"`, `export TF_ROOT="…"` y `export TF_MANIFEST="…"` del generador.
Se rechazan varias asignaciones en una línea (`export A=1 B=2`), `export -n`, `export` sin
asignación, espacios adicionales, tabuladores y cualquier otra palabra delante (`declare`,
`readonly`, `local`, etc.). Una clave repetida con y sin prefijo también invalida el fichero.
El manifiesto de autoridad y `repo-identity.conf` no admiten ese prefijo.
En `agents.conf`, cada valor admite una única pareja de comillas envolventes
o un literal sin espacios ni operadores; nada después del valor. Los operadores dentro
de esa pareja son datos válidos. El lector exige valores de `agents.conf` sin barras invertidas:
una comilla interior escapada se rechaza conservadoramente aunque sea un literal válido para shell.
En `repo-identity.conf`, se conserva el valor exacto después de `=` como en los consumidores
reales; las comillas forman parte del dato y nunca se eliminan. El contraste exige un solo sentido:
si el doctor acredita la identidad, ambos guards reales deben aceptarla. El doctor exige además
UUID bien formado y procedencia adjudicada; un rechazo suyo con aceptación del guard es legítimo.
Todas las claves de identidad presentes, incluidas las
opcionales y los overrides efectivos, rechazan marcadores `PENDIENTE-*`, también entrecomillados.
Los sellos del doctor exigen cabecera y fecha UTC canónica, calendario válido y fecha no futura.
El verificador de nonce conserva su orden de bytes posterior al cebado, sin reloj.
Los estados ajenos se leen como el usuario del actor;
ausencia comprobada es legítima, tipo/propietario/lectura no comprobables dan `NOVERIF`,
contenido distinto de `ACREDITADO` o `NO_ACREDITADO` da `FALLA`.

### Vocabulario del perfil que el doctor entiende

- Fila `bus`: `path=<fichero>` (o `TA_BUS`, que gana; si difieren, `FALLA bus`) y `lectores=<id>,<id>` (por
  defecto, toda fila `ceo`, `torre` y `estacion`).
- Columna `sesion`: **sesión tmux** del actor. Atributo `usuario=`: usuario del SO que corre ese actor
  (también el que opera `incus` en las filas `canal`/`runner`, y el dueño del `crontab` de una fila `cron`).
- Fila `cron`: la línea de `crontab -l` es `<minutos> * * * * <comando>`, con los minutos de la fila y el `id`
  de la fila dentro del comando.
- Un ejemplo mínimo y autoconsistente vive en `manifiestos/ejemplo.perfil.tsv.example`. Lleva ese sufijo A
  PROPÓSITO: un `*.perfil.tsv` dentro de `manifiestos/` pasaría a ser EL perfil de la instancia (y un segundo
  daría AMBIGUO, rc 2).

### Solo lectura, demostrada

El doctor consulta tmux, `crontab`, `incus`, `ps` y `stat`; no repara ni reanima a nadie. Lo único que crea es
un temporal fuera del árbol de estado (para capturar el rechazo de `sudo`). La suite compara el hash del
árbol de estado y del bus antes y después de cada corrida del wrapper `dr`: rutas, tipos,
permisos, propietario, enlaces y SHA256 de todos los ficheros regulares. Para los fixtures
propios con modo 000, la instantánea de prueba habilita lectura temporal, calcula SHA256 y
restaura el modo antes de invocar el doctor; este observa los permisos originales. Un error
de instantánea enrojece la suite. El smoke tmux se
comprueba aparte; no se afirma aquí que esa corrida tenga la instantánea del fixture.

## Escalado obligatorio al bus

Un coordinador que espera una decisión de la capa superior en un menú de su pane **no deja ningún rastro**:
el CEO solo ve sellos, y lo que vive únicamente en un pane es invisible (un bloqueo así llegó a durar más de
una hora sin un solo sello). Por eso el bloqueo se **propaga** al bus, que es el único canal durable:

1. **Todo bloqueo que requiera autoridad superior se SELLA** antes de esperar:
   `ESCALA-<ROL>-<ref>`, con nota `BLOQUEO-AUTORIDAD · espera:<rol> · <decisión> · <default>` (qué se decide,
   quién decide y qué se hará si nadie responde).
2. **El ruling se acusa** con `ACK-<ROL>-<ref>`: sin acuse, el actor no da el bloqueo por resuelto.
3. **La detección es mecánica**, no un humano mirando panes: `torre-sweep.sh` marca `menu-abierto` y el doctor
   lo cruza con el bus. Con un menú abierto y el último sello del rol más viejo que `TA_ESCALADO_MIN` (15 min
   por defecto) sin `ESCALA-<ROL>-*`, sale `FALLA bloqueo-sin-escalar`. Si el último sello ES `ESCALA-<ROL>-*`
   sale `OK escalado`; si es más reciente que el umbral, `OK menu-reciente`.

La garantía mecánica cubre el selector de tres señales en la región activa (las últimas
ocho líneas no vacías, fuera de citas explícitas y del historial anterior al último prompt).
El estado de las citas se reconstruye sobre la captura completa desde ese prompt y se
conserva al entrar en la cola; un cierre dentro de la cola no oculta el selector posterior.
Una pregunta final en texto libre en un pane en reposo, sin escalado del rol durante los
últimos N minutos, produce `AVISO posible-pregunta-sin-escalar`: heurística informativa,
NO cambia el rc ni garantiza detectar todas las esperas de autoridad. Un «?» en medio de
texto informativo o una lista numerada no bastan. Capturas sintéticas: el formato de la UI
puede cambiar y no se afirma identificar citas sin rotular idénticas a un selector vivo.

## Re-acreditación: sellar de verdad, no escribir «SELLO»

Un actor que vuelve de un `/clear`, de un reinicio o de una sesión nueva **no es el de antes**: ha perdido su
contexto, y puede incluso escribir «SELLO …» en su pane sin ejecutar nada. Afirmarlo no lo acredita.

```bash
bash $S/reacreditar.sh --rol <ROL> --iniciar     # ceba el cursor acred-<ROL>, fija NO_ACREDITADO, emite el nonce
bash $S/bus-sellar.sh --rol <ROL> --marcador ACRED-<ROL>-<nonce>   # lo sella EL ACTOR, con su identidad
bash $S/reacreditar.sh --rol <ROL> --verificar   # rc 0 solo con ese sello POSTERIOR al cebado
```

- El estado vive en `$(bus_dir_estado)/acreditacion/<ROL>.estado` (`NO_ACREDITADO` | `ACREDITADO`) y el nonce
  en `<ROL>.nonce`; `<ROL>.inicio` guarda posición e identidad del bus (también posición cero).
  El cursor y su marca deben existir y coincidir con ese cebado al verificar; perderlos nunca
  equivale a una primera lectura. Se ejecuta **como el usuario del actor**: es SU estado.
- `--verificar` lee el tramo del bus posterior al cebado (`--peek`, sin reloj: orden de bytes) y exige la
  CABECERA completa con fecha UTC válida y `[rol: <ROL>] [marcador: ACRED-<ROL>-<nonce>]`. Otro rol, otro nonce, un sello anterior o un
  «SELLO …» citado en una nota no valen: rc 1.
- rc 2: `--verificar` sin `--iniciar`, rol fuera del charset (máximo 26 caracteres: el lector es
  `acred-<ROL>`) o ajeno al perfil, sin perfil válido o sin `TA_BUS`.
- El doctor lo ve: `NO_ACREDITADO`, o ningún sello propio posterior al `session_created` de la sesión, es
  `FALLA acreditacion`.

**`/clear` está prohibido en actores persistentes** (CEO, coordinadores, Orquestador, estaciones). Tras un
`/clear`, un reinicio o una sesión nueva, el actor queda **NO ACREDITADO** hasta re-acreditar; no se continúa
el pipeline sobre un contexto vacío. No hay mecanismo técnico que bloquee el comando (la fábrica no lo
puede): es doctrina, y el doctor la hace observable.

### Manifiesto de capacidades por rol

Re-acreditar demuestra QUE el actor puede sellar; no que conserve el resto de lo que su rol ejerce. Tras
`ACREDITADO`, el actor recorre el manifiesto de su rol y lo confirma con evidencia, no con una afirmación:

| Rol | Skills cargados | Bus | Cursor y watchers | Gates y rutas |
|---|---|---|---|---|
| CEO | `talent-ceo` (+ `talent-pm` si lo ejerce) | sella y lee con su identidad | cursor propio al día; las dos tablas por cron instaladas | rutas canónicas del anexo |
| Coordinador (torre) | `talent-coordination`, `talent-context` | sella cada transición | cursor y vigías de su ronda armados | gates de despacho y de verificación |
| Orquestador | `talent-orchestrator` | sella órdenes | torre-sweep y wakeups re-armados | cola del Mergeador |
| Mergeador / estación | `talent-merger` | sella cada merge y cierre | su cursor al día | gates AND y apply |

El doctor verifica lo que es **mecánicamente** verificable de esta tabla (sesión, proceso, ctx, cursor, cron,
sello); lo demás lo comprueba el actor y lo declara en su sello de acreditación.

## Recolectores mecánicos antes que una respuesta generativa larga

Una respuesta larga y generativa para un inventario, un diagnóstico o una fotografía del estado es frágil
(puede ser retenida por el arnés, truncada o inventada) y cara. Si la tarea es **determinista y de solo
lectura**, se escribe un RECOLECTOR MECÁNICO que consulta las fuentes (perfil, bus, tmux, procesos,
`crontab`, contenedores) y deja un artefacto estructurado en un fichero; el operador interpreta DESPUÉS el
resultado. El doctor es el primer ejemplo: una línea por hecho, un rc que decide, y ningún texto libre de
por medio. Regla práctica: ante «dime cómo está todo», primero se ejecuta el recolector y se cita su salida;
no se redacta de memoria.

## Límites declarados (decisiones diferidas)

- **Un solo usuario del SO.** `bus-sellar.sh` exige `usuario=` distintos para actores de la misma máquina y
  tmux es por usuario; con un único usuario, el doctor da `FALLA sellado-imposible`. El guard no se toca.
- **Otras máquinas.** Sus filas son `NOVERIF` hasta que exista verificación remota.
- **Invalidación automática** de la acreditación al arrancar una sesión (un hook de inicio): hoy la regla es
  doctrinal, más el criterio «sello propio posterior al inicio de la sesión tmux».
