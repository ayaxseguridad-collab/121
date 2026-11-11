#!/usr/bin/env bash
# runner-provision.sh — Preflight de REPARTO runner↔estación (validación del reparto): decide GO/NO-GO ANTES de
# despachar un gate a un runner, en vez de descubrir el problema en caliente a mitad de una suite.
#
# ── ALCANCE REAL, y por qué es más chico que el nombre sugiere ──────────────────────────────────
# El censo del reparto pedía también automatizar el CLONADO del golden y la migración de naming
# `vibe-channel-NN` → `vibe-runner-<maquina>-NN`. Medido contra el motor sincronizado (no un clon
# rancio): la identidad de runners ya resolvió el problema real por otra vía — `manifiestos/runner-identity.map`
# + `scripts/lib/runner-identity.sh`, ya en producción y cerrado en 4 rondas de auditoría — sin
# necesidad de renombrar contenedores en vivo. Reconstruir eso aquí sería duplicar una pieza ya
# auditada. Lo que SÍ seguía sin existir, medido contra el motor real: el rechazo en el REPARTO por
# alcance de estación y por capacidad Docker, y la distinción existe/escribible del directorio de
# trabajo. Este script cubre esos tres, nada más.
#
# ── LOS TRES CHEQUES, Y SU PORQUÉ ────────────────────────────────────────────────────────────────
#   1. ALCANCE (rp_scope_check): el runner declarado en el perfil (`runner.estacion`) tiene que
#      coincidir con la estación que pide el reparto, Y la `maquina` del runner tiene que estar en
#      el `runner_maquina=` de esa fila `estacion` (lista con rangos `a..b`, misma gramática que
#      `runners-remote.sh`). Sin este cheque, una cesión fuera de alcance se descubre cuando el
#      gate ya está corriendo en un runner que la estación no debería tocar.
#   2. DOCKER (rp_docker_check): un gate marcado `--needs-docker` sobre una máquina cuyo atributo
#      `docker=no` esté declarado se rechaza AQUÍ, no en el primer `docker: command not found` a
#      mitad de un shard e2e. Si el atributo NO está declarado (hoy: NINGUNA fila `maquina` del
#      perfil real lo declara todavía), el resultado es NO MEDIDO — no autoriza ni rechaza por
#      defecto, salvo `--strict-docker` (ver abajo): tratar "no declarado" como "rechazar" rompería
#      TODA la flota hoy mismo, y tratarlo como "aceptar" es fingir un dato que no existe. Un valor
#      PRESENTE Y CORRUPTO (p.ej. `docker=maybe`) es un TERCER desenlace, distinto de los dos de
#      arriba — [Acta 1, hallazgo 5] SIEMPRE NO-GO, con o sin `--strict-docker`: alguien escribiendo
#      algo mal es señal más fuerte de intención rota que un campo vacío, y las dos NO se perdonan
#      igual.
#   3. DIRECTORIO DE TRABAJO (rp_workdir_writable_check): un directorio compartido puede EXISTIR
#      con permisos de OTRA estación — eso mató 27 gates con rc=2 medido en producción hoy. Existir
#      y ser escribible son dos comprobaciones DISTINTAS; la reparación (si `--crea-workdir`) NUNCA
#      toca ficheros preexistentes de otro dueño, solo crea lo que falta.
#
# rc: 0 = los tres cheques pedidos pasan (GO) · 1 = algún cheque rechaza (NO-GO, se nombra cuál) ·
#     2 = precondición (perfil ilegible, argumentos inválidos) — infra reintentable, NUNCA se
#     confunde con un rechazo de reparto (1): un `rc 2` no dice "este runner no sirve", dice "no
#     pude decidir".
# Uso: runner-provision.sh --perfil <tsv> --estacion <id> --runner <id>
#        [--gate <id> --needs-docker] [--workdir <ruta> [--crea-workdir]] [--strict-docker]
# Sourceable para tests con RP_NO_MAIN=1 (expone los predicados puros rp_*).
set -uo pipefail
export LC_ALL=C

