# 04 — El perfil de instancia y la operación

## El perfil: topología como DATO

Un TSV de **seis columnas** que describe la instancia: `tipo`, `id`, `maquina`, `contenedor`,
`sesion`, `atributos`. Es lo que hace portable a este skill: todo lo que sabe de una fábrica
concreta lo lee de aquí.

**Nueve tipos válidos**: `maquina`, `torre`, `estacion`, `canal`, `runner`, `cron`, `bus`, `ceo`,
`pm`.

### Precedencia de resolución

| Situación | Resultado |
|---|---|
| `TA_PERFIL` definida y legible | se usa (override **autoritativo**) |
| `TA_PERFIL` definida pero rota | **rc 2** — NO degrada al siguiente escalón |
| Sin `TA_PERFIL`, hay copia en el escrow | se usa |
| Sin `TA_PERFIL`, el escrow no tiene copia | se cae al perfil del motor |
| Ningún candidato legible | **rc 2** |

Un override roto **no** degrada: apuntar a un fichero que no está es un error de operación, no una
invitación a usar otro perfil. En cambio, que el escrow no tenga la copia opcional es **normal**.

## El contrato de validación: V1-V9

`lib-perfil.sh --check` **ES** `perfil_validate` — la misma función, ni una comprobación más ni una
menos. Por construcción es imposible que un perfil pase el gate y sea rechazado en runtime.

| | Comprobación |
|---|---|
| V1 | cabecera exacta de 6 columnas |
| V2 | 6 columnas en toda fila de datos |
| V3 | `tipo` entre los nueve |
| V4 | **`id` único GLOBALMENTE**, no solo por `(tipo,id)` |
| V5 | la `maquina` referenciada existe como fila `maquina` |
| V6 | **a lo sumo una** fila de cada singleton `ceo`/`pm`/`bus` — la ausencia **no** invalida |
| V7 | atributos bien formados `k=v;k=v` |
| V8 | sin clave de atributo duplicada en una fila |
| V9 | **a lo sumo una** fila `maquina` con `acceso=local` — la ausencia **no** invalida |

**V4 es global y la diferencia se puede medir**: un validador que compruebe `(tipo,id)` acepta un
mismo id repetido **entre dos tipos distintos**. Por eso el fixture que prueba V4 debe ser
exactamente ése —colisión cruzada—: uno con dos filas del mismo tipo enrojece con las dos
implementaciones y **no elige entre ellas**.

**V9 es V6 aplicado a la identidad**: de `acceso=local` cuelga la respuesta a «cuál de
estas máquinas soy yo», y con dos filas así los consumidores elegirían **por orden de
línea** — la garantía se apoyaría en el orden del fichero, no en el dato. Se cierra en el
validador; los consumidores, además, fallan cerrado cuando no hay ninguna. Se añadió
después que V1-V8 y **esta tabla tardó una ronda en decirlo**: un contrato que el código
aplica y la referencia no enumera es exactamente la deriva que este skill trata como
hallazgo.

**V6 dice «a lo sumo una», no «exactamente una»**: el perfil es una foto de topología y un rol sin
cubrir es un estado **previsto**, no un fichero corrupto. Lo que jamás puede pasar es que **dos
filas reclamen la misma autoridad singleton**.

### Los rc, y por qué la violación cambia de número

| Situación | `--check` / `perfil_validate` | `perfil_rows` · `perfil_row1` |
|---|---|---|
| Perfil válido | 0 | 0 con la fila · 1 si lo pedido no está |
| Viola cualquiera de V1-V9 | **1** | **2** |
| Sin perfil | **2** | **2** |

En las APIs consumidoras **rc 1 ya significa «cero filas de ese tipo»**, una respuesta normal. Si un
perfil corrupto también diera 1, «este fichero está roto» sería indistinguible de «este host no
tiene crons»: fail-open silencioso.

### Lo que el contrato NO valida — limitación declarada, con su condición de cierre

