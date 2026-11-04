#!/usr/bin/env bash
# verify-code-audit-go.sh — [issue 9011] Tercera vía de M8, SOLO con revisor=code-audit (TCO_REVISOR): el PR lleva archivado
# el veredicto GO de audit-gate.sh (tipo code), atado al headSha, con su run_id, y este verificador FALLA CERRADO.
#
# ⚠ Vía NO recomendable: no hay capa externa de revisión, C1 administra Incus, desarrollador y auditor comparten usuario
# dentro del canal y el veredicto no lleva firma verificable de autoría. La mitigación es CodeRabbit; aquí solo se declara.
#
# El registro (comentario del PR, escrito por --archivar) abre con el marcador y repite lo que audit-gate.sh persiste en
# audit-last-<canal>.env, más el objeto canónico del veredicto:
#   <!-- code-audit-go v1 -->
#   RUN_ID=tco_<epoch>_<12 hex>   SHA=<head, 40 hex>   TYP=code   TS=<UTC ISO8601>
#   {"run_id":…,"artifact_type":"code","artifact_sha":…,"verdict":"GO","blocking_findings":[]}
# Cuenta SOLO si TODO se cumple (cualquier otra cosa es «no»): comentario de un autor permitido (el dueño del token) que abre
# con el marcador; el ÚLTIMO registro que menciona el head manda; SHA del registro y del objeto = head; tipo code; el parser
# canónico (tco_parse_verdict) da GO con el run_id del registro; run_id coherente con TS; ni futuro ni caducado (TTL).
#
# Uso:  verify-code-audit-go.sh <pr> <head_sha> [--run-id <run_id>]     imprime «yes <run_id>» o «no <motivo>» (rc 0 / 1)
#       verify-code-audit-go.sh --archivar <pr> <canal> <literal>        publica el registro si el literal re-verifica como GO
# --archivar exige además (fail-closed): la corrida persistida es de tipo code Y está CALIFICADA por audit-gate.sh como
# auditada sobre el COMMIT (audit-last-<canal>.calificacion, de ESA corrida); una corrida del working tree, sin calificación
# o de otra corrida no se archiva. Cada fichero de la corrida se lee UNA sola vez (instantánea) y las dos instantáneas deben
# ser de la MISMA corrida (RUN_ID y SHA); el registro publicado sale de esas instantáneas, nunca de una relectura. Cada
# instantánea debe tener el esquema EXACTO que escribe audit-gate.sh (sin líneas de más ni de menos, ni CR) y venir de un fichero
# regular que no sea un enlace simbólico; cualquier otra cosa es «no». La lectura
# de comentarios del PR es todo o nada: un fallo de gh o un JSON incompleto descarta la respuesta entera y el resultado es «no».
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F tco_parse_verdict >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$HERE/00-config.sh"; . "$HERE/lib.sh"
fi

TCO_CODE_AUDIT_MARK='<!-- code-audit-go v1 -->'

_tco_ca_no() { printf 'no %s\n' "$1"; return 1; }

# Registro canónico del GO que se archiva en el PR (lo escribe --archivar y lo lee tco_code_audit_go_verify).
tco_code_audit_go_record() { # run_id sha typ ts
  printf '%s\nRUN_ID=%s\nSHA=%s\nTYP=%s\nTS=%s\n```json\n{"run_id":"%s","artifact_type":"%s","artifact_sha":"%s","verdict":"GO","blocking_findings":[]}\n```\n' \
    "$TCO_CODE_AUDIT_MARK" "$1" "$2" "$3" "$4" "$1" "$3" "$2"
}

