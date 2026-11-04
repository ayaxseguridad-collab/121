#!/usr/bin/env bash
# pozos-rotador.sh — daemon de rotación por cuota. REGLA DEL LEAD (2026-09-01):
#   · Se gasta SIEMPRE la cuenta cuyo reset semanal (7d) está más cerca: sus tokens no gastados son tokens perdidos.
#   · Al tope de 5h de esa cuenta, los consumidores pasan a las DOS siguientes por reset (grupo A → 2ª, grupo B → 3ª).
#   · Cuando la primaria recupera (5h < 50%), todo vuelve a ella. Cuando una cuenta CRUZA su reset semanal, su reset pasa
#     a +7d y sale sola del frente de la cola (el orden se recalcula en cada ciclo desde la API, nunca de una lista fija).
#   · Solo entran pozos con token Y habilitados en el ledger (`habilitada_fabrica` ≠ false).
#   · Solo entran al ORDEN las cuentas con 5h y 7d LEGIBLES (≥0) y AMBOS resets válidos (>0): una cuota ilegible no decide
#     a quién se gasta. Las inválidas se excluyen y quedan como `SIN-LECTURA <pozo>` en el log.
# Cuota heredada Fable (no asigna modelos a roles): se lee el cubo semanal con scope «Fable» de cada cuenta y se ALERTA cuando la cuenta del CEO
#   ($SECRET_DIR/ceo-cuenta, p.ej. p4) supera ROTADOR_FABLE_CAP (90%); el CEO decide relanzar su terminal con otro token (no se automatiza: es la sesión del lead).
# Consumidores: $SECRET_DIR/consumidores.map (parseado por map_entries de pozos-lib.sh: el grupo es el ÚLTIMO campo A|B).
# INSTANCIA ÚNICA: toma un `flock -n` exclusivo sobre <estado>/rotador.lock ANTES del bucle; una segunda instancia sale con rc=3
#   sin tocar el estado (dos rotadores a la vez = carrera sobre el estado y doble relanzamiento de los consumidores).
# Estado: dir PRIVADO 0700 ${POZOS_STATE_DIR:-$SECRET_DIR/state} (NUNCA /tmp: world-readable + symlink attack).
#   rotador.state ("<primaria>" o "<A>|<B>"), .pendiente, rotador.failed, rotador.pid, rotador.lock, rotador.log y
#   usage.cache (última lectura de cuotas para la statusline).
#   Compatibilidad: si existe el estado viejo /tmp/pozos-rotador.{state,failed,state.pendiente} o /tmp/pozos-usage.cache y no
#   hay equivalente en el dir privado, se MIGRA una sola vez (solo si es fichero regular, nunca un symlink) y se borra el de /tmp.
# Fallos parciales: rotador.failed (un consumidor por línea) + log "APPLY-FALLO <consumidor>"; el ciclo siguiente reintenta SOLO esos.
. "$(dirname "$0")/pozos-lib.sh"; SD=$(cd "$(dirname "$0")" && pwd); MAP=$SECRET_DIR/consumidores.map
tco_modelos_read || exit 1
STATE_DIR=$(pozos_state_dir) || exit 2
LOG=$STATE_DIR/rotador.log; ST=$STATE_DIR/rotador.state; FAILED=$STATE_DIR/rotador.failed; LOCK=$STATE_DIR/rotador.lock; PIDF=$STATE_DIR/rotador.pid; CACHE=$STATE_DIR/usage.cache
RETRIES=$STATE_DIR/rotador.retries
CAP=${ROTADOR_CAP:-97}; BACK=${ROTADOR_BACK:-50}; EVERY=${ROTADOR_EVERY:-300}; FCAP=${ROTADOR_FABLE_CAP:-90}; CEOP=$(cat "$SECRET_DIR/ceo-cuenta" 2>/dev/null)
MAX_RETRY_CYCLES=${ROTADOR_MAX_RETRY_CYCLES:-5}  # techo del reintento parcial — ver bloque REINTENTO abajo
# migración one-shot del estado viejo de /tmp (solo ficheros regulares; un symlink se ignora y se avisa)
migra_tmp(){ local old=$1 new=$2
  [ -e "$old" ] || return 0; [ -e "$new" ] && return 0
  [ -L "$old" ] && { echo "ESTADO-INSEGURO: $old es un symlink — no lo migro" >&2; return 0; }
  [ -f "$old" ] || return 0
  state_file "$new" || return 0; cat "$old" > "$new" && rm -f "$old" && echo "MIGRADO $old → $new" >&2; }
