#!/usr/bin/env bash
# extract-plan.sh — Extrae el PLAN del dev (regla 17), lo normaliza y lo manda al gate de plan.
# Uso: extract-plan.sh <carril> <ENC> <OUT>
#   carril = canal · ENC = el `TAL-N` del encargo (el mismo `__ISSUE__` del brief) · OUT = fichero
#   donde audit-gate.sh deja el veredicto LITERAL (para relevarlo al dev). NUNCA hardcodeados.
# Exits (el contrato de la regla 17, más el exit 21): 0 veredicto GO/NO-GO · 10 dev busy · 11 sin ancla
#   PLAN-INICIO de ESTE encargo · 12 PLAN-FIN ausente · 13 bloque ambiguo · 14 fallo del extractor ·
#   15 plan vacuo · 16 alarma de staleness · 17 gate sin veredicto · 18 chrome del TUI en el bloque ·
#   19 plan RECHAZADO, OBSOLETO o de vigencia INDETERMINADA (sin presentación nueva) · 20 plan ya APROBADO (nada que gatear) ·
#   21 el plan del diálogo pendiente (pantalla, «transcript sin volcar») es IDÉNTICO (salvo espacios en blanco) al de una ronda ya
#   AUDITADA (ledger): no se gatea otra vez. Operador: contestar el diálogo con la opción 3 pidiendo un plan distinto; no aprobar.
#   [issue 10264] 22 parada del operador vigente (el extractor y el gate se niegan a arrancar hasta una orden humana nueva) ·
#   23 el gate PARÓ por un diálogo de aprobación del auditor (rc 4 + ESCALAR): no se pulsa nada, la ronda NO se consume y
#   decide un humano en el pane del auditor.
#
# [TAL-8039] FUENTE del plan, en TRES niveles (solo cambia la fuente; el resto del bloque —awk de
# anclas, normalización, guarda de chrome, ledger— es el de siempre):
#   1. transcript de la sesión VIVA del pane dev: `ExitPlanMode.input.plan` íntegro, SOLO si el
#      ExitPlanMode es VIGENTE (pendiente de aprobación y sin mensaje humano posterior; lib.sh
#      tco_exitplan_plan_from). Con el TUI en pantalla alternada capture-pane es solo el viewport.
#   2. texto con ancla `PLAN-INICIO` del turno vigente del mismo transcript (sin ExitPlanMode
#      vigente; si hubo uno rechazado/aprobado, solo el texto POSTERIOR a él).
#   3. pantalla (capture-pane -J, escalera de scrollback): RESPALDO, con los MISMOS rechazos.
# Un nivel DISPONIBLE que responde en negativo NO cae al siguiente: plan RECHAZADO/OBSOLETO (19) o ya
# APROBADO (20), otro encargo (11), sin FIN (12), ancla anidada (13), chrome (18). Solo cae un nivel
# NO disponible (sin sesión viva, transcript ilegible, esquema alterado sin texto con ancla). Cada
# nivel loguea `origen=…`.
# ÚNICA excepción acotada: el CLI 2.1.318 no vuelca al transcript el ExitPlanMode PENDIENTE hasta que llega su
# `tool_result` (que solo da el humano al contestar el diálogo). Con el transcript en RECHAZADO u OBSOLETO y la
# sesión en `status=waiting` (lo persiste el propio CLI), el plan vigente solo existe en pantalla: UNA captura
# de detección (la escalera 2000/4000/8000 del nivel 3 solo sube si el bloque no cabe) y se cae al nivel 3 solo
# si el diálogo de plan está abierto y completo al final, con PLAN-FIN pegado a él; el bloque que se corta es
# solo el pegado al diálogo (lib.sh tco_plan_dialog_head_from). Origen logueado: `origen=pantalla (transcript
# sin volcar)`. Si ese plan es idéntico al de una ronda ya AUDITADA del ledger → exit 21; uno rechazado por el
# humano pero nunca auditado SÍ se gatea. «Idéntico» = el mismo sha256 del texto normalizado SOLO en espacios en
# blanco (espacios finales, CRLF, saltos finales): ningún signo, acento ni mayúscula se ignora. El ledger guarda
# el texto que se gateó (el de pantalla, con la sangría del TUI, o el crudo del transcript); un plan renderizado
# de pantalla contra uno crudo casi nunca casa y se audita de más, nunca de menos; el 21 sale sobre todo de
# pantalla contra pantalla. Sin `waiting`, sin captura: exit 19 como siempre.
# Nivel 3 (también el respaldo sin rc 6): el bloque cortado debe ser el ÚLTIMO de la captura (tras la ancla elegida
# solo cabe el PLAN-FIN que lo cierra); con otro PLAN-FIN después —un bloque viejo con su PLAN-FIN y un plan reciente
# con su propio PLAN-FIN pero sin ancla— sale el exit 11. Sin diálogo de plan abierto, tras el PLAN-FIN aceptado solo
# puede quedar el chrome del prompt (líneas vacías y UNA línea-resumen del turno, medido sobre la región de transcript
# encima del compositor); cualquier otro texto (un reciente sin ancla y sin PLAN-FIN) da el exit 11. Con un diálogo de
# plan abierto en el respaldo, el bloque es el pegado al diálogo, como con rc 6.
# Fail-closed; ningún nivel relaja un gate. El `.md` del plan en disco sigue PROHIBIDO como fuente.
_TCO_EP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_TCO_EP_DIR/00-config.sh"
# shellcheck source=/dev/null
. "$_TCO_EP_DIR/lib.sh"

