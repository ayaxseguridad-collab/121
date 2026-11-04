#!/usr/bin/env bash
# Monta el nucleo talent-buzz: relay pinneado + Fenix (Claude) + pair-relay + frenos.
# Idempotente donde es barato serlo; falla cerrado en el resto.
# La fase movil es Entrega 2 y NO vive aqui.
set -euo pipefail
umask 077   # todo secreto nace 0600 / dir 0700; nunca "se corrige despues"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$DIR/../assets"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=00-config.sh
source "$DIR/00-config.sh"
# shellcheck source=SCRIPTDIR/lib-contexto.sh
source "$DIR/lib-contexto.sh"
# shellcheck source=SCRIPTDIR/lib-seguridad.sh
source "$DIR/lib-seguridad.sh"

log() { printf '\n== %s ==\n' "$*"; }
fatal() { echo "FATAL: $*" >&2; exit 1; }

# ── 0. Puertas ───────────────────────────────────────────────────────────────
"$DIR/sonda.sh"

# Bloqueo explicito de aislamiento (CodeRabbit r2 + Alta del auditor, PR #22):
# instalar a Fenix con el home del administrador es una decision INFORMADA, no
# un default — y se decide AQUI, antes de crear checkout, identidades o relay,
# para no dejar despliegues parciales.
if [ "$TB_FENIX_AISLAMIENTO" != "acepto-home-compartido" ]; then
  fatal "instalacion bloqueada: Fenix correria con las credenciales de Claude Code de $TB_FENIX_USER y sin ProtectHome (un compromiso del agente puede leer ese home). Lee references/seguridad.md y, si lo aceptas con conocimiento, exporta TB_FENIX_AISLAMIENTO=acepto-home-compartido y reintenta"
fi

mkdir -p "$TB_HOME"

# ── 1. Checkout pinneado ─────────────────────────────────────────────────────
log "checkout $TB_BUZZ_COMMIT"
if [ ! -d "$TB_SRC/.git" ]; then
  git clone "$TB_BUZZ_REPO_URL" "$TB_SRC"
fi
git -C "$TB_SRC" fetch --all --quiet || true
git -C "$TB_SRC" checkout --quiet "$TB_BUZZ_COMMIT"
# El pin se compara por SHA RESUELTO: TB_BUZZ_COMMIT admite SHA corto/largo/tag
PIN_SHA="$(git -C "$TB_SRC" rev-parse --verify "${TB_BUZZ_COMMIT}^{commit}")" \
  || fatal "no se pudo resolver $TB_BUZZ_COMMIT en $TB_SRC"
[ "$(git -C "$TB_SRC" rev-parse HEAD)" = "$PIN_SHA" ] \
  || fatal "HEAD no es $TB_BUZZ_COMMIT"

