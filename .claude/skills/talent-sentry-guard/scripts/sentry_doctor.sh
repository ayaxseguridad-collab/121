#!/usr/bin/env bash
# scripts/sentry_doctor.sh — sonda fail-closed del Vigía (TAL-5157).
#
# "No hay datos"/"0 resultados"/timeout/conexión rechazada NUNCA se
# interpretan como calma — son FALLOS de la sonda. Solo una respuesta con
# el código HTTP y el body EXACTOS del contrato de cada fuente cuenta como
# sana — un 200 (o 201) genérico con JSON válido NO basta: tiene que ser el
# recurso/organización/proyecto ESPERADO, o el doctor no puede distinguir
# "cero incidentes" de "estoy mirando la fuente equivocada", que es
# precisamente la razón de ser de esta sonda. exit 0 exige TODAS las
# categorías en verde, nunca "no hubo error visible".
#
# ═══════════════════════════════════════════════════════════════════════
# GARANTÍA Y SU LÍMITE (Codex ronda 6, adjudicación CEO — la vara final):
# el objetivo NO es "que no exista un punto de inyección" (lo perseguimos
# seis rondas y cada vez reaparecía con otro nombre: URL → seam de origen →
# cliente HTTP). El objetivo es:
#
#   QUE UNA CORRIDA FABRICADA NO PUEDA PRODUCIR JAMÁS UN VERDE QUE PAREZCA
#   REAL.
#
# Mecanismo: `main` —el ÚNICO que emite `✓ PUERTA ABIERTA`— ABORTA de forma
# INCONDICIONAL (exit 3, código propio, distinto de 0/1/2) en cuanto detecta
# CUALQUIER variable de seam en el entorno (ver seams_presentes()). El verde
# es inalcanzable bajo cualquier inyección, por construcción, y una corrida
# contaminada tampoco puede pasar por un rojo legítimo (exit 1) — tiene su
# propio código y su propio mensaje.
#
# Endurecimiento adicional (ronda 7, acotado A LA BAJA en ronda 8; extendido
# a OCHO ejecutables en la re-auditoría del bounce #2165 ronda 3 — ver nota
# de `timeout`/`head` más abajo) — describe EXACTAMENTE lo que hace, no lo
# que gustaría: además del abort por seams, el script hace UNA cosa concreta
# para EXACTAMENTE OCHO ejecutables externos — curl, railway, python3, stat,
# date, grep, timeout, head (los únicos comandos NO-builtin que invoca):
# (a) `unset -f` de esos ocho nombres, para que una FUNCIÓN exportada con
# uno de esos nombres no los sustituya; (b) resuelve cada uno UNA vez a su
# ruta absoluta al arrancar y los invoca por esa ruta ("$_CURL" …), de modo
# que ni una función ni un PATH alterado A MITAD de corrida los desvíen; y
# (c) `unset BASH_ENV`, que solo impide que un bash HIJO vuelva a cargar
# BASH_ENV — DEFENSA EN PROFUNDIDAD, porque el doctor no lanza bash hijo en
# producción (railway es binario, no bash).
# Los TRES mecanismos —(a), (b) y (c)— tienen cada uno su NEGATIVO CON MUTANTE
# INDEPENDIENTE en el harness (bloque "1b" de
# scripts/test-sentry-doctor-fail-propagation.sh): borrar (a) `unset -f` pone
# rojos los casos de función exportada y de función cargada por BASH_ENV;
# desnudar (b) la resolución absoluta pone rojo el de PATH-a-mitad; borrar
# SOLO (c) `unset BASH_ENV` pone rojo el de herencia por bash hijo. Ningún
# mecanismo afirma más de lo que su mutante mide.
#
# LO QUE ESTE ENDURECIMIENTO NO HACE — declarado, no afirmado de más:
#   - NO endurece BUILTINS (printf, echo, [, exit, …). No se les puede
#     anteponer PATH y `unset -f printf` no impediría que un builtin se use;
#     un entorno que SHADOWE un builtin con una función cae bajo "controla el
#     entorno de ejecución" (ver LÍMITE). Perseguir cada builtin es alcance
#     infinito; la afirmación se acota a los ocho externos y punto.
#   - `unset BASH_ENV` LLEGA TARDE: Bash procesa BASH_ENV y ejecuta ese
#     fichero ANTES de la primera línea de este script. El `unset` impide
#     efectos en procesos hijo posteriores, pero NO revierte aliases, `shopt`,
#     `set -o` ni nada que ese fichero YA aplicó. La ÚNICA parte del vector
#     BASH_ENV que se neutraliza es una función con el nombre de uno de los
#     ocho (vía el `unset -f`); el resto queda bajo el LÍMITE.
#
# LÍMITE, declarado explícito por honestidad — CORREGIDO en la ronda 7 porque
# la redacción anterior ("no cubre root malicioso") era FALSA: un límite
# estrecho y falso es justo la clase de "verde que parece real" que esta sonda
# existe para no producir. El límite VERDADERO es:
#
#   ESTA GARANTÍA NO CUBRE A QUIEN CONTROLA EL ENTORNO DE EJECUCIÓN DEL
#   PROCESO. Ningún script puede defenderse de quien puede reescribir el
#   script, ni de quien controla el entorno con el que se ejecuta.
#
# Eso incluye, sin necesidad de root: anteponer un directorio ESCRIBIBLE en
# PATH (un `curl`/`python3` falso que el propio invocador controla — no hace
# falta ser root para prepender a tu PATH), editar este mismo fichero, fijar
# el PATH ya envenenado antes de arrancar (la resolución a ruta absoluta
# congela lo que el PATH resuelva AL ARRANCAR, no lo saca de un PATH hostil),
# shadowear un builtin con una función, o aplicar aliases/opciones vía
# BASH_ENV antes de que el script corra. La garantía SÍ cubre lo que de verdad
# muerde: el drift accidental de variables `SENTRY_DOCTOR_*` heredadas, la
# sustitución del transporte por función exportada o PATH-a-mitad (los tres
# vectores probados), y la fabricación descuidada que acabaría pegada en un
# HANDOFF como aceptación real — un `[]` que no solo no avisa, sino que
# ACTIVAMENTE tranquiliza.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

