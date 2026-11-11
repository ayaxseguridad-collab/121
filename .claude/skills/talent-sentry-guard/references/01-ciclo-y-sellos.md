# 01 — Ciclo, cursor, ticker, sellos y cadencia

> Fuente: TAL-5157 §B1 (la figura) + §B8 gotchas 8-9 (mudeces del ticker) +
> mecánica heredada de `~/.sentry-analista/ciclo.sh` de C3 (fuera del repo,
> versionada aquí). Leer antes de arrancar la guardia o tras un compact.

## Cadencia (B1)

| Señal | Cada | Qué |
|---|---|---|
| Tick del ciclo | 5 min | Un barrido de las 4 fuentes (ver `05-fuentes-y-consultas.md`) |
| Parte al bus | la del perfil (fila `cron`, ver «Parte de guardia») | Resumen al bus `/tmp/merge-claims.txt` vía `~/sellar.sh` |
| Parte de guardia | la del perfil: `tablas-cron.sh --minutos <id>` (id por defecto `vigia-parte`) | `scripts/parte_guardia.sh` mide; el operador sella |
| Heartbeat | 4 h | `SENTRY-HEARTBEAT` con el estado (nada nuevo ≠ nada corriendo) |
| Digest al CEO | 12 h | Resumen de incidentes, WATCH movidos, issues creadas |

## Parte de guardia (`scripts/parte_guardia.sh`)

El parte es un script, no prosa. Una pasada: puerta del doctor (`--solo-fuentes`), issues NUEVAS de Sentry,
alertas de seguridad de GitHub y consultas de dinero de solo lectura. **No sella al bus ni instala cron**: mide
y emite; la cadencia la pone la fila `cron` del perfil (el skill no lleva ningún número) y el sello es del operador.

- **Una cifra por línea**, siempre `tree=<sha> instant=<UTC> metric=<n> value=<v> …`. Una cifra sin árbol e
  instante no es una medida. El árbol es el HEAD del repo declarado (`TA_PARTE_REPO` ruta absoluta +
  `TA_PARTE_REPO_ID` = `stat -c %d:%i <repo>/.git`); jamás sale del cwd. Repo ausente o con otra identidad = rc 2
  sin una sola cifra, y todo Git corre con `env -i` y rutas explícitas.
- **Sección de issues nuevas (obligatoria)**: grupos de Sentry no vistos en el parte anterior (`~/.vigia-sentry/parte.json`,
  estado propio del parte; el cursor del ciclo de 5 min no se toca) y, durante los 60 min posteriores a cada fusión,
  los de `firstSeen` posterior al ancla. `sentry_triage.py` sigue el cursor de Sentry (tope de 20 páginas por
  ordenación; superarlo es un fallo, no un truncado), así que `sentry_unresolved_total` cuenta todas las páginas.
  Un parte sin esta sección es inválido: se imprime siempre, aunque la consulta falle.
- **Ancla de despliegue** (`SENTRY_MAIN_MOVIDO`): una línea `<epoch entero> <sha>`. Ausente: «sin ancla» declarado
  (con `TA_PARTE_EXIGE_ANCLA=1`, fallo). Presente pero mal formada (p. ej. solo el sha): `SONDA-ROJA`, no una ventana
  que se queda sin activar.
- **Dinero** (`SENTRY_PARTE_MONEY_SQL`, TSV `nombre<TAB>select…`): solo `select`/`with` de una sentencia, por la Management
  API con `read_only`. Sin fichero: `DINERO-NO-CONFIGURADO`. Una fila devuelta es novedad.
- **Silencio**: `silencio_previo` mide los minutos desde el parte anterior; si superan `2 × cadencia` (derivada del
  perfil) el parte no es `LIMPIO`. Sin fila `cron`: `SILENCIO-NO-MEDIDO`. El SILENCIO también es alerta.
- **Estado**: `LIMPIO` (rc 0), `NOVEDAD` (rc 0) o `SONDA-ROJA` (rc 1).
  El estado LIMPIO es inalcanzable si alguna sección no corrió, si la puerta del doctor está cerrada o si falta la configuración de dinero. GitHub sin
  configurar se declara «no vigilada» (no es fallo ni calma). El estado del parte solo avanza si el parte está completo.
