#!/usr/bin/env bash
# Fixtures NEGATIVOS del gate M5: el gate debe devolver rc=1 ante (1) secreto
# staged, (2) secreto solo en un commit intermedio ya "tapado", (3) binario en
# commit, (4) secreto en untracked — y rc=0 en historia limpia. Esto prueba la
# PROPAGACION real del contador (el fallo de subshell de la ronda 4 pasaba
# todos los casos positivos y ninguno de estos).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/probar-antifugas.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0

# nsec sintetico que SI matchea el regex del gate (58 chars del charset tras
# nsec1) — jamas una clave real. Se compone en runtime para que este archivo
# fuente NO contenga un literal que el propio gate marcaria como fuga.
CHARSET="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
FAKE_NSEC="nsec1${CHARSET}${CHARSET:0:26}"

repo_nuevo() {
  local d="$TMP/$1"
  git init -q -b main "$d"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$d" checkout -q -b rama
  echo "$d"
}

caso() { # $1 nombre, $2 rc esperado, $3 repo, resto: args del gate
  local nombre="$1" esperado="$2" repo="$3"; shift 3
  local rc=0
  (cd "$repo" && bash "$GATE" "$@") >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$esperado" ]; then
    echo "OK  $nombre (rc=$rc)"
  else
    echo "FALLO $nombre: rc=$rc, esperado $esperado"; fallos=$((fallos+1))
  fi
}

# 1. Secreto staged -> rc 1
R=$(repo_nuevo caso1)
echo "clave=$FAKE_NSEC" > "$R/config.txt"
git -C "$R" add config.txt
caso "secreto staged" 1 "$R" --cached

# 2. Secreto en commit intermedio, tapado despues -> rc 1 (el diff acumulado
#    estaria limpio; el gate por-commit NO)
R=$(repo_nuevo caso2)
echo "clave=$FAKE_NSEC" > "$R/config.txt"
git -C "$R" add config.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "mete secreto"
echo "clave=PLACEHOLDER" > "$R/config.txt"
git -C "$R" add config.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "tapa secreto"
caso "secreto en commit intermedio tapado" 1 "$R"

# 3. Binario en commit -> rc 1. DETERMINISTA: bytes NUL explicitos, que es la
#    senal que la heuristica binaria de Git evalua. Con bytes aleatorios, una
#    muestra de 256 sin ningun NUL (~37% de las veces) producia un falso limpio
#    (no determinismo cazado en revision ronda 6): el azar no es evidencia.
R=$(repo_nuevo caso3)
printf 'KEYSTORE\000\000\000fixture binario determinista\000\000\000FIN\000' > "$R/firma.keystore"
git -C "$R" add firma.keystore && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "binario"
caso "binario en commit" 1 "$R"

# 4. Secreto en untracked -> rc 1 (modo --cached)
R=$(repo_nuevo caso4)
echo "$FAKE_NSEC" > "$R/notas sueltas.txt"   # con espacio: prueba el NUL-delimit
caso "secreto en untracked (nombre con espacio)" 1 "$R" --cached

# 4b. Secreto que entra por MERGE (critico 2 de la ronda de seguridad).
#    Forma del escape: el fichero del secreto entra al arbol por un merge cuyo
#    resultado IGUALA al padre lateral, y ese padre queda FUERA del rango
#    escaneado (aqui: la base del escaneo apunta a la rama lateral — el caso
#    real es una rama construida sobre otra, o una base que ya alcanza los
#    commits laterales). `git show` SIN -m emite el diff combinado denso, que
#    omite lo que iguala a un padre: el gate viejo decia LIMPIO con el secreto
#    embarcado (rojo demostrado). Con -m, el diff contra el PRIMER padre
#    muestra el fichero entrando y el gate falla.
R=$(repo_nuevo caso4b)
git -C "$R" checkout -q -b lado main
echo "$FAKE_NSEC" > "$R/heredado.txt"
git -C "$R" add heredado.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "rama lateral con secreto"
git -C "$R" checkout -q rama
echo "trabajo normal" > "$R/trabajo.txt"
git -C "$R" add trabajo.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "trabajo"
git -C "$R" -c user.email=t@t -c user.name=t merge -q lado -m "merge que incorpora heredado.txt"
rc=0
(cd "$R" && TB_ANTIFUGAS_BASE=lado bash "$GATE") >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  echo "OK  secreto que entra por merge igualando al padre lateral (rc=1)"
else
  echo "FALLO secreto por merge: rc=$rc, esperado 1"; fallos=$((fallos+1))
fi

