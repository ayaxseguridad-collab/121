#!/usr/bin/env bash
# test-vigias.sh — Tests HERMÉTICOS de los vigías del mando (talent-ceo, ref 08).
#
# Sin red, sin ssh, sin GitHub, sin tocar nada fuera de su directorio temporal: un bus sintético con el
# formato del paquete, un perfil sintético y dobles de `date`, `df`, `du`, `timeout` y `ssh` en un PATH
# temporal. La hora "de ahora" de los vigías la fija el doble de `date` (FX_NOW): cada edad es exacta.
#
# ── MÉTODO: CADA CASO ES UNA FUNCIÓN, Y CADA GUARDA TIENE SU MUTANTE ───────────────────────────
# Un caso (`caso_cN`) corre los vigías de `$V` y devuelve UNA cadena compacta con lo observado. Se afirma
# contra la cadena esperada con los scripts REALES; y para cada guarda se corre el mismo caso contra una
# copia a la que se le quita UNA guarda (`mutante`): la cadena tiene que DIFERIR (el caso enrojece). Un
# mutante que no aplica (el literal ya no está) también es FAIL: no se puede mutar lo que no existe.
# El «control rojo» de la prueba de mejora usa tres vigías de juguete que reproducen los defectos de las
# fuentes vivas (seguir el bus en vivo, reconstruir la fecha de hoy, callar ante un bus ilegible).
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final exige que ejecutados == TOTAL_ESPERADO.
set -uo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
V="$ROOT/scripts"

TOTAL_ESPERADO=89
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }
# Un mutante o un vigía de juguete ENROJECE el caso cuando su cadena difiere de la esperada.
rojo(){ if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (no enrojeció: obtuvo lo mismo que el real '$3')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/tdvig.XXXXXX")" || exit 2
_fin() {
  : "${T:?}"
  case "$T" in "${TMPDIR:-/tmp}"/tdvig.*) chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "$T" ;; esac
}
trap _fin EXIT
export HOME="$T/home"; mkdir -p "$HOME"
REAL_DATE="$(command -v date)"
REAL_TIMEOUT="$(command -v timeout)"
REAL_CMP="$(command -v cmp)"
export FX_REAL_DATE="$REAL_DATE" FX_REAL_TIMEOUT="$REAL_TIMEOUT" FX_REAL_CMP="$REAL_CMP" FX_LOG="$T/log"; mkdir -p "$FX_LOG"
export FX_NOW=1791800000
printf '== vigías: scripts bajo prueba: %s ==\n' "$V"

# ═══ dobles en un PATH temporal ════════════════════════════════════════════════════════════════
mkdir -p "$T/bin"
cat > "$T/bin/date" <<'__FIN_DBL_DATE__'
#!/usr/bin/env bash
# FX_DATE_PARA: se detiene justo cuando el vigía pide la hora para EMITIR un evento (así el caso de la
# interrupción corta el tick entre decidir y emitir) y sigue cuando existe FX_DATE_LIBERA.
if [ -n "${FX_DATE_PARA-}" ] && [ "$*" = '-u +%H:%M:%SZ' ] && [ ! -e "$FX_DATE_LISTO" ]; then
  printf 'listo\n' > "$FX_DATE_LISTO"
  for _ in $(seq 1 150); do [ -e "$FX_DATE_LIBERA" ] && break; sleep 0.2; done
fi
# FX_DATE_FALLA_EN=n: la n-ésima petición de hora para un evento FALLA (la emisión de ese evento falla de
# forma conocida: el vigía no puede ponerle hora y devuelve rc 2), sin matar ningún proceso.
if [ -n "${FX_DATE_FALLA_EN-}" ] && [ "$*" = '-u +%H:%M:%SZ' ]; then
  n=$(( $(cat "$FX_DATE_CONT" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FX_DATE_CONT"
  [ "$n" -ne "$FX_DATE_FALLA_EN" ] || exit 1
fi
if [ -n "${FX_NOW-}" ]; then
  case "$*" in
    '-u +%s'|'+%s') printf '%s\n' "$FX_NOW"; exit 0 ;;
    '-u +%H:%M:%SZ') exec "$FX_REAL_DATE" -u -d "@$FX_NOW" +%H:%M:%SZ ;;
  esac
fi
exec "$FX_REAL_DATE" "$@"
__FIN_DBL_DATE__
cat > "$T/bin/df" <<'__FIN_DBL_DF__'
#!/usr/bin/env bash
[ -z "${FX_DF_FALLA-}" ] || exit 1
case "$*" in
  *ipcent*) if [ "${FX_IPCENT-}" = '-' ]; then printf 'IUse%%\n-\n'; else printf 'IUse%%\n %s%%\n' "${FX_IPCENT-0}"; fi ;;
  *pcent*)  printf 'Use%% Avail\n %s%% %s\n' "${FX_PCENT-0}" "${FX_AVAIL-52428800}" ;;
  *) exit 2 ;;
esac
__FIN_DBL_DF__
cat > "$T/bin/du" <<'__FIN_DBL_DU__'
#!/usr/bin/env bash
for a in "$@"; do ult="$a"; done
printf '%s\t%s\n' "${FX_DU_GB-0}" "$ult"
exit "${FX_DU_RC-0}"
__FIN_DBL_DU__
cat > "$T/bin/timeout" <<'__FIN_DBL_TIMEOUT__'
#!/usr/bin/env bash
# Solo finge el tiempo agotado de `du`; todo lo demás va al timeout real.
if [ "${2-}" = du ]; then
  [ "${FX_TIMEOUT_AGOTA-}" != 1 ] || exit 124
  shift; exec "$@"
fi
exec "$FX_REAL_TIMEOUT" "$@"
__FIN_DBL_TIMEOUT__
cat > "$T/bin/ssh" <<'__FIN_DBL_SSH__'
#!/usr/bin/env bash
{ printf 'CALL\n'; printf '<%s>\n' "$@"; } >> "$FX_LOG/ssh.log"
while [ $# -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) shift ;; esac
done
host="$1"
[ "${FX_SSH_FALLA-}" = "$host" ] && { echo "ssh: fallo simulado" >&2; exit 255; }
[ -z "${FX_SSH_SLEEP-}" ] || sleep "$FX_SSH_SLEEP"
printf '%s %s\n' "${FX_NUC-4}" "${FX_CARGA-0.10}"
__FIN_DBL_SSH__
cat > "$T/bin/cmp" <<'__FIN_DBL_CMP__'
#!/usr/bin/env bash
# FX_CMP_CAMBIA=1: DESPUÉS de una comparación real que da igual (rc 0) cambia viejo por nuevo en el bus (mismo
# tamaño), una sola vez. Es la ventana entre el contraste del tramo y el guardado del cursor.
"$FX_REAL_CMP" "$@"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FX_CMP_CAMBIA-}" ] && [ ! -e "$FX_CMP_MARCA" ]; then
  printf 'hecho\n' > "$FX_CMP_MARCA"
  texto="$(cat "$TA_BUS")"; printf '%s\n' "${texto/viejo/nuevo}" > "$TA_BUS"
fi
exit "$rc"
__FIN_DBL_CMP__
chmod 755 "$T/bin/"*

# /proc sintético para la máquina local (4 núcleos) y perfil sintético con una local y una remota.
mkdir -p "$T/proc"
for i in 0 1 2 3; do printf 'processor\t: %s\nmodel name\t: sintetico\n\n' "$i"; done > "$T/proc/cpuinfo"
carga_loc() { printf '0.00 %s 0.00 1/100 123\n' "$1" > "$T/proc/loadavg"; }
carga_loc 0.10
PF="$T/perfil.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tm-loc\tm-loc\t-\t-\tacceso=local\n'
  printf 'maquina\tm-rem\tm-rem\t-\t-\trol=satelite\n'; } > "$PF"

