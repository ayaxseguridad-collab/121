#!/usr/bin/env bash
# run-tests.sh — Tests HERMÉTICOS de talent-ceo.
#
# Sin red, sin tmux, sin DB, sin tocar nada fuera de su directorio temporal.
# `bash tests/run-tests.sh` -> exit 0.
#
# Los fixtures son SINTÉTICOS y evidentemente falsos: este directorio vive dentro del árbol que
# barre el gate anti-nombres, así que un fixture "realista" rompería el gate igual que un nombre
# de verdad. Las direcciones usan el rango de documentación de la RFC 5737.
#
# ── LA SUITE SE AFIRMA A SÍ MISMA ──────────────────────────────────────────────────────────────
# Al final comprueba que el número de casos EJECUTADOS coincide con TOTAL_ESPERADO. Sin eso, un
# caso que desaparezca —por un borrado, un `return` de más o un fixture que deja de construirse—
# se lleva su cobertura sin que nada enrojezca, y la suite sigue diciendo "todo verde".
set -uo pipefail
export LC_ALL=C
export TF_PAQUETE_ESTADO=distribucion
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --estado ] || exit 2
  export TF_PAQUETE_ESTADO="$2"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/scripts"

TOTAL_ESPERADO=268
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_rc(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (rc esperado=$2 obtenido=$3)"; fi; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado='$2' obtenido='$3')"; fi; }

nl=$'\n'; cr=$'\r'   # separadores de registro, para los fixtures de forja
T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"

# ── fixture base: perfil VÁLIDO y sintético ────────────────────────────────────────────────────
perfil_base() {
  printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10;rol=mando\n'
  printf 'maquina\tmaq-beta\tmaq-beta\t-\t-\tip=192.0.2.11;rol=satelite\n'
  printf 'torre\ttorre-uno\tmaq-alfa\t-\tses-uno\trol=coordinador\n'
  printf 'estacion\test-uno\tmaq-alfa\t-\tses-est\trol=merge\n'
  printf 'canal\tcanal-uno\tmaq-beta\tcont-opaco-1\tses-can\trol=produccion\n'
  printf 'runner\trun-uno\tmaq-beta\tcont-opaco-2\t-\trol=gates\n'
  printf 'cron\tcron-uno\t-\t-\t-\tdueno=CEO;minutos=07,22,37,52\n'
  printf 'bus\tbus-uno\tmaq-alfa\t-\t-\tpath=/dev/null;lock=flock\n'
  printf 'ceo\tCEO\tmaq-alfa\t-\t-\troles=ceo+pm_interino;nota=tienta_a_inferir\n'
  printf 'pm\tPM\t-\t-\tninguna\tejercido_por=CEO\n'
}
P="$T/perfil.tsv"; perfil_base > "$P"

# Perfil con `maq-alfa` declarada LOCAL. Desde que `bus-sellar.sh` VERIFICA la identidad contra el
# perfil, sellar sin `TA_PERFIL` resolveria al perfil REAL de la instancia (manifiestos/*.tsv) y la
# suite dejaria de ser hermetica: pasaria o fallaria segun la topologia de la maquina anfitriona.
# Se exporta un perfil de fixture para TODA la suite; los casos que necesitan otro lo sobrescriben
# en linea (p. ej. "$P", que a proposito NO declara acceso=local).
PL="$T/perfil-local.tsv"
# Desde que sellar exige poder DISTINGUIR a los roles que comparten maquina, el fixture tiene que
# describir una topologia valida: `maq-alfa` aloja torre-uno, est-uno y CEO, asi que los tres
# declaran `usuario=` distintos. El del CEO es el usuario REAL del proceso, que es quien sella en
# la mayoria de los casos. Un fixture ambiguo no probaria el camino feliz: probaria el rechazo.
YO_REAL="$(id -un)"
perfil_base \
  | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/' \
  | sed 's/\trol=coordinador$/\trol=coordinador;usuario=nadie-torre/' \
  | sed 's/\trol=merge$/\trol=merge;usuario=nadie-est/' \
  | sed "s/roles=ceo+pm_interino;nota=tienta_a_inferir/roles=ceo;nota=tienta_a_inferir;usuario=$YO_REAL/" \
  > "$PL"
export TA_PERFIL="$PL"

# El MISMO perfil pero SIN `usuario=`: tres roles en maq-alfa que no se distinguen. Es el fixture
# del caso [r4-4], y se construye aqui para que quede claro que la diferencia con PL es UNA cosa.
PAMB="$T/perfil-ambiguo.tsv"
perfil_base | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/' > "$PAMB"

printf '== contrato del perfil: control POSITIVO ==\n'
bash "$S/lib-perfil.sh" --check "$P" >/dev/null 2>&1
assert_rc "perfil sintetico valido -> 0" 0 $?
bash "$S/lib-perfil.sh" --check "$T/no-existe" >/dev/null 2>&1
assert_rc "sin perfil -> 2 (fail-closed)" 2 $?

printf '== las 8 parejas V1-V8, de FALLO UNICO ==\n'
# Cada fixture viola SU regla y solo la suya. Si un negativo violara dos, una validacion
# correlacionada podria simular la cobertura de la otra.
v_check(){ bash "$S/lib-perfil.sh" --check "$1" >/dev/null 2>&1; }
v_row1(){ ( . "$S/lib-perfil.sh"; perfil_row1 "$2" "" "$1" >/dev/null 2>&1 ); }
pareja(){ # <nombre> <fichero>  => check debe dar 1 y row1 debe dar 2
  v_check "$2"; assert_rc "$1: --check = 1" 1 $?
  v_row1 "$2" maquina; assert_rc "$1: perfil_row1 = 2" 2 $?
}

# V1: cabecera con nombre cambiado, SEIS columnas intactas (si perdiera una, la caza V2)
perfil_base | sed '1s/sesion/sesión/' > "$T/v1.tsv"; pareja "V1 cabecera" "$T/v1.tsv"
# V2: una fila con 5 columnas, tipo e id validos
perfil_base | sed 's/^torre\ttorre-uno\tmaq-alfa\t-\tses-uno\trol=coordinador$/torre\ttorre-uno\tmaq-alfa\t-\tses-uno/' > "$T/v2.tsv"
pareja "V2 columnas" "$T/v2.tsv"
# V3: tipo fuera de los nueve
perfil_base | sed 's/^cron\tcron-uno/tipoinventado\tcron-uno/' > "$T/v3.tsv"; pareja "V3 tipo" "$T/v3.tsv"
# V4: MISMO id en DOS TIPOS DISTINTOS -- el unico que discrimina global de (tipo,id)
perfil_base | sed 's/^pm\tPM\t/pm\tCEO\t/' > "$T/v4.tsv"; pareja "V4 id cruzado" "$T/v4.tsv"
# V5: referencia de maquina huerfana
perfil_base | sed 's/^canal\tcanal-uno\tmaq-beta/canal\tcanal-uno\tmaq-fantasma/' > "$T/v5.tsv"
pareja "V5 maquina huerfana" "$T/v5.tsv"
# V6: dos filas del mismo singleton (con ids distintos, para no violar tambien V4)
{ perfil_base; printf 'bus\tbus-dos\tmaq-alfa\t-\t-\tpath=/dev/null\n'; } > "$T/v6.tsv"
pareja "V6 singleton duplicado" "$T/v6.tsv"
# V7: fragmento sin '=', SIN repetir clave (si repitiera, la cazaria V8)
perfil_base | sed 's/dueno=CEO;minutos=07,22,37,52/dueno=CEO;fragmento_suelto/' > "$T/v7.tsv"
pareja "V7 atributo sin =" "$T/v7.tsv"
# V8: dos fragmentos BIEN formados con la misma clave
perfil_base | sed 's/dueno=CEO;minutos=07,22,37,52/dueno=CEO;dueno=OTRO/' > "$T/v8.tsv"
pareja "V8 clave duplicada" "$T/v8.tsv"

printf '== V4 discrimina de verdad (el caso que no vale) ==\n'
# Dos filas del MISMO tipo con el mismo id: enrojece con las dos implementaciones, asi que NO
# prueba que la unicidad sea global. Se deja como caso documentado, no como prueba de V4.
{ perfil_base; printf 'runner\trun-uno\tmaq-beta\tcont-opaco-3\t-\trol=gates\n'; } > "$T/v4-mismo.tsv"
v_check "$T/v4-mismo.tsv"; assert_rc "dos ids iguales del MISMO tipo tambien violan V4" 1 $?

printf '== los 9 casos del singleton: {ceo,pm,bus} x {0,1,2+} ==\n'
for TIPO in ceo pm bus; do
  perfil_base | grep -v "^$TIPO	" > "$T/s0-$TIPO.tsv"
  v_check "$T/s0-$TIPO.tsv"; assert_rc "$TIPO ausente: --check = 0 (valido)" 0 $?
  v_row1 "$T/s0-$TIPO.tsv" "$TIPO"; assert_rc "$TIPO ausente: perfil_row1 = 1" 1 $?
  v_check "$P"; assert_rc "$TIPO con una: --check = 0" 0 $?
done
# 2+ ya cubierto por la pareja V6 (bus); se anaden ceo y pm para cerrar la tabla
for TIPO in ceo pm; do
  { perfil_base; printf '%s\t%s-bis\tmaq-alfa\t-\t-\tx=1\n' "$TIPO" "$TIPO"; } > "$T/s2-$TIPO.tsv"
  v_check "$T/s2-$TIPO.tsv"; assert_rc "$TIPO duplicado: --check = 1" 1 $?
done

printf '== el PM no se infiere ==\n'
# El fixture SIN fila pm conserva ceo.roles=...pm_interino..., que es justo lo que tienta.
grep -c 'pm_interino' "$T/s0-pm.tsv" >/dev/null 2>&1
assert_eq "el fixture sin pm SI contiene pm_interino" "1" "$(grep -c 'pm_interino' "$T/s0-pm.tsv")"
TA_PERFIL="$T/s0-pm.tsv" bash "$S/perfil-render.sh" --tabla players >/dev/null 2>&1
assert_rc "players sin fila pm -> rc 1, NO se infiere" 1 $?
TA_PERFIL="$P" bash "$S/perfil-render.sh" --tabla players >/dev/null 2>&1
assert_rc "players con fila pm -> rc 0" 0 $?

printf '== minutos leidos del perfil, nunca hardcodeados ==\n'
assert_eq "minutos de cron-uno" "07,22,37,52" "$(TA_PERFIL="$P" bash "$S/tablas-cron.sh" --minutos cron-uno)"
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --minutos cron-inexistente >/dev/null 2>&1
assert_rc "cron inexistente -> rc 1" 1 $?

printf '== bus: identidad por inodo, no por nombre ==\n'
export TA_BUS="$T/bus.log"; : > "$TA_BUS"
( cd "$T" && ln -s bus.log alias-sym.log && ln bus.log alias-hard.log ) 2>/dev/null
for a in "$T/bus.log" "$T/./bus.log" "$T/alias-sym.log" "$T/alias-hard.log"; do
  bash "$S/bus-sellar.sh" --rol CEO --marcador MK --src "$a" >/dev/null 2>&1; rc=$?
  assert_rc "alias $(basename "$a") -> rc 2" 2 "$rc"
done
echo x > "$T/otro.log"
bash "$S/bus-sellar.sh" --rol CEO --marcador MK --src "$T/otro.log" >/dev/null 2>&1
assert_rc "fichero distinto SI sella -> 0" 0 $?

printf '== bus: marcador repetido y atomicidad ==\n'
bash "$S/bus-sellar.sh" --rol CEO --marcador MK >/dev/null 2>&1; assert_rc "marcador repetido -> 3" 3 $?
bash "$S/bus-sellar.sh" --rol CEO --marcador CONC >/dev/null 2>&1 & p1=$!
bash "$S/bus-sellar.sh" --rol CEO --marcador CONC >/dev/null 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
if { [ "$r1" = 0 ] && [ "$r2" = 3 ]; } || { [ "$r1" = 3 ] && [ "$r2" = 0 ]; }; then
  ok "dos escritores del mismo marcador: uno 0 y otro 3"
else bad "dos escritores concurrentes (rc=$r1 y rc=$r2)"; fi
assert_eq "el marcador aparece UNA vez" "1" "$(grep -c 'marcador: CONC]' "$TA_BUS")"

printf '== bus: cursor por lector y precondiciones ==\n'
bash "$S/bus-leer.sh" --lector LECTOR1 >/dev/null 2>&1; assert_rc "lectura inicial -> 0" 0 $?
# Se captura el rc ADEMAS de la salida. Comparando solo stdout, un `bus-leer` que fallara con rc 2
# y no emitiera nada satisfacia `"" = ""` y sumaba PASS: el caso decia cubrir "no repite" y en
# realidad no distinguia "no habia nada pendiente" de "no pude leer". El rc ES el veredicto.
sal_2l="$(bash "$S/bus-leer.sh" --lector LECTOR1 2>/dev/null)"; rc_2l=$?
assert_eq "segunda lectura no repite (y con rc 0, no un fallo mudo)" "0|" "$rc_2l|$sal_2l"
out="$(bash "$S/bus-leer.sh" --lector LECTOR2 2>/dev/null)"
if [ -n "$out" ]; then ok "otro lector tiene su propio cursor"; else bad "otro lector deberia ver el bus entero"; fi
bash "$S/bus-leer.sh" --lector '../../fuga' >/dev/null 2>&1
assert_rc "id con traversal -> rc 2" 2 $?
bash "$S/bus-leer.sh" --lector 'con espacio' >/dev/null 2>&1
assert_rc "id fuera del charset -> rc 2" 2 $?
cdir="$XDG_RUNTIME_DIR/talent-ceo/cursores"
printf '999999999' > "$cdir/LECTOR3.cursor"
bash "$S/bus-leer.sh" --lector LECTOR3 >/dev/null 2>&1; assert_rc "cursor > bus -> rc 2" 2 $?
assert_eq "y el cursor NO se toca" "999999999" "$(cat "$cdir/LECTOR3.cursor")"

printf '== bus: precreaciones inseguras ==\n'
ln -s /dev/null "$cdir/SYM.cursor"
bash "$S/bus-leer.sh" --lector SYM >/dev/null 2>&1; assert_rc "cursor precreado symlink -> 2" 2 $?
# Un fixture que NO se pudo crear se contaba como caso APROBADO: el `|| ok "…caso omitido"`
# incrementaba PASS y el caso real no llegaba a correr nunca. Reproducido con `mkfifo(){ return 1; }`
# la suite terminaba igualmente en verde. Es la misma clase que la suite persigue en el resto del
# paquete —un fallo indistinguible de un éxito— y la tenía dentro. Un fixture que falla es RED: «no
# he podido comprobarlo» no es «está bien». Sigue siendo UN caso en cualquiera de las dos ramas,
# así que el conteo contra TOTAL_ESPERADO no cambia según el entorno.
if mkfifo "$cdir/FIFO.cursor" 2>/dev/null; then
  bash "$S/bus-leer.sh" --lector FIFO >/dev/null 2>&1; assert_rc "cursor precreado FIFO -> 2" 2 $?
else
  bad "cursor precreado FIFO: NO se pudo crear el fixture; el caso no se ha ejercitado"
fi
ln -s /dev/null "$cdir/LOCKSYM.lock"
bash "$S/bus-leer.sh" --lector LOCKSYM >/dev/null 2>&1; assert_rc "lock precreado symlink -> 2" 2 $?
chmod 755 "$cdir"
bash "$S/bus-leer.sh" --lector MODO >/dev/null 2>&1; assert_rc "directorio con modo != 0700 -> 2" 2 $?
chmod 700 "$cdir"

printf '== etime: las tres formas ==\n'
assert_eq "MM:SS"      "330"     "$(bash "$S/runners-vivos.sh" --etime 05:30)"
assert_eq "HH:MM:SS"   "3930"    "$(bash "$S/runners-vivos.sh" --etime 01:05:30)"
assert_eq "D-HH:MM:SS" "442800"  "$(bash "$S/runners-vivos.sh" --etime 5-03:00:00)"
bash "$S/runners-vivos.sh" --etime basura >/dev/null 2>&1; assert_rc "etime no parseable -> 1" 1 $?

printf '== composer: ghost NO es text ==\n'
E="$(printf '\033')"
assert_eq "vacio"       "empty"  "$(printf '' | bash "$S/ronda-canales.sh" --clasificar)"
assert_eq "placeholder" "ghost"  "$(printf '%s[2mescribe aqui%s[0m' "$E" "$E" | bash "$S/ronda-canales.sh" --clasificar)"
assert_eq "texto real"  "text"   "$(printf 'una orden de verdad' | bash "$S/ronda-canales.sh" --clasificar)"
assert_eq "en curso"    "queued" "$(printf 'algo\nWorking (2s)' | bash "$S/ronda-canales.sh" --clasificar)"

printf '== vigia: por transicion, no por nivel ==\n'
EST="$T/cuota.estado"
bash "$S/vigia-cuota.sh" --valor 50 --estado "$EST" >/dev/null 2>&1; assert_rc "primer tick NO grita" 0 $?
bash "$S/vigia-cuota.sh" --valor 90 --estado "$EST" >/dev/null 2>&1; assert_rc "bajo->alto = transicion" 10 $?
bash "$S/vigia-cuota.sh" --valor 95 --estado "$EST" >/dev/null 2>&1; assert_rc "sigue alto: callado" 0 $?
bash "$S/vigia-cuota.sh" --valor 10 --estado "$EST" >/dev/null 2>&1; assert_rc "alto->bajo = transicion" 10 $?

printf '== tablas: la celda sin fuente se pinta, no se deja en blanco ==\n'
salida="$(printf 'a\t\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
# OJO CON EL ALCANCE DE ESTE CASO: solo comprueba que el guion APAREZCA, no DONDE. Con la entrada
# de arriba paso en verde durante seis rondas teniendo dentro el colapso de celdas vacias, porque
# el guion salia — en la columna equivocada. La POSICION se mide en [r8-2]; este se queda como lo
# que de verdad es: el control de que un hueco nunca se pinta en blanco.
case "$salida" in *"—"*) ok "celda ausente -> guion largo (presencia; la columna, en [r8-2])" ;; *) bad "celda ausente sin marcar: '$salida'" ;; esac

