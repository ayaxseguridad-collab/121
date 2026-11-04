#!/usr/bin/env bash
# Verificacion del nucleo talent-buzz. Produce EVIDENCIA, no opiniones:
#   V1 readiness POR MODO · V2 identidad de imagen (M3) · V3 frontera de red
#   por modo (M2) · V4 unidades, roster y auth-tag (M7) · V5 permisos.
# Sale 1 al primer fallo (fail-closed). La verificacion usa el MISMO conjunto
# compose con el que se arranco (base, o base+caddy en modo dominio).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=00-config.sh
source "$DIR/00-config.sh"

evidencia() { printf '[EVIDENCIA] %s\n' "$*"; }
fallo() { printf '[FALLO] %s\n' "$*"; exit 1; }

# Mismo conjunto compose que run.sh (compara literal con "true")
COMPOSE=(docker compose -f compose.yml)
if [ "$TB_MODE" = "dominio" ]; then
  COMPOSE+=(-f compose.caddy.yml)
fi
compose() { (cd "$TB_COMPOSE_DIR" && "${COMPOSE[@]}" "$@"); }

if [ "$TB_MODE" = "tailscale" ]; then
  TB_BIND_IP="$(tailscale ip -4 | head -1)"
else
  TB_BIND_IP="127.0.0.1"
fi

# Contenedor del relay por LABEL de compose, no por nombre aproximado
CID=$(compose ps -q relay)
[ -n "$CID" ] || fallo "no hay contenedor del servicio 'relay' en el conjunto compose"

# ── V1: readiness por modo ───────────────────────────────────────────────────
if [ "$TB_MODE" = "dominio" ]; then
  READY_URL="https://$TB_DOMAIN/_readiness"
else
  READY_URL="http://$TB_BIND_IP:$TB_HTTP_PORT/_readiness"
fi
curl -fsS -m 5 "$READY_URL" >/dev/null || fallo "relay sin readiness en $READY_URL"
evidencia "V1 readiness OK en $READY_URL"

# ── V2: identidad de la imagen (M3) ──────────────────────────────────────────
RUNNING_IMG=$(docker inspect -f '{{.Image}}' "$CID")
LOCAL_IMG=$(docker image inspect -f '{{.Id}}' "$TB_IMAGE_TAG" 2>/dev/null) \
  || fallo "no existe la imagen local $TB_IMAGE_TAG (¿montar.sh la construyo?)"
[ "$RUNNING_IMG" = "$LOCAL_IMG" ] \
  || fallo "el relay NO corre $TB_IMAGE_TAG (corre $RUNNING_IMG, local $LOCAL_IMG)"
evidencia "V2 imagen: contenedor=$RUNNING_IMG == local($TB_IMAGE_TAG)"

# ── V3: frontera de red por modo (M2) ────────────────────────────────────────
if [ "$TB_MODE" = "tailscale" ]; then
  # (a) compose renderizado del MISMO conjunto usado al arrancar (host_ip sale
  # con o sin comillas segun la version de compose — hallado en el ensayo e2e)
  RENDER=$(compose config 2>/dev/null)
  echo "$RENDER" | grep -qE "host_ip: \"?${TB_BIND_IP//./\\.}\"?\$" \
    || fallo "compose config no muestra host_ip=$TB_BIND_IP para el puerto publicado"
  evidencia "V3a compose config: host_ip=$TB_BIND_IP"

  # (b) docker inspect del contenedor
  HOSTIPS=$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}} {{end}}{{end}}' "$CID")
  for ip in $HOSTIPS; do
    case "$ip" in
      "$TB_BIND_IP"|"127.0.0.1") : ;;
      *) fallo "PortBinding con HostIp fuera de la frontera: '$ip' (esperado $TB_BIND_IP o 127.0.0.1)" ;;
    esac
  done
  evidencia "V3b docker inspect HostIp: $HOSTIPS"

  # (c) ss
  BIND_RE="${TB_BIND_IP//./\\.}"
  ss -tln "( sport = :$TB_HTTP_PORT )" | grep -qE "(^|[[:space:]])${BIND_RE}:${TB_HTTP_PORT}([[:space:]]|\$)" \
    || fallo "ss no muestra escucha en $TB_BIND_IP:$TB_HTTP_PORT"
  if ss -tln "( sport = :$TB_HTTP_PORT )" | grep -qE "(0\.0\.0\.0|\[::\]):$TB_HTTP_PORT"; then
    fallo "el puerto $TB_HTTP_PORT tambien escucha en todas las interfaces"
  fi
  evidencia "V3c ss: escucha solo en $TB_BIND_IP:$TB_HTTP_PORT"

  # (d) prueba negativa contra el PUERTO PUBLICADO del relay desde otra interfaz
  OTRA_IP="$(ip -4 -o addr show scope global | awk '$2!="tailscale0"{print $4}' | cut -d/ -f1 | head -1 || true)"
  if [ -n "${OTRA_IP:-}" ]; then
    if curl -fsS -m 3 "http://$OTRA_IP:$TB_HTTP_PORT/_readiness" >/dev/null 2>&1; then
      fallo "PRUEBA NEGATIVA FALLIDA: el relay responde por $OTRA_IP (fuera del tailnet)"
    fi
    evidencia "V3d negativa: $OTRA_IP:$TB_HTTP_PORT no responde; la frontera aguanta"
  else
    evidencia "V3d negativa: sin interfaz adicional — frontera satisfecha por ausencia (registrado)"
  fi
