#!/usr/bin/env bash
# C1-C8 y C10 de scripts/parte_guardia.sh, contra dobles (sin red, sin GitHub ni Sentry reales).
# Cada caso corre el parte en una copia de la skill con un doctor y un tablas-cron DOBLES a su lado (el parte los
# resuelve por su propia carpeta; no hay seams de entorno), `gh` envuelto por gh_contrato.py (gh 2.45.0), un curl
# doble para Supabase y un doble de urlopen de Sentry cargado por PYTHONPATH. Mutantes: cada guarda clave pone
# ROJO su caso al retirarla (copia de la skill con un `sed`) y VERDE al revertir (la copia buena).
# Con SALIDA definida (arnés) deja ahí la salida normalizada de C10 para revisarla antes de versionar la línea base.
# Las comprobaciones `bash -c '…' _ args` llevan SU código entre comillas simples a propósito (lo expande el bash interior);
# los `A && B || C` son "si A y B, PASS; si no, FAIL" sobre comandos que ya imprimen su propio resultado.
# shellcheck disable=SC2016,SC2015,SC2059
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd "$HERE/.." && pwd -P)"
ROOT="$(cd "$HERE/../../.." && pwd -P)"
FIX="$HERE/fixtures/parte"
TMP="$(mktemp -d)"
: "${TMP:?}"
trap 'case "$TMP" in /?*) rm -rf -- "${TMP:?}" ;; esac' EXIT
PASS=0; FAIL=0; SKIP=0
TOKEN="ghp_TOKENSINTETICO0123456789"
SECRETO="SECRETO-SINTETICO-ZZ9QX7-NO-REAL"
PATH0="$PATH"
command -v git >/dev/null 2>&1 || { echo "SKIP todo el fichero: git no disponible"; echo "RESULTADO: PASS=0 FAIL=0 SKIP=1"; exit 0; }

afirmar() { # <nombre> <comando…>
  local n="$1"; shift
  if "$@"; then echo "PASS $n"; PASS=$((PASS + 1)); else echo "FAIL $n"; FAIL=$((FAIL + 1)); fi
}

# ── Copia de la skill con doctor y tablas-cron dobles al lado ──
construir_pkg() { # <destino>
  mkdir -p "$1/skills/talent-ceo/scripts"
  cp -R "$SKILL" "$1/skills/talent-sentry-guard"
  cat >"$1/skills/talent-sentry-guard/scripts/sentry_doctor.sh" <<'__FIN_DOCTOR_DOBLE__'
#!/usr/bin/env bash
rc="$(cat "$PARTE_DOBLE_DIR/doctor.rc" 2>/dev/null || echo 0)"
[ "$rc" = 0 ] && { echo "PUERTA ABIERTA (doble)"; exit 0; }
# Con doctor.err.crudo el stderr es EXACTAMENTE ese fichero (sus bytes), para medir las fronteras del tope de lectura.
[ -f "$PARTE_DOBLE_DIR/doctor.err.crudo" ] && { cat "$PARTE_DOBLE_DIR/doctor.err.crudo" >&2; exit "$rc"; }
echo "PUERTA CERRADA (doble): fallo simulado $(cat "$PARTE_DOBLE_DIR/doctor.msg" 2>/dev/null)" >&2; exit "$rc"
__FIN_DOCTOR_DOBLE__
  cat >"$1/skills/talent-ceo/scripts/tablas-cron.sh" <<'__FIN_CRON_DOBLE__'
#!/usr/bin/env bash
[ "${1:-}" = "--minutos" ] || exit 2
[ -f "$PARTE_DOBLE_DIR/cron.out" ] || { echo "sin fila cron (doble)" >&2; exit 1; }
cat "$PARTE_DOBLE_DIR/cron.out"
__FIN_CRON_DOBLE__
}
PKG="$TMP/pkg"
construir_pkg "$PKG"

# ── Repos: el declarado y uno ajeno (el que sería el cwd) ──
REPO="$TMP/repo"; AJENO="$TMP/ajeno"
for r in "$REPO" "$AJENO"; do
  git init -q "$r" && git -C "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m "base $r"
done
REPO_ID="$(stat -c '%d:%i' "$REPO/.git")"
TREE_REPO="$(git --git-dir="$REPO/.git" rev-parse HEAD)"

nuevo_caso() { # caso sano: 150 grupos conocidos, 5 alertas conocidas, parte previo hace 5 min, doctor abierto
  C="$(mktemp -d -p "$TMP" caso.XXXXXX)"
  mkdir "$C/bin" "$C/home"
  cp "$FIX/curl-supabase.sh" "$C/bin/curl"; chmod 755 "$C/bin/curl"
  cp "$FIX/gh.py" "$C/bin/gh"; chmod 755 "$C/bin/gh"
  python3 "$ROOT/tests/fixtures/instalacion/gh_contrato.py" --envolver "$C/bin/gh"
  local h; for h in sentry gh supa; do printf 'Authorization: Bearer %s\n' "$TOKEN" >"$C/$h.hdr"; chmod 600 "$C/$h.hdr"; done
  python3 "$FIX/generar.py" "$C" --grupos 150 --gh 5 --estado-previo 300
  printf 'ventas_atascadas\tselect id from sales where false\n' >"$C/dinero.tsv"
  printf '201\n[]\n' >"$C/dinero.respuesta"
  echo 0 >"$C/doctor.rc"; echo '07,22,37,52' >"$C/cron.out"
}

