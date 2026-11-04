# Extension: agentes gestionados desde la app de escritorio de Buzz

La app de escritorio (Agents → Create agent) puede correr agentes propios sin
systemd. Utiles para experimentos; para produccion, los servicios systemd del
nucleo/extension hermes son mas gobernables. Lecciones rodadas:

## Deteccion de harnesses

- La app resuelve cada harness buscando su comando: binarios del workspace →
  PATH del proceso → PATH de login shell → rutas comunes (incluye `~/.local/bin`).
- **Adaptadores instalados dentro de un venv NO se detectan** (caso real:
  `hermes-acp` vivia en `~/.hermes/hermes-agent/venv/bin/`). Solucion: wrapper
  en `~/.local/bin` que exporte lo que el adaptador necesite y ejecute el del
  venv. Caso hermes: el wrapper DEBE exportar `HERMES_HOME` apuntando al perfil
  correcto (`~/.hermes/profiles/<perfil>`); sin el, el adaptador cae al perfil
  global y el agente falla con "Internal error" en cada turno.
- Tras crear el wrapper basta reabrir el dialogo: la app re-sondea en cada
  apertura, sin reiniciar.

## Reglas para agentes de la app con modelo local

- La app usa SU PROPIO buzz-acp (embebido en el AppImage), SIN el patch 01:
  el salvavidas de publicacion no existe ahi. Con un modelo local es
  OBLIGATORIO poner la regla de publicacion en "Agent instructions".
- SEGURIDAD de la regla (ronda B1): la respuesta del modelo JAMAS se
  interpola en el comando (`--content "..."`, echo, cat o heredoc estan
  prohibidos) — el propio texto del modelo romperia el quoting y se
  ejecutaria como shell. La respuesta viaja como DATO por stdin
  (`--content -`) desde un archivo escrito con la herramienta de archivos
  del harness, nunca con comandos de terminal:

  > REGLA DE PUBLICACION (la mas importante): tu texto interno NO llega al
  > chat. Para publicar, en TRES pasos: 1) crea con tu herramienta de
  > archivos (write/create file, NUNCA con la terminal) un archivo NUEVO
  > cuyo nombre incluya la fecha-hora y un sufijo aleatorio que tu elijas
  > (p. ej. resp-20260730-x7k2.txt) y escribe en el tu respuesta completa;
  > 2) ejecuta en la terminal exactamente:
  > buzz messages send --channel <uuid del canal del contexto> --content - < <ese archivo>
  > 3) borra el archivo. Hazlo UNA vez al final de cada turno y SIN
  > --reply-to. PROHIBIDO poner tu respuesta dentro del comando (nada de
  > --content "texto", ni echo, ni heredocs de shell). Si no completas los
  > pasos, tu respuesta se pierde.

  El nombre unico por turno evita que dos turnos concurrentes del pool se
  pisen el archivo (una marca de tiempo sola no basta: añade el sufijo).
  Si la instalacion tiene el nucleo del skill montado, `buzz-publicar`
  (helper con protocolo centinela) tambien esta disponible en PATH y es
  preferible cuando el workdir del agente lo permite.

- Modelo: en "Custom model ID" va el nombre EXACTO que sirva el endpoint
  (con talent-llm-local: `claude-qwen-local`). El aviso "Could not load live
  models" es normal en endpoints custom.
- La app guarda el nsec del agente y lo muestra UNA sola vez al crearlo:
  guardalo en el keys.json del equipo en ese momento.
- El pool por defecto (10 instancias) tarda ~1,5 min en arrancar y los
  mensajes recibidos durante el arranque SE PIERDEN. Baja el pool en Advanced
  o espera el punto verde antes de escribirle.
- La pestana Agents solo lista agentes gestionados por la app: los servicios
  systemd del equipo NO aparecen ahi (es lo esperado).