printf '== perfil_attr es pura ==\n'
assert_eq "clave presente" "CEO" "$( . "$S/lib-perfil.sh"; perfil_attr 'dueno=CEO;minutos=07' dueno )"
( . "$S/lib-perfil.sh"; perfil_attr 'dueno=CEO' ausente >/dev/null 2>&1 ); assert_rc "clave ausente -> 1" 1 $?


printf '== opcion sin valor: rc 2, y NUNCA un bucle ==\n'
# CodeRabbit encontro esto en bus-leer.sh y resulto ser de CLASE: seis scripts colgaban. `shift 2`
# con la opcion como ULTIMO argumento no desplaza (rc != 0) y sin `set -e` el bucle relee el mismo
# $1 para siempre. El gate quedaba VERDE porque ningun caso lo ejercia.
for par in "bus-leer.sh:--lector" "bus-sellar.sh:--marcador" "bus-sellar.sh:--rol" \
           "relay-ceo.sh:--a" "relay-ceo.sh:--fichero" "tablas-cron.sh:--minutos" \
           "perfil-render.sh:--tabla" "vigia-cuota.sh:--valor" "runners-vivos.sh:--patron"; do
  sc="${par%%:*}"; op="${par##*:}"
  timeout 5 bash "$S/$sc" "$op" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 124 ]; then bad "$sc $op sin valor: BUCLE INFINITO"
  else assert_rc "$sc $op sin valor -> 2" 2 "$rc"; fi
done

printf '== el sello lleva IDENTIDAD del rol, VERIFICADA contra el perfil ==\n'
# La identidad ya no se acepta porque se afirme: se deriva del perfil (rol EXISTE y esta COLOCADO
# en ESTA maquina). Estos casos fijan que un rol de OTRA maquina no puede sellar.
bash "$S/bus-sellar.sh" --marcador SINROL >/dev/null 2>&1
assert_rc "sellar sin --rol ni TA_ROL -> 2" 2 $?
bash "$S/bus-sellar.sh" --rol 'rol con espacio' --marcador X >/dev/null 2>&1
assert_rc "rol fuera del charset -> 2" 2 $?

bash "$S/bus-sellar.sh" --rol CEO --marcador CONIDENT >/dev/null 2>&1
assert_rc "rol COLOCADO en esta maquina -> 0" 0 $?
# Se cuenta el sello CONCRETO, no `rol: CEO` a secas: otros casos de la suite tambien sellan como
# CEO, asi que un contador suelto medía tres cosas distintas y habria que "ajustarlo" al numero
# observado — que es como un test deja de probar nada.
assert_eq "el sello registra quien sello" "1" "$(grep -c 'rol: CEO.*marcador: CONIDENT\]' "$TA_BUS")"

# [identidad-real] el caso que la charset-validation dejaba pasar: sellar como otro
bash "$S/bus-sellar.sh" --rol canal-uno --marcador SUPLANTA >/dev/null 2>&1
assert_rc "[identidad-real] rol de OTRA maquina -> 2" 2 $?
assert_eq "[identidad-real] y no deja rastro en el bus" "0" "$(grep -c 'SUPLANTA' "$TA_BUS")"

bash "$S/bus-sellar.sh" --rol FANTASMA --marcador FANT >/dev/null 2>&1
assert_rc "[identidad-real] rol inexistente en el perfil -> 2" 2 $?

# PM declara maquina '-': sin ubicacion declarada no hay identidad que verificar
bash "$S/bus-sellar.sh" --rol PM --marcador SINUBIC >/dev/null 2>&1
assert_rc "[identidad-real] rol sin maquina declarada -> 2" 2 $?

# sin ninguna maquina 'acceso=local' no se asume que todo es local (fail-closed, como el relay)
TA_PERFIL="$P" bash "$S/bus-sellar.sh" --rol CEO --marcador SINLOCAL >/dev/null 2>&1
assert_rc "[identidad-real] sin acceso=local -> 2 (no se asume)" 2 $?

# si el perfil exige un usuario del SO, se comprueba de verdad
perfil_base | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/' \
  | sed 's/roles=ceo+pm_interino;nota=tienta_a_inferir/roles=ceo;usuario=nadie-que-exista/' > "$T/sellar-usuario.tsv"
TA_PERFIL="$T/sellar-usuario.tsv" bash "$S/bus-sellar.sh" --rol CEO --marcador USUARIO >/dev/null 2>&1
assert_rc "[identidad-real] usuario= que no coincide -> 2" 2 $?

printf '== el separador de registro NO viaja dentro del dato ==\n'
# Un LF en un campo libre no ROMPE la verificacion de identidad: la esquiva por debajo, escribiendo
# una linea nueva que ya nace del otro lado del control. Quien pueda sellar UNA vez con su identidad
# real podria forjar un sello atribuido a cualquier rol. Se RECHAZA, no se escapa.
bus_sha(){ sha256sum "$TA_BUS" 2>/dev/null | cut -d' ' -f1; }
culpable=''
probar_sin_rastro(){   # <etiqueta> <args de bus-sellar...>
  local etiq="$1"; shift
  local antes despues
  antes="$(bus_sha)"
  bash "$S/bus-sellar.sh" "$@" >/dev/null 2>&1
  despues="$(bus_sha)"
  [ "$antes" = "$despues" ] || { [ -n "$culpable" ] || culpable="$etiq"; }
}

# Cada caso comprueba el VEREDICTO (rc 2) **y el EFECTO** (el bus no cambia). Con solo el rc, una
# regresion que escriba en el bus y devuelva el codigo correcto pasaria la suite: el control miraria
# el resultado y no lo que hizo. Es el mismo defecto que este paquete cierra en el codigo.
forja_rc=''
sellar_rechazado(){   # <etiqueta> <args...> : exige rc 2 Y bus intacto
  local etiq="$1"; shift
  local antes despues rc
  antes="$(bus_sha)"
  bash "$S/bus-sellar.sh" "$@" >/dev/null 2>&1; rc=$?
  despues="$(bus_sha)"
  assert_rc "[forja] $etiq -> 2" 2 "$rc"
  assert_eq "[forja] $etiq: el bus NO cambia" "$antes" "$despues"
}
sellar_rechazado '--marcador con LF' --rol CEO --marcador "CON${nl}LF"
sellar_rechazado '--nota con LF'     --rol CEO --marcador NOTALF --nota "linea uno${nl}linea dos"
sellar_rechazado '--nota con CR'     --rol CEO --marcador NOTACR --nota "linea uno${cr}linea dos"
# El control que de verdad importa: la linea forjada NO puede acabar en el bus. Ademas del rc.
sellar_rechazado 'nota que finge otro rol' --rol CEO --marcador FORJA \
  --nota "inocente${nl}2026-01-01T00:00:00Z [rol: PM] [marcador: FORJADO]"
assert_eq "[forja] la linea atribuida a otro rol NO llega al bus" "0" "$(grep -c 'rol: PM' "$TA_BUS")"

printf '== minutos vacio no genera crontab sin minutos ==\n'
perfil_base | sed 's/dueno=CEO;minutos=07,22,37,52/dueno=CEO;minutos=/' > "$T/min-vacio.tsv"
TA_PERFIL="$T/min-vacio.tsv" bash "$S/tablas-cron.sh" --minutos cron-uno >/dev/null 2>&1
assert_rc "minutos= vacio -> rc 1" 1 $?

printf '== relay: sin acceso=local declarado, falla CERRADO ==\n'
perfil_base | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/' > "$T/con-local.tsv"
echo hola > "$T/relevo.txt"
TA_PERFIL="$T/con-local.tsv" bash "$S/relay-ceo.sh" --a canal:canal-uno --fichero "$T/relevo.txt" --dry-run >/dev/null 2>&1
assert_rc "con acceso=local -> 0" 0 $?
TA_PERFIL="$P" bash "$S/relay-ceo.sh" --a canal:canal-uno --fichero "$T/relevo.txt" --dry-run >/dev/null 2>&1
assert_rc "sin acceso=local -> 2 (no se asume local)" 2 $?

printf '== relay: los argumentos NO se evaluan como shell ==\n'
# Fichero con nombre hostil: con `eval`, el `;` ejecutaria el segundo comando.
mkdir -p "$T/ev"; hostil="$T/ev/a b; touch PWNED"
printf 'carga\n' > "$hostil"
( cd "$T/ev" && TA_PERFIL="$T/con-local.tsv" bash "$S/relay-ceo.sh" --a canal:canal-uno \
    --fichero "$hostil" --dry-run >/dev/null 2>&1 )
if [ -e "$T/ev/PWNED" ]; then bad "INYECCION: el nombre del fichero se ejecuto"
else ok "nombre hostil de fichero: no se ejecuta nada"; fi

# ── LA SUITE SE AFIRMA A SI MISMA ──────────────────────────────────────────────────────────────

printf '== r4: los siete hallazgos, cada uno con su caso ==\n'

# ── #1 · el respaldo del perfil BUSCA, no cuenta niveles ───────────────────────────────────────
# El mismo fichero vive a 3 niveles de la raiz en el motor y a 4 en un repo de producto. Un
# `../../..` fijo acierta en uno y no puede resolver NUNCA en el otro. Se prueban AMBAS
# profundidades con el mismo lib, que es justo lo que un conteo fijo no puede satisfacer.
for prof in 3 4; do
  R="$T/resp$prof"
  if [ "$prof" = 3 ]; then D="$R/skills/talent-ceo/scripts"; else D="$R/.claude/skills/talent-ceo/scripts"; fi
  mkdir -p "$D" "$R/manifiestos"
  cp "$S/lib-perfil.sh" "$D/"
  perfil_base > "$R/manifiestos/x.perfil.tsv"
  got="$( TA_PERFIL='' SECRET_DIR='' bash -c '. "$1"; perfil_path' _ "$D/lib-perfil.sh" 2>/dev/null )"
  assert_eq "[r4-1] respaldo del perfil a profundidad $prof" "$R/manifiestos/x.perfil.tsv" "$got"
done
# Dos manifiestos = ambiguedad: no se elige, se falla cerrado.
cp "$T/resp3/manifiestos/x.perfil.tsv" "$T/resp3/manifiestos/y.perfil.tsv"
TA_PERFIL='' SECRET_DIR='' bash -c '. "$1"; perfil_path' _ "$T/resp3/skills/talent-ceo/scripts/lib-perfil.sh" >/dev/null 2>&1
assert_rc "[r4-1] dos *.perfil.tsv en manifiestos -> 2 (no se elige)" 2 $?
rm -f "$T/resp3/manifiestos/y.perfil.tsv"

# La ambiguedad se mide en TODA LA CADENA, no dentro de cada nivel. Parando en el primer nivel con
# candidato, "el mas cercano gana" era una regla TACITA: con un perfil en el arbol y otro en un
# ancestro se elegia en silencio, y esto es la fuente de autoridad de la IDENTIDAD del sellador.
mkdir -p "$T/anc/hijo/skills/talent-ceo/scripts" "$T/anc/manifiestos" "$T/anc/hijo/manifiestos"
cp "$S/lib-perfil.sh" "$T/anc/hijo/skills/talent-ceo/scripts/"
perfil_base > "$T/anc/hijo/manifiestos/cerca.perfil.tsv"
LP="$T/anc/hijo/skills/talent-ceo/scripts/lib-perfil.sh"
got_anc="$( TA_PERFIL='' SECRET_DIR='' bash -c '. "$1"; perfil_path' _ "$LP" 2>/dev/null )"
assert_eq "[r6-amb] CONTROL: con UNO solo en la cadena, resuelve" "$T/anc/hijo/manifiestos/cerca.perfil.tsv" "$got_anc"
perfil_base > "$T/anc/manifiestos/lejos.perfil.tsv"
err_anc="$( TA_PERFIL='' SECRET_DIR='' bash -c '. "$1"; perfil_path' _ "$LP" 2>&1 >/dev/null )"; rc_anc=$?
assert_rc "[r6-amb] uno cerca y otro en un ANCESTRO -> 2 (no se elige en silencio)" 2 "$rc_anc"
case "$err_anc" in
  *cerca.perfil.tsv*lejos.perfil.tsv*) amb_ok=0 ;;
  *)                                   amb_ok=1 ;;
esac
assert_rc "[r6-amb] y el error DICE cuales son los dos candidatos" 0 "$amb_ok"

# ── #2 · duplicado por CAMPO, no por subcadena ─────────────────────────────────────────────────
# Las notas del bus citan marcadores constantemente; con `grep` de subcadena, esa cita bastaba
# para rechazar con rc 3 un sello legitimo que aun no se habia puesto.
bash "$S/bus-sellar.sh" --rol CEO --marcador CITADOR --nota 'pendiente de [marcador: NOPUESTO]' >/dev/null 2>&1
assert_rc "[r4-2] sellar una nota que CITA otro marcador -> 0" 0 $?
bash "$S/bus-sellar.sh" --rol CEO --marcador NOPUESTO >/dev/null 2>&1
assert_rc "[r4-2] y el marcador citado SIGUE sellable -> 0" 0 $?
bash "$S/bus-sellar.sh" --rol CEO --marcador NOPUESTO >/dev/null 2>&1
assert_rc "[r4-2] el repetido de verdad sigue dando 3" 3 $?

# ── #3 · el alfabeto, cerrado ──────────────────────────────────────────────────────────────────
esc=$(printf '\033')
bash "$S/bus-sellar.sh" --rol CEO --marcador CTRL1 --nota "texto${esc}[2Kborrado" >/dev/null 2>&1
assert_rc "[r4-3] nota con ESC (secuencia ANSI) -> 2" 2 $?
bash "$S/bus-sellar.sh" --rol CEO --marcador 'con espacio' >/dev/null 2>&1
assert_rc "[r4-3] marcador fuera del charset -> 2" 2 $?

# ── #4 · ambiguedad en la MISMA maquina: fail-closed ───────────────────────────────────────────
# PAMB coloca torre-uno, est-uno y CEO en maq-alfa sin `usuario=`: no hay forma de saber cual de
# los tres sello, asi que no se sella. Declarar el agujero no lo cerraba; esto si.
TA_PERFIL="$PAMB" bash "$S/bus-sellar.sh" --rol CEO --marcador AMBIG >/dev/null 2>&1
assert_rc "[r4-4] roles indistinguibles en la misma maquina -> 2" 2 $?
# La UNICA diferencia de PL con PAMB es el `usuario=`; con el, el mismo sello pasa.
bash "$S/bus-sellar.sh" --rol CEO --marcador DESAMB >/dev/null 2>&1
assert_rc "[r4-4] con usuario= que los distingue -> 0" 0 $?

# ── #8 · una entrada invalida no puede DEJAR RASTRO ───────────────────────────────────────────
# Los casos de entrada invalida comprobaban el VEREDICTO (`rc 2`) y no el EFECTO. Un rechazo que
# devuelve el rc correcto y aun asi deja media linea escrita pasaria tal cual: el control mira el
# resultado y no mira lo que hizo. Es el mismo defecto que este paquete cierra en el codigo,
# aplicado a los propios tests. Se compara el bus ANTES y DESPUES de cada invocacion.
probar_sin_rastro 'marcador vacio'          --rol CEO --marcador ''
probar_sin_rastro 'sin rol'                 --marcador SINROL2
probar_sin_rastro 'rol fuera de charset'    --rol 'x y' --marcador X2
probar_sin_rastro 'rol de otra maquina'     --rol canal-uno --marcador SUP2
probar_sin_rastro 'rol inexistente'         --rol FANTASMA2 --marcador FANT2
probar_sin_rastro 'rol sin maquina'         --rol PM --marcador SINUB2
probar_sin_rastro 'nota con LF'             --rol CEO --marcador NLF --nota "a${nl}b"
probar_sin_rastro 'nota con ESC'            --rol CEO --marcador NESC --nota "a${esc}[2Kb"
probar_sin_rastro 'marcador fuera charset'  --rol CEO --marcador 'con espacio 2'
probar_sin_rastro 'src ES el bus'           --rol CEO --marcador SRC2 --src "$TA_BUS"
assert_eq "[r4-8] ninguna entrada invalida deja rastro en el bus" "" "$culpable"

# ── #5 · el filtro no se lista a si mismo ──────────────────────────────────────────────────────
# DOS defectos distintos en el mismo caso, y los dos son ciertos, asi que van los dos.
# (a) El patron era la cadena literal `runners-vivos`, y con eso el caso NO era hermetico:
#     CUALQUIER proceso ajeno de la maquina cuya linea de comandos mencione ese nombre sale en el
#     listado y el caso enrojece sin que el codigo haya cambiado. Medido: enrojecio con
#     `esperado='0' obtenido='2'` mientras un proceso ajeno llevaba el nombre del script en sus
#     argumentos. Es un ROJO AMBIENTAL disfrazado de regresion, de los caros: manda a buscar un
#     defecto que no existe. Con un marcador UNICO de esta corrida, lo unico que puede casarlo es
#     el propio listador (y su fork), que es exactamente lo que el caso afirma que se excluye.
# (b) Sin capturar el rc, un `|| true` convierte CUALQUIER fallo del listador en salida vacia, y
#     una salida vacia tambien da 0 ocurrencias: el caso pasaria sin que el script llegara a
#     ejecutarse. Es el VERDE que miente, con el ROJO que miente al lado.
marca_rv="rv-$(basename "$T")"
salida_rv="$(bash "$S/runners-vivos.sh" --patron "$marca_rv" 2>/dev/null)"; rc_rv=$?
assert_rc "[r4-5] el listador CORRE (si no, el conteo de abajo es vacio, no verde)" 0 "$rc_rv"
assert_eq "[r4-5] el listador no aparece en su propio listado" "0" "$(printf '%s' "$salida_rv" | grep -cF "$marca_rv")"

