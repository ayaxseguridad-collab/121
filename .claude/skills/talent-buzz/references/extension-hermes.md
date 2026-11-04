# Extension hermes — especialistas con modelo local

Amplia el nucleo (relay + Fenix) con hasta 5 agentes especialistas corriendo
sobre un modelo local. Todo lo de este documento esta rodado en la maquina de
referencia (5 hermes sobre Qwen3.6-35B, semanas de uso real).

## Cerebro: dos vias

1. **`talent-llm-local` (mismo paquete, recomendado)**: monta vLLM + medidor por
   usuario + puestos de agente. Los hermes apuntan a `http://127.0.0.1:8001/v1`
   con una clave POR AGENTE (contabilidad de tokens por usuario en `/stats`).
2. **Endpoint OpenAI-compatible propio**: cualquier servidor `/v1/chat/completions`
   (vLLM, llama.cpp, un proveedor). Rellena `OPENAI_COMPAT_*` en la plantilla.

## Topologia en estrella (anti-bucle estructural)

- El orquestador (Fenix) es el UNICO hub: delega y consolida. Los hermes tienen
  PROHIBIDO mencionarse entre si, y su allowlist solo contiene dueno + Fenix
  (+ pubkey del relay si usaras workflows). Los bucles agente-agente quedan
  estructuralmente imposibles: no dependen de que un modelo de 35B obedezca.
- Nombres de agente: UN token sin espacios NI guiones — la resolucion de
  @menciones corta en el primer caracter no alfanumerico.

## Alta de un hermes

1. Identidad: `python3 scripts/genkeys.py` NO sobrescribe: genera las claves de
   los hermes en un keys.json aparte o anade a mano con el mismo formato.
   Alta en el relay: `run.sh add-member <pubkey>` (con `sleep 1` entre altas).
2. `.env` desde `assets/hermes.env.tmpl` (0600). Techos YA puestos en la
   plantilla — son la palanca de rendimiento numero uno sin prefix caching:
   contexto 48k, 8 turnos/sesion, 6 mensajes de contexto, `queue` (no `steer`:
   steer cancela el turno en vuelo y tira prefill de GPU ya pagado).
3. Roles y guardarraices: `python3 scripts/roles.py --acp-dir <dir>` reescribe
   el prompt de rol y las 10 reglas de equipo. Editar el script, no los .env.
4. Unidad: `assets/buzz-hermes@.service.tmpl` + `assets/hardening.conf`
   (`ProtectSystem=strict`, `MemoryMax`). Aislamiento POR INSTANCIA (ronda de
   seguridad): usuario dedicado `hermesbot<N>` por instancia — una instancia
   comprometida no puede leer el estado de las demas. Antes de arrancar
   `buzz-hermes@N`:
   ```bash
   # (una sola vez) Instala la plantilla + el drop-in de hardening. SIN esto el
   # endurecimiento declarado (ProtectSystem=strict, ProtectHome=read-only,
   # MemoryMax, ReadWritePaths por instancia) NO se aplica en la maquina.
   ACP_DIR=<el mismo --acp-dir que usaste en roles.py>   # p.ej. ~/buzz-team/acp
   BIN_DIR=/usr/local/bin                                # donde vive buzz-acp
   sudo sed -e "s|@ACP_DIR@|$ACP_DIR|" -e "s|@BIN_DIR@|$BIN_DIR|" \
     assets/buzz-hermes@.service.tmpl \
     | sudo tee /etc/systemd/system/buzz-hermes@.service >/dev/null
   sudo install -D -m 0644 assets/hardening.conf \
     /etc/systemd/system/buzz-hermes@.service.d/hardening.conf
   sudo systemctl daemon-reload
   # (por instancia N) Usuario dedicado + workdir aislado + semilla del protocolo.
   sudo install -d -m 0711 -o root -g root /var/lib/buzz-hermes
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin hermesbot$N
   sudo install -d -m 0700 -o hermesbot$N -g hermesbot$N /var/lib/buzz-hermes/$N
   printf '%s\n' "PLANTILLA-RESPUESTA (sustituye esta linea con tu respuesta usando str_replace y ejecuta: buzz-publicar <uuid-del-canal>)" | sudo install -m 0600 -o hermesbot$N -g hermesbot$N /dev/stdin /var/lib/buzz-hermes/$N/respuesta.txt
   ```
   Verifica que el hardening quedó activo antes de arrancar:
   `systemctl cat buzz-hermes@$N | grep -E 'ProtectHome|ProtectSystem|MemoryMax'`
   debe listar las tres directivas del drop-in.
   El padre queda 0711 root:root (solo travesia, sin listado); cada `/N` 0700
   de su instancia; `respuesta.txt` es la semilla del protocolo de publicacion
   (ver abajo). Preflight antes del primer arranque:
   `sudo -u hermesbot$N test -r /var/lib/buzz-hermes/$N/respuesta.txt` debe
   pasar, y el mismo test contra el directorio de OTRA instancia debe fallar.
