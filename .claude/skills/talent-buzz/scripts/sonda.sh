#!/usr/bin/env bash
# Sonda de talent-buzz: PUERTA fail-closed. Autoriza el despliegue o explica
# exactamente que falta. NUNCA autoriza una version recortada.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=00-config.sh
source "$DIR/00-config.sh"

FALLOS=()
fallo() { FALLOS+=("$1"); }

need_cmd() {
  local cmd="$1" motivo="$2"
  command -v "$cmd" >/dev/null 2>&1 || fallo "falta '$cmd' ($motivo)"
}

# ── Base ─────────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ] || fallo "SO no soportado: $(uname -s) (se requiere Linux)"
if ! command -v systemctl >/dev/null 2>&1; then
  fallo "falta systemd (los agentes corren como unidades systemd)"
fi
need_cmd git "checkout pinneado de block/buzz"
need_cmd docker "relay en contenedores"
if command -v docker >/dev/null 2>&1; then
  docker compose version >/dev/null 2>&1 || fallo "docker sin plugin compose (docker compose version falla)"
  docker info >/dev/null 2>&1 || fallo "docker no accesible para este usuario (docker info falla)"
fi
need_cmd node "harness claude-agent-acp (npm)"
need_cmd npm "instalar @agentclientprotocol/claude-agent-acp"
need_cmd python3 "genkeys/roles/make-conexion"
need_cmd openssl "generacion de secretos del compose"
need_cmd tar "extraccion del export limpio del contexto de imagen (lib-contexto)"
need_cmd cc "enlazador C para cargo build de los binarios host (build-essential) — hallado en el ensayo e2e: la sonda no lo exigia y el montaje moria a mitad"
need_cmd curl "verificacion de readiness y frontera"
need_cmd ss "verificacion de binds"
command -v claude >/dev/null 2>&1 || fallo "falta Claude Code ('claude') con sesion iniciada: es el cerebro de Fenix"

# Disco: el checkout + build + imagenes piden holgura. Se mide sobre el
# ancestro EXISTENTE mas cercano (TB_HOME puede no existir aun) y se distingue
# "sin espacio" de "ruta no medible".
base_disco="${TB_HOME%/*}"
while [ -n "$base_disco" ] && [ ! -d "$base_disco" ]; do base_disco="${base_disco%/*}"; done
[ -n "$base_disco" ] || base_disco="/"
# `|| true`: si df FALLA (rc!=0), bajo set -e + pipefail la sustitucion
# abortaria la sonda entera y la rama "no medible" era INALCANZABLE (bug
# cazado por el caso 5 del fixture determinista, hallazgo 8): un df roto
# debe caer aqui abajo como no-medible, no matar la sonda sin explicar.
libre_kb=$(df -Pk "$base_disco" 2>/dev/null | awk 'NR==2{print $4}' || true)
if [ -z "${libre_kb:-}" ]; then
  fallo "no se pudo medir el espacio libre en $base_disco"
elif [ "$libre_kb" -lt $((15 * 1024 * 1024)) ]; then
  fallo "menos de 15 GB libres en $base_disco"
fi

# ── Red (frontera M2) ────────────────────────────────────────────────────────
case "$TB_MODE" in
  tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      fallo "modo tailscale sin el CLI 'tailscale' instalado"
    else
      TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
      if [ -z "${TS_IP:-}" ]; then
        fallo "tailscale sin IP v4 (¿tailscale up hecho? ¿sesion caducada?)"
      else
        echo "tailnet OK: IP $TS_IP"
        case "$TS_IP" in
          100.*) : ;;
          *) fallo "la IP de tailscale ($TS_IP) no esta en 100.64.0.0/10; frontera no establecible" ;;
        esac
      fi
      # Prueba negativa (verificar.sh): necesita conocer si hay OTRA interfaz.
      OTRA_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '$2!="tailscale0"{print $4}' | cut -d/ -f1 | head -1 || true)"
      if [ -n "${OTRA_IP:-}" ]; then
        echo "interfaz adicional detectada ($OTRA_IP): la prueba negativa de frontera ES OBLIGATORIA en verificar.sh"
      else
        echo "sin interfaz adicional: la frontera queda satisfecha por ausencia (se registra en la evidencia)"
      fi
    fi
    ;;
  dominio)
    [ -n "$TB_DOMAIN" ] || fallo "modo dominio sin TB_DOMAIN definido"
    if [ -n "$TB_DOMAIN" ]; then
      if command -v getent >/dev/null 2>&1 && ! getent hosts "$TB_DOMAIN" >/dev/null 2>&1; then
        fallo "TB_DOMAIN=$TB_DOMAIN no resuelve DNS todavia"
      fi
    fi
    ;;
  *) fallo "TB_MODE invalido: '$TB_MODE' (tailscale|dominio)" ;;
esac

# ── Veredicto ────────────────────────────────────────────────────────────────
if [ "${#FALLOS[@]}" -gt 0 ]; then
  echo
  echo "SONDA: RECHAZADO. Falta lo siguiente (la sonda no monta versiones recortadas):"
  for f in "${FALLOS[@]}"; do echo "  - $f"; done
  exit 1
fi
echo
echo "SONDA: AUTORIZADO (modo $TB_MODE, commit $TB_BUZZ_COMMIT)"