# ── #6 · fallo de transporte != veredicto de contrato ──────────────────────────────────────────
echo hola > "$T/relevo-r4.txt"
# El transporte se finge con un STUB DETERMINISTA. Con solo `PATH="$T/vacio:$PATH"` se conservaba el
# `tmux` del host: el resultado dependia de la maquina y, si la sesion existia de verdad, el caso
# podia ENTREGAR UN RELEVO A UN DESTINO REAL. Un test no puede tener efectos fuera de su sandbox.
mkdir -p "$T/vacio"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/vacio/tmux"; chmod +x "$T/vacio/tmux"
PATH="$T/vacio:$PATH" TA_PERFIL="$PL" timeout 20 bash "$S/relay-ceo.sh" --a torre:torre-uno --fichero "$T/relevo-r4.txt" >/dev/null 2>&1
assert_rc "[r4-6] transporte caido -> 3, no 1 (el destino SI existe)" 3 $?

# ── #7 · --comando es UNA linea de crontab ─────────────────────────────────────────────────────
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando "ok${nl}* * * * * intruso" >/dev/null 2>&1
assert_rc "[r4-7] --comando con LF -> 2" 2 $?

printf '== r5: los cuatro de la ronda 4 ==\n'

# ── #1 · el indice del skill no puede apuntar a ficheros fantasma ──────────────────────────────
# SKILL.md es el mapa del propio skill: si senala un `references/*.md` que no existe, el siguiente
# que lo lea no encuentra el overlay. Se comprueba TODA referencia, no la que fallaba.
# Dos trampas que este caso aprendio a la mala, las dos midiendo:
# (1) la regex captura el prefijo de ruta COMPLETO: `skill-creator/references/09-*.md` es una
#     referencia legitima a un skill HERMANO, y empezar la regex en `references/` la leeria como
#     propia y la daria por rota. El defecto estaba en el test, no en el SKILL.md.
# (2) el ANEXO es un OVERLAY y su nombre concreto es de cada repo —en un arbol se llama de una
#     forma y en otro de otra—, asi que el indice lo referencia por FAMILIA (`anexo-*`) y no por
#     nombre. Un patron no es una ruta: se comprueba aparte, exigiendo que exista EXACTAMENTE UN
#     overlay en el arbol.
faltan=''
while read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    *\**)         : ;;                                                     # patron, no ruta
    references/*) [ -f "$ROOT/$ref" ]        || faltan="$faltan $ref" ;;   # propia
    *)            [ -f "$ROOT/../$ref" ]     || faltan="$faltan $ref" ;;   # de un skill hermano
  esac
done <<EOF
$(grep -oE '[A-Za-z0-9._-]*/?references/[A-Za-z0-9._-]+\.md' "$ROOT/SKILL.md" | sort -u)
EOF
assert_eq "[r5-1] SKILL.md no referencia ficheros inexistentes" "" "$faltan"
# El overlay existe y es UNO: la familia esta garantizada por el contrato del paquete, el nombre no.
n_anexo=0
for a in "$ROOT"/references/anexo-*.md; do [ -f "$a" ] && n_anexo=$((n_anexo + 1)); done
# TAL-8037: la DISTRIBUCION no trae ningun overlay (cero anexos); una INSTANCIA tiene exactamente UNO. El estado se
# DECLARA (TF_PAQUETE_ESTADO=distribucion|instancia, default instancia) — jamas se deduce de la ausencia de un fichero.
estado_paquete="${TF_PAQUETE_ESTADO:-instancia}"
case "$estado_paquete" in
  distribucion) esperado_anexo=0 ;;
  instancia)    esperado_anexo=1 ;;
  *) echo "FAIL: TF_PAQUETE_ESTADO invalido ($estado_paquete): distribucion|instancia" >&2; exit 2 ;;
esac
assert_eq "[r5-1] overlay references/anexo-*.md ($estado_paquete): 0 en distribucion, EXACTAMENTE 1 en instancia" "$esperado_anexo" "$n_anexo"

# ── #2 · un destino a medias no es un destino ──────────────────────────────────────────────────
# El `case` garantiza que HAY dos puntos, no que haya algo a cada lado.
echo hola > "$T/relevo-r5.txt"
bash "$S/relay-ceo.sh" --a ':canal-uno' --fichero "$T/relevo-r5.txt" >/dev/null 2>&1
assert_rc "[r5-2] --a sin tipo antes de ':' -> 2" 2 $?
bash "$S/relay-ceo.sh" --a 'canal:' --fichero "$T/relevo-r5.txt" >/dev/null 2>&1
assert_rc "[r5-2] --a sin id despues de ':' -> 2" 2 $?

# ── #3 · V9: dos maquinas acceso=local es AMBIGUEDAD, no una eleccion ──────────────────────────
# De `acceso=local` cuelga la identidad del sellador. Con dos filas asi, quien la use elige por
# ORDEN DE LINEA: la garantia se apoyaria en el orden del fichero, no en el dato.
perfil_base \
  | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/' \
  | sed 's/ip=192.0.2.11;rol=satelite/ip=192.0.2.11;rol=satelite;acceso=local/' > "$T/dos-locales.tsv"
bash "$S/lib-perfil.sh" --check "$T/dos-locales.tsv" >/dev/null 2>&1
assert_rc "[r5-3] dos maquinas con acceso=local -> V9, rc 1" 1 $?

# ── #4 · el `%` de crontab, y por la razon correcta ────────────────────────────────────────────
# NO es un problema de printf —el comando viaja como ARGUMENTO—: es la gramatica de crontab, donde
# `%` se traduce a salto de linea y lo que sigue al primero pasa como stdin.
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando 'date +%Y' >/dev/null 2>&1
assert_rc "[r5-4] --comando con % SIN escapar -> 2" 2 $?
# Y no basta el rc: una regresion que "arreglara" `date +\%Y` a `date +%Y` tambien devolveria 0, y
# la entrada emitida tendria OTRA semantica en crontab (el `%` se traduce a salto de linea y lo que
# sigue al primero pasa como stdin). Se comprueba lo que SALE, que es lo que acaba en la tabla.
salida_pct="$(TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando 'date +\%Y' 2>/dev/null)"; rc_pct=$?
assert_rc "[r5-4] --comando con \% escapado -> 0 (pasa tal cual)" 0 "$rc_pct"
case "$salida_pct" in
  *'date +\%Y'*) pct_ok=0 ;;
  *)             pct_ok=1 ;;
esac
assert_rc "[r5-4] y la entrada emitida CONSERVA el \% escapado" 0 "$pct_ok"

printf '== r6: los dos de la ronda 5 ==\n'

# ── #1 · la serializacion remota no puede hablar el dialecto de BASH ───────────────────────────
# `printf '%q'` emite comillas ANSI-C (`$'...\n...'`) en cuanto hay saltos de linea, y el payload
# es un fichero ENTERO: siempre los hay. Quien parte esa cadena en palabras es el LOGIN SHELL de
# la maquina remota, que no tiene por que ser bash.
# El caso no simula: monta un `ssh` de mentira que hace LO QUE HACE EL DE VERDAD —descartar
# opciones, comerse el destino, juntar el resto con espacios y entregarselo al login shell— y usa
# `dash` de login shell cuando esta. Asi el que decide no es la opinion del test, es el parser.
B="$T/bin-r6"; mkdir -p "$B"
cat > "$B/tmux" <<'STUB'
#!/bin/sh
for a in "$@"; do ultimo="$a"; done
printf '%s' "$ultimo" > "$SALIDA_R6"
STUB
cat > "$B/ssh" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; -*) shift ;; *) break ;; esac; done
shift
printf '%s' "$*" > "$RECIBIDO_R6"
exec "${SH_R6:-/bin/sh}" -c "$*"
STUB
cat > "$B/incus" <<'STUB'
#!/bin/sh
# `incus exec <cont> -- argv...` ejecuta argv TAL CUAL, sin shell de por medio.
shift 2
[ "$1" = "--" ] && shift
exec "$@"
STUB
chmod +x "$B/tmux" "$B/ssh" "$B/incus"
export SALIDA_R6="$T/llego-r6.txt" RECIBIDO_R6="$T/recibido-r6.txt"
SH_R6="$(command -v dash 2>/dev/null || printf '/bin/sh')"; export SH_R6

# El payload lleva lo que rompe: salto de linea, comilla simple y un `$`.
printf "primera 'linea'\nsegunda \$linea\n" > "$T/relevo-r6.txt"
# El contrato es el contenido SIN los saltos finales, que es lo que `$(cat)` deja en el script.
esperado_r6="$(cat -- "$T/relevo-r6.txt")"
# Perfil con un destino REMOTO y sin contenedor: es la ruta donde el `%q` salia crudo al login shell.
{ perfil_base | sed 's/ip=192.0.2.10;rol=mando/ip=192.0.2.10;rol=mando;acceso=local/'
  printf 'torre\ttorre-dos\tmaq-beta\t-\tses-torre\trol=coordinador\n'; } > "$T/perfil-r6.tsv"

: > "$SALIDA_R6"; : > "$RECIBIDO_R6"
PATH="$B:$PATH" TA_PERFIL="$T/perfil-r6.tsv" bash "$S/relay-ceo.sh" \
  --a torre:torre-dos --fichero "$T/relevo-r6.txt" >/dev/null 2>&1
assert_eq "[r6-1] remoto sin contenedor: el relevo llega byte a byte" "$esperado_r6" "$(cat "$SALIDA_R6")"
# Y el dialecto, medido EN EL NIVEL QUE IMPORTA. Este assert nacio verde contra el codigo roto y el
# defecto era suyo: miraba la cadena ya serializada del `--dry-run`, donde el bashismo va detras de
# backslashes (`\$\'`) y por tanto no aparece. Reaparece cuando el login shell quita UNA capa, que
# es justo lo que recibe el `ssh`. Se mide ahi: el artefacto correcto, no el que estaba a mano.
assert_eq "[r6-1] lo que recibe el login shell remoto no lleva comillas ANSI-C" \
  "0" "$(grep -oF -- "\$'" "$RECIBIDO_R6" | wc -l | tr -d '[:space:]')"

# La cadena larga: ssh -> login shell POSIX -> incus -> bash -lc -> tmux. Dos serializaciones.
# GUARDA DE REGRESION, no mordida: esta ruta ya pasaba con `%q` —la capa de dentro nombra su
# interprete y la de fuera vuelve a escapar el bashismo—, y se deja fijada para que siga pasando.
: > "$SALIDA_R6"; : > "$RECIBIDO_R6"
PATH="$B:$PATH" TA_PERFIL="$PL" bash "$S/relay-ceo.sh" \
  --a canal:canal-uno --fichero "$T/relevo-r6.txt" >/dev/null 2>&1
assert_eq "[r6-1] remoto + contenedor: el relevo llega byte a byte" "$esperado_r6" "$(cat "$SALIDA_R6")"

# ── #2 · el indice no puede PROHIBIR mudo lo que su propio ejemplo ensena ──────────────────────
# El ejemplo `:73` releva a un canal y la linea de fronteras decia «el CEO no maneja canales uno a
# uno». Quien lee solo el indice concluye que el ejemplo esta mal. No lo esta: la ref 01 lista el
# canal entre los destinos legitimos de un RELAY, y lo que prohibe es el REPARTO DE ENCARGOS. El
# defecto estaba en la compresion del indice, no en el ejemplo — por eso el caso exige las dos
# mitades: que la frontera nombre los dos actos, y que el ejemplo SIGA ahi (arreglarlo borrandolo
# dejaria el indice coherente y sin ensenar el uso que la ref 01 declara legitimo).
frontera_r6="$(grep -A2 'talent-orchestrator' "$ROOT/SKILL.md" | tr '\n' ' ')"
distingue_r6=no
case "$frontera_r6" in *encargo*) case "$frontera_r6" in *relevo*) distingue_r6=si ;; esac ;; esac
assert_eq "[r6-2] la frontera del indice distingue ENCARGO de RELEVO" "si" "$distingue_r6"
ejemplo_r6=no
case "$(cat "$ROOT/SKILL.md")" in *'relay-ceo.sh --a canal:'*) ejemplo_r6=si ;; esac
assert_eq "[r6-2] el indice sigue ensenando el relay a un canal" "si" "$ejemplo_r6"

printf '== r7: el ejemplo ensena el USO, no el nombre de una instancia ==\n'

# ── el cierre que quedo a medias en la r6 ──────────────────────────────────────────────────────
# El contrato del overlay —en la propia tabla de referencias— dice que el anexo es el UNICO fichero
# con nombres reales y que el cuerpo del skill es agnostico. El ejemplo de `--a` llevaba un id con
# FORMA de canal de verdad. El barrido anti-nombres no lo caza, y no es un fallo suyo: compara
# contra los nombres de ESTA instancia, y el contrato no habla de "los nombres de esta fabrica",
# habla de nombres. Un ejemplo es lo que se copia, asi que el id va como HUECO (`<id>` o `$VAR`).
# Este caso NO puede pasar en vacio: si alguien borra el ejemplo, [r6-2] enrojece. Los dos juntos
# dicen "tiene que estar, y tiene que estar sin nombre propio".
ids_literales=''
while read -r destino; do
  [ -n "$destino" ] || continue
  case "${destino#*:}" in
    '<'*|'$'*) : ;;
    *) ids_literales="$ids_literales $destino" ;;
  esac
done <<EOF
$(grep -oE -- '--a [A-Za-z]+:[^ ]+' "$ROOT/SKILL.md" | sed 's/^--a //')
EOF
assert_eq "[r7-1] los destinos de ejemplo del indice son huecos, no ids de instancia" "" "$ids_literales"

printf '== r8: auditoria dirigida — la CLASE del parseo de campos, barrida entera ==\n'

# ── P1 · el tabulador es IFS-WHITESPACE y `read` se come las celdas VACIAS ─────────────────────
# Medido:  printf 'a\t\tc\n' | { IFS=$'\t' read -r x y z; }  ->  x=[a] y=[c] z=[]
# La celda vacia desaparece y TODO se corre una columna. No da error: da otra respuesta.
# El contrato ADMITE vacios —V2 solo exige NF==6, contado con `awk -F'\t'`, que no colapsa, y V5
# contempla `maquina == ""`—, asi que el fixture de abajo es un perfil VALIDO, no un caso raro.
# Los tres consumidores se prueban por separado porque en cada uno el desplazamiento miente de una
# forma distinta: destino, identidad y tabla.
PVAC="$T/perfil-celda-vacia.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t\t\tip=192.0.2.10;acceso=local;usuario=%s\n' "$YO_REAL"
  printf 'torre\ttorre-vac\tmaq-alfa\t\tses-vac\trol=coordinador;usuario=nadie-torre\n'
  printf 'ceo\tCEO\tmaq-alfa\t\t\troles=ceo;usuario=%s\n' "$YO_REAL"; } > "$PVAC"
bash "$S/lib-perfil.sh" --check "$PVAC" >/dev/null 2>&1
assert_rc "[r8-1] el perfil con celdas vacias es VALIDO (V2 cuenta NF, no contenido)" 0 $?

# relay: con el colapso, `atributos` se leia de `sesion` y no se encontraba `acceso=local`, asi que
# el destino local ni siquiera se resolvia (rc 2 de precondicion) — un relevo perdido en silencio.
echo hola > "$T/relevo-r8.txt"
TA_PERFIL="$PVAC" bash "$S/relay-ceo.sh" --a torre:torre-vac --fichero "$T/relevo-r8.txt" --dry-run >/dev/null 2>&1
assert_rc "[r8-1] relay resuelve el destino con celdas vacias en el perfil" 0 $?

# sellar: el mismo desplazamiento tumbaba la IDENTIDAD del sellador, que es de lo que responde el bus.
BVAC="$T/bus-r8"; : > "$BVAC"
TA_BUS="$BVAC" TA_PERFIL="$PVAC" bash "$S/bus-sellar.sh" --rol CEO --marcador R8 --nota "con vacios" >/dev/null 2>&1
assert_rc "[r8-1] sellar verifica identidad con celdas vacias en el perfil" 0 $?

# render: aqui el desplazamiento no rompe nada, PINTA MAL — que es peor, porque se lee como cierto.
# La primera version de este caso usaba el glob `torre-vac*maq-alfa*ses-vac*` y PASABA contra el
# codigo roto: un glob comprueba el ORDEN DE APARICION, no la columna, y con el desplazamiento los
# tres valores siguen apareciendo en ese orden — con un cuarto detras. Se cuentan los campos: con
# `contenedor` vacio la fila tiene TRES valores; con el colapso aparece un cuarto, que es el
# atributo entero corrido desde la ultima columna.
salida_r8="$(TA_PERFIL="$PVAC" bash "$S/perfil-render.sh" --tabla torre 2>/dev/null | tail -1)"
assert_eq "[r8-1] la tabla del perfil no corre un cuarto valor a la fila" \
  "3" "$(printf '%s\n' "$salida_r8" | awk '{print NF}')"
assert_eq "[r8-1] y la sesion sigue siendo la sesion" \
  "ses-vac" "$(printf '%s\n' "$salida_r8" | awk '{print $3}')"

# ── P1b · la misma clase en `lib-tablas`, que es donde paro el PR ──────────────────────────────
# El caso viejo daba por bueno "hay un — en algun sitio". Con el colapso, la fila se corre y el
# guion aparece en la columna que FALTA al final, no en la que esta vacia: pasaba en verde con el
# defecto dentro. Se mide la POSICION, que es lo que se afirmaba sin comprobar.
# Se leen los campos con `awk`, no por desplazamiento de bytes: el «—» son 3 bytes en UTF-8 y
# `cut -c` cuenta bytes, con lo que el propio test tendria el defecto que vino a medir.
fila_r8="$(printf 'a\t\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
assert_eq "[r8-2] el hueco se pinta en la columna VACIA, no en la que falta" "—" "$(printf '%s\n' "$fila_r8" | awk '{print $2}')"
assert_eq "[r8-2] y el valor de despues NO se corre de columna" "c" "$(printf '%s\n' "$fila_r8" | awk '{print $3}')"

