#!/usr/bin/env bash
# C10 — check_github del doctor, contra un doble de curl (SENTRY_DOCTOR_HTTP_CLIENT). Se ejercita SOURCEANDO
# las funciones del doctor (nunca `main` en verde contra dobles: main aborta con exit 3 ante cualquier seam).
# Mutante: retirar check_github de SONDAS_MANIFEST_FUENTES deja de detectar la sonda retirada de check_fuentes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOCTOR="$(cd "$HERE/../scripts" && pwd -P)/sentry_doctor.sh"
FIX="$HERE/fixtures/github"
TMP="$(mktemp -d)"
: "${TMP:?}"
trap 'rm -rf -- "${TMP:?}"' EXIT
REPO="org-ejemplo/repo-ejemplo"
TOKEN="ghp_TOKENSINTETICO0123456789"
SECRETO="SECRETO-SINTETICO-ZZ9QX7-NO-REAL"
PASS=0
FAIL=0

# El doctor invoca el cliente como un ejecutable: envoltorio con bit de ejecución en el temporal.
printf '#!/bin/bash\nexec bash %q "$@"\n' "$FIX/curl-doble.sh" > "$TMP/curl"
chmod 755 "$TMP/curl"

clave() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
# servir <ruta-bajo-api.github.com> <código> <cuerpo>
servir() { printf '%s\n%s\n' "$2" "$3" > "$GH_DOBLE_DIR/$(clave "$1")"; }

RUTAS=(
  "dependabot/alerts?state=open&per_page=1"
  "code-scanning/alerts?state=open&per_page=1"
  "secret-scanning/alerts?state=open&per_page=1&hide_secret=true"
  "security-advisories?per_page=1"
)

# nuevo_caso: directorio de respuestas limpio, con el repo y las cuatro superficies sanas.
nuevo_caso() {
  GH_DOBLE_DIR="$(mktemp -d -p "$TMP")"
  export GH_DOBLE_DIR
  servir "repos/$REPO" 200 "{\"full_name\": \"$REPO\", \"private\": true}"
  local r
  for r in "${RUTAS[@]}"; do servir "repos/$REPO/$r" 200 "[{\"secret\": \"$SECRETO\"}]"; done
  HDR="$GH_DOBLE_DIR/hdr"
  printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HDR"
  chmod 600 "$HDR"
  export SENTRY_DOCTOR_HTTP_CLIENT="$TMP/curl" SENTRY_DOCTOR_GITHUB_REPO="$REPO" SENTRY_DOCTOR_GITHUB_HDR="$HDR"
  unset GITHUB_SEC_SUPERFICIES
}

# fallos_de <doctor> <función…>: ejecuta en subshell (FALLOS limpio) y vuelca un fallo por línea.
fallos_de() {
  local doctor="$1"
  shift
  (
    # shellcheck disable=SC1090
    source "$doctor" >/dev/null 2>&1
    "$@" >/dev/null 2>&1
    printf '%s\n' ${FALLOS[@]+"${FALLOS[@]}"}
  )
}

caso() { # <nombre> <esperado-nº-fallos> <patrón-grep-o-vacío> <doctor> <función…>
  local nombre="$1" n="$2" patron="$3" doctor="$4" salida cuenta
  shift 4
  salida="$(fallos_de "$doctor" "$@")"
  cuenta="$(printf '%s' "$salida" | grep -c . || true)"
  if [ "$cuenta" = "$n" ] && { [ -z "$patron" ] || printf '%s' "$salida" | grep -qE "$patron"; } \
     && ! printf '%s' "$salida" | grep -qF -e "$SECRETO" -e "$TOKEN"; then
    echo "PASS $nombre"
    PASS=$((PASS + 1))
  else
    echo "FAIL $nombre: fallos=$cuenta (esperados $n) :: $salida"
    FAIL=$((FAIL + 1))
  fi
}

llamadas() { grep -c . "$GH_DOBLE_DIR/llamadas.log" 2>/dev/null || echo 0; }
afirmar() { # <nombre> <comando…>
  local nombre="$1"
  shift
  if "$@"; then echo "PASS $nombre"; PASS=$((PASS + 1)); else echo "FAIL $nombre"; FAIL=$((FAIL + 1)); fi
}

# ── C10: repo correcto + cuatro superficies con 200 y lista → sin fallos ──
nuevo_caso
caso "C10 repo y cuatro superficies sanas: sin fallos" 0 "" "$DOCTOR" check_github
afirmar "C10 cinco llamadas (repo + 4 superficies) y hide_secret en secret scanning" \
  bash -c '[ "$(grep -c . "$1/llamadas.log")" = 5 ] && grep -q "hide_secret=true" "$1/llamadas.log"' _ "$GH_DOBLE_DIR"