# ── Endurecimiento del entorno de ejecución (Codex ronda 7/8, bloqueante 1b;
# extendido de seis a OCHO ejecutables en la re-auditoría del bounce #2165
# ronda 3 — BLOQUEANTE: `timeout` y `head` se habían incorporado FUERA de
# este esquema al aplicar dos findings del CR-CLI, contradiciendo y eludiendo
# el propio endurecimiento — un mutante conductual probó Railway "sano" con
# un CLI inexistente vía `timeout()` exportada, y un header con `Host:`
# aceptado vía `head()` exportada, ambos retornando 0. La regla que deja
# esto: cuando se aplica una sugerencia externa sobre código YA endurecido,
# el mutante no es solo del caso nuevo — es también del caso que ya estaba
# protegido) ──
# Actúa sobre EXACTAMENTE los ocho ejecutables externos que el script invoca —
# curl, railway, python3, stat, date, grep, timeout, head (los del `unset -f`
# de abajo). Los TRES mecanismos de abajo tienen NEGATIVO CON MUTANTE
# INDEPENDIENTE en el harness (bloque "1b"): borrar `unset -f` → rojos
# función-exportada y BASH_ENV-función; desnudar la resolución absoluta →
# rojo PATH-a-mitad; borrar solo `unset BASH_ENV` → rojo herencia-por-bash-hijo.
#   (b) FUNCIÓN exportada con uno de esos ocho nombres → se elimina con
#       `unset -f` ANTES de resolver, para que `command -v` devuelva el
#       EJECUTABLE y no una función residual.
#   (c) tras (b), cada uno se resuelve UNA vez a su ruta absoluta al arrancar
#       y se invoca por esa ruta ("$_CURL" …), de modo que ni una función ni
#       un PATH alterado A MITAD de corrida lo desvían.
#   (a) BASH_ENV: `unset BASH_ENV` solo impide su propagación a procesos hijo.
#       LLEGA TARDE — Bash ya ejecutó ese fichero antes de la primera línea de
#       este script. La ÚNICA parte del vector BASH_ENV que se neutraliza es
#       una función con uno de los ocho nombres (vía el `unset -f` de (b)); los
#       aliases/`shopt`/`set -o` que ese fichero ya aplicó NO se revierten.
# LÍMITE (ver cabecera): NO se endurecen los BUILTINS (printf/echo/[/exit…), NO
# se cierra un PATH YA envenenado al arrancar (`command -v` resuelve contra el
# PATH vigente), ni los efectos no-función de BASH_ENV. Todo eso es "controlar
# el entorno de ejecución del proceso" — fuera del alcance de un bash, y
# anteponer un directorio escribible en PATH no necesita root; por eso el
# límite honesto no habla de "root" sino de quien controla ese entorno.
unset BASH_ENV
unset -f curl railway python3 stat date grep timeout head 2>/dev/null || true
_CURL="$(command -v curl || echo curl)"
_RAILWAY="$(command -v railway || echo railway)"
_PYTHON3="$(command -v python3 || echo python3)"
_STAT="$(command -v stat || echo stat)"
_DATE="$(command -v date || echo date)"
_GREP="$(command -v grep || echo grep)"
_TIMEOUT="$(command -v timeout || echo timeout)"
_HEAD="$(command -v head || echo head)"

FALLOS=()
falla() { FALLOS+=("$1"); }

# SONDAS_EJECUTADAS + llamar_sonda — MAYOR del veredicto r4 del bounce #2165:
# check_fuentes()/check_runtime() llamaban a cada check_* directo; retirar
# SOLO la invocación de una (dejando la función definida e intacta) dejaba
# el arnés VERDE — 7 mutantes independientes, las 7 con remove_rc=0. El
# doctor podía omitir una fuente ENTERA —y su fallo de productor— y seguir
# anunciando "TODAS las categorías detectadas". `llamar_sonda` registra el
# nombre en SONDAS_EJECUTADAS ANTES de invocar — si la llamada se retira, el
# registro NUNCA ocurre, y el manifiesto de main() (declarado aparte, ver
# abajo) lo detecta.
SONDAS_EJECUTADAS=()
llamar_sonda() {
  SONDAS_EJECUTADAS+=("$1")
  "$@"
}

# CONFIG_PERMITIDA — línea brillante del contrato de producción: `main` corre
# con paths por defecto + clientes reales + SOLO estos cinco valores de
# config obligatoria por tenant (más LINEAR_API_KEY, que no lleva prefijo
# SENTRY_DOCTOR_). CUALQUIER otra variable `SENTRY_DOCTOR_*` presente es un
# override de test (cliente, header-file, path de runtime, umbral) — es
# decir, un SEAM — y su sola presencia significa entorno-no-limpio.
# Enumerar la config PERMITIDA (whitelist) en vez de los seams (blacklist)
# es deliberado: un seam nuevo que se añada en el futuro queda cazado por
# construcción sin tener que acordarse de listarlo.
CONFIG_PERMITIDA=(
  SENTRY_DOCTOR_SENTRY_ORG
  SENTRY_DOCTOR_SENTRY_PROJECT
  SENTRY_DOCTOR_BETTERSTACK_MONITOR_ID
  SENTRY_DOCTOR_SUPABASE_PROJECT_REF
  SENTRY_DOCTOR_RAILWAY_EXPECTED
  # Rutas de header-file: hallazgo CRITICAL del texto CR-CLI (corrida 2),
  # medido y confirmado real contra references/06-gotchas.md#14 ("El
  # validador externo usa overrides de header-file, NUNCA crea el runtime
  # ajeno" — apuntar SENTRY_DOCTOR_*_HDR al scratchpad propio es el patrón
  # DOCUMENTADO, no un seam de test). Sin esta entrada, seams_presentes()
  # marcaba como "entorno contaminado" a cualquier validador externo
  # siguiendo su propio contrato — contradicción real entre el gotcha y el
  # whitelist. NO son seam de transporte (no eligen origen ni cliente
  # HTTP): el contenido se valida en header_file_valido(), los permisos en
  # cada check_*.
  SENTRY_DOCTOR_SENTRY_HDR
  SENTRY_DOCTOR_BETTERSTACK_HDR
  SENTRY_DOCTOR_SUPABASE_HDR
  # T07 v4 (revisor #2165, hallazgo [3]): check_linear() adoptó el MISMO
  # patrón de header-file persistente que los tres de arriba — misma razón
  # exacta, override de ruta DOCUMENTADO, no un seam.
  SENTRY_DOCTOR_LINEAR_HDR
  # Sexta fuente (GitHub, alertas de seguridad). Misma razón exacta que los
  # cuatro de arriba: repo = config obligatoria por tenant, HDR = override de ruta de
  # header-file DOCUMENTADO; ninguno elige origen ni cliente HTTP.
  SENTRY_DOCTOR_GITHUB_REPO
  SENTRY_DOCTOR_GITHUB_HDR
)

# seams_presentes — imprime (una por línea) toda variable SENTRY_DOCTOR_*
# presente en el entorno que NO sea config permitida. `${!SENTRY_DOCTOR_@}`
# lista los nombres de variables SET con ese prefijo (incluidas las
# heredadas del entorno, que en un proceso nuevo son variables de shell, e
# incluidas las fijadas a vacío — fail-closed: presente es presente). Vacío
# ⇒ entorno limpio.
seams_presentes() {
  local v c permitida
  for v in ${!SENTRY_DOCTOR_@}; do
    permitida=0
    for c in "${CONFIG_PERMITIDA[@]}"; do
      [ "$v" = "$c" ] && { permitida=1; break; }
    done
    [ "$permitida" -eq 0 ] && printf '%s\n' "$v"
  done
}

