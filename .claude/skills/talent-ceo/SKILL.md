---
name: talent-ceo
description: >-
  Rol CEO de la capa META: el mando operativo de la fábrica — decide CÓMO se construye (el PM
  decide QUÉ). Cubre el bus de sellos con identidad y atomicidad, el ciclo por cron con sus dos
  tablas periódicas, la ronda de canales, los relays a estaciones y canales, la vigilancia de
  cuota por transición y el perfil de instancia que hace todo esto portable a otra fábrica.
  Doctrina central: la topología es DATO, no código — este skill no asume ningún nombre, prefijo
  ni forma, y todo lo que sabe de una instancia lo lee de su perfil. Usar al ejercer o auditar el
  mando de la fábrica: sellar en el bus, leer con cursor propio, montar o revisar las tablas por
  cron, repartir relays, vigilar cuota, arrancar con el paso-0 o escribir el banco de regreso.
  Triggers (ES/EN): "bus de la fábrica", "sellar marcador", "cursor del bus", "tabla de
  mergeadores", "tabla de coordinadores", "ronda de canales", "relay del CEO", "perfil de
  instancia", "vigía de cuota", "paso-0", "banco de regreso", "mando operativo", "factory bus",
  "seal marker", "reader cursor", "cron tables", "instance profile", "quota watchdog".
  Token-only, sin MCP. Repo-agnóstico salvo su anexo.
---

# Talent CEO — mando operativo de la fábrica (Septiembre 2026)

El CEO **opera** la fábrica: reparte encargos, sella hitos en el bus, mantiene las dos tablas
periódicas, hace la ronda de canales y entrega relays. No escribe producto y no decide QUÉ se
construye — eso es del PM (`talent-pm`), y la frontera entre ambos está en la ref 01.

## Quick Orientation

**La idea que hay que entender antes que ninguna otra**: este skill **no sabe** cómo se llama nada
en tu fábrica. Cuántas máquinas hay, qué canales existen, en qué sesión vive cada estación, con qué
minutos corre cada tabla: **todo eso es DATO** y vive en el **perfil de instancia**, un TSV de seis
columnas. El skill viaja limpio a otra fábrica y funciona leyendo *su* perfil.

De ahí salen las dos prohibiciones que más veces se han roto en la práctica y que aquí son
invariantes con test:

1. **`contenedor` es un identificador OPACO.** Prohibido deducir el tipo, el rol o la ubicación de
   la forma del nombre. El tipo lo dice la columna `tipo`. *En una fábrica real hay filas `runner`
   cuyo contenedor se llama como se llamaría un canal: un `case` sobre el prefijo las clasifica mal
   y falla en silencio.*
2. **El PM no se infiere.** Si no hay fila `pm`, el consumidor **aborta** (rc 1). Deducirlo de que
   otra fila declare `roles=…pm_interino…` está prohibido: quién ejerce un rol es un hecho de la
   topología, no una lectura de una cadena de texto. **Un PM inferido es un mando inventado.**

| Ref | Qué contiene | Cuándo abrirla |
|---|---|---|
| `references/01-rol-mando-y-fronteras.md` | Qué decide el CEO y qué no · frontera con el PM · poderes delegados · relays | Antes de asumir una decisión que quizá no te toca |
| `references/02-bus-y-sellos.md` | Bus append-only · identidad por inodo · atomicidad · cursores por lector · modelo de amenaza declarado | Al sellar, al leer, o al depurar un sello duplicado |
| `references/03-ciclo-por-cron-y-tablas.md` | Las dos tablas, columna a columna, y **la fuente de cada celda** · la ronda de canales | Al montar, leer o reparar una tabla periódica |
| `references/04-pozos-en-operacion.md` | Perfil de instancia · contrato V1-V9 · runners vivos · vigía de cuota | Al tocar el perfil o al añadir una comprobación |
| `references/05-leyes-del-mando.md` | Doctrina mínima: qué se escala, qué se decide, qué no se toca | Ante una duda de autoridad |
| `references/06-paso-0-y-bancos.md` | Paso-0 de reanudación · banco de regreso · qué se mide y qué se pregunta | Al arrancar tras un relanzamiento o antes de compactar |
| `references/07-doctor-y-acreditacion.md` | **Doctor de instancia** (lo declarado contra lo que corre) · escalado obligatorio al bus · re-acreditación de actores · manifiesto de capacidades por rol | Tras montar o reiniciar la fábrica, ante un actor que volvió de un `/clear`, o al sospechar que el perfil y el runtime divergen |
| `references/anexo-*.md` (uno por repo) | **OVERLAY**: la instancia concreta, con sus nombres reales | Solo al operar ESTA fábrica |