# ═══ utilidades de los casos ═══════════════════════════════════════════════════════════════════
iso() { "$REAL_DATE" -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# nuevo: estado y bus LIMPIOS (mktemp -d da un directorio 0700 propio, como exige el estado de la fábrica).
nuevo() { ST="$(mktemp -d "$T/st.XXXXXX")"; BUS="$(mktemp "$T/bus.XXXXXX")"; [ -z "${BUS_VACIO-}" ] || BUS=''; }
# sella <edad-seg> <rol> <marcador> <nota>: añade un sello con el formato del paquete, de hace <edad> s.
sella() { printf '%s [rol: %s] [marcador: %s] %s\n' "$(iso $((FX_NOW - $1)))" "$2" "$3" "${4-}" >> "$BUS"; }
# corre <script> args…: OUT/RC/ERR del tick, sobre el bus y el estado actuales.
corre() {
  local s="$1"; shift
  # `timeout`: un mutante que arma el bucle de `vigias.sh` donde el real rechaza la configuración no debe colgar la suite.
  OUT="$(env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" TA_PERFIL="${PERFIL:-$PF}" TA_PROC_DIR="$T/proc" TA_VIG_ESPERA=1 timeout 20 bash "$V/$s" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
nlin() { if [ -z "$OUT" ]; then echo 0; else printf '%s\n' "$OUT" | wc -l | tr -d ' '; fi; }
# dos <línea>: sus dos primeras palabras (sin `cut`: nada que bufferice).
dos() { local a="${1%% *}" r="${1#* }"; printf '%s %s' "$a" "${r%% *}"; }
# muta <nombre> <fichero> <literal-viejo> <literal-nuevo>: copia los scripts a $MV y cambia UN literal.
muta() {
  MV="$T/mut-$1"
  case "$MV" in "$T"/mut-*) rm -rf -- "$MV" ;; *) return 2 ;; esac
  mkdir -p "$MV"; cp -p "$ROOT/scripts/"*.sh "$MV/"
  local c; c="$(cat "$MV/$2")"
  case "$c" in *"$3"*) : ;; *) return 1 ;; esac
  printf '%s\n' "${c/"$3"/"$4"}" > "$MV/$2"
}
# mutante <etiqueta> <esperado-real> <caso> <fichero> <viejo> <nuevo>: el caso, con UNA guarda quitada, debe diferir.
mutante() {
  local et="$1" esp="$2" caso="$3" got vreal="$V"
  if ! muta "$et" "$4" "$5" "$6"; then bad "mutante $et: el literal a mutar ya no está en $4 (no se puede mutar lo que no existe)"; return; fi
  V="$MV"; got="$("$caso")"; V="$vreal"
  rojo "mutante $et enrojece el caso" "$got" "$esp"
}

# ═══ casos ═════════════════════════════════════════════════════════════════════════════════════
# C1: un PIDO de otro rol, una nota normal y un PIDO del rol excluido -> UNA línea; el tick siguiente, 0.
caso_c1() {
  local a b
  nuevo
  sella 300 ROLA M1 "PIDO ayuda con el gate"
  sella 200 ROLA M2 "nota normal sin nada"
  sella 100 ROLX M3 "PIDO del rol excluido"
  corre vigia-bus.sh --modo pedidos --lector L1 --excluir-rol ROLX; a="$(nlin)|${OUT% *}"
  corre vigia-bus.sh --modo pedidos --lector L1 --excluir-rol ROLX; b="$(nlin)"
  printf '%s|%s|%s' "$a" "$b" "$RC"
}
esp_c1='1|PEDIDO ROLA M1 PIDO ayuda con el gate|0|0'

# C2: un PIDO escrito mientras ningún tick corre (vigía caducado) lo entrega el primer tick tras el hueco.
caso_c2() {
  local a
  nuevo
  sella 500 ROLA M1 "nota normal"
  corre vigia-bus.sh --modo pedidos --lector L2; a="$(nlin)"
  sella 60 ROLA M2 "PIDO decision durante el hueco"
  sella 30 ROLA M3 "otra nota"
  corre vigia-bus.sh --modo pedidos --lector L2
  printf '%s|%s|%s' "$a" "$(nlin)" "${OUT% *}"
}
esp_c2='0|1|PEDIDO ROLA M2 PIDO decision durante el hueco'

# C3: un rojo -> `ROJO <rol> <marcador> …` una vez; un PIDO no sale en modo rojos; --patron sustituye al vocabulario.
caso_c3() {
  local a b c
  nuevo
  sella 300 ROLA M1 "gate en ROJO por unit"
  sella 200 ROLA M2 "nota normal"
  sella 100 ROLA M3 "PIDO ayuda"
  corre vigia-bus.sh --modo rojos --lector L3; a="$(nlin)|${OUT% *}"
  corre vigia-bus.sh --modo rojos --lector L3; b="$(nlin)"
  sella 50 ROLA M4 "algo especial"
  corre vigia-bus.sh --modo rojos --lector L3 --patron 'especial'; c="$(nlin)"
  printf '%s|%s|%s' "$a" "$b" "$c"
}
esp_c3='1|ROJO ROLA M1 gate en ROJO por unit|0|1'

# C4: edad del último sello de otro rol por transición: 25 min, 30 h (=1800 min, sin envoltura de 24 h),
# 2 min (calla) y re-armado al volver a haber sellos.
caso_c4() {
  local r m
  nuevo; sella 1500 ROLA M1 "ultimo de otro"; sella 60 ROLX M2 "sello propio"
  corre vigia-silencio.sh --excluir-rol ROLX; m="${OUT#SILENCIO-BUS }"; r="$(nlin)|${m%% *}"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  nuevo; sella 108000 ROLA M3 "hace treinta horas"; sella 60 ROLX M4 "sello propio"
  corre vigia-silencio.sh --excluir-rol ROLX; m="${OUT#SILENCIO-BUS }"; r="$r|$(nlin)|${m%% *}"
  nuevo; sella 120 ROLA M5 "hace dos minutos"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  nuevo; sella 1500 ROLA M6 "silencio"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  sella 120 ROLA M7 "vuelve la actividad"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  FX_NOW=$((FX_NOW + 1800))
  corre vigia-silencio.sh --excluir-rol ROLX; m="${OUT#SILENCIO-BUS }"; r="$r|$(nlin)|${m%% *}"
  printf '%s' "$r"
}
esp_c4='1|25|0|1|1800|0|1|0|1|32'

# C5: bus ausente, truncado (cursor > bus) o sin líneas con formato -> UNA línea …-NO-MEDIDO por transición, rc 0.
caso_c5() {
  local r
  nuevo; BUS="$T/no-existe-$RANDOM"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$RC|$(nlin)|${OUT%% *}"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$r|$(nlin)"
  BUS="$(mktemp "$T/bus.XXXXXX")"; sella 10 ROLA M1 "nota"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$r|$(nlin)"
  BUS="$T/no-existe-$RANDOM"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$r|$(nlin)"
  nuevo; sella 30 ROLA M2 "uno"; sella 20 ROLA M3 "dos"; sella 10 ROLA M4 "tres"
  corre vigia-bus.sh --modo rojos --lector L5; r="$r|$(nlin)"
  printf 'x\n' > "$BUS"
  corre vigia-bus.sh --modo rojos --lector L5; r="$r|$RC|$(nlin)|${OUT%% *}"
  nuevo; printf 'basura sin formato\nmas basura\n' >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$r|$(nlin)"
  corre vigia-bus.sh --modo pedidos --lector L5; r="$r|$(nlin)"
  nuevo; BUS="$T/no-existe-$RANDOM"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$RC|$(nlin)|${OUT%% *}"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  nuevo; printf 'basura sin formato\n' >> "$BUS"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  nuevo; sella 60 ROLX M5 "solo sellos propios"
  corre vigia-silencio.sh --excluir-rol ROLX; r="$r|$(nlin)"
  printf '%s' "$r"
}
esp_c5='0|1|PEDIDO-NO-MEDIDO|0|0|1|0|0|1|ROJO-NO-MEDIDO|1|0|0|1|SILENCIO-BUS-NO-MEDIDO|0|1|1'

# C6: máquina del perfil ociosa >= N min -> una vez; la carga alta reinicia el contador; ssh caído -> NO-MEDIDO.
caso_c6() {
  local r='' t0="$FX_NOW" t w
  nuevo; carga_loc 0.10
  for t in 0 600 1200 1800 2400; do
    FX_NOW=$((t0 + t)); corre vigia-ociosa.sh --maquina m-loc --hueco-max 3600; r="$r$(nlin)"
    if [ "$t" = 1800 ]; then w="${OUT% *}"; fi
  done
  r="$r|$w"
  FX_NOW=$((t0 + 3000)); carga_loc 2.00; corre vigia-ociosa.sh --maquina m-loc --hueco-max 3600; r="$r|$(nlin)"
  carga_loc 0.10; r="$r|"
  for t in 3600 4200 4800; do FX_NOW=$((t0 + t)); corre vigia-ociosa.sh --maquina m-loc --hueco-max 3600; r="$r$(nlin)"; done
  FX_NOW=$((t0 + 5400)); carga_loc 2.00; corre vigia-ociosa.sh --maquina m-loc --hueco-max 3600; r="$r|$(nlin)"
  FX_NOW=$((t0 + 6000)); carga_loc 0.10; corre vigia-ociosa.sh --maquina m-loc --hueco-max 3600; r="$r|$(nlin)"
  FX_NOW=$((t0 + 7000)); FX_SSH_FALLA=m-rem corre vigia-ociosa.sh --maquina m-rem; w="${OUT%% no se pudo*}"; r="$r|$(nlin)|$w"
  FX_NOW=$((t0 + 7300)); FX_SSH_FALLA=m-rem corre vigia-ociosa.sh --maquina m-rem; r="$r|$(nlin)"
  for t in 7600 8200 8800 9400; do
    FX_NOW=$((t0 + t)); FX_NUC=8 FX_CARGA=0,50 corre vigia-ociosa.sh --maquina m-rem --hueco-max 3600
  done
  r="$r|$(nlin)|${OUT% *}"
  printf '%s' "$r"
}
esp_c6='00010|OCIOSA m-loc carga5m 0.10/4 < 0.30 por núcleo durante 30 min|0|000|0|0|1|OCIOSA-NO-MEDIDO m-rem|0|1|OCIOSA m-rem carga5m 0.50/8 < 0.30 por núcleo durante 30 min'

