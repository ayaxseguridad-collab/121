# Seguridad del despliegue talent-buzz

## Lo que NUNCA se comparte ni se versiona

- `keys.json` (todas las identidades: hex + nsec). Unica copia; respaldala
  cifrada si quieres, pero jamas en un repo ni en un chat.
- Los `.env` de agentes y del compose (claves privadas, API keys, passwords).
- El runbook `CONEXION.md` generado por `make-conexion.py` (contiene nsec):
  0600, se comparte por canal seguro y se destruye tras el onboarding.
- Cualquier keystore de firma (fase movil, Entrega 2).

Todo secreto nace 0600 (umask 077 en los scripts): los permisos no "se
corrigen despues".

## Frontera de red (decision M2)

- Modo tailscale: relay y pair-relay se publican SOLO en la IP del tailnet
  (`BUZZ_BIND_IP`); `verificar.sh` lo comprueba por 4 vias, incluida una
  prueba negativa desde otra interfaz. La autenticacion del relay NO sustituye
  el cifrado de transporte: fuera del tailnet, solo wss.
- Modo dominio: el relay escucha en loopback y publica Caddy con TLS.

## Frenos

- `buzz-panic {stop|start|status}`: para TODOS los agentes de golpe; no
  depende del relay, del LLM ni de que los agentes obedezcan.
- Kill switches de chat (`!cancel`/`!rotate`/`!shutdown`): solo funcionan con
  owner + auth tag configurados (si no, son no-ops SILENCIOSOS).
- `BUZZ_ACP_ALLOWED_RESPOND_TO=owner-only,allowlist` en todos los env: el
  harness se niega a arrancar si alguien lo abre a "responder a cualquiera".

## Limitaciones honestas

- Los permisos de Buzz son membresia de canal: no hay permisos granulares.
  El aislamiento real es el usuario de sistema (hermesbot) + hardening systemd.
- Fenix corre con las credenciales de Claude Code del administrador: su unidad
  lleva el hardening maximo compatible con eso (sin ProtectHome). El CLAUDE.md
  y el settings.json del workdir son POLITICA de comportamiento del agente, NO
  un mecanismo de aislamiento: un proceso comprometido puede leer el home. El
  aislamiento real (cuenta y HOME dedicados con solo las credenciales
  necesarias, ProtectHome=yes, ReadWritePaths minimos) queda como follow-up
  declarado. Es una decision explicita de esta version, no un olvido.
- Metricas kind 44200: los miembros directos requieren `users.agent_owner_pubkey`
  en Postgres o el relay las rechaza EN SILENCIO (deuda operativa documentada).
