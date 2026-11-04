#!/usr/bin/env bash
# desmontar.sh — retira lo que instalo este skill. Nada mas.
#
#   sudo bash desmontar.sh              quita servicios y configuracion
#   sudo bash desmontar.sh --con-pesos  ademas borra los 22 GB de pesos
#   sudo bash desmontar.sh --dry-run    enseña lo que borraria
#
# Lo que NO toca nunca: tus preferencias de Claude Code que no pusimos nosotros, tu
# Docker, tu driver, tus otros contenedores y tu historico de consumo.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$AQUI/00-config.sh"
# shellcheck source=lib.sh
. "$AQUI/lib.sh"

CON_PESOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --con-pesos) CON_PESOS=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           morir "Opcion desconocida: $1" ;;
  esac
  shift
done

exigir_root
titulo "Retirada"

confirmar "Voy a parar y borrar los servicios de IA local. ¿Sigo?" || { info "Nada hecho."; exit 0; }

# --- servicios --------------------------------------------------------------
for u in llm-bridge llm-meter vllm nvidia-powerlimit; do
  if [ -f "/etc/systemd/system/$u.service" ]; then
    ejec systemctl disable --now "$u.service" >/dev/null 2>&1
    ejec rm -f "/etc/systemd/system/$u.service"
    ok "Servicio $u retirado"
  fi
done
ejec systemctl daemon-reload
ejec docker rm -f vllm >/dev/null 2>&1 || true

# --- Claude Code: quirurgico ------------------------------------------------
# Se quitan SOLO las claves que anadimos, anotadas al instalar. Restaurar el
# respaldo entero borraria cualquier ajuste que el alumno haya hecho despues.
ajustes="$LL_HOME/.claude/settings.json"
registro="$LL_STATE/claves-anadidas.json"
if [ -f "$ajustes" ] && [ -f "$registro" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] revertiria en %s solo lo que puso el skill (restaurando valores previos)\n' "$ajustes"
    ok "Ajustes de Claude Code revertidos sin tocar el resto"
  else
    python3 - "$ajustes" "$registro" <<'PY'
import json, sys
destino, registro = sys.argv[1], sys.argv[2]
try:
    datos = json.load(open(destino))
    previo = json.load(open(registro))
except Exception as e:
    sys.exit(f"  no toco {destino}: {e}")
env = datos.get("env", {})
borradas = restauradas = respetadas = 0
for k, info in previo.items():
    if k not in env:
        continue
    # Si el valor de ahora NO es el que dejamos, lo ha cambiado el usuario despues:
    # no es nuestro y no se toca.
    if env[k] != info.get("puesto"):
        respetadas += 1
        continue
    if info.get("existia"):
        env[k] = info.get("antes")     # devolver lo que habia
        restauradas += 1
    else:
        del env[k]                      # la creamos nosotros: fuera
        borradas += 1
if not env:
    datos.pop("env", None)
json.dump(datos, open(destino, "w"), indent=2, ensure_ascii=False)
print(f"  {borradas} claves borradas · {restauradas} devueltas a su valor anterior"
      + (f" · {respetadas} respetadas por haberlas cambiado tu" if respetadas else ""))
PY
    rc=$?
    # El registro es la UNICA fuente de que claves puso el skill y con que valor
    # previo. Si la reversion fallo (settings.json ilegible o roto), borrarlo aqui
    # deja el ajuste a medias y sin forma de repetir el intento.
    if [ "$rc" -eq 0 ]; then
      rm -f "$registro"
      ok "Ajustes de Claude Code revertidos sin tocar el resto"
    else
      warn "No he podido revertir $ajustes: conservo $registro para reintentarlo."
      info "Arregla el JSON y vuelve a lanzar la retirada."
    fi
  fi
  info "Tu copia previa sigue en $ajustes.antes-de-llm-local por si acaso"
elif [ -f "$ajustes" ]; then
  warn "No hay registro de que claves anadimos: no toco $ajustes"
  info "Si quieres revertirlo a mano, la copia esta en $ajustes.antes-de-llm-local"
fi

# --- perfiles de agente -----------------------------------------------------
for i in $(seq 1 "$N_HERMES"); do
  d="$LL_HOME/.hermes/profiles/hermes-$i"
  [ -d "$d" ] && { ejec rm -rf "$d"; ok "Puesto hermes-$i retirado"; }
done

# --- ficheros del skill -----------------------------------------------------
for f in token-meter.py tps.py anthropic-bridge.py nvidia-inference-tune.sh; do
  [ -f "$LL_PREFIX/$f" ] && ejec rm -f "$LL_PREFIX/$f"
done
[ -d "$LL_PREFIX" ] && ejec rmdir --ignore-fail-on-non-empty "$LL_PREFIX"
[ -d "$LL_ETC" ] && { ejec rm -rf "$LL_ETC"; ok "Configuracion y claves borradas"; }

# --- imagen y pesos ---------------------------------------------------------
if confirmar "¿Borro tambien la imagen del motor (unos 28 GB)?"; then
  ejec docker rmi "$VLLM_IMAGE" >/dev/null 2>&1 && ok "Imagen borrada" || warn "La imagen no estaba o esta en uso"
fi

if [ "$CON_PESOS" = "1" ]; then
  if confirmar "¿Seguro que borro los pesos de $LL_MODELS (unos 22 GB)? Volver a bajarlos lleva rato."; then
    # Ruta absoluta y comprobada: nunca un glob sobre una variable que pudiera venir vacia.
    [ -n "${LL_MODELS:-}" ] && [ -d "$LL_MODELS" ] && ejec rm -rf -- "$LL_MODELS" && ok "Pesos borrados"
  fi
else
  info "Los pesos se quedan en $LL_MODELS (usa --con-pesos para borrarlos)."
fi

info "Tu historico de consumo sigue en $LL_STATE/history — borralo tu si quieres."
printf '\n'; ok "Retirada terminada."