# C7: inodos al 84, 91, 91, 70 y 90 % (cinco ticks) y un arranque sin estado con el 91 %; "-" y df caído -> NO-MEDIDO.
caso_c7() {
  local r='' v
  nuevo
  for v in 84 91 91 70 90; do FX_IPCENT=$v corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r$(nlin)"; done
  nuevo; FX_IPCENT=91 corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$(nlin)|${OUT% *}"
  nuevo; FX_IPCENT='-' corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$(nlin)|${OUT%% /tmp*}"
  FX_IPCENT='-' corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$(nlin)"
  nuevo; FX_DF_FALLA=1 corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$RC|$(nlin)"
  printf '%s' "$r"
}
esp_c7='01001|1|INODOS /tmp al 91 % (umbral 85 %)|1|INODOS-NO-MEDIDO|0|0|1'

# C8: disco al 89, 92, 96, 98, 99, 80 y 98 % -> una línea por umbral cruzado (90, 95, 97); el descenso calla.
caso_c8() {
  local r='' v m
  nuevo
  for v in 89 92 96 98 99 80 98; do
    FX_PCENT=$v corre vigia-recursos.sh --modo disco --ruta /
    if [ "$(nlin)" = 1 ]; then m="${OUT#*umbral }"; r="$r|1:${m%% *}"; else r="$r|0"; fi
  done
  nuevo; FX_PCENT=96 corre vigia-recursos.sh --modo disco --ruta /; m="${OUT#*umbral }"; r="$r|$(nlin):${m%% *}|${OUT% *}"
  nuevo; FX_DF_FALLA=1 corre vigia-recursos.sh --modo disco --ruta /; r="$r|$(nlin)|${OUT%% / *}"
  printf '%s' "$r"
}
esp_c8='|0|1:90|1:95|1:97|0|0|1:97|1:95|DISCO / al 96 % (50 GB libres) umbral 95 %|1|DISCO-NO-MEDIDO'