# ── repo equivocado: un fallo, y no se sigue con las superficies ──
nuevo_caso
servir "repos/$REPO" 200 '{"full_name": "otro-org/otro-repo"}'
caso "C10 repo equivocado (full_name distinto): un fallo" 1 "github-repo: recurso presente pero no es el esperado" "$DOCTOR" check_github
afirmar "C10 repo equivocado: no se consultan las superficies" bash -c '[ "$(grep -c . "$1/llamadas.log")" = 1 ]' _ "$GH_DOBLE_DIR"

# ── superficie 403 / 404: un fallo cada una ──
nuevo_caso
servir "repos/$REPO/${RUTAS[0]}" 403 "{\"message\": \"Dependabot alerts are disabled\", \"secret\": \"$SECRETO\"}"
caso "C10 superficie 403: un fallo" 1 "github-dependabot: 403" "$DOCTOR" check_github
nuevo_caso
servir "repos/$REPO/${RUTAS[1]}" 404 '{"message": "Not Found"}'
caso "C10 superficie 404: un fallo" 1 "github-code-scanning: recurso no encontrado" "$DOCTOR" check_github
nuevo_caso
servir "repos/$REPO/${RUTAS[0]}" 403 '{}'
servir "repos/$REPO/${RUTAS[3]}" 404 '{}'
caso "C10 dos superficies caídas: un fallo cada una" 2 "github-" "$DOCTOR" check_github

# ── no lista / inalcanzable / 401 ──
nuevo_caso
servir "repos/$REPO/${RUTAS[3]}" 200 '{"ghsa_id": "GHSA-aaaa-bbbb-cccc"}'
caso "C10 superficie que no devuelve lista: un fallo" 1 "github-advisories: recurso presente pero no es una lista" "$DOCTOR" check_github
nuevo_caso
rm -f -- "${GH_DOBLE_DIR:?}/$(clave "repos/$REPO/${RUTAS[2]}")"
caso "C10 superficie inalcanzable: un fallo" 1 "github-secret-scanning: fuente inalcanzable" "$DOCTOR" check_github
nuevo_caso
servir "repos/$REPO" 401 '{"message": "Bad credentials"}'
caso "C10 repo con 401: un fallo" 1 "github-repo: 401 credencial inválida" "$DOCTOR" check_github

# ── GitHub es fuente OPCIONAL (decisión del CEO): sin config se VE «no vigilada» y no falla; con la
#    variable definida la config es parcial o completa y rige fail-closed con el motivo nombrado ──
sin_config() { # <doctor>: 0 si, sin SENTRY_DOCTOR_GITHUB_REPO, check_github da rc 0, 0 fallos, muestra «github: no vigilada» y no toca la red
  local salida
  nuevo_caso
  unset SENTRY_DOCTOR_GITHUB_REPO SENTRY_DOCTOR_GITHUB_HDR
  salida="$(
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    check_github
    printf 'RC=%s\n' "$?"
    printf 'FALLOS=%s\n' "${#FALLOS[@]}"
  )"
  printf '%s' "$salida" | grep -q 'github: no vigilada' && printf '%s' "$salida" | grep -q '^RC=0$' \
    && printf '%s' "$salida" | grep -q '^FALLOS=0$' && [ ! -s "$GH_DOBLE_DIR/llamadas.log" ]
}
parcial_header() { # <doctor> <ausente|0644|segunda>: 0 si la config parcial da UN fallo «config parcial» con su motivo
  local doctor="$1" variante="$2" patron salida
  nuevo_caso
  case "$variante" in
    ausente)  rm -f -- "${HDR:?}"; patron='config parcial.*header-file ausente' ;;
    0644)     chmod 644 "$HDR"; patron='config parcial.*permisos inseguros' ;;
    segunda)  printf 'Authorization: Bearer %s\nHost: otro.invalid\n' "$TOKEN" > "$HDR"; patron='config parcial.*contenido inesperado' ;;
  esac
  salida="$(fallos_de "$doctor" check_github)"
  [ "$(printf '%s' "$salida" | grep -c .)" = 1 ] && printf '%s' "$salida" | grep -qE "$patron" \
    && [ ! -s "$GH_DOBLE_DIR/llamadas.log" ]
}
afirmar "C10 sin config: rc 0, 0 fallos y «github: no vigilada» visible, sin llamadas de red" sin_config "$DOCTOR"
afirmar "C10 config parcial (repo definido, header-file ausente): un fallo con su motivo" parcial_header "$DOCTOR" ausente
afirmar "C10 config parcial (repo definido, header-file 0644): un fallo con su motivo" parcial_header "$DOCTOR" 0644
afirmar "C10 config parcial (repo definido, header-file con segunda cabecera): un fallo con su motivo" parcial_header "$DOCTOR" segunda
nuevo_caso
rm -f -- "${GH_DOBLE_DIR:?}/$(clave "repos/$REPO")"
caso "C10 config parcial (repo definido, la fuente no responde): un fallo" 1 "github-repo: fuente inalcanzable" "$DOCTOR" check_github
nuevo_caso
export SENTRY_DOCTOR_GITHUB_REPO=""
caso "C10 config parcial (repo definido pero vacío): un fallo" 1 "config parcial.*vacía" "$DOCTOR" check_github
nuevo_caso
export SENTRY_DOCTOR_GITHUB_REPO="org-ejemplo/../x"
caso "C10 repo con traversal: formato inválido" 1 "formato inválido" "$DOCTOR" check_github
nuevo_caso
export GITHUB_SEC_SUPERFICIES="dependabot,inventada"
caso "C10 superficie desconocida en la lista: un fallo" 1 "superficie desconocida" "$DOCTOR" check_github

