#!/usr/bin/env bash
# Pruebas de reparto extraídas del pin; usa las dependencias reales del skill.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 — [$2]"; fi; }
TOTAL_ESPERADO=16

mk_perfil_reparto() { # <ruta destino> — perfil sintético de 4 máquinas, 100% hermético (sin datos reales)
  cat > "$1" <<'TSV'
tipo	id	maquina	contenedor	sesion	atributos
maquina	host	host	-	-	acceso=local;docker=si
maquina	sur	sur	-	-	acceso=ssh_root;docker=no
maquina	este	este	-	-	acceso=ssh_root
maquina	norte	norte	-	-	acceso=ssh_root
estacion	M1	host	-	-	runner_maquina=host,sur
estacion	M2	host	-	-	runner_maquina=este
runner	r-host-01	host	r-host-01	-	estacion=M1
runner	r-sur-01	sur	r-sur-01	-	estacion=M1
runner	r-este-01	este	r-este-01	-	estacion=M2
TSV
}
LIBPERFIL_REPARTO="$HERE/../../talent-ceo/scripts/lib-perfil.sh"

# ==========================================================================
echo "== reparto runner-provision.sh: preflight de reparto (alcance, docker, workdir) =="
RP_REPARTO="$SCRIPTS/runner-provision.sh"
PERFIL_REPARTO="$WORK/reparto-perfil.tsv"; mk_perfil_reparto "$PERFIL_REPARTO"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-host-01 >/dev/null 2>&1 )
chk "reparto rp_scope_check: runner dentro de alcance -> GO (rc 0)" "[ $? -eq 0 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-este-01 >/tmp/reparto-o1.$$ 2>&1
  rc=$?; grep -q "pertenece a la estación 'M2', no a 'M1'" /tmp/reparto-o1.$$ || rc=9
  rm -f /tmp/reparto-o1.$$; exit "$rc" )
chk "reparto rp_scope_check: cesión fuera de alcance -> NO-GO nombrando la estación real (rc 1)" "[ $? -eq 1 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-sur-01 --needs-docker >/dev/null 2>&1 )
chk "reparto rp_docker_check: docker=no + --needs-docker -> NO-GO (rc 1)" "[ $? -eq 1 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M2 --runner r-este-01 --needs-docker >/dev/null 2>&1 )
chk "reparto rp_docker_check: docker= no declarado, sin --strict-docker -> GO-con-aviso (rc 0)" "[ $? -eq 0 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M2 --runner r-este-01 --needs-docker --strict-docker >/dev/null 2>&1 )
chk "reparto rp_docker_check: docker= no declarado, CON --strict-docker -> NO-GO (rc 1)" "[ $? -eq 1 ]"

# [Acta 1, hallazgo MAYOR] regresión: un valor PRESENTE Y CORRUPTO (docker=maybe) colapsaba en el
# MISMO GO-con-aviso que "ausente", ignorando --strict-docker igual que ella. Ahora es SIEMPRE
# NO-GO — perfil aparte (no el compartido $PERFIL_REPARTO) para no acoplar esta fila a los demás casos.
PERFIL_REPARTO_MALFORMADO="$WORK/reparto-perfil-docker-malformado.tsv"
cat > "$PERFIL_REPARTO_MALFORMADO" <<'TSV'
tipo	id	maquina	contenedor	sesion	atributos
maquina	host	host	-	-	acceso=local;docker=maybe
estacion	M1	host	-	-	runner_maquina=host
runner	r-host-01	host	r-host-01	-	estacion=M1
TSV
( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO_MALFORMADO" --estacion M1 --runner r-host-01 --needs-docker >/tmp/reparto-h5a.$$ 2>&1
  rc=$?; grep -q "CORRUPTO en 'host': 'maybe'" /tmp/reparto-h5a.$$ || rc=9
  rm -f /tmp/reparto-h5a.$$; exit "$rc" )
chk "reparto [docker corrupto] rp_docker_check: docker=maybe (CORRUPTO) SIN --strict-docker -> NO-GO igual (antes: GO-con-aviso, mismo trato que ausente)" "[ $? -eq 1 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO_MALFORMADO" --estacion M1 --runner r-host-01 --needs-docker --strict-docker >/dev/null 2>&1 )
chk "reparto [docker corrupto] rp_docker_check: docker=maybe (CORRUPTO) CON --strict-docker -> NO-GO (sigue igual, control)" "[ $? -eq 1 ]"

# Control de discriminación: el caso AUSENTE (ya probado arriba, r-este-01 sin --strict-docker)
# sigue dando GO — si este control fallara, la prueba de arriba no discriminaría ausente de
# corrupto, que es justo lo que el hallazgo pedía separar.
( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M2 --runner r-este-01 --needs-docker >/dev/null 2>&1 )
chk "reparto [docker corrupto] control: docker= AUSENTE (distinto de corrupto) sigue en GO-con-aviso sin --strict-docker" "[ $? -eq 0 ]"