# --- localización del lector de perfil (mismo patrón que runners-remote.sh: reutiliza, no duplica
#     el parser del TSV) ------------------------------------------------------------------------
rp_lib_perfil() {
  local c
  if [ -n "${TC_LIB_PERFIL-}" ]; then
    [ -r "$TC_LIB_PERFIL" ] && { printf '%s\n' "$TC_LIB_PERFIL"; return 0; }
    return 1
  fi
  c="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../talent-ceo/scripts/lib-perfil.sh"
  [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
  return 1
}

# rp_lib_perfil_attr3 — la envoltura de TRES valores vive EN ESTE miembro (lectura de atributos del perfil):
# `perfil_attr` (dos valores) es la interfaz ajena de arriba; `perfil_attr3` es propia, siempre
# junto a este script, sin indirección de override — no hay razón para que apunte a otro sitio.
rp_lib_perfil_attr3() {
  local c
  c="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-perfil-attr3.sh"
  [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
  return 1
}

# rp_en_lista <nombre> <lista> — MISMA gramática que `rr_en_lista` de runners-remote.sh (comas +
# rangos `pref01..06` de ancho exacto). Duplicada A PROPÓSITO en vez de factorizada: extraer una
# función de un script ya auditado en 4 rondas para compartirla con uno nuevo es un cambio sobre
# código sellado por una ganancia de mantenibilidad, no una corrección — no entra en esta pieza.
# Queda declarado aquí para quien reconcilie ambos scripts más adelante (candidato a
# `scripts/lib/perfil-lista.sh` compartido, quien gobierne el refactor de listas).
# rc 0 está · rc 1 no está (lista legible) · rc 2 lista malformada/vacía (no se puede decidir).
rp_en_lista() {
  awk -v n="$1" -v l="$2" '
    BEGIN {
      c = split(l, it, ","); hay = 0; encontrado = 0
      for (i = 1; i <= c; i++) {
        e = it[i]; gsub(/^[ \t]+|[ \t]+$/, "", e)
        if (e == "") continue
        hay = 1
        p = index(e, "..")
        if (p == 0) { if (e == n) encontrado = 1; continue }
        izq = substr(e, 1, p - 1); der = substr(e, p + 2)
        if (der !~ /^[0-9]+$/) exit 2
        if (!match(izq, /[0-9]+$/)) exit 2
        pref = substr(izq, 1, RSTART - 1); desde = substr(izq, RSTART)
        if (length(der) != length(desde)) exit 2
        if ((der "") < (desde "")) exit 2
        if (index(n, pref) != 1) continue
        cola = substr(n, length(pref) + 1)
        if (cola !~ /^[0-9]+$/ || length(cola) != length(desde)) continue
        if ((cola "") >= (desde "") && (cola "") <= (der "")) encontrado = 1
      }
      if (!hay) exit 2
      exit encontrado ? 0 : 1
    }'
}

# rp_scope_check <perfil> <estacion> <runner> — rc 0 GO · rc 1 NO-GO (fuera de alcance, con motivo
# por stderr) · rc 2 NO MEDIDO (perfil/filas ilegibles: no se puede decidir, nunca se asume GO).
rp_scope_check() {
  # [lectura de atributos del perfil] las dos lecturas de abajo pasan por
  # `perfil_attr3` (rc 0 valor · rc 1 ausente · rc 2 NO MEDIDO/vacío-corrupto), no por `perfil_attr`
  # directo — `scripts/check-perfil-attr-eje.sh` lo hace estructural, no solo declarado.
  local perfil="$1" est_id="$2" run_id="$3" fila_run est_run maq_run fila_est run_maq_lista rc attr_rc
  fila_run="$(perfil_row1 runner "$run_id" "$perfil")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "rp_scope_check: runner '$run_id' no resuelve en el perfil (rc $rc)" >&2; return 2; }
  est_run="$(perfil_attr3 "$(printf '%s' "$fila_run" | cut -f6)" estacion)"; attr_rc=$?
  case "$attr_rc" in
    1) echo "rp_scope_check: NO-GO — runner '$run_id' no declara 'estacion=' (ausente)" >&2; return 1 ;;
    2) echo "rp_scope_check: runner '$run_id' declara 'estacion=' VACÍA/corrupta — NO MEDIDO" >&2; return 2 ;;
  esac
  maq_run="$(printf '%s' "$fila_run" | cut -f3)"
  [ "$est_run" = "$est_id" ] || {
    echo "rp_scope_check: NO-GO — runner '$run_id' pertenece a la estación '$est_run', no a '$est_id'" >&2
    return 1
  }
  fila_est="$(perfil_row1 estacion "$est_id" "$perfil")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "rp_scope_check: estación '$est_id' no resuelve en el perfil (rc $rc)" >&2; return 2; }
  run_maq_lista="$(perfil_attr3 "$(printf '%s' "$fila_est" | cut -f6)" runner_maquina)"; attr_rc=$?
  case "$attr_rc" in
    1) echo "rp_scope_check: estación '$est_id' sin 'runner_maquina=' declarado (ausente) — NO MEDIDO" >&2; return 2 ;;
    2) echo "rp_scope_check: estación '$est_id' declara 'runner_maquina=' VACÍA/corrupta — NO MEDIDO" >&2; return 2 ;;
  esac
  rp_en_lista "$maq_run" "$run_maq_lista"; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "rp_scope_check: NO-GO — máquina '$maq_run' del runner fuera de runner_maquina='$run_maq_lista' de '$est_id'" >&2; return 1 ;;
    *) echo "rp_scope_check: runner_maquina de '$est_id' malformado — NO MEDIDO" >&2; return 2 ;;
  esac
}

