# Fase movil (Entrega 2): APK Android propio + pairing

La app movil oficial de Buzz asume un relay publico con TLS. Un despliegue
talent-buzz vive dentro de un tailnet y habla `ws://` — eso exige un APK
propio con DOS patches (verificados contra `block/buzz@4a1ebf2`, como todo
en este skill) y una politica de trafico en claro que NO es "permitir todo":

- **Patch 02 — esquemas + autoridad de cleartext**: normalizacion explicita
  de esquemas `{http→ws, https→wss, ws→ws, wss→wss}` (el codigo upstream
  degradaba `wss` a `ws` en la validacion de credenciales) y una UNICA
  autoridad para trafico en claro: `ws/http` SOLO hacia (a) el host MagicDNS
  exacto inyectado en build y (b) IPs del rango del tailnet `100.64.0.0/10`.
  Cualquier otro host en claro se rechaza; `wss/https` valen para cualquiera.
  La misma decision vive en dos capas: la politica Dart (`RelayUrlPolicy`,
  con matriz de tests esquema×host) y el `network_security_config.xml` de
  Android (cleartext OFF por defecto, dominio autorizado inyectado). Ambas
  capas se rellenan desde UNA fuente: el `--host` de `movil.sh`.
- **Patch 03 — paridad de DMs**: el escritorio p-taggea a todos los
  participantes de un DM; la app movil no lo hacia y los harnesses de
  agentes (que filtran por mencion) no veian los DMs del movil. Con el
  patch, todo DM lleva p-tags de sus participantes (menos el autor), con
  test que lo fija.

## Requisitos

- Los del nucleo (sonda) + **Android SDK** (`ANDROID_HOME` o `~/Android/Sdk`)
  con build-tools, **JDK** (`keytool` en PATH), `unzip`, `python3`.
- El toolchain Flutter lo trae el propio arbol de Buzz (hermit): no se
  instala aparte.
- Red para el primer build (hermit + pub descargan dependencias).

## Construir el APK

```bash
scripts/movil.sh construir \
  --host <maquina>.<tailnet>.ts.net \
  --ip <ip-tailnet-del-relay> \
  --build-number <N>
```

- `--host` es el MagicDNS EXACTO del relay (minusculas; sin `_`). Es la unica
  fuente de la autoridad de cleartext: se inyecta a la vez en la constante
  Dart y en el network security config del APK. movil.sh exige ACREDITARLO:
  debe ser `*.ts.net` y resolver (todas sus IPv4) dentro de `100.64.0.0/10`
  desde la maquina de build — un dominio publico aqui autorizaria cleartext
  fuera del tailnet y se rechaza fail-closed.
- `--ip` (opcional, repetible) añade IPs del tailnet al network security
  config. Android no expresa rangos CIDR ahi: si el pairing va a usar la IP
  en vez del nombre, la IP exacta tiene que declararse. La politica Dart ya
  acepta todo 100.64.0.0/10; esta capa de plataforma es mas estricta a
  proposito.
- `--build-number` es OBLIGATORIO y debe SUBIR en cada build que
  distribuyas: Android no actualiza a un versionCode igual o menor, y un
  valor "por defecto" repetiria el anterior sin que nadie lo note.

El APK se construye desde el **export limpio de pin+patches** (doctrina M3:
jamas del checkout de trabajo) y despues se verifica fail-closed sobre el
artefacto final:

- V1: el placeholder no sobrevive en ningun byte del APK.
- V2: el manifest fusionado referencia `network_security_config` y NO
  permite cleartext global.
- V3: el host inyectado esta en el network security config DEL APK.
- V4: la firma del APK es la huella del keystore propio.

## Keystore (firma)

La primera ejecucion genera `android-upload.keystore` + `android-signing.env`
(0600 de nacimiento) y las siguientes lo REUTILIZAN. Regla dura: **el mismo
keystore firma todas las builds para siempre** — Android rechaza actualizar
una app cuya firma cambia; perder el keystore = desinstalar y reinstalar en
cada movil. Respaldalo cifrado fuera de la maquina. El keystore vive fuera
del arbol de build (el gradle de Buzz lo exige) y jamas se versiona
(references/seguridad.md).

## Distribuir e instalar

```bash
scripts/movil.sh portal          # sirve el APK SOLO en la IP del tailnet
```

Desde el movil (con Tailscale activo y dentro del tailnet): abrir la URL que
imprime el portal, descargar el `.apk` e instalarlo (Android pedira permitir
"instalar apps desconocidas" para el navegador). La frontera es la misma M2
del relay: fuera del tailnet el portal no responde.

## Pairing — Buzz Desktop 0.5.1 (dependencia VERSIONADA)

El pairing del movil se hace escaneando el QR que genera la app de
escritorio, y este skill lo FIJA a **Buzz Desktop 0.5.1** — no "la ultima
release": el payload del pairing es un contrato entre escritorio y movil, y
una release nueva de Desktop puede cambiarlo por delante del pin `4a1ebf2`
del APK. Si usas otra version de Desktop y el pairing falla, vuelve a 0.5.1
antes de culpar al APK.

### Estado del ensayo de pairing

Esta seccion declara QUE se ha rodado de verdad; nada fuera de ella vale
como afirmacion de compatibilidad (D6).

- RODADO: build del APK con movil.sh en maquina fresca (V1-V4 en verde,
  keystore generado de cero), portal con prueba negativa real fuera del
  tailnet, y descarga de Buzz Desktop 0.5.1 con sha256 registrado.
- **NO RODADO**: el flujo interactivo QR → SAS → conexion → DM respondido
  contra Desktop 0.5.1. Hasta que un ensayo lo complete y su evidencia se
  registre aqui, trata la compatibilidad del pairing como NO VERIFICADA.
  Decision del dueño (2026-07-30): esta version se entrega SIN ese ensayo;
  la primera instalacion real que complete el flujo debe actualizar esta
  seccion con su resultado (exito o fallo, con version exacta de Desktop).

Flujo:

1. Instalar Buzz Desktop **0.5.1** y conectarlo a la comunidad (runbook de
   `make-conexion.py` con la identidad del humano).
2. Desktop → ajustes → *Pair mobile device* → aparece el QR.
3. En el movil, abrir la app Buzz recien instalada → *Scan QR* → escanear.
4. La app valida la URL del relay contra la autoridad de cleartext (si el QR
   trae un host en claro que no es el MagicDNS del build ni una IP del
   tailnet, se rechaza: es lo esperado) y hace el handshake NIP-42.
5. Confirmar el codigo SAS en ambos lados; el movil queda emparejado.

Verificacion minima post-pairing (M4): abrir un canal y ver historial;
mandar un DM a un agente y recibir respuesta (esto ejercita el patch 03: el
agente solo responde si el DM lleva su p-tag).

## Errores reales destilados

- QR con `wss://` y el movil intenta `ws://`: eso era el bug de
  normalizacion upstream; con el patch 02 no ocurre (y hay test que lo fija).
- "Cleartext relay URL not allowed": la autoridad funciono — el host del QR
  no es el `--host` del build ni 100.64/10. Reconstruye el APK con el host
  correcto; no lo "arregles" relajando la politica.
- La app instala pero no actualiza una version previa: firma distinta
  (keystore nuevo) o `--build-number` que no subio.
- Pairing OK pero los DMs al agente no obtienen respuesta: APK sin el patch
  03 (sin p-tags en DM) o agente sin harness activo (`buzz-panic status`).