# C9: carpeta sobre el tope; igual; luego du agotando el tiempo; sin tope declarado; sin carpetas; du caído.
caso_c9() {
  local r=''
  nuevo
  FX_DU_GB=150 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$(nlin)|${OUT% *}"
  FX_DU_GB=150 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$r|$(nlin)"
  FX_TIMEOUT_AGOTA=1 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$r|$(nlin)|${OUT%% (du*}"
  FX_TIMEOUT_AGOTA=1 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$r|$(nlin)"
  nuevo; corre vigia-recursos.sh --modo carpeta --carpeta /datos/b; r="$r|$(nlin)|${OUT%% (usa*}"
  corre vigia-recursos.sh --modo carpeta --carpeta /datos/b; r="$r|$(nlin)"
  nuevo; corre vigia-recursos.sh --modo carpeta; r="$r|$(nlin)|${OUT%%: usa*}"
  corre vigia-recursos.sh --modo carpeta; r="$r|$(nlin)"
  nuevo; FX_DU_RC=1 FX_DU_GB=50 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$r|$(nlin)|${OUT%% (du*}"
  nuevo; FX_DU_RC=1 FX_DU_GB=300 corre vigia-recursos.sh --modo carpeta --carpeta /datos/a=100; r="$r|$(nlin)"
  printf '%s' "$r"
}
esp_c9='1|CARPETA /datos/a = 150 GB > tope 100 GB|0|1|CARPETA-NO-MEDIDO /datos/a|0|1|CARPETA-SIN-TOPE /datos/b sin tope declarado|0|1|CARPETA-SIN-TOPE no se declaró ninguna carpeta|0|1|CARPETA-NO-MEDIDO /datos/a|1'

# C10: texto hostil del bus -> cada evento es UNA línea <= 220 bytes, UTF-8 válido, sin controles, con hora medida.
caso_c10() {
  local largo='' i l mb mc r
  nuevo
  for i in $(seq 1 60); do largo="${largo}éáñ€"; done
  printf '%s [rol: ROLA] [marcador: M10] PIDO \033[31mrojo\033[0m c1\xc2\x9bc1 nul\0nul\ttab ñandú inv\xffalido %s %s\n' \
    "$(iso $((FX_NOW - 5)))" "$largo" "$largo" >> "$BUS"
  printf '%s [rol: ROLA] [marcador: M11] PIDO %s\n' "$(iso $((FX_NOW - 4)))" "$(printf 'x%.0s' $(seq 1 400))" >> "$BUS"
  # El recorte por bytes cae EXACTO en el primer byte de «é»: el corte parte el carácter y hay que quitarlo.
  printf '%s [rol: ROLA] [marcador: M12] PIDO %séééé\n' "$(iso $((FX_NOW - 3)))" "$(printf 'x%.0s' $(seq 1 188))" >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector L10
  r="$(nlin)"
  mb=0; mc=0
  while IFS= read -r l; do
    [ "${#l}" -le "$mb" ] || mb="${#l}"
    n="$( (export LC_ALL=C.utf8; printf '%s' "$l" | { read -r x; printf '%s' "${#x}"; }) )"
    [ "$n" -le "$mc" ] || mc="$n"
  done < <(printf '%s\n' "$OUT")
  r="$r|$mb|$mc"
  r="$r|$(printf '%s' "$OUT" | LC_ALL=C grep -c $'[\001-\010\013-\037\177]\\|\xc2[\x80-\x9f]')"
  printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; r="$r|$?"
  l="$(printf '%s\n' "$OUT" | head -n 1)"
  printf '%s\n' "$l" | grep -Eq ' [0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; r="$r|$?"
  printf '%s' "$OUT" | grep -q 'ñandú'; r="$r|$?"
  printf '%s' "$r"
}
esp_c10='3|220|220|0|0|0|0'

# C11 (una vez): arranca con VIGIAS-ARMADOS y termina con VIGIAS-PARADOS; un tick fallido es VIGIA-FALLO, rc 1.
caso_c11a() {
  local r h
  nuevo; sella 100 ROLA M1 "nota"
  corre vigias.sh --una-vez --excluir-rol ROLX
  r="$RC|${OUT%% *}|$(dos "${OUT##*$'\n'}")|$(nlin)"
  nuevo; sella 100 ROLA M1 "nota"
  h="$(printf '%s' / | cksum)"; h="${h%% *}"
  mkdir -m 700 "$ST/vigias"; mkdir "$ST/vigias/disco-$h-90.estado"
  corre vigias.sh --una-vez --excluir-rol ROLX
  r="$r|$RC|$(printf '%s\n' "$OUT" | grep -c '^VIGIA-FALLO disco')|$(dos "${OUT##*$'\n'}")"
  printf '%s' "$r"
}
esp_c11a='0|VIGIAS-ARMADOS|VIGIAS-PARADOS rc=0|3|1|1|VIGIAS-PARADOS rc=1'

# C11 (bucle): cortado con TERM, termina SOLO a sus hijos, escribe VIGIAS-PARADOS y un señuelo del mismo
# grupo sigue vivo. Corre en su propia sesión (setsid): una mutación que señale al grupo no alcanza a este test.
caso_c11b() {
  local vp dp hijos='' h t1 el vivo hmuerto fin
  nuevo; sella 100 ROLA M1 "nota"
  rm -f "$T/decoy.pid" "$T/vig.pid" "$T/vloop.out"
  env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" TA_PERFIL="$PF" TA_PROC_DIR="$T/proc" \
      FX_IPCENT=91 FX_SSH_SLEEP=8 VV="$V" FX_DECOY="$T/decoy.pid" FX_PIDF="$T/vig.pid" \
      setsid bash "$T/lanza.sh" --excluir-rol ROLX --cada-bus 5 > "$T/vloop.out" 2> "$T/vloop.err" < /dev/null &
  for t1 in $(seq 1 40); do [ -s "$T/vig.pid" ] && [ -s "$T/decoy.pid" ] && grep -q '^INODOS' "$T/vloop.out" 2>/dev/null && break; sleep 0.25; done
  vp="$(cat "$T/vig.pid" 2>/dev/null)"; dp="$(cat "$T/decoy.pid" 2>/dev/null)"
  case "$vp$dp" in ''|*[!0-9]*) printf 'sin-arranque'; return ;; esac
  # Los hijos del multiplexor, menos el señuelo (que es hijo del lanzador, o sea del mismo PID, y NO debe tocarse).
  for h in $(ps -o pid=,stat= --ppid "$vp" 2>/dev/null | grep -v ' Z' | tr -s ' ' | tr ' ' '\n' | grep -E '^[0-9]+$'); do
    [ "$h" = "$dp" ] || hijos="$hijos $h"
  done
  t1=$SECONDS
  kill -TERM "$vp"
  for _ in $(seq 1 60); do kill -0 "$vp" 2>/dev/null || break; sleep 0.25; done
  el=$((SECONDS - t1))
  vivo=muerto; kill -0 "$dp" 2>/dev/null && vivo=vivo
  hmuerto=si; for h in $hijos; do kill -0 "$h" 2>/dev/null && hmuerto=no; done
  [ -n "$hijos" ] || hmuerto=sin-hijos
  # limpieza: solo PID registrados por este caso y verificados por su línea de órdenes
  for h in $hijos "$dp" "$vp"; do
    case "$(ps -o args= -p "$h" 2>/dev/null)" in *vigia*|*"sleep 300"*|*lanza.sh*) kill -TERM "$h" 2>/dev/null ;; esac
  done
  printf '%s|%s|%s|%s|%s' "$(grep -c '^VIGIAS-ARMADOS' "$T/vloop.out")" "$(dos "$(tail -n 1 "$T/vloop.out")")" "$vivo" "$hmuerto" "$([ "$el" -le 3 ] && echo rapido || echo lento)"
}
esp_c11b='1|VIGIAS-PARADOS rc=143|vivo|si|rapido'

# C12: sin perfil válido o con un vigía mal configurado -> rc 2 con motivo en stderr, sin salida y sin estado.
v12() {
  nuevo; corre vigias.sh "$@"
  printf '%s|%s|%s|%s' "$RC" "$(printf '%s' "$ERR" | grep -c 'PRECOND')" "$(nlin)" "$(find "$ST" -type f | wc -l | tr -d ' ')"
}
caso_c12() {
  local r=''
  printf 'esto no es un perfil\n' > "$T/malo.tsv"
  { printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'; printf 'maquina\tm-rem\tm-rem\t-\t-\trol=satelite\n'; } > "$T/sin-local.tsv"
  r="$(PERFIL="$T/no-existe.tsv" v12)"
  r="$r $(PERFIL="$T/malo.tsv" v12)"
  r="$r $(PERFIL="$T/sin-local.tsv" v12)"
  r="$r $(v12 --cada-silencio 0)"
  r="$r $(v12 --cada-bus abc)"
  r="$r $(v12 --sin nada)"
  r="$r $(v12 --maquina inexistente)"
  r="$r $(v12 --carpeta relativa=10)"
  r="$r $(BUS_VACIO=1 v12)"
  r="$r $(PERFIL="$T/no-existe.tsv" v12 --sin ociosa)"
  r="$r $(v12 --excluir-rol 'a b')"
  printf '%s' "$r"
}
esp_c12='2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0 2|1|0|0'

# Extra: sin --excluir-rol el silencio dice SIN-ROL-EXCLUIDO UNA vez (default declarado), y sigue midiendo.
caso_sinrol() {
  local r
  nuevo; sella 1500 ROLA M1 "nota"
  corre vigia-silencio.sh; r="$(nlin)|$(printf '%s\n' "$OUT" | grep -c '^SIN-ROL-EXCLUIDO')|$(printf '%s\n' "$OUT" | grep -c '^SILENCIO-BUS ')"
  corre vigia-silencio.sh; r="$r|$(nlin)"
  printf '%s' "$r"
}
esp_sinrol='2|1|1|0'

# Extra: la emisión fallida (stdout roto) devuelve rc 2 y NO pierde la transición: el tick siguiente la repite.
caso_emision() {
  local a b
  nuevo; export FX_IPCENT=91
  env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" bash "$V/vigia-recursos.sh" --modo inodos --ruta /tmp > /dev/full 2>/dev/null; a=$?
  corre vigia-recursos.sh --modo inodos --ruta /tmp; b="$(nlin)"
  unset FX_IPCENT
  printf '%s|%s' "$a" "$b"
}
esp_emision='2|1'

# R2-M1: un TERM entre decidir y emitir no pierde el aviso. El doble de `date` detiene al tick justo cuando pide
# la hora del evento; se le envía TERM por su PID (registrado y verificado por su línea de órdenes) y el tick
# siguiente tiene que emitir. Con el estado persistido antes de emitir, el reintento calla (143|0|).
caso_m1() {
  local pid a r i
  nuevo; rm -f "$T/date.listo" "$T/date.libera"
  FX_IPCENT=91 FX_DATE_PARA=1 FX_DATE_LISTO="$T/date.listo" FX_DATE_LIBERA="$T/date.libera" \
    env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" TA_VIG_ESPERA=1 \
    bash "$V/vigia-recursos.sh" --modo inodos --ruta /tmp > "$T/m1.out" 2> "$T/m1.err" &
  pid=$!
  for i in $(seq 1 60); do [ -s "$T/date.listo" ] && break; sleep 0.1; done
  [ -s "$T/date.listo" ] || { printf 'sin-parada'; return; }
  case "$(ps -o args= -p "$pid")" in *"vigia-recursos.sh --modo inodos"*) kill -TERM "$pid" ;; *) printf 'sin-tick'; return ;; esac
  wait "$pid"; a=$?
  printf 'libera\n' > "$T/date.libera"; sleep 0.5      # el doble huérfano suelta el candado heredado
  FX_IPCENT=91 corre vigia-recursos.sh --modo inodos --ruta /tmp
  r="$a|$(nlin)|${OUT% *}"
  printf '%s' "$r"
}
esp_m1='143|1|INODOS /tmp al 91 % (umbral 85 %)'

# R3-M3: el cursor solo avanza sobre bytes entregados y contrastados. `ventana` lanza un tick de vigia-bus cuyo
# primer evento queda detenido (doble de `date`) y, MIENTRAS tanto, llama a la función `$3` que toca el bus; luego
# lo libera. `$4` hace fallar la n-ésima emisión (fallo conocido: nadie muere). Deja VRC (rc) y VN (líneas emitidas).
ventana() {
  local modo="$1" lector="$2" accion="$3" falla="${4-}" pid i
  rm -f "$T/date.listo" "$T/date.libera" "$T/date.cont"
  FX_DATE_PARA=1 FX_DATE_LISTO="$T/date.listo" FX_DATE_LIBERA="$T/date.libera" FX_DATE_CONT="$T/date.cont" FX_DATE_FALLA_EN="$falla" \
    env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" TA_VIG_ESPERA=1 \
    bash "$V/vigia-bus.sh" --modo "$modo" --lector "$lector" > "$T/vent.out" 2> "$T/vent.err" &
  pid=$!
  for i in $(seq 1 60); do [ -s "$T/date.listo" ] && break; sleep 0.1; done
  "$accion"
  printf 'libera\n' > "$T/date.libera"
  wait "$pid"; VRC=$?
  VN="$(grep -c . "$T/vent.out")"
}
palabra() { if [ "$1" = pedidos ]; then PAL=PIDO; else PAL=ROJO; fi; }
sella_sobrante() { sella 5 ROLA M2 "$PAL dos"; }
reemplaza_viejo() { printf '%s [rol: ROLA] [marcador: M1] %s nuevo\n' "$(iso $((FX_NOW - 20)))" "$PAL" > "$BUS"; }

# Variante A: se sella algo entre la lectura y la entrega y la emisión del sobrante FALLA (2.ª emisión). El sobrante
# no estaba en la instantánea: no puede haberse consumido, y el tick siguiente lo entrega.
caso_ventana_a() {
  local r='' modo
  for modo in pedidos rojos; do
    nuevo; palabra "$modo"; sella 20 ROLA M1 "$PAL uno"
    ventana "$modo" LA sella_sobrante 2; r="$r$VRC|$VN"
    corre vigia-bus.sh --modo "$modo" --lector LA; r="$r|$(nlin)|${OUT% *};"
  done
  printf '%s' "$r"
}
esp_va='0|1|1|PEDIDO ROLA M2 PIDO dos;0|1|1|ROJO ROLA M2 ROJO dos;'
# Control de éxito: con stdout operativo el sobrante se entrega UNA vez (en este tick o en el siguiente) y el reintento emite 0.
caso_ventana_ok() {
  local r='' modo
  for modo in pedidos rojos; do
    nuevo; palabra "$modo"; sella 20 ROLA M1 "$PAL uno"
    ventana "$modo" LK sella_sobrante; r="$r$VN"
    corre vigia-bus.sh --modo "$modo" --lector LK; r="$r+$(nlin)"
    corre vigia-bus.sh --modo "$modo" --lector LK; r="$r+$(nlin);"
  done
  printf '%s' "$r"
}
esp_vok='1+1+0;1+1+0;'
# Variante B: el contenido ya leído cambia (mismo tamaño) antes de que termine la entrega. Lo entregado fue lo leído;
# el cambio no se consume en silencio: el tick siguiente lo dice (NO-MEDIDO) y el cursor no se mueve.
X160="$(printf 'x%.0s' $(seq 1 160))"
reemplaza_largo() { printf '%s [rol: ROLA] [marcador: M1] %s nuevo %s\n' "$(iso $((FX_NOW - 20)))" "$PAL" "$X160" > "$BUS"; }
cambia_primer_byte() { printf '3' | dd of="$BUS" conv=notrunc bs=1 count=1 2>/dev/null; }
cambia_byte_medio() { printf 'y' | dd of="$BUS" conv=notrunc bs=1 seek=100 count=1 2>/dev/null; }
sin_cambio() { :; }
# El contrato del bus es solo-añadir: un cambio en lo ya leído (corto, LARGO —fuera de los últimos 64 bytes— o en el
# PRIMER byte del tramo) entre la instantánea y la confirmación es una violación. El tick que lo ve entrega lo leído, dice
# `…-NO-MEDIDO` y NO avanza el cursor; el tick siguiente, con el bus estable, entrega el evento tal como está ahora (una
# vez) y el tercero emite 0. Cadena por modo: rc | líneas del tick 1 | primera palabra de su última línea | líneas del
# tick 2 | líneas del tick 2 que traen $busca | líneas del tick 3.
caso_cambio() {
  local v="$1" r='' modo ult busca acc
  for modo in pedidos rojos; do
    nuevo; palabra "$modo"
    case "$v" in
      corto)   sella 20 ROLA M1 "$PAL viejo"; acc=reemplaza_viejo; busca=nuevo ;;
      largo)   sella 20 ROLA M1 "$PAL viejo $X160"; acc=reemplaza_largo; busca=nuevo ;;
      primero) sella 20 ROLA M1 "$PAL viejo $X160"; acc=cambia_primer_byte; busca=viejo ;;
      medio)   sella 20 ROLA M1 "$PAL viejo $X160"; acc=cambia_byte_medio; busca=viejo ;;
      intacto) sella 20 ROLA M1 "$PAL viejo $X160"; acc=sin_cambio; busca=viejo ;;
    esac
    ventana "$modo" LB "$acc"; ult="$(tail -n 1 "$T/vent.out")"; r="$r$VRC|$VN|${ult%% *}"
    corre vigia-bus.sh --modo "$modo" --lector LB; r="$r|$(nlin)|$(printf '%s\n' "$OUT" | grep -c "$busca")"
    corre vigia-bus.sh --modo "$modo" --lector LB; r="$r|$(nlin);"
  done
  printf '%s' "$r"
}
esp_cambio='0|2|PEDIDO-NO-MEDIDO|1|1|0;0|2|ROJO-NO-MEDIDO|1|1|0;'
# Control con el bus intacto: un tick que entrega y avanza, y los siguientes emiten 0 (sin NO-MEDIDO).
esp_intacto='0|1|PEDIDO|0|0|0;0|1|ROJO|0|0|0;'
# Cambio POSTERIOR a la confirmación en la zona que guarda el cursor: el tick siguiente lo dice (NO-MEDIDO) y no avanza.
caso_posterior() {
  local r
  nuevo; PAL=PIDO; sella 20 ROLA M1 "PIDO viejo"
  corre vigia-bus.sh --modo pedidos --lector LQ; r="$(nlin)"
  reemplaza_viejo
  corre vigia-bus.sh --modo pedidos --lector LQ; r="$r|$(nlin)|${OUT%% *}"
  printf '%s' "$r"
}
esp_posterior='1|1|PEDIDO-NO-MEDIDO'
# La ventana entre el cmp y el guardado del cursor (doble de `cmp`: tras comparar igual, el bus cambia). La suma del
# cursor cubre el tramo ENTERO: el tick siguiente lo ve y dice NO-MEDIDO (sin avanzar); el tercero calla (ya dicho).
# Con $1 vacío es el control: bus intacto, un solo evento y ni NO-MEDIDO ni duplicados.
caso_ventana_cmp() {
  local r='' modo cambia="${1-}"
  for modo in pedidos rojos; do
    nuevo; palabra "$modo"; sella 20 ROLA M1 "$PAL viejo $X160"; rm -f "$T/cmp.marca"
    FX_CMP_CAMBIA="$cambia" FX_CMP_MARCA="$T/cmp.marca" corre vigia-bus.sh --modo "$modo" --lector LW; r="$r$RC|$(nlin)|${OUT%% *}"
    corre vigia-bus.sh --modo "$modo" --lector LW; r="$r|$(nlin)|${OUT%% *}"
    corre vigia-bus.sh --modo "$modo" --lector LW; r="$r|$(nlin);"
  done
  printf '%s' "$r"
}
esp_vcmp='0|1|PEDIDO|1|PEDIDO-NO-MEDIDO|0;0|1|ROJO|1|ROJO-NO-MEDIDO|0;'
esp_vcmp_ok='0|1|PEDIDO|0||0;0|1|ROJO|0||0;'
caso_ventana_cmp_si() { caso_ventana_cmp 1; }
# Un cursor viejo (suma de solo 64 bytes, sin «v2») NO se migra: es ilegible, falla cerrado y no se reescribe.
caso_cursor_viejo() {
  local r c antes s
  nuevo; sella 20 ROLA M1 "PIDO viejo $X160"      # más de 64 bytes: el cursor viejo guarda exactamente 64
  corre vigia-bus.sh --modo pedidos --lector LV; r="$(nlin)"
  c="$ST/vigias/bus-LV.cursor"
  # Cursor viejo AUTÉNTICO: dispositivo:inodo, desplazamiento al final del bus, 64 y el cksum de los últimos 64 bytes.
  s="$(tail -c 64 "$BUS" | cksum)"
  printf '%s %s 64 %s\n' "$(stat -c '%d:%i' "$BUS")" "$(wc -c < "$BUS" | tr -d ' ')" "${s%% *}" > "$c"; antes="$(cat "$c")"
  corre vigia-bus.sh --modo pedidos --lector LV; r="$r|$(nlin)|${OUT%% *}|$([ "$(cat "$c")" = "$antes" ] && echo intacto || echo tocado)"
  printf '%s' "$r"
}
esp_cviejo='1|1|PEDIDO-NO-MEDIDO|intacto'
# Envoltorios sin argumentos para `mutante` (que llama al caso sin parámetros).
caso_cambio_corto() { caso_cambio corto; }
caso_cambio_largo() { caso_cambio largo; }
caso_cambio_primero() { caso_cambio primero; }
# Identidad: el bus sustituido por otro fichero con el MISMO principio y más bytes no se lee desde el cursor.
caso_rotado() {
  local r viejo
  nuevo; sella 20 ROLA M1 "PIDO uno"
  corre vigia-bus.sh --modo pedidos --lector LR; r="$(nlin)"
  viejo="$BUS"; cp -p "$viejo" "$viejo.nuevo"; BUS="$viejo.nuevo"; sella 5 ROLA M2 "PIDO dos"; BUS="$viejo"
  mv -f "$viejo.nuevo" "$viejo"
  corre vigia-bus.sh --modo pedidos --lector LR; r="$r|$(nlin)|${OUT%% *}"
  printf '%s' "$r"
}
esp_rotado='1|1|PEDIDO-NO-MEDIDO'
# Una línea a medio escribir NO se consume: espera a su salto de línea.
caso_parcial() {
  local r
  nuevo; sella 20 ROLA M1 "PIDO uno"
  printf '%s [rol: ROLA] [marcador: M2] PIDO dos' "$(iso $((FX_NOW - 5)))" >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector LP; r="$(nlin)"
  printf '\n' >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector LP; r="$r|$(nlin)|${OUT% *}"
  printf '%s' "$r"
}
esp_parcial='1|1|PEDIDO ROLA M2 PIDO dos'

