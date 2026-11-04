#!/usr/bin/env bash
# probar-sonda.sh — pasa casos-sonda.tsv por la puerta y comprueba veredicto y motivo.
#
#   bash tests/probar-sonda.sh
#
# Sale 0 si todos los casos dan lo esperado. Es la prueba de que la puerta es
# fail-closed: cualquier maquina que no sea la de referencia tiene que rechazarse,
# y con el motivo correcto — no basta con que rechace por cualquier cosa.

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SONDA="$AQUI/../scripts/sonda.sh"
FAKE="$AQUI/fake-nvidia-smi.sh"
CASOS="$AQUI/casos-sonda.tsv"

# El disco del runner no es el de la referencia: medimos la puerta con datos
# sintéticos, conservando sus umbrales y el caso negativo de disco insuficiente.
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" || exit 2
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--output=avail*) printf 'Avail\n%sG\n' "${FAKE_DISCO_GB:-100}" ;;
  *--output=source*) printf 'Filesystem\nfixture-disco\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/df" || exit 2
export PATH="$T/bin:$PATH"
TOTAL_ESPERADO=22

# Sin esto, un TSV que falte o este vacio hace fallar la redireccion de mas abajo
# EN SILENCIO (sin -e): el bucle no corre ninguna vez, falla se queda en 0 y el
# script anuncia exito sin haber probado nada.
[ -r "$CASOS" ] && [ -s "$CASOS" ] || {
  printf 'FALLO: no se pueden cargar casos de sonda: %s\n' "$CASOS" >&2
  exit 1
}

pasa=0; falla=0; casos=0

while IFS=$'\t' read -r nombre esperado entorno fragmento; do
  case "$nombre" in ''|'#'*) continue ;; esac
  casos=$((casos + 1))

  # El entorno del caso se aplica solo a esta invocacion.
  env_args=()
  if [ "$entorno" != "-" ]; then
    # Se trocea por espacios, asi que en el TSV los nombres de GPU van con '_' y se
    # dejan tal cual: sustituir '_' por espacio aqui destrozaria nombres de variable
    # como MIN_DISCO_MODELOS_GB.
    for asignacion in $entorno; do env_args+=("$asignacion"); done
  fi

  salida="$(env LL_DISTRO_ID=ubuntu "${env_args[@]}" NVIDIA_SMI="$FAKE" DRY_RUN=1 bash "$SONDA" 2>&1)"
  rc=$?
  veredicto="$([ $rc -eq 0 ] && echo autoriza || echo rechaza)"

  problema=""
  [ "$veredicto" != "$esperado" ] && problema="esperaba $esperado y dio $veredicto"
  if [ -z "$problema" ] && [ "$esperado" = "rechaza" ] && [ "$fragmento" != "-" ]; then
    grep -qF -- "$fragmento" <<<"$salida" || problema="rechaza, pero no por el motivo esperado ('$fragmento')"
  fi

  if [ -z "$problema" ]; then
    printf '  OK    %s\n' "$nombre"; pasa=$((pasa + 1))
  else
    printf '  FALLO %s — %s\n' "$nombre" "$problema"; falla=$((falla + 1))
    printf '%s\n' "$salida" | sed 's/^/          | /'
  fi
done <"$CASOS"

[ "$casos" -gt 0 ] || {
  printf 'FALLO: no se ejecuto ningun caso de sonda\n' >&2
  exit 1
}
[ "$casos" -eq "$TOTAL_ESPERADO" ] || {
  printf 'FALLO: casos ejecutados %s != TOTAL_ESPERADO %s\n' "$casos" "$TOTAL_ESPERADO" >&2
  exit 1
}

printf '\n  %d casos correctos · %d fallidos\n\n' "$pasa" "$falla"
[ "$falla" -eq 0 ]