# [Seam inyectable] El gate de plan. Se invoca por ruta del propio skill (jamás por PATH).
_tco_plan_gate() { bash "$_TCO_EP_DIR/audit-gate.sh" "$@"; }

# Delimita el bloque DE ESTE encargo: $1=ENC · stdin = captura/plan · stdout = contenido entre anclas.
#   Ancla FUERTE a inicio de línea (patrón de STOP-AUDIT) + GUARDA de bloque ambiguo: entre la última
#   PLAN-FIN previa y la INICIO elegida debe haber EXACTAMENTE una INICIO anclada.
#   rc 0 ok · 1 sin ancla DE ESTE encargo · 2 fence sin cerrar (truncado) · 3 bloque ambiguo.
_tco_plan_cut() {
  awk -v enc="$1" '
    BEGIN { ini = "^[^[:alnum:]]*PLAN-INICIO[[:space:]]+" enc "([^[:alnum:]-]|$)"
            fin = "^[^[:alnum:]]*PLAN-FIN[[:space:]]*$" }
    { l[NR]=$0; if ($0 ~ ini) s=NR; if ($0 ~ fin) isfin[NR]=1 }
    END {
      if (!s) exit 1                                   # sin ancla DE ESTE encargo
      p=0; for (i=1; i<s; i++) if (i in isfin) p=i     # última PLAN-FIN anterior al bloque
      n=0; for (i=p+1; i<=s; i++) if (l[i] ~ ini) n++
      if (n != 1) exit 3                               # bloque ambiguo (ancla anidada o en prosa)
      for (i=s+1; i<=NR; i++) { if (l[i] ~ fin) { f=1; break } print l[i] }
      if (!f) exit 2                                   # fence sin cerrar ⇒ captura truncada
    }'
}

# rc del awk -> exit del contrato (mismos mensajes de siempre). $1=rc $2=ENC $3=detalle del nivel.
_tco_plan_rc_exit() {
  case "$1" in
    1) echo "FAIL-CLOSED: sin ancla PLAN-INICIO de $2 ($3) (¿plan de OTRO encargo? caso ch04)"; return 11 ;;
    2) echo "FAIL-CLOSED: PLAN-FIN ausente ($3)";                                                return 12 ;;
    3) echo "FAIL-CLOSED: bloque ambiguo (ancla anidada/en prosa) — re-pedir presentación";      return 13 ;;
    *) echo "FAIL-CLOSED: fallo inesperado del extractor (rc=$1)";                               return 14 ;;
  esac
}