# rp_docker_check <perfil> <runner> <necesita_docker 0|1> <strict 0|1> — rc 0 GO · rc 1 NO-GO. El
# valor de `docker=` tiene TRES formas, cada una con su propio desenlace — [Acta 1] la ausencia y
# la corrupción NO comparten desenlace, aunque las dos empiecen en "no sé si tiene docker":
#   - AUSENTE (`''`, nadie ha declarado el atributo todavía): NO MEDIDO → GO-con-aviso por
#     defecto (no rompe la flota de hoy); `--strict-docker` lo vuelve NO-GO para cuando el perfil
#     esté poblado en todas sus filas `maquina`.
#   - `no`: NO-GO siempre (declaración explícita de que la máquina no sirve para esto).
#   - `si`: GO siempre.
#   - CORRUPTO (cualquier otro valor, p.ej. `maybe`/`Si`/`1`): NO-GO **siempre**, con o sin
#     `--strict-docker` — alguien escribió algo y lo escribió mal, que es una señal MÁS fuerte de
#     intención rota que un campo vacío; tratarlo igual que "ausente" perdonaría datos corruptos
#     hasta que alguien pidiera el modo estricto.
rp_docker_check() {
  # [lectura de atributos del perfil] Antes esta función llamaba a `perfil_attr` directo y distinguía
  # ausente/vacío a mano con su propio `docker_rc=$?` — correcto, pero era una TERCERA
  # reimplementación de la misma decisión (ver el censo de atributos del perfil). Ahora pasa por
  # `perfil_attr3`, que ya separa las dos formas por rc — esta función solo decide qué GO/NO-GO
  # corresponde a cada rc, no cómo detectarlas.
  local perfil="$1" run_id="$2" necesita="$3" strict="$4" fila_run maq_run fila_maq docker_val rc attr_rc
  [ "$necesita" = 1 ] || return 0   # el gate no pide Docker: nada que comprobar
  fila_run="$(perfil_row1 runner "$run_id" "$perfil")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "rp_docker_check: runner '$run_id' no resuelve en el perfil (rc $rc)" >&2; return 2; }
  maq_run="$(printf '%s' "$fila_run" | cut -f3)"
  fila_maq="$(perfil_row1 maquina "$maq_run" "$perfil")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "rp_docker_check: máquina '$maq_run' no resuelve en el perfil (rc $rc)" >&2; return 2; }
  docker_val="$(perfil_attr3 "$(printf '%s' "$fila_maq" | cut -f6)" docker)"; attr_rc=$?
  case "$attr_rc" in
    1)
      # AUSENTE (perfil_attr3 rc 1): nadie ha declarado 'docker=' todavía — NO MEDIDO por defecto,
      # GO-con-aviso (no rompe la flota de hoy); --strict-docker lo vuelve bloqueante.
      if [ "$strict" = 1 ]; then
        echo "rp_docker_check: NO-GO (--strict-docker) — máquina '$maq_run' sin 'docker=' declarado" >&2
        return 1
      fi
      echo "rp_docker_check: NO MEDIDO — máquina '$maq_run' sin 'docker=' declarado (GO-con-aviso; usa --strict-docker para exigirlo)" >&2
      return 0
      ;;
    2)
      # NO MEDIDO (perfil_attr3 rc 2): la clave SÍ está escrita, con valor vacío — señal MÁS
      # fuerte de intención rota que un campo ausente; NO-GO siempre, con o sin --strict-docker.
      echo "rp_docker_check: NO-GO — valor de 'docker=' CORRUPTO (vacío) en '$maq_run': la clave está declarada sin valor — esto NO es lo mismo que ausente, no se perdona con o sin --strict-docker" >&2
      return 1
      ;;
  esac
  case "$docker_val" in
    no) echo "rp_docker_check: NO-GO — máquina '$maq_run' declara docker=no y el gate lo necesita" >&2; return 1 ;;
    si) return 0 ;;
    *)
      # Valor PRESENTE (rc 0, no vacío) pero ni 'si' ni 'no' (p.ej. 'maybe', 'Si', '1') — mismo
      # trato que el rc 2 de arriba: NO-GO siempre, no se perdona con --strict-docker.
      echo "rp_docker_check: NO-GO — valor de 'docker=' CORRUPTO en '$maq_run': '$docker_val' (ni 'si' ni 'no' — esto NO es lo mismo que ausente, no se perdona con o sin --strict-docker)" >&2
      return 1
      ;;
  esac
}

