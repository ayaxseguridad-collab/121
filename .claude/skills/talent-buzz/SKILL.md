---
name: talent-buzz
description: >
  Desplegar un equipo de agentes en Buzz (block/buzz) self-hosted identico al de
  referencia: relay pinneado a commit y construido en local, orquestador Fenix
  (Claude via claude-agent-acp) como servicio systemd, pair-relay para moviles,
  identidades Nostr frescas por instalacion, frontera de red verificada (tailnet
  o dominio+TLS) y frenos de emergencia. Extensiones documentadas: especialistas
  hermes con modelo local (via talent-llm-local o endpoint OpenAI-compatible) y
  agentes de la app de escritorio. La sonda es una PUERTA: autoriza o explica
  que falta, nunca monta una version recortada. Trigger (ES/EN): "buzz",
  "block/buzz", "equipo de agentes", "agent team chat", "relay nostr", "buzz
  self-hosted", "montar buzz", "chat de agentes", "fenix orquestador", "hermes
  buzz", "agentes residentes", "nostr relay equipo", "deploy buzz", "buzz
  relay", "equipo IA local", "multi-agent chat".
---

# Equipo de agentes en Buzz self-hosted — el mismo que el de referencia

## Quick Orientation

| Propiedad | Valor |
|---|---|
| Que monta | Relay **block/buzz @ 4a1ebf2** (imagen construida EN LOCAL desde ese commit, jamas `:main`) · **Fenix** (Claude orquestador, systemd) · pair-relay · CLI `buzz` · frenos (`buzz-panic`, kill switches de chat) |
| Identidades | Nostr secp256k1 frescas POR INSTALACION (genkeys.py, 0600). Este skill jamas incluye ni reutiliza claves de otra instalacion |
| Red | Modo **tailscale** (relay SOLO en la IP del tailnet, verificado por 4 vias) o **dominio** (relay en loopback, publica Caddy con TLS) |
| Requisitos | Linux+systemd, Docker+compose, git, Node+npm, Claude Code con sesion, 15 GB. La sonda (`scripts/sonda.sh`) es la puerta |
| Extensiones | `references/extension-hermes.md` (especialistas con modelo local; cerebro via **talent-llm-local** del mismo paquete o endpoint propio) · `references/extension-app-agents.md` |
| Movil | **Entrega 2**: APK Android propio (patches 02 esquemas+autoridad cleartext y 03 paridad DM) construido, verificado y firmado con `scripts/movil.sh`; pairing FIJADO a Buzz Desktop **0.5.1** (estado real del ensayo: "Estado del ensayo de pairing" en `references/movil.md`). Requiere ademas Android SDK + JDK. Ver "Fase movil" |
| Idioma | Espanol, para alumnos de Vibecoder Academy |

## Fases (las dirige Claude con los scripts; la sonda manda)

1. **Decision de red** (pregunta al usuario): `TB_MODE=tailscale` (recomendado:
   cero puertos abiertos, probado extremo a extremo) o `TB_MODE=dominio` (+`TB_DOMAIN`).
2. **Sonda**: `scripts/sonda.sh`. Si rechaza, se arregla lo que falte y se
   repite. No hay via "a medias".
3. **Consentimiento de aislamiento** (pregunta OBLIGATORIA al usuario, sin
   default): Fenix corre con las credenciales de Claude Code del usuario y sin
   ProtectHome — un agente comprometido puede leer ese home. Explicalo con
   references/seguridad.md delante; SOLO si el usuario lo acepta con
   conocimiento, exporta `TB_FENIX_AISLAMIENTO=acepto-home-compartido`. Sin
   eso, montar.sh se niega a instalar Fenix (fail-closed). El aislamiento con
   cuenta dedicada es follow-up declarado.
4. **Montaje**: `scripts/montar.sh` — checkout pinneado + patches verificados +
   imagen del relay construida del arbol + binarios en `/usr/local/bin` (RUTA
   UNICA) + compose con secretos frescos + miembros (owner admin, fenix) +
   servicio de Fenix con workdir gobernado (CLAUDE.md + settings.json, que son
   politica del agente, NO aislamiento) + pair-relay confinado + `buzz-panic`.
