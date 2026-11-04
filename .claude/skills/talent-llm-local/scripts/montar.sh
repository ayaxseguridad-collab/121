#!/usr/bin/env bash
# montar.sh — deja la maquina con IA local igual que la de referencia.
#
#   sudo bash montar.sh                 monta todo
#   sudo bash montar.sh --dry-run       enseña lo que haria, sin tocar nada
#   sudo bash montar.sh --only servicio corre una sola fase
#   sudo bash montar.sh --from puente   retoma desde una fase
#   sudo bash montar.sh --sin-puente    salta la integracion con Claude Code
#   bash montar.sh --help
#
# Reentrante e idempotente: correrlo dos veces no duplica unidades, claves,
# perfiles ni bloques de configuracion.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$AQUI/.." && pwd)"
# shellcheck source=00-config.sh
. "$AQUI/00-config.sh"
# shellcheck source=lib.sh
. "$AQUI/lib.sh"

FASES=(sonda requisitos claves motor modelo servicio medidor puente claude hermes verificar banco)
# 'claves' va antes que 'servicio' porque el medidor las necesita ya escritas, y
# 'servicio' antes que 'medidor' porque el medidor lee la clave interna del motor.

SOLO=""; DESDE=""; SIN_PUENTE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --only)       [ -n "${2:-}" ] || morir "--only necesita el nombre de una fase" "Fases: ${FASES[*]}"
                  SOLO="$2"; shift ;;
    --from)       [ -n "${2:-}" ] || morir "--from necesita el nombre de una fase" "Fases: ${FASES[*]}"
                  DESDE="$2"; shift ;;
    --sin-puente) SIN_PUENTE=1 ;;
    # se exporta porque quien la consume es `confirmar`, en lib.sh
    --si)         export LL_ASUMIR_SI=1 ;;
    -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            morir "Opcion desconocida: $1" "Prueba con:  bash $0 --help" ;;
  esac
  shift
done
export DRY_RUN

toca() {
  local f="$1"
  [ -n "$SOLO" ] && { [ "$f" = "$SOLO" ]; return; }
  if [ -n "$DESDE" ]; then
    local vista=0
    for x in "${FASES[@]}"; do
      [ "$x" = "$DESDE" ] && vista=1
      [ "$x" = "$f" ] && { [ "$vista" = 1 ]; return; }
    done
    return 1
  fi
  return 0
}

# ===================================================================== fases

fase_sonda() {
  titulo "1/12 · Sonda — ¿llega esta maquina?"
  bash "$AQUI/sonda.sh" || morir "La sonda ha rechazado esta maquina." \
    "El montaje no sigue. Los motivos estan arriba, uno por uno." \
    "Que queda fuera y por que:  references/01-requisitos-y-sonda.md"
}

fase_requisitos() {
  titulo "2/12 · Requisitos — Docker y NVIDIA Container Toolkit"
  exigir_root

  if tiene docker; then
    ok "Docker ya esta:  $(docker --version | sed 's/,.*//')"
  else
    confirmar "Docker no esta instalado. ¿Lo instalo?" || morir \
      "Sin Docker no hay motor: vLLM corre en contenedor."
    info "Instalando Docker desde el repositorio oficial…"
    ejecc install -m 0755 -d /etc/apt/keyrings
    ejecc bash -c 'curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
    ejecc chmod a+r /etc/apt/keyrings/docker.gpg
    # El origen depende de la distribucion: poner el de Ubuntu en Debian instala un
    # repositorio que no existe. Se deriva de /etc/os-release, no se da por supuesto.
    ejecc bash -c '
      . /etc/os-release
      printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n" \
        "$(dpkg --print-architecture)" "$ID" "${UBUNTU_CODENAME:-$VERSION_CODENAME}" \
        > /etc/apt/sources.list.d/docker.list'
    ejecc apt-get update -qq
    ejecc apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ejecc systemctl enable --now docker
    ok "Docker instalado."
  fi

  if tiene nvidia-ctk; then
    ok "NVIDIA Container Toolkit ya esta."
  else
    confirmar "Falta el NVIDIA Container Toolkit. ¿Lo instalo?" || morir \
      "Sin el toolkit, el contenedor no ve las GPU."
    info "Instalando el NVIDIA Container Toolkit…"
    ejecc bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
    ejecc bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list'
    ejecc apt-get update -qq
    ejecc apt-get install -y nvidia-container-toolkit
    ejecc nvidia-ctk runtime configure --runtime=docker
    ejecc systemctl restart docker
    ok "Toolkit instalado y Docker reconfigurado."
  fi

  # Prueba real: que un contenedor VEA las tarjetas. Que los paquetes esten
  # instalados no demuestra que el runtime funcione.
  if [ "$DRY_RUN" != "1" ]; then
    # Tiene que LISTAR las tarjetas. Un contenedor que arranca y sale con exito no
    # demuestra nada sobre el acceso a GPU, y decir "correcto" ahi seria enganioso.
    if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
      if docker run --rm --runtime nvidia --gpus all --entrypoint nvidia-smi "$VLLM_IMAGE" -L >/dev/null 2>&1; then
        ok "El contenedor ve las GPU."
      else
        morir "El contenedor NO ve las GPU." \
          "Los paquetes estan, pero el runtime no expone las tarjetas." \
          "Prueba a mano:  docker run --rm --runtime nvidia --gpus all --entrypoint nvidia-smi $VLLM_IMAGE -L" \
          "Suele arreglarse con:  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
      fi
    else
      info "El acceso a GPU desde contenedor se comprobara al descargar la imagen."
    fi
  fi
}

