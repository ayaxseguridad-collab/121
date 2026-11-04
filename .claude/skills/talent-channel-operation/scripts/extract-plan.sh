#!/usr/bin/env bash
# extract-plan.sh — Extrae el PLAN del dev (regla 17), lo normaliza y lo manda al gate de plan.
# Uso: extract-plan.sh <carril> <ENC> <OUT>
#   carril = canal · ENC = el `TAL-N` del encargo (el mismo `__ISSUE__` del brief) · OUT = fichero
#   donde audit-gate.sh deja el veredicto LITERAL (para relevarlo al dev). NUNCA hardcodeados.
# Exits (el contrato de la regla 17, sin cambios): 0 veredicto GO/NO-GO · 10 dev busy · 11 sin ancla
#   PLAN-INICIO de ESTE encargo · 12 PLAN-FIN ausente · 13 bloque ambiguo · 14 fallo del extractor ·
#   15 plan vacuo · 16 alarma de staleness · 17 gate sin veredicto · 18 chrome del TUI en el bloque ·
#   19 plan RECHAZADO, OBSOLETO o de vigencia INDETERMINADA (sin presentación nueva) · 20 plan ya APROBADO (nada que gatear).
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

# Cuerpo; $1 = directorio temporal ya creado (lo limpia el wrapper). Devuelve el exit del contrato.
_tco_extract_plan_run() {
  local tmpd="$1" carril="$2" ENC="$3" OUT="$4"
  local RAW="$tmpd/raw" CUT="$tmpd/cut" TMPN="$tmpd/norm"
  local rc=0 trc SB LAST R PREV PEND SHA V grc=0

  # (0) PRECONDICIÓN — pane dev IDLE; un plan capturado a media presentación no se gatea
  if tco_pane_busy "$carril" "$(tco_pane_dev)"; then echo "dev busy: no capturar"; return 10; fi

  # (1-2) CAPTURAR + DELIMITAR. Niveles 1-2: transcript de la sesión viva (sin escalera: el plan
  #   llega íntegro). Nivel 3: pantalla, con -J (une el soft-wrap) y escalera de scrollback.
  trc=0; tco_plan_from_transcript "$carril" > "$RAW" || trc=$?
  case "$trc" in
    2) echo "FAIL-CLOSED: el plan del transcript está RECHAZADO u OBSOLETO y no hay una presentación nueva — re-pedir la presentación (ExitPlanMode)"; return 19 ;;
    3) echo "FAIL-CLOSED: el plan del transcript ya fue APROBADO — nada que gatear"; return 20 ;;
    5) echo "FAIL-CLOSED: vigencia indeterminada: línea ilegible posterior al ExitPlanMode — re-pedir la presentación (ExitPlanMode)"; return 19 ;;
  esac
  if [ "$trc" = 0 ]; then
    _tco_plan_cut "$ENC" < "$RAW" > "$CUT" || rc=$?
    case "$rc" in
      0) : ;;
      *) _tco_plan_rc_exit "$rc" "$ENC" "origen=transcript — el nivel disponible rechaza por contenido, sin caer a pantalla"; return $? ;;
    esac
  else
    tco_info "$carril: plan origen=pantalla (RESPALDO: capture-pane; mismos rechazos)" >&2
    for SB in 2000 4000 8000; do
      if ! tco_cap_pane "$carril" "$(tco_pane_dev)" "$SB" > "$RAW"; then : > "$RAW"; fi
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
  fi

  # (3) NORMALIZAR — MÍNIMA y NO destructiva: solo padding del terminal (espacio en cola) y colapso de
  #     líneas en blanco repetidas. NADA que dependa del contenido.
  #     TCO_BUSY_REGEX es un DETECTOR DE BUSY (paso 0), NUNCA un filtro de contenido: filtrar por
  #     substring borraría líneas del plan que mencionen «plan mode on» / «bypass permissions» /
  #     «esc to interrupt» — frecuente en un plan sobre este mismo sistema.
  sed -e 's/[[:space:]]*$//' "$CUT" | cat -s > "$TMPN"

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
    *) echo "gate sin veredicto (rc=$grc, salida='$V'): ronda $R NO consumida; recuperar con
           audit-gate.sh --parse-only $carril (PROC-03) y promover el .pending solo si aparece veredicto"; return 17 ;;
  esac
  return 0
}

# API: tco_extract_plan <carril> <ENC> <OUT> -> exit del contrato (0 = veredicto GO/NO-GO en OUT).
tco_extract_plan() {
  local carril="${1:-}" ENC="${2:-}" OUT="${3:-}" tmpd rc=0
  tco_valid_token "$carril" && tco_valid_token "$ENC" && [ -n "$OUT" ] \
    || { echo "uso: extract-plan.sh <carril> <ENC> <OUT> (carril/ENC: solo [A-Za-z0-9_.-])"; return 2; }
  tmpd="$(mktemp -d)" || { echo "FAIL-CLOSED: sin directorio temporal"; return 14; }
  mkdir -p "$TCO_RUNS_DIR"             # el ledger se usa abajo; sin esto la ronda 1 no tiene dónde vivir
  _tco_extract_plan_run "$tmpd" "$carril" "$ENC" "$OUT" || rc=$?
  rm -rf "$tmpd"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  rc=0
  tco_extract_plan "$@" || rc=$?
  exit "$rc"
fi