# R2-M2: un tick SIN bytes nuevos no acredita que el bus vuelva a tener formato. basura -> tick vacío -> más
# basura -> sello válido -> basura nueva: 1/0/0/0/1 avisos NO-MEDIDO (con el tick vacío re-armando saldría 1/0/1/0/1).
caso_m2() {
  local r
  nuevo
  printf 'basura\n' >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector L7; r="$(nlin)"
  corre vigia-bus.sh --modo pedidos --lector L7; r="$r$(nlin)"
  printf 'mas basura\n' >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector L7; r="$r$(nlin)"
  sella 10 ROLA M1 "sello valido"
  corre vigia-bus.sh --modo pedidos --lector L7; r="$r$(nlin)"
  printf 'basura nueva\n' >> "$BUS"
  corre vigia-bus.sh --modo pedidos --lector L7; r="$r$(nlin)"
  printf '%s' "$r"
}
esp_m2='10001'

# R2-M3: el cursor se confirma DESPUÉS de entregar. Con stdout en /dev/full el vigía da rc 2 y el reintento,
# con stdout operativo, entrega el evento (antes daba rc 0 y 0 líneas: el pedido se perdía). Pedidos y rojos.
caso_m3() {
  local r='' modo a
  for modo in pedidos rojos; do
    nuevo
    if [ "$modo" = pedidos ]; then sella 10 ROLA M1 "PIDO no perder"; else sella 10 ROLA M1 "ROJO no perder"; fi
    env PATH="$T/bin:$PATH" TA_BUS="$BUS" TA_BUS_STATE_DIR="$ST" bash "$V/vigia-bus.sh" --modo "$modo" --lector L8 > /dev/full 2>/dev/null; a=$?
    corre vigia-bus.sh --modo "$modo" --lector L8
    r="$r$a|$(nlin)|${OUT% *};"
  done
  printf '%s' "$r"
}
esp_m3='2|1|PEDIDO ROLA M1 PIDO no perder;2|1|ROJO ROLA M1 ROJO no perder;'

