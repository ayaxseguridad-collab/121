#!/usr/bin/env bash
# banco.sh — mide TU maquina. Los numeros de la documentacion son de otra.
#
#   bash banco.sh
#
# Mide cuatro cosas y las guarda en ~/llm-local/banco-<fecha>.txt:
#   1. velocidad con un solo cliente
#   2. velocidad con los 5 clientes a la vez (que es para lo que esta montado esto)
#   3. lectura del contexto (prefill) a TRES tamanios — es una curva, no una cifra:
#      se degrada al crecer el contexto porque la atencion es cuadratica
#   4. cache de prefijo: el mismo contexto reenviado, que es como trabajan los agentes
#
# El texto de las tiradas de lectura es ALEATORIO Y UNICO en cada corrida: un banco
# que repite texto mide el cache, no la maquina. Los tokens de entrada se toman del
# usage que devuelve el servidor, no de una estimacion por caracteres.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$AQUI/00-config.sh"
# shellcheck source=lib.sh
. "$AQUI/lib.sh"

[ -r "$KEYS_FILE" ] || morir "No puedo leer las claves de $KEYS_FILE." \
  "Si el montaje esta hecho, prueba con sudo."
# shellcheck disable=SC1090
. "$KEYS_FILE"

BASE="http://$BIND_ADDR:$PORT_MEDIDOR/v1/chat/completions"
SALIDA="$LL_STATE/banco-$(date +%Y%m%d-%H%M).txt"
mkdir -p "$LL_STATE"

