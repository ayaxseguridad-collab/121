#!/usr/bin/env bash
# audit-gate.sh — Envía un artefacto (plan|code) al panel de auditoría con run_id+artifact_sha,
# espera el bloque JSON de veredicto y lo parsea. Imprime GO|NO-GO|INVALID (stdout = SOLO el veredicto).
# [issue 10264] Imprime también ESCALAR (rc 4): el auditor tiene abierto un diálogo de aprobación; el gate PARA sin pulsar
# nada y decide un humano en el panel. rc 22: parada del operador vigente (ver tco_parada_exigir en lib.sh).
# Escribe el veredicto LITERAL de la auditoría en $OUT (para relevarlo de vuelta al dev).
# INVARIANTE (lead 2026-06-28): el literal de auditoría SIEMPRE se releva al dev — también en GO
# (el GO suele traer sugerencias NO bloqueantes que el dev debe incorporar). Sin excepciones.
# [v5] Doctrina commit-antes-de-auditar: en type=code el artifact_sha debe ser un COMMIT real del
# repo del carril (el head futuro del PR — así M8/shaok atan). Si no lo es: warn + el auditor lee
# el working tree, y ese GO NO es apto para merge-gate (TCO_AUDIT_REQUIRE_COMMIT=yes lo hace fatal).
# [v5] Recuperación: la corrida persiste run_id/sha en $TCO_RUNS_DIR/audit-last-<carril>.env; si el
# gate muere pero el auditor SÍ emitió el veredicto, `audit-gate.sh --parse-only <carril>` lo
# recupera del scrollback (por nonce run_id — un veredicto viejo no matchea).
# Uso: audit-gate.sh <carril> <plan|code> <literalfile> <artifact_sha> <out_verdict_file>
#      audit-gate.sh --parse-only <carril> [run_id] [artifact_sha] [out]
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/00-config.sh"; . "$HERE/lib.sh"

# [v5] Guarda el LITERAL del veredicto desde una captura (desde la ÚLTIMA 'Veredicto' si existe;
# si no, las últimas líneas no vacías). Extraído para reutilizarlo en loop/sweep/--parse-only.
tco_save_verdict_literal() { # capture outfile
  if printf '%s' "$1" | grep -qi 'veredicto'; then
    # [CR #547] awk case-insensitive ALINEADO con el guard grep -qi: un "VEREDICTO" en mayúsculas
    # matcheaba el guard pero no el awk → literal VACÍO relevado al dev (rompía la invariante).
    printf '%s' "$1" | awk 'tolower($0) ~ /veredicto/{last=NR} {l[NR]=$0} END{if(last) for(i=last;i<=NR;i++) print l[i]}' > "$2"
  else
    printf '%s' "$1" | grep -v '^$' | tail -40 > "$2"
  fi
}

# [v5/B11] SWEEP de scrollback amplio buscando el veredicto atado al nonce run_id+sha. Primero el
# parser canónico (GO|NO-GO); si nada, el parser ReportFindings (tco_parse_verdict_rf — SOLO puede
# producir NO-GO, asimetría anti-bypass B6: un GO en formato laxo es INVALID siempre). Inmune a
# veredictos viejos retenidos tras recycle/compact: el nonce es único por corrida.
# Imprime GO|NO-GO por stdout y guarda el literal en $5. rc 1 = nada recuperable.
tco_sweep_verdict() { # carril pane run sha out [scrollback=5000]
  local scr v
  scr="$(tco_cap_pane "$1" "$2" "${6:-5000}" 2>/dev/null || true)"
  v="$(printf '%s' "$scr" | tco_parse_verdict "$3" "$4" || true)"
  if [ "$v" = GO ] || [ "$v" = NO-GO ]; then
    tco_save_verdict_literal "$scr" "$5"
    printf '%s' "$v"; return 0
  fi
  v="$(printf '%s' "$scr" | tco_parse_verdict_rf "$3" "$4" || true)"
  if [ "$v" = NO-GO ]; then
    tco_err "TRAZA [B14]: veredicto recuperado en formato ReportFindings (CONFIRMED⇒NO-GO) — revisar el pane; el GO canónico sigue exigiendo el bloque JSON"
    tco_save_verdict_literal "$scr" "$5"
    printf 'NO-GO'; return 0
  fi
  return 1
}