# requerido — invariantes tenant-ready 25b/25c/25e del repo: CERO
# marca/dominio/identificador de tenant literal en el código. Todo valor
# que identifique AL TENANT (org de Sentry, proyecto de Sentry, nombre de
# proyecto de Railway, ref de proyecto de Supabase, ID de monitor de Better
# Stack) es config OBLIGATORIA por entorno — nunca un default incrustado.
# Hallazgo real (TAL-5157, check en vivo del CEO): el default
# "Academia Ejemplo" para Railway estaba MAL (el proyecto real es
# "Academia Ejemplo 2.0") y nadie lo habría visto si el doctor lo hubiera
# aceptado en silencio — la corrección NO es arreglar el valor, es no tener
# ninguno: un tenant nuevo es datos+provisioning, nunca código (test mental
# 25e: "¿funcionaría tal cual para un tenant que no soy yo?" — con un
# default de marca, la respuesta es no).
#
# NO se puede invocar como `x="$(requerido ...)"`: command substitution
# corre en una subshell, y un `falla()` disparado ahí dentro modificaría la
# copia de FALLOS de esa subshell, no la del padre — el fallo real
# quedaría registrado y perdido en el mismo aliento. Por eso esta función
# NO llama a falla(): solo devuelve 0/1 por exit code, y el CALLER (en su
# propio contexto de shell, sin subshell de por medio) es quien llama a
# falla() si hace falta.
#   $1 = nombre de la variable de entorno a exigir (no su valor)
requerido() {
  local varname="$1"
  [ -n "${!varname:-}" ]
}

# ═══════════════════════════════════════════════════════════════════════
# CAMINO A, corregido en ronda 5 de re-auditoría 5157 — LA CLASE MUERTA DE
# VERDAD, no un seam que la reagrupa.
#
# Rondas 1-4 persiguieron la misma familia de bug bajo formas sucesivas:
# marca hardcodeada -> ref ausente -> ref sin atar -> atada por subcadena
# -> ruta exacta pero host libre -> UN SEAM ÚNICO que sustituía origen sin
# restricciones (SENTRY_DOCTOR_UNSAFE_TEST_ORIGIN, ronda 4: "eliminaste
# seis puertas y dejaste una que las abre todas a la vez"). El nombre
# UNSAFE no era un control técnico — cualquier variable heredada por el
# shell lo activaba, sin flag, sin confirmación, sin aviso en la salida.
#
# La pregunta correcta (Codex, ronda 5): ¿el seam necesita existir? NO. La
# URL efectiva de cada fuente (esquema + host + puerto + ruta) es AHORA un
# literal Bash inline en cada check_* — ni una variable de entorno, ni una
# función indirecta, la tocan JAMÁS. No hay NINGÚN camino de código donde
# algo que no sea el propio texto fuente determine a qué origen se
# conecta.
#
# Lo único inyectable es el CLIENTE HTTP que hace la llamada —
# SENTRY_DOCTOR_HTTP_CLIENT, default "curl" — exactamente el mismo patrón
# que check_railway ya usaba para su CLI (SENTRY_DOCTOR_RAILWAY_CLI) sin
# que Codex lo señalara como bypass en NINGUNA de las 5 rondas. La
# asimetría es real, no cosmética: sustituir qué BINARIO se ejecuta exige
# tener ese binario en disco y en el PATH o pasado por ruta absoluta —ya
# controlas la máquina si puedes hacer eso—, mientras que sustituir una
# URL solo exigía heredar una variable de texto, sin tocar el filesystem,
# el vector de "drift accidental" real que motivó las 4 rondas anteriores.
# Un test doble (fake-curl) que intercepta la llamada NUNCA decide a qué
# conectarse el binario REAL en producción — decide qué canned response
# devolver él mismo, sin abrir ningún socket. Ver
# scripts/test-sentry-doctor-fail-propagation.sh para el test double.
#
# Bloqueante adicional cerrado en esta misma ronda (Codex #3): "no está
# demostrado que origen literal implique destino efectivo inalterable
# bajo el entorno real del proceso" — curl puede obedecer ~/.curlrc y
# HTTPS_PROXY/ALL_PROXY heredadas, y un header-file solo se validaba por
# permisos, no por contenido (podría llevar un Host: adicional). Los TRES
# se cierran en curl_seguro()/header_file_valido() de abajo: -q ignora
# cualquier ~/.curlrc (debe ir primero, así lo exige curl), --noproxy '*'
# ignora HTTPS_PROXY/ALL_PROXY/no_proxy del entorno, y el header-file se
# valida como EXACTAMENTE una línea "Authorization: <valor>", nada más.
# ═══════════════════════════════════════════════════════════════════════

# curl_seguro — invoca $SENTRY_DOCTOR_HTTP_CLIENT (default curl) con los
# flags que lo aíslan de configuración implícita del entorno. -q debe ser
# el PRIMER argumento (así lo exige curl para desactivar la lectura de
# ~/.curlrc); --noproxy '*' ignora HTTPS_PROXY/ALL_PROXY/no_proxy
# heredadas. El resto de argumentos se reenvían tal cual.
curl_seguro() {
  local cliente="${SENTRY_DOCTOR_HTTP_CLIENT:-$_CURL}"
  "$cliente" -q -s --max-time 5 --noproxy '*' "$@"
}

# header_file_valido — el header-file usado en `-H @fichero` solo se
# validaba antes por existencia y permisos (600); un contenido con líneas
# adicionales (p.ej. un Host: que alterase el vhost de destino tras un
# proxy/CDN mal configurado) pasaba sin detectarse. Ahora se exige
# EXACTAMENTE una línea no vacía, con forma "Authorization: <valor>" — ni
# más líneas, ni otra cabecera.
header_file_valido() {
  # Hallazgo del texto CR-CLI (corrida 3), medido y REPRODUCIDO en vivo con
  # un header-file vacío: `grep -c .` sobre un fichero vacío imprime "0" Y
  # sale con exit≠0 (grep: sin matches = exit 1) — el `|| echo 0` se dispara
  # IGUAL, y la sustitución de comando concatena AMBAS salidas ("0\n0"),
  # dejando `nlineas` como un string de DOS líneas. `[ "$nlineas" -eq 1 ]`
  # revienta con "integer expression expected" (verificado: `bash: line 15:
  # [: 0\n0: integer expression expected`). El resultado FUNCIONAL ya
  # fail-closed por accidente (rc≠0 de `[` sigue siendo "no válido" para el
  # `&&`), pero por un motivo aritmético no por diseño — la misma familia
  # que el gotcha ya censado de los fallbacks stat/date. `head -1` fuerza
  # una sola línea sin importar cuántas veces se dispare el `|| echo 0`.
  #
  # BLOQUEANTE r3 del bounce #2165, CORREGIDO: la primera versión de este fix
  # usaba `head` BARE, fuera del `unset -f`/resolución-absoluta — un `head`
  # exportado como función (`head(){ echo 1; }`) hacía que un header-file de
  # DOS líneas (`Authorization:` + `Host:` inyectado) contara como "1 línea
  # válida" y pasara, saltándose exactamente el guard que esta función existe
  # para hacer cumplir. `head` ahora es uno de los OCHO nombres sellados
  # (`unset -f` + `$_HEAD` resuelto al arrancar, arriba de este fichero).
  local hdr="$1" nlineas
  nlineas="$("$_GREP" -c . "$hdr" 2>/dev/null | "$_HEAD" -1)"
  [[ "$nlineas" =~ ^[0-9]+$ ]] || return 1
  [ "$nlineas" -eq 1 ] && "$_GREP" -qE '^Authorization: \S' "$hdr" 2>/dev/null
}

