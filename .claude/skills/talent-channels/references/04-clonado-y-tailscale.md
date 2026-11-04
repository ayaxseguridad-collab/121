# 04 — Clonado y Tailscale

## Table of Contents

- [Clonado (`scripts/03-clone.sh`)](#clonado-scripts03-clonesh)
- [Fix tailscaled (`scripts/03b-fix-tailscale.sh [target]`)](#fix-tailscaled-scripts03b-fix-tailscalesh-target)
- [Verificación de ruta de red (al provisionar)](#verificación-de-ruta-de-red-al-provisionar)
- [Acceso](#acceso)

## Clonado (`scripts/03-clone.sh`)

Detiene golden (copia CoW limpia) y, por cada `y` en `1..COUNT`:

1. `incus copy golden $(tc_channel_name y)` (CoW) + start.
2. **Identidad única**: `hostname`, `/etc/hosts`, regenera `machine-id` + `ssh_host_*` + borra `tailscaled.state`. Reinicio.
3. **Puerto Tailscale fijo y único**: `PORT=$((41640+y))` en `/etc/default/tailscaled` (userspace). Sin esto, si todos comparten 41641 colisionan en la NAT y unos quedan inalcanzables.
4. `tailscale up --ssh --authkey=<TS_AUTHKEY> --hostname=<canal> --accept-dns=false` (authkey desde `$SECRET_DIR/tailscale-authkey`, validado `tskey-`, nunca impreso).

Idempotente: salta canales **ya provisionados** (arrancan y tienen IP en el tailnet); si un canal existe pero quedó a medias (fallo tras el copy, sin join), aborta con instrucción de borrarlo y relanzar — existir no basta para saltar.

**Modo `--local-only` (`TC_LOCAL_ONLY=yes`, TAL-2296)**: canales SIN Tailscale — `03-clone` no pide
`tailscale-authkey`, se salta los pasos 3-4 (puerto + `tailscale up`) y el criterio de "ya
provisionado" pasa a ser "arranca" (no "tiene IP en el tailnet"). El acceso es **local** (`incus
exec` / launchers `v` con fallback local, gotcha 13). `provision.sh --local-only` además salta la
fase `golden-ts` (fix de tailscaled del host, innecesario sin tailnet). **Multi-fábrica**: si dos
fábricas conviven en un host y ambas usan tailnet, dales `TS_PORT_BASE` distinto para que los puertos
`base+y` no colisionen (ver `01` §Multi-fábrica).

## Fix tailscaled (`scripts/03b-fix-tailscale.sh [target]`)

- En **unprivileged** no hay TUN → userspace; y el `--cleanup` del unit falla → override `ExecStartPre=-` (asset `tailscaled-override.conf`).
- `target` = un canal → aplica + `tailscale up`. `target` = golden → aplica, detiene tailscaled y para el contenedor (**el golden no se une al tailnet**).
- En `provision.sh` se corre sobre golden tras construirlo (fase `golden-ts`).

## Verificación de ruta de red (al provisionar)

Un `tailscale up` verde NO garantiza una ruta de red apta para producción — un host puede quedar
**relay-only** (todo el tráfico por DERP) con el uplink degradado. ANTES de cargar flota sobre una
máquina recién unida al tailnet, verificar la ruta:

1. **Ruta default por ethernet cableado con lease real**: `ip route get 8.8.8.8` DEBE salir por la
   NIC cableada con una IP de lease real — **nunca** link-local (`169.254.x`) ni `wlan`. Root cause
   real de v05/v10: el DHCP no respondía en la ethernet (link físico UP a 1000 Mb/s pero sin lease
   → `169.254.x`), así que el host ruteaba por **Wi-Fi**, que colapsaba bajo el tráfico de la flota
   → jitter/pérdida → caída del tailnet → espiral D-state. Fix: **IP estática en ethernet con
   métrica preferente** (Wi-Fi solo de respaldo). Un host que rutea por Wi-Fi **no es apto para
   flota**.
2. **Direct-path en el tailnet** (no relay): `tailscale status` no debe mostrar `relay` en los
   peers que van a hablar con este host; una conexión **direct** es el estado apto.
3. **Ping al gateway** de la NAT/uplink (round-trip sano, sin pérdida).
4. **Egress sostenido**: una transferencia real de varios MB que se **mantenga** — no un solo
   paquete que pasa.

Un host **relay-only con `rx=0` NO es apto para producción**: es exactamente la firma del host
degradado (loadavg alto con ~1 runnable, procesos en D-state esperando red — ver
`06-operacion-y-launchers.md` §"Host degradado — diagnóstico y recuperación 4+4"). Enlaza con los
gotchas de red 1-3 de `07-verificacion-y-gotchas.md` (FORWARD DROP · tailscaled userspace · puerto
por canal / `rx 0`) y con el gotcha del NIC Realtek r8169 (ASPM) de `07-verificacion-y-gotchas.md`
§Gotchas — mismo síntoma-firma (ping OK, TCP/tailscale degradan), causa distinta (chip onboard, no
DHCP/ruta).

## Acceso

- **Remoto** (otros dispositivos del tailnet): `ssh vivecoder@vibe-channel-<XY>` — requiere **regla `ssh` en la ACL** del tailnet (Tailscale SSH). Ver 07.
- **Local** (desde el host que hospeda): `sudo incus exec vibe-channel-<XY> -- su - vivecoder`. Es el fallback **local-only** (no sustituye el acceso remoto).