correr() { # <caso> [VAR=valor…] → OUT, RC (cwd = home del caso; entorno vacío salvo lo declarado)
  local c="$1"; shift
  OUT="$(cd "${CWD:-$c/home}" && env -i PATH="$c/bin:$PATH0" HOME="$c/home" PYTHONPATH="$FIX/shim" PARTE_DOBLE_DIR="$c" \
    SENTRY_ORG=org-ejemplo SENTRY_PROJECT=proy-ejemplo SENTRY_HDR="$c/sentry.hdr" \
    TA_PARTE_REPO="$REPO" TA_PARTE_REPO_ID="$REPO_ID" SENTRY_PARTE_ESTADO="$c/estado.json" \
    SENTRY_PARTE_MONEY_SQL="$c/dinero.tsv" SENTRY_DOCTOR_SUPABASE_PROJECT_REF=abcdefghij0123456789 SENTRY_DOCTOR_SUPABASE_HDR="$c/supa.hdr" \
    GITHUB_SEC_REPO=org-ejemplo/repo-ejemplo GITHUB_SEC_HDR="$c/gh.hdr" "$@" \
    bash "${PKG_USADO:-$PKG}/skills/talent-sentry-guard/scripts/parte_guardia.sh" 2>"$c/stderr")"
  RC=$?
  # Las corridas con mutante (NO_REGISTRAR=1) pueden contener el token a propósito: no entran en el registro global.
  [ -n "${NO_REGISTRAR:-}" ] || { printf '%s\n' "$OUT" >>"$TMP/todo.out"; cat "$c/stderr" >>"$TMP/todo.out"; }
}

estado_es() { printf '%s\n' "$OUT" | head -1 | grep -q "estado=$1 "; }
tiene() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
metricas_bien_formadas() { # toda línea que no es cabecera ni título de sección es una medida con árbol e instante
  local malas
  malas="$(printf '%s\n' "$OUT" | grep -vE '^(PARTE-GUARDIA tree=[0-9a-f]{40,64} instant=[0-9T:Z-]+ estado=|== )' \
    | grep -cvE '^tree=[0-9a-f]{40,64} instant=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z metric=[a-z0-9_]+ value=' || true)"
  [ "$malas" = 0 ]
}
sin_salida() { [ -z "$OUT" ]; }

