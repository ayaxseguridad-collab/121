# 02 · El pipeline de reparacion

Como pasar de una memoria degradada a una memoria fiable **sin borrar nada**. Este
documento es la metodologia completa; los scripts del skill son la red de seguridad
antes y despues, pero cada decision de este pipeline la tomas TU (o tu sesion de
Claude Code contigo mirando). Ningun script adjudica por ti.

## Table of Contents

- [1. Las dos leyes](#1-las-dos-leyes)
- [2. La regla de autoridad](#2-la-regla-de-autoridad)
- [3. Los cinco estados](#3-los-cinco-estados)
- [4. El patron de anulacion](#4-el-patron-de-anulacion)
- [5. Los siete pasos, en orden](#5-los-siete-pasos-en-orden)
- [6. Paso 1: dedupe y consolidacion](#6-paso-1-dedupe-y-consolidacion)
- [7. Paso 2: contradicciones](#7-paso-2-contradicciones)
- [8. Paso 3: normas superadas](#8-paso-3-normas-superadas)
- [9. Paso 4: caducadas y superseded](#9-paso-4-caducadas-y-superseded)
- [10. Paso 5: decisiones pendientes](#10-paso-5-decisiones-pendientes)
- [11. Paso 6: sync con la realidad](#11-paso-6-sync-con-la-realidad)
- [12. Paso 7: espejos](#12-paso-7-espejos)
- [13. Declarar los cambios](#13-declarar-los-cambios)

## 1. Las dos leyes

**Ley 1 — append-only.** El historico no se borra: se anula en su sitio. Una nota
derogada CON su marca de anulacion es un activo (prueba de que quedo derogada, y de
por que); una nota borrada es un agujero que la proxima copia vieja, o tu propia
costumbre, vuelve a llenar con la norma muerta. Borrar fisicamente un fichero es una
operacion excepcional que exige decision explicita tuya, registrada — nunca un paso
rutinario del pipeline. Y esa excepcion autoriza al HUMANO, no al tooling: ocurre
FUERA del pipeline, ningun modo de `verificar.sh` la representa, y el mundo cerrado
marcara la desaparicion en rojo — correctamente: ese rojo es tu registro de que la
excepcion ocurrio, no un fallo a silenciar.

**Ley 2 — sustituir no es anular.** Escribir la norma nueva en otra nota NO mata a la
vieja: la vieja sigue ahi, y quien lea con `grep` (que corta en la primera
coincidencia) puede encontrarla primero y obedecerla. Toda derogacion se marca SOBRE
el texto derogado, no solo al lado de su sucesor.

## 2. La regla de autoridad

«Lo mas reciente gana» es el desempate, no la ley. La fecha SOLO decide entre fuentes
del **mismo nivel de autoridad**:

```text
  nivel 1  decision explicita tuya        la dijiste o la sellaste tal cual;
           (mayor autoridad)              nadie la deroga por escribir despues
  nivel 2  instrucciones vigentes         CLAUDE.md del repo manda en su repo;
           por ambito                     CLAUDE.md global manda fuera de el
  nivel 3  notas de memoria               el grueso del corpus
           (menor autoridad)
```

- **Distinto nivel** → el nivel superior determina que se OBEDECE mientras tanto —
  pero NO autoriza reescribir nada. Un conflicto entre niveles distintos es
  fail-closed: no se modifica ninguna de las dos fuentes, se registra un placeholder
  de decision pendiente (paso 5) y se pregunta ANTES de anular o acotar la fuente
  inferior. Una nota de la semana pasada no anula una linea vigente de tu CLAUDE.md;
  y la nota tampoco se anula sola: quiza lo desactualizado es el CLAUDE.md, y eso
  solo lo decides tu.
- **Mismo nivel, ambas con fecha** → gana la mas reciente, y la perdedora recibe su
  bloque de anulacion (seccion 4) citandola.
- **Sin fecha, o autoridad ambigua** → NO se toca nada. El conflicto se registra como
  decision pendiente (paso 5) y se resuelve preguntando a quien manda: tu. Inventarse
  la antiguedad es fabricar historia.

Origen de esta regla: en el corpus donde se rodo esta metodologia, la recencia fue un
criterio decidido explicitamente por el dueno del corpus PARA esa pasada. Aqui se
generaliza solo lo generalizable: recencia como desempate entre iguales, jerarquia
por encima.

## 3. Los cinco estados

Toda nota que pierde una adjudicacion queda en exactamente uno de estos estados,
marcado en el cuerpo Y en el `description:` del frontmatter (gotcha 4 del SKILL.md):

| Estado | Cuando | Que sigue vigente |
|---|---|---|
| `ANULADA` | una decision posterior la derogo entera | nada: solo su valor historico |
| `ACOTADA` | sigue viva pero SOLO en un subdominio | la parte acotada, nada mas |
| `CADUCADA` | tenia ventana temporal declarada y vencio | nada; ni siquiera hizo falta derogarla |
| `SUPERSEDED` | una doctrina nueva la reemplaza como sistema | lo que la sucesora conserve explicitamente |
| `ALIAS-STUB` | su contenido se consolido en otra nota | todo, pero VIVE EN LA SUCESORA |

La diferencia entre `ANULADA` y `SUPERSEDED` es de grano: anulas una norma concreta;
supersedes un regimen completo (y entonces conviene decir que partes de la mecanica
vieja se CONSERVAN, si alguna — una supersede sin conservaciones explicitas invita a
tirar tambien lo que seguia sirviendo).

Formato del description de una perdedora (los indices y previews solo ensenian esta
linea, asi que el estado va delante):

```text
description: "[ANULADA 2026-07-27] → sucesora: politica-backups-v2 — pedia backup
manual diario; desde el 27-jul lo hace el cron. Historico."
```

## 4. El patron de anulacion

Cuatro campos, colocados **ANTES** del texto muerto (la marca se lee primero):

```text
> ANULADA 2026-07-27 — el backup manual quedo automatizado.
> Linea muerta: "haz backup manual de la base cada dia antes de trabajar"
> Linea vigente: [[politica-backups-v2]] (cron diario, verificado 27-jul)
> Autoridad: decision propia, sesion del 27-jul.

haz backup manual de la base cada dia antes de trabajar    <- queda tal cual, debajo
```

- **Linea muerta**: cita literal **OBLIGATORIA** (el numero de linea puede
  ACOMPAÑARLA si el fichero es largo, pero no la sustituye: `verificar.sh` exige la
  cita para correlacionar la marca con el texto muerto real). Sin cita, dentro de
  tres meses nadie sabra que parte exacta quedo derogada.
- **Linea vigente**: enlace o nombre de la nota/decision sucesora. Si usas `[[wiki-links]]`,
  usalos; si no, el slug o la ruta valen — lo importante es que un grep lo encuentre.
- **Motivo**: una frase. "Porque si" no sobrevive al tiempo.
- **Autoridad**: quien y cuando. En tu corpus personal, "decision propia + fecha".

Prueba rapida de colocacion: `grep -nE -m1 'ANULADA|<fragmento de la linea muerta>'
fichero.md` debe devolver la linea de la MARCA, no la norma muerta.

Para `ACOTADA`, mismo esqueleto con el alcance residual explicito:

```text
> ACOTADA 2026-07-27 — de criterio general a caso particular.
> Linea muerta (como criterio GENERAL): "si el test pasa aislado, es un flake"
> Linea vigente: [[gotcha-rerun-aislado-evidencia-debil]]
> Alcance residual: SOLO para sospecha de fallo de infraestructura; NUNCA adjudica
> el resultado de un fix.
```

## 5. Los siete pasos, en orden

```text
  1 dedupe          menos notas          ┐ cada paso reduce el
  2 contradicciones menos conflictos     │ trabajo del siguiente:
  3 superadas       menos normas vivas   │ adjudicar antes del dedupe
  4 caducadas       menos regimen viejo  │ = adjudicar lo mismo N veces;
  5 pendientes      conflictos aparcados │ caducar antes de adjudicar
  6 sync realidad   cero mapas falsos    │ puede caducar al ganador
  7 espejos         una sola verdad      ┘
  (y el indice SIEMPRE al final: ver references/04)
```

Antes del paso 1: `diagnostico.sh` (censo) y `salvaguarda.sh` (snapshot). Sin
salvaguarda no se toca nada — ver `references/03`.

Si tu corpus es pequeno (menos de ~30 notas), puedes hacer los 7 pasos en una sola
sesion. Si es grande, una pasada por paso, verificando entre pasos: los pasos estan
disenados para ser seguros por separado.

## 6. Paso 1: dedupe y consolidacion

Busca pares de notas que cuentan lo mismo. El diagnostico te da candidatos (titulos
parecidos, slugs parecidos); la decision de si son duplicados es tuya.

- **Duplicado exacto o casi**: gana el **superconjunto** (la nota mas completa). Antes
  de tocar nada, lista las clausulas que SOLO estan en la perdedora; migralas al
  ganador en una seccion `Clausulas fusionadas (fecha) desde <perdedora>`; y despues
  comprueba con `grep` que CADA clausula aparece en el superviviente. Lo que no
  aparezca, se perdio en la fusion.
- **La perdedora NO se borra**: queda como **alias-stub** — un fichero minimo que
  declara donde vive ahora el contenido:

```text
---
description: "[ALIAS-STUB 2026-07-27] → sucesora: politica-tests-completa — ..."
---
**[ALIAS-STUB 2026-07-27]** Consolidado en [[politica-tests-completa]]
(superconjunto: incluye las 3 clausulas exclusivas de esta nota, migradas).
Este archivo existe para no romper enlaces y greps entrantes.
```

El stub es minimo **a proposito**: el historico NO se pierde — vive en el ganador via la
fusion VERIFICADA (cada clausula del perdedor se comprueba por `grep` en el superviviente,
y `verificar.sh` lo exige en el modo `semantico:fusion`). Conservar ademas el cuerpo viejo
en el stub re-crearia la duplicacion que la fusion existe para curar.

- **Parecidas pero NO duplicadas** (mismo tema, matices distintos): NO fusionar a
  ciegas. O conviven con una linea que las cruce ("ver tambien X para el caso Y"), o
  la fusion preserva TODOS los matices. En la duda, convivir es mas barato que perder
  una clausula.

Clasifica cada fichero tocado: `alias-stub` | `fusionado` | `retirado` (este ultimo
solo con tu decision explicita registrada). Esa clasificacion va al plan de cambios
(seccion 13).

## 7. Paso 2: contradicciones

Con los duplicados fuera, lista los pares que se contradicen de verdad. Para cada par:

1. ¿Mismo nivel de autoridad? Si no → cross-level: NO se modifica nada; placeholder
   (paso 5) y preguntar — seccion 2. La adjudicacion por recencia es SOLO entre
   iguales.
2. ¿Ambas con fecha? Si no → paso 5 (pendiente).
3. Gana la mas reciente. La perdedora recibe el bloque de anulacion (o de acotacion,
   si sigue viva en un subdominio) ANTES de su texto, y su description se reescribe
   con el estado delante.

Registra la tabla de adjudicaciones (par → ganadora → motivo) en tu nota de la pasada
o en el propio plan de cambios: dentro de un mes esa tabla ES la memoria de por que
tu corpus quedo como quedo.

## 8. Paso 3: normas superadas

Normas que nadie contradijo nota-a-nota, pero que una decision posterior tuya dejo
sin efecto (cambiaste de herramienta, de flujo, de politica). Mismo tratamiento:
bloque de anulacion citando la decision que las supero. La nota **ancla** (la
decision vigente) NO se toca — se anula alrededor de ella, nunca a ella.

## 9. Paso 4: caducadas y superseded

`CADUCADA` y `SUPERSEDED` usan el **mismo esqueleto de 4 campos de la seccion 4**
(`Linea muerta` / `Linea vigente` / motivo en la apertura / `Autoridad`) — no es un
formato aparte, es el mismo patron de anulacion con el nombre del estado que toque:

- **CADUCADA**: la nota declaraba su propia ventana ("durante la migracion", "hasta
  que salga la version X") y la ventana vencio. Marca `CADUCADA + fecha + que la
  cerro` en la apertura, y el resto del bloque (`Linea muerta`/`Linea vigente`/
  `Autoridad`) igual que ANULADA. Es la anulacion mas barata: la nota ya habia
  consentido morir.
- **SUPERSEDED**: reemplazaste un sistema entero (tu regimen de tests, tu politica de
  ramas). Marca la doctrina vieja `SUPERSEDED + fecha + sucesora` en la apertura —
  y **declara las conservaciones** (que mecanica de la vieja sigue valiendo dentro
  de la nueva) en el motivo o en el cuerpo del bloque: recomendacion documental de
  esta seccion, no una etiqueta que el gate verifique. Sin conservaciones
  explicitas, lo util muere con lo obsoleto.

## 10. Paso 5: decisiones pendientes

Todo conflicto que NO pudiste adjudicar (sin fecha, autoridad ambigua, o simplemente
necesitas pensarlo) se aparca en una nota placeholder — corta a proposito:

```text
---
description: "[PENDIENTE 2026-07-27] conflicto sin adjudicar: politica de ramas"
---
Conflicto: [[nota-a]] dice X · [[nota-b]] dice Y. Sin fecha en nota-a.
Se resuelve: cuando yo decida. Mientras tanto: NINGUNA de las dos se toca.
```

Cinco lineas bastan. Un placeholder gordo escrito antes de decidir es trabajo tirado:
cuando decidas, lo reescribes igual. Lo unico que el placeholder debe garantizar es
que el conflicto no se te pierda y que NADIE (ni tu agente) lo resuelva de facto.

Este placeholder es un fichero **NUEVO**: se declara con modo `alta` en
`cambios-declarados.tsv` (`references/03` seccion 5), no `solo-adicion` — el
descriptor lleva su contenido COMPLETO, y `verificar.sh` comprueba que la ruta
NO estaba en el snapshot ademas de que el contenido coincida byte a byte.

## 11. Paso 6: sync con la realidad

La memoria describe tu mundo operativo. Cuando el mundo cambia y la memoria no, cada
nota en imperativo se vuelve un **mapa operativo falso**: "aplica el fichero X" cuando
X ya no existe, "usa el comando Y" cuando Y se retiro. Tu agente ejecuta esos mapas
con confianza — y falla, o hace algo peor.

- Busca notas que ordenen actuar sobre ficheros/comandos/procesos: verifica que
  existan. El diagnostico te da candidatos (rutas citadas que no resuelven).
- Lo muerto **NO se reescribe ni se borra**: se conserva INTACTO y se le antepone el
  bloque de anulacion del paso 3 (estado abriendo el `description:` + marca
  estructural ANTES del texto muerto) con puntero a la solucion vigente: "ANULADA
  <fecha> — quedo resuelto de forma permanente por Y. NO aplicar lo de abajo." Es la
  UNICA forma que `verificar.sh` acepta como `semantico:anulacion` (`references/03`)
  — reescribir la instruccion, aunque sea "a pasado", destruye el original que la
  verificacion exige correlacionar.
- Cabeceras y estados ("estamos en la fase Z") que ya no son verdad: tampoco se
  editan en sitio — anteponles el reencuadre conservando el texto original debajo:
  "Estado historico (mayo), ya no vigente:" + la linea original intacta.

## 12. Paso 7: espejos

Si la misma informacion vive en dos sitios (una nota en el repo y su copia en la
memoria general; un README y una nota que lo cita), decide cual es el **canonico** y
corrige SIEMPRE ahi primero; despues propaga a la copia. Corregir la copia es trabajo
perdido: la proxima sincronizacion (o tu proxima pasada) la pisa con el canonico
viejo. Si no sabes cual es el canonico, esa es una contradiccion mas: adjudicala
(paso 2) antes de tocar ninguna de las dos.

En corpus con historico append-only (un changelog, un log de decisiones), el asiento
viejo NO se reescribe: se anade una **errata al lado**, fechada, que remite a la
lectura vigente. El asiento se conserva tal cual; la errata gana.

## 13. Declarar los cambios

Cada pasada termina declarando QUE cambio, fichero a fichero, en
`cambios-declarados.tsv` (separador TAB; el formato exacto y la verificacion estan en
`references/03-salvaguardas-y-verificacion.md`):

```text
(las columnas van separadas por TAB real; aqui se escribe <TAB> para poder leerlo)
notas/politica-vieja.md <TAB> semantico:anulacion <TAB> descriptores/anulacion.txt
notas/politica-tests-completa.md <TAB> solo-adicion <TAB> descriptores/clausulas.txt
notas/nota-intocable.md <TAB> intacto <TAB> -
notas/pendiente-politica-ramas.md <TAB> alta <TAB> descriptores/pendiente-completo.txt
INDEX <TAB> [Tests](politica-tests-completa.md) — vigente 27-jul <TAB> [Tests](politica-vieja.md)
```

La regla que lo gobierna es **mundo cerrado**: lo que difiera entre el snapshot y tu
corpus debe ser EXACTAMENTE lo declarado — ni un fichero mas, ni una linea menos.
`verificar.sh` lo comprueba y falla cerrado. Reparar sin declarar es reparar a
ciegas: no sabras que mas cambio hasta que duela.