# [Acta 1, veto NO-GO ronda 3 — H2] regresión: `docker=` con valor VACÍO (la clave SÍ está escrita,
# `perfil_attr` la encuentra con rc 0 y string vacío) colapsaba en el MISMO GO-con-aviso que
# AUSENTE (clave nunca escrita, `perfil_attr` rc 1) porque `rp_docker_check` descartaba el rc de
# `perfil_attr` con `$(...)` sin capturarlo. Perfil aparte para no acoplar esta fila a las demás.
PERFIL_REPARTO_VACIO="$WORK/reparto-perfil-docker-vacio.tsv"
cat > "$PERFIL_REPARTO_VACIO" <<'TSV'
tipo	id	maquina	contenedor	sesion	atributos
maquina	host	host	-	-	acceso=local;docker=
estacion	M1	host	-	-	runner_maquina=host
runner	r-host-01	host	r-host-01	-	estacion=M1
TSV
( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO_VACIO" --estacion M1 --runner r-host-01 --needs-docker >/tmp/reparto-h2a.$$ 2>&1
  rc=$?; grep -q "CORRUPTO (vacío) en 'host'" /tmp/reparto-h2a.$$ || rc=9
  rm -f /tmp/reparto-h2a.$$; exit "$rc" )
chk "reparto [docker vacío] rp_docker_check: docker= VACÍO (clave escrita sin valor) SIN --strict-docker -> NO-GO (antes: GO-con-aviso, mismo trato que ausente)" "[ $? -eq 1 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO_VACIO" --estacion M1 --runner r-host-01 --needs-docker --strict-docker >/dev/null 2>&1 )
chk "reparto [docker vacío] rp_docker_check: docker= VACÍO CON --strict-docker -> NO-GO (sigue igual, control)" "[ $? -eq 1 ]"

( # Control de discriminación: AUSENTE de verdad (clave nunca escrita, perfil $PERFIL_REPARTO sin fila
  # docker= para 'este') sigue en GO-con-aviso — si este control fallara, el test de arriba no
  # discriminaría vacío de ausente, que es justo lo que este hallazgo pedía separar.
  TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M2 --runner r-este-01 --needs-docker >/dev/null 2>&1 )
chk "reparto [docker vacío] control: docker= AUSENTE (clave nunca escrita, distinto de vacío) sigue en GO-con-aviso sin --strict-docker" "[ $? -eq 0 ]"

# [refacto-99, sitio (b)] el `case` de rp_main no tenía rama `*)` para DOCKER (a diferencia de
# sus hermanos ALCANCE/WORKDIR, que sí la tienen): un rc=2 de rp_docker_check no imprimía NADA
# para DOCKER y dejaba `fallo` intacto en ese bloque.
# NOTA DE ALCANCE (declarada, no inventada — ORDEN-REFACTO-99-1739 pide declarar si el arnés no
# deja montar el caso "aislado"): rp_docker_check solo devuelve rc=2 por dos vías (runner no
# resuelve / máquina no resuelve), y las DOS comparten el mismo `perfil_row1`, que valida el
# perfil ENTERO (V5, invariante whole-file) antes de resolver una sola fila — la MISMA validación
# de la que depende rp_scope_check. Por construcción, si el perfil es lo bastante válido para que
# ALCANCE dé GO, el runner y su máquina YA resolvieron limpio, así que DOCKER no puede fallar con
# rc=2 en ese mismo momento: "alcance GO + docker rc=2 aislado" es estructuralmente INALCANZABLE
# con un perfil bien formado, no solo difícil de construir. Lo que SÍ es alcanzable y sí se
# ejercita aquí: runner inexistente -> ALCANCE y DOCKER caen en rc=2 A LA VEZ (mismo `perfil_row1`,
# mismo motivo) — el rc global no cambia (ALCANCE ya lo pone en NO-GO por su cuenta), pero la LÍNEA
# de estado de DOCKER es el síntoma real y observable del defecto: antes del fix desaparecía en
# silencio (ningún "DOCKER: ..." impreso pese a que rp_docker_check SÍ corrió y SÍ devolvió 2);
# con el fix, aparece "DOCKER: NO MEDIDO" con el mismo trato que sus hermanos.
( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-reparto-no-declarado --needs-docker >/tmp/reparto-rb.$$ 2>&1
  rc=$?; grep -q "DOCKER: NO MEDIDO" /tmp/reparto-rb.$$ || rc=9
  rm -f /tmp/reparto-rb.$$; exit "$rc" )
chk "reparto [runner ausente] rp_docker_check rc=2 (runner no declarado) -> ahora imprime 'DOCKER: NO MEDIDO' con el mismo trato que ALCANCE/WORKDIR (antes: la línea de DOCKER desaparecía en silencio, sin rama '*' en el case)" "[ $? -eq 1 ]"