# rp_workdir_writable_check <ruta> <crea 0|1> — distingue EXISTE de ESCRIBIBLE (el hallazgo de
# hoy: 27 gates con rc=2 por un directorio presente con permisos de otra estación). rc 0 GO
# (escribible, verificado con una escritura de sondeo real y su limpieza, no solo el flag -w que
# algunos FS de red reportan mal) · rc 1 NO-GO existe-pero-no-escribible (infra reintentable, NUNCA
# se trata como fallo de producto) · rc 2 NO MEDIDO (no se pudo determinar ninguna de las dos).
# Con crea=1 y el directorio AUSENTE, lo crea — y SOLO en ese caso: nunca reintenta permisos sobre
# uno ya existente ni toca ficheros ajenos que ya hubiera dentro.
rp_workdir_writable_check() {
  local dir="$1" crea="$2" sonda
  if [ ! -e "$dir" ]; then
    if [ "$crea" = 1 ]; then
      mkdir -p -- "$dir" 2>/dev/null || { echo "rp_workdir_writable_check: no pude crear '$dir' — NO MEDIDO" >&2; return 2; }
      echo "rp_workdir_writable_check: '$dir' creado (no existía)" >&2
      return 0
    fi
    echo "rp_workdir_writable_check: '$dir' no existe (sin --crea-workdir) — NO-GO infra-reintentable" >&2
    return 1
  fi
  [ -d "$dir" ] || { echo "rp_workdir_writable_check: '$dir' existe pero no es un directorio — NO MEDIDO" >&2; return 2; }
  sonda="$dir/.rp-sonda-escritura.$$"
  if ( umask 077; : > "$sonda" ) 2>/dev/null; then
    rm -f -- "$sonda" 2>/dev/null
    return 0
  fi
  echo "rp_workdir_writable_check: '$dir' EXISTE pero NO es escribible (¿permisos de otra estación?) — NO-GO infra-reintentable, restos ajenos NO tocados" >&2
  return 1
}