# [R9011/B2] CALIFICACIÓN de lo auditado, ligada a la corrida: audit-last-<carril>.calificacion = RUN_ID, SHA y AUDITADO
# (commit | working-tree | no-aplica). Va en un fichero HERMANO y no en audit-last-<carril>.env porque ese registro lo
# conserva la acreditación de F8 con un esquema CERRADO de cuatro líneas (instalacion/scripts/originales.py). Quien archiva
# un GO como revisión del head (verify-code-audit-go.sh --archivar) exige AUDITADO=commit de ESTA corrida; lo demás es «no».
tco_audit_qualify() { # carril run sha auditado
  printf 'RUN_ID=%s\nSHA=%s\nAUDITADO=%s\n' "$2" "$3" "$4" | tco_atomic_write "$TCO_RUNS_DIR/audit-last-$1.calificacion"
}

# [R9011b/B2-R] Escritura ATÓMICA de un fichero de la corrida: el contenido (stdin) va a un temporal OCULTO del MISMO directorio
# y se renombra con mv (rename(2), atómico) sobre el destino. Quien lea el destino ve la versión anterior completa o la nueva
# completa, nunca un fichero a medias ni vacío; los temporales ocultos no casan con ningún audit-last-*. El permiso es el de
# la umask (mktemp crea con 600). Si algo falla, el temporal se borra y el destino queda como estaba (rc 1).
tco_atomic_write() { # destino  (contenido por stdin)
  local dest="$1" tmp mode
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
  printf -v mode '%o' $(( 0666 & ~0$(umask) ))
  if cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp"; return 1
}