# 4c. Cobertura de los OTROS patrones del regex (hallazgo 9): las claves de
#    API del despliegue y hex64, compuestas en runtime para no auto-matchear.
FAKE_SK="sk-""lead-sintetica-de-fixture"
FAKE_HEX=""; for _ in 1 2 3 4 5 6 7 8; do FAKE_HEX="${FAKE_HEX}a1b2c3d4"; done  # 64 hex
R=$(repo_nuevo caso4c)
echo "api=$FAKE_SK" > "$R/config.txt"
git -C "$R" add config.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "clave sk"
caso "patron de clave API en commit" 1 "$R"
R=$(repo_nuevo caso4d)
echo "token=$FAKE_HEX" > "$R/notas.txt"
git -C "$R" add notas.txt
caso "patron hex64 staged" 1 "$R" --cached
# 4e. Binario STAGED (el veto por numstat en modo --cached, no solo por commit)
R=$(repo_nuevo caso4e)
printf 'STAGED\000\000\000binario determinista\000FIN\000' > "$R/upload.keystore"
git -C "$R" add upload.keystore
caso "binario staged (--cached)" 1 "$R" --cached
# 4f. Secreto en el NOMBRE de un fichero commiteado
R=$(repo_nuevo caso4f)
echo "contenido inocuo" > "$R/backup-$FAKE_SK.txt"
git -C "$R" add . && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "nombre con secreto"
caso "secreto en nombre de fichero commiteado" 1 "$R"

# 4g. NO DIVULGACION (M2): el gate DETECTA, pero su propia salida NO debe
#     contener ningun secreto — ni siquiera cuando el secreto vive en el NOMBRE
#     del fichero. Ejercita los tres sitios que imprimen rutas/etiquetas no
#     confiables: label de escanea_texto (untracked <nombre>), rutas de
#     veta_binarios (numstat) y el echo de binario untracked. Se CAPTURA la
#     salida (el resto de casos la descarta) y se comprueba, en tres frentes
#     INDEPENDIENTES del detector, que no revela el secreto:
#       (1) no matchea el regex detector (RE_CHECK, no auto-matcheable);
#       (2) no aparece el VALOR sintetico completo (grep -F literal);
#       (3) no aparece un SUFIJO distintivo de la credencial SK — la redaccion
#           por-prefijo de la 1a vuelta dejaba este sufijo visible (M2, 2a vuelta).
#     (2)+(3) no dependen del mismo regex que usa el detector: si redacta solo
#     borrase el prefijo, (3) cazaria la fuga aunque (1) diese verde.
RE_CHECK='nsec1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{50,}|sk-(lead|hermes)|[0-9a-f]{64}'
SUF_SK="${FAKE_SK#sk-*-}"   # sufijo distintivo tras 'sk-lead-' -> 'sintetica-de-fixture'
R=$(repo_nuevo caso4g)
printf 'BIN\000\000\000determinista\000' > "$R/upload-$FAKE_SK.keystore"  # binario STAGED, secreto en nombre
git -C "$R" add -- "upload-$FAKE_SK.keystore"
printf '%s\n' "$FAKE_NSEC" > "$R/fuga-$FAKE_SK.txt"                       # untracked: secreto en nombre Y contenido
printf 'BIN\000\000\000determinista\000' > "$R/blob-$FAKE_HEX.bin"       # binario untracked, hex en nombre
rc=0
OUT=$(cd "$R" && bash "$GATE" --cached 2>&1) || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FALLO no-divulgacion: rc=$rc, esperado 1 (deberia detectar)"; fallos=$((fallos+1))
elif printf '%s' "$OUT" | grep -qE "$RE_CHECK"; then
  echo "FALLO no-divulgacion: la salida matchea el regex detector de secretos"; fallos=$((fallos+1))
elif printf '%s' "$OUT" | grep -qF -e "$FAKE_SK" -e "$FAKE_NSEC" -e "$FAKE_HEX"; then
  echo "FALLO no-divulgacion: la salida contiene un valor sintetico completo"; fallos=$((fallos+1))
elif printf '%s' "$OUT" | grep -qF "$SUF_SK"; then
  echo "FALLO no-divulgacion: la salida deja visible el sufijo distintivo de la credencial SK"; fallos=$((fallos+1))
else
  echo "OK  no-divulgacion: detecta (rc=1) y no revela valor, sufijo ni patron de secreto"
fi

# 5. Historia limpia -> rc 0
R=$(repo_nuevo caso5)
echo "hola" > "$R/limpio.txt"
git -C "$R" add limpio.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "limpio"
caso "historia limpia" 0 "$R"
caso "indice limpio" 0 "$R" --cached

# 6. Base inexistente -> rc 2, no "sin commits" (Alta ronda 5)
R=$(repo_nuevo caso6)
rc=0
(cd "$R" && TB_ANTIFUGAS_BASE=rama-fantasma bash "$GATE") >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  echo "OK  base inexistente falla explicito (rc=2)"
else
  echo "FALLO base inexistente: rc=$rc, esperado 2"; fallos=$((fallos+1))
fi

if [ "$fallos" -eq 0 ]; then echo "probar-antifugas-fixtures: TODO OK"; else echo "probar-antifugas-fixtures: $fallos fallos"; exit 1; fi