rp_main() {
  local perfil='' estacion='' runner='' gate='' necesita_docker=0 workdir='' crea_workdir=0 strict_docker=0
  while [ $# -gt 0 ]; do case "$1" in
    --perfil)         perfil="${2-}"; shift 2 || return 2 ;;
    --estacion)       estacion="${2-}"; shift 2 || return 2 ;;
    --runner)         runner="${2-}"; shift 2 || return 2 ;;
    --gate)           gate="${2-}"; shift 2 || return 2 ;;
    --needs-docker)   necesita_docker=1; shift ;;
    --workdir)        workdir="${2-}"; shift 2 || return 2 ;;
    --crea-workdir)   crea_workdir=1; shift ;;
    --strict-docker)  strict_docker=1; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; return 0 ;;
    *) printf 'runner-provision: flag desconocido: %s\n' "$1" >&2; return 2 ;;
  esac; done
  [ -n "$estacion" ] && [ -n "$runner" ] || { printf 'runner-provision: --estacion y --runner son obligatorios\n' >&2; return 2; }

  local lib
  lib="$(rp_lib_perfil)" || { printf 'runner-provision: no encuentro lib-perfil.sh (skill talent-ceo). Indícalo con TC_LIB_PERFIL=<ruta>.\n' >&2; return 2; }
  # shellcheck source=/dev/null
  . "$lib" || { printf 'runner-provision: lib-perfil.sh ilegible\n' >&2; return 2; }
  local lib3
  lib3="$(rp_lib_perfil_attr3)" || { printf 'runner-provision: no encuentro lib-perfil-attr3.sh (propio de este skill)\n' >&2; return 2; }
  # shellcheck source=/dev/null
  . "$lib3" || { printf 'runner-provision: lib-perfil-attr3.sh ilegible\n' >&2; return 2; }
  if [ -z "$perfil" ]; then perfil="$(perfil_path)" || { printf 'runner-provision: SIN PERFIL\n' >&2; return 2; }; fi

  local fallo=0 rc

  rp_scope_check "$perfil" "$estacion" "$runner"; rc=$?
  case "$rc" in 0) echo "ALCANCE: GO";; 1) echo "ALCANCE: NO-GO"; fallo=1;; *) echo "ALCANCE: NO MEDIDO"; fallo=1;; esac

  if [ -n "$gate" ] || [ "$necesita_docker" = 1 ]; then
    rp_docker_check "$perfil" "$runner" "$necesita_docker" "$strict_docker"; rc=$?
    case "$rc" in 0) echo "DOCKER: GO";; 1) echo "DOCKER: NO-GO"; fallo=1;; *) echo "DOCKER: NO MEDIDO"; fallo=1;; esac
  fi

  if [ -n "$workdir" ]; then
    rp_workdir_writable_check "$workdir" "$crea_workdir"; rc=$?
    case "$rc" in 0) echo "WORKDIR: GO";; 1) echo "WORKDIR: NO-GO"; fallo=1;; *) echo "WORKDIR: NO MEDIDO"; fallo=1;; esac
  fi

  [ "$fallo" -eq 0 ]
}

if [ -z "${RP_NO_MAIN-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  rp_main "$@"; exit $?
fi