fase_claves() {
  titulo "3/12 · Claves — una por usuario, generadas aqui"
  exigir_root

  if [ -f "$KEYS_FILE" ] && grep -q '^VLLM_API_KEY=' "$KEYS_FILE"; then
    ok "Ya hay claves en $KEYS_FILE — se conservan (correr esto dos veces no las rota)."
    return 0
  fi

  local lead; lead="$(clave_nueva sk-lead)"
  local hermes=() alias_map="$lead=tu sesion"
  for i in $(seq 1 "$N_HERMES"); do
    local k; k="$(clave_nueva "sk-hermes-$i")"
    hermes+=("$k"); alias_map="$alias_map;$k=hermes-$i"
  done

  {
    printf '# Claves de tu servidor local. NO salen de esta maquina y no van a ningun repositorio.\n'
    printf '# Generadas al azar el %s. Para rotarlas: borra este fichero y vuelve a correr la fase.\n\n' "$(date -Iseconds)"
    printf 'VLLM_API_KEY=%s\n' "$lead"
    printf 'STATS_KEY=%s\n' "$lead"
    for i in $(seq 1 "$N_HERMES"); do printf 'HERMES_KEY_%d=%s\n' "$i" "${hermes[$((i-1))]}"; done
    # Entrecomillado a proposito: el valor lleva espacios y ';'. Sin comillas,
    # `source claves.env` parte la linea e intenta EJECUTAR el resto como ordenes.
    # systemd tambien acepta el entrecomillado en EnvironmentFile (quita las comillas).
    printf "ALIAS_MAP='%s'\n" "$alias_map"
  } | escribir "$KEYS_FILE" 0640

  # 0640 root:<usuario>: systemd la lee como root antes de bajar privilegios, y tu
  # usuario puede consultarla para configurar clientes a mano. El resto del sistema no.
  ejecc chgrp "$(id -gn "$LL_USER")" "$KEYS_FILE"
  if [ "$DRY_RUN" = "1" ]; then
    omit "En dry-run no se generan claves de verdad."
  else
    ok "$((1 + N_HERMES)) claves generadas en $KEYS_FILE (modo 0640)."
  fi
}

fase_motor() {
  titulo "4/12 · Motor — imagen de vLLM fijada por digest"
  exigir_root
  info "Descargando $VLLM_IMAGE"
  info "(etiqueta equivalente: $VLLM_VERSION — el digest es el que manda)"
  ejec docker pull "$VLLM_IMAGE" || morir "No se ha podido descargar la imagen." \
    "Comprueba la conexion y que Docker funciona:  docker info"
  [ "$DRY_RUN" = "1" ] && omit "En dry-run no se descarga la imagen." || ok "Imagen lista."
}

