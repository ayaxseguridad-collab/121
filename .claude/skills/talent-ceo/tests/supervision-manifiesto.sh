#!/usr/bin/env bash
# Regresiones de los lectores del doctor frente a las fuentes distribuidas y generadas.
# Se carga desde test-supervision.sh y comparte sus fixtures herméticos y autoconteo.
# shellcheck disable=SC2154 # variables de la suite que carga este fichero

printf '== lectores: manifiesto y datos del generador ==\n'
sed -n '/^leer_conf() {/,/^}/p; /^leer_identidad() {/,/^}/p' "$DOC" > "$T/lectores.sh"
conf_rc() {
  bash -c '. "$1"; declare -A datos=(); leer_conf "$2" datos "${3-}"' prueba "$T/lectores.sh" "$@"
}
conf_rc "$PKG/manifiestos/ejemplo.conf"
assert_eq 'lector acepta el ejemplo distribuido integro' 0 "$?"
fx_nuevo
cp "$PKG/manifiestos/ejemplo.conf" "$T/autoridad.conf"
sed -i 's/^TCO_REPO_DIR=.*/TCO_REPO_DIR=Producto-A/; s|^TCO_REPO_SLUG=.*|TCO_REPO_SLUG=example-org/Producto-A|' "$FXSK/talent-channel-operation/scripts/repo-identity.conf"
dr
assert_eq 'doctor acredita el ejemplo integro como autoridad sin omitir el auditor' '0|1|1' \
  "$RC|$(printf '%s\n' "$OUT" | grep -c '^OK identidad canal-operation:')|$(printf '%s\n' "$OUT" | grep -c '^OK auditor ')"

fx_nuevo
printf 'TF_GATE_CMD_docs="test -f README.md"\nTF_GATE_CMD_db_guards="true"\ntf_gate2="literal"\n' >> "$T/autoridad.conf"
dr
assert_eq 'doctor admite varios gates minusculos y guiones bajos' 0 "$RC"
leidos="$(bash -c '
  . "$1"; declare -A datos=(); leer_conf "$2" datos || exit 1
  printf "%s|%s|%s" "${datos[TF_GATE_CMD_docs]}" "${datos[TF_GATE_CMD_db_guards]}" "${datos[tf_gate2]}"
' prueba "$T/lectores.sh" "$T/autoridad.conf")"; lector_rc=$?
assert_eq 'lector conserva comandos y admite minuscula inicial como el validador' '0|test -f README.md|true|literal' "$lector_rc|$leidos"

# Cada mutante llega al doctor con identidad válida; autoridad ilegible mantiene la puerta cerrada.
# shellcheck disable=SC2016 # expansiones hostiles son datos literales de prueba
for dato in 'TF_GATE_CMD_docs-x="true"' '_TF_GATE="true"' '1TF_GATE="true"' \
  'TF.GATE="true"' 'TF GATE="true"' 'TF:GATE="true"' 'TF_GATE_CMD_docs="$(true)"' \
  'TF_GATE_CMD_docs="${HOME}"' 'TF_GATE_CMD_docs="`true`"' 'TF_GATE_CMD_docs="a\b"' \
  'TF_GATE_CMD_docs="ok"resto' 'TF_GATE_CMD_docs="a""b"' $'TF_GATE_CMD_docs="a\tb"' \
  $'TF_GATE_CMD_docs="a\rb"' 'TF_GATE_CMD_docs="true"'; do
  fx_nuevo
  # La última entrada repite la misma clave con valores idénticos: también se rechaza.
  [ "$dato" != 'TF_GATE_CMD_docs="true"' ] || printf '%s\n' "$dato" >> "$T/autoridad.conf"
  printf '%s\n' "$dato" >> "$T/autoridad.conf"
  dr
  assert_eq "autoridad rechazada: $dato" '1|1|1|0' \
    "$RC|$(printf '%s\n' "$OUT" | grep -c '^NOVERIF identidad procedencia:')|$(printf '%s\n' "$OUT" | grep -c '^FALLA identidad canal-operation:')|$(printf '%s\n' "$OUT" | grep -c '^PUERTA ABIERTA$')"
done
printf 'export tf_gate="true"\n' > "$T/agents-minuscula.conf"
conf_rc "$T/agents-minuscula.conf" agents
assert_eq 'la gramatica de agents conserva claves mayusculas' 1 "$?"