# Normalización SOLO de comparación (jamás del artefacto que va al gate): ÚNICAMENTE espacios en blanco al final
# de cada línea (cubre CRLF); los saltos de línea finales los quita la sustitución de comando de quien lee.
# NO se ignora ningún signo (`<` frente a `>`, `-` frente a `+`, `!`, `==`), ningún acento ni ninguna mayúscula:
# cambian el sentido de un plan de código. Bash ≥ 4.4 (mapfile), como el resto del canal.
_tco_plan_norm() { LC_ALL=C sed 's/[[:space:]]*$//'; }

# sha256 del texto normalizado del fichero $1; rc 1 si queda vacío (un plan vacío no iguala a nada).
_tco_plan_sha() {
  local t
  t="$(_tco_plan_norm < "$1")" || return 1
  [ -n "$t" ] || return 1
  printf '%s' "$t" | sha256sum | cut -d' ' -f1
}

# $1=plan cortado de pantalla $2=carril $3=ENC. Imprime la ronda K y rc 0 si es idéntico (mismo sha256 del texto
# normalizado en blanco) al plan de una ronda COMPLETADA del ledger (`.norm`: el texto que se gateó; una
# `.pending` no cuenta); rc 1 si no.
_tco_plan_ledger_equal() {
  local cut="$1" carril="$2" ENC="$3" scut sf f k
  local -a rounds=()
  scut="$(_tco_plan_sha "$cut")" || return 1
  # La lista se lee ENTERA antes de recorrerla (mapfile): ningún consumidor sale a mitad de la tubería.
  mapfile -t rounds < <(find "$TCO_RUNS_DIR" -maxdepth 1 -type f -name "plan-$carril-$ENC-r*.norm" 2>/dev/null | sort -V)
  for f in "${rounds[@]}"; do
    sf="$(_tco_plan_sha "$f")" || continue
    if [ "$sf" = "$scut" ]; then k="${f##*-r}"; printf '%s\n' "${k%.norm}"; return 0; fi
  done
  return 1
}

# $1=captura (la que acaba de cortarse con rc 0) $2=ENC. rc 0 si tras la ÚLTIMA ancla `PLAN-INICIO <ENC>` hay UN solo
# `PLAN-FIN` (el que cierra ese bloque): ese bloque es el último de la captura. Si hay otro `PLAN-FIN` después, el plan más
# reciente no trae su ancla y el corte habría tomado un bloque VIEJO del scrollback (falso GO): se rechaza. Un pendiente con
# ancla y sin `PLAN-FIN` no llega aquí (el corte da rc 2). Lee todas sus tuberías: grep -c y tail, ningún consumidor sale antes.
_tco_plan_block_is_last() {
  local raw="$1" ENC="$2" n nfin
  n="$(grep -nE "^[^[:alnum:]]*PLAN-INICIO[[:space:]]+${ENC}([^[:alnum:]-]|\$)" "$raw" | tail -n 1 | cut -d: -f1)"
  [ -n "$n" ] || return 1
  nfin="$(tail -n +"$n" "$raw" | grep -cE '^[^[:alnum:]]*PLAN-FIN[[:space:]]*$')"
  [ "$nfin" -eq 1 ]
}