# Una peticion; imprime "tokens segundos"
tirada() {
  local clave="$1" n_out="$2" prompt="$3" t0 t1 r cfg rc
  cfg="$(conf_clave "$clave")"
  t0="$(date +%s.%N)"
  r="$(curl -sf --max-time 600 "$BASE" --config "$cfg" \
       -H 'content-type: application/json' \
       -d "$(python3 -c '
import json,sys
print(json.dumps({"model": sys.argv[1], "max_tokens": int(sys.argv[2]),
                  "temperature": 0.7,
                  "messages": [{"role":"user","content": sys.argv[3]}]}))
' "$SERVED_NAME" "$n_out" "$prompt")")"
  rc=$?
  rm -f "$cfg"
  [ "$rc" -eq 0 ] || { printf '0 0\n'; return 1; }
  t1="$(date +%s.%N)"
  python3 -c '
import json,sys
d = json.loads(sys.argv[1]); u = d.get("usage") or {}
print(u.get("completion_tokens", 0), "%.2f" % (float(sys.argv[3]) - float(sys.argv[2])))
' "$r" "$t0" "$t1"
}

titulo "Banco — cuanto rinde TU maquina"
info "Modelo: $SERVED_NAME · $(nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd' + ')"
printf '\n'

# ------------------------------------------------------------------ calentamiento
info "Calentando (la primera peticion siempre es lenta: compila los grafos)…"
tirada "$VLLM_API_KEY" 64 "Di hola." >/dev/null

# ------------------------------------------------------------------ 1 cliente
info "1) Un solo cliente, 400 tokens de respuesta…"
read -r tok seg < <(tirada "$VLLM_API_KEY" 400 \
  "Escribe una explicacion de 400 palabras sobre por que el cielo es azul.")
UNO="$(python3 -c "print('%.1f' % ($tok/max($seg,0.001)))")"
ok "$UNO tokens/segundo  ($tok tokens en ${seg}s)"

# ------------------------------------------------------------------ 5 clientes
info "2) Los 5 clientes a la vez (lo que de verdad importa con agentes)…"
tmp="$(mktemp -d)"
CLAVES=("$VLLM_API_KEY")
for i in $(seq 1 "$N_HERMES"); do v="HERMES_KEY_$i"; CLAVES+=("${!v}"); done
t0="$(date +%s.%N)"
for i in "${!CLAVES[@]}"; do
  ( tirada "${CLAVES[$i]}" 400 "Explica en 400 palabras el concepto numero $i de la termodinamica." \
    >"$tmp/$i" ) &
done
wait
t1="$(date +%s.%N)"
TOTAL_TOK=0
for i in "${!CLAVES[@]}"; do read -r t _ <"$tmp/$i"; TOTAL_TOK=$((TOTAL_TOK + t)); done
PARED="$(python3 -c "print('%.2f' % ($t1 - $t0))")"
AGREGADO="$(python3 -c "print('%.1f' % ($TOTAL_TOK/max($PARED,0.001)))")"
CADA="$(python3 -c "print('%.1f' % ($AGREGADO/${#CLAVES[@]}))")"
rm -rf "$tmp"
ok "$AGREGADO tokens/segundo agregados · unos $CADA por cliente"

# ------------------------------------------------------------------ lectura (curva)
# Mismo endpoint y metodo con el que se midio la curva de referencia: /v1/completions
# con prompt crudo (el medidor lo retransmite igual que el chat). Los prompts largos van
# por fichero: un argumento de 100k tokens revienta el limite de argv del sistema
# (128 KB por argumento), y ademas asi el texto nunca pasa por `ps`.
BASE_COMP="http://$BIND_ADDR:$PORT_MEDIDOR/v1/completions"
tirada_larga() {  # $1=clave $2=fichero_prompt $3=max_tokens → "prompt_tok segundos"
  local clave="$1" fich="$2" n_out="$3" body t0 t1 r cfg rc
  body="$(mktemp)"
  python3 - "$SERVED_NAME" "$n_out" "$fich" >"$body" <<'PY'
import json, sys
with open(sys.argv[3]) as f:
    prompt = f.read()
print(json.dumps({"model": sys.argv[1], "max_tokens": int(sys.argv[2]),
                  "temperature": 0.7, "prompt": prompt}))
PY
  cfg="$(conf_clave "$clave")"
  t0="$(date +%s.%N)"
  r="$(curl -sf --max-time 600 "$BASE_COMP" --config "$cfg" \
       -H 'content-type: application/json' --data-binary "@$body")"
  rc=$?
  rm -f "$body" "$cfg"
  [ "$rc" -eq 0 ] || { printf '0 0\n'; return 1; }
  t1="$(date +%s.%N)"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); u = d.get("usage") or {}
print(u.get("prompt_tokens", 0), "%.2f" % (float(sys.argv[3]) - float(sys.argv[2])))
' "$r" "$t0" "$t1"
}

texto_unico() {  # $1=numero_de_palabras $2=fichero_destino — palabras aleatorias unicas
  python3 - "$1" "$2" <<'PY'
import random, string, sys
r = random.SystemRandom()
def palabra():
    return "".join(r.choice(string.ascii_lowercase) for _ in range(r.randint(3, 9)))
with open(sys.argv[2], "w") as f:
    f.write(" ".join(palabra() for _ in range(max(1, int(sys.argv[1])))))
PY
}

info "3) Lectura de contexto a tres tamanios (texto unico: repetirlo mediria el cache)…"
# Calibracion: cuantos tokens salen de N palabras aleatorias NO se puede suponer (las
# palabras inventadas tokenizan a ~3 tokens cada una, no a ~1,3 como el texto normal;
# suponerlo nos descuadro el objetivo un 150% la primera vez). Se mide con una sonda
# y el conteo real del servidor.
CAL_FILE="$(mktemp)"
texto_unico 200 "$CAL_FILE"
read -r CAL_PTOK _ < <(tirada_larga "$VLLM_API_KEY" "$CAL_FILE" 1) || true
rm -f "$CAL_FILE"
[ "${CAL_PTOK:-0}" -gt 0 ] || morir "La sonda de calibracion no respondio." \
  "¿Esta el medidor arriba?  curl -s localhost:$PORT_MEDIDOR/stats"

CURVA_FILE="$(mktemp)"
PROMPT_100K="$(mktemp)"
FRIO_100K=""
for objetivo in 4000 32000 100000; do
  tmp_prompt="$PROMPT_100K"
  [ "$objetivo" -eq 100000 ] || tmp_prompt="$(mktemp)"
  texto_unico "$((objetivo * 200 / CAL_PTOK))" "$tmp_prompt"
  if read -r ptok seg < <(tirada_larga "$VLLM_API_KEY" "$tmp_prompt" 8) \
     && [ "${ptok:-0}" -gt 0 ]; then
    v="$(python3 -c "print('%.0f' % ($ptok/max($seg,0.001)))")"
    printf '  %4sk   %s tok/s  (%s tok en %ss)\n' "$((objetivo/1000))" "$v" "$ptok" "$seg" \
      >>"$CURVA_FILE"
    [ "$objetivo" -eq 100000 ] && FRIO_100K="$seg"
    ok "$((objetivo/1000))k: $v tok/s leyendo"
  else
    printf '  %4sk   FALLO\n' "$((objetivo/1000))" >>"$CURVA_FILE"
    info "$((objetivo/1000))k: fallo la tirada (¿contexto del servidor mas corto?)"
  fi
  [ "$objetivo" -eq 100000 ] || rm -f "$tmp_prompt"
done

# ------------------------------------------------------------------ cache de prefijo
CACHE_LINEA="cache de prefijo   (sin dato: fallo la tirada de 100k)"
if [ -n "$FRIO_100K" ]; then
  info "4) Cache de prefijo: la misma conversacion de 100k mas un turno nuevo…"
  # La tirada anterior dejo el prefijo calculado. Se reenvia CRECIDO con un turno nuevo
  # (~2k tokens unicos), que es exactamente lo que hace un agente: el cache absorbe lo
  # viejo y solo se paga lo nuevo. Reenviar identico daria un factor mayor pero irreal.
  TURNO="$(mktemp)"
  texto_unico "$((2000 * 200 / CAL_PTOK))" "$TURNO"
  cat "$TURNO" >>"$PROMPT_100K"
  rm -f "$TURNO"
  if read -r _ seg_c < <(tirada_larga "$VLLM_API_KEY" "$PROMPT_100K" 8) \
     && [ "$(python3 -c "print(1 if $seg_c > 0 else 0)")" -eq 1 ]; then
    FACTOR="$(python3 -c "print('%.0f' % ($FRIO_100K/max($seg_c,0.001)))")"
    CACHE_LINEA="$(printf 'cache de prefijo   100k en frio %ss · +1 turno nuevo %ss  (%sx)' \
      "$FRIO_100K" "$seg_c" "$FACTOR")"
    ok "en frio ${FRIO_100K}s → con turno nuevo ${seg_c}s (${FACTOR}x)"
  fi
fi
rm -f "$PROMPT_100K"

# ------------------------------------------------------------------ informe
{
  printf 'Banco de IA local — %s\n' "$(date -Iseconds)"
  printf 'GPU:    %s\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd' + ')"
  printf 'Modelo: %s\n\n' "$MODEL_ID"
  printf '1 cliente          %s tok/s\n' "$UNO"
  printf '5 clientes         %s tok/s agregados (~%s cada uno)\n\n' "$AGREGADO" "$CADA"
  printf 'lectura de contexto (texto unico, tokens reales del servidor):\n'
  cat "$CURVA_FILE"
  printf '%s\n\n' "$CACHE_LINEA"
  printf 'Referencia (2x RTX 5060 Ti, este mismo script sobre la maquina donde se roda):\n'
  printf '  1 cliente 127-135 · 5 clientes ~359 agregados (~72 cada uno)\n'
  printf '  lectura ~5400 tok/s a 4k · ~4950 a 32k · ~3650 a 100k (la curva baja: es normal)\n'
  printf '  cache de prefijo: 100k en frio ~27s · +1 turno nuevo ~1,3s (20x)\n'
  printf '\nSi tus numeros son bastante peores con el mismo hardware, mira el limite de\n'
  printf 'potencia y la temperatura:  nvidia-smi --query-gpu=enforced.power.limit,temperature.gpu --format=csv\n'
  printf 'Y si van lentos solo cuando OTRO usuario trabaja, no es averia: es el cache\n'
  printf 'compartido y la cola (ver referencias 05 y 06 del skill).\n'
} | tee "$SALIDA"
rm -f "$CURVA_FILE"

printf '\n'; ok "Guardado en $SALIDA"