tco_audit_once() { # carril type literalfile sha outfile
  local carril="$1" typ="$2" lit="$3" sha="$4" out="$5"
  # [issue 10264] Parada del operador vigente: ni modelo, ni pane, ni nada. rc 22 (también para quien nos llame con `source`).
  tco_parada_exigir "$carril" audit-gate || return $?
  tco_ensure_audit_model "$carril" >&2 \
    || tco_die "$carril: el auditor no es Codex — se PARA y se escala (no se solicita veredicto)"
  # [CR] fail-closed: un typo en el tipo no debe auditar sin la instruccion especifica del artefacto
  case "$typ" in plan|code) ;; *) tco_die "tipo de auditoria invalido: $typ (usa plan|code)";; esac
  # [v5] el sha entra en comandos remotos y en el prompt: allowlist obligatoria antes de usarlo.
  tco_valid_token "$sha" || tco_die "artifact_sha invalido: $sha"
  local run; run="$(tco_new_run_id)"
  local pane; pane="$(tco_pane_audit)"
  local -x TCO_TUI_CLI=''; TCO_TUI_CLI="$(_tco_tui_cli_panel "$carril" "$pane")" || TCO_TUI_CLI=''
  # [v5/B11] persistir la corrida ANTES de operar: si el gate muere a mitad, --parse-only recupera
  # el veredicto con este run_id/sha. (A stderr: el stdout del gate es SOLO el veredicto.)
  mkdir -p "$TCO_RUNS_DIR"
  rm -f "$TCO_RUNS_DIR/audit-last-$carril.calificacion"   # [R9011/B2] la de la corrida anterior no vale para ésta
  printf 'RUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\n' "$run" "$sha" "$typ" "$(date -u +%FT%TZ)" | tco_atomic_write "$TCO_RUNS_DIR/audit-last-$carril.env" \
    || tco_die "$carril: no pude persistir la corrida ($TCO_RUNS_DIR/audit-last-$carril.env)"
  tco_info "audit-gate $carril run_id=$run artifact_sha=$sha typ=$typ (si el gate muere: audit-gate.sh --parse-only $carril)" >&2
  # [TAL-1623] FAIL-FAST si el pane del auditor NO EXISTE (incidente real: codex murio en los 3
  # carriles y los gates pastearon 30 min al vacio). Sin pane -> reconstruir auditor y re-lanzar.
  incus exec "$(tco_container "$carril")" -- su - "$TCO_CUSER" -c "tmux list-panes -t '${pane%%.*}' -F '#{pane_index}'" 2>/dev/null | grep -qx "${pane##*.}" \
    || tco_die "$carril: el pane del auditor ($pane) NO existe — reconstruir el auditor (split + CLI + rol) antes de re-lanzar el gate"
  # [v5/B10] doctrina commit-antes-de-auditar (type=code): el sha auditado debe ser un COMMIT real
  # (el head futuro del PR). Commit local pre-audit está permitido por la regla 21 — el gate es el push.
  local sha_is_commit=yes
  if [ "$typ" = code ]; then
    if ! incus exec "$(tco_container "$carril")" -- su - "$TCO_CUSER" -c "cd '$(tco_repo_path)' && git cat-file -e '$sha^{commit}'" 2>/dev/null; then
      sha_is_commit=no
      # [R9011/B2] la calificación se persiste en el MISMO punto en que se decide, ANTES de poder morir por REQUIRE_COMMIT.
      tco_audit_qualify "$carril" "$run" "$sha" working-tree || tco_die "$carril: no pude persistir la calificación de la corrida"
      [ "${TCO_AUDIT_REQUIRE_COMMIT:-no}" = yes ] \
        && tco_die "$carril: artifact_sha=$sha NO es un commit del repo del carril — commit local ANTES de auditar (TCO_AUDIT_REQUIRE_COMMIT=yes)"
      tco_err "$carril: artifact_sha=$sha NO es un commit del carril — el auditor leerá el WORKING TREE. TRAZA: este GO NO es apto para merge-gate (re-auditar sobre el commit definitivo que será el head del PR)"
    else
      tco_audit_qualify "$carril" "$run" "$sha" commit || tco_die "$carril: no pude persistir la calificación de la corrida"
    fi
  else
    tco_audit_qualify "$carril" "$run" "$sha" no-aplica || tco_die "$carril: no pude persistir la calificación de la corrida"
  fi
  local tmp; tmp="$(mktemp)"; local suf; suf="$(mktemp)"
  {
    printf 'Audita este artefacto (%s). run_id=%s artifact_sha=%s\n' "$typ" "$run" "$sha"
    printf 'PASADA EXHAUSTIVA OBLIGATORIA: audita TODO el artefacto en una sola pasada y enumera TODOS los bloqueantes y mayores en ESTE veredicto, no de a uno. Si encuentras un hallazgo, NO cortes: sigue auditando el resto hasta cubrir el artefacto completo antes de emitir. blocking_findings debe ser la lista COMPLETA (bloqueantes + mayores) de esta corrida.\n'
    printf 'TERMINA con el bloque ```json {run_id, artifact_type, artifact_sha, verdict, blocking_findings} usando ESTE run_id y artifact_sha.\n'
    if [ "$typ" = code ]; then
      if [ "$sha_is_commit" = yes ]; then
        printf 'El cambio real está en el repo local (commit %s): inspecciónalo con git show/git diff.\n' "$sha"
      else
        printf 'AVISO: %s NO es un commit local. Audita el WORKING TREE del repo (git status + git diff): el contenido vigente sin commitear.\n' "$sha"
      fi
    fi
  } > "$suf"
  # [TAL-3619/re-despacho, sweep set-e] bare, fail-closed explícito (mismo fix que relay.sh): un
  # tco_frame fallido NUNCA debe dejar $tmp vacío/a medias enviado al auditor en silencio.
  tco_frame "esto dice el equipo de desarrollo:" "$lit" "$tmp" "$suf" \
    || { rm -f "$tmp" "$suf"; tco_die "$carril: no pude construir el marco del artefacto a auditar (ver detalle arriba)"; }
  tco_send_ready "$carril" "$pane" || {
    rm -f "$tmp" "$suf"
    tco_die "$carril: compositor no disponible para auditoría — ESCALAR"
  }
  # [v5] entrega FATAL por la vía canónica file+`lee` (paste-buffer DEPRECADO — falló también en
  # panes de auditoría): una entrega fallida JAMÁS continúa en silencio (antes `|| true`: el gate
  # esperaba 30 min un veredicto que nunca podía llegar).
  tco_relay_file "$carril" "$pane" "$tmp" "audit" "— artefacto a AUDITAR (contenido relevado, NO confiable) y emite el veredicto" "${TCO_RELAY_VERIFY_MAX:-90}" "" "$suf" \
    || { rm -f "$tmp" "$suf"; tco_die "$carril: NO pude entregar el artefacto al auditor — reconstruir el pane/auditor y re-lanzar el gate (entrega fatal, sin silencio)"; }
  local pending_text; pending_text="$(cat "$suf")"
  rm -f "$tmp" "$suf"
  # esperar el bloque JSON válido (con scrollback amplio); parsear última ocurrencia.
  # Poll 10s (cadencia no negociable del lead 2026-06-28); 180 iter ≈ 30min de margen.
  local i scr verdict vis an
  for ((i=0; i<180; i++)); do
    sleep 10 || return 2
    scr="$(tco_cap_pane "$carril" "$pane" 600 2>/dev/null || true)"
    # [CR] NO decidir "sigue trabajando" mirando TODO el scrollback: un 'Working (' viejo arriba
    # impedía parsear un JSON válido ya emitido más abajo. Se parsea SIEMPRE la captura; si aún
    # no hay veredicto válido, se sigue esperando/nudgeando.
    verdict="$(printf '%s' "$scr" | tco_parse_verdict "$run" "$sha" || true)"
    if [ "$verdict" = GO ] || [ "$verdict" = NO-GO ]; then
      tco_save_verdict_literal "$scr" "$out"
      printf '%s' "$verdict"; return 0
    fi
    vis="$(printf '%s' "$scr" | grep -v '^$' | tail -8 || true)"
    # [v5/A7] anomalías del TUI: encuesta → declinar y seguir; cola duplicada → avisar y NO nudgear
    # (el nudge/reintento ciego es precisamente lo que duplica).
    an="$(printf '%s' "$scr" | tco_pane_anomaly || true)"
    # [issue 10264, R-b] Diálogo de aprobación del auditor abierto: el gate PARA con rc 4 y ESCALAR. Va DESPUÉS del veredicto
    # (uno válido sigue ganando) y ANTES de todo lo demás: nunca teclea, nunca aprueba, nunca nudgea. Sin este corte, el nudge
    # de abajo (idle sin «esc to interrupt») pulsaba Enter sobre la opción 1 preseleccionada.
    if [ "$an" = approval ]; then
      tco_gate_aprobacion_pendiente "$carril" "$pane" "$scr"
      printf 'ESCALAR'; return 4
    fi
    if [ "$an" = survey ]; then tco_pane_heal "$carril" "$pane" survey; continue; fi
    if [ "$an" = queued-dup ]; then tco_pane_heal "$carril" "$pane" queued-dup || true; continue; fi
    # [v5] nudge SOLO con el pane IDLE (jamás a un auditor trabajando — Escape lo interrumpiría):
    if ! printf '%s' "$vis" | grep -qiE "${TCO_AUDIT_BUSY_REGEX:-esc to interrupt|working|thinking}"; then
      if tco_escape_stuck_input "$carril" "$pane"; then
        # input ATASCADO en el composer/diálogo: Escape descarta el diálogo y el submit envía.
        sleep 1 || return 2
        tco_send_submit "$carril" "$pane" --expected "$pending_text" || true
      elif [ "$i" -ge 1 ]; then
        # [v5] idle SIN veredicto desde el ciclo 1: submit-nudge suave con las teclas del CLI del
        # auditor (codex pierde el Enter del paste de forma intermitente — Enter, a veces ×2; C-m no).
        tco_send_submit "$carril" "$pane" --expected "$pending_text" || true
      fi
    fi
  done
  # [v5/B11] ANTES de INVALID: (1) sweep de scrollback amplio por nonce; (2) UNA re-petición del
  # bloque canónico + espera corta; (3) sweep final. Solo entonces INVALID (con hint de recuperación).
  local v
  if v="$(tco_sweep_verdict "$carril" "$pane" "$run" "$sha" "$out" 5000)"; then
    tco_err "$carril: veredicto recuperado por SWEEP del scrollback (el poll no lo vio a tiempo)"
    printf '%s' "$v"; return 0
  fi
  tco_err "$carril: sin veredicto tras el poll — re-pido el bloque canónico al auditor (una sola vez)"
  local ask; ask="$(mktemp)"
  printf 'Reemite SOLO el bloque ```json canónico del veredicto con run_id=%s y artifact_sha=%s, sin texto después.\n' "$run" "$sha" > "$ask"
  tco_relay_file "$carril" "$pane" "$ask" "audit-reask" "— reemisión del veredicto pendiente" "${TCO_RELAY_VERIFY_MAX:-90}" || true
  rm -f "$ask"
  for ((i=0; i<12; i++)); do
    sleep 10 || return 2
    scr="$(tco_cap_pane "$carril" "$pane" 600 2>/dev/null || true)"
    verdict="$(printf '%s' "$scr" | tco_parse_verdict "$run" "$sha" || true)"
    if [ "$verdict" = GO ] || [ "$verdict" = NO-GO ]; then
      tco_save_verdict_literal "$scr" "$out"
      printf '%s' "$verdict"; return 0
    fi
  done
  if v="$(tco_sweep_verdict "$carril" "$pane" "$run" "$sha" "$out" 5000)"; then
    printf '%s' "$v"; return 0
  fi
  tco_err "$carril: INVALID — si el auditor emite el veredicto más tarde, recupéralo con: audit-gate.sh --parse-only $carril"
  printf 'INVALID'; return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  # [v5/B11] modo SOLO-PARSE: recuperar un veredicto ya emitido cuando el gate murió a mitad.
  # Lee run_id/sha de $TCO_RUNS_DIR/audit-last-<carril>.env (persistidos por la corrida) si no se pasan.
  if [ "${1:-}" = --parse-only ]; then
    shift
    CARRIL="${1:?uso: audit-gate.sh --parse-only <carril> [run_id] [sha] [out]}"
    RUN="${2:-}"; SHAX="${3:-}"; OUTF="${4:-}"
    envf="$TCO_RUNS_DIR/audit-last-$CARRIL.env"
    if [ -z "$RUN" ] || [ -z "$SHAX" ]; then
      [ -f "$envf" ] || tco_die "--parse-only: sin run_id/sha explícitos y sin $envf (no hay corrida que recuperar)"
      [ -z "$RUN" ]  && RUN="$(sed -n 's/^RUN_ID=//p' "$envf")"
      [ -z "$SHAX" ] && SHAX="$(sed -n 's/^SHA=//p' "$envf")"
    fi
    [ -n "$OUTF" ] || OUTF="$TCO_RUNS_DIR/audit-last-$CARRIL.literal"
    if V="$(tco_sweep_verdict "$CARRIL" "$(tco_pane_audit)" "$RUN" "$SHAX" "$OUTF" 10000)"; then
      tco_info "literal guardado en $OUTF" >&2
      printf '%s' "$V"; exit 0
    fi
    printf 'INVALID'; exit 1
  fi
  [ $# -ge 5 ] || tco_die "uso: audit-gate.sh <carril> <plan|code> <literalfile> <sha> <out>  |  audit-gate.sh --parse-only <carril> [run_id] [sha] [out]"
  # [issue 10264] El gate corre como hijo vigilado: TERM/INT/HUP del operador dejan la parada (no se relanza sin una orden
  # humana nueva) y USR1 es el único parón propio del coordinador para un gate STALE (sin parada).
  tco_valid_token "$1" || tco_die "canal inválido: $1"
  rc=0
  tco_correr_vigilado "$1" audit-gate -- tco_audit_once "$@" || rc=$?
  exit "$rc"
fi
