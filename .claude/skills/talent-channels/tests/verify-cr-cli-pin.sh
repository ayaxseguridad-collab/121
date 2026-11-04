#!/usr/bin/env bash
# verify-cr-cli-pin.sh — verificación de red OPT-IN (TAL-1968, auditoría ronda 3).
#
# NO forma parte de run-tests.sh ni de ningún gate local: run-tests.sh es deliberadamente hermético
# (NO toca red/incus/credenciales reales, ver su cabecera) y sus secciones #16/#17 solo prueban el
# MECANISMO de resolución de Node / instalación del CLI de CodeRabbit con un fixture propio — no
# pueden, ni deben, validar que el valor EXACTO hoy pineado en scripts/02-golden.sh coincida con el
# artefacto real publicado (eso exige red). Este script cubre ESE hueco por separado: descarga los
# artefactos reales x64/arm64 de la versión pineada y compara su sha256 contra CR_CLI_SHA256_X64/
# CR_CLI_SHA256_ARM64. Un pin incorrecto SÍ hace fallar este script (exit 1).
#
# Uso:  bash tests/verify-cr-cli-pin.sh
# Requiere: curl, sha256sum, red hacia cli.coderabbit.ai. Descarga ~40MB por arquitectura.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN="$HERE/../scripts/coderabbit-pin.conf"

[ -f "$GOLDEN" ] || { echo "ERROR: no encuentro $GOLDEN" >&2; exit 1; }

ver="$(sed -n 's/^CR_CLI_VERSION=//p' "$GOLDEN")"
sha_x64="$(sed -n 's/^CR_CLI_SHA256_X64=//p' "$GOLDEN")"
sha_arm64="$(sed -n 's/^CR_CLI_SHA256_ARM64=//p' "$GOLDEN")"
[ -n "$ver" ] && [ -n "$sha_x64" ] && [ -n "$sha_arm64" ] \
  || { echo "ERROR: no pude extraer CR_CLI_VERSION/CR_CLI_SHA256_* de $GOLDEN" >&2; exit 1; }

echo "Pin declarado: CodeRabbit CLI $ver"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

for pair in "x64:$sha_x64" "arm64:$sha_arm64"; do
  arch="${pair%%:*}"; want="${pair#*:}"
  url="https://cli.coderabbit.ai/releases/${ver}/coderabbit-linux-${arch}.zip"
  echo "→ descargando $url"
  if ! curl -fsSL --connect-timeout 30 --max-time 300 --retry 2 "$url" -o "$tmp/$arch.zip"; then
    echo "FAIL $arch: no se pudo descargar el artefacto" >&2
    fail=1
    continue
  fi
  got="$(sha256sum "$tmp/$arch.zip" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then
    echo "OK   $arch: sha256 coincide ($got)"
  else
    echo "FAIL $arch: sha256 NO coincide — pineado=$want real=$got — PIN INCORRECTO" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "PIN VERIFICADO: CodeRabbit CLI $ver — x64 y arm64 coinciden con el artefacto publicado."
else
  echo "PIN NO VERIFICADO — ver FAIL arriba. NO usar este pin hasta corregirlo." >&2
fi
exit "$fail"