# [commit (e), CEO-RULING-99-EL-TEST-SIN-DIENTES-SE-ARREGLA-ANTES-DE-FUNDIR-1845] El test de arriba
# no aísla la rama `*)`: en su escenario, ALCANCE ya fuerza `fallo=1` por su cuenta (mismo
# `perfil_row1`, mismo motivo), así que el `rc` global no depende de que DOCKER contribuya —
# confirmado con mutación en ACTA-99-A (quitar solo `fallo=1` de la rama `*)` deja el test en
# verde). El escenario "ALCANCE y WORKDIR pasan, SOLO rp_docker_check devuelve 2" es
# estructuralmente inalcanzable con un perfil real (V5 de lib-perfil.sh, ya declarado arriba), así
# que se aísla con un SEAM en vez de un perfil: `RP_NO_MAIN=1` (ya usado por validate-manifest.sh
# líneas 116/144) hace `runner-provision.sh` sourceable, y se REDEFINE `rp_docker_check` para que
# devuelva 2 sin condición — no se prueba `rp_docker_check` (ya tiene su propia cobertura), se
# prueba SOLO el `case` de `rp_main` que decide qué hacer con ese rc. Mismo precedente de seam que
# `RC_DF_BIN` en runner-clean.sh (línea ~137, usado en este mismo arnés en la línea ~1390).
( # shellcheck source=skills/talent-channels/scripts/runner-provision.sh
  RP_NO_MAIN=1 . "$RP_REPARTO"
  rp_docker_check() { return 2; }
  WD_E1="$WORK/reparto-e1-workdir"; mkdir -p "$WD_E1"
  out="$(TC_LIB_PERFIL="$LIBPERFIL_REPARTO" rp_main --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-host-01 --needs-docker --workdir "$WD_E1" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -q "^ALCANCE: GO$" \
    && printf '%s\n' "$out" | grep -q "^WORKDIR: GO$" \
    && printf '%s\n' "$out" | grep -q "^DOCKER: NO MEDIDO$" \
    && [ "$rc" -eq 1 ] || { echo "$out" >&2; exit 9; } )
chk "reparto [rama docker aislada] rp_main aísla la rama '*)' de DOCKER (seam: rp_docker_check redefinida a rc=2 fijo) -> con ALCANCE y WORKDIR en GO limpio, SOLO 'DOCKER: NO MEDIDO' produce el NO-GO (rc 1) — la contribución de esa rama al veredicto queda probada aislada, no de prestado" "[ $? -eq 0 ]"

( # SIN 'set -e': el rc esperado del preflight es 1 (NO-GO) — con -e activo la subshell abortaría
  # justo ahí y el chmod 700 de restauración de abajo NUNCA correría, dejando "$D" en 500 para el
  # `rm -rf "$WORK"` final del arnés (permission denied medido: exactamente este bug, en vivo).
  D="$WORK/reparto-wd-ajeno"; mkdir -p "$D"; echo contenido-ajeno > "$D/archivo-ajeno"; chmod 500 "$D"
  before="$(cat "$D/archivo-ajeno" 2>/dev/null || echo NOLEIBLE)"
  TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-host-01 --workdir "$D" >/dev/null 2>&1
  rc=$?
  chmod 700 "$D"   # SIEMPRE se restaura, corra lo que corra arriba — nunca condicionado a set -e
  after="$(cat "$D/archivo-ajeno" 2>/dev/null || echo NOLEIBLE)"
  [ "$before" = "$after" ] || rc=9
  exit "$rc" )
chk "reparto rp_workdir_writable_check: existe-no-escribible -> NO-GO (rc 1) y contenido ajeno intacto" "[ $? -eq 1 ]"

( TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-host-01 --workdir "$WORK/reparto-wd-ausente" >/dev/null 2>&1 )
chk "reparto rp_workdir_writable_check: ausente sin --crea-workdir -> NO-GO (rc 1)" "[ $? -eq 1 ]"

( set -e
  TC_LIB_PERFIL="$LIBPERFIL_REPARTO" bash "$RP_REPARTO" --perfil "$PERFIL_REPARTO" --estacion M1 --runner r-host-01 \
    --workdir "$WORK/reparto-wd-nueva" --crea-workdir >/dev/null
  [ -d "$WORK/reparto-wd-nueva" ] )
chk "reparto rp_workdir_writable_check: ausente CON --crea-workdir -> GO (rc 0) y directorio creado" "[ $? -eq 0 ]"


TOTAL=$((PASS + FAIL))
echo "runner-provision: PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL/$TOTAL_ESPERADO"
[ "$TOTAL" -eq "$TOTAL_ESPERADO" ] && [ "$FAIL" -eq 0 ]