# check_http_source — verifica una fuente HTTP genérica vía GET + 200
# (Sentry y Better Stack la usan; Supabase NO — su endpoint exige POST con
# body y responde 201, tiene su propia función `check_supabase` más abajo).
# $url es SIEMPRE un literal construido por el caller a partir de un
# origen hardcodeado en el propio código + la identidad declarada — no
# existe ninguna variable de entorno que pueda desviarlo.
#   $1 = nombre lógico (para el mensaje)
#   $2 = URL a consultar (GET)
#   $3 = ruta al header-file (formato: `Authorization: <esquema> <token>`)
#   $4 = field_path: recorrido "campo.subcampo" dentro del JSON de
#        respuesta a comparar contra $5 (p.ej. "slug", "data.id"); STRING
#        VACÍO = modo "shape lista" (solo exige isinstance(d, list), sin
#        comparar valor — lo usa sentry-issues).
#   $5 = valor esperado para $4 (ignorado si $4 está vacío).
# $4/$5 viajan como ARGV del subproceso Python, nunca interpolados dentro
# del código fuente — un valor con comillas/operadores no puede alterar la
# expresión evaluada ni ejecutar código.
check_http_source() {
  local name="$1" url="$2" hdr="$3" field_path="$4" expected="${5:-}"
  local raw status body

  if [ ! -f "$hdr" ]; then
    falla "$name: header-file ausente ($hdr)"
    return 1
  fi
  local perms
  perms="$("$_STAT" -c %a "$hdr" 2>/dev/null || "$_STAT" -f %Lp "$hdr" 2>/dev/null)"
  if [ "$perms" != "600" ]; then
    falla "$name: header-file con permisos inseguros ($perms, se exige 600)"
    return 1
  fi
  if ! header_file_valido "$hdr"; then
    falla "$name: header-file con contenido inesperado (debe ser exactamente una línea 'Authorization: <valor>')"
    return 1
  fi

  if ! raw="$(curl_seguro -H @"$hdr" -w '\n%{http_code}' "$url" 2>/dev/null)"; then
    falla "$name: fuente inalcanzable (timeout/conexión rechazada) — NO se puede distinguir de 'sin incidentes', tratado como fallo"
    return 1
  fi
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  case "$status" in
    401) falla "$name: 401 credencial inválida"; return 1 ;;
    403) falla "$name: 403 credencial sin scope suficiente"; return 1 ;;
    404) falla "$name: recurso no encontrado (org/proyecto/monitor ausente)"; return 1 ;;
    200) ;;
    *)   falla "$name: HTTP inesperado ($status, se esperaba 200)"; return 1 ;;
  esac

  if [ -z "$body" ]; then
    falla "$name: respuesta vacía"
    return 1
  fi
  if ! printf '%s' "$body" | "$_PYTHON3" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    falla "$name: respuesta no es JSON válido (malformada/incompleta)"
    return 1
  fi
  if [ -n "$field_path" ]; then
    if ! printf '%s' "$body" | "$_PYTHON3" -c '
import json, sys
field_path, expected = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
for part in field_path.split("."):
    d = d.get(part) if isinstance(d, dict) else None
sys.exit(0 if str(d) == expected else 1)
' "$field_path" "$expected" >/dev/null 2>&1; then
      falla "$name: recurso presente pero no es el esperado (organización/proyecto/monitor incorrecto)"
      return 1
    fi
  else
    if ! printf '%s' "$body" | "$_PYTHON3" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, list) else 1)' >/dev/null 2>&1; then
      falla "$name: recurso presente pero no es una lista (shape inesperado)"
      return 1
    fi
  fi
  return 0
}

# check_sentry — TRES llamadas reales, ninguna con expect='True':
#   1) identidad de la ORGANIZACIÓN — GET /organizations/{slug}/, verificado
#      contra docs.sentry.io/api/organizations/retrieve-an-organization/:
#      devuelve {"slug": "...", ...}.
#   2) identidad del PROYECTO — GET /projects/{org}/{project}/, verificado
#      contra docs.sentry.io/api/projects/retrieve-a-project/: devuelve
#      {"slug": "...", ...} a nivel de PROYECTO (no de org — sin este paso,
#      "org correcta" no implica "proyecto correcto": la org puede tener
#      más de un proyecto).
#   3) issues, FILTRADOS POR PROYECTO — GET /projects/{org}/{project}/issues/
#      (verificado contra docs.sentry.io/api/events/list-a-projects-issues/,
#      endpoint project-scoped, no el org-wide genérico de antes), shape
#      SIEMPRE una lista JSON.
# Los tres deben acreditar identidad ANTES de mirar cuántos issues hay — así
# "0 issues" solo puede significar "sin incidentes", nunca "org/proyecto
# equivocado" ni "consulta sin acotar al proyecto".
#
# Las TRES URLs son literales "https://sentry.io" + ruta derivada de la
# identidad — sin ninguna variable de entorno de por medio.
check_sentry() {
  local hdr="${SENTRY_DOCTOR_SENTRY_HDR:-$HOME/.vigia-sentry/hdr}"
  if ! requerido SENTRY_DOCTOR_SENTRY_ORG; then
    falla "sentry-org: config ausente (SENTRY_DOCTOR_SENTRY_ORG obligatorio por tenant, sin valor por defecto)"
    return 1
  fi
  if ! requerido SENTRY_DOCTOR_SENTRY_PROJECT; then
    falla "sentry-project: config ausente (SENTRY_DOCTOR_SENTRY_PROJECT obligatorio por tenant, sin valor por defecto)"
    return 1
  fi
  local org="$SENTRY_DOCTOR_SENTRY_ORG" project="$SENTRY_DOCTOR_SENTRY_PROJECT"
  local org_url="https://sentry.io/api/0/organizations/${org}/"
  local project_url="https://sentry.io/api/0/projects/${org}/${project}/"
  local issues_url="https://sentry.io/api/0/projects/${org}/${project}/issues/?statsPeriod=24h"
  check_http_source "sentry-org" "$org_url" "$hdr" "slug" "$org" || return 1
  check_http_source "sentry-project" "$project_url" "$hdr" "slug" "$project" || return 1
  check_http_source "sentry-issues" "$issues_url" "$hdr" "" "" || return 1
  return 0
}

# check_betterstack — Better Stack sigue la especificación JSON:API
# (confirmado: "Our API follows the JSON:API specification", docs oficiales)
# — un GET de un recurso único responde {"data": {"id": "...", ...}}. La
# aserción real es que `data.id` sea EXACTAMENTE el monitor esperado, no
# solo que exista una clave "data" (eso aceptaría cualquier recurso
# JSON:API, incluido el monitor equivocado). URL literal
# "https://uptime.betterstack.com" + el monitor_id declarado.
check_betterstack() {
  local hdr="${SENTRY_DOCTOR_BETTERSTACK_HDR:-$HOME/.vigia-betterstack/hdr}"
  if ! requerido SENTRY_DOCTOR_BETTERSTACK_MONITOR_ID; then
    falla "betterstack: config ausente (SENTRY_DOCTOR_BETTERSTACK_MONITOR_ID obligatorio por tenant, sin valor por defecto)"
    return 1
  fi
  local monitor_id="$SENTRY_DOCTOR_BETTERSTACK_MONITOR_ID"
  local url="https://uptime.betterstack.com/api/v2/monitors/${monitor_id}"
  check_http_source betterstack "$url" "$hdr" "data.id" "$monitor_id"
}

