#!/usr/bin/env bash
# mutantes-behavior-watch.sh — Runner de mutantes del selftest de behavior-watch.
#
# Por fila: copia los skills a un temporal, NEUTRALIZA la condición anclada (`# C:<ANCLA>`) con su sed,
# acredita la mutación con cmp (el fichero cambió) y la presencia de cada ancla, y corre el selftest de la
# COPIA. Exige rc 1, el caso nombrado en rojo, y que ningún caso fuera de «nombrado ∪ colateral declarado»
# enrojezca (el rojo es causal). Un ancla ausente o una mutación que no cambia nada = NO MEDIDO, nunca verde.
# rc 0 = las 43 filas cayeron por su caso · rc 1 = algún superviviente, rojo no causal o NO MEDIDO.
set -uo pipefail
SK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # raíz de skills (paquete: skills/, instalado: .claude/skills/)
T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "${T:?}"' EXIT

# Campos separados por «~» (el sed contiene «|»): id ~ fichero (relativo a talent-channel-operation/scripts) ~ anclas ~
# sed ~ debe caer ~ colateral declarado ('*' = cualquiera) ~ NO MEDIDO si el caso nombrado queda verde
FILAS=$(cat <<'EOF'
MU-P1~behavior-watch.sh~P1~/# C:P1$/ s/elif \[ "\$live" = idle \]; then verdict=SANO; rc=1/elif false; then :/~N-P1-IDLE~TEXTO-IDLE-NEUTRO TEXTO-IDLE-CMD~
MU-UNK~behavior-watch.sh~UNK~/# C:UNK$/ s/verdict=UNKNOWN; rc=2/verdict=SANO; rc=0/~N-P1-UNK P2-IV~STATE-SIN-CARRIL CPU-ILEGIBLE GIT-ILEGIBLE CPU-CORTADA SUB-ILEGIBLE CPU-PGREP-ROTO SUB-PADRE-000 SUB-PADRE-600 CPU-PGREP-NIETO CPU-PID-MUERTO SUB-ENLACE-CERRADO SID-ENLACE-CERRADO SUB-JSONL-ENLACE CPU-STAT-AUSENTE CPU-STAT-ILEGIBLE~
MU-P2~behavior-watch.sh~P2~/# C:P2$/ s/elif \[ "\$p2rc" != 0 \]; then verdict=SANO; rc=0/elif false; then :/~N-P2-NO~N-P2-TERM N-P2-PR P2-III W-AUSENTE W-CERRADO~
MU-P2-TERM~lib.sh~P2-TERM~/# C:P2-TERM$/ s/printf '%s %s terminal\\n' "\$run" "\$ph"; return 1/:/~N-P2-TERM~W-CERRADO~
MU-P2-PR~lib.sh~P2-PR~/# C:P2-PR$/ s/printf '%s %s pr_\(merged\|closed\)\\n' "\$run" "\$ph"; return 1/:/~N-P2-PR~P2-III P2-CLOSED~
MU-STALL-1~behavior-watch.sh~STALL-1~/# C:STALL-1$/ s/c1=y || c1=n/c1=y || c1=y/~N-STALL-1~THINKING-LARGO POLLING-LOG FUENTE-NO-ESENCIAL N-SUBAGENTE N-SUBAGENTE-ENLACE~
MU-STALL-2~behavior-watch.sh~STALL-2~/# C:STALL-2$/ s/c2=y || c2=n/c2=y || c2=y/~N-STALL-2~N-STALL-2-PORCELAIN N-STALL-2-VENTANA~
MU-STALL-3~behavior-watch.sh~STALL-3~/# C:STALL-3$/ s/then c3=y; else c3=n; fi/then c3=y; else c3=y; fi/~N-STALL-3~GATE-VIVO~
MU-LOCK~behavior-watch.sh~LOCK~/# C:LOCK$/ { s/flock -[sx] -w 30 9/true/; s/then write=0; fi/then :; fi/ }~C-CONCURRENTE~~
MU-SELLO~behavior-watch.sh~SELLO~/# C:SELLO$/ s/if \[ "\$src" = 0 \] || \[ "\$src" = 3 \]; then/if true; then/~SELLO-RC2~~
MU-VACIO~behavior-watch.sh~VACIO~/# C:VACIO$/ s/^bw_main() { # C:VACIO$/bw_main() { echo "behavior: SANO · rc 0"; return 0; # C:VACIO/~POS-STALL~*~
MU-W-SIN-CARRIL~run-state-write.sh~W-KEYS~/# C:W-KEYS / s/{carril: \$c, phase: \$p, ts: \$t}/{phase: $p, ts: $t}/~W-KNOWN~W-CERRADO W-FAILSOFT F-LLENO W-INVALIDO W-OTRO-TAL W-CONCURRENTE W-ATOMICO~
MU-W-CLAVE-EXTRA~run-state-write.sh~W-KEYS W-KEYS-EXACTAS~/# C:W-KEYS / s/ts: \$t}/ts: $t, user: "u"}/; /C:W-KEYS-EXACTAS/ s/keys == \["carril","phase","ts"\] and //~W-KNOWN~W-CONCURRENTE~
MU-W-SIN-FICHERO~lib.sh~W-NOSTATE~/# C:W-NOSTATE$/ s/printf 'no - no_state\\n'; return 1/printf 'no - ok\\n'; return 0/~W-AUSENTE~N-P2-NO~
MU-W-CIERRE-ACTIVO~run-state-write.sh~W-CLOSE~/C:W-CLOSE$/ s/--arg p "\$phase"/--arg p active/~W-CERRADO~~
MU-W-RC1~run-state-write.sh~W-FAILSOFT~/# C:W-FAILSOFT$/ s/exit 0; }/exit 1; }/~W-FAILSOFT~F-LLENO W-INVALIDO W-NUEVO-FALLA~
MU-W-SIN-RC-ESCRITURA~run-state-write.sh~W-WRITE-RC W-VALIDA~/# C:W-WRITE-RC$/ s/ || _rsw_fallo "[^"]*"//; /# C:W-VALIDA / s/ || _rsw_fallo "[^"]*"//~F-LLENO~W-INVALIDO W-NUEVO-FALLA~
MU-W-SIN-VALIDAR~run-state-write.sh~W-VALIDA~/# C:W-VALIDA / s/ || _rsw_fallo "el temporal no valida[^"]*"/ || true/~W-INVALIDO~~
MU-W-RECORRE~run-state-write.sh~W-SOLO-TAL~/# C:W-SOLO-TAL$/ a for o in "$runs"/*/state.json; do [ -f "$o" ] \&\& printf '{}' > "$o"; done~W-OTRO-TAL~F-LLENO W-FAILSOFT W-INVALIDO W-CONCURRENTE~
MU-W-SIN-TEMPORAL~run-state-write.sh~W-TMP~/# C:W-TMP$/ s/^tmp=.*$/${TCO_RSW_WRITE_CMD:-printf %s\\\\n} "$json" > "$sj"; exit 0   # C:W-TMP/~W-CONCURRENTE~W-FAILSOFT F-LLENO W-INVALIDO W-KNOWN W-CERRADO W-OTRO-TAL W-ATOMICO W-NUEVO-FALLA~W-CONCURRENTE
MU-W-DETECTOR-ESCRIBE~behavior-watch.sh~W-DET-RO~/# C:W-DET-RO / s/p2rc=\$?/p2rc=$?; for o in "$TCO_RUNS_DIR"\/*\/state.json; do [ -f "$o" ] \&\& printf ' ' >> "$o"; done/~W-RUNS-INTACTO~~
MU-STALL-2-VENTANA~behavior-watch.sh~STALL-2~/# C:STALL-2$/ s/-ge "\$TC_STALL_WINDOW" \] \&\& c2=y/-ge 1 ] \&\& c2=y/~N-STALL-2-VENTANA~~
MU-GIT-ILEGIBLE~behavior-watch.sh~STALL-2~/# C:STALL-2$/ s/c2=y || c2=n; fi/c2=y || c2=n; fi; [ -n "$g_since" ] || c2=y/~GIT-ILEGIBLE~~
MU-FIN~lib.sh~FIN~/# C:FIN$/ s/|| return 1   # C:FIN/|| true   # C:FIN/~CPU-CORTADA~~
MU-SUBAGENTE~behavior-watch.sh~SUBAG~/# C:SUBAG$/ s/bytes=\$(( bytes + sub ))/bytes=$bytes/~N-SUBAGENTE~N-SUBAGENTE-ENLACE~
MU-SUB-ILEGIBLE~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/ || exit 1/ || :/g~SUB-ILEGIBLE~SUB-PADRE-000 SUB-PADRE-600 F-PROY-000 F-PROY-600 SUB-JSONL-ENLACE~
MU-SUB-RAMA~behavior-watch.sh~SUBAG~/# C:SUBAG$/ s/else bytes=''; fi/else :; fi/~SUB-ILEGIBLE~SUB-PADRE-000 SUB-PADRE-600 SUB-ENLACE-CERRADO SID-ENLACE-CERRADO SUB-JSONL-ENLACE~
MU-PGREP~lib.sh~PGREP~/C:PGREP$/ s/\[ \$? -le 1 \] || return 1; //~CPU-PGREP-ROTO~CPU-PGREP-NIETO~
MU-SUB-PADRE~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/\[ -d \\"\\$s\\" \] && \[ -x \\"\\$s\\" \] || exit 1/:/~SUB-PADRE-000 SUB-PADRE-600~~
MU-PGREP-PROF~lib.sh~PGREP~/C:PGREP$/ s/d "\$h" || return 1/d "$h"/~CPU-PGREP-NIETO~~
MU-PID~lib.sh~PGREP~/C:PGREP$/ s#\[ -d /proc/'"\$pid"' \] || exit 1; ##~CPU-PID-MUERTO~~
MU-ENLACE~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/find -H /find /g~N-SUBAGENTE-ENLACE~~
MU-PROY~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/\[ -d \\"\\$b\\" \] && \[ -x \\"\\$b\\" \] || exit 1/:/~F-PROY-000 F-PROY-600~~
MU-ENLACE-D~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/\[ -L \\"\\$d\\" \] && exit 1; //~SUB-ENLACE-CERRADO~~
MU-ENLACE-S~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/\[ -L \\"\\$s\\" \] && exit 1; //~SID-ENLACE-CERRADO~~
MU-JSONL~behavior-watch.sh~SUB-LEE~/# C:SUB-LEE$/ s/ \[ -z \\"\\$n\\" \] || exit 1;//~SUB-JSONL-ENLACE~~
MU-W-ENUM-ABIERTO~run-state-write.sh~W-ENUM~/# C:W-ENUM$/ s/in active|done|cancelled|superseded|bounced|delivered) : ;;/in *) : ;;/; /C:W-ENUM$/ s/ and (.phase | IN([^)]*))//~W-ENUM~W-FAILSOFT~
MU-RC21~behavior-watch.sh~RC22~/# C:RC22$/ s/rc=22/rc=21/~C11~*~
MU-ATOMICO~run-state-write.sh~W-STAGING~/# C:W-STAGING$/ s#/\.stg\.XXXXXX#/stg.XXXXXX#~W-ATOMICO~~
MU-TEXTO~behavior-watch.sh~INFLIGHT~/# C:INFLIGHT$/ s/tco_transcript_pending_tool_from/tco_transcript_inflight_from/~TEXTO-IDLE-NEUTRO~~
MU-PENDIENTE~lib.sh~NO-TEXTO~/# C:NO-TEXTO$/ s/> 0 then/> 99 then/~IDLE-HERRAMIENTA-PENDIENTE~~
MU-STAT~lib.sh~STAT~/# C:STAT C:PGREP$/ s#elif \[ -d /proc/\$p \]; then exit 1; fi#elif false; then :; fi#~CPU-STAT-AUSENTE CPU-STAT-ILEGIBLE~~
MU-REPORT-CREA~behavior-watch.sh~REPORT-NUEVO~/# C:REPORT-NUEVO$/ s/ \&\& \[ "\$report" = 0 \]//~REPORT-NUEVO~~
EOF
)