# ── lista declarada: solo se consultan las declaradas ──
nuevo_caso
export GITHUB_SEC_SUPERFICIES="dependabot"
caso "C10 solo dependabot declarada: sin fallos" 0 "" "$DOCTOR" check_github
afirmar "C10 solo dependabot declarada: 2 llamadas (repo + dependabot)" bash -c '[ "$(grep -c . "$1/llamadas.log")" = 2 ]' _ "$GH_DOBLE_DIR"

# ── manifiesto de sondas: la sexta fuente figura y su retirada se detecta ──
# Sustituye los cinco checks previos por no-ops y deja check_github real; fuentes_sin_github imita el
# defecto «sonda retirada de check_fuentes» (queda definida la función, desaparece su invocación).
retiro_detectado() { # <doctor>: 0 si verificar_manifiesto_sondas delata check_github retirada de check_fuentes
  local salida
  salida="$(
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    check_sentry() { :; }; check_betterstack() { :; }; check_supabase() { :; }; check_railway() { :; }
    check_linear() { :; }; check_github() { :; }
    check_fuentes() {
      llamar_sonda check_sentry; llamar_sonda check_betterstack; llamar_sonda check_supabase
      llamar_sonda check_railway; llamar_sonda check_linear
    }
    check_fuentes
    verificar_manifiesto_sondas --solo-fuentes
    printf '%s\n' ${FALLOS[@]+"${FALLOS[@]}"}
  )"
  printf '%s' "$salida" | grep -q "check_github"
}
cableado_completo() { # <doctor>: 0 si, con las seis sondas cableadas, el manifiesto no reclama nada
  local salida
  salida="$(
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    check_sentry() { :; }; check_betterstack() { :; }; check_supabase() { :; }; check_railway() { :; }
    check_linear() { :; }; check_github() { :; }
    check_fuentes
    verificar_manifiesto_sondas --solo-fuentes
    printf '%s\n' ${FALLOS[@]+"${FALLOS[@]}"}
  )"
  [ -z "$salida" ]
}
afirmar "C10 las seis sondas cableadas en check_fuentes: el manifiesto no reclama nada" cableado_completo "$DOCTOR"
afirmar "C10 sonda check_github retirada de check_fuentes: el manifiesto la detecta" retiro_detectado "$DOCTOR"

# Mutante: check_github fuera de SONDAS_MANIFEST_FUENTES -> la retirada deja de detectarse (ROJO) y al
# volver al original se detecta de nuevo (VERDE).
MUT="$TMP/sentry_doctor_mutante.sh"
sed 's/ check_linear check_github)$/ check_linear)/' "$DOCTOR" > "$MUT"
if cmp -s "$DOCTOR" "$MUT"; then
  echo "FAIL MUTANTE-4: la sustitución no cambió el fichero (el manifiesto cambió de forma)"
  FAIL=$((FAIL + 1))
else
  if retiro_detectado "$DOCTOR" && ! retiro_detectado "$MUT" && retiro_detectado "$DOCTOR"; then
    echo "PASS MUTANTE-4: original detecta la retirada (VERDE); sin la entrada del manifiesto no la detecta (ROJO); revertido VERDE"
    PASS=$((PASS + 1))
  else
    echo "FAIL MUTANTE-4: el mutante no puso ROJO su caso"
    FAIL=$((FAIL + 1))
  fi