# check_supabase — el endpoint database/query de la Management API NO es un
# GET genérico: exige POST con body {"query":...} + Content-Type: application/
# json, y responde 201 (no 200) en éxito (verificado contra
# supabase.com/docs/reference/api/v1-run-a-query). Por eso NO reusa
# check_http_source (que solo hace GET+200) — función propia. URL literal
# "https://api.supabase.com" + la ref declarada.
check_supabase() {
  local hdr="${SENTRY_DOCTOR_SUPABASE_HDR:-$HOME/.vigia-supabase/hdr}"
  if ! requerido SENTRY_DOCTOR_SUPABASE_PROJECT_REF; then
    falla "supabase: config ausente (SENTRY_DOCTOR_SUPABASE_PROJECT_REF obligatorio por tenant, sin valor por defecto)"
    return 1
  fi
  local ref="$SENTRY_DOCTOR_SUPABASE_PROJECT_REF"
  # Formato ESTRICTO de la ref (Codex ronda 7, bloqueante 2). La ref es un
  # segmento de path dentro del host fijo api.supabase.com, y `select 1 as
  # ok` NO acredita identidad (a diferencia de Sentry/Better Stack, cuyo
  # body declara el slug/id esperado y desmiente una identidad falsa). Sin
  # validar el formato, un valor como `ref-esperada/../otra-ref` altera la
  # RUTA efectiva dentro del host fijo y una respuesta válida de OTRO
  # proyecto daría verde para la ref declarada. Las refs de Supabase son 20
  # caracteres [a-z0-9]; la regex rechaza `/`, `.`, `-`, mayúsculas y
  # cualquier longitud distinta — cierra el traversal de plano.
  # (Las otras identidades no necesitan esto: org/proyecto de Sentry y
  # monitor de Better Stack SÍ se acreditan contra el body de la respuesta,
  # que llevaría la identidad real del recurso resuelto y no coincidiría con
  # la declarada tras un traversal → fallo. Supabase es la única fuente sin
  # esa acreditación descendente.)
  if ! [[ "$ref" =~ ^[a-z0-9]{20}$ ]]; then
    falla "supabase: SENTRY_DOCTOR_SUPABASE_PROJECT_REF con formato inválido (se exige 20 caracteres [a-z0-9]; recibido: '${ref}')"
    return 1
  fi
  local url="https://api.supabase.com/v1/projects/${ref}/database/query"
  local raw status body

  if [ ! -f "$hdr" ]; then
    falla "supabase: header-file ausente ($hdr)"
    return 1
  fi
  local perms
  perms="$("$_STAT" -c %a "$hdr" 2>/dev/null || "$_STAT" -f %Lp "$hdr" 2>/dev/null)"
  if [ "$perms" != "600" ]; then
    falla "supabase: header-file con permisos inseguros ($perms, se exige 600)"
    return 1
  fi
  if ! header_file_valido "$hdr"; then
    falla "supabase: header-file con contenido inesperado (debe ser exactamente una línea 'Authorization: <valor>')"
    return 1
  fi

  # User-Agent explícito (gotcha #6 del brief): sin él, Cloudflare responde
  # `error code: 1010` que parece Postgres y no lo es.
  if ! raw="$(curl_seguro -H @"$hdr" -H 'Content-Type: application/json' \
        -H 'User-Agent: talent-sentry-guard-doctor/1' -X POST \
        --data '{"query":"select 1 as ok","read_only":true}' \
        -w '\n%{http_code}' "$url" 2>/dev/null)"; then
    falla "supabase: fuente inalcanzable (timeout/conexión rechazada)"
    return 1
  fi
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"

  case "$status" in
    401) falla "supabase: 401 credencial inválida"; return 1 ;;
    403) falla "supabase: 403 credencial sin scope suficiente"; return 1 ;;
    404) falla "supabase: proyecto no encontrado"; return 1 ;;
    201) ;;
    *)   falla "supabase: HTTP inesperado ($status, se esperaba 201)"; return 1 ;;
  esac

  if [ -z "$body" ]; then
    falla "supabase: respuesta vacía"
    return 1
  fi
  if ! printf '%s' "$body" | "$_PYTHON3" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    falla "supabase: respuesta no es JSON válido (malformada/incompleta)"
    return 1
  fi
  # Shape esperado de un SELECT: lista de filas no vacía, cada fila un
  # objeto — CONFIRMADO CONTRA PRODUCCIÓN REAL (validación en vivo de C3,
  # TAL-5157): `select 1 as ok` devolvió HTTP 201 con body `[{"ok":1}]`.
  if ! printf '%s' "$body" | "$_PYTHON3" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d and isinstance(d, list) and isinstance(d[0], dict)) else 1)' >/dev/null 2>&1; then
    falla "supabase: respuesta no es una lista no vacía de filas-objeto (shape inesperado para un SELECT)"
    return 1
  fi
  return 0
}

# check_railway — NUNCA llama la API GraphQL cruda (gotcha sellado: HTTP 200
# con el error dentro del body, verificado en vivo TAL-5157). Siempre el
# CLI, y siempre valida (a) exit code Y (b) que el stdout parsea como JSON
# antes de confiar en él (el CLI emite texto plano, no JSON, cuando falla).
# $SENTRY_DOCTOR_RAILWAY_CLI permite inyectar un binario `railway` falso
# desde el test harness — el patrón que se extendió a las demás fuentes
# vía SENTRY_DOCTOR_HTTP_CLIENT en esta ronda. No tiene URL en absoluto: la
# identidad (.name) se lee de LA MISMA invocación que genera la respuesta.
check_railway() {
  local cli="${SENTRY_DOCTOR_RAILWAY_CLI:-$_RAILWAY}"
  # SIN DEFAULT — hallazgo real del check en vivo del CEO (TAL-5157): el
  # valor "Academia Ejemplo" que llevaba este default ERA INCORRECTO (el
  # proyecto real se llama "Academia Ejemplo 2.0"), y el doctor lo habría
  # aceptado en silencio si hubiera acertado por casualidad. La corrección
  # no es arreglar el string — es no tener ninguno (invariante 25b/c/e).
  if ! requerido SENTRY_DOCTOR_RAILWAY_EXPECTED; then
    falla "railway: config ausente (SENTRY_DOCTOR_RAILWAY_EXPECTED obligatorio por tenant, sin valor por defecto)"
    return 1
  fi
  local expected="$SENTRY_DOCTOR_RAILWAY_EXPECTED"
  # `railway status` NO tiene flag --service (verificado en vivo: `railway
  # status --help`, CLI 5.29.0 — --service existe en otros subcomandos como
  # `variables`/`logs`/`redeploy`, no en `status`). `status` opera a nivel de
  # PROYECTO (--project/-p, "defaults to linked project"), no de servicio.
  # El proyecto se resuelve por la sesión CLI ya enlazada (railway link,
  # patrón del contrato de credenciales) — no se pasa --project a mano aquí.
  #
  # Hallazgo del texto CR-CLI (corrida 1), medido y confirmado real: la
  # invocación no llevaba límite de tiempo — un CLI colgado (red, prompt de
  # auth interactivo, lo que sea) cuelga el doctor ENTERO indefinidamente.
  #
  # BLOQUEANTE r3 del bounce #2165, CORREGIDO: la primera versión de este fix
  # resolvía `timeout` con un `command -v` LOCAL a esta función, FUERA del
  # `unset -f`/resolución-absoluta de arriba — reabría exactamente la clase
  # de "ejecutable sustituible" que ese endurecimiento existe para cerrar
  # (mutante conductual probó Railway "sano" con un CLI inexistente, vía una
  # función `timeout()` exportada). `timeout` ahora es uno de los OCHO
  # nombres sellados (`unset -f` + `$_TIMEOUT` resuelto al arrancar, arriba).
  local out
  if ! out="$("$_TIMEOUT" 15 "$cli" status --json --environment production </dev/null 2>&1)"; then
    falla "railway: timeout o exit≠0 ($out)"
    return 1
  fi
  if ! printf '%s' "$out" | "$_PYTHON3" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    falla "railway: salida no es JSON válido pese a exit 0"
    return 1
  fi
  # Identidad de proyecto — CAMPO CANÓNICO verificado contra el código
  # fuente REAL del CLI (railwayapp/cli, src/commands/status.rs: la salida
  # --json es `serde_json::to_value(project)` del tipo generado por el
  # query GraphQL `src/gql/queries/strings/Project.graphql`, que declara
  # `id`/`name`/`workspaceId`/... a nivel raíz del objeto `project`). El
  # campo de identidad del proyecto es `.name`, NO una búsqueda de
  # substring en cualquier punto del JSON — un servicio o deployment con
  # ese texto en otro campo ya NO cuenta como coincidencia.
  # $expected viaja como ARGV, nunca interpolado en el código fuente.
  if ! printf '%s' "$out" | "$_PYTHON3" -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("name") == sys.argv[1] else 1)