# $1=captura (la que acaba de cortarse con rc 0) $2=ENC $3=carril. Respaldo de pantalla SIN diálogo de plan abierto: tras el
# `PLAN-FIN` que cierra el bloque cortado solo puede quedar el chrome del prompt: líneas vacías y, a lo sumo, UNA línea-resumen
# del turno (`✻ Crunched for 43s · done …` de Claude, `Worked for 43s • …` de Codex). Se mide sobre la región de transcript
# (`tco_tui_regions_from transcript`: lo que hay encima del compositor, que ya deja fuera el borde, el estado y el pie); si el
# chrome no se localiza se mide sobre la captura entera. Cualquier otro texto detrás es un plan más reciente sin ancla y sin
# `PLAN-FIN` propio (el corte habría tomado un bloque VIEJO): se rechaza. rc 0 = solo chrome. Bash ≥ 4.4 (mapfile).
_tco_plan_tail_is_chrome() {
  local raw="$1" ENC="$2" carril="$3" reg rrc=0 i s=-1 f=-1 sum=0 line
  local -a L=()
  local re_ini="^[^[:alnum:]]*PLAN-INICIO[[:space:]]+${ENC}([^[:alnum:]-]|\$)"
  local re_fin='^[^[:alnum:]]*PLAN-FIN[[:space:]]*$'
  local re_sum='^[[:space:]]*([^[:alnum:][:space:]]+)?[[:space:]]*[^[:space:]]+ for [0-9]+[hms]'
  local -x TCO_TUI_CLI=''; TCO_TUI_CLI="$(_tco_tui_cli_panel "$carril" "$(tco_pane_dev)")" || TCO_TUI_CLI=''
  reg="$(tco_tui_regions_from transcript < "$raw")" || rrc=$?
  if [ "$rrc" -eq 2 ]; then reg="$(cat "$raw")"; fi
  mapfile -t L < <(printf '%s\n' "$reg")
  for ((i = 0; i < ${#L[@]}; i++)); do
    if [[ "${L[i]}" =~ $re_ini ]]; then s=$i; fi
  done
  [ "$s" -ge 0 ] || return 1
  for ((i = s + 1; i < ${#L[@]}; i++)); do
    if [[ "${L[i]}" =~ $re_fin ]]; then f=$i; break; fi
  done
  [ "$f" -ge 0 ] || return 1
  for ((i = f + 1; i < ${#L[@]}; i++)); do
    line="${L[i]}"
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
    if [[ "$line" =~ $re_sum ]]; then
      sum=$((sum + 1))
      if [ "$sum" -le 1 ]; then continue; fi
    fi
    return 1
  done
  return 0
}

# Cuerpo; $1 = directorio temporal ya creado (lo limpia el wrapper). Devuelve el exit del contrato.
_tco_extract_plan_run() {
  local tmpd="$1" carril="$2" ENC="$3" OUT="$4"
  local RAW="$tmpd/raw" CUT="$tmpd/cut" TMPN="$tmpd/norm"
  local rc=0 trc SB LAST R PREV PEND SHA V grc=0 unrec=0 ulog=0 dlg=0 urc K

  # (0) PRECONDICIÓN — pane dev IDLE; un plan capturado a media presentación no se gatea
  if tco_pane_busy "$carril" "$(tco_pane_dev)"; then echo "dev busy: no capturar"; return 10; fi

  # (1-2) CAPTURAR + DELIMITAR. Niveles 1-2: transcript de la sesión viva (sin escalera: el plan
  #   llega íntegro). Nivel 3: pantalla, con -J (une el soft-wrap) y escalera de scrollback.
  trc=0; tco_plan_from_transcript "$carril" > "$RAW" || trc=$?
  case "$trc" in
    2) echo "FAIL-CLOSED: el plan del transcript está RECHAZADO u OBSOLETO y no hay una presentación nueva — re-pedir la presentación (ExitPlanMode)"; return 19 ;;
    3) echo "FAIL-CLOSED: el plan del transcript ya fue APROBADO — nada que gatear"; return 20 ;;
    5) echo "FAIL-CLOSED: vigencia indeterminada: línea ilegible posterior al ExitPlanMode — re-pedir la presentación (ExitPlanMode)"; return 19 ;;
    6) unrec=1; trc=1 ;;   # rechazado/obsoleto con el CLI en `waiting`: la presentación pendiente solo está en pantalla
  esac
  if [ "$trc" = 0 ]; then
    _tco_plan_cut "$ENC" < "$RAW" > "$CUT" || rc=$?
    case "$rc" in
      0) : ;;
      *) _tco_plan_rc_exit "$rc" "$ENC" "origen=transcript — el nivel disponible rechaza por contenido, sin caer a pantalla"; return $? ;;
    esac
  else
    if [ "$unrec" != 1 ]; then tco_info "$carril: plan origen=pantalla (RESPALDO: capture-pane; mismos rechazos)" >&2; fi
    for SB in 2000 4000 8000; do
      if ! tco_cap_pane "$carril" "$(tco_pane_dev)" "$SB" > "$RAW"; then : > "$RAW"; fi
      if [ "$unrec" = 1 ]; then
        # Solo vale el plan de un diálogo de plan ABIERTO y completo al final; el bloque lo delimita el propio diálogo.
        urc=0; tco_plan_dialog_head_from < "$RAW" > "$tmpd/head" || urc=$?
        case "$urc" in
          0) mv "$tmpd/head" "$RAW" || { echo "FAIL-CLOSED: no pude preparar la captura del diálogo"; return 14; }
             # El origen se loguea SOLO con el diálogo detectado (una vez), no en cada intento sin diálogo.
             [ "$ulog" = 1 ] || { tco_info "$carril: plan origen=pantalla (transcript sin volcar)" >&2; ulog=1; } ;;
          1) echo "FAIL-CLOSED: el plan del transcript está RECHAZADO u OBSOLETO y no hay una presentación nueva — re-pedir la presentación (ExitPlanMode)"; return 19 ;;
          *) _tco_plan_rc_exit 2 "$ENC" "pantalla: el plan sobre el diálogo pendiente no cierra con PLAN-FIN pegado al diálogo"; return $? ;;
        esac
      fi
      if [ "$unrec" != 1 ]; then
        # Respaldo: con un diálogo de plan ABIERTO (el ExitPlanMode pendiente no está volcado) el bloque es el pegado al
        # diálogo, con el mismo atado que con rc 6; sin diálogo, vale la regla de la cola de más abajo.
        dlg=0; urc=0; tco_plan_dialog_head_from < "$RAW" > "$tmpd/head" || urc=$?
        if [ "$urc" = 0 ]; then
          dlg=1; mv "$tmpd/head" "$RAW" || { echo "FAIL-CLOSED: no pude preparar la captura del diálogo"; return 14; }
        fi
      fi
      rc=0; _tco_plan_cut "$ENC" < "$RAW" > "$CUT" || rc=$?
      # AMBOS rc de «recorte insuficiente» suben peldaño: rc2 = falta PLAN-FIN, rc1 = falta PLAN-INICIO
      # (un ancla fuera de la ventana da rc1, NO rc2 — romper aquí dejaba planes válidos sin recuperar).
      case "$rc" in 1|2) continue ;; *) break ;; esac
    done
    case "$rc" in
      0) : ;;
      1) _tco_plan_rc_exit 1 "$ENC" "ni con SB=8000"; return $? ;;
      2) _tco_plan_rc_exit 2 "$ENC" "ni con SB=8000 (escalera agotada)"; return $? ;;
      *) _tco_plan_rc_exit "$rc" "$ENC" ""; return $? ;;
    esac
    # El bloque cortado de la pantalla tiene que ser el ÚLTIMO de la captura (también en el respaldo sin rc 6).
    if ! _tco_plan_block_is_last "$RAW" "$ENC"; then
      _tco_plan_rc_exit 1 "$ENC" "pantalla: tras ese PLAN-INICIO hay otro PLAN-FIN, el plan más reciente no trae su ancla"; return $?
    fi
    # Sin diálogo de plan abierto: tras el PLAN-FIN aceptado solo cabe el chrome del prompt (vacías y una línea-resumen).
    if [ "$unrec" != 1 ] && [ "$dlg" != 1 ] && ! _tco_plan_tail_is_chrome "$RAW" "$ENC" "$carril"; then
      _tco_plan_rc_exit 1 "$ENC" "pantalla: tras el PLAN-FIN queda texto que no es el chrome del prompt (el plan más reciente no trae su ancla, hay prosa tras el PLAN-FIN o el TUI no se localizó) — re-presentar el plan sin texto tras PLAN-FIN"; return $?
    fi
  fi

  # (3) NORMALIZAR — MÍNIMA y NO destructiva: solo padding del terminal (espacio en cola) y colapso de
  #     líneas en blanco repetidas. NADA que dependa del contenido.
  #     TCO_BUSY_REGEX es un DETECTOR DE BUSY (paso 0), NUNCA un filtro de contenido: filtrar por
  #     substring borraría líneas del plan que mencionen «plan mode on» / «bypass permissions» /
  #     «esc to interrupt» — frecuente en un plan sobre este mismo sistema.
  sed -e 's/[[:space:]]*$//' "$CUT" | cat -s > "$TMPN"

  # (3a) Con el diálogo pendiente sin volcar: un plan IDÉNTICO al de una ronda ya auditada no se gatea otra vez. Se
  #      compara el artefacto ya normalizado ($TMPN) con los `.norm` del ledger, que pasaron por la MISMA normalización.
  if [ "$unrec" = 1 ] && K="$(_tco_plan_ledger_equal "$TMPN" "$carril" "$ENC")"; then
    echo "FAIL-CLOSED: plan idéntico (salvo espacios en blanco) al de la ronda $K ya auditado — el dev lo re-presentó sin cambios; no se gatea otra vez (contestar el diálogo con la opción 3 pidiendo un plan distinto; no aprobar)"; return 21
  fi

  # (3b) GUARDA de captura sucia — chrome en su FORMA REAL Y COMPLETA, anclada `^…$`. Con el pane idle
  #      y el corte fence-a-fence no debería dispararse nunca; si lo hace, la captura no es limpia ⇒ se
  #      RE-CAPTURA. JAMÁS se borra una línea por CONTENER una frase. Deliberadamente estrecha: el
  #      parentético del footer es OBLIGATORIO y el prefijo admite glifos del TUI pero NO marcadores
  #      markdown (`- * + > . _`), para que una viñeta del plan («- plan mode on») no dispare falso
  #      positivo. Un chrome que se escape queda VISIBLE en el literal auditado; un falso positivo
  #      para un plan válido, no.
  if grep -qE '^[[:space:]]*[^[:alnum:][:space:]*+>._-]*[[:space:]]*(plan mode on|bypass permissions on)[[:space:]]*\(shift\+tab to cycle\)[[:space:]]*$|^[[:space:]]*[^[:alnum:][:space:]*+>._-]+[[:space:]]*[A-Za-z]+…?[[:space:]]*\([^)]*esc to interrupt[^)]*\)[[:space:]]*$|^[[:space:]]*\?[[:space:]]+for shortcuts[[:space:]]*$' "$TMPN"; then
    echo "FAIL-CLOSED: chrome del TUI dentro del bloque (captura sucia) — re-capturar con el pane idle"; return 18
  fi

  # (4) ANTI-VACUO
  if [ "$(wc -l < "$TMPN")" -lt 10 ]; then echo "plan vacuo (<10 líneas útiles): re-pedir presentación"; return 15; fi

  # (5) RONDA — de artefactos COMPLETADOS, por índice MÁXIMO. `find` (no un glob que falla bajo
  #     pipefail) para que la ronda 1, sin ningún .norm, NO aborte el script.
  LAST="$(find "$TCO_RUNS_DIR" -maxdepth 1 -type f -name "plan-$carril-$ENC-r*.norm" 2>/dev/null \
          | sed -n 's/.*-r\([0-9]\{1,\}\)\.norm$/\1/p' | sort -n | tail -1 || true)"
  R=$(( ${LAST:-0} + 1 ))
  PREV="$TCO_RUNS_DIR/plan-$carril-$ENC-r$((R-1)).norm"

  # (6) ALARMA DE STALENESS — contra la última ronda COMPLETADA; antes de gastar nada
  if [ "$R" -gt 1 ] && diff -q "$PREV" "$TMPN" >/dev/null 2>&1; then
    echo "ALARMA DE STALENESS: plan idéntico a la ronda $((R-1)) — gate DETENIDO, re-pedir presentación"; return 16
  fi

  # (7) LEDGER TRANSACCIONAL pending → gate → completed. La ronda se CONSUME solo con veredicto real:
  #     un gate muerto o INVALID deja `.pending` (sobrescribible) y NO envenena el contador.
  PEND="$TCO_RUNS_DIR/plan-$carril-$ENC-r$R.pending"
  mv "$TMPN" "$PEND" || { echo "FAIL-CLOSED: no pude escribir el ledger $PEND"; return 14; }
  SHA="$(sha256sum "$PEND" | cut -d' ' -f1)"          # hex ⇒ pasa tco_valid_token (lib.sh:32)
  tco_valid_token "$SHA" || { echo "FAIL-CLOSED: sha256 ilegible de $PEND"; return 14; }
  V="$(_tco_plan_gate "$carril" plan "$PEND" "$SHA" "$OUT")" || grc=$?
  case "$V" in
    GO|NO-GO) mv "$PEND" "$TCO_RUNS_DIR/plan-$carril-$ENC-r$R.norm" || { echo "FAIL-CLOSED: no pude consumir la ronda $R"; return 14; } ;;   # ronda consumida
    *)
      # [issue 10264] El gate PARÓ por un diálogo de aprobación del auditor (rc 4 + ESCALAR): no es «sin veredicto».
      if [ "$grc" = 4 ]; then
        echo "gate PARADO: diálogo de aprobación del auditor abierto; NO se pulsa nada; ronda $R NO consumida (.pending intacto); decide un humano en el pane .1 del canal $carril (3/Esc rechaza; nunca la opción 2)"; return 23
      fi
      # Parada del operador vigente: el gate se negó a arrancar y el plan NO se re-gatea hasta una orden humana nueva.
      if [ "$grc" = 22 ]; then
        echo "gate NO lanzado: parada del operador vigente en el canal $carril; ronda $R NO consumida (.pending intacto); solo una orden humana nueva la levanta (ver parada-operador-$carril.env en runs/)"; return 22
      fi
      echo "gate sin veredicto (rc=$grc, salida='$V'): ronda $R NO consumida; recuperar con
           audit-gate.sh --parse-only $carril (PROC-03) y promover el .pending solo si aparece veredicto"; return 17 ;;
  esac
  return 0
}