fi

# Mutantes de la fuente opcional (ROJO con el defecto, VERDE al restaurar):
#  5) la config vuelve a ser obligatoria -> el caso «sin config» deja de ser rc 0 con «no vigilada»;
#  6) se quita la comprobación del header-file de check_github -> los casos de config parcial pierden su motivo.
mutante_doctor() { # <n> <descripción> <caso…> -- <script sed>
  local n="$1" desc="$2" script mut="$TMP/sentry_doctor_mutante_$1.sh"
  shift 2
  local -a caso_cmd=()
  while [ "$1" != "--" ]; do caso_cmd+=("$1"); shift; done
  shift
  script="$1"
  sed "$script" "$DOCTOR" > "$mut"
  if cmp -s "$DOCTOR" "$mut"; then
    echo "FAIL MUTANTE-$n: la sustitución no cambió el fichero"
    FAIL=$((FAIL + 1))
  elif "${caso_cmd[@]}" "$DOCTOR" && ! "${caso_cmd[@]}" "$mut" && "${caso_cmd[@]}" "$DOCTOR"; then
    echo "PASS MUTANTE-$n: $desc: original VERDE; defecto ROJO; revertido VERDE"
    PASS=$((PASS + 1))
  else
    echo "FAIL MUTANTE-$n: $desc: el mutante no puso ROJO su caso"
    FAIL=$((FAIL + 1))
  fi
}
mutante_doctor 5 "config de GitHub obligatoria otra vez (caso «sin config»)" sin_config -- \
  's/if \[ -z "\${SENTRY_DOCTOR_GITHUB_REPO+x}" \]; then/if false; then/'
parcial_todos() { parcial_header "$1" ausente && parcial_header "$1" 0644 && parcial_header "$1" segunda; }
mutante_doctor 6 "sin la comprobación del header-file (casos de config parcial)" parcial_todos -- \
  '/^check_github()/,/^}/ { s/if \[ ! -f "\$hdr" \]; then/if false; then/; s/if \[ "\$perms" != "600" \]; then/if false; then/; s/if ! header_file_valido "\$hdr"; then/if false; then/ }'

# ── seam: main aborta con exit 3 y jamás emite PUERTA ABIERTA ──
nuevo_caso
salida_main="$(bash "$DOCTOR" --solo-fuentes 2>&1)"
rc_main=$?
if [ "$rc_main" = 3 ] && printf '%s' "$salida_main" | grep -q "ENTORNO CONTAMINADO" \
   && printf '%s' "$salida_main" | grep -q "SENTRY_DOCTOR_HTTP_CLIENT" && ! printf '%s' "$salida_main" | grep -q "PUERTA ABIERTA"; then
  echo "PASS C10 seam inyectado (cliente HTTP): main sale con rc 3 y sin PUERTA ABIERTA"
  PASS=$((PASS + 1))
else
  echo "FAIL C10 seam inyectado: rc=$rc_main :: $salida_main"
  FAIL=$((FAIL + 1))
fi
nuevo_caso
unset SENTRY_DOCTOR_HTTP_CLIENT
export SENTRY_DOCTOR_GITHUB_FALSO=1
salida_main="$(bash "$DOCTOR" --solo-fuentes 2>&1)"
rc_main=$?
if [ "$rc_main" = 3 ] && printf '%s' "$salida_main" | grep -q "SENTRY_DOCTOR_GITHUB_FALSO"; then
  echo "PASS C10 variable SENTRY_DOCTOR_GITHUB_* fuera de la lista permitida: rc 3"
  PASS=$((PASS + 1))
else
  echo "FAIL C10 variable desconocida SENTRY_DOCTOR_GITHUB_*: rc=$rc_main :: $salida_main"
  FAIL=$((FAIL + 1))
fi
unset SENTRY_DOCTOR_GITHUB_FALSO
# REPO y HDR son config permitida: no son seams.
nuevo_caso
unset SENTRY_DOCTOR_HTTP_CLIENT
seams="$(
  # shellcheck disable=SC1090
  source "$DOCTOR" >/dev/null 2>&1
  seams_presentes
)"
[ -z "$seams" ] && { echo "PASS C10 SENTRY_DOCTOR_GITHUB_REPO/HDR están en CONFIG_PERMITIDA (no son seams)"; PASS=$((PASS + 1)); } \
  || { echo "FAIL C10 REPO/HDR contados como seams: $seams"; FAIL=$((FAIL + 1)); }

echo "RESULTADO: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