' "$expected" >/dev/null 2>&1; then
    falla "railway: proyecto no coincide con el esperado (campo .name distinto de '$expected')"
    return 1
  fi
  return 0
}

# check_linear — sin esto, el doctor podía abrir la puerta aunque la Vigía
# fuera incapaz de buscar/crear/comentar issues (la mitad de su mandato).
# Ping mínimo real: viewer{id}, sin Bearer (gotcha ya sellado: la API key
# personal de Linear va SIN prefijo en Authorization). URL literal
# "https://api.linear.app/graphql".
#
# CRITICAL (T07 v3/v4, revisor #2165, hallazgo [3]): la versión original
# pasaba la clave como `-H "Authorization: $key"` — un argumento literal
# del proceso `curl`, visible en `ps -eo args`/`/proc/<pid>/cmdline` para
# CUALQUIER proceso de la máquina durante toda la vida del subproceso. No
# es "se filtra si alguien mira": está publicado desde que arranca.
#
# Fix DEFINITIVO (v4 — sustituye el header-file EFÍMERO de v3, que cerraba
# argv pero rompía la arquitectura del resto del fichero): mismo patrón
# EXACTO que check_sentry/check_betterstack/check_supabase — header-file
# PERSISTENTE, provisionado por el operador, `SENTRY_DOCTOR_LINEAR_HDR`
# (override) con default `$HOME/.vigia-linear/hdr`, validado con
# `header_file_valido()` igual que los otros tres. `SENTRY_DOCTOR_LINEAR_HDR`
# entra en `CONFIG_PERMITIDA` (ver el array arriba) por la MISMA razón que
# los otros tres `*_HDR`: es un override de ruta de header-file DOCUMENTADO,
# no un seam — sin esa entrada, `seams_presentes()` marcaría como
# "entorno contaminado" a un operador siguiendo el contrato de este mismo
# check. La fuente deja de ser `LINEAR_API_KEY` leído del entorno del
# proceso (otros scripts del skill, como `crear_issue_desde_sentry.py`,
# siguen leyendo esa env var directamente — llaman a `urllib` en proceso,
# nunca a un subproceso `curl`, así que ese vector de argv no les aplica).
check_linear() {
  local hdr="${SENTRY_DOCTOR_LINEAR_HDR:-$HOME/.vigia-linear/hdr}"
  local url="https://api.linear.app/graphql"
  if [ ! -f "$hdr" ]; then
    falla "linear: header-file ausente ($hdr)"
    return 1
  fi
  local perms
  perms="$("$_STAT" -c %a "$hdr" 2>/dev/null || "$_STAT" -f %Lp "$hdr" 2>/dev/null)"
  if [ "$perms" != "600" ]; then
    falla "linear: header-file con permisos inseguros ($perms, se exige 600)"
    return 1
  fi
  if ! header_file_valido "$hdr"; then
    falla "linear: header-file con contenido inesperado (debe ser exactamente una línea 'Authorization: <valor>')"
    return 1
  fi
  local raw status body
  if ! raw="$(curl_seguro -X POST \
        -H @"$hdr" -H 'Content-Type: application/json' \
        --data '{"query":"query{ viewer{id} }"}' \
        -w '\n%{http_code}' "$url" 2>/dev/null)"; then
    falla "linear: fuente inalcanzable (timeout/conexión rechazada)"
    return 1
  fi
  status="${raw##*$'\n'}"; body="${raw%$'\n'*}"
  if [ "$status" != "200" ]; then
    falla "linear: HTTP inesperado ($status, se esperaba 200)"
    return 1
  fi
  if ! printf '%s' "$body" | "$_PYTHON3" -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if isinstance(d.get('data',{}).get('viewer',{}).get('id'), str) else 1)
" >/dev/null 2>&1; then
    # MAJOR (T07 v3/v4, hallazgo [2]): la versión anterior interpolaba
    # `${body:0:120}` en el mensaje de falla — publicaba en el log/stderr
    # el cuerpo de la respuesta que el fix de argv acababa de proteger.
    # Cerrar una puerta y dejar la otra abierta no cierra nada: solo la
    # CLASIFICACIÓN del fallo, nunca el contenido de la respuesta.
    falla "linear: viewer.id ausente o credencial rechazada"
    return 1
  fi
  return 0
}