# ── P2 · dato con estructura dentro del dato: ANSI en una celda ────────────────────────────────
# Las celdas vienen de capturas de pane, y una captura trae secuencias ANSI. Son caracteres que NO
# se ven pero SI se cuentan: `tabla_pad` mide con ${#s}, asi que la fila coloreada se desalinea —
# en la tabla cuyo unico oficio es leerse de un vistazo. Es la capa siguiente del mismo sitio que
# ya paso de contar BYTES a contar CARACTERES. `ronda-canales.sh` ya limpiaba ANSI; aqui faltaba.
con_ansi="$(printf 'a\t\033[31mrojo\033[0m\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
sin_ansi="$(printf 'a\trojo\tc\n'                | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
assert_eq "[r8-3] una celda con ANSI se pinta igual que sin el (no desalinea)" "$sin_ansi" "$con_ansi"

# ── P4 · coherencia doc<->codigo: cada flag que la doc promete, existe ─────────────────────────
# GUARDA, no mordida: hoy los once salen bien. Se fija porque es la comprobacion mas barata del
# paquete —un grep— y porque un flag documentado que el script no acepta es de las pocas cosas que
# el lector descubre fallando, no leyendo.
# La primera version usaba `grep -oE '[a-z-]+\.sh --[a-z-]+'`, que solo captura el flag PEGADO al
# nombre del script: de `relay-ceo.sh --a … --fichero …` recogia `--a` y perdia `--fichero`. Un test
# que dice "todo flag" y mira uno por linea deja verde el borrado de los demas. Se recorren TODOS
# los flags de la linea, atribuyendolos al ultimo script nombrado en ella.
flags_rotos=''
while read -r script flag; do
  [ -n "$script" ] && [ -n "$flag" ] || continue
  case "$script" in
    skills/*/scripts/*.sh) script_path="$ROOT/../../$script" ;;
    *) script_path="$ROOT/scripts/$script" ;;
  esac
  if [ -f "$script_path" ]; then
    grep -qF -- "$flag)" "$script_path" || flags_rotos="$flags_rotos $script$flag"
  else
    flags_rotos="$flags_rotos $script(no-existe)"
  fi
done <<EOF
$(cat "$ROOT/SKILL.md" "$ROOT"/references/*.md | tr -d '\140' | awk '
   { s = ""
     for (i = 1; i <= NF; i++) {
       if ($i ~ /^skills\/[a-z-]+\/scripts\/[a-z-]+\.sh$/) { s = $i }
       else if ($i ~ /[a-z-]+\.sh$/) { n = split($i, pa, "/"); s = pa[n] }
       else if (s != "" && $i ~ /^--[a-z-]+$/) print s, $i
     } }' | sort -u)
EOF
assert_eq "[r8-4] todo flag que la doc promete lo acepta su script" "" "$flags_rotos"

# ── P4 · y al reves: todo ejemplo de la doc trae los argumentos OBLIGATORIOS ────────────────────
# El caso de arriba comprueba que los flags documentados EXISTAN. No veia el fallo simetrico: un
# ejemplo al que le FALTA un obligatorio. Paso de verdad — el Quick Start sellaba sin `--rol`, o
# sea que copiar el ejemplo canonico del skill daba rc 2. Un ejemplo que no corre es peor que no
# tener ejemplo: el lector supone que el error es suyo.
# Los obligatorios se leen del propio script, de sus mensajes «PRECOND: falta X» y «X obligatorio»,
# admitiendo alternativas (`--minutos|--crontab`, `--rol (o TA_ROL)`).
# LIMITACION DECLARADA: se exige que aparezca una de las alternativas TEXTUALMENTE en la linea; un
# ejemplo que cumpliera el obligatorio por otra via no contemplada aqui daria falso positivo.
docs_sin_obligatorio=''
for sc in "$ROOT"/scripts/*.sh; do
  base="$(basename "$sc")"
  specs="$(grep -ohE 'PRECOND: falta [^"]*|PRECOND: --[a-z-]+ obligatorio' "$sc" \
           | sed 's/.*PRECOND: falta //; s/.*PRECOND: //; s/ obligatorio.*//')"
  [ -n "$specs" ] || continue
  # Solo las lineas COPIABLES —las que empiezan por `bash` o por env + `bash`—. Las filas de las
  # tablas de rc (`| Sellar | \`bus-sellar.sh --marcador X\` | …`) son ETIQUETAS, no ejemplos: ahi
  # el flag nombra la operacion, no la invocacion completa, y exigirles los obligatorios daba
  # falsos positivos en cinco sitios. La distincion no es cosmetica: lo que alguien copia y pega
  # es lo que tiene que correr.
  ejemplos="$(grep -hE "^ *([A-Z_]+=[^ ]+ )*bash .*${base} --" "$ROOT/SKILL.md" "$ROOT"/references/*.md 2>/dev/null || true)"
  [ -n "$ejemplos" ] || continue
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    alts="$(printf '%s' "$spec" | grep -oE '\-\-[a-z-]+|TA_[A-Z_]+' | tr '\n' ' ')"
    [ -n "$alts" ] || continue
    while IFS= read -r linea; do
      [ -n "$linea" ] || continue
      hay=no
      for a in $alts; do case "$linea" in *"$a"*) hay=si ;; esac; done
      [ "$hay" = si ] || docs_sin_obligatorio="$docs_sin_obligatorio ${base}[$alts]"
    done <<EOF2
$ejemplos
EOF2
  done <<EOF
$specs
EOF
done
assert_eq "[r8-16] todo ejemplo de la doc trae los argumentos obligatorios de su script" "" "$docs_sin_obligatorio"

# ── P4 · el contrato que ENUMERA la doc es el que APLICA el validador ──────────────────────────
# V9 se anadio al validador una ronda antes y la referencia siguio enumerando V1-V8: un perfil que
# cumple las ocho documentadas podia salir rechazado por una regla que no estaba escrita en ningun
# sitio que el operador leyera. Se comprueba que cada regla que el codigo nombra esta en la ref.
reglas_sin_doc=''
# La extraccion mira DOS formas, no una: `fail("V5")` y el `printf("perfil: V5 violado ...)` que
# usa la regla que se cruza al final. Con solo la primera, V5 no salia y el caso decia «toda regla»
# comprobando ocho de nueve — otra vez un control que afirma mas de lo que mide.
for v in $(grep -ohE '"V[0-9]+"|perfil: V[0-9]+ violado' "$ROOT/scripts/lib-perfil.sh" \
           | grep -oE 'V[0-9]+' | sort -u); do
  grep -q "| $v |" "$ROOT/references/04-pozos-en-operacion.md" || reglas_sin_doc="$reglas_sin_doc $v"
done
assert_eq "[r8-6] toda regla que el validador aplica esta enumerada en la ref 04" "" "$reglas_sin_doc"

# ── P4 · las DOS limpiezas de ANSI del paquete son la MISMA ────────────────────────────────────
# `lib-tablas.sh` pinta la captura y `ronda-canales.sh` la clasifica: dos consumidores del mismo
# formato. Con dos expresiones distintas, la que menos se mira se queda corta — y fue lo que paso:
# una limpiaba solo el color y dejaba `[?25l` y `]0;titulo` visibles. Se exige por igualdad de
# TEXTO, no por buena intencion en un comentario.
# La extraccion se ancla al PROGRAMA de sed, no a un trozo de la linea: la primera version recorto
# por comillas y en `ronda-canales.sh` —que tiene mas comillas en la linea— se llevo medio comando.
# Las dos salian VACIAS y el caso comparaba nada con nada: verde perfecto sin mirar el codigo. Lo
# cazo el guard de vacuidad de dos lineas mas abajo, que esta ahi exactamente para esto.
# Y se comparan TODAS las copias de `ronda-canales.sh`, no la primera: ese fichero tiene DOS y
# mirar solo una dejaba que la otra divergiera sin que nada enrojeciera — el mismo agujero que este
# caso vino a cerrar, un nivel mas abajo.
exp_tablas="$(grep -oh "sed -E 's[^']*'" "$ROOT/scripts/lib-tablas.sh"    | grep -F 'x1b\]' | head -1)"
copias_ronda="$(grep -oh "sed -E 's[^']*'" "$ROOT/scripts/ronda-canales.sh" | grep -cF "$exp_tablas")"
total_ronda="$(grep -oh "sed -E 's[^']*'" "$ROOT/scripts/ronda-canales.sh" | grep -cF 'x1b\]')"
assert_eq "[r8-7] TODAS las copias de ronda-canales usan la misma expresion" "$total_ronda" "$copias_ronda"
exp_ronda="$( grep -oh "sed -E 's[^']*'" "$ROOT/scripts/ronda-canales.sh" | grep -F 'x1b\]' | head -1)"
assert_eq "[r8-7] la limpieza ANSI es identica en lib-tablas y en ronda-canales" "$exp_tablas" "$exp_ronda"
[ -n "$exp_tablas" ] && anclada=si || anclada=no
assert_eq "[r8-7] y no esta vacia (si no, el caso de arriba compara nada con nada)" "si" "$anclada"

# ── P2 · ANSI que NO es color: CSI privado y OSC ───────────────────────────────────────────────
# El caso anterior probaba `ESC[31m` y daba cobertura por "ANSI". Una captura de pane trae ademas
# el cursor (`ESC[?25l`, CSI privado) y el titulo de ventana (`ESC]0;…BEL`, OSC). Con la limpieza
# corta salian como `[?25l` y `]0;titulo` VISIBLES: falsean el contenido y el ancho.
sin_ansi_b="$(printf 'a\trojo\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
priv_ansi="$(printf 'a\t\033[?25lrojo\033[?25h\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
assert_eq "[r8-8] CSI privado (cursor) tampoco desalinea" "$sin_ansi_b" "$priv_ansi"
osc_ansi="$(printf 'a\t\033]0;titulo\007rojo\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
assert_eq "[r8-8] OSC (titulo de ventana) tampoco desalinea" "$sin_ansi_b" "$osc_ansi"
# OSC no es la unica secuencia de CARGA: DCS (`ESC P`), SOS (`ESC X`), PM (`ESC ^`) y APC (`ESC _`)
# tienen la misma gramatica —introductor, carga, ST—. Tratadas como escapes de dos caracteres se
# quitaba el introductor y la CARGA quedaba VISIBLE: `ESC P abc ST` salia como `abc`, texto que
# nadie escribio en la celda. Se prueba la familia, no la que fallaba.
carga_ok=si
for intro in 'P' 'X' '\136' '_'; do
  got="$(printf "a\t\033${intro}oculto\033\\\\rojo\tc\n" | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1)"
  [ "$got" = "$sin_ansi_b" ] || carga_ok="ESC-$intro: $got"
done
assert_eq "[r8-8] DCS/SOS/PM/APC no dejan su carga visible en la celda" "si" "$carga_ok"
# Y el otro lado del mismo control: limpiar de MAS tambien miente. Con la clase de intermedios mal
# escrita (`[ -\/]`, que en un bracket POSIX es el rango ` `..`\` porque la barra invertida NO
# escapa), un `ESC[Afoo` se comia la `A` de intermedio y la `f` de final: la celda perdia TEXTO
# LEGITIMO y nadie lo notaba, porque los casos de arriba solo probaban CSI CON parametros.
# Se prueban las dos direcciones: que quite lo que sobra y que no toque lo que no.
assert_eq "[r8-8] un CSI sin parametros no se lleva por delante el texto de despues" \
  "foo" "$(printf 'a\t\033[Afoo\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1 | awk '{print $2}')"
assert_eq "[r8-8] y los caracteres de parametro sueltos NO son ANSI: se conservan" \
  "a?b=c>d" "$( . "$S/lib-tablas.sh"; tabla_celda 'a?b=c>d' )"
# Y las secuencias TRUNCADAS, de las tres familias. Una captura de pane se corta por donde se
# corta, asi que esto no es un caso de laboratorio: sin sus reglas quedaba residuo VISIBLE —`31`
# de un `ESC[31` sin final, `(` de un `ESC(` sin final, `0;titulo` de un OSC sin BEL—, que es la
# misma mentira contada en trozos mas pequenos. La suite las probaba todas COMPLETAS y por eso no
# lo veia: **probar solo la forma bien terminada es probar la forma que ya tienes en la cabeza.**
trunc_ok=si
for seq in '\033[31' '\033(' '\033]0;titulo' '\033P'; do
  got="$( . "$S/lib-tablas.sh"; tabla_celda "$(printf "X${seq}")" )"
  [ "$got" = "X" ] || trunc_ok="$seq -> $got"
done
assert_eq "[r8-17] las secuencias TRUNCADAS (CSI, nF, cadena) no dejan residuo visible" "si" "$trunc_ok"
assert_eq "[r8-17] y una captura cortada en mitad de una secuencia se clasifica empty" \
  "empty" "$(printf '\033[31' | bash "$S/ronda-canales.sh" --clasificar)"

# ── P2 · el TERMINADOR no es el mismo para todas las cadenas ───────────────────────────────────
# Solo OSC admite BEL (extension de xterm); DCS, SOS, PM y APC terminan SOLO con ST. Con una regla
# comun, un BEL dentro de la carga de un DCS cortaba la limpieza antes de tiempo y el resto de la
# carga salia a la celda. La suite no lo veia porque **probaba todas las cadenas terminadas en ST**.
assert_eq "[r8-18] un BEL dentro de un DCS no termina la secuencia" \
  "XY" "$( . "$S/lib-tablas.sh"; tabla_celda "$(printf 'X\033Pa\007b\033\\Y')" )"
assert_eq "[r8-18] y el BEL SI termina un OSC, que es el unico que lo admite" \
  "XY" "$( . "$S/lib-tablas.sh"; tabla_celda "$(printf 'X\033]0;t\007Y')" )"

# ── P2 · los controles C1, y por que NO se borran por rango ────────────────────────────────────
# `tr -d '[:cntrl:]'` cubre C0 y DEL, no los C1 (0x80-0x9F) — y ahi vive el CSI de 8 bits `0x9B`,
# que hace de `ESC [` en un terminal que los interprete. El codigo, la doc y un caso afirmaban
# cubrir «cualquier control» y no era verdad.
# Y NO se pueden borrar por rango: en UTF-8 esos bytes son CONTINUACION de caracteres legitimos —
# el propio «—» es `e2 80 94`—, asi que borrarlos partiria el guion que la tabla existe para pintar.
# El corte es «no es UTF-8 valido». Se prueban las DOS direcciones, que es la leccion de la noche.
# El fixture anterior era `0x9B` seguido de un `[2J` LITERAL —o sea, un CSI de 8 bits mal formado—
# y el assert daba por CORRECTA la carga visible que sobraba: yo mismo habia codificado el residuo
# como bueno. La forma real es `0x9B 2 J`, sin el corchete. Y se comprueba la otra direccion: el
# guion largo lleva un 0x80 DENTRO y no puede tocarse.
assert_eq "[r8-19] un CSI de 8 bits (0x9B) se limpia ENTERO, no solo su introductor" \
  "XY" "$( . "$S/lib-tablas.sh"; tabla_celda "$(printf 'X\2332JY')" )"
assert_eq "[r8-19] y un OSC de 8 bits tambien" \
  "XY" "$( . "$S/lib-tablas.sh"; tabla_celda "$(printf 'X\2350;t\234Y')" )"
assert_eq "[r8-19] una captura que solo lleva un CSI de 8 bits es empty, no text" \
  "empty" "$(printf '\2332J' | bash "$S/ronda-canales.sh" --clasificar)"

# ── P2 · el `%` de crontab y la PARIDAD de barras ──────────────────────────────────────────────
# Borrar pares `\%` de izquierda a derecha ignoraba la paridad: en `\\%` la primera barra escapa a
# la SEGUNDA, el `%` queda SUELTO y crontab lo traduce igual — pero el borrado se llevaba el par y
# daba la cadena por limpia. Escapado = numero IMPAR de barras delante. Se prueban los cuatro.
for par in '%:2' '\%:0' '\\%:2' '\\\%:0'; do
  cmd="date +${par%:*}"; esp="${par##*:}"
  TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando "$cmd" >/dev/null 2>&1
  assert_rc "[r8-20] paridad de barras ante el % de crontab: $cmd" "$esp" $?
done

# ── P2 · los C1 tampoco pasan por los campos que se RECHAZAN (no se limpian) ───────────────────
# `[[:cntrl:]]` es C0 y DEL. Un `0x9B` suelto entraba al bus y a la linea de crontab. Se rechaza
# lo que NO es UTF-8 valido —unica condicion bajo la que ese byte esta suelto— para no filtrar por
# rango y cargarse los acentos, que en `--nota` son prosa legitima.
: > "$T/bus-c1"; : > "$T/bus-acentos"    # el sellador exige que el bus EXISTA: sin esto el caso
                                        # de control fallaba por precondicion y no por la nota
TA_BUS="$T/bus-c1" TA_PERFIL="$PL" bash "$S/bus-sellar.sh" --rol CEO --marcador C1 --nota "$(printf 'a\233b')" >/dev/null 2>&1
assert_rc "[r8-21] --nota con un C1 suelto -> 2" 2 $?
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando "$(printf 'echo \233')" >/dev/null 2>&1
assert_rc "[r8-21] --comando con un C1 suelto -> 2" 2 $?
TA_BUS="$T/bus-acentos" TA_PERFIL="$PL" bash "$S/bus-sellar.sh" --rol CEO --marcador ACENTOS --nota 'ñáü—' >/dev/null 2>&1
assert_rc "[r8-21] y la prosa con acentos SIGUE pasando (no se filtra por rango)" 0 $?

# ── P3 · una maquina destino VACIA no es "remota" ──────────────────────────────────────────────
# V2 admite la celda vacia, y con ella `$maq != $local_id` es cierto: el relevo acababa en
# `ssh -- ""`. Sin saber DONDE vive el destino no se decide nada.
PMV="$T/perfil-maq-vacia.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10;acceso=local\n'
  printf 'torre\ttorre-sinmaq\t\t-\tses-x\trol=coordinador\n'; } > "$PMV"
echo hola > "$T/relevo-maqvacia.txt"
TA_PERFIL="$PMV" bash "$S/relay-ceo.sh" --a torre:torre-sinmaq --fichero "$T/relevo-maqvacia.txt" --dry-run >/dev/null 2>&1
assert_rc "[r8-22] destino sin maquina declarada -> 2, no se trata como remoto" 2 $?