- Ningún token ni valor de `secret` sale por la salida; los textos de Sentry y GitHub se imprimen como datos
  (una línea, sin comillas ni backticks). Todo texto reflejado (título, enlace, motivo de un error) pasa por el
  enmascarado de las credenciales declaradas y de cualquier `Authorization:`/`Bearer`; si algo se enmascara, el
  parte es `SONDA-ROJA` (`credencial-reflejada`), nunca `LIMPIO`. Las consultas de dinero rechazan además `INTO`.
  El `Link` de Sentry solo se sigue si es exactamente el endpoint de issues del proyecto (sin `../` ni segmentos extra).

## Cursor y diff incremental

- `~/.vigia-sentry/cursor.json` guarda el último barrido: por grupo, el
  `lastSeen` y el `count` vistos. El ciclo clasifica **solo el delta** contra
  ese cursor — un grupo que no se movió no se re-triagea.
- El cursor es de la máquina de la Vigía. Un tercero que valide fuentes NO
  lo tiene ni debe fabricarlo (ver gotcha #14 del SKILL y `--solo-fuentes`).
- `sentry_doctor.sh` exige `cursor.json` legible y JSON válido antes de
  abrir la puerta (check de RUNTIME, no de FUENTE).

## Ticker — las dos mudeces de la primera noche (gotcha 8)

**El pane quieto NO prueba que el tick esté vivo.** El despertador one-shot
murió en silencio dos veces la primera noche (50 min y 3h24m sin latido). Por
eso:

- El ticker es un **bucle infinito** que escribe un `TICK <ISO>` a
  `~/.vigia-sentry/tick.log` en cada vuelta — nunca un `sleep` one-shot.
- Un **monitor externo de staleness** vigila la mtime de ese log: si supera el
  umbral (900 s, fijo en producción), es fallo.
- `sentry_doctor.sh` (check `check_tick`) mide esa mtime contra ese umbral —
  un TICK viejo es PUERTA CERRADA, no calma. El umbral es override-able vía
  `SENTRY_DOCTOR_TICK_UMBRAL` (igual que `SENTRY_DOCTOR_TICK_LOG` para la
  ruta), pero **NO es config de tenant**: es un SEAM de test —
  `sentry_doctor.sh:149-157` lo enumera junto a cliente/header-file/path de
  runtime como override que `seams_presentes()` debe cazar, y su sola
  presencia en el entorno de producción significa "entorno contaminado", no
  "umbral ajustado a propósito". Úsalo solo para acortar la espera en un
  test local — nunca lo exportes en el runner real.

## Matar procesos del propio ciclo — self-match (gotcha 9)

`pkill -f <needle>` / `pgrep -f <needle>` con el nombre del propio watcher
**se auto-matchea** (el pgrep aparece en su propia búsqueda) → `exit 144` y el
proceso real sigue vivo. Matar por **PID exacto** (guardado al lanzar) o por un
needle fragmentado que no aparezca en la línea de comando del pgrep.

## Sellos al bus (vocabulario cerrado)

| Sello | Cuándo | Contenido mínimo |
|---|---|---|
| `SENTRY-URGENTE-<X>` | S0/S1 money o auth (ver `02-…`) | shortId + fuente + por qué es urgente + a quién se escaló |
| `SENTRY-CONSULTA-<X>` | S3 que no se puede sellar ni tiene default seguro | qué falta decidir + quién decide + gatillo |
| `SENTRY-VERIFICA-<TAL>-{OK\|CONSULTA}` | cese post-deploy (ver `04-…` E/D/5A) | sha del release + cifra exacta de eventos nuevos en la ventana |
| `SENTRY-HEARTBEAT` | cada 4 h | estado (WATCH activos, issues en vuelo) |
| `VIGIA-RESUELTA-<shortId>-<sha7>` | resolución por `resolver_ficha.py --apply` con tres pruebas | pr + merge + release + eventos_nuevos=0 + ventana; sha7 del commit de fusión en main |

**El token JAMÁS aparece en un sello, ni un fragmento** (límite duro, B9).

## Arranque / relevo

- Torre del HOST (C3): relanzar SOLO con `--resume <uuid>` de
  `~/.config/talent-channels/env/c3.session` (pozo por cuenta, ley 1-sep).
- Tras un compact: `talent-context` (compact-60/relevo) + releer este fichero
  y `03-buckets-y-baselines.md` (el estado vivo de los sets) antes de reanudar
  el ciclo.
- Paso 0 SIEMPRE: `bash scripts/sentry_doctor.sh`. Sin PUERTA ABIERTA no hay
  guardia fiable.