# API: tco_extract_plan <carril> <ENC> <OUT> -> exit del contrato (0 = veredicto GO/NO-GO en OUT).
tco_extract_plan() {
  local carril="${1:-}" ENC="${2:-}" OUT="${3:-}" tmpd rc=0
  tco_valid_token "$carril" && tco_valid_token "$ENC" && [ -n "$OUT" ] \
    || { echo "uso: extract-plan.sh <carril> <ENC> <OUT> (carril/ENC: solo [A-Za-z0-9_.-])"; return 2; }
  # [issue 10264] Parada del operador vigente: el plan no se extrae ni se gatea (exit 22), antes de tocar disco o panel.
  tco_parada_exigir "$carril" extract-plan || return $?
  tmpd="$(mktemp -d)" || { echo "FAIL-CLOSED: sin directorio temporal"; return 14; }
  mkdir -p "$TCO_RUNS_DIR"             # el ledger se usa abajo; sin esto la ronda 1 no tiene dónde vivir
  _tco_extract_plan_run "$tmpd" "$carril" "$ENC" "$OUT" || rc=$?
  rm -rf "$tmpd"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  rc=0
  # [issue 10264] Hijo vigilado: un TERM/INT/HUP al extractor mata también al gate que espera (árbol del hijo) y deja la
  # parada; USR1 es el único parón propio del coordinador (sin parada). Sin canal válido, el uso falla como siempre.
  if tco_valid_token "${1:-}"; then
    tco_correr_vigilado "$1" extract-plan -- tco_extract_plan "$@" || rc=$?
  else
    tco_extract_plan "$@" || rc=$?
  fi
  exit "$rc"
fi