# ── P2 · «UTF-8 valido» NO implica «sin controles» ─────────────────────────────────────────────
# Los C1 tienen forma UTF-8 legitima: U+009B —que ES el CSI— se codifica `c2 9b`, pasa cualquier
# validacion de codificacion y un terminal en UTF-8 lo interpreta igual. Se rechaza la BANDA de
# codepoints U+0080..U+009F, que no aparece en prosa: es la banda de control, no letras.
TA_BUS="$T/bus-c1u"; : > "$TA_BUS"
TA_BUS="$TA_BUS" TA_PERFIL="$PL" bash "$S/bus-sellar.sh" --rol CEO --marcador C1U --nota "$(printf 'a\302\233b')" >/dev/null 2>&1
assert_rc "[r8-23] --nota con U+009B BIEN codificado (c2 9b) -> 2" 2 $?
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno --comando "$(printf 'echo \302\233')" >/dev/null 2>&1
assert_rc "[r8-23] --comando con U+009B bien codificado -> 2" 2 $?

# ── P2 · un NUL en el relevo lo altera EN SILENCIO ─────────────────────────────────────────────
# La sustitucion de comandos descarta el NUL —bash avisa por stderr y sigue— asi que el relevo se
# entregaba ALTERADO con rc 0. Entregar un texto distinto del que alguien escribio, y decir que fue
# bien, es la peor combinacion que hay.
printf 'ab\000cd' > "$T/relevo-nul.txt"
bash "$S/relay-ceo.sh" --a torre:torre-dos --fichero "$T/relevo-nul.txt" --dry-run >/dev/null 2>&1
assert_rc "[r8-24] un relevo con NUL se rechaza, no se entrega recortado" 2 $?
assert_eq "[r8-19] y el guion largo —que LLEVA un 0x80 dentro— queda intacto" \
  "a—b" "$( . "$S/lib-tablas.sh"; tabla_celda 'a—b' )"

# ── P2 · un campo del perfil no puede mandar sobre el terminal ─────────────────────────────────
# El perfil lo edita una persona y estas columnas se imprimian TAL CUAL. Un `id` con `ESC[2J` pasa
# `--check` con rc 0 —el contrato valida ESTRUCTURA, no que los campos sean inertes— y al pintar la
# tabla borraba la pantalla: la tabla de mando quedaba a merced del dato que muestra.
PCTL="$T/perfil-control.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10;acceso=local\n'
  printf 'cron\tcr\033[2Jon\302\233malo\t-\t-\t-\tdueno=CEO;minutos=07\n'; } > "$PCTL"
bash "$S/lib-perfil.sh" --check "$PCTL" >/dev/null 2>&1
assert_rc "[r8-11] el perfil con un ESC en un campo PASA el contrato (valida estructura)" 0 $?
# Mismo motivo: si `perfil-render` fallara, la salida vacia daria `0` controles y el caso pasaria
# sin haber pintado tabla ninguna.
salida_ctl="$(TA_PERFIL="$PCTL" bash "$S/perfil-render.sh" --tabla cron 2>/dev/null)"; rc_ctl=$?
assert_rc "[r8-11] el render CORRE (si no, el conteo de abajo es vacio, no verde)" 0 "$rc_ctl"
# Se cuentan TODOS los caracteres de control, no solo el ESC: equiparar "sin byte ESC" con "sin
# controles" dejaba pasar los C1 (0x80-0x9F), que hacen de introductor igual que `ESC[`. El caso
# habria seguido verde con el renderizador emitiendolos.
# Se cuentan los C0 **y** los C1 en su forma UTF-8 (`c2 80`..`c2 9f`): `[:cntrl:]` no ve los
# segundos, asi que el caso afirmaba «ningun control» comprobando solo la mitad.
assert_eq "[r8-11] y aun asi la tabla no emite NINGUN control, ni C0 ni C1" "0" \
  "$(printf '%s\n' "$salida_ctl" | LC_ALL=C tr -dc '[:cntrl:]' | tr -d '\n' | wc -c | tr -d '[:space:]')"
assert_eq "[r8-11] (y los C1 codificados en UTF-8 tampoco)" "0" \
  "$(printf '%s\n' "$salida_ctl" | LC_ALL=C grep -c $'\xc2[\x80-\x9f]')"

# ── P2 · la familia nF: `ESC ( B` no la cubria NINGUNA regla ───────────────────────────────────
# La seleccion de juego de caracteres (`ESC` + intermedios `0x20-0x2F` + final) no es exotica: la
# emite cualquier terminal al resetearse. Salia como `(B` en la celda — contenido y ancho falsos —
# y en el clasificador convertia una captura VACIA en `text`, o sea un canal ocioso contado como
# canal con trabajo. Se prueba en los dos consumidores, que es donde duele distinto.
assert_eq "[r8-12] un escape nF (ESC ( B) no deja residuo visible en la celda" \
  "—" "$( . "$S/lib-tablas.sh"; tabla_celda "$(printf '\033(B')" )"
assert_eq "[r8-12] y una captura que solo lleva eso se clasifica empty, no text" \
  "empty" "$(printf '\033(B' | bash "$S/ronda-canales.sh" --clasificar)"
assert_eq "[r8-12] un ESC suelto tampoco cuenta como contenido" \
  "empty" "$(printf '\033' | bash "$S/ronda-canales.sh" --clasificar)"

# ── P1 · el ultimo registro sin salto de linea final ───────────────────────────────────────────
# `while read -r linea` devuelve falso al topar con EOF aunque haya cargado texto, asi que una
# captura que no acabe en LF PERDIA su ultima fila **sin ruido** — y una captura de pane no tiene
# por que acabar en LF: depende de donde se corte. Perder una fila en silencio es exactamente lo
# que la regla de oro de `lib-tablas` prohibe.
assert_eq "[r8-13] la ultima fila NO se pierde si la captura no acaba en salto de linea" \
  "c" "$(printf 'a\tb\tc' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | tail -1 | awk '{print $3}')"
assert_eq "[r8-13] y una captura vacia sigue sin inventar fila" \
  "2" "$(printf '' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) | wc -l)"

# ── P2 · un patron ERE invalido no puede parecerse a "no hay runners" ──────────────────────────
# `--patron '['` hacia fallar a `grep` dentro de la tuberia y el `exit 0` de despues devolvia la
# cabecera sola con rc 0: **indistinguible de "cero runners vivos"**. Fail-open del peor tipo, el
# que tranquiliza. Ahora es precondicion.
bash "$S/runners-vivos.sh" --patron '[' >/dev/null 2>&1
assert_rc "[r8-14] --patron con ERE invalido -> 2, no un listado vacio con rc 0" 2 $?

# ── P2 · el recorte de saltos FINALES del relevo, afirmado a mano ──────────────────────────────
# `contenido="$(cat -- "$fichero")"` recorta los saltos de linea finales. Es lo que se quiere —un
# salto final en `tmux send-keys -l` ENVIARIA la linea, y el relevo se deja escrito, no ejecutado—
# pero el caso que lo cubria calculaba el esperado con la MISMA sustitucion, o sea comparaba un
# recorte consigo mismo: pasaba dijera lo que dijera el codigo. Aqui el esperado va ESCRITO.
printf 'primera\nsegunda\n\n\n' > "$T/relevo-recorte.txt"
: > "$SALIDA_R6"; : > "$RECIBIDO_R6"
PATH="$B:$PATH" TA_PERFIL="$T/perfil-r6.tsv" bash "$S/relay-ceo.sh" \
  --a torre:torre-dos --fichero "$T/relevo-recorte.txt" >/dev/null 2>&1
assert_eq "[r8-15] el relevo llega SIN los saltos finales, y el esperado no se calcula igual" \
  "primera${nl}segunda" "$(cat "$SALIDA_R6")"

# ── P2 · el dato NO viaja por `awk -v`, que reinterpreta los escapes ───────────────────────────
# Medido: `awk -v a='loc\141l'` deja `a` valiendo `local`. El validador ve el texto CRUDO —para V9,
# `acceso=loc\141l` NO es `acceso=local`, asi que dos maquinas escritas asi pasan el limite de "a lo
# sumo una local"— mientras el lector devolvia `local` para las dos: el perfil diria una cosa y sus
# consumidores otra, que es el desacuerdo que V9 existe para impedir.
assert_eq "[r8-9] perfil_attr devuelve el valor LITERAL, sin pasar escapes por awk" \
  'loc\141l' "$( . "$S/lib-perfil.sh"; perfil_attr 'acceso=loc\141l' acceso )"
assert_eq "[r8-9] y el literal de verdad sigue leyendose igual" \
  'local' "$( . "$S/lib-perfil.sh"; perfil_attr 'acceso=local' acceso )"

# ── P1 · un argumento que FINGE un registro de `ps` no crea un runner fantasma ─────────────────
# GUARDA, y con DOS limitaciones dichas: (1) el `ps` de esta maquina sanea el salto de linea, asi
# que la condicion no se crea; (2) el par `99999 99998` NO existe en la tabla de procesos a
# proposito — un par REAL no se puede forzar de forma determinista sin carreras, asi que este caso
# no ejercita el residuo declarado en el codigo (una continuacion que imite al proceso SIGUIENTE).
# Ese residuo se declara donde vive, no se simula aqui con un fixture que no lo reproduce.
# el argumento no llega a partirse y el caso pasa con el codigo viejo y con el nuevo. Lo que fija es
# el contrato para donde SI se parta: el reensamblado por FORMA («empieza por dos numeros») lo
# cumple tambien un argumento que lleve «\n99999 99998 texto» y fabricaria una fila con un PID que
# no existe — alguien iria a matar un proceso inventado. Por eso la apertura de registro se ata a la
# tabla de procesos REAL y no a la forma de la linea.
marca_fant="fa-$(basename "$T")"
bash -c 'sleep 30; :' "$(printf 'primera\n99999 99998 finge-registro %s' "$marca_fant")" &
pid_fant=$!
sleep 1
# El rc se captura: sin eso, un fallo del listador da salida vacia, `awk` imprime `0` y el assert
# lo acepta como prueba de que no hay PID inventado. Verde sin haber corrido nada.
salida_fant="$(bash "$S/runners-vivos.sh" --patron "$marca_fant" 2>/dev/null)"; rc_fant=$?
assert_rc "[r8-10] el listador CORRE (si no, el conteo de abajo es vacio, no verde)" 0 "$rc_fant"
assert_eq "[r8-10] un argumento que finge un registro no cuela un PID inventado" \
  "0" "$(printf '%s\n' "$salida_fant" | awk '$1 == "99999" { n++ } END { print n + 0 }')"
kill "$pid_fant" 2>/dev/null; wait "$pid_fant" 2>/dev/null

# ── P2 · el separador de registro DENTRO del dato, otra vez: `ps` y los argumentos multilinea ──
# GUARDA DECLARADA, NO MORDIDA — y el motivo importa. La clase es real: un argumento puede llevar
# saltos de linea y, si `ps` los imprimiera tal cual, las lineas de continuacion no serian
# registros y el lector tomaria una palabra del argumento como `pid`. Pero MEDIDO aqui: el salto SI
# llega a `/proc/<pid>/cmdline` y el `ps` de esta maquina lo SUSTITUYE POR UN ESPACIO, asi que el
# fixture NO consigue crear la condicion y este caso pasa con el codigo viejo y con el nuevo.
# Se deja como guarda de portabilidad —POSIX no obliga a `ps` a sanear— y se declara asi en vez de
# venderlo como un rojo que nunca fue.
# El fixture pone el marcador en la SEGUNDA linea del argumento a proposito: asi el `grep` casa la
# linea de continuacion, que es donde esta el defecto. Se comprueba que el PID emitido es un
# NUMERO; sin reensamblar, es una palabra del argumento.
# El `; :` NO es decorativo: con `bash -c 'sleep 30'` a secas, bash hace EXEC de `sleep` porque el
# script es un unico comando simple, y el proceso que queda ya no lleva el argumento — el fixture
# no creaba la condicion que dice crear y el caso salia vacio. Medido. Con dos comandos, bash se
# queda vivo y `ps` ve el argumento multilinea.
marca_ml="ml-$(basename "$T")"
bash -c 'sleep 30; :' "$(printf 'primera-linea-del-argumento\n%s' "$marca_ml")" &
pid_ml=$!
sleep 1                       # que el proceso exista cuando se tome la instantanea
# La primera version de este assert miraba la fila 2 de la salida y PASABA contra el codigo roto:
# el registro bien formado va DELANTE de su propia continuacion, asi que la primera fila sale bien
# y el defecto anade una fila FANTASMA detras. Se mide el invariante que de verdad importa: toda
# fila emitida empieza por un PID, es decir por digitos. Con el defecto, la fila de continuacion
# empieza por una palabra del argumento.
salida_ml="$(bash "$S/runners-vivos.sh" --patron "$marca_ml" 2>/dev/null)"; rc_ml=$?
assert_rc "[r8-5] el listador CORRE (si no, el conteo de abajo es vacio, no verde)" 0 "$rc_ml"
filas_sin_pid="$(printf '%s\n' "$salida_ml" | tail -n +2 | awk '$1 !~ /^[0-9]+$/ { n++ } END { print n + 0 }')"
assert_eq "[r8-5] un argumento multilinea no cuela una fila sin PID en el listado" "0" "$filas_sin_pid"
kill "$pid_ml" 2>/dev/null; wait "$pid_ml" 2>/dev/null

# ══ r9 · lo que la ronda dirigida no miró ══════════════════════════════════════════════════════

# ── [r9-1..6] `tabla_desde_stdin` TIRABA los campos por encima del ancho de cabecera ───────────
# El defecto: `for ((i=0; i<n; i++))` recorría SOLO las columnas de la cabecera, asi que una fila
# con mas campos se pintaba recortada, con rc 0 y stderr vacio. Medido contra el codigo anterior:
#   printf 'a\tb\tc\tSOBRANTE\n' | tabla_desde_stdin UNO DOS TRES  ->  «a b c» · rc 0 · sin aviso
# Perdida SILENCIOSA de datos en el panel de mando. Los seis casos van en las DOS direcciones a
# proposito —tres para el defecto, tres para lo que ya funcionaba— porque un caso que solo recorre
# la forma que ya tenias en la cabeza no prueba el arreglo: confirma tu suposicion.
err_r9="$T/r9.err"
out_r9="$(printf 'a\tb\tc\tSOBRANTE\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) 2>"$err_r9")"
rc_r9=$?
assert_rc "[r9-1] fila con MAS campos que columnas -> rc 1 (antes: 0)" 1 "$rc_r9"
# Separado de [r9-1] a proposito: un "arreglo" que avisara y siguiera RECORTANDO pasaria aquel y
# fallaria este. Es exactamente la forma de medio arreglo que ya se colo una vez en este fichero.
assert_eq "[r9-2] el campo sobrante SE PINTA, no se descarta" "1" \
  "$(printf '%s' "$out_r9" | grep -c 'SOBRANTE')"
assert_eq "[r9-3] y el aviso sale por stderr nombrando la fila" "1" \
  "$(grep -c 'FILA 1: 4 campos para 3 columnas' "$err_r9")"

# La otra direccion: que el arreglo no se lleve por delante lo que ya era correcto.
out_r9c="$(printf 'a\tb\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) 2>"$err_r9")"
rc_r9c=$?
assert_eq "[r9-4] fila CORTA: sigue rellenando con «—», rc 0 y sin aviso" "0|1|" \
  "$rc_r9c|$(printf '%s' "$out_r9c" | tail -1 | grep -c '—')|$(cat "$err_r9")"
out_r9e="$(printf 'a\tb\tc\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) 2>"$err_r9")"
rc_r9e=$?
assert_eq "[r9-5] fila EXACTA: rc 0 y stderr vacio" "0|" "$rc_r9e|$(cat "$err_r9")"

# El contador de filas se prueba aparte: un contador que no incremente —o que cuente desde 0—
# pasaria [r9-3] y mentiria en cuanto la fila ancha no fuese la primera, que es el caso real.
printf 'a\tb\tc\nX\tY\tZ\tW\tQ\n' | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) \
  >/dev/null 2>"$err_r9"
assert_eq "[r9-6] el aviso numera la fila ANCHA, no la primera" "1" \
  "$(grep -c 'FILA 2: 5 campos para 3 columnas' "$err_r9")"

# ── [r9-8..11] CAN (0x18) y SUB (0x1A) ABORTAN una secuencia en curso ─────────────────────────
# En ECMA-48, CAN y SUB cancelan la secuencia que este abierta: el terminal la descarta y sigue
# mostrando lo que venga DESPUES. La limpieza no los contemplaba, asi que `tr -d '[:cntrl:]'` se
# llevaba el byte de control y dejaba los PARAMETROS como texto de la celda. Medido antes:
#     ESC [ 3 1 CAN m   ->  «31m»      (deberia quedar «m»)
#     ESC [ 7 SUB X     ->  «7X»       (deberia quedar «X»)
#     ESC ( CAN B       ->  «(B»       (deberia quedar «B»)
# Y el cuarto NO era residuo sino PERDIDA: con una cadena abortada, la regla de «cadena truncada»
# —greedy hasta el final— se comia el texto de despues:
#     ESC ] 0 ; titulo CAN rojo  ->  «—»   (deberia quedar «rojo»)
# es decir, la celda se quedaba SIN dato y se pintaba el guion: la tabla decia "aqui no hubo dato"
# donde si lo habia. Se anaden tres reglas de aborto —cadena, CSI y nF— colocadas ANTES de sus
# reglas de truncado, que son las greedy.
r9_cansub() { printf "a\t$1\tc\n" | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) 2>/dev/null | tail -1 | awk '{print $2}'; }
assert_eq "[r9-8]  CSI abortado por CAN: queda lo de DESPUES, no los parametros" "m" "$(r9_cansub '\033[31\030m')"
assert_eq "[r9-9]  CSI abortado por SUB: idem (SUB aborta igual que CAN)" "X" "$(r9_cansub '\033[7\032X')"
assert_eq "[r9-10] cadena abortada por CAN: el texto de despues SOBREVIVE" "rojo" "$(r9_cansub '\033]0;titulo\030rojo')"
# [r9-12..13] LA MISMA cadena, pero CON su terminador detras. Este es el caso que dejo pasar el
# defecto: [r9-10] no ponia terminador, asi que la regla de cadena COMPLETA no podia casar y el
# aborto se llevaba el merito. Con el BEL detras, la regla completa —cuya clase negada admitia el
# CAN— casaba de `ESC]` hasta el BEL y se comia `rojo`: la celda salia «—». La clase negada de las
# DOS reglas completas excluye ahora CAN y SUB, asi que ninguna puede CRUZAR un aborto.
# Es la tercera vez en esta pieza que un caso pasa porque solo recorre la forma que yo tenia en la
# cabeza. Por eso van las dos familias y las dos direcciones.
assert_eq "[r9-12] cadena abortada CON terminador detras (OSC/BEL): no se traga el texto" "rojo" \
  "$(r9_cansub '\033]0;t\030rojo\007')"