fase_modelo() {
  titulo "5/12 · Modelo — pesos de $MODEL_ID"
  exigir_root
  ejecc mkdir -p "$LL_MODELS"

  if [ "$DRY_RUN" != "1" ] && [ -n "$(find "$LL_MODELS" -name '*.safetensors' -print -quit 2>/dev/null)" ]; then
    ok "Los pesos ya estan en $LL_MODELS."
    return 0
  fi

  info "Son unos 22 GB. La primera vez tarda; solo pasa una vez."
  # Se descarga con la red ABIERTA. El HF_HUB_OFFLINE del entorno del servicio se
  # aplica despues: sirve para que los arranques del dia a dia no salgan a internet,
  # pero impediria esta descarga inicial.
  ejec docker run --rm \
    -v "$LL_MODELS:/root/.cache/huggingface" \
    --entrypoint python3 "$VLLM_IMAGE" \
    -c "from huggingface_hub import snapshot_download; snapshot_download('$MODEL_ID')" \
    || morir "No se han podido descargar los pesos." \
       "Si el fallo es de espacio, mira cuanto queda:  df -h $LL_MODELS"
  [ "$DRY_RUN" = "1" ] && omit "En dry-run no se descargan los pesos." || ok "Pesos descargados."
}

fase_servicio() {
  titulo "6/12 · Servicio del motor"
  exigir_root
  cargar_claves

  # Clave INTERNA del motor. Es la unica que el motor conoce, y solo vive en este
  # fichero (modo 0600). No se rota al re-ejecutar: si cambiase aqui y el medidor no
  # se reiniciara a la vez, el medidor quedaria hablando con una clave vieja.
  if [ -r "$ENV_FILE" ] && grep -q '^UPSTREAM_KEY=' "$ENV_FILE" 2>/dev/null; then
    UPSTREAM_KEY="$(grep -m1 '^UPSTREAM_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  else
    UPSTREAM_KEY="$(clave_nueva sk-interna)"
  fi
  export UPSTREAM_KEY

  plantilla "$SKILL/assets/vllm.env.tmpl" "$ENV_FILE" 0600
  plantilla "$SKILL/assets/vllm.service.tmpl" /etc/systemd/system/vllm.service 0644

  if [ "$APLICAR_POWER_LIMIT" = "si" ]; then
    ejecc install -D -m 0755 "$SKILL/assets/nvidia-inference-tune.sh" "$LL_PREFIX/nvidia-inference-tune.sh"
    plantilla "$SKILL/assets/nvidia-powerlimit.service.tmpl" /etc/systemd/system/nvidia-powerlimit.service 0644
    ejecc systemctl daemon-reload
    ejecc systemctl enable --now nvidia-powerlimit.service
    # El limite es su propio criterio: si no queda aplicado se dice, y NO se
    # disfraza de "persistencia completa" mas adelante.
    if [ "$DRY_RUN" = "1" ]; then
      omit "En dry-run no se aplica el limite de potencia."
    elif systemctl is-active --quiet nvidia-powerlimit.service; then
      ok "Limite de potencia aplicado (${POWER_LIMIT_W} W en todas las tarjetas)."
    else
      warn "El limite de potencia no ha quedado aplicado. El motor va a arrancar igual,"
      warn "pero las GPU corren sin limitar. Detalle:  systemctl status nvidia-powerlimit"
    fi
  else
    omit "Limite de potencia desactivado por configuracion."
  fi

  ejecc systemctl daemon-reload
  ejecc systemctl enable --now vllm.service
  if [ "$DRY_RUN" != "1" ]; then
    info "Arrancando el motor. La primera vez tarda unos 2-3 minutos (compila los grafos)."
    esperar_http "http://$BIND_ADDR:$PORT_MOTOR/health" 420 \
      && ok "Motor respondiendo en $BIND_ADDR:$PORT_MOTOR" \
      || morir "El motor no ha llegado a responder." \
         "Mira que dice:  journalctl -u vllm -n 80 --no-pager" \
         "Averias frecuentes:  references/07-averias.md"
  fi
}

fase_medidor() {
  titulo "7/12 · Medidor y monitor"
  exigir_root
  ejecc install -D -m 0755 "$SKILL/assets/token-meter.py" "$LL_PREFIX/token-meter.py"
  ejecc install -D -m 0755 "$SKILL/assets/tps.py"         "$LL_PREFIX/tps.py"
  ejecc install -d -o "$LL_USER" -m 0755 "$LL_STATE" "$LL_STATE/history"
  plantilla "$SKILL/assets/llm-meter.service.tmpl" /etc/systemd/system/llm-meter.service 0644
  ejecc systemctl daemon-reload
  ejecc systemctl enable --now llm-meter.service
  if [ "$DRY_RUN" != "1" ]; then
    esperar_http "http://$BIND_ADDR:$PORT_MEDIDOR/stats" 30 \
      && ok "Medidor en $BIND_ADDR:$PORT_MEDIDOR — consulta con:  curl -s localhost:$PORT_MEDIDOR/stats" \
      || warn "El medidor no responde todavia:  journalctl -u llm-meter -n 40 --no-pager"
  fi
}