5. Owner + auth tag (NIP-OA): `BUZZ_ACP_AGENT_OWNER` + `BUZZ_AUTH_TAG` (ejemplo
   `compute_auth_tag` del repo de Buzz, firmado por el dueno, SIN condiciones de
   kind). Sin esto, memoria/metricas/kill-switches son no-ops SILENCIOSOS.
   Ademas: los miembros directos requieren `users.agent_owner_pubkey` en el
   Postgres del relay o los eventos de metricas kind 44200 se rechazan EN SILENCIO.

## Publicacion segura (buzz-publicar) y el salvavidas (patch 01)

Los modelos locales redactan la respuesta pero a veces no ejecutan el paso que
la publica — y una respuesta interpolada en un comando shell es ademas un
vector de inyeccion (ronda de seguridad B1). Defensa en capas:
- La regla PUBLICAR del prompt (la pone `roles.py`): la respuesta se escribe
  con `str_replace` sobre la semilla `respuesta.txt` (herramienta de archivos,
  no shell) y se publica con `buzz-publicar <uuid>` — el helper la manda por
  STDIN (`--content -`), jamas dentro de la linea de comandos. El protocolo
  centinela ademas serializa turnos concurrentes: entre siembra y publicacion
  solo un turno puede escribir; el que llega tarde falla ruidoso, sin mezclas.
  Si el envio falla, el helper resiembra la plantilla (el protocolo nunca se
  queda muerto), preserva el payload en `respuesta-fallida.XXXXXX` (0600) como
  EVIDENCIA AUTORITATIVA del turno, y sale con rc!=0.
- El patch 01 en buzz-acp: si el turno emitio mensaje sin publicar (o su
  publicacion reporto fallo — reconoce `buzz messages send` Y `buzz-publicar`
  en posicion de comando), lo publica el harness. Es un salvavidas REARMADO y
  BEST-EFFORT, no una garantia: solo actua si hubo agent_message_chunk y el
  relay responde; ante un fallo, la evidencia es el payload preservado por
  buzz-publicar. El razonamiento (thought) SE DESCARTA SIEMPRE — publicarlo
  saca al canal parrafos de pensamiento sin sentido.

## Operacion

- Kill switches de chat: `!cancel` / `!rotate` / `!shutdown` (requieren owner).
  Freno duro: `buzz-panic {stop|start|status}` — no depende de nada.
- DM nuevo con un agente => reiniciar su servicio (los canales DM nuevos no
  llegan como notificacion de membresia al harness).
- Memoria (NIP-AE) y canvas se cachean por sesion: tras editar, `!rotate`.
- Heartbeat: SOLO para un rol de operacion (variante en la plantilla). El
  heartbeat no recibe memoria ni canvas (prompt autocontenido) y el exito se
  mide asi: una hora con todo sano = CERO mensajes publicados.