# R2: la exclusión abarca el ciclo completo. Con el candado de la clave retenido por otro tick, el vigía NO
# decide ni emite (rc 2 tras la espera); cuando el otro termina, el tick siguiente emite. Bus (por lector) y estado (por clave).
caso_candados() {
  local r h hold
  nuevo; sella 10 ROLA M1 "PIDO uno"; mkdir -m 700 "$ST/vigias"
  ( flock -x 9; sleep 3 ) 9>>"$ST/vigias/bus-L9.ciclo" & hold=$!
  sleep 0.5
  corre vigia-bus.sh --modo pedidos --lector L9; r="$RC|$(nlin)"
  wait "$hold"
  corre vigia-bus.sh --modo pedidos --lector L9; r="$r|$RC|$(nlin)"
  h="$(printf '%s' /tmp | cksum)"; h="${h%% *}"
  ( flock -x 9; sleep 3 ) 9>>"$ST/vigias/inodos-$h.ciclo" & hold=$!
  sleep 0.5
  FX_IPCENT=91 corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$RC|$(nlin)"
  wait "$hold"
  FX_IPCENT=91 corre vigia-recursos.sh --modo inodos --ruta /tmp; r="$r|$RC|$(nlin)"
  printf '%s' "$r"
}
esp_candados='2|0|0|1|2|0|0|1'

# ═══ el lanzador del caso de bucle (un fichero en el directorio temporal; el bucle corre en su propia sesión) ═══
cat > "$T/lanza.sh" <<'__FIN_LANZA__'
#!/usr/bin/env bash
sleep 300 &
echo "$!" > "$FX_DECOY"
echo "$$" > "$FX_PIDF"
exec bash "$VV/vigias.sh" "$@"
__FIN_LANZA__
chmod 755 "$T/lanza.sh"

# ═══ afirmaciones con los scripts reales ═══════════════════════════════════════════════════════
printf '== C1-C3: el bus por cursor (pedidos y rojos) ==\n'
assert_eq 'C1 un PIDO de otro rol sale UNA vez (la nota normal y el PIDO del rol excluido no); el tick siguiente emite 0' "$esp_c1" "$(caso_c1)"
assert_eq 'C2 un PIDO escrito durante el hueco del vigía lo entrega el primer tick tras el hueco' "$esp_c2" "$(caso_c2)"
assert_eq 'C3 un rojo sale UNA vez como ROJO <rol> <marcador> …; un PIDO no en modo rojos; --patron sustituye al vocabulario' "$esp_c3" "$(caso_c3)"

printf '== C4-C5: silencio y lo no medido ==\n'
assert_eq 'C4 silencio por transición con la hora ISO del sello: 25 min, 30 h = 1800 min, 2 min calla y re-arma' "$esp_c4" "$(caso_c4)"
assert_eq 'C5 bus ausente, truncado o sin formato: UNA línea …-NO-MEDIDO por transición, rc 0, nunca calma' "$esp_c5" "$(caso_c5)"

printf '== C6-C9: ociosidad y recursos ==\n'
assert_eq 'C6 ociosa una vez a los 30 min, la carga alta reinicia la racha, ssh caído es OCIOSA-NO-MEDIDO, coma decimal vale' "$esp_c6" "$(caso_c6)"
assert_eq 'C7 inodos 84,91,91,70,90: avisa en el tick 2 y en el 5; arranque sin estado al 91 % avisa; sin dato es NO-MEDIDO' "$esp_c7" "$(caso_c7)"
assert_eq 'C8 disco 89,92,96,98,99,80,98: una vez por umbral (90, 95, 97), el descenso calla; primer tick alto avisa' "$esp_c8" "$(caso_c8)"
assert_eq 'C9 carpeta sobre el tope una vez; du agotado es CARPETA-NO-MEDIDO; sin tope y sin carpetas se dice; du caído no es calma' "$esp_c9" "$(caso_c9)"

printf '== C10: una línea = un evento ==\n'
assert_eq 'C10 texto hostil (ESC, C1, NUL, tab, 400 caracteres, acentos, byte inválido): líneas <= 220, UTF-8, sin controles, con hora' "$esp_c10" "$(caso_c10)"

printf '== C11-C12: el multiplexor ==\n'
assert_eq 'C11 --una-vez: ARMADOS … PARADOS; un tick fallido es VIGIA-FALLO y rc 1' "$esp_c11a" "$(caso_c11a)"
assert_eq 'C11 bucle cortado con TERM: PARADOS rc=143, termina a su hijo en pocos segundos y el señuelo del mismo grupo sigue vivo' "$esp_c11b" "$(caso_c11b)"
assert_eq 'C12 once configuraciones inválidas: rc 2 con motivo, sin salida y sin ningún estado escrito (fail-closed)' "$esp_c12" "$(caso_c12)"
assert_eq 'sin --excluir-rol el silencio avisa SIN-ROL-EXCLUIDO una vez y sigue midiendo' "$esp_sinrol" "$(caso_sinrol)"
assert_eq 'la emisión fallida da rc 2 y no pierde la transición: el tick siguiente la repite' "$esp_emision" "$(caso_emision)"

printf '== ronda 2: interrupción, tick vacío, cursor tras entregar y exclusión del ciclo ==\n'
assert_eq 'R2-M1 un TERM entre decidir y emitir no pierde el aviso: el tick siguiente emite' "$esp_m1" "$(caso_m1)"
assert_eq 'R2-M2 un tick sin bytes nuevos no re-arma un bus sin formato: basura, vacío, basura, sello, basura = 1/0/0/0/1' "$esp_m2" "$(caso_m2)"
assert_eq 'R2-M3 con stdout en /dev/full el reintento entrega el evento (pedidos y rojos): el cursor se confirma tras entregar' "$esp_m3" "$(caso_m3)"