fase_puente() {
  titulo "8/12 · Puente Anthropic (opcional)"
  if [ "$SIN_PUENTE" = "1" ]; then
    omit "Saltado por --sin-puente."
    info "Quedan el motor (sirviendo $SERVED_NAME), el medidor y los puestos de agente."
    warn "Los alias qwen y qwent NO: los da el puente. Sin el, el modo pensante se pide"
    warn "con chat_template_kwargs.enable_thinking (ver references/05 §6)."
    return 0
  fi
  exigir_root
  ejecc install -D -m 0755 "$SKILL/assets/anthropic-bridge.py" "$LL_PREFIX/anthropic-bridge.py"
  plantilla "$SKILL/assets/llm-bridge.service.tmpl" /etc/systemd/system/llm-bridge.service 0644
  ejecc systemctl daemon-reload
  ejecc systemctl enable --now llm-bridge.service
  if [ "$DRY_RUN" != "1" ]; then
    sleep 2
    systemctl is-active --quiet llm-bridge.service \
      && ok "Puente en $BIND_ADDR:$PORT_PUENTE" \
      || warn "El puente no ha arrancado:  journalctl -u llm-bridge -n 40 --no-pager"
  fi
}

fase_claude() {
  titulo "9/12 · Claude Code — el modelo local en /model (opcional)"
  if [ "$SIN_PUENTE" = "1" ]; then omit "Saltado junto con el puente."; return 0; fi

  local ajustes="$LL_HOME/.claude/settings.json"
  if [ ! -d "$LL_HOME/.claude" ]; then
    omit "No hay Claude Code en esta maquina ($LL_HOME/.claude no existe)."
    info "El resto del montaje funciona igual. Si lo instalas luego:  sudo bash $0 --only claude"
    return 0
  fi

  # Copia de seguridad UNA sola vez: si se corre dos veces, la segunda no debe
  # pisar el respaldo del original con el ya modificado.
  if [ -f "$ajustes" ] && [ ! -f "$ajustes.antes-de-llm-local" ] && [ "$DRY_RUN" != "1" ]; then
    cp -a "$ajustes" "$ajustes.antes-de-llm-local"
    ok "Copia de tus ajustes en $ajustes.antes-de-llm-local"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] anadiria a %s las claves env: ANTHROPIC_BASE_URL, ANTHROPIC_CUSTOM_MODEL_OPTION*, CLAUDE_CODE_ATTRIBUTION_HEADER\n' "$ajustes"
    return 0
  fi

  render "$SKILL/assets/claude-settings.snippet.json" >"$LL_STATE/.snippet.json" \
    || morir "No se ha podido generar el fragmento de ajustes de Claude Code."

  python3 - "$ajustes" "$LL_STATE/.snippet.json" "$LL_STATE/claves-anadidas.json" <<'PY'
import json, os, sys
destino, fragmento, registro = sys.argv[1], sys.argv[2], sys.argv[3]
actual = {}
if os.path.exists(destino):
    try:
        actual = json.load(open(destino))
    except json.JSONDecodeError:
        sys.exit("settings.json no es JSON valido; no lo toco. Revisalo a mano.")
nuevo = json.load(open(fragmento))
env = actual.setdefault("env", {})

# Para cada clave se anota si YA EXISTIA y con que valor. Sin eso, la retirada
# borraria ajustes que el alumno tenia antes de instalar nada — p. ej. su propio
# ANTHROPIC_BASE_URL apuntando a otro sitio. Se guarda tambien el valor que
# ponemos, para no pisar despues un cambio que haya hecho el a mano.
if os.path.exists(registro):
    previo = json.load(open(registro))       # una reinstalacion no pisa el original
else:
    previo = {k: {"existia": k in env, "antes": env.get(k)} for k in nuevo["env"]}
for k, v in nuevo["env"].items():
    previo.setdefault(k, {"existia": k in env, "antes": env.get(k)})
    previo[k]["puesto"] = v

env.update(nuevo["env"])
json.dump(actual, open(destino, "w"), indent=2, ensure_ascii=False)
json.dump(previo, open(registro, "w"), indent=2, ensure_ascii=False)