# check_github — sexta fuente, OPCIONAL: sin SENTRY_DOCTOR_GITHUB_REPO imprime «github: no vigilada» y
# sigue (rc 0); con la variable definida es fail-closed. El repo declarado existe y CADA superficie de seguridad
# declarada (GITHUB_SEC_SUPERFICIES; por defecto las cuatro) responde 200 con una LISTA. Reutiliza
# check_http_source (GET + 200 + JSON + identidad exacta + header-file 0600 de una línea), así que
# comparte sus garantías: URL de origen literal `https://api.github.com` + identidad declarada, sin
# override; cliente inyectable solo por SENTRY_DOCTOR_HTTP_CLIENT (seam que main rechaza con exit 3).
# La identidad del repo (full_name == SENTRY_DOCTOR_GITHUB_REPO) se acredita ANTES de las superficies:
# si falla (repo equivocado, header inválido, 401), no se sigue y cuenta UN fallo. Una superficie
# desactivada (403/404) o que no devuelve lista es un fallo propio, nunca «0 alertas». El header-file
# es de solo lectura (`security_events` / `repo` / `repository_advisories:read`, ver references/05).
check_github() {
  local hdr="${SENTRY_DOCTOR_GITHUB_HDR:-$HOME/.vigia-github/hdr}"
  # FUENTE OPCIONAL (decisión del CEO): una instancia con el Vigía ya montado no puede caer por una
  # actualización del paquete. Sin SENTRY_DOCTOR_GITHUB_REPO no se vigila GitHub y la ausencia se VE
  # (no es un fallo ni un verde mudo). Con la variable definida —aunque sea vacía— la config es
  # PARCIAL o completa y rige fail-closed: header-file 0600 de una línea + identidad + superficies.
  if [ -z "${SENTRY_DOCTOR_GITHUB_REPO+x}" ]; then
    printf 'github: no vigilada (SENTRY_DOCTOR_GITHUB_REPO no definida; fuente opcional)\n'
    return 0
  fi
  if ! requerido SENTRY_DOCTOR_GITHUB_REPO; then
    falla "github: config parcial (SENTRY_DOCTOR_GITHUB_REPO definida pero vacía)"
    return 1
  fi
  local repo="$SENTRY_DOCTOR_GITHUB_REPO"
  # Formato estricto owner/nombre: es un tramo de path dentro del host fijo (corta traversal).
  if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ "$repo" == *..* ]]; then
    falla "github: SENTRY_DOCTOR_GITHUB_REPO con formato inválido (se espera owner/nombre)"
    return 1
  fi
  local declaradas="${GITHUB_SEC_SUPERFICIES:-dependabot,code-scanning,secret-scanning,advisories}"
  local -a sups=()
  local s
  IFS=',' read -r -a sups <<< "$declaradas"
  if [ "${#sups[@]}" -eq 0 ]; then
    falla "github: GITHUB_SEC_SUPERFICIES vacía"
    return 1
  fi
  # Config parcial: con el repo declarado, el header-file DEBE existir, ser 0600 y de una línea
  # `Authorization: …`; si no, un fallo nombrado y sin tocar la red.
  if [ ! -f "$hdr" ]; then
    falla "github: config parcial (repo declarado): header-file ausente ($hdr)"
    return 1
  fi
  local perms
  perms="$("$_STAT" -c %a "$hdr" 2>/dev/null || "$_STAT" -f %Lp "$hdr" 2>/dev/null)"
  if [ "$perms" != "600" ]; then
    falla "github: config parcial (repo declarado): header-file con permisos inseguros ($perms, se exige 600)"
    return 1
  fi
  if ! header_file_valido "$hdr"; then
    falla "github: config parcial (repo declarado): header-file con contenido inesperado (debe ser exactamente una línea 'Authorization: <valor>')"
    return 1
  fi
  local base="https://api.github.com/repos/${repo}"
  check_http_source "github-repo" "$base" "$hdr" "full_name" "$repo" || return 1
  local rc=0 ruta
  for s in "${sups[@]}"; do
    case "$s" in
      dependabot)      ruta="dependabot/alerts?state=open&per_page=1" ;;
      code-scanning)   ruta="code-scanning/alerts?state=open&per_page=1" ;;
      secret-scanning) ruta="secret-scanning/alerts?state=open&per_page=1&hide_secret=true" ;;
      advisories)      ruta="security-advisories?per_page=1" ;;
      *) falla "github: superficie desconocida en GITHUB_SEC_SUPERFICIES ('${s}')"; rc=1; continue ;;
    esac
    check_http_source "github-${s}" "${base}/${ruta}" "$hdr" "" "" || rc=1
  done
  return "$rc"
}

# check_ciclo_operativo — sin esto, una sonda con las 5 fuentes accesibles
# pero el CICLO roto (sin cursor, sin bus, sin sellador) aprobaría igual,
# aunque la Vigía no pudiera completar un ciclo real. Verifica EXISTENCIA +
# permisos mínimos, no contenido (el contenido es responsabilidad de
# sentry_triage.py en cada ciclo, no del doctor de arranque).
check_ciclo_operativo() {
  local cursor="${SENTRY_DOCTOR_CURSOR:-$HOME/.vigia-sentry/cursor.json}"
  local bus="${SENTRY_DOCTOR_BUS:-/tmp/merge-claims.txt}"
  local sellar="${SENTRY_DOCTOR_SELLAR:-$HOME/sellar.sh}"
  local propios=0

  if [ ! -f "$cursor" ]; then
    falla "ciclo: cursor.json ausente ($cursor)"; propios=$((propios + 1))
  # $cursor viaja como ARGV, no interpolado en el código (misma higiene
  # que el resto de identidades: una ruta con comillas no debe poder
  # alterar la expresión evaluada).
  elif ! "$_PYTHON3" -c 'import json, sys; json.load(open(sys.argv[1]))' "$cursor" >/dev/null 2>&1; then
    falla "ciclo: cursor.json existe pero no parsea como JSON"; propios=$((propios + 1))
  fi

  if [ ! -f "$bus" ]; then
    falla "ciclo: bus ausente ($bus)"; propios=$((propios + 1))
  fi

  if [ ! -f "$sellar" ]; then
    falla "ciclo: sellar.sh ausente ($sellar)"; propios=$((propios + 1))
  elif [ ! -x "$sellar" ]; then
    falla "ciclo: sellar.sh existe pero no es ejecutable"; propios=$((propios + 1))
  fi

  [ "$propios" -eq 0 ]
}

# check_tick — el ticker debe haber latido dentro del umbral (segundos).
#   $1 = ruta al log del ticker   $2 = umbral en segundos
check_tick() {
  local log="$1" umbral="$2" mtime now
  if [ ! -f "$log" ]; then
    falla "ticker: log ausente ($log)"
    return 1
  fi
  mtime="$("$_STAT" -c %Y "$log" 2>/dev/null || "$_STAT" -f %m "$log" 2>/dev/null)"
  now="$("$_DATE" +%s)"
  if [ $(( now - mtime )) -gt "$umbral" ]; then
    falla "ticker: TICK stale ($(( (now - mtime) / 60 )) min sin latido, umbral $(( umbral / 60 )) min)"
    return 1
  fi
  return 0
}

# Dos ámbitos que el doctor NO debe mezclar (hallazgo real de la validación
# de C3, TAL-5157): checks de FUENTE (sentry/betterstack/supabase/railway/
# linear) acreditan credencial y superficie — los puede correr un TERCERO
# desde OTRA máquina (torre de C3, host del CEO), y de hecho es exactamente
# así como se validan en la práctica. Checks de RUNTIME/CICLO (ticker,
# cursor.json, bus, sellar.sh) solo tienen sentido en la máquina donde la
# Vigía corre de verdad — un validador externo que los incluyera daría
# rojo por un motivo FALSO (está midiendo su propia máquina, no la de la
# Vigía), que es exactamente el fallo que este doctor existe para no
# cometer. Por eso hay dos modos, nunca mezclados en la misma corrida:
#   --solo-fuentes  → sentry, betterstack, supabase, railway, linear, github
#   --completo      → --solo-fuentes + ticker + ciclo operativo (default)
# LÍMITE DECLARADO (veredicto r5 del bounce #2165, misma clase que MAYOR 1 de
# test-sentry-python-guards.py — elegido (b) "acotar y declarar" en vez de
# (a) "anclar fuera del artefacto"): el harness acredita que CADA SONDA DEL
# MANIFIESTO SE EJECUTA (ver los tests de check_fuentes+check_runtime y
# verificar_manifiesto_sondas en scripts/test-sentry-doctor-fail-propagation.sh).
# NO acredita que estos dos arrays no se reduzcan EN EL MISMO commit junto con
# la línea `llamar_sonda check_*` correspondiente — esa reducción es visible
# en el `git diff` de este fichero, la vigila la revisión del diff, no este
# harness. Perseguir un manifiesto que vigile a este manifiesto no termina
# nunca. Una afirmación acotada y verdadera vale más que una ancha y falsa.
SONDAS_MANIFEST_FUENTES=(check_sentry check_betterstack check_supabase check_railway check_linear check_github)
SONDAS_MANIFEST_RUNTIME=(check_tick check_ciclo_operativo)