> **El anexo es el único fichero con nombres reales.** El cuerpo del skill es agnóstico y hay un
> barrido que lo verifica: cualquier nombre de máquina, canal, runner o IP fuera del anexo **rompe
> el gate**. No es una convención de estilo — es lo que permite que el skill viaje.

## Quick Start

```bash
# Ruta RELATIVA A LA RAÍZ DEL REPO, que es desde donde se ejecuta. Si operas el paquete desde el
# repositorio donde vive como paquete —y no instalado en uno consumidor— el prefijo `.claude/`
# sobra: `S=skills/talent-ceo/scripts`. Cada uno de los cinco comandos de abajo está ejecutado.
S=.claude/skills/talent-ceo/scripts

# 1) ¿Tengo perfil, y es válido? Sin esto, nada de lo demás significa nada.
bash $S/lib-perfil.sh --check          # 0 válido · 1 viola V1-V9 · 2 sin perfil (fail-closed)
# Nada de lo demás arranca sin perfil válido: rc 2 es fail-closed, nunca un 0 silencioso.

# 2) ¿Qué ha pasado en el bus desde la última vez que MIRÉ YO?
TA_BUS=/ruta/al/bus bash $S/bus-leer.sh --lector CEO

# 3) ¿Con qué minutos corre mi tabla? (del perfil, nunca de memoria)
bash $S/tablas-cron.sh --minutos tabla-mergeadores

# 4) Entregar un relevo, viendo antes el comando exacto
bash $S/relay-ceo.sh --a canal:$CANAL_ID --fichero ~/relevo.txt --dry-run

# 5) Sellar un hito (la hora la mide el sellador, no se la pasa nadie)
TA_BUS=/ruta/al/bus bash $S/bus-sellar.sh --rol CEO --marcador HITO --nota "lo que consta"
```

## Essential Patterns Quick Reference

| Necesitas | Usa | rc que importan |
|---|---|---|
| Validar el perfil | `lib-perfil.sh --check` | 0 · 1 viola V1-V9 · **2 sin perfil** |
| Leer filas de un tipo | `perfil_rows <tipo>` | 0 · **1 cero de ese tipo** · 2 sin perfil o inválido |
| Leer LA fila | `perfil_row1 <tipo> [id]` | 0 · 1 ausente o >1 · 2 |
| Sellar | `bus-sellar.sh --rol R --marcador X` | 0 · 2 precondición · **3 repetido** |
| Leer el bus | `bus-leer.sh --lector <ID>` | 0 · 2 (incluye **cursor inválido** y **emisión interrumpida**) |
| Minutos de una tabla | `tablas-cron.sh --minutos <id>` | 0 · 1 sin fila cron · 2 |
| Tabla de players | `perfil-render.sh --tabla players` | 0 · **1 sin fila `pm`** · 2 |
| Vigilar cuota | `vigia-cuota.sh --valor N --estado F` | 0 sin cambio · **10 transición** |
| Antigüedad de un proceso | `runners-vivos.sh --etime <ETIME>` | 0 · 1 no parseable |
| Estado de un composer | `ronda-canales.sh --clasificar` | `empty\|ghost\|text\|queued` |
| ¿Lo declarado corre de verdad? | `doctor.sh` (solo lectura) | 0 puerta abierta · **1 algún FALLA o NOVERIF** · 2 no puede evaluar |
| Re-acreditar un actor | `reacreditar.sh --rol R --iniciar\|--verificar` | 0 · **1 sin sello válido posterior** · 2 precondición |

**El mapeo de rc que hay que tener claro** (y que no es capricho): una violación del contrato da
**rc 1 en el validador** pero **rc 2 en las APIs que sirven filas**. Motivo: en esas APIs el rc 1 ya
significa «cero filas de ese tipo», que es una respuesta *normal*. Si un perfil corrupto también
diera 1, «este fichero está roto» sería indistinguible de «este host no tiene crons»: **fail-open
silencioso**. Un perfil inválido es input inservible ⇒ mismo cubo que ausente.

