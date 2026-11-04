# 03 · Salvaguardas y verificacion

Protegerte ANTES de tocar la memoria, y comprobar DESPUES que cambio exactamente lo
que declaraste — nada mas. Todo lo de este documento es fail-closed: en la duda, el
veredicto es rojo y no se avanza.

## Table of Contents

- [1. El mapa de salvaguardas](#1-el-mapa-de-salvaguardas)
- [2. S1: snapshot restaurable](#2-s1-snapshot-restaurable)
- [3. Cuando git puede sustituir al snapshot](#3-cuando-git-puede-sustituir-al-snapshot)
- [4. S3: el estado tambien en el frontmatter](#4-s3-el-estado-tambien-en-el-frontmatter)
- [5. El plan de cambios: cambios-declarados.tsv](#5-el-plan-de-cambios-cambios-declaradostsv)
- [6. S5: la prueba diferencial](#6-s5-la-prueba-diferencial)
- [7. Mundo cerrado](#7-mundo-cerrado)
- [8. S6: verificar el indice por contenido](#8-s6-verificar-el-indice-por-contenido)
- [9. verificar.sh: contrato completo](#9-verificarsh-contrato-completo)
- [10. Flujo manual sin bash](#10-flujo-manual-sin-bash)

## 1. El mapa de salvaguardas

```text
  ANTES de tocar             DURANTE                DESPUES
  ─────────────              ───────                ───────
  S1 snapshot +              declarar cada          S5 diferencial por fichero
     manifiesto de hashes    cambio en              S6 indice por contenido
     (o rama git si          cambios-declarados     mundo cerrado sobre el
      TODO esta limpio)      .tsv                   conjunto entero
```

La eleccion snapshot-o-git NO es tuya: la hace `salvaguarda.sh` con criterios duros
(seccion 3), y en la duda gana el snapshot. Los nombres S1/S3/S5/S6 vienen de la
metodologia original; se conservan para poder citarlos.

## 2. S1: snapshot restaurable

`salvaguarda.sh <dir-de-memoria>` produce, en un directorio hermano fechado FUERA del
corpus:

- `snapshot-<fecha>.tar.gz` — el corpus completo, tal cual esta.
- `manifest.txt` — `sha256sum` de cada fichero del corpus. El manifiesto es lo que
  permite despues distinguir "intacto" de "tocado" fichero a fichero.
- Permisos restrictivos (directorio 0700, ficheros 0600): tu memoria puede contener
  cosas que no quieres pasear.

Restaurar = extraer el tar sobre un directorio vacio y (si restauras el corpus
entero) mover. `tests/probar-salvaguarda.sh` demuestra el ciclo completo: crear,
extraer a un destino temporal y comprobar que los hashes restaurados coinciden con el
manifiesto. Un snapshot que no se probo restaurar es una esperanza, no una
salvaguarda.

El snapshot se conserva hasta que la pasada este verificada en verde. Despues puedes
archivarlo o tirarlo: el corpus reparado ya lleva su historia dentro (append-only).

## 3. Cuando git puede sustituir al snapshot

Si tu memoria vive dentro de un repositorio git, una rama + `git diff` dan lo mismo
que S1/S5 — pero SOLO si git de verdad tiene el baseline. `salvaguarda.sh` lo
comprueba con criterios duros y elige por ti:

```text
  ¿git valido como salvaguarda?           (TODOS deben cumplirse)
  ├── el corpus esta dentro de un worktree git
  ├── TODOS los ficheros del corpus estan rastreados
  │     (git ls-files --error-unmatch <cada-uno> → 0)
  ├── NINGUNO tiene cambios sin commitear
  │     (git status --porcelain sobre el corpus → vacio)
  └── todos existen en HEAD
  → SI a todo: rama de trabajo + git diff sirven
  → cualquier NO: SNAPSHOT OBLIGATORIO (el script lo dice y por que)
```

El caso que engana: un fichero **untracked**. Esta "en el repo" a ojos tuyos, pero no
esta en ningun commit — si la reparacion lo pisa, `git checkout` no te lo devuelve.
Por eso el criterio es fail-closed. La memoria general del harness
(`~/.claude/projects/<slug>/memory/`) y el CLAUDE.md global de usuario van SIEMPRE
por snapshot: no viven en git.

## 4. S3: el estado tambien en el frontmatter

Toda nota que pierda una adjudicacion lleva el estado en DOS sitios: el bloque en el
cuerpo (patron de 4 campos, `references/02` seccion 4) y el `description:` del
frontmatter, empezando por el estado:

```text
description: "[ANULADA 2026-07-27] → sucesora: <slug> — <resumen historico>"
```

Por que dos sitios: los indices, buscadores y previews solo leen el description. Una
nota anulada con description intacto se sigue **vendiendo como viva** en todas las
superficies que no abren el fichero.

**El estado debe ABRIR el description, no aparecer de pasada.** Un description
vigente que solo MENCIONA el estado ("...la anterior quedo ANULADA en mayo") sigue
vendiendo la nota como viva: los indices y previews leen esa linea entera, no
buscan la palabra dentro. `verificar.sh` (`tm_s3_ok`/`tm_s3_estado`) exige que el
estado sea lo PRIMERO del contenido efectivo del description (tolera comillas y un
`[` de apertura):

```text
description: "[ANULADA 2026-07-27] → sucesora: <slug> — <resumen historico>"
                ^^^^^^^ debe abrir aqui, no aparecer mas adelante
```

## 5. El plan de cambios: cambios-declarados.tsv

Cada pasada de reparacion termina en un TSV que declara el universo COMPLETO de lo
que cambio. Gramatica (separador = TAB, una fila por entrada):

```text
  filas de fichero:   <ruta> TAB <modo> TAB <descriptor>
    modo:  intacto        el fichero NO debio cambiar (se verifica por hash);
                          descriptor = '-'
           solo-adicion   solo se anadieron lineas; <descriptor> = ruta al fichero
                          con el bloque anadido EXACTO (linea a linea)
           alta           fichero NUEVO (no estaba en el snapshot): <descriptor> =
                          ruta al fichero con el CONTENIDO COMPLETO, byte a byte
                          (p. ej. el placeholder de decisiones pendientes, seccion
                          10; el indice se declara `semantico:indice`, no `alta`)
           semantico:anulacion   reescritura legitima; descriptor: linea 1 =
                          fragmento literal de la linea muerta
           semantico:fusion      descriptor: una clausula preservada por linea
                          (TODAS deben aparecer en el ganador)
           semantico:alias-stub  descriptor: linea 1 = slug/nombre de la sucesora
           semantico:indice      para el fichero indice cuando sus lineas se
                          sustituyen legitimamente (compactar, actualizar
                          one-liners); descriptor = '-' — lo verifican sus
                          filas INDEX (obligatorias: sin ellas, ROJO)
  filas de indice:    INDEX TAB <one-liner-nuevo> TAB <one-liner-viejo>
    (la palabra clave INDEX en la columna 1 las distingue de las rutas)
```

**NO existe un modo de "borrado autorizado", a proposito**: el corpus es append-only
(paso 3 — nunca borrar historico) y una baja legitima se modela como
`semantico:anulacion` o `semantico:alias-stub`, jamas como desaparicion del fichero.
Por eso CUALQUIER ruta que falte respecto al snapshot es ROJO sin excepcion: es la
propiedad central del mundo cerrado, no una limitacion.

Reglas duras del parser (exit 2 si se violan): TAB como unico separador · exactamente
3 columnas por fila · rutas con espacios permitidas (por eso el TAB) · un TAB o salto
de linea DENTRO de una ruta no es representable y se rechaza · rutas relativas al
directorio del corpus · un path solo puede aparecer en una fila · **el descriptor
NUNCA symlink ni hardlink al fichero del corpus, ni un fichero que viva DENTRO del
corpus** (identidad de fichero, no de ruta textual: un descriptor "externo" que en
realidad ES la norma que dice verificar deja cualquier diff comparando el mismo
inodo consigo mismo — critico en `alta`, que compara el fichero completo).

Las filas `intacto` son opcionales fichero a fichero (todo lo no declarado se ASUME
intacto y se verifica igual — seccion 7); declararlas explicitamente sirve para los
ficheros que te preocupan.

## 6. S5: la prueba diferencial

Para cada fila `solo-adicion`, el hash no basta: un hash distinto no distingue "le
anadi el bloque" de "lo reescribi entero". La prueba es un diff dirigido, fail-closed:

```bash
d="$(mktemp)"; base="$(mktemp)"
trap 'rm -f "$d" "$base"' EXIT               # NUNCA una ruta fija en /tmp: dos
                                             # ejecuciones colisionan y en maquina
                                             # compartida es blanco de symlink
tar -xzOf snapshot.tar.gz "$ruta" > "$base" || exit 1
                                             # rc de TAR medido APARTE: dentro de un
                                             # <(…) se pierde, y una extraccion
                                             # fallida (stream vacio) haria que diff
                                             # viera "todo añadido" en vez de ROJO
diff "$base" "$corpus/$ruta" > "$d"; rc=$?
[ $rc -le 1 ] || exit 1                      # diff roto (fichero ausente…) = ROJO
! grep -q '^<' "$d" || exit 1                # CUALQUIER linea eliminada = ROJO
diff <(grep '^>' "$d" | sed 's/^> //') "$descriptor" || exit 1
                                             # lo anadido == el bloque declarado,
                                             # ni una linea mas, ni una menos
```

Si esto da rojo NO se "arregla a mano sobre la marcha": se restaura del snapshot y se
repite la pasada. Arreglar a mano encima de una pasada fallida es como se pierden
clausulas sin enterarse.

## 7. Mundo cerrado

La salvaguarda por fichero no basta: una reparacion puede hacer bien todo lo
declarado y ADEMAS tocar un fichero que nadie declaro. Por eso el verificador
computa el conjunto real de diferencias y lo compara con el declarado:

```text
  manifiesto(snapshot)  vs  manifiesto(corpus actual)
        │
        ├── ficheros con hash distinto  ┐
        ├── ficheros nuevos             │ = CONJUNTO REAL de deltas
        └── ficheros desaparecidos      ┘

  CONJUNTO REAL  ==  filas declaradas con modo != intacto
        (las filas `intacto` se verifican por hash, pero NO son deltas)
  cualquier path real no declarado  → ROJO, exit != 0, con el path en el motivo
  cualquier path declarado que NO cambio → ROJO tambien (declaraste de mas:
        o la pasada quedo a medias, o el TSV esta desactualizado)
```

Este es el cierre que convierte "hice lo que dije" en algo comprobable: no hay
categoria de cambio invisible.

## 8. S6: verificar el indice por contenido

Si tu corpus tiene un indice (MEMORY.md o equivalente), verificarlo por nombre de
fichero es un **verde falso**: el nombre ya estaba antes de tu cambio. Cada fila
`INDEX` del TSV se comprueba por contenido, en positivo Y en negativo:

```bash
grep -F -x -q "$one_liner_nuevo" MEMORY.md      # el nuevo esta, EXACTO (linea entera)
! grep -F -q "$one_liner_viejo" MEMORY.md       # el viejo ya no esta
```

Sin el negativo, un indice con la linea nueva ANADIDA pero la vieja sin quitar pasa
la comprobacion — y quien lea el indice seguira encontrando la entrada muerta.

## 9. verificar.sh: contrato completo

```bash
bash scripts/verificar.sh <snapshot-dir> <corpus-dir> <cambios-declarados.tsv>
```

- **Entradas**: `<snapshot-dir>` debe contener el tar y `manifest.txt` de
  `salvaguarda.sh`; el TSV debe parsear con la gramatica de la seccion 5. Cualquier
  entrada ausente o malformada → **exit 2** con el motivo (no un verde vacio: un
  verificador que "no encontro que verificar" y sale 0 es el peor verde falso).
- **Symlinks: NO soportados, fail-closed (exit 2)** — en `salvaguarda.sh`,
  `verificar.sh` Y `diagnostico.sh` (el censo, `references/01` §4), y ademas como
  defensa en profundidad DENTRO de `tm_manifest`/`tm_git_baseline` (lib.sh): un
  symlink no entra en `find -type f`, asi que podria cambiar de destino (o
  aparecer/desaparecer) sin dejar delta en los hashes, agujereando el mundo
  cerrado — o el censo, o el criterio de baseline git — sin que nadie lo note.
  Si tu corpus los necesita, sustituyelos por ficheros reales antes de la pasada.
- **Por fila**: `intacto` → hash identico. `solo-adicion` → prueba S5. `alta` →
  el fichero NUEVO **no** puede estar en el snapshot (si lo esta, es reescritura
  disfrazada), **debe** existir en el corpus, y su contenido COMPLETO debe
  coincidir byte a byte con el descriptor — mundo cerrado sigue intacto: un
  `alta` no declarada sigue dando ROJO (seccion 7), y el descriptor pasa el
  guard anti-circularidad de la seccion 5 (symlink/hardlink/dentro del
  corpus → exit 2). `semantico:*` → checks minimos por categoria:
  - `anulacion` — la marca es el **BLOQUE COMPLETO**, no una palabra suelta en
    prosa: apertura `> ESTADO fecha — motivo` acotada a `ANULADA|ACOTADA|CADUCADA|
    SUPERSEDED` (`ALIAS-STUB`/`PENDIENTE` tienen contrato propio y NO cuentan
    aqui) con fecha ISO valida (rangos de mes/dia y delimitada contra digito
    adyacente) y motivo real (>=3 alfanumericos); ANTES del texto muerto
    (gotcha 2); los campos `Linea muerta`/`Linea vigente`/4o campo condicionado
    al estado (`Alcance residual` si ACOTADA, `Autoridad` en el resto) con
    payload real (>=2 alfanumericos cada uno); la cita de `Linea muerta`
    CORRELACIONA con el fragmento del descriptor; y el token de estado del
    cuerpo COINCIDE con el que abre `description:` (S3).
  - `fusion` exige que CADA clausula listada en el descriptor aparezca en el
    fichero (grep -F por clausula).
  - `alias-stub` exige marca ALIAS-STUB + referencia a la sucesora + S3.
  El verificador NO juzga si la adjudicacion fue correcta — eso es tuyo; juzga
  que la mecanica no perdio nada.
- **Global**: mundo cerrado (seccion 7) sobre el conjunto entero + S6 por cada fila
  INDEX.
- **Salidas**: `OK` (todo verde) · `FALLO` con cada motivo y su path · exit 0 solo
  con todo verde.

## 10. Flujo manual sin bash

Sin bash (o si prefieres verlo con tus manos), el equivalente minimo:

1. **S1**: copia el directorio entero a `memoria-backup-<fecha>/` y guarda un listado
   con hashes (en cualquier SO moderno hay un equivalente de `sha256sum`).
2. **Declara** en un fichero de texto que vas a tocar y como, antes de tocar.
3. **S5**: tras la pasada, compara cada fichero declarado con su copia (cualquier
   herramienta de diff); en los `solo-adicion`, comprueba que no hay lineas en el
   lado del backup que falten en el actual.
4. **Mundo cerrado**: recorre el listado de hashes y confirma que SOLO difieren los
   ficheros declarados.
5. **S6**: abre el indice y busca el texto nuevo (debe estar) y el viejo (no debe).

Es exactamente lo que hacen los scripts, sin ellos. Mas lento, igual de seguro si no
te saltas el paso 4 — que es el que todo el mundo se salta.
