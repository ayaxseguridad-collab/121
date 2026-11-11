# 07 — Verificación y gotchas

## Table of Contents

- [Verificación (`scripts/verify.sh`, read-only)](#verificación-scriptsverifysh-read-only)
  - [Validar el manifiesto del motor (`scripts/validate-manifest.sh`, standalone)](#validar-el-manifiesto-del-motor-scriptsvalidate-manifestsh-standalone)
  - [Verificar por CONDUCTA — taxonomía honesta de señales (T3)](#verificar-por-conducta--taxonomía-honesta-de-señales-t3)
- [Gotchas (resumen accionable)](#gotchas-resumen-accionable)
- [Reparación puntual](#reparación-puntual)

## Verificación (`scripts/verify.sh`, read-only)

PASS/FAIL por ítem: incus + pool btrfs + bridge + `incus-forward`/`incus-startup` · golden STOPPED · cada canal RUNNING + hostname único + TCP saliente + toolchain (node/claude/codex) + **`~/.codex` y `~/.claude` existen y son del usuario** + **[TAL-2296] config baseline horneada** (codex `config.toml` con `check_for_update_on_startup=false` + `trust_level="trusted"`; claude `hasCompletedOnboarding == true` + `settings.json` `model` igual al identificador completo de Sonnet vigente del registro (ID completo del tier de coding, regla 0) **y** ausencia de credencial de agente `~/.claude/.credentials.json` **y** `~/.codex/auth.json`; `DISABLE_AUTOUPDATER=1` en `.bashrc`) + puerto tailscale `41640+y` + repo + **motor `talent-factory` si `TF_REPO_DIR`** + `$ENV_DEST` (solo se exige si el carril tiene `<canal>.env` en el escrow; sin él es SKIP, no FAIL) + en el tailnet. **`TC_LOCAL_ONLY=yes`** convierte los ítems de tailnet (puerto + "en tailnet") en **SKIP**. **[TAL-2630] Identidad/perfil por canal (fail-closed):** además, sobre TODOS los contenedores reales de la fábrica (`incus list` acotado por `MACHINE_NUM`, incl. los de fuera de `1..COUNT` como 91-94), valida la credencial EFECTIVA contra el perfil DECLARADO (`channel-profiles.list`/overrides; **canal sin declarar = FALLO fail-closed**, no se asume producción): identidad md5 del env (siempre, both-ways) / de la sesión CR, ausencia de `sbp_`/CR efectiva **en todo el contenedor** para producción, y runner CERO-credencial container-wide (`/home/runner` incl.) — nunca por grep de texto del árbol; todo error de inspección → FALLO; reconciliación fail-closed (canal declarado sin contenedor, o `incus list`/`MACHINE_NUM`/filtro que no rinden → FALLO). `verify.sh` devuelve no-cero si algo falla. `status.sh` = foto rápida diaria.

### Validar el manifiesto del motor (`scripts/validate-manifest.sh`, standalone)

En multi-fábrica, cada fábrica consume el motor `talent-factory` con un **manifiesto** (`TF_PROJECT` +
`TF_REPO_URL` + claves consumidas). El validador **vive en este skill** (no dentro del motor) y se
corre contra la ruta del manifiesto: `validate-manifest.sh <manifiesto> [--project P] [--repo R]
[--require K1,K2,…]` — valida SIN ejecutarlo (nunca `source`/`eval`): formato `KEY=value` estricto
(líneas malformadas → rechazo), **claves duplicadas → rechazo**, requeridas presentes y no vacías
(`TF_PROJECT`/`TF_REPO_URL` siempre + `--require`), y **coincidencia** `TF_PROJECT`/`TF_REPO_URL` con
`--project`/`--repo` (comparando el valor **sin comillas** shell — los manifiestos reales citan los
valores). Rc 0 = válido; rc≠0 = inválido (token `ABORT:*`). Predicados puros `vm_*` cubiertos por
`tests/run-tests.sh` §13 (incl. smoke obligatorio contra `tests/fixtures/manifiesto-ejemplo.conf`).

**Aviso "motor detrás de origin"**: el motor sembrado en el golden puede ir por **detrás de su
origin** (se hornea en un momento; el motor evoluciona). Antes de correr gates del motor:
`git -C ~/$TF_REPO_DIR pull`. `TF_REPO_DIR` está **desambiguado** del repo de producto (`02-golden`
aborta si colisionan).

La verificación de credenciales **a propagar** (logins del host — **Claude** por **copia** con `refresh-claude-auth.sh` (ruta primaria) y **Codex** por **MOVE** con `auth-move.sh` (un-login-un-lugar); tokens gh/linear/convex — `GITHUB_TOKEN`/`LINEAR_API_KEY`/`CONVEX_DEPLOY_KEY`, los mismos que valida `tc_preflight_env_tokens`) se hace en el **host** durante el preflight de `provision.sh` (`tc_preflight_host_logins` antes de golden, `tc_preflight_env_tokens` antes de `env`), porque es la máquina creadora la que se los pasa a los carriles. Asimetría Claude(copia)/Codex(move): ver `references/05` §asimetría.

Prueba real adicional: `v<XY>` abre tmux con 2 paneles y Claude/Codex responden.

### Verificar por CONDUCTA — taxonomía honesta de señales (T3)

Cada señal prueba UNA cosa; usar la equivocada da falsa confianza. Doctrina canónica (los demás
skills de fábrica remiten aquí):

| Señal | Qué prueba | Qué NO prueba |
|---|---|---|
| `verify.sh` en verde | **Provisión** (toolchain, config baseline, red, AUSENCIA de credenciales horneadas) | Que haya credencial viva ni de qué cuenta |
| Fingerprint md5 de los `refresh-*-auth.sh` | **Integridad de propagación** host→canal (la copia es fiel al fichero fuente) | La **identidad de la cuenta**: una credencial equivocada o comprometida en el host se copia idéntica y pasa el md5 |
| md5 `68b329da` | Sentinel de **extracción vacía del token** — es el md5 de UNA LÍNEA VACÍA (`echo "$at" \| md5sum` con `$at` vacío), NO de un fichero vacío (`d41d8cd9…`); válido solo para ese procedimiento exacto (`05` §nota del sentinel) | Nada más |
| Ping genérico / `--list` / health-check / grep de fraseo en scrollback | Que ALGO responde / que un texto apareció alguna vez | Ni cuenta correcta ni actividad actual (el scrollback viejo false-positivea) |
| `git rev-parse HEAD` / `git ls-remote` / `esc-to-interrupt` visible | Estado del **repo** / **conectividad** / **actividad del proceso** | La identidad de la cuenta del proveedor |
| **Lectura DIRECTA de la cred en disco** (`.credentials.json`: `at_len`/`expiresAt`/`subscriptionType` + `.claude.json`: `oauthAccount.emailAddress`) — ver `05` §Lectura directa | Estado **LOCAL** de la cred (presente/no-expirada localmente/blanca/expirada) + la **identidad registrada en el último login local** (el email, no una etiqueta hardcodeada) — sin TUI y sin gastar `/usage` | Que la cred esté **viva server-side** (el servidor puede haberla revocado): eso solo lo prueba una request autenticada real |
| **Respuesta AUTENTICADA con identificador estable de cuenta/organización**, comparada con el esperado | **Identidad real de cuenta** confirmada por el servidor | — |

Si el proveedor no expone un identificador estable de cuenta desde el canal, declararlo
explícitamente: *"la identidad de cuenta no es verificable desde el canal; se confía en la
selección hecha en el host"* — nunca presentar una señal más débil como si lo fuera.

## Gotchas (resumen accionable)

1. **Sin internet en contenedores** → Docker FORWARD DROP. Correr `01b-network-fix.sh` (regla ACCEPT + servicio).
2. **tailscaled no arranca** → unprivileged: userspace + override `--cleanup` no-fatal (`03b-fix-tailscale.sh`).
3. **Canal inalcanzable / `rx 0`** → puerto Tailscale compartido. Cada canal `PORT=41640+y` (lo hace `03-clone.sh`). Si el host quedó con caché viejo: `sudo systemctl restart tailscaled` en el host.
4. **`ssh vivecoder@vibe-channel-XY` rechazado** → falta regla `ssh` en la ACL del tailnet. Snippet (consola admin → Access controls):

   ```json
   "ssh": [{ "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"] }]
   ```

   Mientras tanto: acceso **local** `sudo incus exec vibe-channel-XY -- su - vivecoder`.
5. **shift+tab no entra en plan mode** → falta `extended-keys` en tmux. Ya va en el golden; tras cambiarlo, reabrir la sesión (`v<XY>k` → `v<XY>`).
6. **Claude pide login** en un canal → **propagar del host** con `refresh-claude-auth.sh <canal>` (ruta primaria: copia la credencial del host, misma cuenta a N canales sin cascada). El `claude login` per-canal (device-flow) es el **fallback** cuando el host no está acreditado.
   **Codex sin auth / `codex login status` no logueado** → esperado: el golden NO hornea Codex (TAL-2294). Acredita el carril moviendo un login: `bash scripts/auth-move.sh move <cuenta> host:<host> channel:<canal>` (o `pool:<pozo>` como origen). NUNCA `refresh-codex-auth.sh all` (fan-out = cascada de rotación).
7. **gh sin auth** en un canal → `push-carril-env.sh <canal>` (hace `gh auth login --with-token`).
8. **`git clone` falla en golden** (repo privado) → falta/expiró `git-bootstrap-token` (re-intake). El token es efímero; `origin` nunca lo lleva.
9. **provision rechaza correr** → lo lanzaste como root directo. Usa `sudo bash provision.sh` (se necesita `SUDO_USER`).
10. **No formatea el disco** → guardas (particiones, montado, root/boot, tamaño). Revisa `disk-scan.sh`; para disco con particiones usa `TC_ALLOW_PARTITIONED=yes` + confirmación. Una **partición** (`/dev/sdXN`) vale como `POOL_DISK` (no hace falta disco entero) — ver `02-disco-y-pool.md`.
11. **Codex falla con `unable to open database file` (`~/.codex/state_5.sqlite`, code 14)** → el directorio `~/.codex` (o `~/.claude`) quedó propiedad de `root` porque se creó con `mkdir` como root sin chownear el dir. Ya corregido en `02-golden.sh` (chown del dir tras el mkdir). En goldens viejos: `incus exec <canal> -- chown -R vivecoder:vivecoder /home/vivecoder/.codex /home/vivecoder/.claude` (lo hacen también `refresh-codex-auth.sh`/`refresh-claude-auth.sh`).
12. **Preflight host avisa de logins/tokens faltantes** → es la verificación de lo que se va a propagar. Por defecto avisa, no bloquea. Para gate estricto: `TC_REQUIRE_HOST_LOGINS=yes` (logins del host a propagar: Claude por copia y Codex por MOVE) y/o `TC_REQUIRE_OP_TOKENS=yes` (tokens gh/linear/convex: `GITHUB_TOKEN`/`LINEAR_API_KEY`/`CONVEX_DEPLOY_KEY`).
13. **`hash -r` tras swap de binario en panes de larga vida** → un shell que ya resolvió `claude`/`codex` cachea la ruta; tras actualizar/mover el binario, ese pane sigue lanzando el VIEJO hasta `hash -r` (o abrir shell nuevo). Aplica a cualquier pane tmux longevo (canales, Torre).
14. **Claude crashea en CPUs Intel N95 (GC concurrente de bun)** → preflight POR CPU al aprovisionar: en máquinas con esa familia, `BUN_JSC_useConcurrentGC=0` en `/etc/environment` del contenedor (y del host si ahí corre Claude) antes de declarar el canal utilizable. Síntoma: crash del CLI sin stack útil, reproducible al poco de arrancar.
15. **Golden STALE pre-TAL-2294 que aún hornea `~/.codex/auth.json`** → en flotas desplegadas ANTES del fix (histórico: flota atlas), el golden viejo hornea la credencial y `03-clone.sh` la arrastra en cascada a cada clon. Los scripts en `origin/main` ya no lo hacen (el hard-check anti-credencial vive en `02-golden.sh`; el clone NO tiene check propio — el backstop por canal es el chk de ausencia de `verify.sh`). Si un clon nace con `auth.json`: **re-hornear el golden** de esa máquina con el `02-golden.sh` actual y verificar el clon siguiente.
16. **`claude --continue` colisiona por cwd compartido (T11)** → `--continue` resume "la última sesión de este directorio": con varias sesiones/actores sobre el MISMO cwd (Torre, host multi-actor) resume la sesión AJENA. Usar `--resume <uuid>` (sesión explícita) o sesión fresca + re-brief. Ya aplicado en los lanzadores `torre-*` (ref 06); doctrina del orquestador en `talent-orchestrator` ref 09.
17. **`protected_regular` en hosts con sysctl endurecido** → en sistemas con
    `fs.protected_regular=1` o superior (Ubuntu 24.04 con perfil de seguridad hardened),
    **root no puede abrir para escritura (O_CREAT / append) un fichero de `/tmp` cuyo
    dueño sea otro usuario** — la syscall devuelve `EACCES` aunque el fichero tenga
    permisos globales de escritura. Afecta al **buzón espejo del flock**
    (`/tmp/m<N>-flock-out.txt`; `08-runners-del-mergeador.md` §Buzón espejo del flock)
    cuando el proceso que escribe corre como root pero el fichero fue creado por
    otro usuario. Remedio: **escribir el fichero como su usuario dueño**, derivando el usuario
    del propietario real del fichero (`owner=$(stat -c %U <ruta>); sudo -u "$owner" tee -a
    <ruta>`) o del usuario efectivo del canal en su config — **nunca hardcodear un usuario
    concreto** (varía por instalación); o crear el fichero con el usuario correcto desde el
    inicio y no cambiar de actor.
18. **[TAL-3318] `kill` falla con EACCES dentro del contenedor (kernel ≥7.0) → gate `unit` rojo
    permanente** → en hosts nuevos (Ubuntu 26.04, kernel 7.0) AppArmor media las señales entre
    procesos del contenedor unprivileged y el perfil default de Incus las DENIEGA: `kill(2)` →
    EACCES, el teardown de vitest no puede matar sus workers y el gate `unit` falla SIEMPRE
    (parece flake del repo; es el host). Fix SCOPED — **nunca el perfil `default` global**: el
    default lo heredan TODOS los contenedores del host (fábrica o no) y ampliar ahí `raw.apparmor`
    tiene blast-radius innecesario. Canónico: perfil dedicado —
    `incus profile create <fabrica>-signal && incus profile set <fabrica>-signal
    raw.apparmor='signal,'` y añadirlo a cada canal de la fábrica
    (`incus profile add <canal> <fabrica>-signal`); alternativa per-canal:
    `incus config set <canal> raw.apparmor='signal,'`. Reiniciar los contenedores afectados. En un
    host mono-fábrica tocar el default «funciona», pero el canónico es scoped. **Smoke de
    aceptación post-montaje** (por canal; MANUAL — `verify.sh` aún no lo corre, automatizarlo es
    follow-up): `incus exec <canal> -- su - "$CUSER" -c 'sleep 30 & kill %1 && echo KILL-OK'` —
    sin `KILL-OK`, el canal NO se declara utilizable (validado en el arranque CRM 2026-07-22).
19. **[TAL-3318] El host "se actualiza solo" y tumba la flota** → un host recién instalado trae
    needrestart (reinicia servicios tras cada apt), unattended-upgrades y el updater gráfico
    activos: cualquiera puede reiniciar Incus/daemons — o pedir reboot — con la flota en caliente.
    Guardrails al montar el host: needrestart en modo LISTA con Incus fuera de su alcance
    (drop-in en `/etc/needrestart/conf.d/`: `$nrconf{restart} = 'l';` +
    `$nrconf{override_rc}{qr(^incus)} = 0;`), `APT::Periodic::Unattended-Upgrade "0";` y updater
    gráfico desactivado. Las actualizaciones del host pasan a ser EXPLÍCITAS, en ventana sin vuelo
    (misma doctrina que los binarios de agente, ref 06 §Mantenimiento).
    Parches de seguridad (norma del 22-oct-2026): en ventana programada o de noche sin suites, de
    UNA máquina en una y nunca en paralelo, con `ionice -c3 nice -n19`; en los hosts con runners,
    esperar a que el avg60 de presión de IO sea < 5 % antes de cada tanda, porque el apt comparte
    disco con los gates (un apt en paralelo dejó la cola de merge casi parada unos 40 min). Un log
    de espera sin líneas nuevas no es un cuelgue: mira la presión de IO del host antes de tocar
    prioridades. HOLD (`apt-mark hold`) de todo lo que reinicie el escritorio remoto del operador
    (libfreerdp*, libwinpr*, gdm, gnome-shell, gnome-remote-desktop): ese escritorio jamás se
    desactiva, filtra ni reinicia, y toda regla de cortafuegos se acota por puerto (nunca una
    política DROP por defecto en INPUT). Si un paquete pendiente lo reinicia, queda fuera y se
    avisa al CEO.

20. **Crash de Claude con kernel 7.0.0 × Bun 1.4.0 (segfault del GC, causa DISTINTA del gotcha 14)**
    → con la combinación causal EXACTA **kernel 7.0.0 × Bun 1.4.0** en contenedor unprivileged
    (firma `panic: Segmentation fault at address 0x0` / `embedder failed to suspend thread …
    Trace/breakpoint trap`), `BUN_JSC_useConcurrentGC=0` (el fix del gotcha 14, familia de CPU N95)
    **NO aplica aquí** — es una causa distinta, ligada al **kernel real de la máquina**, no a la
    familia de CPU. **Mitigación operativa (aprobada):** instalar el CLI con **Bun 1.3.x** (pin del
    runtime) como **ROOT** + **`DISABLE_AUTOUPDATER=1`** (ya baseline del golden). **Addendum
    (verificación obligatoria tras el pin):** confirmar SIEMPRE que la build pineada resultante
    **además ofrece el modelo que exige la Regla 0** — una build vieja puede tener la TUI viva pero
    solo ofrecer un modelo no válido (histórico: build 2.1.100 con TUI viva pero una versión anterior,
    no válido); si no lo ofrece, **binary search hacia builds más nuevas** hasta encontrar la
    última que tenga la TUI viva Y el modelo requerido. **Afecta SOLO a hosts con kernel 7.0.0
    real** — verificar `uname -r` antes de aplicar este fix; no confundir con el incidente de shim
    en PATH (gotcha 22 abajo), que es una causa de censo falso completamente distinta, no un crash
    del CLI. Documentar la versión del runtime pineada en el ledger del canal. Síntoma: crash del
    CLI sin stack útil, reproducible al poco de arrancar.
21. **NIC Realtek r8169 se ahoga bajo carga (bug ASPM) — parece "host caído" y NO lo está** →
    síntoma: **ICMP pasa** (`ping` <1 ms) pero **TCP muere** (ssh banner-exchange timeout) y
    **tailscale degrada a `relay`**. Diagnóstico exprés: `ping OK + ssh timeout + tailscale relay`
    = ESTE gotcha, **no** reiniciar a ciegas. Es el NIC onboard ahogándose bajo el tráfico de la
    flota, no la máquina. Escalera de fixes: (1) **IP estática en ethernet + Wi-Fi OFF** (elimina
    la ruta de escape inestable; ver `04-clonado-y-tailscale.md` §"Verificación de ruta de red");
    (2) **desactivar ASPM del r8169** (runtime + persistente entre boots); (3) **dongle
    USB-ethernet** como fix definitivo si el chip es defectuoso de fábrica. Relacionado con la
    espiral D-state del host degradado (ref 06).
22. **Un shim con nombre de herramienta del sistema en PATH compartido puede simular censos falsos
    de infra** (contenedores "muertos"/flotas fantasma que no lo están) → verificar con **rutas
    absolutas** (`/usr/bin/incus`) o `command -v` antes de creer un censo. La doctrina completa de
    higiene HOST-GUARD (anti-shim + anti-host-equivocado) se aplica también en `talent-channel-operation`; aquí es
    solo el recordatorio de no fiarse ciegamente de un binario resuelto por PATH.
23. **[issue 9562] Puertos de Supabase local abiertos a la LAN y a la tailnet → cortafuegos opcional**
    (`scripts/cortafuegos-supabase.sh`, desactivado por defecto) → el rango publicado (por defecto
    54421-54424) escucha en todas las interfaces. Con Tailscale, `ts-forward` acepta lo que entra por
    `tailscale0` antes de DOCKER-USER, así que la regla clave va en raw/PREROUTING (se evalúa antes del
    DNAT). **Cuándo usarlo**: hosts con Tailscale o en una LAN no confiable que corren la pila de los
    gates, y SOLO tras `--dry-run`. **Cuándo NO**: hosts con RDP (el script se niega a aplicar, y a
    medir mal también: sin `ss`, `systemctl` o `hostname` no aplica), hosts de la lista de excluidos y
    hosts donde los canales de Incus apunten a la IP del puente del host en esos puertos (también los
    corta). **Antes de activar**: leer las redes de los puentes de docker (`docker network ls`,
    `docker network inspect <red>`, `default-address-pools` de `/etc/docker/daemon.json`) y declarar UN
    CIDR que las cubra en `CORTAFUEGOS_REDES_DOCKER` (obligatoria, sin valor por defecto: sin ella
    `apply` se niega y el dry-run imprime `<REDES_DOCKER>`). **Configuración**:
    `/etc/talent-channels/cortafuegos.conf` (`KEY=valor`, sin permisos de escritura de grupo/otros, de
    root si corre root); puertos y CIDR en decimal SIN ceros a la izquierda (iptables lee `06475` en octal
    y sería el puerto de RDP: se rechaza). **Persistir** (opcional, a mano): instalar el script con
    `install -m 0755 -o root -g root cortafuegos-supabase.sh /usr/local/sbin/`, la unit
    `assets/cortafuegos-supabase.service` en `/etc/systemd/system/`, y `systemctl enable --now`. La unit
    lleva `After=` de `gnome-remote-desktop` y `xrdp` (solo ordenación, sin dependencia) para que, al
    arrancar el host, la negativa por RDP vea esos servicios ya activos. **Límite de la detección**: la
    señal autoritativa es el oyente en el puerto de RDP (`ss`); `systemctl --user` de GNOME solo se
    consulta como complemento y, si falla (sin bus de sesión, desde root o la unit), se ignora, así que
    un RDP de usuario activo pero que aún no escucha no se ve. **Revertir**:
    `systemctl disable --now cortafuegos-supabase.service` y `cortafuegos-supabase.sh remove`; `remove`
    DESCUBRE con `-S` las reglas con la marca `tc-supabase-fw` y la forma de este script (no las
    reconstruye desde la configuración, que ni lee), las quita aunque el CIDR o los puertos hayan cambiado,
    nunca bloquea por RDP, lista y deja una línea con la marca y otra forma y sale con rc 1 si queda
    algo; con `status` se comprueba que no queda ninguna. `apply` exige root (rc 4 si no), crea DOCKER-USER
    con `-N` si no existe, y `remove` no la borra (solo quita las reglas con la marca). **Cambiar el CIDR o los puertos**: `remove` y
    luego `apply` (`apply` añade, no sustituye: la regla vieja de raw seguiría cortando). Pruebas: `tests/cortafuegos-supabase.sh` (dobles de `iptables`,
    `ip6tables`, `ss`, `systemctl`, `hostname`, `id` y `stat`; sin root ni cortafuegos real).

## Reparación puntual

Cada fase es invocable suelta: `sudo bash scripts/<fase>.sh`. O `provision.sh --only <fase>` / `--from <fase>`.

Registro de modelos: `~/.config/talent-channel-operation/modelos.conf` del usuario del rol; los roles se resuelven por proveedor con `tco_modelo_read` (tabla en `talent-channel-operation`, ref 11): CEO, PM, plan, re-plan y código sensible usan Opus vigente; código y coordinación, Sonnet vigente; el auditor es de otro proveedor. Resolver tras acreditar Claude con `talent-channel-operation/scripts/resolver-modelos.sh`.