nuevas = sum(1 for v in previo.values() if not v["existia"])
pisadas = [k for k, v in previo.items() if v["existia"] and v["antes"] != v["puesto"]]
print(f"  {nuevas} claves nuevas, {len(previo)-nuevas} ya existian")
if pisadas:
    print(f"  valores anteriores guardados para: {', '.join(pisadas)}")
    print("  (la retirada los devuelve tal cual estaban)")
PY
  # El bloque de arriba sale distinto de cero si settings.json no es JSON valido.
  # Sin comprobarlo, la integracion quedaria sin hacer y el montaje diria que fue bien.
  local rc=$?
  rm -f "$LL_STATE/.snippet.json"
  [ "$rc" -eq 0 ] || morir "No he podido escribir en $ajustes." \
    "Tu settings.json no es JSON valido; no lo toco para no empeorarlo." \
    "Arreglalo (o renombralo) y repite solo esta fase:  sudo bash $0 --only claude"
  chown "$LL_USER" "$LL_STATE/claves-anadidas.json" 2>/dev/null || true

  ok "Listo. En una sesion NUEVA de Claude Code:  /model  ->  «$MODELO_NOMBRE»"
  info "Alias que puedes teclear:  /model qwen  (rapido)  ·  /model qwent  (pensante)"
  warn "NO anadas ANTHROPIC_AUTH_TOKEN ni ANTHROPIC_API_KEY: anularian tu suscripcion."
}

fase_hermes() {
  titulo "10/12 · Cuatro puestos de agente"
  cargar_claves

  if ! sudo -u "$LL_USER" bash -lc 'command -v hermes' >/dev/null 2>&1; then
    warn "Hermes no esta instalado. Dejo los perfiles escritos igualmente."
    info "Para instalarlo:  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
  fi

  for i in $(seq 1 "$N_HERMES"); do
    local dir var
    export NOMBRE="hermes-$i" CONTEXT_LENGTH=131072
    var="HERMES_KEY_$i"; export API_KEY="${!var}"
    dir="$LL_HOME/.hermes/profiles/$NOMBRE"
    plantilla "$SKILL/assets/hermes-profile.yaml.tmpl" "$dir/config.yaml" 0600
    [ "$DRY_RUN" != "1" ] && chown -R "$LL_USER" "$LL_HOME/.hermes" 2>/dev/null || true
  done
  [ "$DRY_RUN" = "1" ] && omit "En dry-run no se escriben los perfiles." \
    || ok "$N_HERMES puestos configurados, cada uno con su clave y su directorio de datos."
  info "Uso:  hermes-1 chat        ·  desatendido:  hermes-1 chat -Q -q \"...\""
  warn "Nunca dos instancias sobre el mismo directorio de datos: corrompe el estado."
}

VERIFICACION_FALLIDA=0
fase_verificar() {
  titulo "11/12 · Verificacion"
  [ "$DRY_RUN" = "1" ] && { omit "En dry-run no hay nada montado que verificar."; return 0; }
  # Un FALLO del nucleo se propaga al codigo de salida del instalador. Degradarlo a
  # aviso y seguir hasta imprimir "Montaje terminado" seria declarar exito sobre una
  # maquina que no funciona.
  bash "$AQUI/verificar.sh" || VERIFICACION_FALLIDA=1
}

fase_banco() {
  titulo "12/12 · Mide TU maquina"
  [ "$DRY_RUN" = "1" ] && { omit "En dry-run no se mide."; return 0; }
  info "Los numeros de la documentacion son de 2x RTX 5060 Ti. Los tuyos salen de aqui:"
  info "  bash $AQUI/banco.sh"
}

