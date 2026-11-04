# 03 — El ciclo por cron, las dos tablas y la ronda

## Por qué hay dos tablas y no una

La fábrica se mira por dos tablas periódicas desfasadas: ciclo combinado en torno a 7,5 minutos,
sin que ninguna corra al doble de ritmo. Tienen propósitos distintos:

- **Tabla de mergeadores** — el estado de las estaciones de merge y su cola.
- **Tabla de coordinadores** — el estado de los coordinadores y de los canales que llevan.

Cada una corre en sus propios minutos, y **esos minutos viven en el perfil**, en el atributo
`minutos` de su fila `cron`. Nunca se hardcodean aquí: la cadencia de UNA instancia no es una
constante del skill, y el skill viaja a instancias que no son ésta.

```bash
bash scripts/tablas-cron.sh --minutos <id-de-cron>
bash scripts/tablas-cron.sh --crontab <id-de-cron> --comando /ruta/al/comando
```

Sin fila `cron` con ese id, o sin atributo `minutos`, se falla (rc 1). **No hay cadencia por
defecto**: una cadencia inventada coloca trabajo real a una hora que nadie decidió.

## Las columnas, y la FUENTE de cada celda

Lo que hace fiable una tabla de mando no son sus columnas: es saber **de dónde sale cada celda** y
qué se pinta cuando esa fuente falta.

### Tabla de mergeadores

| Columna | Fuente | Si falta la fuente |
|---|---|---|
| Estación | fila `estacion` del perfil | la fila no existe ⇒ no se pinta la fila entera |
| Sesión | columna `sesion` de esa fila | `—` |
| Estado del pane | captura del pane, clasificada por `ronda-canales.sh` | `—` |
| Cola | recuento declarado por la estación | `—` |
| Último sello | último `marcador:` suyo en el bus | `—` |

### Tabla de coordinadores

| Columna | Fuente | Si falta la fuente |
|---|---|---|
| Coordinador | fila `torre` del perfil | la fila no existe ⇒ no se pinta la fila |
| Canales a cargo | filas `canal` cuya topología apunta a esa torre | `—` |
| Canales ocupados | clasificación del composer de cada canal | `—` |
| Antigüedad del proceso | `runners-vivos.sh` sobre el proceso vivo | `—` |

**La regla de oro**: si falta la fuente de una celda se pinta **`—`**, jamás un valor inventado y
**jamás un blanco**. El blanco es peor que el guion: se lee como «cero», «vacío» o «todo bien»
según quién mire, y nadie pregunta. El `—` dice exactamente una cosa: *aquí no hubo dato*. Una
tabla de mando cuyo hueco pueda confundirse con un valor **miente sin que nadie la acuse**.

Y un detalle de render que muerde donde más importa: al alinear columnas hay que contar
**caracteres**, no bytes — `—` ocupa 3 en UTF-8 y desalinea **justo las celdas sin dato**, que son
las que se consultan.

**La regla de oro tiene DOS lados, y el segundo estuvo roto.** El hueco lo cubre el `—`; el
**sobrante** no lo cubría nadie. Una fila con **más** campos que columnas tiene la cabecera se
recortaba a la anchura de ésta y lo que sobraba **desaparecía sin ruido**: `rc 0`, stderr vacío y
una fila con aspecto perfectamente normal. Eso es **pérdida silenciosa de datos** en el panel con
el que se decide, y además tapa la noticia que el campo de más trae consigo — que la captura no
tiene la forma que el llamante cree: o la fuente cambió de formato, o la cabecera se quedó corta, o
hay un tabulador dentro de una celda.

El contrato de `tabla_desde_stdin` es hoy:

| Caso | Qué se pinta | rc | stderr |
|---|---|---|---|
| Fila con **menos** campos que columnas | la fila, completada con `—` | 0 | — |
| Fila **exacta** | la fila | 0 | — |
| Fila con **más** campos que columnas | la fila **ENTERA**, con los sobrantes | **1** | una línea por fila, con **su número** |

La fila ancha se pinta entera en vez de recortarse con aviso porque recortar seguiría **perdiendo**
el dato y obligaría a volver a la captura cruda para saber qué decía; lo que sobra sale más allá de
la última columna, que es justo donde se ve que sobra. El `rc` se devuelve **al final**, con la
tabla ya pintada: abortar en la primera fila ancha dejaría sin ver todas las siguientes, que es
cambiar una ceguera por otra.

## La ronda de canales

Recorrer los canales y clasificar el estado de su composer en cuatro:

| Estado | Qué significa |
|---|---|
| `empty` | composer vacío: el canal está libre |
| `ghost` | hay texto, pero es el **placeholder** de la interfaz (tramo atenuado) |
| `text` | hay texto real escrito y sin enviar |
| `queued` | hay texto y **aparece** una de las señales de envío o ejecución en curso |

**`queued` es una HEURÍSTICA sobre texto visible, y su sesgo es deliberado.** La señal se busca en
el texto ya limpio de secuencias; no hay forma de distinguir, en una captura de texto plano, entre
«la interfaz escribió *Working*» y «el operador tecleó *Working* en el composer sin enviarlo». El
segundo caso sale `queued` aunque por la letra de la tabla sería `text`.

**Se deja así a propósito, y el motivo es cuál de los dos errores duele.** Clasificar de más hacia
`queued` hace que el CEO **no** despache a un canal que en realidad estaba libre: se pierde un
turno. Clasificar de menos —un canal ocupado leído como `text`— hace que se le despache **encima de
un trabajo en curso**. El primero cuesta latencia; el segundo, trabajo perdido. Afinar la señal
para atrapar el caso raro del operador que teclea justo esas palabras metería falsos negativos en
la dirección cara, así que la regla se queda ancha y **el sesgo se declara aquí en vez de dejar que
alguien lo descubra leyendo el `grep`**.

**`ghost` no es `text`, y la diferencia no es cosmética.** El placeholder lo pinta la propia
interfaz cuando no hay nada: tomarlo por texto real hace creer que un canal tiene trabajo cuando
está ocioso y —peor— invita a **obedecer un texto que no escribió nadie**. El criterio del tramo
atenuado viene de `talent-context`.

El parser es **puro**: recibe la captura por stdin y no habla con la terminal. Así se puede probar
sin una sesión viva, que es la única forma de probarlo de verdad.

## Actualización semanal de modelos

Cada usuario de rol acredita Claude y resuelve su registro propio. La fila semanal se obtiene con
`TA_ROL=<id-del-perfil> bash skills/talent-ceo/scripts/cron-modelos.sh --linea` y se instala en su crontab.
Ejecuta `skills/talent-channel-operation/scripts/actualizar-modelos.sh --ejecutar` los domingos a las 03:17; compara usando el CLI acreditado,
aplica la configuración y los canales ociosos, y difiere los ocupados. Las torres reciben un aviso
sellado en el bus y cambian con intervención del rol; el doctor mantiene la puerta cerrada hasta
acreditar el modelo vigente. El cron necesita la sesión acreditada o el token ya exportado por el
entorno de ese usuario y TA_BUS/TA_PERFIL de la instancia. No instala ni consulta actualizaciones del CLI.