**El validador comprueba la ESTRUCTURA del TSV, no que los campos sean INERTES.** Un perfil cuyo
`id` contenga una secuencia de escape —por ejemplo `ESC[2J`, que borra la pantalla— **pasa
`--check` con rc 0**: V1-V9 hablan de columnas, tipos, unicidad y gramática de atributos, y ninguna
dice nada del contenido byte a byte de una celda.

**La superficie observable está cerrada igualmente, y en otro sitio**: `perfil-render.sh`
**neutraliza los caracteres de control antes de imprimir** las columnas, en sus dos ramas. Sin eso,
la tabla de mando quedaba a merced del dato que muestra: quien pudiera editar el perfil podía
borrar o falsear la pantalla del que lo lee.

**Qué haría falta para cerrarlo en origen**: una **V10** que exija campos inertes en el validador.
**No está**, y no por olvido — **es un cambio de CONTRATO**, y un cambio de contrato no entra por la
puerta de un barrido de hallazgos: cambia lo que un perfil válido significa para todos los
consumidores, presentes y futuros, y merece revisarse como tal y no como un detalle dentro de un
fix. Adjudicado así por el CEO (`C1-2269-SIN-V10`).

**Consecuencia práctica mientras no exista V10**: cualquier consumidor NUEVO que imprima campos del
perfil tiene que neutralizarlos él, igual que hace el renderizador. La garantía vive en el
consumidor, no en el dato — y eso es justo lo que una V10 invertiría.

**Y el caso extremo, dicho porque es el mismo agujero y no otro**: un campo con un **NUL** lo ve el
validador —que lee el fichero con `awk`— pero **no puede verlo ningún consumidor**, porque el shell
no es capaz de guardar un NUL en una variable: la sustitución de comandos lo elimina. Con eso, un
perfil que para V9 tiene **una** máquina `acceso=local` puede tener **dos** para quien lo consume.
No es un fallo de un consumidor concreto —es una limitación del transporte— y la cierra **la misma
V10**: exigir campos inertes incluye exigir que no haya NUL. Mientras tanto queda aquí escrito, que
es la diferencia entre una deuda gobernada y un agujero.

## Operación

**Runners vivos.** `ps -o etime` emite tres formas y la tercera lleva guion: `MM:SS`, `HH:MM:SS` y
**`D-HH:MM:SS`**. Un parser que solo parta por `:` devuelve una antigüedad absurda justo para los
procesos más viejos, que son los que interesan.

**Vigía de cuota.** Emite **por transición**, no por nivel. Un vigía que repite el aviso en cada
tick mientras el valor sigue alto entrena a quien lo lee a ignorarlo, y el día que aparece un aviso
nuevo ya nadie lo mira: el ruido no molesta, **borra la señal**. El primer tick sin estado previo
registra el lado y **calla** — uno que nace gritando es indistinguible de uno roto.

**Pozos y terna.** Qué pozo usa cada rol, cuál es la terna vigente y cuáles están prohibidos es
**dato del perfil**, no decisión del operador: **nadie conmuta por su cuenta**. Un cambio de pozo
altera quién puede empujar y con qué identidad; se pide, se decide arriba y se refleja en el
perfil. Si el perfil y la realidad discrepan, se para y se escala: operar con un pozo que el perfil
no declara es operar sin trazabilidad.

**El doctor: la estructura no acredita el runtime.** `lib-perfil.sh --check` valida la FORMA del perfil; que
lo declarado exista (torres, crons, cursores, contenedores) lo contrasta `doctor.sh`, de solo lectura (ref
07). Vocabulario que entiende, sin cambiar V1-V9: fila `bus` con `path=` y `lectores=<id>,<id>`; columna
`sesion` = sesión tmux; atributo `usuario=` = usuario del SO del actor (el sellador lo exige distinto entre
actores de la misma máquina). El ejemplo mínimo es `manifiestos/ejemplo.perfil.tsv.example`; **no** se llama
`*.perfil.tsv` porque entonces `perfil_path` lo tomaría por EL perfil.