# Carga las claves. En dry-run, si aun no existen (o no se puede leer el fichero
# porque esto va sin administrador), usa marcadores: asi se puede previsualizar el
# montaje entero sin haber generado nada todavia.
cargar_claves() {
  if [ -r "$KEYS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$KEYS_FILE"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    # Solo se simulan las claves que ESTE script consume (las de los puestos de
    # agente). La del motor la lee su propio fichero de entorno, no montar.sh.
    for i in $(seq 1 "$N_HERMES"); do eval "HERMES_KEY_$i=sk-hermes-$i-EJEMPLO"; done
    warn "Todavia no hay claves: se enseñan marcadores. Las reales se generan al montar."
    return 0
  fi
  morir "Faltan las claves." "Corre antes:  sudo bash $0 --only claves"
}

# Renderiza una plantilla a su destino y PARA si algo falla. `render | escribir` sin
# comprobar deja pasar en silencio una plantilla con un marcador sin valor, y la unidad
# resultante seria basura con aspecto de correcta.
#
# Se renderiza primero a un temporal: `escribir` trunca el destino ANTES de que el
# pipe termine, asi que si `render` fallase a mitad, un destino que ya tenia una
# unidad valida quedaria en 0 bytes aunque el montaje pare aqui. Renderizar aparte
# y solo escribir si salio bien deja el destino intacto ante un fallo.
plantilla() {
  local origen="$1" destino="$2" modo="${3:-0644}"
  local tmp; tmp="$(mktemp)"
  render "$origen" >"$tmp" \
    || { rm -f "$tmp"; morir "No se ha podido generar $destino desde $(basename "$origen")." \
         "Suele ser un valor de configuracion sin definir. El montaje para aqui."; }
  escribir "$destino" "$modo" <"$tmp"
  rm -f "$tmp"
}

# ------------------------------------------------------ sustitucion de plantillas
# Reemplaza @@VAR@@ por el valor de la variable del mismo nombre.
render() {
  local f="$1"
  python3 - "$f" <<'PY'
import os, re, sys
texto = open(sys.argv[1]).read()
faltan = []
def sub(m):
    v = os.environ.get(m.group(1))
    if v is None:
        faltan.append(m.group(1))
        return m.group(0)
    return v
salida = re.sub(r"@@(\w+)@@", sub, texto)
if faltan:
    sys.exit("plantilla %s: sin valor para %s" % (sys.argv[1], ", ".join(sorted(set(faltan)))))
sys.stdout.write(salida)
PY
}

# Las plantillas leen del entorno, asi que se exporta lo que consumen.
export LL_USER LL_HOME LL_PREFIX LL_ETC LL_STATE LL_MODELS ENV_FILE KEYS_FILE
export VLLM_IMAGE VLLM_VERSION MODEL_ID SERVED_NAME TP_SIZE MAX_MODEL_LEN MAX_NUM_SEQS
export GPU_MEM_UTIL MOE_BACKEND BIND_ADDR PORT_MOTOR PORT_MEDIDOR PORT_PUENTE
export LOCAL_MODEL_ID LOCAL_THINK_MODEL_ID THINK_MIN_TOKENS POWER_LIMIT_W N_HERMES
MODELO_NOMBRE="${MODELO_NOMBRE:-Qwen3.6 35B (local)}"
MODELO_DESC="${MODELO_DESC:-Tu propio modelo, corriendo en tus GPU}"
export MODELO_NOMBRE MODELO_DESC

# ===================================================================== marcha
if [ -n "$SOLO" ]; then
  printf '%s\n' "${FASES[@]}" | grep -qx "$SOLO" \
    || morir "Fase desconocida: $SOLO" "Fases: ${FASES[*]}"
fi
if [ -n "$DESDE" ]; then
  printf '%s\n' "${FASES[@]}" | grep -qx "$DESDE" \
    || morir "Fase desconocida: $DESDE" "Fases: ${FASES[*]}"
fi
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN: no se toca nada. Solo se enseña lo que se haria."

for f in "${FASES[@]}"; do
  toca "$f" && "fase_$f"
done

printf '\n'
if [ "${VERIFICACION_FALLIDA:-0}" = "1" ]; then
  fail "Montaje INCOMPLETO: la verificacion del nucleo ha fallado."
  printf '\n  Cada fallo aparece arriba con el comando que lo arregla. Cuando lo tengas,\n'
  printf '  vuelve a lanzar el montaje: es reentrante y no duplica nada.\n'
  printf '  Si no encuentras la causa:  references/07-averias.md\n\n'
  exit 1
fi
ok "Montaje terminado."
printf '\n  Que hacer ahora:\n'
printf '    · Abre una sesion NUEVA de Claude Code y elige el modelo con /model\n'
printf '    · Mide tu maquina:   bash %s/banco.sh\n' "$AQUI"
printf '    · Mira el consumo:   curl -s localhost:%s/stats | python3 -m json.tool\n' "$PORT_MEDIDOR"
printf '    · Ideas de proyectos: references/08-que-hacer-con-ella.md\n\n'