# Verificador PURO (sin red). stdin = comentarios del PR [{login,created,body}] (1..N arrays, como los deja --paginate).
# args: head_sha now_epoch ttl_s run_esperado(opcional) autores(csv de logins permitidos)
# stdout: «yes <run_id>» | «no <motivo>». rc 0 solo con «yes».
tco_code_audit_go_verify() {
  local head="${1:-}" now="${2:-}" ttl="${3:-}" want_run="${4:-}" authors="${5:-}"
  local j rec body run sha typ ts verdict ts_epoch run_epoch gap k
  j="$(cat)"
  [[ $head =~ ^[0-9a-f]{40}$ ]] && [[ $now =~ ^[0-9]{9,12}$ ]] && [[ $ttl =~ ^[1-9][0-9]{0,8}$ ]] || { _tco_ca_no entrada-invalida; return 1; }
  [ -z "$want_run" ] || tco_valid_token "$want_run" || { _tco_ca_no entrada-invalida; return 1; }
  [[ $authors =~ ^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$ ]] || { _tco_ca_no sin-autores-permitidos; return 1; }
  # Candidatos: autor permitido (sin distinguir mayúsculas), abre con el marcador y menciona el head; manda el más reciente.
  rec="$(printf '%s' "$j" | jq -rs --arg authors "$authors" --arg mark "$TCO_CODE_AUDIT_MARK" --arg head "$head" '
      ( $authors | ascii_downcase | split(",") ) as $ok
      | ( add // [] )
      | [ .[]? | select( ((.login // "") | ascii_downcase) as $l | any($ok[]; . == $l) )
               | select( (.body // "") as $b | ($b | startswith($mark)) and ($b[($mark | length):] | test("^\\r?\\n")) )
               | select( (.body // "") | contains($head) ) ]
      | sort_by(.created // "") | last // empty | .body' 2>/dev/null)" || rec=''
  [ -n "$rec" ] || { _tco_ca_no sin-registro-para-el-head; return 1; }
  body="$(printf '%s' "$rec" | tr -d '\r')"
  # Cada campo exactamente una vez y con su forma; un registro ambiguo no se interpreta.
  for k in RUN_ID SHA TYP TS; do
    [ "$(printf '%s\n' "$body" | grep -c "^$k=")" = 1 ] || { _tco_ca_no registro-malformado; return 1; }
  done
  run="$(printf '%s\n' "$body" | sed -n 's/^RUN_ID=//p')"; sha="$(printf '%s\n' "$body" | sed -n 's/^SHA=//p')"
  typ="$(printf '%s\n' "$body" | sed -n 's/^TYP=//p')"; ts="$(printf '%s\n' "$body" | sed -n 's/^TS=//p')"
  [[ $run =~ ^tco_[0-9]{9,12}_[0-9a-f]{12}$ ]] && [[ $sha =~ ^[0-9a-f]{40}$ ]] && [[ $typ =~ ^[a-z]{1,12}$ ]] \
    && [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { _tco_ca_no registro-malformado; return 1; }
  [ "$sha" = "$head" ] || { _tco_ca_no sha-del-registro-distinto; return 1; }
  [ "$typ" = code ] || { _tco_ca_no tipo-no-code; return 1; }
  # El veredicto: el parser canónico del gate (nonce run_id + artifact_sha) y, además, el objeto exacto que escribe --archivar.
  verdict="$(printf '%s' "$body" | tco_parse_verdict "$run" "$head" 2>/dev/null)" || verdict=INVALID
  case "$verdict" in
    GO) : ;;
    NO-GO) _tco_ca_no veredicto-no-go; return 1 ;;
    *) _tco_ca_no veredicto-invalido; return 1 ;;
  esac
  printf '%s' "$body" | tr -d ' \t\r\n' \
    | grep -qF "{\"run_id\":\"$run\",\"artifact_type\":\"code\",\"artifact_sha\":\"$head\",\"verdict\":\"GO\",\"blocking_findings\":[]}" \
    || { _tco_ca_no veredicto-invalido; return 1; }
  [ -z "$want_run" ] || [ "$want_run" = "$run" ] || { _tco_ca_no run-distinto-del-esperado; return 1; }
  ts_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || { _tco_ca_no registro-malformado; return 1; }
  [ "$(date -u -d "@$ts_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" = "$ts" ] || { _tco_ca_no registro-malformado; return 1; }
  run_epoch="${run#tco_}"; run_epoch="${run_epoch%%_*}"
  gap=$(( run_epoch > ts_epoch ? run_epoch - ts_epoch : ts_epoch - run_epoch ))
  [ "$gap" -le 300 ] || { _tco_ca_no run-incoherente-con-ts; return 1; }
  [ "$ts_epoch" -le $(( now + 120 )) ] || { _tco_ca_no ts-futuro; return 1; }
  [ $(( now - ts_epoch )) -le "$ttl" ] || { _tco_ca_no caducado; return 1; }
  printf 'yes %s\n' "$run"
}

# Logins permitidos como autor del registro: el dueño del token (gh api user) y, si el operador lo declara, TCO_CODE_AUDIT_AUTHORS.
tco_code_audit_go_authors() {
  local viewer extra="${TCO_CODE_AUDIT_AUTHORS:-}" out=''
  viewer="$(gh api user --jq .login 2>/dev/null || true)"
  [ -z "$viewer" ] || out="$viewer"
  [ -z "$extra" ] || out="${out:+$out,}$extra"
  printf '%s' "$out"
}

tco_code_audit_go_comments() { # pr repo → array JSON; TODO o NADA: ante cualquier fallo se descarta la respuesta entera (sale [] y rc 1)
  # [R9011/B1] el rc de gh se conoce ANTES de usar su salida. Con un fallo en cualquier página, gh ya habrá impreso las
  # anteriores: unir esa salida parcial con un [] (como hacía «|| echo '[]'») dejaba pasar un GO cuya revocación iba en la
  # página que no llegó. Aquí la salida cruda solo se usa si gh terminó con rc 0 Y TODO lo impreso es un array JSON válido.
  local raw all
  raw="$(gh api --paginate "repos/$2/issues/$1/comments" \
    --jq '[.[]?|{login:(.user.login//""), created:(.created_at//""), body:(.body//"")}]' 2>/dev/null)" \
    || { echo "tco: no pude leer COMPLETOS los comentarios del PR #$1 (gh api rc≠0): se descarta la respuesta entera" >&2; echo '[]'; return 1; }
  all="$(printf '%s' "$raw" | jq -cs 'if all(.[]; type == "array") then add // [] else error("no es un array") end' 2>/dev/null)" \
    || { echo "tco: la respuesta de comentarios del PR #$1 no es JSON válido y completo: se descarta entera" >&2; echo '[]'; return 1; }
  printf '%s\n' "$all"
}

# [R9011/MA1] Validación ESTRICTA del literal RECIBIDO, con la misma exigencia que el verificador puro: el objeto que el parser
# canónico (tco_parse_verdict) toma como veredicto —el último que casa con run_id y artifact_sha— debe ser, byte a byte
# sin espacios, el GO de código {"run_id","artifact_type":"code","artifact_sha","verdict":"GO","blocking_findings":[]}.
# tco_parse_verdict (lib.sh) NO se toca: artifact_type es opcional para sus otros usuarios; esta exigencia vive aquí, en el
# consumidor nuevo. Un literal plan, sin tipo o de otro tipo no se normaliza a code con el TYP del registro: es «no».
tco_code_audit_literal_go() { # run sha (stdin = literal) → rc 0 solo si es el GO de código canónico de ESA corrida y ESE sha
  local exp_run="${1:-}" exp_sha="${2:-}" run_re sha_re joined match
  [ -n "$exp_run" ] && [ -n "$exp_sha" ] || return 1
  tco_valid_token "$exp_run" && tco_valid_token "$exp_sha" || return 1
  run_re="${exp_run//./\\.}"; sha_re="${exp_sha//./\\.}"
  joined="$(cat | tr -d ' \t\r\n')"
  match="$(printf '%s' "$joined" \
    | grep -oE "\\{\"run_id\":\"${run_re}\"[^{}]*\"artifact_sha\":\"${sha_re}\"[^{}]*\"verdict\":\"(NO-GO|GO)\"[^{}]*\"blocking_findings\":\\[[^]]*\\][^{}]*\\}" \
    | tail -1)" || true
  [ -n "$match" ] || return 1
  [ "$match" = "{\"run_id\":\"$exp_run\",\"artifact_type\":\"code\",\"artifact_sha\":\"$exp_sha\",\"verdict\":\"GO\",\"blocking_findings\":[]}" ]
}

# Publica el registro en el PR. Solo si: la última auditoría persistida del canal es de tipo code, el literal es un GO de ESA
# corrida (run_id + sha), el head del PR es el sha auditado y el registro construido pasa el propio verificador.
# [R9011c/MA2] Lectura de UN fichero de la corrida: solo un fichero REGULAR que no sea un enlace simbólico, abierto UNA vez, y
# con el contenido EXACTO (salto final incluido, que $(…) se comería: por eso el «x» centinela). Ante cualquier duda, «no»:
# - ni enlace simbólico ni fichero no regular, comprobados ANTES de leer;
# - cierre de la ventana entre comprobar y leer: tras la lectura el nombre debe seguir sin ser un enlace, seguir siendo un fichero
#   regular y tener la MISMA identidad que antes de leer (dispositivo, inodo, tipo, tamaño y hora de cambio de estado con
#   nanosegundos; el número de inodo solo no basta: el sistema de ficheros reutiliza el recién liberado). Una sustitución en esa
#   ventana (enlace puesto y quitado, o un fichero nuevo del productor) da «no» de más, nunca «sí» de más.
# Límite que NO se cierra con bash/coreutils: quien pueda escribir en el directorio de corridas y restituya EL MISMO fichero
# (mv del original de vuelta, sin tocarlo) entre la comprobación y la lectura no se detecta; ese actor ya podría escribir un
# .env válido. Tampoco hay forma de abrir «sin seguir enlaces» desde bash: la defensa es comprobar antes y después.
# [R9011d/MA3] FIDELIDAD de la captura: $(…) de bash ELIMINA los bytes NUL («ignored null byte in input») sin dar error, así que
# lo que llegaba a la validación ya estaba saneado y un .env o una calificación válidos con un NUL (al final, dentro de TYP o
# AUDITADO, en medio de RUN_ID o SHA) se archivaban. Sin una segunda apertura: el número de BYTES capturados (locale C, sin el
# centinela) debe ser igual al tamaño que dio el «stat» de ESA misma lectura (va PRIMERO en la identidad). Si no coinciden, «no»:
# eso detecta el NUL y cualquier otra pérdida de bytes de la captura.
_tco_ca_slurp() { # fichero variable → deja el contenido exacto en la variable; rc 1 ante cualquier duda
  local LC_ALL=C f="$1" id1 id2 out tam
  [ ! -L "$f" ] && [ -f "$f" ] || return 1
  id1="$(stat -c '%s:%d:%i:%F:%z' "$f" 2>/dev/null)" && [ -n "$id1" ] || return 1
  out="$(cat "$f" && printf x)" || return 1
  out="${out%x}"
  [ ! -L "$f" ] && [ -f "$f" ] || return 1
  id2="$(stat -c '%s:%d:%i:%F:%z' "$f" 2>/dev/null)" && [ "$id1" = "$id2" ] || return 1
  tam="${id2%%:*}"
  [[ $tam =~ ^[0-9]+$ ]] && [ "${#out}" -eq "$tam" ] || return 1
  printf -v "$2" '%s' "$out"
}

# [R9011d/MA3] Rechazo explícito de los caracteres de control: cada byte de la instantánea es ASCII imprimible (0x20-0x7e) o el
# salto de línea que cierra cada línea. Así un CR, un tabulador, un NUL, un DEL o un byte ≥ 0x80 dan «no» ANTES de mirar la forma
# de ningún valor (defensa en profundidad: las expresiones de abajo ya solo admiten las clases de cada campo). Si la expresión no
# compilara, también es «no».
_tco_ca_sin_control() { # instantánea → rc 0 solo si todos sus bytes son imprimibles o saltos de línea
  local LC_ALL=C nl=$'\n' re
  re="^[[:print:]${nl}]*\$"
  [[ $1 =~ $re ]] || return 1
}

# [R9011c/MA2] Esquema EXACTO de cada instantánea, el que escribe audit-gate.sh (tco_audit_once y tco_audit_qualify):
#   .env           RUN_ID=<tco_epoch_12hex> SHA=<40 hex> TYP=<code|plan> TS=<YYYY-MM-DDTHH:MM:SSZ>   (4 líneas, ese orden)
#   .calificacion  RUN_ID=<tco_epoch_12hex> SHA=<40 hex> AUDITADO=<commit|working-tree|no-aplica>     (3 líneas, ese orden)
# cada línea terminada en salto. Cualquier línea de más o de menos, repetida, vacía, desordenada, con un carácter fuera de la
# forma (CR, espacio, control, «=» sobrante) o sin el salto final es «no». Locale C: las clases son bytes, no letras acentuadas.
# RUN_ID: tco_new_run_id (lib.sh). SHA: el productor admite cualquier token (tco_valid_token) pero el único archivable es el del
# head del PR, que gh da en 40 hex minúscula (el verificador lo exige igual): cualquier otra forma no puede archivarse.
_tco_ca_env_fields() { # instantánea  vRUN vSHA vTYP vTS → rc 0 solo con el esquema exacto
  local LC_ALL=C nl=$'\n' re
  re="^RUN_ID=(tco_[0-9]{9,12}_[0-9a-f]{12})${nl}SHA=([0-9a-f]{40})${nl}TYP=(code|plan)${nl}TS=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)${nl}\$"
  _tco_ca_sin_control "$1" || return 1
  [[ $1 =~ $re ]] || return 1
  printf -v "$2" '%s' "${BASH_REMATCH[1]}"; printf -v "$3" '%s' "${BASH_REMATCH[2]}"
  printf -v "$4" '%s' "${BASH_REMATCH[3]}"; printf -v "$5" '%s' "${BASH_REMATCH[4]}"
}
_tco_ca_qual_fields() { # instantánea  vRUN vSHA vAUDITADO → rc 0 solo con el esquema exacto
  local LC_ALL=C nl=$'\n' re
  re="^RUN_ID=(tco_[0-9]{9,12}_[0-9a-f]{12})${nl}SHA=([0-9a-f]{40})${nl}AUDITADO=(commit|working-tree|no-aplica)${nl}\$"
  _tco_ca_sin_control "$1" || return 1
  [[ $1 =~ $re ]] || return 1
  printf -v "$2" '%s' "${BASH_REMATCH[1]}"; printf -v "$3" '%s' "${BASH_REMATCH[2]}"; printf -v "$4" '%s' "${BASH_REMATCH[3]}"
}

tco_code_audit_go_archive() { # pr canal literal
  local pr="${1:-}" carril="${2:-}" lit="${3:-}" repo="$TCO_REPO_SLUG" envf qualf envsnap qualsnap run sha typ ts qrun qsha qaud head authors comments tmp now_env now_qual
  [[ $pr =~ ^[0-9]+$ ]] || tco_die "pr inválido: $pr"
  tco_valid_token "$carril" || tco_die "canal inválido: $carril"
  [ -f "$lit" ] || tco_die "falta el fichero con el veredicto literal: $lit"
  envf="$TCO_RUNS_DIR/audit-last-$carril.env"
  qualf="$TCO_RUNS_DIR/audit-last-$carril.calificacion"
  [ ! -L "$envf" ] || tco_die "la corrida persistida ($envf) es un enlace simbólico: no se archiva"
  [ -f "$envf" ] || tco_die "sin corrida persistida ($envf): no hay GO que archivar"
  # [R9011b/B2-R] UNA instantánea por fichero: cada uno se abre UNA sola vez y TODOS sus campos salen de esa lectura. Antes
  # RUN_ID, SHA y AUDITADO se sacaban con aperturas sueltas: si otra corrida del canal reescribía el fichero entre dos
  # aperturas, se validaba la identidad de una corrida y se tomaba lo auditado de otra (un GO del working tree se archivaba
  # como si fuera del commit). Con las dos instantáneas en la mano, solo se archiva si son de la MISMA corrida (RUN_ID y SHA).
  # [R9011c/MA2] Además, cada instantánea debe tener el esquema EXACTO del productor (_tco_ca_*_fields) y venir de un fichero
  # regular sin enlace simbólico (_tco_ca_slurp).
  _tco_ca_slurp "$envf" envsnap || tco_die "no pude leer la corrida persistida ($envf) como fichero regular y estable (¿enlace simbólico, no regular o cambiado durante la lectura?): no se archiva"
  _tco_ca_env_fields "$envsnap" run sha typ ts \
    || tco_die "la corrida persistida del canal $carril no tiene el esquema exacto (RUN_ID, SHA, TYP y TS, una vez cada uno, en ese orden, sin líneas de más): no se archiva"
  [ "$typ" = code ] || tco_die "la última auditoría del canal $carril es de tipo '$typ', no 'code': no se archiva como GO de código"
  # [R9011/B2] SOLO vale una corrida calificada por audit-gate.sh como auditada sobre el COMMIT: su fichero de calificación
  # debe existir, ser de ESTA corrida (RUN_ID y SHA) y decir AUDITADO=commit. Una corrida sobre el working tree (que el
  # productor avisa «NO apta para merge-gate»), una sin calificación (anterior a este cambio) o una ajena → no se archiva.
  [ ! -L "$qualf" ] || tco_die "la calificación de la corrida $run del canal $carril ($qualf) es un enlace simbólico: no se archiva"
  [ -f "$qualf" ] || tco_die "la corrida $run del canal $carril no tiene calificación de lo auditado ($qualf): no se archiva (re-auditar sobre el commit con audit-gate.sh)"
  _tco_ca_slurp "$qualf" qualsnap || tco_die "no pude leer la calificación de la corrida del canal $carril ($qualf) como fichero regular y estable: no se archiva"
  _tco_ca_qual_fields "$qualsnap" qrun qsha qaud \
    || tco_die "la calificación de la corrida del canal $carril no tiene el esquema exacto (RUN_ID, SHA y AUDITADO, una vez cada uno, en ese orden, sin líneas de más): no se archiva"
  [ "$qrun" = "$run" ] && [ "$qsha" = "$sha" ] \
    || tco_die "la calificación del canal $carril es de OTRA corrida o de otro sha: no se archiva"
  [ "$qaud" = commit ] \
    || tco_die "la corrida $run se auditó sobre '$qaud', no sobre el commit: ese GO no es apto como revisión del head (re-auditar sobre el commit definitivo)"
  tco_code_audit_literal_go "$run" "$sha" < "$lit" \
    || tco_die "el literal no es un GO de código (artifact_type=code presente y exacto) de la corrida $run sobre $sha: no se archiva"
  tco_load_tokens
  head="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo '')"
  [ "$head" = "$sha" ] || tco_die "el head del PR #$pr es '$head', no el sha auditado '$sha': re-auditar sobre el commit definitivo"
  tmp="$(mktemp)"
  tco_code_audit_go_record "$run" "$sha" "$typ" "$ts" > "$tmp"
  authors="$(tco_code_audit_go_authors)"
  comments="$(jq -n --arg l "${authors%%,*}" --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --rawfile b "$tmp" '[{login:$l, created:$c, body:$b}]')"
  printf '%s' "$comments" | tco_code_audit_go_verify "$sha" "$(date -u +%s)" "${TCO_CODE_AUDIT_TTL:-172800}" "$run" "$authors" >/dev/null \
    || { rm -f "$tmp"; tco_die "el registro construido no supera el verificador (¿registro caducado o dueño del token no resoluble?): no se archiva"; }
  gh pr comment "$pr" --repo "$repo" --body-file "$tmp" >/dev/null || { rm -f "$tmp"; tco_die "no pude publicar el registro en el PR #$pr"; }
  rm -f "$tmp"
  tco_info "GO de code-audit archivado en el PR #$pr @ ${sha:0:12} (run_id=$run)"
  # [R9011b/B2-R] El registro se construyó SOLO con la instantánea validada (run_id, sha, tipo y hora de $envsnap): nada de lo
  # publicado sale de una relectura. Si mientras tanto otra corrida del canal escribió en disco, se dice (el GO publicado sigue
  # siendo el de la corrida validada; M8 lo ata a su run_id y a su head, así que no se confunde con la corrida nueva).
  # (misma lectura exacta que la instantánea, salto final incluido; si ya no se puede leer como fichero regular, también se avisa)
  now_env=''; now_qual=''
  _tco_ca_slurp "$envf" now_env 2>/dev/null || now_env=''; _tco_ca_slurp "$qualf" now_qual 2>/dev/null || now_qual=''
  if [ "$now_env" != "$envsnap" ] || [ "$now_qual" != "$qualsnap" ]; then
    tco_err "AVISO: tras validar, la corrida o la calificación del canal $carril cambiaron en disco (otra corrida empezó entre medias): el registro publicado es el de la instantánea validada (run_id=$run), no el de la corrida nueva"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  case "${1:-}" in
    --archivar) shift; tco_code_audit_go_archive "$@"; exit 0 ;;
    ''|-h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 2 ;;
  esac
  [ $# -ge 2 ] || tco_die "uso: verify-code-audit-go.sh <pr> <head_sha> [--run-id <run_id>]  |  --archivar <pr> <canal> <literal>"
  PR="$1"; HEADSHA="$2"; shift 2
  RUNID=''
  if [ "${1:-}" = --run-id ]; then RUNID="${2:?--run-id exige un valor}"; shift 2; fi
  [ $# -eq 0 ] || tco_die "argumento desconocido: $1"
  [[ $PR =~ ^[0-9]+$ ]] || tco_die "pr inválido: $PR"
  tco_load_tokens
  rc=0
  tco_code_audit_go_comments "$PR" "$TCO_REPO_SLUG" \
    | tco_code_audit_go_verify "$HEADSHA" "$(date -u +%s)" "${TCO_CODE_AUDIT_TTL:-172800}" "$RUNID" "$(tco_code_audit_go_authors)" || rc=$?
  exit "$rc"
fi