printf '== ronda 3: el cursor solo avanza sobre lo entregado y contrastado ==\n'
assert_eq 'R3-A sellado entre la lectura y la entrega con la emisión del sobrante FALLIDA: el sobrante no se pierde (pedidos y rojos)' "$esp_va" "$(caso_ventana_a)"
assert_eq 'R3 control de éxito: el sobrante se entrega UNA vez y el reintento emite 0 (pedidos y rojos)' "$esp_vok" "$(caso_ventana_ok)"
assert_eq 'R3-B lo ya leído cambia (mismo tamaño) antes de confirmar: NO-MEDIDO sin avanzar y el reintento lo entrega (pedidos y rojos)' "$esp_cambio" "$(caso_cambio corto)"
assert_eq 'R3-B LARGO el cambio cae FUERA de los últimos 64 bytes del tramo: NO-MEDIDO sin avanzar, sin pérdida silenciosa (pedidos y rojos)' "$esp_cambio" "$(caso_cambio largo)"
assert_eq 'R3-B PRIMER BYTE el cambio está en el primer byte del tramo: NO-MEDIDO sin avanzar (pedidos y rojos)' "$esp_cambio" "$(caso_cambio primero)"
assert_eq 'R3-B BYTE INTERMEDIO un único byte del medio del tramo: NO-MEDIDO sin avanzar (pedidos y rojos)' "$esp_cambio" "$(caso_cambio medio)"
assert_eq 'R4 ventana cmp->guardado del cursor: el cambio se detecta en el tick siguiente (NO-MEDIDO), nunca en silencio (pedidos y rojos)' "$esp_vcmp" "$(caso_ventana_cmp 1)"
assert_eq 'R4 control de la ventana: bus intacto, un evento, sin NO-MEDIDO ni duplicados (pedidos y rojos)' "$esp_vcmp_ok" "$(caso_ventana_cmp)"
assert_eq 'R4 un cursor viejo (suma de 64 bytes, sin v2) es ilegible: NO-MEDIDO y el cursor no se toca' "$esp_cviejo" "$(caso_cursor_viejo)"
assert_eq 'R3-B control con el bus intacto: entrega y avanza, sin NO-MEDIDO (pedidos y rojos)' "$esp_intacto" "$(caso_cambio intacto)"
assert_eq 'R3 un cambio posterior a la confirmación en la zona del cursor se dice como NO-MEDIDO y no se consume' "$esp_posterior" "$(caso_posterior)"
assert_eq 'R3 el bus sustituido por otro fichero (mismo principio, más bytes) no se lee desde el cursor: NO-MEDIDO' "$esp_rotado" "$(caso_rotado)"
assert_eq 'R3 una línea a medio escribir no se consume hasta que lleva su salto de línea' "$esp_parcial" "$(caso_parcial)"
assert_eq 'R2 el candado abarca el ciclo: con la clave retenida el vigía no decide ni emite (rc 2); libre, emite' "$esp_candados" "$(caso_candados)"

# ═══ un mutante por guarda: cada uno quita UNA y su caso tiene que enrojecer ═══════════════════
printf '== mutantes: una guarda quitada enrojece su caso (t=%ss) ==\n' "$SECONDS"
mutante 'bus-cursor-no-avanza' "$esp_c1" caso_c1 vigia-bus.sh '&& mv -f -- "$ctmp" "$cursor"' '&& true'
mutante 'bus-sin-exclusion-de-rol' "$esp_c1" caso_c1 vigia-bus.sh '&& fuera=1' '&& fuera=0'
mutante 'bus-patron-pedidos-roto' "$esp_c2" caso_c2 vigia-bus.sh '[[ $texto =~ $patron ]] || continue' 'continue'
mutante 'bus-no-medido-callado' "$esp_c5" caso_c5 vigia-bus.sh 'vig_no_medido "$clave" "$clase-NO-MEDIDO" "lector $lector: $1"' 'true #'
mutante 'silencio-envoltura-24h' "$esp_c4" caso_c4 vigia-silencio.sh 'edad=$((ahora - te))' 'edad=$(((ahora - te) % 86400))'
mutante 'silencio-no-medido-callado' "$esp_c5" caso_c5 vigia-silencio.sh 'vig_no_medido silencio SILENCIO-BUS-NO-MEDIDO "$1" || exit 2' 'true'
mutante 'silencio-sin-aviso-de-rol' "$esp_sinrol" caso_sinrol vigia-silencio.sh 'vig_avisa_sube sin-rol-excluido' 'true #'
mutante 'aviso-por-nivel' "$esp_c4" caso_c4 lib-vigias.sh 'vig_decide "$1" "$2" "$3"; rc=$?' '[ "$2" -ge "$3" ] && rc=10 || rc=0'
mutante 'primer-tick-parte-de-alto' "$esp_c7" caso_c7 lib-vigias.sh "printf 'bajo' > \"\$f\"" "printf 'alto' > \"\$f\""
mutante 'estado-confirmado-antes-de-emitir' "$esp_emision" caso_emision lib-vigias.sh '10) if vig_evento "$4" "$5"; then vig_confirma; return $?; fi' '10) vig_confirma; if vig_evento "$4" "$5"; then return 0; fi'
mutante 'estado-confirmado-antes-de-emitir (interrupcion)' "$esp_m1" caso_m1 lib-vigias.sh '10) if vig_evento "$4" "$5"; then vig_confirma; return $?; fi' '10) vig_confirma; if vig_evento "$4" "$5"; then return 0; fi'
mutante 'detector-persiste-el-estado-real-antes-de-emitir' "$esp_m1" caso_m1 lib-vigias.sh '--estado "$sombra")"' '--estado "$f")"'
mutante 'bus-tick-vacio-rearma-el-no-medido' "$esp_m2" caso_m2 vigia-bus.sh 'if [ "$TOT" -eq 0 ]; then :' 'if [ "$TOT" -eq 0 ]; then vig_medido "$clave" || exit 2'
mutante 'bus-cursor-confirmado-antes-de-entregar' "$esp_m3" caso_m3 vigia-bus.sh 'if [ "$L" -gt 0 ]; then procesa "$snap"; else' 'if [ "$L" -gt 0 ]; then avanza; procesa "$snap"; else'
mutante 'bus-cursor-confirma-mas-de-lo-entregado (A)' "$esp_va" caso_ventana_a vigia-bus.sh '"$((off + L))"' '"$(wc -c < "$bus" | tr -d " ")"'
mutante 'bus-cursor-sin-contrastar-la-zona-guardada' "$esp_posterior" caso_posterior vigia-bus.sh '[ "$cur" = "$sum" ] || nm "lo ya entregado ha cambiado en el bus; decide quien opera"' 'true'
mutante 'bus-sin-contraste-del-tramo-antes-de-avanzar' "$esp_cambio" caso_cambio_corto vigia-bus.sh 'cmp -s -n "$L" -- "$tmp" "$snap"' 'true'
mutante 'bus-contraste-solo-de-los-64-bytes-finales' "$esp_cambio" caso_cambio_largo vigia-bus.sh 'cmp -s -n "$L" -- "$tmp" "$snap"' '[ "$(head -c "$L" -- "$tmp" | tail -c 64 | cksum)" = "$(tail -c 64 -- "$snap" | cksum)" ]'
mutante 'bus-cursor-guarda-la-suma-de-solo-64-bytes' "$esp_vcmp" caso_ventana_cmp_si vigia-bus.sh 'mm=$L ' 'mm=$((L < 64 ? L : 64)) '
mutante 'bus-contraste-solo-de-los-64-bytes-finales (primer byte)' "$esp_cambio" caso_cambio_primero vigia-bus.sh 'cmp -s -n "$L" -- "$tmp" "$snap"' '[ "$(head -c "$L" -- "$tmp" | tail -c 64 | cksum)" = "$(tail -c 64 -- "$snap" | cksum)" ]'
mutante 'bus-cursor-sin-identidad-del-bus' "$esp_rotado" caso_rotado vigia-bus.sh '[ "${BASH_REMATCH[1]}" = "$id" ] || nm "el bus no es el mismo que leyó este cursor (rotado o sustituido); decide quien opera"' 'true'
mutante 'bus-consume-la-linea-a-medio-escribir' "$esp_parcial" caso_parcial vigia-bus.sh 'L=$((bruto - resto))' 'L=$bruto'
mutante 'bus-sin-candado-de-lector' "$esp_candados" caso_candados vigia-bus.sh 'flock -x -w "${TA_VIG_ESPERA:-10}" 6 || vig_precond "candado del lector no adquirible: $ciclo"' 'true'
mutante 'estado-sin-candado-de-ciclo' "$esp_candados" caso_candados lib-vigias.sh 'if ! flock -x -w "${TA_VIG_ESPERA:-10}" "$fd"; then' 'if ! true; then'
mutante 'ociosa-ssh-caido-callado' "$esp_c6" caso_c6 vigia-ociosa.sh 'vig_no_medido "$clave" OCIOSA-NO-MEDIDO "$id no se pudo medir (sin respuesta o lectura ilegible)"' 'true #'
mutante 'ociosa-carga-alta-no-reinicia' "$esp_c6" caso_c6 vigia-ociosa.sh 'rm -f -- "$racha"; min=0' 'min=0'
mutante 'ociosa-decimales-sin-centesimas' "$esp_c6" caso_c6 lib-vigias.sh 'frac="${frac}00"; frac="${frac:0:2}"' 'frac=0'
mutante 'inodos-umbral-por-defecto' "$esp_c7" caso_c7 vigia-recursos.sh "umbrales=(85) ;;" "umbrales=(95) ;;"
mutante 'inodos-sin-dato-callado' "$esp_c7" caso_c7 vigia-recursos.sh 'vig_no_medido "$clave" INODOS-NO-MEDIDO "$ruta sin dato de inodos (df sin respuesta o el sistema de ficheros no los cuenta)"' 'true #'
mutante 'disco-estado-compartido-entre-umbrales' "$esp_c8" caso_c8 vigia-recursos.sh 'vig_decide "$clave-$t" "$u" "$t"' 'vig_decide "$clave" "$u" "$t"'
mutante 'disco-no-elige-el-umbral-mas-alto' "$esp_c8" caso_c8 vigia-recursos.sh '[ -z "$mayor" ] || [ "$t" -gt "$mayor" ]' '[ -z "$mayor" ]'
mutante 'carpeta-du-agotado-callado' "$esp_c9" caso_c9 vigia-recursos.sh 'vig_no_medido "carpeta-$h" CARPETA-NO-MEDIDO "$r (du sin terminar en $tdu s o con error)"' 'true #'
mutante 'carpeta-du-con-error-es-calma' "$esp_c9" caso_c9 vigia-recursos.sh '{ [ "$rc" -ne 0 ] && [ "$g" -le "$tope" ]; }' 'false'
mutante 'carpeta-sin-tope-callado' "$esp_c9" caso_c9 vigia-recursos.sh 'vig_avisa_sube "sintope-$h" 1 1 CARPETA-SIN-TOPE' 'true #'
mutante 'carpeta-sin-ninguna-callado' "$esp_c9" caso_c9 vigia-recursos.sh 'vig_avisa_sube sintope-global 1 1 CARPETA-SIN-TOPE' 'true #'
mutante 'linea-conserva-controles' "$esp_c10" caso_c10 lib-vigias.sh "tr '\\000-\\037\\177' ' ' \\" 'cat \'
mutante 'linea-sin-tope-de-longitud' "$esp_c10" caso_c10 lib-vigias.sh 'head -c $((VIG_MAX_LINEA - 10))' 'cat'
mutante 'linea-conserva-utf8-invalido-o-partido' "$esp_c10" caso_c10 lib-vigias.sh ' | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"' ')"'
mutante 'linea-conserva-c1' "$esp_c10" caso_c10 lib-vigias.sh 's/\xc2[\x80-\x9f]/ /g; ' ''
mutante 'multiplexor-sin-aviso-de-parada' "$esp_c11a" caso_c11a vigias.sh '[ "$armado" -eq 0 ] || vig_evento VIGIAS-PARADOS "rc=$rc"' 'true'
mutante 'multiplexor-tick-fallido-callado' "$esp_c11a" caso_c11a vigias.sh 'vig_avisa_sube "fallo-$n" 1 1 VIGIA-FALLO "$n terminó con rc $rc"' 'true #'
mutante 'multiplexor-mata-por-grupo' "$esp_c11b" caso_c11b vigias.sh 'kill -TERM "$p" 2>/dev/null' 'kill -TERM 0 2>/dev/null'
mutante 'multiplexor-no-termina-a-sus-hijos' "$esp_c11b" caso_c11b vigias.sh 'kill -TERM "$p" 2>/dev/null' 'true'
mutante 'multiplexor-acepta-perfil-invalido' "$esp_c12" caso_c12 vigias.sh 'perfil_validate >/dev/null || vig_precond "perfil de instancia ausente o inválido (lib-perfil.sh --check)"' 'perfil_validate >/dev/null || true'
mutante 'multiplexor-acepta-periodo-cero' "$esp_c12" caso_c12 vigias.sh '[ "$p" -ge 1 ] && [ "$p" -le 86400 ]' '[ "$p" -ge 0 ]'