LEGACY=${POZOS_LEGACY_TMP_PREFIX:-/tmp/pozos-rotador}   # solo para poder probar la migración sin tocar el /tmp real
migra_tmp "$LEGACY.state" "$ST"; migra_tmp "$LEGACY.state.pendiente" "$ST.pendiente"; migra_tmp "$LEGACY.failed" "$FAILED"
migra_tmp "${POZOS_LEGACY_CACHE:-/tmp/pozos-usage.cache}" "$CACHE"
for f in "$LOG" "$ST" "$ST.pendiente" "$FAILED" "$LOCK" "$PIDF" "$CACHE" "$RETRIES"; do state_file "$f" || exit 2; done
# instancia única: bloqueo exclusivo NO bloqueante antes de cualquier trabajo
exec 9>>"$LOCK" || { echo "no pude abrir $LOCK" >&2; exit 2; }
flock -n 9 || { echo "$(date +%H:%M) YA-CORRIENDO: otra instancia del rotador tiene $LOCK (pid $(cat "$PIDF" 2>/dev/null || echo '?')) — no arranco" >&2; exit 3; }
echo $$ > "$PIDF"
[ -r "$MAP" ] || { echo "$(date +%H:%M) sin $MAP — nada que rotar" | tee -a "$LOG"; exit 2; }
# apply <pozoA> <pozoB> [solo-estos-consumidores(fichero)] → instala en cada consumidor según su grupo; rc = nº de fallos
apply(){ local a=$1 b=$2 only=${3:-} tipo nombre host ct grupo tok id rc=0 pids=() ids=()
  : > "$FAILED.tmp"
  while read -r tipo nombre host ct grupo; do
    id="$tipo:$nombre"; [ -n "$only" ] && ! grep -qxF "$id" "$only" && continue
    tok=$TOKENS_DIR/$([ "$grupo" = A ] && echo "$a" || echo "$b").token
    [ -r "$tok" ] || { echo "$(date +%H:%M) APPLY-FALLO $id (token $(basename "$tok") ilegible)" | tee -a "$LOG"; echo "$id" >> "$FAILED.tmp"; continue; }
    case $tipo in
      canal)  bash "$SD/pozos-install-token.sh" "$nombre" "$tok" </dev/null >>"$LOG" 2>&1 & pids+=($!); ids+=("$id") ;;
      torre)  bash "$SD/pozos-install-token-torre.sh" "$nombre" "$tok" </dev/null >>"$LOG" 2>&1 || { echo "$(date +%H:%M) APPLY-FALLO $id" | tee -a "$LOG"; echo "$id" >> "$FAILED.tmp"; } ;;
      remoto) bash "$SD/pozos-install-token-remote.sh" "$host" "$ct" "$nombre" "$tok" </dev/null >>"$LOG" 2>&1 & pids+=($!); ids+=("$id") ;;
      *) echo "$(date +%H:%M) APPLY-FALLO $id (tipo desconocido)" | tee -a "$LOG"; echo "$id" >> "$FAILED.tmp" ;;
    esac
  done < <(map_entries "$MAP")
  local i; for i in "${!pids[@]}"; do wait "${pids[$i]}" || { echo "$(date +%H:%M) APPLY-FALLO ${ids[$i]}" | tee -a "$LOG"; echo "${ids[$i]}" >> "$FAILED.tmp"; }; done
  mv "$FAILED.tmp" "$FAILED"; rc=$(wc -l < "$FAILED"); return "$rc"; }
# rotar <pozoA> <pozoB> <estado-si-completo> <etiqueta>: aplica, y solo sella el estado si TODOS aplicaron; si no, deja el reintento armado
rotar(){ local a=$1 b=$2 newst=$3 tag=$4 n
  if apply "$a" "$b"; then echo "$(date +%H:%M) ROTADO ($tag)" | tee -a "$LOG"; echo "$newst" > "$ST"; echo "$newst" > "$ST.pendiente"
  else n=$(wc -l < "$FAILED"); echo "$(date +%H:%M) ROTACION-PARCIAL ($tag): $n consumidores sin aplicar — reintento en el próximo ciclo: $(tr '\n' ' ' < "$FAILED")" | tee -a "$LOG"; echo "$newst" > "$ST.pendiente"; fi; }