# El comando real produce los datos; no recrear el formato del generador en el fixture.
GEN="$T/generado"; GENHOME="$T/home-generado"
python3 "$PKG/instalacion/instalacion.py" generar \
  --respuestas "$PKG/instalacion/tests/fixtures/minima.resp" --salida "$GEN" --home "$GENHOME" > "$T/generar.log" 2>&1
assert_eq 'generador real sobre respuestas minimas termina sin error' 0 "$?"
conf_rc "$GEN/manifiestos/ejemplo.conf"
assert_eq 'lector acepta el manifiesto generado real' 0 "$?"
for miembro in talent-channel-operation talent-orchestrator; do
  leidos="$(bash -c '
    . "$1"; declare -A datos=(); leer_conf "$2" datos agents || exit 1
    printf "%s|%s|%s|%s" "${datos[AM_LEDGER]}" "${datos[TF_ROOT]}" "${datos[TF_MANIFEST]}" "${datos[TCO_AUDIT_CLI]}"
  ' prueba "$T/lectores.sh" "$GENHOME/.config/$miembro/agents.conf")"; lector_rc=$?
  assert_eq "lector acepta agents generado de $miembro y sus tres export" \
    "0|$GEN/ledger/cuentas.json|$GEN|$GEN/manifiestos/ejemplo.conf|claude-root" "$lector_rc|$leidos"
done
bash -c '
  . "$1"; declare -A datos=(); leer_identidad "$2" datos || exit 1
  [ "${datos[PKG_IDENTITY_PROJECT]}" = ejemplo ] && [ "${datos[TCO_TF_MANIFEST]}" = "$3" ]
' prueba "$T/lectores.sh" "$GEN/instalacion/generado/identidad-aprobada.conf" "$GEN/manifiestos/ejemplo.conf"
assert_eq 'identidad generada conserva valores exactos' 0 "$?"
bash "$ROOT/scripts/lib-perfil.sh" --check "$GEN/manifiestos/ejemplo.perfil.tsv" >/dev/null 2>&1
assert_eq 'el lector del perfil acepta la topologia generada real' 0 "$?"
bash -c '
  . "$1"; export TA_PERFIL="$2"; fila="$(perfil_row1 bus)" || exit 1
  perfil_campos "$fila"; [ "$(perfil_attr "${PERFIL_CAMPOS[5]}" path)" = "$3" ]
' prueba "$ROOT/scripts/lib-perfil.sh" "$GEN/manifiestos/ejemplo.perfil.tsv" "$GENHOME/ejemplo/bus"
assert_eq 'lector del perfil conserva la ruta del bus del generador' 0 "$?"

# La vía real de adjudicación escribe repo-identity.conf sin comillas envolventes.
PRODUCTO="$T/producto"; DESTINO="$PRODUCTO/.claude/skills"
mkdir -p "$DESTINO/talent-channel-operation/scripts" "$DESTINO/talent-channel-operation/references" \
  "$DESTINO/talent-orchestrator/scripts"
cp "$SK/talent-channel-operation/scripts/00-config.sh" "$DESTINO/talent-channel-operation/scripts/"
cp "$GEN/instalacion/generado/anexos/talent-channel-operation/anexo-ejemplo.md" "$DESTINO/talent-channel-operation/references/"
git -C "$PRODUCTO" init -q
git -C "$PRODUCTO" remote add origin https://github.com/org-example/producto.git
PKG_HOST_HOME="$GENHOME" bash "$SK/skill-creator/scripts/sync-package.sh" --migrate-identity \
  --to "$DESTINO" --authority "$GEN/manifiestos/ejemplo.conf" \
  --approved "$GEN/instalacion/generado/identidad-aprobada.conf" > "$T/migrar.log" 2>&1
assert_eq 'adjudicacion real del fragmento generado termina sin error' 0 "$?"
for miembro in talent-channel-operation talent-orchestrator; do
  bash -c '
    . "$1"; declare -A datos=(); leer_identidad "$2" datos || exit 1
    [ "${datos[PKG_IDENTITY_PROJECT]}" = ejemplo ] || exit 1
    if [ "$3" = talent-channel-operation ]; then
      [ "${datos[TCO_REPO_SLUG]}" = org-example/producto ] && [ "${datos[TCO_REPO_DIR]}" = producto ]
    else
      [ "${datos[TORC_HOST_ENV_REL]}" = ejemplo/.env.local ]
    fi
  ' prueba "$T/lectores.sh" "$DESTINO/$miembro/scripts/repo-identity.conf" "$miembro"
  assert_eq "lector acepta identidad adjudicada real de $miembro" 0 "$?"
done