# ═══ control rojo de la prueba de mejora: los defectos de las fuentes vivas, con vigías de juguete ═══
printf '== control rojo: los vigías de juguete reproducen los defectos de las fuentes vivas (t=%ss) ==\n' "$SECONDS"
# Juguete 1: sigue el bus EN VIVO (como `tail -F -n0`): solo ve lo que se escribe mientras mira.
toy_vivo() {
  local a n0
  nuevo; sella 500 ROLA M1 "nota normal"
  n0="$(wc -c < "$BUS" | tr -d ' ')"; sleep 0.1
  OUT="$(tail -c +$((n0 + 1)) "$BUS" | grep -a -i 'PIDO')"; a="$(nlin)"             # primer tick: nada
  sella 60 ROLA M2 "PIDO decision durante el hueco"                                  # cae mientras NO mira
  n0="$(wc -c < "$BUS" | tr -d ' ')"; sleep 0.1                                      # vuelve a mirar: solo lo POSTERIOR
  OUT="$(tail -c +$((n0 + 1)) "$BUS" | grep -a -i 'PIDO')"
  printf '%s|%s|%s' "$a" "$(nlin)" "${OUT% *}"
}
rojo 'juguete 1: el vigía que sigue el bus en vivo pierde el PIDO del hueco (C2 enrojece)' "$(toy_vivo)" "$esp_c2"
# Juguete 2: reconstruye la fecha de HOY con la hora del sello y envuelve las 24 h.
toy_fecha() {
  local l ts hms ls d
  nuevo; sella 108000 ROLA M3 "hace treinta horas"
  l="$(head -n 1 "$BUS")"; ts="${l%% *}"; hms="${ts#*T}"; hms="${hms%Z}"
  ls="$("$REAL_DATE" -u -d "$("$REAL_DATE" -u -d "@$FX_NOW" +%F) $hms" +%s)"; d=$((FX_NOW - ls))
  [ "$d" -ge 0 ] || d=$((d + 86400))
  printf '1|%s|0|1|%s|0|1|0|1|32' "$((d / 60))" "$((d / 60))"
}
rojo 'juguete 2: el vigía que reconstruye la fecha de hoy mide mal las 30 h (C4 enrojece)' "$(toy_fecha)" "$esp_c4"
# Juguete 3: calla ante un bus ilegible, que es indistinguible de un monitor sano.
toy_calla() {
  local r
  nuevo; BUS="$T/no-existe-$RANDOM"
  OUT=''; [ -r "$BUS" ] || OUT=''
  r="0|$(nlin)|${OUT%% *}"
  printf '%s' "$r"
}
rojo 'juguete 3: el vigía que calla ante un bus ilegible no dice nada (C5 enrojece)' "$(toy_calla)" "$esp_c5"

# ═══ contrato de los ficheros ══════════════════════════════════════════════════════════════════
printf '== invariantes del propio texto ==\n'
NUEVOS=("$V/lib-vigias.sh" "$V/vigia-bus.sh" "$V/vigia-silencio.sh" "$V/vigia-ociosa.sh" "$V/vigia-recursos.sh" "$V/vigias.sh")
sin_sintaxis=0; for f in "${NUEVOS[@]}" "$HERE/test-vigias.sh"; do bash -n "$f" 2>/dev/null || sin_sintaxis=$((sin_sintaxis + 1)); done
assert_eq 'los seis ficheros nuevos y este test pasan bash -n' 0 "$sin_sintaxis"
assert_eq 'ningún vigía ni el multiplexor usa kill 0, pkill, pgrep ni señales a grupos' 0 "$(grep -hE 'kill 0|pkill|pgrep|kill -- -' "${NUEVOS[@]}" | wc -l | tr -d ' ')"
assert_eq 'los filtros de texto no usan herramientas que bufferizan: un monitor mudo' 0 "$(grep -hE '^[^#]*\b(a[w]k|c[u]t)\b' "${NUEVOS[@]}" | wc -l | tr -d ' ')"
assert_eq 'los ficheros nuevos no llevan la clave de issue fija ni literales de la casa' 0 "$(grep -hEi 'T[A]L-[0-9]|blackam[p]|Talent[ _-]Academ[y]' "${NUEVOS[@]}" "$HERE/test-vigias.sh" | wc -l | tr -d ' ')"
assert_eq 'los vigías no escriben nada fuera del directorio de estado (cero /tmp literal)' 0 "$(grep -hE '^[^#]*/tmp/' "${NUEVOS[@]}" | wc -l | tr -d ' ')"
ayuda=''; desconocido=''
for s in vigia-bus vigia-silencio vigia-ociosa vigia-recursos vigias; do
  bash "$V/$s.sh" --help >/dev/null 2>&1; ayuda="$ayuda$?"
  bash "$V/$s.sh" --nada >/dev/null 2>&1; desconocido="$desconocido$?"
done
assert_eq 'cada vigía imprime su uso con --help y sale 0' 00000 "$ayuda"
assert_eq 'un argumento desconocido es rc 2 en cada vigía' 22222 "$desconocido"

printf '== la referencia 08: la pieza la completa, no la crea ==\n'
ref08_ok() { [ -f "$1/references/08-vigias-y-medidores.md" ] && grep -q '^## Vig' "$1/references/08-vigias-y-medidores.md"; }
ref08_ok "$ROOT"; assert_eq 'la referencia 08 existe y trae el apartado «Vigías»' 0 "$?"
mkdir -p "$T/sin08/references"; ref08_ok "$T/sin08"
assert_eq 'negativo: sin la referencia 08 la comprobación FALLA y la pieza no la crea por su cuenta' 1 "$?"

printf '\n== %d ok, %d FAIL (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desapareció un caso?)"; rc=1; }
exit "$rc"