total=0; cayeron=0; malos=0
while IFS='~' read -r id fich anclas sedx debe colat nm_si_verde; do
  [ -n "$id" ] || continue
  total=$((total+1))
  rm -rf -- "${T:?}/sk"; mkdir -p "$T/sk"
  cp -a "$SK/talent-channel-operation" "$SK/talent-ceo" "$T/sk/"
  f="$T/sk/talent-channel-operation/scripts/$fich"
  falta=''
  for a in $anclas; do grep -qE "C:$a( |$)" "$f" || falta="$falta $a"; done
  if [ -n "$falta" ]; then printf 'NO-MEDIDO %s: ancla ausente:%s\n' "$id" "$falta"; malos=$((malos+1)); continue; fi
  cp "$f" "$T/orig"
  sed -i "$sedx" "$f"
  if cmp -s "$T/orig" "$f"; then printf 'NO-MEDIDO %s: la mutación no cambió %s\n' "$id" "$fich"; malos=$((malos+1)); continue; fi
  bash "$T/sk/talent-channel-operation/scripts/selftest-behavior-watch.sh" > "$T/out" 2>&1; rc=$?
  rojos="$(sed -n 's/^FAIL \([A-Z0-9-]*\): .*/\1/p' "$T/out" | sort -u | tr '\n' ' ')"
  estado=CAE
  [ "$rc" = 1 ] || estado="SOBREVIVE (rc $rc)"
  for c in $debe; do
    case " $rojos " in *" $c "*) ;; *)
      if [ -n "$nm_si_verde" ] && [ "$c" = "$nm_si_verde" ]; then estado="NO-MEDIDO ($c quedó verde en esta corrida)"
      else estado="SOBREVIVE ($c no enrojece)"; fi ;;
    esac
  done
  if [ "$colat" != '*' ] && [ "$estado" = CAE ]; then
    for r in $rojos; do
      case " $debe $colat " in *" $r "*) ;; *) estado="ROJO-NO-CAUSAL ($r fuera de lo declarado)" ;; esac
    done
  fi
  printf '%s %s: rc %s · debe caer [%s] · rojos [%s]\n' "$estado" "$id" "$rc" "$debe" "${rojos% }"
  [ "$estado" = CAE ] || grep '^FAIL ' "$T/out" | head -8 | sed 's/^/    detalle: /'
  if [ "$estado" = CAE ]; then cayeron=$((cayeron+1)); else malos=$((malos+1)); fi
done <<<"$FILAS"

# Comodines de colateral: solo los dos de los mutantes globales (MU-VACIO, MU-RC21); un defecto local no puede saltarse la causalidad.
[ "$(printf '%s\n' "$FILAS" | grep -cE '^([^~]*~){5}\*~[^~]*$')" -le 2 ] || { echo "COMODINES: más de 2 filas con colateral '*'"; exit 1; }
printf '\nMUTANTES: %s/%s caen por su caso · %s superviviente(s), rojo(s) no causal(es) o NO MEDIDO\n' "$cayeron" "$total" "$malos"
[ "$total" -eq 43 ] && [ "$cayeron" -eq 43 ] || exit 1
exit 0