else
  # Modo dominio: publica Caddy; el relay NO expone puertos host.
  CADDY_CID=$(compose ps -q caddy)
  [ -n "$CADDY_CID" ] || fallo "modo dominio sin contenedor caddy en el conjunto compose (¿arrancado sin BUZZ_COMPOSE_TLS=true?)"
  [ "$(docker inspect -f '{{.State.Running}}' "$CADDY_CID")" = "true" ] \
    || fallo "caddy presente pero no corriendo"
  evidencia "V3a caddy activo ($CADDY_CID)"

  RELAY_PORTS=$(docker inspect -f '{{len .HostConfig.PortBindings}}' "$CID")
  [ "$RELAY_PORTS" = "0" ] \
    || fallo "el relay publica $RELAY_PORTS puerto(s) host en modo dominio (compose.caddy.yml debe resetearlos)"
  evidencia "V3b relay sin puertos host publicados (publica Caddy)"

  RENDER=$(compose config 2>/dev/null)
  echo "$RENDER" | grep -q 'caddy' || fallo "el conjunto compose renderizado no incluye caddy"
  evidencia "V3c conjunto compose renderizado incluye caddy (mismo set que el arranque)"
  # V3d es V1: readiness real por https://$TB_DOMAIN
  evidencia "V3d readiness TLS externa cubierta por V1 ($READY_URL)"
fi

# ── V4: unidades, roster y auth-tag (M7) ─────────────────────────────────────
for u in buzz-claude buzz-pair-relay; do
  [ "$(systemctl is-active "$u")" = "active" ] || fallo "unidad $u no activa"
done
evidencia "V4 unidades buzz-claude y buzz-pair-relay activas"

OWNER_PK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['public_key'])" "$TB_KEYS_JSON" "$TB_OWNER_NAME")
FENIX_PK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['public_key'])" "$TB_KEYS_JSON" "$TB_FENIX_NAME")
ROSTER=$("$TB_COMPOSE_DIR/run.sh" list-members 2>/dev/null || true)
echo "$ROSTER" | grep -qi "$OWNER_PK" || fallo "el owner ($OWNER_PK) NO figura en el roster del relay"
echo "$ROSTER" | grep -qi "$FENIX_PK" || fallo "fenix ($FENIX_PK) NO figura en el roster del relay"
evidencia "V4 roster: owner y fenix presentes"

AUTH_LINE=$(grep -E '^BUZZ_AUTH_TAG=.+' "$TB_HOME/fenix.env" 2>/dev/null || true)
if [ -z "$AUTH_LINE" ] || echo "$AUTH_LINE" | grep -q '<pendiente'; then
  fallo "BUZZ_AUTH_TAG de Fenix ausente o pendiente: sin el, memoria/metricas/kill-switches son no-ops (compute_auth_tag, ver SKILL.md)"
fi
evidencia "V4 auth-tag de Fenix presente"

# ── V5: permisos ─────────────────────────────────────────────────────────────
for f in "$TB_KEYS_JSON" "$TB_HOME/fenix.env"; do
  [ -f "$f" ] || fallo "$f no existe (esperado tras montar.sh) — V5 no verifica en vacio"
  perms=$(stat -c '%a' "$f")
  [ "$perms" = "600" ] || fallo "$f con permisos $perms (esperado 600)"
done
if [ -f "$TB_COMPOSE_DIR/.env" ]; then
  perms=$(stat -c '%a' "$TB_COMPOSE_DIR/.env")
  [ "$perms" = "600" ] || fallo "$TB_COMPOSE_DIR/.env con permisos $perms (esperado 600)"
fi
evidencia "V5 permisos 0600 en claves y envs"

echo
echo "VERIFICACION DEL NUCLEO: OK"
echo "Smoke final (lo dirige el skill): mencion a @${TB_FENIX_NAME} con el CLI buzz y esperar su respuesta."