con_mutante() { # <fichero bajo scripts/> <patrón sed> <reemplazo>: deja PKG_USADO en una copia mutada (y comprueba que mutó)
  local m="$TMP/pkgm"
  case "$m" in "$TMP"/*) rm -rf -- "${m:?}" ;; esac
  construir_pkg "$m"
  local f="$m/skills/talent-sentry-guard/scripts/$1"
  sed -i "s#$2#$3#" "$f"
  if cmp -s "$f" "$SKILL/scripts/$1"; then echo "FAIL el mutante sobre $1 no cambió nada"; FAIL=$((FAIL + 1)); fi
  PKG_USADO="$m"
}
sin_mutante() { unset PKG_USADO; }

# ── C1: todas las secciones corrieron y 0 novedades ──
nuevo_caso; correr "$C"
afirmar "C1 LIMPIO: rc 0, estado LIMPIO y las secciones obligatorias presentes" \
  bash -c '[ "$1" = 0 ]' _ "$RC"
estado_es LIMPIO && afirmar "C1 estado=LIMPIO con árbol del repo declarado" tiene "estado=LIMPIO causas=ninguna" \
  || { echo "FAIL C1 estado distinto de LIMPIO: $(printf '%s\n' "$OUT" | head -1)"; FAIL=$((FAIL + 1)); }
afirmar "C1 la sección de issues nuevas de Sentry y las cifras clave existen" \
  bash -c 'printf "%s\n" "$1" | grep -q "^== issues nuevas (Sentry) ==" && printf "%s\n" "$1" | grep -q "metric=sentry_unresolved_total value=150" && printf "%s\n" "$1" | grep -q "metric=sentry_nuevos_desde_ultimo_parte value=0"' _ "$OUT"
afirmar "C1 toda medida lleva tree=<sha> instant=<UTC>, una por línea" metricas_bien_formadas
afirmar "C1 el árbol es el HEAD del repo declarado" tiene "tree=$TREE_REPO "

# ── C2 y caso 14-sep: grupo nuevo tras un despliegue, FUERA de la primera página de Sentry ──
nuevo_caso
python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300
echo "$(( $(date +%s) - 3000 )) abcdef1" >"$C/main-movido"
cp "$C/estado.json" "$C/estado.semilla"
correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
estado_es NOVEDAD && afirmar "C2 estado=NOVEDAD, rc 0" bash -c '[ "$1" = 0 ]' _ "$RC" \
  || { echo "FAIL C2 estado: $(printf '%s\n' "$OUT" | head -1)"; FAIL=$((FAIL + 1)); }
afirmar "C2 nuevos desde el último parte >= 1 y nuevos post-despliegue >= 1" \
  bash -c 'printf "%s\n" "$1" | grep -q "metric=sentry_nuevos_desde_ultimo_parte value=1" && printf "%s\n" "$1" | grep -q "metric=sentry_nuevos_post_despliegue value=1"' _ "$OUT"
afirmar "C2 el grupo nuevo está listado en la sección de issues nuevas (eventos 141, origen ambos)" \
  tiene 'metric=sentry_issue_nueva value=PROY-150 eventos="141" .*origen="ambos"'
afirmar "C2 el barrido pidió la segunda página (cursor=2) por orden" grep -q 'cursor=2' "$C/sentry-peticiones.log"
# El mismo estado con el barrido SIN seguir el cursor (el comportamiento antiguo) sale «limpio».
con_mutante sentry_triage.py 'siguiente = parse_next_cursor(link)' 'siguiente = None'
cp "$C/estado.semilla" "$C/estado.json"
correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
afirmar "14-sep antes: sin seguir el cursor el mismo estado sale LIMPIO (la novedad se pierde)" estado_es LIMPIO
sin_mutante
cp "$C/estado.semilla" "$C/estado.json"
correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
afirmar "14-sep después: el mismo estado sale NOVEDAD (verde al revertir)" estado_es NOVEDAD

# ── C3: puerta cerrada, sonda fallida o sección que no corrió → SONDA-ROJA, rc 1, nunca LIMPIO ──
roja() { # <nombre> <causa-esperada>
  afirmar "C3 $1: SONDA-ROJA, rc 1, nunca LIMPIO" bash -c '[ "$1" = 1 ] && printf "%s\n" "$2" | head -1 | grep -q "estado=SONDA-ROJA .*causas=.*$3"' _ "$RC" "$OUT" "$2"
}
nuevo_caso; echo 1 >"$C/doctor.rc"; correr "$C"
roja "doctor cerrado" doctor-puerta-cerrada
afirmar "C3 doctor cerrado: se declara la puerta cerrada" tiene 'metric=doctor_puerta value=cerrada'
con_mutante parte_guardia.sh 'roja.append("doctor-puerta-cerrada")' 'pass'
correr "$C"
afirmar "C3 mutante (retirar la sonda roja del doctor) -> el caso se pone rojo" bash -c '! printf "%s\n" "$1" | head -1 | grep -q "estado=SONDA-ROJA"' _ "$OUT"
sin_mutante
nuevo_caso; echo 3 >"$C/doctor.rc"; correr "$C"
roja "doctor contaminado (rc 3)" doctor-puerta-cerrada
nuevo_caso; echo 403 >"$C/sentry.fallo"; correr "$C"
roja "Sentry caído (403)" sentry-consulta-fallida
afirmar "C3 Sentry caído: la sección de issues nuevas se imprime igual y dice fallida" \
  bash -c 'printf "%s\n" "$1" | grep -q "^== issues nuevas (Sentry) ==" && printf "%s\n" "$1" | grep -q "metric=sentry_consulta_nuevas value=fallida"' _ "$OUT"
nuevo_caso; echo 1 >"$C/dependabot.rc"; echo 'gh: HTTP 500' >"$C/dependabot.err"; correr "$C"
roja "GitHub configurado y caído" github-consulta-fallida
nuevo_caso; correr "$C" GITHUB_SEC_REPO= SENTRY_DOCTOR_GITHUB_REPO=org-ejemplo/repo-ejemplo
roja "GitHub con config parcial" github-config-parcial
nuevo_caso; correr "$C" GITHUB_SEC_REPO=
afirmar "GitHub sin config: sección «no vigilada», sin fallo (LIMPIO conserva la cobertura declarada)" \
  bash -c '[ "$1" = 0 ] && printf "%s\n" "$2" | grep -q "metric=github_estado value=no-vigilada" && printf "%s\n" "$2" | head -1 | grep -q "estado=LIMPIO"' _ "$RC" "$OUT"

# ── Credencial reflejada: el token del header vuelve en un título, un enlace o un error → enmascarado y SONDA-ROJA ──
sin_token() { ! printf '%s\n' "$OUT" | grep -qF -e "$TOKEN" -e 'OTROTOKEN99999'; }
nuevo_caso
python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$TOKEN"
correr "$C"
afirmar "M1 token reflejado en título y enlace de Sentry: no sale por stdout (0 apariciones)" sin_token
afirmar "M1 título y enlace: se ve la máscara y el grupo sigue listado" tiene 'metric=sentry_issue_nueva value=PROY-150 .*titulo="fallo nuevo 150 tras el despliegue \[OCULTO\]".*enlace="https://example.invalid/g150\?t=\[OCULTO\]"'
roja "token reflejado en título y enlace" credencial-reflejada
afirmar "M1 título y enlace: la sonda roja lo dice (metric=sonda_roja)" tiene 'metric=sonda_roja value=credencial-reflejada'
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'HTTP 401 con la credencial %s' "$TOKEN" >"$C/doctor.msg"; correr "$C"
afirmar "M1 token reflejado en el error del doctor: no sale por stdout" sin_token
roja "token reflejado en el error del doctor" credencial-reflejada
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'Authorization: Bearer OTROTOKEN99999 rechazado' >"$C/doctor.msg"; correr "$C"
afirmar "M1 cabecera Authorization/Bearer ajena al header-file: enmascarada por patrón" sin_token
roja "cabecera Authorization reflejada en un error" credencial-reflejada
nuevo_caso; echo 403 >"$C/sentry.fallo"; correr "$C"
afirmar "M1 error de Sentry sin credencial: no se marca reflejo (sin falsos positivos)" bash -c '! printf "%s\n" "$1" | head -1 | grep -q credencial-reflejada' _ "$OUT"
# Token PARTIDO por un salto de línea (la fuente rompe una credencial de una línea): ni el primer fragmento ni el
# segundo pueden salir, por stdout ni por stderr; cada reflejo es SONDA-ROJA credencial-reflejada rc 1.
T1="${TOKEN:0:12}"; T2="${TOKEN:12}"
sin_fragmentos() { # OUT y el stderr del último caso, sin ninguna de las dos mitades
  ! printf '%s\n' "$OUT" | grep -qF -e "$T1" -e "$T2" && ! grep -qF -e "$T1" -e "$T2" "$C/stderr"
}
for donde in titulo enlace; do
  nuevo_caso
  python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$TOKEN" --reflejo-en "$donde" --partir 12
  correr "$C"
  afirmar "M1 token partido por un salto de línea en el $donde: ningún fragmento sale (stdout ni stderr)" sin_fragmentos
  roja "token partido en el $donde" credencial-reflejada
done
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'error reflejado %s\n%s' "$T1" "$T2" >"$C/doctor.msg"; correr "$C"
afirmar "M1 token partido por un salto de línea en el error del doctor: ningún fragmento sale" sin_fragmentos
roja "token partido en el error del doctor" credencial-reflejada
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'error reflejado %s\r\n  %s' "$T1" "$T2" >"$C/doctor.msg"; correr "$C"
afirmar "M1 token partido por CRLF y espacios en el error del doctor: ningún fragmento sale" sin_fragmentos
roja "token partido por CRLF y espacios" credencial-reflejada
nuevo_caso
python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "texto-normal-sin-credencial" --partir 6
correr "$C"
afirmar "M1 control: un título normal con salto de línea NO es un reflejo (sin falso rojo)" bash -c '[ "$1" = 0 ] && printf "%s\n" "$2" | head -1 | grep -q "estado=NOVEDAD causas=sentry-issues-nuevas$"' _ "$RC" "$OUT"
# Mutantes: sin el enmascarado por valor, el token del título sale; sin el patrón genérico, la cabecera ajena sale.
NO_REGISTRAR=1
nuevo_caso
python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$TOKEN"
con_mutante parte_guardia.sh '    if OCULTOS:' '    if False:'
correr "$C"
afirmar "M1 mutante (sin enmascarar por valor) -> el caso se pone rojo: el token sale por stdout" bash -c 'printf "%s\n" "$1" | grep -qF -e "$2"' _ "$OUT" "$TOKEN"
sin_mutante
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'Authorization: Bearer OTROTOKEN99999 rechazado' >"$C/doctor.msg"
con_mutante parte_guardia.sh '    texto = PATRON_GENERICO.sub(MASCARA, texto)' '    pass'
correr "$C"
afirmar "M1 mutante (sin patrón genérico) -> el caso se pone rojo: la cabecera ajena sale" bash -c 'printf "%s\n" "$1" | grep -qF OTROTOKEN99999' _ "$OUT"
sin_mutante

# Mutantes del token partido: sin la normalización previa (coincidencia tolerante a blancos) salen los fragmentos del
# título; sin enmascarar el fichero ENTERO antes de la primera línea sale el primer fragmento del error.
nuevo_caso
python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$TOKEN" --reflejo-en titulo --partir 12
con_mutante parte_guardia.sh 'partes = \[tolerante.*' 'partes = []'
correr "$C"
afirmar "M1 mutante (sin coincidencia tolerante a blancos) -> el caso se pone rojo: los fragmentos salen" bash -c 'printf "%s\n" "$1" | grep -qF -e "$2" -e "$3"' _ "$OUT" "$T1" "$T2"
sin_mutante
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'error reflejado %s\n%s' "$T1" "$T2" >"$C/doctor.msg"
con_mutante parte_guardia.sh 'ocultar(crudo).splitlines' 'crudo.splitlines'
correr "$C"
afirmar "M1 mutante (primera línea antes de enmascarar) -> el caso se pone rojo: el primer fragmento sale" bash -c 'printf "%s\n" "$1" | grep -qF -e "$2"' _ "$OUT" "$T1"
sin_mutante
unset NO_REGISTRAR

# ── Fronteras de fuga: tope duro de lectura (1 MiB, fstat) y credenciales de 4 a 7 caracteres ──
sin_frag() { # ninguna de las cadenas aparece en stdout ni en stderr del último caso
  local t
  for t in "$@"; do
    if printf '%s\n' "$OUT" | grep -qF -e "$t" || grep -qF -e "$t" "$C/stderr"; then return 1; fi
  done
  return 0
}
err_crudo() { # <caso> <bytes> <cabecera> <cola>: doctor.err de EXACTAMENTE <bytes> bytes: cabecera, relleno de espacios, salto y cola
  python3 -c 'import sys; n, cab, cola = int(sys.argv[1]), sys.argv[2], "\n" + sys.argv[3]; open(sys.argv[4], "wb").write((cab + " " * (n - len(cab) - len(cola)) + cola).encode())' \
    "$2" "$3" "$4" "$1/doctor.err.crudo"
}
TOPE=1048576
# Frontera 1: exactamente el tope, con la credencial partida cerca del final → se lee entero y se enmascara
nuevo_caso; echo 1 >"$C/doctor.rc"; err_crudo "$C" "$TOPE" "error reflejado $T1" "$T2"; correr "$C"
afirmar "Frontera tope: el fichero mide exactamente 1048576 bytes" bash -c '[ "$(stat -c %s "$1/doctor.err.crudo")" = "$2" ]' _ "$C" "$TOPE"
afirmar "Frontera tope exacto: token partido cerca del final, ningún fragmento sale" sin_frag "$T1" "$T2"
roja "tope exacto con el token partido al final" credencial-reflejada
afirmar "Frontera tope exacto: no se declara detalle-no-acotado" bash -c '! printf "%s\n" "$1" | grep -q detalle-no-acotado' _ "$OUT"
# Frontera 2: un byte por encima → detalle-no-acotado, sin leer ni publicar el contenido
nuevo_caso; echo 1 >"$C/doctor.rc"; err_crudo "$C" "$((TOPE + 1))" "error reflejado $T1" "$T2"; correr "$C"
afirmar "Frontera tope superado: el fichero mide 1048577 bytes" bash -c '[ "$(stat -c %s "$1/doctor.err.crudo")" = "$2" ]' _ "$C" "$((TOPE + 1))"
roja "tope superado (1048577 bytes)" detalle-no-acotado
afirmar "Frontera tope superado: motivo fijo y ningún contenido publicado" \
  bash -c 'printf "%s\n" "$1" | grep -q "motivo=\"detalle-no-acotado\"" && ! printf "%s\n" "$1" | grep -qF -e "$2" -e "$3" -e "error reflejado"' _ "$OUT" "$T1" "$T2"
# Sondas del acta: la credencial cruza el byte 65536; y entera DESPUÉS del 65536
nuevo_caso; echo 1 >"$C/doctor.rc"; err_crudo "$C" "$((16 + ${#T1} + 65536 + 1 + ${#T2}))" "error reflejado $T1" "$T2"; correr "$C"
afirmar "Sonda doctor-cruza65536: ningún fragmento sale" sin_frag "$T1" "$T2"
roja "token que cruza el byte 65536" credencial-reflejada
nuevo_caso; echo 1 >"$C/doctor.rc"; err_crudo "$C" "$((1 + 65537 + 1 + ${#TOKEN}))" "x" "$TOKEN"; correr "$C"
afirmar "Sonda doctor-despues65536: el token entero tras 65537 espacios no sale" sin_frag "$TOKEN"
roja "token entero después del byte 65536" credencial-reflejada
# Frontera 3: credencial de 4 caracteres partida en TRES trozos en título, enlace y error
K4='Zq#7'; K4P=$'Zq\n#\n7'
for donde in titulo enlace; do
  nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$K4P" --reflejo-en "$donde"
  correr "$C" LINEAR_API_KEY="$K4"
  afirmar "Frontera 4 caracteres en tres trozos ($donde): ningún fragmento sale" sin_frag "Zq"
  roja "credencial de 4 caracteres partida en el $donde" credencial-reflejada
done
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'error %s' "$K4P" >"$C/doctor.msg"; correr "$C" LINEAR_API_KEY="$K4"
afirmar "Frontera 4 caracteres en tres trozos (error): ningún fragmento sale" sin_frag "Zq"
roja "credencial de 4 caracteres partida en el error" credencial-reflejada
# Sonda del acta sentry-corta7: 7 caracteres partidos en título, enlace y error
K7P=$'ZXQ\n9876'
for donde in titulo enlace; do
  nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$K7P" --reflejo-en "$donde"
  correr "$C" LINEAR_API_KEY=ZXQ9876
  afirmar "Sonda corta7 ($donde): ningún fragmento sale" sin_frag "ZXQ"
  roja "credencial de 7 caracteres partida en el $donde" credencial-reflejada
done
nuevo_caso; echo 1 >"$C/doctor.rc"; printf 'error %s' "$K7P" >"$C/doctor.msg"; correr "$C" LINEAR_API_KEY=ZXQ9876
afirmar "Sonda corta7 (error): ningún fragmento sale" sin_frag "ZXQ"
roja "credencial de 7 caracteres partida en el error" credencial-reflejada
# Frontera 4: credencial de menos de 4 caracteres → rc 2, sin cifras y sin el valor en ninguna salida
nuevo_caso; correr "$C" LINEAR_API_KEY=Qz7
afirmar "Frontera 3 caracteres (LINEAR_API_KEY): rc 2, ninguna cifra por stdout" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
afirmar "Frontera 3 caracteres: el mensaje de stderr no contiene el valor" bash -c 'grep -q PRECOND "$1/stderr" && ! grep -qF Qz7 "$1/stderr"' _ "$C"
nuevo_caso; printf 'Authorization: Bearer ab\n' >"$C/sentry.hdr"; chmod 600 "$C/sentry.hdr"; correr "$C"
afirmar "Frontera 2 caracteres (header-file): rc 2 y ninguna cifra por stdout" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
# Control: con una credencial de 4 caracteres registrada, un texto normal no da falso rojo
nuevo_caso; correr "$C" LINEAR_API_KEY="$K4"
afirmar "Control: credencial de 4 caracteres registrada y texto normal: LIMPIO, rc 0" bash -c '[ "$1" = 0 ] && printf "%s\n" "$2" | head -1 | grep -q "estado=LIMPIO causas=ninguna"' _ "$RC" "$OUT"
# Mutantes: umbral devuelto a 8 y lectura acotada devuelta a f.read(65536)
NO_REGISTRAR=1
nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 150 --nuevos 1 --nuevos-hace-min 40 --gh 5 --estado-previo 300 --reflejo "$K4P" --reflejo-en titulo
con_mutante parte_guardia.sh 'LONGITUD_MIN_CREDENCIAL = 4' 'LONGITUD_MIN_CREDENCIAL = 8'
correr "$C" LINEAR_API_KEY="$K4"
afirmar "Frontera mutante (umbral devuelto a 8) -> el caso se pone rojo: ya no hay credencial-reflejada" bash -c '! printf "%s\n" "$1" | grep -q credencial-reflejada' _ "$OUT"
sin_mutante
nuevo_caso; echo 1 >"$C/doctor.rc"; err_crudo "$C" "$TOPE" "error reflejado $T1" "$T2"
con_mutante parte_guardia.sh 'f.read(TOPE_DETALLE)' 'f.read(65536)'
correr "$C"
afirmar "Frontera mutante (lectura devuelta a f.read(65536)) -> el caso se pone rojo: el primer fragmento sale" bash -c 'printf "%s\n" "$1" | grep -qF -e "$2"' _ "$OUT" "$T1"
sin_mutante
unset NO_REGISTRAR

# ── C4: ancla de despliegue (main-movido) ──
nuevo_caso; correr "$C" SENTRY_MAIN_MOVIDO="$C/no-existe"
afirmar "C4 ancla ausente: «sin ancla» declarado y no es fallo" \
  bash -c '[ "$1" = 0 ] && printf "%s\n" "$2" | grep -q "metric=post_despliegue_ventana value=sin-ancla"' _ "$RC" "$OUT"
correr "$C" SENTRY_MAIN_MOVIDO="$C/no-existe" TA_PARTE_EXIGE_ANCLA=1
roja "ancla ausente en una instancia que la exige" ancla-exigida-ausente
for malo in "abcdef1" "1760000000" "1760000000 zzzz" "x 1760000000" "$(( $(date +%s) + 7200 )) abcdef1"; do
  printf '%s\n' "$malo" >"$C/main-movido"; correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
  roja "ancla mal formada («$malo»)" ancla-mal-formada
done
printf '1760000000 abcdef1\n1760000100 abcdef2\n' >"$C/main-movido"; correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
roja "ancla con dos líneas" ancla-mal-formada
echo "$(( $(date +%s) - 10800 )) abcdef1" >"$C/main-movido"; correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
afirmar "C4 ancla bien formada pero de hace 3 h: ventana cerrada, post-despliegue NA" \
  bash -c 'printf "%s\n" "$1" | grep -q "metric=post_despliegue_ventana value=cerrada" && printf "%s\n" "$1" | grep -q "metric=sentry_nuevos_post_despliegue value=NA"' _ "$OUT"
con_mutante parte_guardia.sh 'roja.append("ancla-mal-formada")' 'pass'
printf 'abcdef1\n' >"$C/main-movido"; correr "$C" SENTRY_MAIN_MOVIDO="$C/main-movido"
afirmar "C4 mutante (ancla mal formada tolerada) -> el caso se pone rojo" bash -c '! printf "%s\n" "$1" | head -1 | grep -q "estado=SONDA-ROJA"' _ "$OUT"
sin_mutante

# ── C5: más de una página de grupos; tope de páginas ──
nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 250 --gh 5 --estado-previo 300; correr "$C"
afirmar "C5 250 grupos en 3 páginas: sentry_unresolved_total cuenta todas" tiene 'metric=sentry_unresolved_total value=250 *$'
nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 2100 --gh 5 --estado-previo 300; correr "$C"
roja "más de 20 páginas (2.100 grupos): el tope es un fallo, no un truncado" sentry-consulta-fallida

# ── C6: dinero ──
nuevo_caso; correr "$C" SENTRY_PARTE_MONEY_SQL=
roja "SENTRY_PARTE_MONEY_SQL ausente" DINERO-NO-CONFIGURADO
afirmar "C6 se declara DINERO-NO-CONFIGURADO" tiene 'metric=dinero_estado value=DINERO-NO-CONFIGURADO'
con_mutante parte_guardia.sh 'roja.append("DINERO-NO-CONFIGURADO")' 'pass'
correr "$C" SENTRY_PARTE_MONEY_SQL=
afirmar "C6 mutante (dinero sin configurar tolerado) -> el caso se pone rojo" bash -c '! printf "%s\n" "$1" | head -1 | grep -q "estado=SONDA-ROJA"' _ "$OUT"
sin_mutante
for sql in 'borra\tdelete from sales' 'doble\tselect 1; drop table sales' 'cte\twith x as (delete from t returning 1) select 1 from x' 'ddl\tcreate table x(a int)' 'seleccion_into\tselect 1 into tabla_sonda' 'cte_into\twith x as (select 1 as a) select a into tabla_sonda from x'; do
  nuevo_caso; printf "$sql\n" >"$C/dinero.tsv"; correr "$C"
  roja "consulta que no es select/with de una sentencia («${sql%%\\t*}»)" dinero-rechazada
  afirmar "C6 «${sql%%\\t*}»: la API de dinero ni se llamó" bash -c '! [ -e "$1/curl-cuerpos.log" ]' _ "$C"
done
# Mutante de m1: retirar «into» de la lista de verbos deja pasar SELECT … INTO (la API sí se llama).
con_mutante parte_guardia.sh '|do|into)(' '|do)('
nuevo_caso; printf 'seleccion_into\tselect 1 into tabla_sonda\n' >"$C/dinero.tsv"; correr "$C"
afirmar "C6 mutante (sin «into» en la lista de verbos) -> el caso se pone rojo: la API se llamó" bash -c '[ -e "$1/curl-cuerpos.log" ]' _ "$C"
sin_mutante
nuevo_caso; printf '500\n{}\n' >"$C/dinero.respuesta"; correr "$C"
roja "dinero con HTTP 500" dinero-fallida
nuevo_caso; printf '201\n{"a":1}\n' >"$C/dinero.respuesta"; correr "$C"
roja "dinero con respuesta que no es lista" dinero-fallida
nuevo_caso; printf '201\n[{"id":1}]\n' >"$C/dinero.respuesta"; correr "$C"
afirmar "C6 una fila de dinero es NOVEDAD con su cifra" bash -c '[ "$1" = 0 ] && printf "%s\n" "$2" | head -1 | grep -q "estado=NOVEDAD" && printf "%s\n" "$2" | grep -q "metric=dinero_ventas_atascadas value=1"' _ "$RC" "$OUT"
afirmar "C6 la consulta viaja read_only y el token no va por argv" \
  bash -c 'grep -q "\"read_only\": true" "$1/curl-cuerpos.log" && ! grep -q "$2" "$1/curl-argv.log"' _ "$C" "$TOKEN"

# ── C7: el repo es el declarado, o rc 2 sin una sola cifra ──
nuevo_caso
correr "$C" TA_PARTE_REPO=; afirmar "C7 repo sin declarar: rc 2 y cero salida" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
correr "$C" TA_PARTE_REPO_ID=1:1; afirmar "C7 inodo distinto: rc 2 y cero salida" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
correr "$C" TA_PARTE_REPO=repo-relativo; afirmar "C7 ruta relativa: rc 2 y cero salida" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
CWD="$AJENO" correr "$C" TA_PARTE_REPO="$AJENO" TA_PARTE_REPO_ID="$REPO_ID"
afirmar "C7 cron simulado (cwd = repo ajeno, repo declarado con otra identidad): rc 2 y cero salida" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
afirmar "C7 con rc 2 no se hizo ni una petición a Sentry" bash -c '! [ -e "$1/sentry-peticiones.log" ]' _ "$C"
CWD="$AJENO" correr "$C"
afirmar "C7 con cwd en OTRO repo el árbol sigue siendo el del repo declarado" tiene "tree=$TREE_REPO "
con_mutante parte_guardia.sh '\[ "\$ID_REAL" = "\$TA_PARTE_REPO_ID" \] || precond' 'true'
CWD="$AJENO" correr "$C" TA_PARTE_REPO="$AJENO" TA_PARTE_REPO_ID="$REPO_ID"
afirmar "C7 mutante (sin comprobar el inodo) -> el caso se pone rojo" bash -c '[ "$1" != 2 ]' _ "$RC"
sin_mutante

# ── C8: cadencia leída del perfil; el silencio también es alerta ──
nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 150 --gh 5 --estado-previo 3600; correr "$C"
afirmar "C8 parte previo hace 60 min con cadencia de 15: silencio_previo=60 (umbral 30) y no LIMPIO" \
  bash -c 'printf "%s\n" "$1" | head -1 | grep -q "estado=NOVEDAD" && printf "%s\n" "$1" | grep -q "metric=silencio_previo value=60 umbral_min=\"30\""' _ "$OUT"
nuevo_caso; echo '*/10' >"$C/cron.out"; python3 "$FIX/generar.py" "$C" --grupos 150 --gh 5 --estado-previo 1500; correr "$C"
afirmar "C8 cadencia */10 leída del perfil: umbral derivado 20, 25 min de silencio = NOVEDAD" \
  tiene 'metric=silencio_previo value=25 umbral_min="20"'
nuevo_caso; echo '30' >"$C/cron.out"; correr "$C"
afirmar "C8 un solo minuto por hora: cadencia 60" tiene 'metric=cadencia_min value=60 *$'
nuevo_caso; rm -f "$C/cron.out"; correr "$C"
roja "sin fila cron en el perfil" SILENCIO-NO-MEDIDO
nuevo_caso; correr "$C"
afirmar "C8 parte previo hace 5 min: silencio_previo=5 y LIMPIO" bash -c 'printf "%s\n" "$1" | grep -q "metric=silencio_previo value=5 " && printf "%s\n" "$1" | head -1 | grep -q "estado=LIMPIO"' _ "$OUT"
nuevo_caso; rm -f "$C/estado.json"; correr "$C"
afirmar "C8 primer parte (sin estado previo): silencio_previo=NA declarado" tiene 'metric=silencio_previo value=NA'

# ── C10: carga (2.000 grupos en 20 páginas, 300 alertas de GitHub en 3 páginas) idéntica a la línea base ──
normalizar() { sed -E 's/tree=[0-9a-f]{40,64}/tree=TREE/; s/instant=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/instant=INSTANT/'; }
nuevo_caso; python3 "$FIX/generar.py" "$C" --grupos 2000 --nuevos 3 --gh 300 --gh-nuevos 2 --estado-previo 330
cp "$C/estado.json" "$C/estado.semilla"
correr "$C"; r1="$RC"; printf '%s\n' "$OUT" | normalizar >"$TMP/carga-1.txt"
cp "$C/estado.semilla" "$C/estado.json"
correr "$C"; r2="$RC"; printf '%s\n' "$OUT" | normalizar >"$TMP/carga-2.txt"
[ -z "${SALIDA:-}" ] || cp "$TMP/carga-1.txt" "$SALIDA/carga-normalizada.txt"
afirmar "C10 carga: rc 0 las dos veces" bash -c '[ "$1" = 0 ] && [ "$2" = 0 ]' _ "$r1" "$r2"
afirmar "C10 carga: salida normalizada idéntica a baseline-carga.txt (corrida 1)" diff -u "$FIX/baseline-carga.txt" "$TMP/carga-1.txt"
afirmar "C10 carga: salida normalizada idéntica a baseline-carga.txt (corrida 2)" diff -u "$FIX/baseline-carga.txt" "$TMP/carga-2.txt"
afirmar "C10 carga: 2.000 grupos contados en las 20 páginas" grep -q 'metric=sentry_unresolved_total value=2000' "$TMP/carga-1.txt"

# ── Ningún token ni valor de secret en NINGUNA salida de ningún caso ──
afirmar "Invariante: ni el token de prueba ni el secreto sintético salen por ninguna salida (0 apariciones)" \
  bash -c '[ -s "$1" ] && [ "$(grep -c -e "$2" -e "$3" "$1" || true)" = 0 ]' _ "$TMP/todo.out" "$TOKEN" "$SECRETO"

echo "RESULTADO: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" = 0 ]
