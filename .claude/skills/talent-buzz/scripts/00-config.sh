#!/usr/bin/env bash
# Configuracion del despliegue talent-buzz. Todo es sobreescribible por entorno.
# shellcheck disable=SC2034

# Fuente fijada: los patches de assets/patches/ estan verificados contra ESTE
# commit. SHA COMPLETO (hallazgo 11 de la ronda de seguridad): un prefijo
# corto es falsificable por colision/ambiguedad; los guards resuelven y
# comparan contra los 40 caracteres.
TB_BUZZ_REPO_URL="${TB_BUZZ_REPO_URL:-https://github.com/block/buzz.git}"
TB_BUZZ_COMMIT="${TB_BUZZ_COMMIT:-4a1ebf25c782fc6a68f0a69e6f866f793a259a1f}"
TB_IMAGE_TAG="${TB_IMAGE_TAG:-buzz-relay:${TB_BUZZ_COMMIT}}"

# Directorios
TB_HOME="${TB_HOME:-$HOME/buzz-equipo}"          # claves, envs, workdir de Fenix
TB_SRC="${TB_SRC:-$TB_HOME/buzz-src}"            # checkout pinneado + parcheado
TB_COMPOSE_DIR="${TB_COMPOSE_DIR:-$TB_SRC/deploy/compose}"
TB_BIN_DIR="${TB_BIN_DIR:-/usr/local/bin}"       # RUTA UNICA de binarios (leccion: dos CLIs buzz segun PATH = confusion)

# Red: "tailscale" (frontera = IP del tailnet) o "dominio" (Caddy + TLS upstream)
TB_MODE="${TB_MODE:-tailscale}"
TB_DOMAIN="${TB_DOMAIN:-}"                       # solo modo dominio
TB_HTTP_PORT="${TB_HTTP_PORT:-80}"               # la comunidad se deriva del header Host: solo :80/:443 se normalizan
TB_PAIR_PORT="${TB_PAIR_PORT:-3310}"

# Identidades
TB_KEYS_JSON="${TB_KEYS_JSON:-$TB_HOME/keys.json}"
TB_OWNER_NAME="${TB_OWNER_NAME:-owner}"
TB_FENIX_NAME="${TB_FENIX_NAME:-fenix}"

# Usuario de servicio de Fenix (necesita las credenciales de Claude Code de este usuario)
TB_FENIX_USER="${TB_FENIX_USER:-$USER}"

# BLOQUEO DE AISLAMIENTO (fail-closed): Fenix corre con las credenciales de
# Claude Code de TB_FENIX_USER y SIN ProtectHome — un agente comprometido puede
# leer ese home. El montaje se NIEGA a instalar Fenix salvo consentimiento
# informado explicito: TB_FENIX_AISLAMIENTO=acepto-home-compartido
# (ver references/seguridad.md; la alternativa con cuenta dedicada es follow-up).
TB_FENIX_AISLAMIENTO="${TB_FENIX_AISLAMIENTO:-}"