## Critical Gotchas

1. **`ps -o etime` tiene TRES formas, y la tercera lleva guion** (2026-09-06). `MM:SS`,
   `HH:MM:SS` y **`D-HH:MM:SS`**. Un parser que solo parta por `:` lee `5-03` como minutos y
   devuelve una antigüedad absurda **justo para los procesos más viejos**, que son los que
   interesan. `runners-vivos.sh` separa el tramo de días por `-` antes de tocar los `:`.

2. **Comparar rutas NO es comprobar identidad** (2026-09-06). Decidir «¿este fichero es el bus?»
   comparando cadenas deja **cuatro** puertas abiertas: ruta relativa, `..`, symlink y hardlink.
   Se compara con `-ef` (dispositivo + inodo). Hay test para las cuatro.

3. **Buscar fuera del candado convierte el rc 3 en decoración** (2026-09-06). Si el marcador se
   busca antes de tomar el lock, dos escritores concurrentes pueden ver ambos «no está» y sellar
   los dos. La búsqueda **y** el append van dentro de la misma sección crítica.

4. **`-L` se pregunta ANTES que `-d` o `-f`** (2026-09-06). Un symlink a un directorio satisface
   `-d`, así que preguntar primero por directorio deja pasar exactamente el ataque que se quiere
   impedir. Vale para el directorio de cursores, el cursor y el lock.

5. **Un cursor mayor que el bus significa truncado, no «al día»** (2026-09-06). Emitir desde ahí
   da vacío y el lector se cree al corriente: fail-open. Se falla cerrado (rc 2) **sin tocar el
   cursor**, y el diagnóstico imprime cursor y tamaño **sin volcar el bus**.

6. **El texto atenuado del composer NO es una orden** (2026-09-06). El placeholder que pinta la
   propia interfaz se clasifica `ghost`, no `text`. Confundirlos hace creer que un canal tiene
   trabajo cuando está ocioso y, peor, invita a obedecer un texto que no escribió nadie.

7. **Avisar por nivel destruye la señal** (2026-09-06). Un vigía que repite el aviso en cada tick
   mientras el valor sigue alto entrena a ignorarlo. Se emite **por transición**; y el primer tick
   sin estado previo **no grita**: registra el lado y calla.

8. **`printf '%-*s'` cuenta bytes, no caracteres** (2026-09-06). Con «—» (3 bytes en UTF-8) la
   tabla se desalinea **justo en las celdas sin dato**, que son las que hay que mirar. Se cuenta
   con `${#s}`.

9. **`$?` se captura en una variable INMEDIATAMENTE** (2026-09-06). Cualquier sustitución de
   comandos en la misma línea —un `$(basename …)` dentro del propio `printf`— lo pisa. Un test que
   mide el rc equivocado **falla contra código sano** e invita a romperlo.

## Cross-Skill Integration

- **`talent-pm`** — la contraparte: el PM decide QUÉ, el CEO CÓMO. La frontera, en la ref 01.
- **`talent-orchestrator`** — reparte **encargos** a coordinadores; cuando hay orquestador el CEO
  no reparte encargos canal a canal. **Entregar un relevo no es eso**: la ref 01 lista el canal
  entre los destinos legítimos de un relay, y por eso el ejemplo de arriba releva a un canal.
- **`talent-merger`** — único consumidor de CodeRabbit y quien mergea; el CEO no mergea.
- **`talent-channel-operation`** — la estación que lleva encargos a PR draft + HANDOFF.
- **`talent-context`** — de ahí viene el criterio de `ghost` y la doctrina compact-60 que usa la
  ref 06.
- **`talent-channels`** — aprovisiona las máquinas donde vive todo esto.

## Next Steps

1. Lee la **ref 04** y valida tu perfil: sin perfil válido, el resto del skill no arranca.
2. Lee la **ref 02** antes de sellar por primera vez: el bus es append-only y compartido.
3. Si vas a montar las tablas, la **ref 03** trae las columnas y **la fuente de cada celda**; una
   celda sin fuente se pinta `—`, nunca en blanco.
4. Tras un relanzamiento, la **ref 06**: paso-0, y qué se mide en vez de suponerse.

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6): `skill-creator/references/09-paquete-de-fabrica.md`.
Nunca vuelques el entorno ni ficheros de credenciales; comprueba únicamente nombres y presencia.