5. **Auth tag de Fenix** (NIP-OA): ejecutar el ejemplo `compute_auth_tag` del
   repo (`buzz-sdk`), firmado con la clave del dueno, SIN condiciones de kind;
   pegar en `fenix.env` como `BUZZ_AUTH_TAG` y reiniciar `buzz-claude`.
   Sin owner+auth-tag, memoria/metricas/kill-switches son no-ops SILENCIOSOS.
6. **Verificacion**: `scripts/verificar.sh` (readiness, identidad de imagen,
   frontera por 4 vias con prueba negativa, unidades, permisos). Despues, el
   smoke humano: mencion a @fenix con el CLI `buzz` y respuesta recibida.
7. **Onboarding humano**: `scripts/make-conexion.py` genera el runbook con las
   claves inyectadas al vuelo (0600; se destruye tras usarlo). App de
   escritorio oficial de Buzz para los humanos.

## Fase movil — Entrega 2

La app movil oficial asume un relay publico con TLS; un despliegue
talent-buzz exige un APK propio. `scripts/movil.sh construir --host
<magicdns-exacto> [--ip <ip-tailnet>] --build-number <N>`:

- construye desde el **export limpio de pin+patches** (doctrina M3, jamas
  del checkout);
- inyecta la **autoridad unica de trafico en claro** (ws/http SOLO hacia el
  host MagicDNS del build o IPs 100.64.0.0/10; el resto en claro se
  rechaza, wss/https valen para cualquiera) en las DOS capas — politica
  Dart con matriz de tests y network security config de Android — desde UNA
  fuente (`--host`);
- firma con **keystore propio** (nace 0600; el MISMO keystore firma todas
  las builds futuras o Android no actualiza: respaldalo);
- y verifica el artefacto final fail-closed: V1 placeholder ausente del
  APK, V2 manifest con network security config y sin cleartext global, V3
  host presente en el APK, V4 huella del certificado == keystore propio.

`movil.sh portal` sirve el APK SOLO en la IP del tailnet (frontera M2). El
pairing esta FIJADO a **Buzz Desktop 0.5.1** — dependencia VERSIONADA del
payload de pairing, no "ultima release". El estado real del ensayo de
pairing (que se rodo y que no) se declara SIEMPRE en la seccion "Estado del
ensayo de pairing" de `references/movil.md`: no afirmes disponibilidad por
encima de lo que diga esa seccion. Guia, errores reales y flujo:
`references/movil.md`.

## Troubleshooting destilado (errores reales de la instalacion de referencia)

- El relay va en puerto **80** (o 443 tras Caddy): la comunidad se deriva del
  header Host y solo :80/:443 se normalizan — un puerto no estandar da 404
  "no community".
- `add-member`: `sleep 1` entre altas (colision de timestamps kind 13534).
- Nombres de agente: un token sin espacios NI guiones (la resolucion de
  @menciones corta en `\w+`).
- DM nuevo con un agente systemd => reiniciar su servicio.
- Memoria/canvas se cachean por sesion => tras editar, `!rotate`.
- Metricas kind 44200 de miembros directos: exigen `users.agent_owner_pubkey`
  en Postgres o el relay las descarta EN SILENCIO.
- Icono del AppImage de escritorio: `StartupWMClass=buzz-desktop` en el
  lanzador o el dock no lo ancla.
- Modelos locales que "escriben" pero no publican: regla PUBLICAR en el prompt
  (publicacion via `buzz-publicar`: la respuesta viaja por stdin, JAMAS
  interpolada en un comando) + patch 01 (fallback REARMADO y best-effort; el
  razonamiento SE DESCARTA).

## Paquete de fábrica

Este skill es miembro del **paquete de skills de fábrica** (16): linear-skill · skill-creator · talent-buzz ·
talent-ceo · talent-channel-operation · talent-channels · talent-context · talent-coordination ·
talent-issue-craft · talent-llm-local · talent-memoria · talent-merger · talent-orchestrator · talent-pm · talent-prd · talent-repo-onboarding. El paquete viaja JUNTO y
**motor-primero**: canónico en el repo motor `talent-factory` (`skills/`), propagado como núcleo
a los repos de producto con `skill-creator/scripts/sync-package.sh` (overlays por repo intactos)
y validado con `skill-creator/scripts/validate-package.sh` + `<skill>/invariants.tsv`.
Manifiesto: `skill-creator/assets/package.manifest` · doctrina y ratchet (D6):
`skill-creator/references/09-paquete-de-fabrica.md`.