assert_eq "[r9-13] idem en la familia que solo admite ST (DCS)" "rojo" \
  "$(r9_cansub '\033P1\030rojo\033\\')"
# La direccion contraria: una cadena COMPLETA sin aborto se sigue limpiando entera, carga incluida.
assert_eq "[r9-14] cadena completa sin aborto: se limpia entera, no queda carga" "rojo" \
  "$(r9_cansub '\033]0;titulo\007rojo')"
assert_eq "[r9-11] nF abortado por CAN: queda el byte final, no el intermedio" "B" "$(r9_cansub '\033(\030B')"

# ── [r9-7] el Quick Start tiene que EJECUTAR desde la raiz del repo ────────────────────────────
# El defecto: `S=skills/talent-ceo/scripts` no resuelve en un repo que instala el paquete bajo
# `.claude/`. Los CINCO comandos del Quick Start daban `rc 127 · No such file or directory`: el
# ejemplo canonico del skill no corria copiado y pegado.
# NO vale comprobar que la ruta resuelve desde ALGUN ancestro —`.claude` es ancestro del paquete y
# `skills/talent-ceo/scripts` resuelve desde el, asi que ese check pasaria contra el defecto—. Se
# comprueba lo que el Quick Start promete: que la ubicacion REAL del paquete relativa a la RAIZ DEL
# REPO esta entre las rutas que el documento nombra. Asi vale igual instalado bajo `.claude/` que
# operado desde el repositorio donde vive como paquete: cada uno encuentra la suya.
# El caso necesita una raíz de repo. Sin ella se contabiliza SKIP con motivo;
# con ella se sigue evaluando la ruta exacta que promete el Quick Start.
raiz_repo=''; d_r9="$ROOT"
while :; do
  [ -e "$d_r9/.git" ] && { raiz_repo="$d_r9"; break; }
  [ "$d_r9" = "/" ] && break
  d_r9="$(dirname "$d_r9")"
done
if [ -z "$raiz_repo" ]; then
  SKIP=$((SKIP+1))
  printf '  SKIP sin raiz de repo; el Quick Start desde la raiz del repo no es evaluable\n'
else
  if [ "$ROOT" = "$raiz_repo" ]; then rel_r9='scripts'; else rel_r9="${ROOT#"$raiz_repo"/}/scripts"; fi
  hay_r9=0
  while IFS= read -r cand_r9; do
    [ "$cand_r9" = "$rel_r9" ] && hay_r9=1
  done < <(grep -oE '\bS=[A-Za-z0-9_./-]+' "$ROOT/SKILL.md" | sed 's/^S=//' | sort -u)
  assert_eq "[r9-7] el Quick Start nombra la ruta real del paquete ($rel_r9)" "1" "$hay_r9"
fi

printf '== r9: la MAGNITUD, la dimension que las guardas de charset no miraban ==\n'
# Tres sitios distintos con el MISMO defecto: `case "$x" in *[!0-9]*)` acepta cualquier cadena de
# digitos, incluida una que NO CABE en el entero de 64 bits de bash. Ahi `[ ... -gt ... ]` no
# compara: ERRA («integer expression expected»). Sin `set -e` el script sigue como si la condicion
# fuese falsa, y en los tres casos la rama que se toma es la INSEGURA. Es la leccion de
# «charset != gramatica» que ya estaba escrita en `tablas-cron.sh`, con una dimension mas.
GRANDE=18446744073709551616                      # 2^64: todo digitos, no cabe

# [r9-15..16] bus-leer: el cursor gigante evadia la guarda de "cursor > tamano" y el
# `$((pos + 1))` desbordaba a 1 -> se re-emitia EL BUS ENTERO con rc 0 y se reescribia el cursor.
tdir_r9="$T/r9bus"; mkdir -p "$tdir_r9/c" "$tdir_r9/r"; chmod 700 "$tdir_r9/c"
printf 'ABC\n' > "$tdir_r9/bus"; printf '%s' "$GRANDE" > "$tdir_r9/c/HUGE.cursor"
salida_r9="$(XDG_RUNTIME_DIR="$tdir_r9/r" TA_BUS="$tdir_r9/bus" TA_BUS_CURSOR_DIR="$tdir_r9/c" \
             bash "$S/bus-leer.sh" --lector HUGE 2>/dev/null)"; rc_r9b=$?
assert_rc "[r9-15] cursor que no cabe en 64 bits -> rc 2 (antes: 0 y rebobinado)" 2 "$rc_r9b"
# Separado a proposito: un arreglo que devolviera 2 pero hubiera EMITIDO Y REESCRITO el cursor
# pasaria el anterior. Lo que importa es que no rebobine ni toque nada.
assert_eq "[r9-16] y ni emite el bus ni toca el cursor" "|$GRANDE" \
  "$salida_r9|$(cat "$tdir_r9/c/HUGE.cursor")"

# [r9-17] tablas-cron: `minutos` de 20 digitos pasaba la gramatica porque `10#…` desbordaba.
PGR="$T/perfil-grande.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10\n'
  printf 'cron\tc-grande\t-\t-\t-\tminutos=%s\n' "$GRANDE"
  printf 'cron\tc-paso\t-\t-\t-\tminutos=*/%s\n' "$GRANDE"
  printf 'cron\tc-cero\t-\t-\t-\tminutos=007\n'; } > "$PGR"
TA_PERFIL="$PGR" bash "$S/tablas-cron.sh" --minutos c-grande >/dev/null 2>&1; rc_a=$?
TA_PERFIL="$PGR" bash "$S/tablas-cron.sh" --minutos c-paso   >/dev/null 2>&1; rc_b=$?
assert_eq "[r9-17] minutos y paso fuera del rango entero -> rc 1 (antes: 0 y a la crontab)" "1|1" "$rc_a|$rc_b"
# La otra direccion: el tope por LONGITUD no puede cargarse un valor legitimo con ceros delante.
assert_eq '[r9-18] pero "007" sigue siendo valido (el tope es de longitud, no de forma)' "007" \
  "$(TA_PERFIL="$PGR" bash "$S/tablas-cron.sh" --minutos c-cero 2>/dev/null)"

# [r9-19] vigia-cuota: con un valor que no cabe, la comparacion erraba y `lado_actual` se quedaba
# en su valor inicial `bajo`: no alertaba y devolvia 0. Fail-open en la pieza que existe para cerrar.
est_r9="$T/estado-r9"; printf 'bajo\n' > "$est_r9"
bash "$S/vigia-cuota.sh" --valor "$GRANDE" --umbral 80 --estado "$est_r9" >/dev/null 2>&1
assert_rc "[r9-19] valor que no cabe en 64 bits -> rc 2, no un 'sin cambio' con rc 0" 2 $?

printf '== r9: el ancho de columna no puede depender del locale del llamante ==\n'
# `${#s}` cuenta caracteres SEGUN EL LOCALE de quien llama: bajo `LC_ALL=C` —el de esta suite y el
# de cualquier cron sin `LANG`— vuelve a contar BYTES, y «—» mide 3. La tabla se desalineaba justo
# en las celdas sin dato. Se compara el ancho pintado bajo DOS locales: tiene que ser el mismo.
anch_c="$(LC_ALL=C      bash -c '. "'"$S"'/lib-tablas.sh"; tabla_pad "—" 6; printf "|"')"
anch_u="$(LC_ALL=C.UTF-8 bash -c '. "'"$S"'/lib-tablas.sh"; tabla_pad "—" 6; printf "|"' 2>/dev/null)"
assert_eq "[r9-20] tabla_pad rellena igual bajo LC_ALL=C que bajo UTF-8" "$anch_u" "$anch_c"
# Y que rellena de verdad a 6 CARACTERES (si contara bytes saldrian 3 espacios menos).
assert_eq "[r9-21] y el relleno es de CARACTERES: «—» + 5 espacios" "—     |" "$anch_c"

# [r9-22] perfil-render pintaba con `printf '%-14s'`, que mide bytes: un `id` con tilde desplazaba
# todas las columnas siguientes de esa fila.
PAC="$T/perfil-acentos.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10\n'
  printf 'canal\tcanál\tmaq-alfa\tcont-1\tses-1\trol=x\n'
  printf 'canal\tcanal\tmaq-alfa\tcont-1\tses-1\trol=x\n'; } > "$PAC"
sal_r9="$(TA_PERFIL="$PAC" bash "$S/perfil-render.sh" --tabla canal 2>/dev/null)"
# La columna MAQUINA tiene que empezar en la MISMA posicion en las dos filas: una con tilde y otra
# sin ella. Se mide la posicion, no el texto — el defecto era un desplazamiento de una columna.
#
# Y se mide en CARACTERES a mano. La primera version usaba `awk index()`, que bajo el `LC_ALL=C`
# de esta suite cuenta BYTES: daba 16 y 17 sobre un render que estaba PERFECTAMENTE alineado (15 y
# 15 en caracteres) y el caso salia rojo contra codigo correcto. Es el mismo defecto que persigue
# —medir el ancho con una regla que depende del locale— metido en el instrumento de medida.
_pos_car() {   # posicion, en caracteres, donde arranca "maq-alfa" en la linea dada
  local l="${1-}" pre
  pre="${l%%maq-alfa*}"
  [ "$pre" = "$l" ] && { printf '0'; return; }     # no aparece: 0, y la guarda de abajo lo caza
  printf '%s' "$(( $(printf '%s' "$pre" | LC_ALL=C tr -d '\200-\277' | wc -c) + 1 ))"
}
pos_con="$(_pos_car "$(printf '%s\n' "$sal_r9" | grep    'canál' | head -1)")"
pos_sin="$(_pos_car "$(printf '%s\n' "$sal_r9" | grep -E '^canal ' | head -1)")"
assert_eq "[r9-22] la columna MAQUINA arranca igual con tilde que sin ella" "$pos_sin" "$pos_con"
# Guarda de vacuidad: si el fixture no hubiera pintado nada, las dos posiciones serian 0 y el caso
# de arriba pasaria sin haber medido nada. Ya me colo una vez un assert entre dos cadenas vacias.
assert_eq "[r9-23] (guarda) el fixture pinto de verdad: la posicion no es 0" "1" \
  "$([ "${pos_sin:-0}" -gt 0 ] && echo 1 || echo 0)"

printf '== r10: auditoria COMPLETA — los diez que no miraba ninguna ronda dirigida ==\n'

# ── bus-leer: un cursor que no se entiende NO es un cursor en cero ─────────────────────────────
# Antes: `+1`, `-1`, ` 1`, `1 ` y `abc` caian a 0 EN SILENCIO y re-emitian el bus entero con rc 0,
# reescribiendo el cursor. Medido sobre un bus `abcdef`: los cinco daban `abcdef` y cursor 7.
d10="$T/r10bus"; mkdir -p "$d10/c" "$d10/r"; chmod 700 "$d10/c"
printf 'abcdef\n' > "$d10/bus"
_leer10() { XDG_RUNTIME_DIR="$d10/r" TA_BUS="${2:-$d10/bus}" TA_BUS_CURSOR_DIR="$d10/c" \
            bash "$S/bus-leer.sh" --lector "$1" 2>/dev/null; }
printf '+1' > "$d10/c/CUR.cursor"
sal10="$(_leer10 CUR)"; rc10=$?
assert_eq "[r10-1] cursor ilegible -> rc 2, sin emitir y sin tocarlo (antes: rc 0 y rebobinado)" \
  "2||+1" "$rc10|$sal10|$(cat "$d10/c/CUR.cursor")"
# La otra direccion: el cursor AUSENTE si es un cero legitimo — es la primera lectura del lector.
sal10b="$(_leer10 NUEVO)"; rc10b=$?
assert_eq "[r10-2] cursor AUSENTE sigue siendo la primera lectura, no un error" "0|abcdef" "$rc10b|$sal10b"

# ── bus-leer: el cursor va atado al bus, no solo al lector ─────────────────────────────────────
# Antes: leido un bus `AAAA` (cursor->4), leer con el MISMO lector otro bus `BBBBBBBB` emitia solo
# `BBBB` con rc 0 — los cuatro primeros bytes del bus NUEVO se saltaban en silencio.
printf 'AAAA' > "$d10/bus1"; printf 'BBBBBBBB' > "$d10/bus2"
# La PREPARACION se afirma, no se ignora. Antes iba a `/dev/null` sin mirar su rc: con un mutante
# que hiciera fallar toda lectura, la preparacion no creaba cursor ni marca, la lectura del bus
# rotado daba `2|` por OTRO motivo y el caso salia verde sin haber ejercitado una rotacion.
_leer10 ROT "$d10/bus1" >/dev/null; rc10prep=$?
sal10c="$(_leer10 ROT "$d10/bus2")"; rc10c=$?
assert_eq "[r10-3] bus rotado -> rc 2 tras una preparacion que SI funciono" "0|2|" \
  "$rc10prep|$rc10c|$sal10c"
# Otra direccion: con el MISMO bus se sigue leyendo con normalidad.
printf 'CCCC' >> "$d10/bus1"
sal10d="$(_leer10 ROT "$d10/bus1")"; rc10d=$?
assert_eq "[r10-4] mismo bus: la lectura incremental sigue funcionando" "0|CCCC" "$rc10d|$sal10d"

# ── relay-ceo: contenido que empieza por guion ─────────────────────────────────────────────────
# Sin `--`, `tmux send-keys -t <pane> -l -l` devuelve rc 0 y NO escribe nada (medido en tmux 3.4):
# el relay canta entrega y el pane queda vacio.
# El contenido del fixture era `-l`, el MISMO token que la opcion, asi que buscar la subcadena
# `'-l' '--'` daba verde tambien con el mutante `(... -l "$contenido" --)`, donde el `--` va DESPUES
# del payload y ya no protege nada. Se usa un contenido DISTINTO de la opcion y se afirma la cola
# EXACTA: opcion, separador, payload, en ese orden.
printf -- '-X' > "$T/relevo-guion.txt"
cmd10="$(TA_PERFIL="$PL" bash "$S/relay-ceo.sh" --a torre:torre-uno --fichero "$T/relevo-guion.txt" --dry-run 2>/dev/null)"
assert_eq "[r10-5] el -- va ENTRE la ultima opcion y el contenido, no detras" "1" \
  "$(printf '%s' "$cmd10" | grep -c -- "'-l' '--' '-X'")"

# ── la limpieza ANSI y los C1 BIEN CODIFICADOS ────────────────────────────────────────────────
# `c2 9b` ES U+009B, el CSI: `iconv` no lo descarta (esta bien codificado), `[:cntrl:]` no lo ve y
# las reglas buscan `\x1b`. Medido: los cuatro bytes de `c2 9b 32 4a` llegaban INTACTOS a la celda.
_c10() { printf "a\t$1\tc\n" | ( . "$S/lib-tablas.sh"; tabla_desde_stdin UNO DOS TRES ) 2>/dev/null | tail -1 | awk '{print $2}'; }
assert_eq "[r10-6] C1 codificado (CSI de 8 bits) se limpia entero" "rojo" "$(_c10 '\xc2\x9b2Jrojo')"
assert_eq "[r10-7] y su aborto por CAN deja lo de despues, no los parametros" "m" "$(_c10 '\xc2\x9b31\x18m')"
assert_eq "[r10-8] el clasificador no llama «text» a una carga invisible" "empty" \
  "$(printf '\xc2\x9b2J\n' | bash "$S/ronda-canales.sh" --clasificar 2>/dev/null)"
# LA OTRA DIRECCION, y no es opcional: el primer intento de esto borraba la banda 0x80-0x9F a lo
# bruto y se cargaba el guion largo (`e2 80 94`) y cualquier acento. Lo cazo este caso.
assert_eq "[r10-9] y NO toca texto legitimo cuyos bytes caen en esa banda" "a—b|canál|ñ" \
  "$(_c10 'a—b')|$(_c10 'canál')|$(_c10 'ñ')"