probe(){ local model salida rc; model=$(tco_modelo_read salud) && [ -n "$model" ] || return 1; [ -r "$TOKENS_DIR/$1.token" ] || { echo "SIN-TOKEN"; return 1; }; salida=$(CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKENS_DIR/$1.token") timeout 60 claude -p 'Responde solo: OK' --model "$model" 2>&1 </dev/null) && return 0; rc=$?; if printf '%s' "$salida" | grep -qi 'session limit'; then echo 'session limit'; fi; return "$rc"; }
while true; do
  tco_modelos_read || exit 1
  now=$(TZ=America/Mexico_City date +%H:%M)
  raw=$(for p in $(pozos_list_habilitados); do [ -r "$TOKENS_DIR/$p.token" ] && pozo_usage_row "$p"; sleep 2; done)
  # caché de uso para la statusline ("pozo 5h r5 7d r7 fable rfable"): en el dir privado 0700, escritura atómica, NUNCA /tmp
  ( umask 077; printf '%s\n' "$raw" > "$CACHE.tmp" ) && mv "$CACHE.tmp" "$CACHE"
  # filtro de filas USABLES: 5h y 7d legibles (≥0) y ambos resets válidos (>0); las demás se excluyen y se loguean
  rows=""; while IFS= read -r fila; do [ -n "$fila" ] || continue
    if pozo_row_valida "$fila"; then rows+="$fila"$'\n'
    else echo "$now SIN-LECTURA ${fila%% *} (5h/7d o resets ilegibles: «$fila») — fuera del orden" >> "$LOG"; fi
  done <<< "$raw"
  rows=$(printf '%s' "$rows" | sort -k5,5n)
  prim=$(echo "$rows" | head -1 | cut -d' ' -f1); u5=$(echo "$rows" | head -1 | cut -d' ' -f2); nxt=$(echo "$rows" | sed -n 2p | cut -d' ' -f1); nx2=$(echo "$rows" | sed -n 3p | cut -d' ' -f1)
  st=$(cat "$ST" 2>/dev/null); echo "$now primaria=${prim:-∅} 5h=${u5:--1}% siguientes=${nxt:-∅},${nx2:-∅} estado=${st:-∅}" >> "$LOG"
  if [ -n "$CEOP" ]; then fab=$(echo "$rows" | awk -v p="$CEOP" '$1==p{print $6}'); [ "${fab:--1}" -ge "$FCAP" ] && echo "$now FABLE-ALERTA: cuenta del CEO $CEOP Fable7d=${fab}% ≥ ${FCAP}% — relanzar la terminal CEO con el token de la siguiente cuenta por reset" | tee -a "$LOG"; fi
  if [ -z "$prim" ]; then echo "$now SIN-LECTURA: ningún pozo habilitado con token y cuota legible" >> "$LOG"; sleep "$EVERY"; continue; fi
  # reintento de un ciclo anterior que quedó parcial (mismo objetivo pendiente)
  if [ -s "$FAILED" ] && [ -r "$ST.pendiente" ]; then pend=$(cat "$ST.pendiente"); pa=${pend%%|*}; pb=${pend##*|}
     echo "$now REINTENTO parcial → $pend: $(tr '\n' ' ' < "$FAILED")" | tee -a "$LOG"
     if apply "$pa" "$pb" "$FAILED"; then
        echo "$now ROTADO (reintento completo)" | tee -a "$LOG"; echo "$pend" > "$ST"; st=$pend; : > "$RETRIES"
     else
        # M5-BOUNCE CRÍTICO-3 (TAL-5115): si el reintento sigue parcial, $ST no se sella y el
        # `st` de la línea de abajo seguiría leyendo la primaria vieja — el bloque de cuota más
        # abajo entonces podría disparar un `rotar` SIN filtro (A y B enteros), re-aplicando el
        # token a los consumidores que YA lo tenían desde el intento anterior. `continue` acota
        # el ciclo siguiente a seguir reintentando SOLO $FAILED hasta completarlos, antes de que
        # una nueva decisión de cuota pueda relanzar a los ya aplicados.
        #
        # Hallazgo CERO×2 ronda 1 (MAJOR, sobre este mismo fix): sin techo, un consumidor
        # PERMANENTEMENTE roto (contenedor borrado, torre inalcanzable) deja el `continue` de
        # abajo cortando TODOS los ciclos futuros antes de llegar al bloque de cuota — el resto
        # de la flota SANA queda pegada a una cuenta capada indefinidamente por culpa de un solo
        # consumidor que nunca va a responder. `MAX_RETRY_CYCLES` acota cuántos ciclos se
        # reintenta este MISMO batch antes de darlo por perdido: se limpia $FAILED/$ST.pendiente
        # (abandona el reintento — esos consumidores recuperan el token en la PRÓXIMA rotación
        # completa que sí los incluya), se loguea fuerte para intervención manual, y esta vuelta
        # NO hace `continue`: cae al resto del ciclo para que la flota sana no quede rehén.
        n_retry=$(( $(cat "$RETRIES" 2>/dev/null || echo 0) + 1 ))
        echo "$n_retry" > "$RETRIES"
        if [ "$n_retry" -ge "$MAX_RETRY_CYCLES" ]; then
           # CERO×2 ronda 2 (MAJOR sobre el giveup de ronda 1): limpiar SOLO $FAILED/$ST.pendiente
           # sin sellar $ST dejaba `st` apuntando a la primaria VIEJA — la misma vuelta, el bloque
           # de cuota de abajo releía esa `st` desactualizada, la condición que disparó la
           # rotación seguía vigente (nada resolvió la cuota en los ~MAX_RETRY_CYCLES×EVERY
           # transcurridos) y volvía a llamar `rotar` SIN FILTRO al mismo target — reabriendo
           # exactamente el daño de CRÍTICO-3 (kill+relanzamiento a consumidores YA aplicados),
           # ahora en bucle cada ~MAX_RETRY_CYCLES×EVERY en vez de cada ciclo. Y el propio
           # consumidor roto, nunca excluido de consumidores.map, repoblaba $FAILED de inmediato.
           # Fix: sellar $ST al target ($pend) AQUÍ MISMO — los consumidores sanos ya recibieron
           # el token; tratar el batch como "completo" evita que la MISMA transición se
           # re-dispare. El roto queda documentado en el log para intervención manual y se
           # recoge en el PRÓXIMO trigger de rotación legítimo (no en un bucle de la misma).
           echo "$now CONSUMIDOR(ES) PERMANENTEMENTE ROTO(S) tras $n_retry intentos — dados de baja de ESTA rotación (requiere intervención manual), estado sellado a $pend con los consumidores sanos ya aplicados: $(tr '\n' ' ' < "$FAILED")" | tee -a "$LOG"
           echo "$pend" > "$ST"; st=$pend
           : > "$FAILED"; rm -f "$ST.pendiente"; : > "$RETRIES"
        else
           echo "$now ROTACION-PARCIAL (reintento $n_retry/$MAX_RETRY_CYCLES): siguen sin aplicar $(tr '\n' ' ' < "$FAILED")" | tee -a "$LOG"
           sleep "$EVERY"; continue
        fi
     fi
  fi
  if [ "$st" != "$prim" ] && [ "$st" != "$nxt|$nx2" ]; then # cambio de primaria (reset cruzado o arranque) → todos a la primaria si no está capada
     if [ "$u5" -lt "$CAP" ]; then echo "$now ROTANDO todo a $prim (nueva primaria por reset semanal)" | tee -a "$LOG"; rotar "$prim" "$prim" "$prim" "todo a $prim"; fi
  fi
  st=$(cat "$ST" 2>/dev/null)
  if [ "$st" = "$prim" ] && { [ "$u5" -ge "$CAP" ] || probe "$prim" | grep -qi 'session limit'; }; then
     if [ -z "$nxt" ]; then echo "$now SIN-ALTERNATIVA: $prim capada al ${u5}% y no hay otro pozo habilitado con token — decisión del lead (créditos o esperar reset)" | tee -a "$LOG"
     else [ -z "$nx2" ] && { nx2=$nxt; echo "$now solo hay una alternativa: A y B van a $nxt" >> "$LOG"; }
          echo "$now ROTANDO: $prim al ${u5}% → A=$nxt B=$nx2" | tee -a "$LOG"; rotar "$nxt" "$nx2" "$nxt|$nx2" "$prim capada"; fi
  elif [ "$st" != "$prim" ] && [ "$u5" -ge 0 ] && [ "$u5" -lt "$BACK" ] && probe "$prim" >/dev/null; then
     echo "$now VOLVIENDO a $prim (5h al ${u5}%)" | tee -a "$LOG"; rotar "$prim" "$prim" "$prim" "vuelta a $prim"
  fi
  sleep "$EVERY"
done
