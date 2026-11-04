# 10 — Cuentas y pozos

Doctrina de gestión de **cuentas** (de Claude/Codex) y **pozos** que consume el Orquestador para
alimentar la flota. El Orquestador NO opera credenciales carril por carril (eso es de
`talent-channels`); **decide qué cuenta alimenta qué fábrica y cuándo**, y mantiene el mapa
consumidor→cuenta libre de violaciones.

## Table of Contents

- [1. Fuente de verdad: el ledger](#1-fuente-de-verdad-el-ledger)
- [2. Qué es un pozo](#2-qué-es-un-pozo)
- [3. Cosecha = MOVE (un-login = un-lugar)](#3-cosecha--move-un-login--un-lugar)
- [4. Política de selección y rotación de grupos](#4-política-de-selección-y-rotación-de-grupos)
- [5. Los 4 muros (puntero)](#5-los-4-muros-puntero)
- [6. Coordinador único](#6-coordinador-único)
- [7. Tokens de larga duración y rotación por reset semanal (doctrina VIGENTE desde 2026-09-01)](#7-tokens-de-larga-duración-y-rotación-por-reset-semanal-doctrina-vigente-desde-2026-09-01)

```text
Modelo cuentas ↔ pozos (ledger/cuentas.json — única fuente de verdad)

  cuentas[]  ──alias──►  pozos{p1,p2,…}  (habilitada_fabrica: true/false)
     │                        │
     │ grants_vivos           │ cosecha = MOVE (un-login = un-lugar; NUNCA copia)
     │ rest_5h/rest_7d        ▼
     └──────────────►  contenedor con login pre-cargado (capacidad lista)
                              │
                    verificación funcional (request real) ANTES de extraer
```

## 1. Fuente de verdad: el ledger

El estado de cuentas y pozos vive en **`ledger/cuentas.json`** del repo motor (`talent-factory`) —
única fuente de verdad. Estructura:

- **`pozos`** — objeto; la **clave es el id del pozo** (`p1`, `p2`, …). Cada pozo: `estado`,
  `cuenta` (alias que referencia una entrada de `cuentas`), `nota`, `habilitada_fabrica` (bool).
- **`cuentas`** — array; cada una: `alias`, `estado`, `grants_vivos` (dónde está viva ahora mismo),
  restos y resets (`rest_5h`/`reset_5h_utc`, `rest_7d`/`reset_7d_utc`, `rest_fable`).
- Campos de política a nivel raíz: `politica_seleccion`, `nota_reserva`, `plan_sabado`,
  `coordinator_host`.

> **PROHIBIDO enumerar los pozos.** El conjunto de pozos se **DERIVA SIEMPRE de las claves de
> `pozos` en runtime** (orden natural por clave). Nunca hardcodear `p1-p5`/`p1-p6` en doc, script o
> decisión: el inventario crece (un pozo nuevo aparece en el ledger y todo lo demás lo recoge solo);
> una lista fija queda obsoleta en cuanto entra `pN+1`. Al editar el ledger se **preservan** todas
> las claves y campos desconocidos (nunca reescribirlo perdiendo prosa curada por el lead).

## 2. Qué es un pozo

Un **pozo** es un contenedor con el **login pre-cargado** de una cuenta: una reserva de capacidad
lista para cosechar. `habilitada_fabrica: false` marca una cuenta **VETADA** para consumidores de
fábrica (p. ej. cuentas que el lead declara 🔒 INTOCABLE / reserva de un grupo). El Orquestador
solo reparte cuentas con `habilitada_fabrica: true` del grupo activo.

## 3. Cosecha = MOVE (un-login = un-lugar)

Extraer un login de un pozo es una **operación MOVE transaccional**, no una copia: la credencial
vive en **UN solo lugar a la vez**. El protocolo técnico completo (freeze durable, journal de
crash-recovery, commit por `mv` atómico, reconciliación por inspección) es de `talent-channels`
— ver `references/05-credenciales-por-carril.md` y `scripts/auth-move.sh`; aquí NO se duplica.

Lo que el Orquestador debe respetar:

- **Codex JAMÁS se clona/fan-out**: su refresh token es de un solo uso; copiarlo a N destinos
  re-arma la cascada de deslogueos. Se **mueve** con `auth-move.sh move <cuenta> <from> <to>`.
- **Verificación funcional dentro del pozo** antes de extraer (request real one-shot, no `md5`): un
  pozo con token muerto no es capacidad.
- **Estado del pozo = lectura DIRECTA de la cred, NUNCA `/usage` vía TUI** (frágil: pozos vivos
  salen "sin lectura"; etiquetas hardcodeadas mienten tras un re-login) — mecánica y veredicto
  LOCAL (presente/blanca/expirada) en `talent-channels` ref 05 §Lectura directa; el email de
  `oauthAccount` es la identidad del último login, no la etiqueta. "Viva server-side" solo lo
  prueba la verificación funcional de arriba (request real).
- Tras cosechar, el pozo queda **consumido/recargable** en el ledger (lo refleja el propio MOVE al
  registrar la propiedad en el commit).

## 4. Política de selección y rotación de grupos

Encuadre de toda esta sección: **gestión eficiente de recursos** — acelerar la producción con
calidad y **SIN DESPERDICIO** de capacidad ya disponible; nunca un ejercicio de apurar límites.

- **`politica_seleccion` del ledger**: usar primero la cuenta de **reset 7d MÁS CERCANO** (su
  capacidad restante caduca antes — no usarla sería desperdiciarla); **no recolocar** flotas ya
  desplegadas; pozo consumido → recargar.
- **LEY de rotación alternada de grupos** (lead 2026-07-09): NADIE usa cuentas fuera del **grupo
  activo**; al reset del grupo, **rotar TODO** al otro grupo y dejar descansar el primero. El
  Orquestador **audita el mapa consumidor→cuenta tras cada reparto** — las **torres** son el punto
  ciego típico (status lines rancias muestran ventanas pre-rotación; confirmar con una request autenticada con identificador de cuenta — taxonomía T3, `talent-channels` ref 07).
- **Puente de credenciales host→canales (T4)**: recurso de EMERGENCIA (pozo muerto a mitad de un
  lanzamiento) — préstamo reversible de la cred viva del host en modo conservador (runway
  compartido); doctrina completa en `talent-channels` ref 05 §Puente. El Orquestador lo autoriza
  y planifica la reversión al reset.
- **Reportar la ventana de expiry al acreditar**: una cred de grant corto (~7 h) se reparte con
  su expiry declarado — el Orquestador planifica el trabajo dentro de esa ventana, no descubre el
  vencimiento por el muro 1.

## 5. Los 4 muros (puntero)

| Marcador | Muro | Recovery (resumen) |
|---|---|---|
| `Not logged in` / `refresh token revoked` | auth caída | propagar credencial (Codex: MOVE); sesión YA atascada → RESTART (T1) |
| `usage limit · resets <hora>` | cap 5h | esperar + "continuemos" |
| `weekly limit · resets <día>` | cap semanal | PARK (trabajo local a salvo) o escalar por pozo |
| `429` / `temporarily limiting` | sobrecarga transitoria | RESTART + re-despacho **escalonado 2-en-2** (T8) |

Doctrina canónica de los 4 muros: `talent-channels/references/05` §Muros de cuenta; detalle
operativo del coordinador (incl. despacho escalonado §7c) en
`talent-channel-operation/references/11-modelo-effort-y-recycle.md` §7b/§7c. El **único** muro
que justifica abrir un pozo es el **semanal**.

### Lecturas de estado en vivo (corrida F1, 2026-07-14)

- **Forced-refresh = la lectura de verdad**: el ERR de una cred on-disk NO es el estado real de la
  cuenta. Un refresh mínimo del token distingue **vivo** (refresh OK → leer `/oauth/usage`),
  **capado** y **revocado** (`invalid_grant` = BLANCA, solo revive con login fresco del lead).
  El endpoint de refresh se rate-limitea por ráfagas (IP-wide): espaciar los canaries, jamás
  refrescar N pozos en loop apretado.
- **5h=0% + 7d=100% = capado semanal**: la sesión responde (sirve ráfagas cortas) pero NO sostiene
  trabajo de flota. No confundir "responde" con "usable" — un pozo así NO se propaga.
- **Contenedores-pozo pueden estar CRUZADOS**: la identidad real del token es
  `/api/oauth/profile` (email del dueño), no la etiqueta del contenedor ni el `oauthAccount` del
  `.claude.json` (ambos pueden ser stale). Visto en vivo: el contenedor "p5" contenía la cuenta
  de p6. Verificar identidad ANTES de razonar sobre cuotas por etiqueta.
- **Escalera de resets**: documentar por pozo la hora de reset 5h/7d (la da `/oauth/usage` en
  `resets_at`) — al muro semanal, la decisión "esperar vs abrir pozo" se toma con la escalera
  delante, no a ciegas.

## 6. Coordinador único

Las operaciones MOVE/cosecha se ejecutan **solo desde la estación coordinadora**: el host declarado
en `coordinator_host` del ledger, con el ledger escribible en su path canónico local (guard
fail-closed en `auth-move.sh`). Una **segunda estación** exigiría una lease compartida por cuenta —
**no soportado hoy**; es un límite explícito, no un descuido. Mientras haya un solo coordinador, la
propiedad del ledger (actualizada en el commit del MOVE) es autoridad suficiente.

## 7. Tokens de larga duración y rotación por reset semanal (doctrina VIGENTE desde 2026-09-01)

**Supersede** para Claude la mecánica de «un login = un lugar» de §3 (que sigue siendo obligatoria
para Codex) y la rotación por grupos de §4. Ruling del lead el 1-sep-2026 tras cuatro caídas en
cascada de canales en un solo día: «pon el token de cada pozo en muchas cuentas y no volvamos a
tener este problema» + «NUNCA un canal sin cuenta válida y activa» + «se gasta primero la cuenta
que antes renueva: tokens no gastados son tokens perdidos».

### 7.1 Por qué

- Un login OAuth normal lleva un **refresh token rotativo**: copiarlo a N consumidores hace que el
  primero que refresca invalide al resto (cascada de `Login expired` / `Not logged in`).
- Un **token de larga duración** (`claude setup-token`, válido 1 año, formato `sk-ant-oat…`) **no
  rota**: N consumidores pueden compartir la misma cuenta sin carrera. El único límite pasa a ser
  la **cuota** de la cuenta (ventanas 5 h y 7 d), y esa se gestiona por rotación.

### 7.2 Inventario (todo FUERA del repo, en `$SECRET_DIR` = `~/.config/talent-channels`, 0600)

| Fichero | Contenido |
|---|---|
| `tokens/pN.token` | token largo de la cuenta del pozo `pN` (uno por pozo; el valor JAMÁS se imprime ni se sella) |
| `pozos-lectores.map` | dónde vive una **línea OAuth logueada** de cada cuenta (lector de cuota): `pN <contenedor>` o `pN <host-ip> <contenedor>`; por defecto el propio contenedor `pN` |
| `ceo-cuenta` | pozo cuya cuenta usa la terminal del CEO (Opus vigente), p. ej. `p4` — para la FABLE-ALERTA |
| `consumidores.map` | consumidores a rotar: `canal NN [A\|B]` · `torre <sesión-tmux> [B]` · `remoto <sesión> <host-ip> <contenedor> [B]` |
| `env/<sesión>.env` | (solo torres del host) `export CLAUDE_CODE_OAUTH_TOKEN=…` 0600 que la torre `source`a |
| `state/` | dir PRIVADO `0700` del rotador: `rotador.{state,state.pendiente,failed,pid,lock,log}` y `usage.cache` (última lectura de cuotas, la que consume la statusline). Reubicable con `$POZOS_STATE_DIR`; **nunca `/tmp`** |
| ledger `cuentas.json` | estado por pozo (`TOKEN-LARGO`, `TOKEN-LARGO-EN-USO-FLOTA`, …) y prosa del lead — los pozos se DERIVAN de sus claves |

Los **tokens largos NO pueden leer `/api/oauth/usage`** (la API responde `rate_limit_error`):
para leer cuota hace falta una línea OAuth normal logueada por el lead en el pozo (el «lector»),
que **no se mueve** nunca — se queda en el pozo solo para leer.

### 7.3 Cómo se obtiene un token (una vez por cuenta, requiere al lead)

```bash
# en el pozo, dentro de tmux (setup-token necesita TTY):
incus exec pN -- su - vivecoder -c 'tmux new-session -d -s st; tmux send-keys -t st "claude setup-token" Enter'
# capturar la URL del pane (grep https://claude.com/cai/oauth/authorize…), dársela al lead → autoriza con ESA cuenta
# y devuelve el código (por portapapeles, nunca en texto); pegarlo con send-keys; el token aparece en el pane:
# el fichero destino se crea 0600 ANTES de volcar el secreto (sin ventana de exposición); luego se captura el token:
install -m 600 /dev/null $SECRET_DIR/tokens/pN.token
incus exec pN -- su - vivecoder -c 'tmux capture-pane -p -t st -J -S -60 | tr -d "\n" | grep -oE "sk-ant-oat[A-Za-z0-9_-]+" | tail -1' > $SECRET_DIR/tokens/pN.token
# Tras cargar lib-modelos.sh, comprobar el ID antes de cargar la credencial:
model="$(tco_modelo_read salud)" && [ -n "$model" ] || exit 1
# La sesión acreditada del usuario aporta la credencial sin imprimirla.
claude -p 'Responde solo: OK' --model "$model"
```

### 7.4 Cómo se instala en un consumidor (scripts de este skill, `scripts/pozos-*.sh`)

- Canal local: `pozos-install-token.sh <NN> <token-file> [modelo]` — escribe `~/.claude_token.env`
  (`export CLAUDE_CODE_OAUTH_TOKEN=…`), lo carga desde `.bashrc`/`.profile`, **mata el CLI y lo
  relanza con `--continue` EN EL CWD DEL PROCESO** (`readlink /proc/PID/cwd`) y sondea. Relanzar
  desde otro cwd arranca una sesión nueva con contexto 0 (incidente ch01, 1-sep) — nunca hacerlo.
- Torre del host: `pozos-install-token-torre.sh <sesión-tmux> <token-file>` (modelo por defecto
  `Sonnet vigente`, coordinación) — escribe `$SECRET_DIR/env/<sesión>.env` (0600) y la torre lo
  `source`a; el token **nunca viaja por `tmux send-keys`** (quedaría en el scrollback y en `ps`).
  En el host el cwd es **compartido con el CEO**: se relanza con `--resume <uuid>` (uuid del
  `cmdline`, de los `fd` del proceso o el cacheado en `env/<sesión>.session`), nunca con
  `--continue`; sin uuid válido sale `rc=7` sin tocar la terminal.
- **Guard de suite/gate en vuelo** (los tres instaladores): si el CLI tiene hijos corriendo (suite,
  `db-guards`, build), NO se mata — `rc=6`, el token queda escrito y el rotador reintenta el
  relanzamiento en el ciclo siguiente. `POZOS_FORCE=1` lo fuerza (solo a mano, con criterio).
- Estación remota: `pozos-install-token-remote.sh <host-ip> <contenedor> <sesión> <token-file>`.
- Ninguno imprime el token ni lo pasa por argv/tmux: el secreto va **siempre por stdin** a un
  fichero creado 0600 ANTES de volcarlo; el consumidor recibe solo el `source`. Los tres
  instaladores salen con `rc≠0` si falla la escritura, el relanzamiento (ssh/incus/tmux) o la
  sonda, para que el rotador lo registre como `APPLY-FALLO`. Los coordinadores **no tocan**
  `~/.claude_token.env`; lo administra el Orquestador/CEO.
- **Allowlist antes de cualquier orden remota** (defensa en profundidad, M5-BOUNCE 2026-09-02):
  `host` (IPv4 o hostname `[A-Za-z0-9.-]`, nunca empezando por `-`), `contenedor` y `sesión tmux`
  (`[A-Za-z0-9._-]+`), `modelo` (`claude-[a-z0-9-]+`) y `pozo` (`p[0-9]+`) se validan con
  `pozos_require` **antes** de construir nada para `ssh`/`incus`/`su`/`tmux`; un valor fuera de
  formato corta con `FORMATO-INVALIDO` y `rc=2` sin ejecutar nada. Todo lo que se interpola en una
  orden remota va con `printf %q` (el shell del host **re-parsea** el argumento de `ssh` y `su -c`
  lo parsea otra vez: dos niveles), y el `CWD` recuperado del proceso vivo se re-inserta escapado y
  solo si es un **directorio existente**. El `claude` que se mata debe ser **hijo directo del pane 0**
  (`pgrep -P <pane_pid>`), nunca un `claude` cualquiera del contenedor. Los valores salen de ficheros
  del operador (`pozos-lectores.map`, `consumidores.map`) y de argv: un typo o una entrada
  comprometida no puede convertirse en orden extra ejecutada como root en toda la flota.
- `scripts/pozos-selftest.sh` — prueba de humo SIN red (fixtures inline en un tmp): parseo del
  mapa de consumidores (grupo = último campo `A|B`), lectura de uso con `scope.model` dict/string
  y JSON roto, escritura 0600 del env, filtro `habilitada_fabrica`, **allowlist** (rechaza
  `c1; false #`, `h$(id)`, sesión con espacio, `gpt-5`…), **`printf %q`** de un CWD con comilla
  simple, **filtro de filas de cuota** inválidas (5h/7d o resets ilegibles), **estado 0700 + rechazo
  de symlink**, **instancia única** del rotador (flock ya tomado → `rc=3`) y `bash -n` de los scripts.
  Correrlo tras tocar cualquier `pozos-*.sh`.

### 7.5 Regla de rotación (del lead, literal) y el daemon

1. Se gasta **siempre la cuenta cuyo reset semanal está más cerca** (orden por `seven_day.resets_at`).
2. Al **tope de 5 h** de esa cuenta, los consumidores pasan a las **dos siguientes** por reset
   (grupo A → 2.ª, grupo B → 3.ª). Cuando la primaria recupera (5 h < 50 %), todo vuelve a ella.
3. Cuando una cuenta **cruza su reset semanal**, su `resets_at` pasa a +7 d y **sale sola del
   frente de la cola**: su semana fresca es colchón, no se toca. Entran las siguientes (sábado, etc.).
4. Si TODAS tocan techo a la vez, la capacidad se acabó de verdad: créditos extra o esperar al
   reset más cercano — decisión del lead, con la escalera de resets delante.

`pozos-rotador.sh` lo ejecuta solo (cada 5 min): lee la cuota real de cada cuenta **con token y
habilitada** (`habilitada_fabrica: false` en el ledger la excluye aunque tenga token; campo ausente
= habilitada), ordena por reset semanal, y aplica los cambios con los instaladores de §7.4.
Antes de rotar valida que exista alternativa (`SIN-ALTERNATIVA` si la primaria está capada y no hay
otro pozo con token: decisión del lead) y que el token destino sea legible; si solo hay una
alternativa, A y B van a la misma. Al **orden solo entran las cuentas con 5 h y 7 d legibles
(≥ 0) y AMBOS resets válidos (> 0)**: una cuota ilegible no puede decidir a quién se gasta —
la fila se excluye y queda como `SIN-LECTURA <pozo>` en el log.

**Instancia única**: el rotador toma un `flock -n` exclusivo sobre `<estado>/rotador.lock` **antes
del bucle**; una segunda instancia sale con `rc=3` (`YA-CORRIENDO`) sin tocar el estado — dos
rotadores a la vez son una carrera sobre el estado y un doble relanzamiento de los consumidores.

**Estado en dir PRIVADO `0700`**, `${POZOS_STATE_DIR:-$SECRET_DIR/state}` — **nunca `/tmp`**
(world-readable y expuesto a symlink attack): `rotador.state` (se sella **solo cuando todos los
consumidores aplicaron**), `rotador.state.pendiente`, `rotador.failed`, `rotador.pid`,
`rotador.lock`, `rotador.log` y `usage.cache` (la caché de cuotas que lee la statusline). Todos se
crean `0600` con `O_EXCL` y se rechazan si la ruta es un enlace simbólico. El estado viejo de
`/tmp/pozos-rotador.*` y `/tmp/pozos-usage.cache` se **migra una sola vez** al arrancar.
Si alguno falla (ssh/incus/tmux/sonda) queda `APPLY-FALLO <tipo:nombre>` en el log, la lista en
`<estado>/rotador.failed` y el ciclo siguiente reintenta SOLO esos (`ROTACION-PARCIAL` →
`REINTENTO` → `ROTADO`). Log en `<estado>/rotador.log` (armar un
Monitor sobre `ROTANDO|ROTADO|VOLVIENDO|ROTACION-PARCIAL|APPLY-FALLO|SIN-ALTERNATIVA|SIN-LECTURA|FABLE-ALERTA`). `pozos-cuotas.sh` imprime la **«tabla de pozos»** (CDMX) para el lead: uso 5 h, 7 d y **cubo semanal Fable** por cuenta, ordenada por reset semanal. Cuando el lead pide «tabla de pozos», se ejecuta tal cual y se pega su salida (alias de host `tabla-de-pozos`).

**Fable** (nombre del cubo de cuota heredado, no modelo asignado a un rol): la API expone un límite semanal con `scope.model = "Fable"` en `limits[]` (`kind: weekly_scoped`). El rotador lo lee y emite `FABLE-ALERTA` cuando la cuenta del CEO (`$SECRET_DIR/ceo-cuenta`) supera el 90 %: la terminal del CEO se relanza a mano con el token de la siguiente cuenta por reset (es la sesión del lead; no se automatiza).

### 7.6 Paso-0 tras compact o cambio de cuenta (lo que debe sobrevivir)

1. `ls $SECRET_DIR/tokens/` — un token por pozo del ledger; si falta alguno, §7.3 con el lead.
2. `pgrep -f pozos-rotador.sh` — si no corre, relanzarlo (`nohup … &`; pid, lock, estado y log en
   `${POZOS_STATE_DIR:-$SECRET_DIR/state}/rotador.*`) y re-armar el Monitor del log. Leer
   `<estado>/rotador.state` para saber en qué cuenta va la flota. Si sale `YA-CORRIENDO` (rc=3),
   ya hay una instancia viva: **no** relanzar (el `flock` es la garantía de instancia única).
3. `bash scripts/pozos-cuotas.sh` — tabla real; comprobar que la primaria coincide con el estado.
4. Sonda real de un consumidor por grupo: cargar `lib-modelos.sh` del paquete y obtener
   `model="$(tco_modelo_read salud)" && [ -n "$model" ] || exit 1` antes de cargar el token;
   después ejecutar `. ~/.claude_token.env; claude -p 'OK' --model "$model"` dentro del
   contenedor — la pantalla del pane puede mostrar «session limit» de ANTES del token.
5. Los lectores (líneas OAuth en los pozos) caducan por no-uso: si `pozos-cuotas.sh` da `SIN
   LECTURA`, pedir al lead un `claude login` en ese pozo (o `/login` en su TUI).

### 7.7 Lo que NO cambia

- Codex: sigue siendo MOVE un-login-un-lugar (§3). Runners sellados: CERO credenciales.
- Los tokens largos nunca se committean, sellan al bus ni pegan en Linear; solo su longitud o el
  email de la cuenta.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; CEO y plan/fallback usan Opus vigente, los demás roles y salud Sonnet vigente. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