# ── sin `iconv`, la validacion se saltaba en vez de fallar ────────────────────────────────────
# Medido con un PATH funcional pero sin `iconv`: una nota con el C1 crudo `0x9b 2J` se sellaba con
# rc 0 y el byte quedaba en el bus; un `--comando` igual salia a la linea de crontab, que se EJECUTA.
sin_iconv="$T/bin-sin-iconv"; mkdir -p "$sin_iconv"
for d10d in /usr/bin /bin /usr/local/bin; do [ -d "$d10d" ] && ln -sf "$d10d"/* "$sin_iconv"/ 2>/dev/null; done
rm -f "$sin_iconv/iconv"
if PATH="$sin_iconv" command -v iconv >/dev/null 2>&1; then
  bad "[r10-10] (fixture) no se pudo construir un PATH sin iconv; el caso NO se ha ejercitado"
  bad "[r10-11] (fixture) idem"
else
  # CONTROL POSITIVO en el mismo caso, y no es adorno: la primera version de este assert daba rc 2
  # contra el codigo SIN arreglar — o sea, verde por el motivo equivocado. El motivo era que el
  # fichero del bus no existia y `bus-sellar` fallaba por PRECONDICION antes de llegar a `iconv`.
  # Se compara la PAREJA «con iconv» / «sin iconv»: solo el arreglo hace que difieran.
  : > "$T/bus-si"
  XDG_RUNTIME_DIR="$T/r10si" TA_PERFIL="$PL" TA_BUS="$T/bus-si" \
    bash "$S/bus-sellar.sh" --rol CEO --marcador SI0 --nota "nota limpia" >/dev/null 2>&1
  rc_con=$?
  sha_bus_antes="$(sha256sum < "$T/bus-si" | cut -d' ' -f1)"
  PATH="$sin_iconv" XDG_RUNTIME_DIR="$T/r10si" TA_PERFIL="$PL" TA_BUS="$T/bus-si" \
    bash "$S/bus-sellar.sh" --rol CEO --marcador SI1 --nota "$(printf 'x\x9b2Jy')" >/dev/null 2>&1
  rc_sin=$?
  # Y se afirma EL EFECTO, no solo el rc: el mutante `printf '%s' "$2" >> "$TA_BUS"; exit 2` escribe
  # el C1 hostil en el bus y deja la pareja de rc intacta. Lo que importa es que el bus quede limpio.
  # Y la propiedad FUERTE: el bus queda **byte a byte** como estaba. Contar el 0x9b no bastaba —el
  # mutante del auditor escribia el MARCADOR (`SI1`, ya validado antes del guard) y la asercion no lo
  # veia: rechazo con rastro, y la suite verde. Se compara el sha256 de antes y de despues.
  assert_eq "[r10-10] con iconv sella (0), sin iconv falla CERRADO (2) y el bus queda INTACTO" \
    "0|2|$sha_bus_antes" "$rc_con|$rc_sin|$(sha256sum < "$T/bus-si" | cut -d" " -f1)"
  # Se captura stdout en vez de tirarlo: el mutante `printf ... ; exit 2` EMITE la entrada hostil y
  # devuelve el rc esperado. Una entrada de crontab que llega a stdout ya puede acabar en un
  # crontab; el rc llega tarde.
  sal_cron="$(PATH="$sin_iconv" TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno \
    --comando "$(printf 'echo \x9b2J')" 2>/dev/null)"; rc_cron=$?
  assert_eq "[r10-11] sin iconv: rc 2 Y stdout VACIO (nada que pueda acabar en un crontab)" "2|" \
    "$rc_cron|$sal_cron"
fi

# ── vigia-cuota: persistia la transicion ANTES de comprobar que el aviso salio ─────────────────
# Medido con stdout en /dev/full: el estado quedaba en `alto`, el rc decia 10 («he avisado») y el
# tick siguiente devolvia 0 sin reemitir. La transicion se perdia PARA SIEMPRE.
est10="$T/estado-r10"; printf 'bajo' > "$est10"
bash "$S/vigia-cuota.sh" --valor 90 --umbral 80 --estado "$est10" >/dev/full 2>/dev/null
rc10v=$?
assert_eq "[r10-12] si el aviso no sale: rc 2 y el estado NO avanza" "2|bajo" "$rc10v|$(cat "$est10")"
sal10v="$(bash "$S/vigia-cuota.sh" --valor 90 --umbral 80 --estado "$est10" 2>/dev/null)"; rc10w=$?
assert_eq "[r10-13] y el tick siguiente SI reemite la transicion perdida" "10|1" \
  "$rc10w|$(printf '%s' "$sal10v" | grep -c 'bajo->alto')"

# ── runners-vivos: el parser de ETIME aceptaba formas de ninguna gramatica ─────────────────────
# `1:02:03:04` devolvia 3724 (se comia un componente) y `99:99` devolvia 6039. Una antiguedad
# inventada, y de ella cuelga la decision de matar un proceso.
# Se afirma que NO SALE NUMERO, no solo el rc. Los mutantes `printf '3724\n'; return 1` y
# `printf '6039\n'; return 1` devuelven el rc correcto y emiten igualmente la antiguedad inventada:
# quien consuma stdout se la cree. El rc es el veredicto, pero la salida es el dano.
sal_e1="$(bash "$S/runners-vivos.sh" --etime '1:02:03:04' 2>/dev/null)"; rc_e1=$?
assert_eq "[r10-14] etime de cuatro componentes: rc 1 Y sin emitir numero inventado" "1|" "$rc_e1|$sal_e1"
sal_e2="$(bash "$S/runners-vivos.sh" --etime '99:99' 2>/dev/null)"; rc_e2=$?
assert_eq "[r10-15] etime con segundos fuera de rango: rc 1 Y stdout vacio" "1|" "$rc_e2|$sal_e2"
# La otra direccion: las TRES formas documentadas siguen dando lo mismo que antes.
assert_eq "[r10-16] y las tres gramaticas documentadas no se tocan" "330|3930|442800" \
  "$(bash "$S/runners-vivos.sh" --etime 05:30)|$(bash "$S/runners-vivos.sh" --etime 01:05:30)|$(bash "$S/runners-vivos.sh" --etime 5-03:00:00)"

printf '== r11: lo que la ronda de MUTANTES demostro que NADIE acreditaba ==\n'
# La pasada con mutantes no encontro (casi) codigo roto: encontro ARREGLOS CORRECTOS QUE NADIE
# COMPROBABA. Cada mutante de abajo es literalmente el que sobrevivio en su acta, y cada caso existe
# para que ese mutante enrojezca. Un arreglo sin caso que lo muerda dura hasta el proximo que
# "simplifique" el fichero.
d11="$T/r11"; mkdir -p "$d11"

# Un directorio de utilidades desde el que se puede ROMPER una sola herramienta, dejando el resto
# del PATH intacto. `rm -f` ANTES de sembrar el stub: sin eso se escribe A TRAVES del symlink y se
# intenta sobrescribir el binario del sistema (comprobado: falla por permisos, pero no es lo que se
# quiere hacer).
_bin_roto() {   # _bin_roto <dir> <herramienta>
  mkdir -p "$1"
  for _d11 in /usr/bin /bin /usr/local/bin; do [ -d "$_d11" ] && ln -sf "$_d11"/* "$1"/ 2>/dev/null; done
  rm -f "$1/$2"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$1/$2"; chmod +x "$1/$2"
}

_leer11() { XDG_RUNTIME_DIR="$d11/r" TA_BUS="${2:-$d11/bus}" TA_BUS_CURSOR_DIR="$d11/c" \
            bash "$S/bus-leer.sh" --lector "$1" 2>/dev/null; }
mkdir -p "$d11/c" "$d11/r"; chmod 700 "$d11/c"

# [r11-1] cursor y marca son DOS escrituras: si la segunda falla, el lector NO puede quedar enclavado.
# Mutante del acta: `mv` que falla en su segunda invocacion. Con el orden viejo (cursor y luego
# marca) quedaba cursor>0 SIN marca, y eso es rc 2 por contrato: el lector no volvia a leer JAMAS.
printf 'ABC\n' > "$d11/bus"
cat > "$d11/mvfail.sh" <<'EOF11'
mv(){ MV_N=$(( ${MV_N:-0} + 1 )); if [ "$MV_N" -eq 2 ]; then return 1; fi; /usr/bin/mv "$@"; }
export -f mv
bash "$1" --lector ATOM
EOF11
XDG_RUNTIME_DIR="$d11/r" TA_BUS="$d11/bus" TA_BUS_CURSOR_DIR="$d11/c" \
  bash "$d11/mvfail.sh" "$S/bus-leer.sh" >/dev/null 2>&1
sal11a="$(_leer11 ATOM)"; rc11a=$?
assert_eq "[r11-1] si falla la 2a escritura, el lector SIGUE pudiendo leer (no se enclava)" "0|ABC" \
  "$rc11a|$sal11a"

# [r11-2] normalizacion decimal: `09` es octal INVALIDO en $(( )). Sin `10#`, `tail` no corre, no se
# emite nada y el cursor salta al final: el tramo entero perdido con rc 0.
printf '0123456789XYZ' > "$d11/bus2"
_leer11 OCT "$d11/bus2" >/dev/null            # primera lectura: crea cursor Y marca
printf '09' > "$d11/c/OCT.cursor"
sal11b="$(_leer11 OCT "$d11/bus2")"; rc11b=$?
assert_eq "[r11-2] un cursor con cero inicial emite lo mismo que sin el (no es octal)" "0|9XYZ" \
  "$rc11b|$sal11b"

# [r11-3] cursor >0 SIN marca: es estado que no se puede acreditar. Sin este corte, un cursor legado
# se aplica a un bus distinto y se salta su principio.
printf 'BBBBBBBB' > "$d11/bus3"
printf '4' > "$d11/c/LEG.cursor"; rm -f "$d11/c/LEG.bus"
sal11c="$(_leer11 LEG "$d11/bus3")"; rc11c=$?
assert_eq "[r11-3] cursor >0 sin marca de bus -> rc 2 y NO emite" "2|" "$rc11c|$sal11c"

# [r11-4] `wc` roto: `tam` vacio. Degradarlo a 0 hace que un bus con contenido parezca estar al dia.
_bin_roto "$d11/sin-wc" wc
mkdir -p "$d11/c4" "$d11/r4"; chmod 700 "$d11/c4"
sal11d="$(PATH="$d11/sin-wc" XDG_RUNTIME_DIR="$d11/r4" TA_BUS="$d11/bus" TA_BUS_CURSOR_DIR="$d11/c4" \
          bash "$S/bus-leer.sh" --lector W 2>/dev/null)"; rc11d=$?
assert_eq "[r11-4] con \`wc\` roto: rc 2, sin emitir y sin dejar cursor" "2||no" \
  "$rc11d|$sal11d|$([ -f "$d11/c4/W.cursor" ] && echo si || echo no)"

# [r11-5] `date` roto: un sello SIN hora escrito y cantado como sellado.
_bin_roto "$d11/sin-date" date
: > "$d11/bus-d"
PATH="$d11/sin-date" XDG_RUNTIME_DIR="$d11/r5" TA_PERFIL="$PL" TA_BUS="$d11/bus-d" \
  bash "$S/bus-sellar.sh" --rol CEO --marcador D1 --nota "limpia" >/dev/null 2>&1
rc11e=$?
assert_eq "[r11-5] con \`date\` roto: rc 2 y el bus queda VACIO (no un sello sin hora)" "2|0" \
  "$rc11e|$(wc -c < "$d11/bus-d" | tr -d ' ')"

# [r11-6] estado corrupto != estado ausente. Degradarlo a "primer tick" BORRA la transicion, porque
# el primer tick por contrato calla.
printf 'basura' > "$d11/est"
sal11f="$(bash "$S/vigia-cuota.sh" --valor 90 --umbral 80 --estado "$d11/est" 2>/dev/null)"; rc11f=$?
assert_eq "[r11-6] estado corrupto -> rc 2, sin emitir y SIN sobrescribir la evidencia" "2||basura" \
  "$rc11f|$sal11f|$(cat "$d11/est")"

# [r11-7] instantanea unica: lo que se ENTREGA tiene que ser lo que se VALIDO. El stub sustituye el
# fichero justo despues de la comprobacion; releer el original entregaria la version nueva.
_bin_roto "$d11/toctou" cmp
printf 'VIEJO' > "$d11/relevo.txt"
cat > "$d11/toctou/cmp" <<EOF11
#!/usr/bin/env bash
/usr/bin/cmp "\$@"; _rc=\$?
printf 'NUEVO' > "$d11/relevo.txt"
exit \$_rc
EOF11
chmod +x "$d11/toctou/cmp"
cmd11="$(PATH="$d11/toctou" TA_PERFIL="$PL" bash "$S/relay-ceo.sh" --a torre:torre-uno \
         --fichero "$d11/relevo.txt" --dry-run 2>/dev/null)"
assert_eq "[r11-7] se entrega lo VALIDADO, no lo que aparecio despues" "1|0" \
  "$(printf '%s' "$cmd11" | grep -c VIEJO)|$(printf '%s' "$cmd11" | grep -c NUEVO)"

# [r11-8] emision interrumpida: el cursor no puede avanzar si stdout no recibio el tramo.
mkdir -p "$d11/c8" "$d11/r8"; chmod 700 "$d11/c8"
XDG_RUNTIME_DIR="$d11/r8" TA_BUS="$d11/bus" TA_BUS_CURSOR_DIR="$d11/c8" \
  bash "$S/bus-leer.sh" --lector SP >/dev/full 2>/dev/null
rc11g=$?
assert_eq "[r11-8] emision a /dev/full: rc 2 y el cursor NO avanza" "2|no" \
  "$rc11g|$([ -f "$d11/c8/SP.cursor" ] && echo si || echo no)"

# [r11-9] `stat` roto para el BUS. Romper `stat` entero no sirve: `lib-bus.sh` lo usa antes para
# comprobar el modo del directorio de cursores, asi que la ejecucion moria ahi y el caso daba rc 2
# CON Y SIN mutante — verde por el motivo equivocado, que es justo lo que esta ronda persigue. El
# stub falla SOLO para la ruta del bus, y se afirma el MENSAJE: el rc 2 lo produce cualquier fallo.
_bin_roto "$d11/sin-stat" stat
cat > "$d11/sin-stat/stat" <<EOF11
#!/usr/bin/env bash
for _a in "\$@"; do [ "\$_a" = "$d11/bus" ] && exit 1; done
exec /usr/bin/stat "\$@"
EOF11
chmod +x "$d11/sin-stat/stat"
mkdir -p "$d11/c9" "$d11/r9"; chmod 700 "$d11/c9"
err11="$(PATH="$d11/sin-stat" XDG_RUNTIME_DIR="$d11/r9" TA_BUS="$d11/bus" TA_BUS_CURSOR_DIR="$d11/c9" \
  bash "$S/bus-leer.sh" --lector ST 2>&1 >/dev/null)"; rc11h=$?
assert_eq "[r11-9] sin poder leer la identidad del bus: rc 2 y lo DICE (no se inventa)" "2|1" \
  "$rc11h|$(printf '%s' "$err11" | grep -c 'identidad del bus')"

# [r11-10..12] LOS VECINOS de los siete introductores C1. Traducir siete y olvidar los otros
# veinticinco dejaba NEL (0x85) llegando al terminal. Se recorre la banda ENTERA byte a byte.
if PATH="$sin_iconv" command -v iconv >/dev/null 2>&1; then
  bad "[r11-10] (fixture) PATH sin iconv no construido"; bad "[r11-11] (fixture) idem"; bad "[r11-12] (fixture) idem"
else
  restos=0
  for _b11 in 80 81 82 83 84 85 86 87 88 89 8a 8b 8c 8d 8e 8f 91 92 93 94 95 96 97 99 9a; do
    _o11="$(PATH="$sin_iconv" bash -c "printf 'a\tX\\x$_b11""Y\tc\n' | ( . \"$S/lib-tablas.sh\"; tabla_desde_stdin UNO DOS TRES )" 2>/dev/null | tail -1 | awk '{print $2}')"
    [ "$_o11" = "XY" ] || restos=$((restos + 1))
  done
  assert_eq "[r11-10] sin iconv, los 25 vecinos C1 NO llegan a la celda" "0" "$restos"
  assert_eq "[r11-11] sin iconv, una captura de solo NEL no cuenta como trabajo" "empty" \
    "$(PATH="$sin_iconv" bash -c "printf '\x85\n' | bash \"$S/ronda-canales.sh\" --clasificar" 2>/dev/null)"
  PAC11="$T/perfil-nel.tsv"
  { printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
    printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10\n'
    printf 'cron\tc\x85r\t-\t-\t-\tminutos=05\n'; } > "$PAC11"
  assert_eq "[r11-12] sin iconv, perfil-render no imprime el byte crudo" "0" \
    "$(PATH="$sin_iconv" TA_PERFIL="$PAC11" bash "$S/perfil-render.sh" --tabla cron 2>/dev/null | LC_ALL=C od -An -tx1 | tr -s ' ' | grep -c ' 85' || true)"
fi

# [r11-13..14] LA OTRA DIRECCION en los dos consumidores donde no estaba cubierta: forzar la rama de
# C1 crudo destruye el guion largo (`e2 80 94`), y eso hay que verlo. `n` y `a` acentuadas NO valen
# como prueba: `c3 b1` y `c3 a1` no tienen ningun byte en la banda 0x80-0x9F. El guion si.
# La captura es SOLO el guion largo, a proposito: con `a—b` quedan la `a` y la `b` aunque el guion
# se destruya, asi que la clasificacion sigue siendo `text` con y sin mutante — el caso no
# discriminaba. Con el guion solo, forzar la rama de C1 crudo lo borra entero y la captura pasa a
# `empty`: un canal con texto contado como LIBRE.
assert_eq "[r11-13] una captura de SOLO guion largo sigue siendo texto, no se destruye" "text" \
  "$(printf '—\n' | bash "$S/ronda-canales.sh" --clasificar 2>/dev/null)"
PGL11="$T/perfil-guion.tsv"
{ printf 'tipo\tid\tmaquina\tcontenedor\tsesion\tatributos\n'
  printf 'maquina\tmaq-alfa\tmaq-alfa\t-\t-\tip=192.0.2.10\n'
  printf 'cron\ta—b\t-\t-\t-\tminutos=05\n'; } > "$PGL11"
assert_eq "[r11-14] y sobrevive en perfil-render" "1" \
  "$(TA_PERFIL="$PGL11" bash "$S/perfil-render.sh" --tabla cron 2>/dev/null | grep -c -- 'a—b')"

# [r11-15..16] `--estado bajo` se lee como un VALOR y es una RUTA: deja `bajo` y `bajo.lock` en el
# cwd. Paso dos veces el mismo dia, a dos operadores distintos, y los ficheros llegaron a aparecer
# sin seguir en el arbol de una entrega. Se rechaza el literal; `./bajo` sigue valiendo.
d11b="$T/r11b"; mkdir -p "$d11b"
( cd "$d11b" && bash "$S/vigia-cuota.sh" --valor 90 --umbral 80 --estado bajo >/dev/null 2>&1 )
rc11i=$?
assert_eq "[r11-15] --estado con el literal de un lado -> rc 2 y NO deja ficheros en el cwd" "2|0" \
  "$rc11i|$(ls -A "$d11b" | wc -l)"
# La otra direccion: con una ruta explicita, el mismo nombre SI vale — no se prohibe el nombre.
( cd "$d11b" && bash "$S/vigia-cuota.sh" --valor 90 --umbral 80 --estado ./bajo >/dev/null 2>&1 )
# El fichero se llama `bajo` pero su CONTENIDO es el lado medido, que con valor 90 y umbral 80 es
# `alto`. La primera version de este caso esperaba `bajo` —confundiendo el nombre del fichero con su
# contenido, que es la MISMA confusion que el caso de arriba persigue—. Se deja dicho.
assert_eq "[r11-16] pero ./bajo sigue siendo un fichero de estado legitimo (y guarda el LADO, no su nombre)" "0|alto" \
  "$?|$(cat "$d11b/bajo" 2>/dev/null)"

printf '== r12: el --help es un CONTRATO, no un volcado de las primeras lineas ==\n'
# [r12-1] CASO DE CLASE, no puntual. Cada script pinta su cabecera con `sed -n '2,N p'` sobre SI
# MISMO, y basta que la cabecera encoja —o que alguien anada comentarios y empuje el codigo hacia
# abajo, que es lo que hice yo hoy en tres de ellos— para que la `N` DESBORDE y el `--help` imprima
# `set -uo pipefail` y la linea de `source` como si fueran documentacion. Medido: SEIS de los nueve
# scripts lo hacian.
# El caso barre TODOS los scripts que soportan `--help`, presentes y futuros: un caso puntual habria
# arreglado un fichero y dejado la puerta abierta para el siguiente. Toda linea de un `--help` tiene
# que empezar por `#`, porque lo que se pinta es el bloque de comentario y nada mas.
# EL CENSO ES OBSERVABLE, NO TEXTUAL — y esta es la correccion que pidio la auditoria acotada.
# La primera version prefiltraba por la FORMA LITERAL del comando de impresion (`sed -n 'N,Np'`), asi
# que un script que pintara su ayuda de otra manera equivalente se caia del barrido y el caso seguia
# verde mientras la regresion era real. Mutante que lo demostro: `sed -n '2,31p'` -> `sed -n -e
# '2,34p'` en bus-leer — el `--help` imprimia `set -uo pipefail` y `HERE=...`, y la suite daba
# **245 ok, 0 FAIL**. El enunciado decia «NINGUN --help del paquete» y el censo era «los que imprimen
# de ESTA forma»: la comprobacion prometia un universo y verificaba un subconjunto.
# Ahora se pertenece al censo por lo que el script HACE: responde a `--help` con rc 0 y salida no
# vacia. Las librerias que se source-ean (`lib-bus`, `lib-tablas`) no imprimen nada y quedan fuera
# solas, sin lista blanca que mantener.
censo=''; help_sucio=''; declaran=''
for _sc12 in "$ROOT"/scripts/*.sh; do
  _n12="$(basename "$_sc12")"
  grep -q -- '--help' "$_sc12" && declaran="$declaran $_n12"
  _o12="$(bash "$_sc12" --help 2>/dev/null)" || continue
  [ -n "$_o12" ] || continue
  censo="$censo $_n12"
  while IFS= read -r _l12; do
    case "$_l12" in
      '#'*) : ;;
      *) help_sucio="$help_sucio $_n12:[$(printf '%s' "$_l12" | cut -c1-40)]" ;;
    esac
  done <<EOF12
$_o12
EOF12
done
# GUARDA DE COMPLETITUD, no de cantidad. La version anterior solo exigia «hay al menos cinco», que no
# acredita nada sobre QUIEN falta: un script podia salirse del censo y el minimo seguia cumpliendose.
# Se compara el censo con el conjunto de los que DECLARAN `--help` en su texto: si uno lo declara y
# no aparece, o su ayuda esta vacia o el barrido no lo ve, y las dos cosas hay que saberlas.
assert_eq "[r12-1] (completitud) todo script que declara --help esta en el censo del barrido" \
  "$declaran" "$censo"
assert_eq "[r12-2] NINGUN --help del paquete imprime una linea que no empiece por #" "" "$help_sucio"

printf '== r13: la cota que faltaba y la tuberia que no dispara ==\n'

# [r13-1] `10#` NO desborda ni falla sobre un numero que no cabe: **ENVUELVE**. Medido:
# `10#18446744073709551621` (2^64+5) da **5**. Por eso el `-le 59` de la gramatica de ETIME no acota
# nada por si solo: un valor astronomico se convierte en uno pequeno y pasa. La cota de LONGITUD
# existia y estaba puesta en `dias` y `h`, pero NO en `m` ni `s` — la puerta de al lado sin cerrar,
# en el mismo `&&`. Antes: `--etime 00:18446744073709551621` -> rc 0 y "5".
GRANDE13=18446744073709551621
assert_eq "[r13-1] (premisa) 10# sobre 2^64+5 no falla: envuelve a 5" "5" "$((10#$GRANDE13))"
sal13=$(bash "$S/runners-vivos.sh" --etime "00:$GRANDE13" 2>/dev/null); rc13=$?
assert_eq "[r13-2] minutos que no caben en 64 bits -> rc 1 y SIN emitir antiguedad" "1|" "$rc13|$sal13"
sal13b=$(bash "$S/runners-vivos.sh" --etime "0:00:$GRANDE13" 2>/dev/null); rc13b=$?
assert_eq "[r13-3] y lo mismo en los segundos" "1|" "$rc13b|$sal13b"

# [r13-4..6] `printf ... | grep -q` bajo `set -uo pipefail` NO dispara con entradas grandes: `grep -q`
# sale al casar y cierra el descriptor, `printf` muere por SIGPIPE (141) y `pipefail` devuelve 141,
# asi que el `if` no entra Y NADIE SE ENTERA. Se sustituyo por `case` con glob en los CUATRO sitios
# del paquete, no solo en los dos que traia el hallazgo.
# El fixture es grande a proposito: con entradas pequenas el defecto no aflora, que es justo lo que
# lo hacia invisible.
# 100 KB: por ENCIMA del bufer de tuberia (64 KB, que es lo que hace falta para que `printf` llegue
# a bloquearse y reciba SIGPIPE) y por DEBAJO del limite de longitud de UN argumento de `exec`
# (`MAX_ARG_STRLEN`, 128 KB en Linux). Con 200 KB el script ni arrancaba: rc 126, que es "no
# ejecutable" y no tiene nada que ver con el defecto — un fixture que no llega a correr no prueba nada.
grande13="$(head -c 100000 /dev/zero | tr '\0' 'x')"
: > "$T/bus13"; mkdir -p "$T/r13"
# LA SENAL VA AL PRINCIPIO, y no es un detalle del fixture: es LA condicion del defecto. Con la
# senal al final, `grep` tiene que leer la entrada entera, no sale antes de tiempo y no hay SIGPIPE
# — o sea que el `if` dispara y el caso pasa CON Y SIN arreglo. Comprobado: con la senal al final,
# este caso SOBREVIVIA a su propio mutante. Un fixture que no crea la condicion que dice probar es
# un adorno, por muy grande que sea.
XDG_RUNTIME_DIR="$T/r13" TA_PERFIL="$PL" TA_BUS="$T/bus13" \
  bash "$S/bus-sellar.sh" --rol CEO --marcador M13 --nota "$(printf '\xc2\x9b2J')$grande13" >/dev/null 2>&1
assert_eq "[r13-4] sellar rechaza un C1 aunque la nota sea grande, y el bus queda VACIO" "2|0" \
  "$?|$(wc -c < "$T/bus13" | tr -d ' ')"
TA_PERFIL="$P" bash "$S/tablas-cron.sh" --crontab cron-uno \
  --comando "$(printf '\xc2\x9b2J')$grande13" >/dev/null 2>&1
assert_rc "[r13-5] la entrada de crontab tampoco se emite con un C1 en carga grande" 2 $?
# El clasificador: el mecanismo no aflora por esta puerta (se dice en el fichero), asi que el caso
# fija la DIRECCION CARA — que un placeholder grande siga siendo `ghost` y no texto real.
assert_eq "[r13-6] un placeholder atenuado GRANDE sigue siendo ghost, no trabajo real" "ghost" \
  "$(printf '\033[2m%s\033[0m\n' "$grande13" | bash "$S/ronda-canales.sh" --clasificar 2>/dev/null)"
# Y la otra direccion, que es la que se rompe si uno se pasa de listo con el glob:
assert_eq "[r13-7] pero con texto real fuera del atenuado sigue siendo text" "text" \
  "$(printf '\033[2mgris\033[0m hola\n' | bash "$S/ronda-canales.sh" --clasificar 2>/dev/null)"

printf '== r14: NUL fail-closed en el perfil y la guarda que cambia con la localizacion ==\n'

# [r14-1/2] Un NUL en el perfil se rechaza ANTES de validar. `awk` no tiene contrato definido con el
# byte NUL —segun la implementacion trunca el registro, lo descarta o lo arrastra—, asi que un perfil
# con NUL puede recorrer las nueve reglas y salir VALIDO mientras el consumidor lee una fila distinta
# de la que se valido. Dar un visto bueno sobre algo que no se sabe leer es peor que no validar.
# EL NUL VA DENTRO DE UN ATRIBUTO LIBRE (`nota=`), a proposito: asi no rompe ninguna V y el fichero
# es, por lo demas, EXACTAMENTE el perfil bueno. Sin la guarda esto sale rc 0 —«valido»—, que es la
# forma cara del fallo; con ella, rc 2.
perfil_base | sed -n '1,9p' > "$T/p14-nul.tsv"
printf 'ceo\tCEO\tmaq-alfa\t-\t-\troles=ceo+pm_interino;nota=tienta' >> "$T/p14-nul.tsv"
printf '\000'                                                        >> "$T/p14-nul.tsv"
printf '_a_inferir\n'                                                >> "$T/p14-nul.tsv"
perfil_base | sed -n '11p'   >> "$T/p14-nul.tsv"
# Y el CONTROL POSITIVO, que es lo que convierte esto en una acreditacion: el MISMO fichero sin el
# NUL. Sin esta pareja, un rc 2 por cualquier otro motivo —una V que salta, un fixture mal armado—
# pasaria por bueno y el caso seria un adorno. Ya paso hoy con [r10-10]: nacio verde contra el
# codigo roto porque fallaba por precondicion antes de llegar a lo que decia medir.
perfil_base | sed -n '1,9p' > "$T/p14-limpio.tsv"
printf 'ceo\tCEO\tmaq-alfa\t-\t-\troles=ceo+pm_interino;nota=tienta_a_inferir\n' >> "$T/p14-limpio.tsv"
perfil_base | sed -n '11p'   >> "$T/p14-limpio.tsv"
bash "$S/lib-perfil.sh" --check "$T/p14-nul.tsv" >/dev/null 2>&1
assert_rc "[r14-1] un perfil con un byte NUL se rechaza fail-closed (rc 2), no se valida a ciegas" 2 $?
bash "$S/lib-perfil.sh" --check "$T/p14-limpio.tsv" >/dev/null 2>&1
assert_rc "[r14-2] (control positivo) el MISMO perfil sin el NUL es valido: el rc 2 lo trae el NUL" 0 $?

# [r14-3] `[[:cntrl:]]` NO significa lo mismo en cada localizacion, y eso decide QUE GUARDA contesta.
# Medido en este host con la nota `a \xc2\x9b 2J b`: bajo `LC_ALL=C` la clase no casa el C1 y decide
# la guarda especifica; bajo una localizacion UTF-8 la clase SI lo casa —cntrl incluye
# U+0080..U+009F— y decide la generica. Las dos rechazan, pero el operador lee un diagnostico
# distinto segun la localizacion de QUIEN LLAMA, y el bueno es el especifico: dice que el byte esta
# BIEN CODIFICADO, que es justo lo que despista. Con `local LC_ALL=C` el diagnostico ya no depende
# de la maquina. NOTA: el que cambia de significado es la CLASE, no el rango de bytes de la guarda
# C1 — ese casa igual en las cuatro localizaciones instaladas aqui, comprobado en las dos
# direcciones (`ñ` y el guion largo NO casan).
LOC14="$(locale -a 2>/dev/null | grep -i 'utf' | sed -n '1p')"
[ -n "$LOC14" ] || LOC14=C.utf8
sal14="$(LC_ALL="$LOC14" bash "$S/bus-sellar.sh" --rol CEO --marcador M14 \
  --nota "$(printf 'a\xc2\x9b2Jb')" 2>&1 >/dev/null)"; rc14=$?
esp14=no; case "$sal14" in *'control C1'*) esp14=si ;; esac
assert_eq "[r14-3] el diagnostico del C1 no depende de la localizacion del que llama" "2|si" \
  "$rc14|$esp14"

printf '== r15: el TOCTOU de la identidad del bus y el Quick Start que promete ejecucion ==\n'

# [r15-1] TOCTOU REPRODUCIDO, no plausible. La identidad `%d:%i` se medía ANTES de tomar el candado
# y el fichero se lee DESPUES; entre las dos cosas cabe una rotacion. La ventana no es teorica:
# `flock -w 10` puede esperar hasta diez segundos con un sellador dentro.
# EL ARNES CREA LA CARRERA A PROPOSITO Y DE FORMA DETERMINISTA, que es lo que lo separa de un caso
# que "confia" en pillar la ventana: se RETIENE el candado desde otro proceso, se lanza el lector
# —que mide la identidad y se queda esperando— y SE ROTA EL BUS MIENTRAS ESPERA. Cuando el candado
# se suelta, el lector de la version anterior seguia con la identidad vieja y emitia el tramo
# equivocado del fichero NUEVO con rc 0: exactamente el defecto que la marca existe para impedir,
# reabierto por la puerta de al lado.
R15="$T/r15"; mkdir -p "$R15/run"
busR15="$R15/bus"; lockR15="$R15/bus.lock"
printf 'AAAA\n' > "$busR15"; : > "$lockR15"
env_r15(){ XDG_RUNTIME_DIR="$R15/run" TA_BUS="$busR15" TA_BUS_LOCK="$lockR15" "$@"; }
env_r15 bash "$S/bus-leer.sh" --lector L15 >/dev/null 2>&1   # fija cursor Y marca de identidad
( flock -x 9; sleep 3 ) 9>"$lockR15" & holder15=$!
sleep 0.5
env_r15 bash "$S/bus-leer.sh" --lector L15 > "$R15/salida" 2>/dev/null & lector15=$!
sleep 1
printf 'BBBBBBBBBB\n' > "$R15/busB"; mv -f "$R15/busB" "$busR15"   # rotacion DENTRO de la ventana
wait $lector15; rc15=$?
wait $holder15 2>/dev/null
assert_eq "[r15-1] el bus rotado mientras el lector espera el candado -> rc 2 y NI UN BYTE emitido" \
  "2|0" "$rc15|$(wc -c < "$R15/salida" | tr -d ' ')"

# [r15-2] CASO DE CLASE sobre el Quick Start, y su censo es OBSERVABLE —no la forma del texto—:
# se ejecutan todos los comandos del bloque y se exige que el que hable sea EL SCRIPT, no el shell.
# El bloque promete cuatro lineas mas arriba que «cada uno de los cinco comandos de abajo esta
# ejecutado», y un token como `canal:<id>` convierte esa promesa en falsa sin tocar una letra del
# script: `<id>` es REDIRECCION, bash muere con «bash: line 1: id: No such file or directory» y el
# comando NO LLEGA A CORRER. Medido: con el token roto, rc 1 del shell; con el arreglado, rc 2 del
# script, que es el fail-closed documentado sin perfil ni bus.
# La cota de CINCO ata el censo a lo que promete la prosa: si el bloque crece, las dos cosas se
# mueven juntas o esto enrojece.
qs_malos=''; qs_n=0
while IFS= read -r _l15; do
  [ -n "$_l15" ] || continue
  qs_n=$((qs_n + 1))
  _e15="$(bash -c "S=\"$ROOT/scripts\"; $_l15" 2>&1 >/dev/null)"
  case "$_e15" in 'bash: '*) qs_malos="$qs_malos [$_l15]" ;; esac
done <<EOF15
$(grep -E '^(TA_BUS=[^ ]+ )?bash \$S/' "$ROOT/SKILL.md")
EOF15
assert_eq "[r15-2] los CINCO comandos del Quick Start los ejecuta el script, no muere el shell antes" \
  "5|" "$qs_n|$qs_malos"

printf '== r16: el doctor de instancia y la re-acreditacion (TAL-8043) ==\n'
# [r16-1] Su suite propia (supervision) lleva su autoconteo; aqui se encadena como UN caso: si enrojece,
# o si su contador no cuadra, esta suite lo dice. La salida completa queda en su fichero temporal.
bash "$HERE/test-supervision.sh" > "$T/supervision.log" 2>&1; rc16=$?
tail -n 3 "$T/supervision.log" | sed 's/^/    | /'
assert_rc "[r16-1] test-supervision.sh: 0 FAIL y su autoconteo cuadra" 0 "$rc16"

printf '== leer-auditor: resolución del lanzador y fallo cerrado ==\n'
for regression in alias_claude alias_codex missing_both absolute launcher_file builtin_derived function_derived builtin_declared function_declared; do
  python3 "$ROOT/../talent-channel-operation/tests/launcher-identity-regressions.py" "$regression" reader
  assert_rc "leer-auditor: $regression" 0 "$?"
done

python3 "$HERE/test-acreditacion-propietarios.py"
assert_rc 'lector con propietarios y permisos reales' 0 "$?"

printf '\n== %d ok, %d FAIL, %d SKIP (esperados: %d casos) ==\n' "$PASS" "$FAIL" "$SKIP" "$TOTAL_ESPERADO"
rc=0
[ "$FAIL" -eq 0 ] || { echo "FAIL: hubo casos rojos"; rc=1; }
[ $((PASS + FAIL + SKIP)) -eq "$TOTAL_ESPERADO" ] || {
  echo "FAIL: casos contabilizados $((PASS + FAIL + SKIP)) != TOTAL_ESPERADO $TOTAL_ESPERADO (¿desaparecio un caso?)"; rc=1; }
exit "$rc"