check_fuentes() {
  llamar_sonda check_sentry
  llamar_sonda check_betterstack
  llamar_sonda check_supabase
  llamar_sonda check_railway
  llamar_sonda check_linear
  llamar_sonda check_github
}

check_runtime() {
  llamar_sonda check_tick "${SENTRY_DOCTOR_TICK_LOG:-$HOME/.vigia-sentry/tick.log}" "${SENTRY_DOCTOR_TICK_UMBRAL:-900}"
  llamar_sonda check_ciclo_operativo
}

# verificar_manifiesto_sondas — MAYOR del veredicto r4: lo que REALMENTE se
# ejecutó (SONDAS_EJECUTADAS, poblado por llamar_sonda) contra lo que el modo
# EXIGE (SONDAS_MANIFEST_FUENTES/_RUNTIME, declarados aparte de
# check_fuentes/check_runtime — dos listas textualmente distintas). Si una
# sonda del manifiesto nunca corrió, es un fallo REAL vía falla() — el
# doctor no puede anunciar "TODAS las categorías detectadas" sin haber
# corrido las que el modo promete. Función STANDALONE (no inline en main())
# para que el harness pueda ejercitarla directo, igual que cada check_*.
verificar_manifiesto_sondas() {
  local modo="$1"
  local manifest_modo=("${SONDAS_MANIFEST_FUENTES[@]}")
  [ "$modo" = "--completo" ] && manifest_modo+=("${SONDAS_MANIFEST_RUNTIME[@]}")
  local sonda_esperada sonda_ejecutada encontrada
  for sonda_esperada in "${manifest_modo[@]}"; do
    encontrada=0
    for sonda_ejecutada in "${SONDAS_EJECUTADAS[@]}"; do
      [ "$sonda_esperada" = "$sonda_ejecutada" ] && { encontrada=1; break; }
    done
    [ "$encontrada" -eq 0 ] && falla "manifiesto de sondas: '$sonda_esperada' nunca se ejecutó (cableado roto en check_fuentes/check_runtime, modo $modo)"
  done
}

main() {
  # ── ABORT INCONDICIONAL POR ENTORNO CONTAMINADO — LO PRIMERO DE TODO ──
  # (Codex ronda 7, bloqueante 1a): esta comprobación va ANTES de validar el
  # argumento de modo. Si fuera después, una corrida contaminada con un
  # argumento inválido saldría con 2 (uso) antes de llegar aquí, y "cualquier
  # seam presente → exit 3" dejaría de ser incondicional — una corrida
  # contaminada podría escaparse por la puerta del uso inválido. Ahora no:
  # si CUALQUIER variable de seam está presente, `main` NO emite veredicto y
  # sale con 3 pase lo que pase con el resto de argumentos. exit 3 es código
  # propio, distinto de 0 (abierta), 1 (cerrada/rojo real) y 2 (uso): una
  # corrida contaminada no puede pasar ni por verde ni por un rojo legítimo.
  # Va antes del banner, así que una corrida contaminada tampoco llega a
  # imprimir `MODO: produccion`.
  local seams; seams="$(seams_presentes)"
  if [ -n "$seams" ]; then
    printf '✗ ENTORNO CONTAMINADO: variable(s) de seam presente(s) en modo producción — NO se emite veredicto\n' >&2
    printf '  - %s\n' $seams >&2
    printf '  (un veredicto de producción exige entorno limpio: paths por defecto + clientes reales + solo la config obligatoria por tenant)\n' >&2
    exit 3
  fi

  local modo="${1:---completo}"
  case "$modo" in
    --solo-fuentes|--completo) ;;
    *)
      echo "Uso: $0 [--solo-fuentes|--completo]" >&2
      exit 2
      ;;
  esac

  # Banner de MODO — aseverado, no decorativo: como el único camino hasta
  # aquí es un entorno sin seams, `MODO: produccion` NO puede mentir (es
  # verdadero por el abort de arriba). Acompaña a TODO veredicto de main.
  case "$modo" in
    --solo-fuentes) check_fuentes ;;
    --completo)     check_fuentes; check_runtime ;;
  esac

  # LÍMITE DECLARADO (veredicto r5 del bounce #2165, MAYOR 2): el harness
  # prueba que `verificar_manifiesto_sondas` DETECTA una sonda faltante y que
  # `check_fuentes`/`check_runtime` REALMENTE pueblan SONDAS_EJECUTADAS — pero
  # nada vigila que ESTA LÍNEA (la invocación desde `main()`) siga presente.
  # El auditor lo probó: retirarla sin tocar nada más deja el harness verde y
  # "TODAS las categorías detectadas". Guardar la invocación de la invocación
  # es la misma recursión sin fin que MAYOR 1 — no se persigue. Retirar esta
  # línea es un cambio de UNA línea en `main()`, visible en cualquier `git
  # diff` de este fichero; esa visibilidad la vigila la revisión del diff,
  # no un guardián en tiempo de ejecución. Con esta línea presente (estado
  # actual, verificado), el manifiesto SÍ se aplica al doctor entregable.
  verificar_manifiesto_sondas "$modo"

  if [ "${#FALLOS[@]}" -gt 0 ]; then
    printf '✗ PUERTA CERRADA (%s) [MODO: produccion]: %d fallo(s)\n' "$modo" "${#FALLOS[@]}" >&2
    printf '  - %s\n' "${FALLOS[@]}" >&2
    exit 1
  fi
  printf '✓ PUERTA ABIERTA (%s) [MODO: produccion]\n' "$modo"
  exit 0
}

# main-guard: al sourcear (para tests) NO se ejecuta main(). Hallazgo del
# texto CR-CLI (corrida 3), medido y REPRODUCIDO en vivo: `[[ ... ]] &&
# main "$@"` como statement top-level, cuando la condición es falsa (fichero
# SOURCEADO, no ejecutado), es una compound-list cuyo exit status es el del
# `[[ ]]` (1, "falso") — bajo `set -e` en el shell/script que hace `source`,
# eso aborta INMEDIATAMENTE tras la línea de source, antes de correr ningún
# test. Reproducido: `bash -c 'set -e; source sentry_doctor.sh; echo X'` no
# imprime X, exit 1. El harness actual usa `set -uo pipefail` (sin `-e`) y
# por eso no lo sufre HOY — pero es una mina para cualquier consumidor
# futuro que sí use `set -e`. `if/fi` siempre sale 0 cuando no ejecuta main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