# ── 2. Patches + arbol EXACTO (M3: la imagen solo puede salir de pin+patches) ─
log "patches y verificacion de arbol exacto"
for p in "$ASSETS"/patches/*.patch; do
  if git -C "$TB_SRC" apply --reverse --check "$p" 2>/dev/null; then
    echo "$(basename "$p"): ya aplicado"
  else
    git -C "$TB_SRC" apply "$p"
    echo "$(basename "$p"): aplicado"
  fi
done
# Reversa total EN ORDEN INVERSO al de aplicacion: si al quitar los patches el
# arbol NO queda identico al commit, hay drift no auditado y NO se construye.
mapfile -t PATCHES_ORD < <(ls "$ASSETS"/patches/*.patch)
for ((i=${#PATCHES_ORD[@]}-1; i>=0; i--)); do
  p="${PATCHES_ORD[$i]}"
  git -C "$TB_SRC" apply -R "$p" \
    || fatal "el arbol contiene cambios que no son exactamente los patches (falla la reversa de $(basename "$p")); borra $TB_SRC y reintenta"
done
DRIFT=""
while IFS= read -r linea; do
  [ -z "$linea" ] && continue
  estado=${linea:0:2}; ruta=${linea:3}
  if [ "$estado" = "??" ]; then
    # Unico untracked tolerado: artefactos de build cargo (necesarios para los
    # binarios host). NUNCA llegan a la imagen: el contexto Docker es un export
    # limpio (ver seccion 3), no este checkout.
    case "$ruta" in
      target/*|target) : ;;
      *) DRIFT="$DRIFT$linea"$'\n' ;;
    esac
  else
    DRIFT="$DRIFT$linea"$'\n'
  fi
done < <(git -C "$TB_SRC" status --porcelain)
# Restaurar los patches ANTES de decidir, para no dejar el arbol a medias.
for p in "$ASSETS"/patches/*.patch; do git -C "$TB_SRC" apply "$p"; done
if [ -n "$DRIFT" ]; then
  echo "Drift detectado sobre $TB_BUZZ_COMMIT+patches:" >&2
  printf '%s' "$DRIFT" >&2
  fatal "el arbol no es exactamente commit+patches; limpia o borra $TB_SRC"
fi
echo "arbol exacto: $TB_BUZZ_COMMIT + patches auditados, sin drift rastreado"

# ── 3. Imagen del relay desde CONTEXTO EXACTO (M3) ───────────────────────────
# El contexto Docker es un export limpio de commit+patches (git archive), no el
# checkout de trabajo: ni untracked ni IGNORADOS (.hermit/, target/, editores…)
# pueden entrar por construccion — `git status` ni muestra los ignorados y
# .dockerignore no los cubre todos, asi que inspeccionarlos era insuficiente.
log "imagen del relay ($TB_IMAGE_TAG) desde export limpio"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
exportar_contexto_exacto "$TB_SRC" "$TB_BUZZ_COMMIT" "$ASSETS/patches" "$CTX" \
  || fatal "no se pudo exportar el contexto exacto commit+patches"
docker build -t "$TB_IMAGE_TAG" "$CTX"
rm -rf "$CTX"; trap - EXIT

# ── 4. Binarios host (ruta unica) ────────────────────────────────────────────
log "binarios (cargo via hermit del repo)"
(cd "$TB_SRC" && ./bin/cargo build --release -p buzz-cli -p buzz-acp -p buzz-pair-relay)
for b in buzz buzz-acp buzz-pair-relay; do
  sudo install -m 755 "$TB_SRC/target/release/$b" "$TB_BIN_DIR/$b"
done
command -v claude-agent-acp >/dev/null 2>&1 || sudo npm install -g @agentclientprotocol/claude-agent-acp
# M6: la ruta EFECTIVA del adaptador se resuelve aqui y se inyecta en el env de
# Fenix — npm global puede instalar en /usr/bin, /usr/local/bin u otro prefix.
CLAUDE_ACP="$(command -v claude-agent-acp || true)"
[ -n "$CLAUDE_ACP" ] && [ -x "$CLAUDE_ACP" ] \
  || fatal "claude-agent-acp no resoluble tras la instalacion npm"
echo "claude-agent-acp: $CLAUDE_ACP"

# ── 5. Frontera de red (M2) ──────────────────────────────────────────────────
if [ "$TB_MODE" = "tailscale" ]; then
  TB_BIND_IP="$(tailscale ip -4 | head -1)"
  TB_HOST="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
  TB_RELAY_URL="ws://$TB_HOST"
else
  TB_BIND_IP="127.0.0.1"   # en modo dominio publica Caddy, no el relay
  TB_HOST="$TB_DOMAIN"
  TB_RELAY_URL="wss://$TB_HOST"
fi
echo "frontera: bind=$TB_BIND_IP host=$TB_HOST relay=$TB_RELAY_URL"

# ── 6. Compose .env (secretos frescos, 0600 de nacimiento por umask) ─────────
log "compose"
ENVF="$TB_COMPOSE_DIR/.env"
if [ -f "$ENVF" ]; then
  echo ".env ya existe: se conserva (borralo tu si quieres regenerar secretos)"
  # Reconciliacion COMPLETA de claves invariantes (huecos 6-7 de la ronda de
  # seguridad): un .env heredado puede traer BUZZ_IMAGE distinto (bypass del
  # pin M3), BUZZ_REQUIRE_RELAY_MEMBERSHIP=false (autenticacion fuera) o
  # frontera/URLs divergentes — y hasta ahora solo se reconciliaba
  # BUZZ_BIND_IP. Ademas el .env se verifica 0600+dueño ANTES de tocarlo
  # (un restore 0644 no "se acepta y ya") y la reescritura es atomica,
  # conservando los secretos byte a byte (reconciliar_env, lib-seguridad.sh).
  reconciliar_env "$ENVF" \
    "BUZZ_IMAGE=$TB_IMAGE_TAG" \
    "BUZZ_DOMAIN=$TB_HOST" \
    "RELAY_URL=$TB_RELAY_URL" \
    "BUZZ_HTTP_PORT=$TB_HTTP_PORT" \
    "BUZZ_BIND_IP=$TB_BIND_IP" \
    "BUZZ_REQUIRE_RELAY_MEMBERSHIP=true" \
    "BUZZ_PAIRING_RELAY_URL=ws://$TB_HOST:$TB_PAIR_PORT" \
    || fatal "el .env heredado no pasa la verificacion o la reconciliacion fallo"
  echo "claves invariantes reconciliadas (imagen pinneada, frontera, membership, URLs)"
else
  if [ ! -f "$TB_KEYS_JSON" ]; then
    python3 "$DIR/genkeys.py" --out "$TB_KEYS_JSON" --members "$TB_OWNER_NAME,$TB_FENIX_NAME,_relay"
  fi
  # La ruta y los NOMBRES van por sys.argv, jamas interpolados en el codigo
  # Python (cierre del descarte de 1.0.5, hallazgo 10: una ruta o nombre con
  # comilla ejecutaria codigo arbitrario).
  RELAY_SK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['private_key'])" "$TB_KEYS_JSON" "_relay")
  OWNER_PK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['public_key'])" "$TB_KEYS_JSON" "$TB_OWNER_NAME")
  {
    echo "BUZZ_IMAGE=$TB_IMAGE_TAG"
    echo "BUZZ_DOMAIN=$TB_HOST"
    echo "RELAY_URL=$TB_RELAY_URL"
    echo "BUZZ_HTTP_PORT=$TB_HTTP_PORT"
    echo "BUZZ_BIND_IP=$TB_BIND_IP"
    echo "BUZZ_RELAY_PRIVATE_KEY=$RELAY_SK"
    echo "RELAY_OWNER_PUBKEY=$OWNER_PK"
    echo "BUZZ_REQUIRE_RELAY_MEMBERSHIP=true"
    echo "BUZZ_ALLOW_NIP_OA_AUTH=true"
    echo "BUZZ_AUTO_MIGRATE=true"
    echo "BUZZ_PAIRING_RELAY_URL=ws://$TB_HOST:$TB_PAIR_PORT"
    echo "POSTGRES_DB=buzz"
    echo "POSTGRES_USER=buzz"
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "REDIS_PASSWORD=$(openssl rand -hex 24)"
    echo "BUZZ_S3_ACCESS_KEY=$(openssl rand -hex 16)"
    echo "BUZZ_S3_SECRET_KEY=$(openssl rand -hex 24)"
    echo "BUZZ_S3_BUCKET=buzz-media"
    echo "BUZZ_GIT_HOOK_HMAC_SECRET=$(openssl rand -hex 24)"
  } > "$ENVF.tmp"
  mv "$ENVF.tmp" "$ENVF"
  echo ".env creado (0600, escritura atomica)"
fi

# M2: run.sh compara literalmente con "true"; en modo dominio Caddy DEBE entrar
# al conjunto compose o el dominio externo no funciona.
if [ "$TB_MODE" = "dominio" ]; then
  BUZZ_COMPOSE_TLS=true "$TB_COMPOSE_DIR/run.sh" start
else
  "$TB_COMPOSE_DIR/run.sh" start
fi

log "readiness"
if [ "$TB_MODE" = "dominio" ]; then
  READY_URL="https://$TB_HOST/_readiness"
else
  READY_URL="http://$TB_BIND_IP:$TB_HTTP_PORT/_readiness"
fi
LISTO=no
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "$READY_URL" >/dev/null 2>&1; then LISTO=si; break; fi
  sleep 2
done
[ "$LISTO" = "si" ] || fatal "el relay no respondio readiness en $READY_URL tras 120s"
echo "relay listo en $READY_URL"

# ── 7. Miembros (M7: los fallos de alta CIERRAN el montaje; sleep 1 por la
#      colision de timestamps kind 13534) ────────────────────────────────────
log "miembros"
OWNER_PK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['public_key'])" "$TB_KEYS_JSON" "$TB_OWNER_NAME")
FENIX_PK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['public_key'])" "$TB_KEYS_JSON" "$TB_FENIX_NAME")
"$TB_COMPOSE_DIR/run.sh" add-member "$OWNER_PK" --role admin
sleep 1
"$TB_COMPOSE_DIR/run.sh" add-member "$FENIX_PK"

# ── 8. Fenix ─────────────────────────────────────────────────────────────────
log "fenix"
FENIX_SK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['nsec'])" "$TB_KEYS_JSON" "$TB_FENIX_NAME")
FENIX_ENV="$TB_HOME/fenix.env"
if [ ! -f "$FENIX_ENV" ]; then
  sed -e "s|@RELAY_URL@|$TB_RELAY_URL|" \
      -e "s|@OWNER_PUBKEY@|$OWNER_PK|" \
      -e "s|@FENIX_NSEC@|$FENIX_SK|" \
      -e "s|@CLAUDE_ACP@|$CLAUDE_ACP|" \
      "$ASSETS/fenix.env.tmpl" > "$FENIX_ENV"
  echo "fenix.env creado (0600). PENDIENTE: BUZZ_AUTH_TAG (ver SKILL.md, compute_auth_tag)"
else
  # M6 tambien en re-ejecuciones: la ruta del adaptador pudo cambiar
  sed -i "s|^BUZZ_ACP_AGENT_COMMAND=.*|BUZZ_ACP_AGENT_COMMAND=$CLAUDE_ACP|" "$FENIX_ENV"
fi

WORKDIR="$TB_HOME/fenix-workdir"
mkdir -p "$WORKDIR/.claude"
[ -f "$WORKDIR/CLAUDE.md" ] || cat > "$WORKDIR/CLAUDE.md" <<'EOF'
Eres Fenix, el orquestador residente del equipo en Buzz. Trabajas SOLO dentro
de este directorio. No tocas servicios del sistema ni credenciales. Publicas
con el CLI `buzz` y delegas segun tus team-instructions. Nada se aplica sin
aprobacion nombrada del dueno.
EOF
[ -f "$WORKDIR/.claude/settings.json" ] || cat > "$WORKDIR/.claude/settings.json" <<EOF
{
  "permissions": {
    "deny": ["Read(**/keys.json)", "Read(**/*.env)", "Bash(sudo *)"]
  }
}
EOF

# El usuario DEBE existir antes de renderizar el unit: con un TB_FENIX_USER
# inexistente, el getent de @HOME@ expande a vacio y systemd recibe un unit
# invalido que falla tarde y criptico en vez de aqui y claro.
FENIX_HOME="$(getent passwd "$TB_FENIX_USER" | cut -d: -f6)" \
  || { echo "ERROR: el usuario TB_FENIX_USER='$TB_FENIX_USER' no existe (getent passwd fallo)" >&2; exit 1; }
[ -n "$FENIX_HOME" ] || { echo "ERROR: TB_FENIX_USER='$TB_FENIX_USER' sin home en passwd" >&2; exit 1; }
sed -e "s|@USER@|$TB_FENIX_USER|" \
    -e "s|@HOME@|$FENIX_HOME|" \
    -e "s|@ENVFILE@|$FENIX_ENV|" \
    -e "s|@WORKDIR@|$WORKDIR|" \
    -e "s|@BIN_DIR@|$TB_BIN_DIR|" \
    "$ASSETS/buzz-claude.service.tmpl" | sudo tee /etc/systemd/system/buzz-claude.service >/dev/null

# ── 9. pair-relay (bind SOLO en la frontera) ─────────────────────────────────
log "pair-relay"
sed -e "s|@BIND_ADDR@|$TB_BIND_IP:$TB_PAIR_PORT|" \
    -e "s|@BIN_DIR@|$TB_BIN_DIR|" \
    "$ASSETS/buzz-pair-relay.service.tmpl" | sudo tee /etc/systemd/system/buzz-pair-relay.service >/dev/null

# ── 10. Frenos, publicador seguro y arranque ─────────────────────────────────
log "frenos y arranque"
sudo install -m 755 "$DIR/buzz-panic" "$TB_BIN_DIR/buzz-panic"
# buzz-publicar: canal de publicacion seguro de los agentes (la respuesta viaja
# por stdin, jamas interpolada en un comando — ronda de seguridad B1).
sudo install -m 755 "$DIR/publicar.sh" "$TB_BIN_DIR/buzz-publicar"
sudo systemctl daemon-reload
sudo systemctl enable --now buzz-pair-relay buzz-claude

echo
echo "MONTAJE DEL NUCLEO COMPLETO. Siguientes pasos (SKILL.md):"
echo "  1. BUZZ_AUTH_TAG de Fenix (compute_auth_tag) + systemctl restart buzz-claude"
echo "  2. $DIR/verificar.sh   (frontera M2 + identidad de imagen M3 + roster/auth M7)"
echo "  3. Onboarding humano: python3 $DIR/make-conexion.py --keys $TB_KEYS_JSON --relay-url $TB_RELAY_URL"
