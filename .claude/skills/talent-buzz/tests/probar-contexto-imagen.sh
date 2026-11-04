#!/usr/bin/env bash
# Fixture del cierre M3 (ronda 5): el contexto de build de la imagen se produce
# con exportar_contexto_exacto (el MISMO mecanismo de montar.sh) y debe
# contener EXACTAMENTE commit+patches:
#   - el contenido parcheado esta presente,
#   - un archivo UNTRACKED del checkout NO esta,
#   - un archivo IGNORADO por .gitignore (el caso .hermit/ que se colaba con
#     la inspeccion por `git status --porcelain`) NO esta,
#   - drift rastreado en el checkout NO contamina el export.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=lib-contexto.sh
source "$DIR/../scripts/lib-contexto.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fallos=0
ok() { echo "OK  $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos+1)); }

# ── Repo de juguete con commit fijado ────────────────────────────────────────
REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/src"
printf 'linea original\n' > "$REPO/src/codigo.txt"
printf '.hermit/\nartefactos/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm base
COMMIT=$(git -C "$REPO" rev-parse HEAD)

# Patch auditado sobre ese commit
PATCHES="$TMP/patches"
mkdir -p "$PATCHES"
cat > "$PATCHES/01-cambio.patch" <<'EOF'
--- a/src/codigo.txt
+++ b/src/codigo.txt
@@ -1 +1 @@
-linea original
+linea parcheada
EOF

# Contaminacion del checkout: ignorado (el caso .hermit), untracked y drift rastreado
mkdir -p "$REPO/.hermit"
printf 'cache de toolchain\n' > "$REPO/.hermit/colado.txt"
mkdir -p "$REPO/artefactos"
printf 'binario viejo\n' > "$REPO/artefactos/residuo.bin"
printf 'nota suelta\n' > "$REPO/untracked.txt"
printf 'linea original\ndrift local no auditado\n' > "$REPO/src/codigo.txt"

# ── Export ───────────────────────────────────────────────────────────────────
CTX="$TMP/ctx"
mkdir -p "$CTX"
if exportar_contexto_exacto "$REPO" "$COMMIT" "$PATCHES" "$CTX"; then
  ok "export commit+patches completado"
else
  mal "export fallo"; exit 1
fi

if grep -q 'linea parcheada' "$CTX/src/codigo.txt"; then ok "contenido parcheado presente"; else mal "el patch no esta en el contexto"; fi
if grep -q 'drift local' "$CTX/src/codigo.txt"; then mal "el drift rastreado del checkout contamino el export"; else ok "drift rastreado del checkout fuera del contexto"; fi
if [ -e "$CTX/.hermit/colado.txt" ]; then mal "IGNORADO (.hermit) dentro del contexto"; else ok "ignorado .hermit fuera del contexto"; fi
if [ -e "$CTX/artefactos/residuo.bin" ]; then mal "ignorado (artefactos/) dentro del contexto"; else ok "ignorado artefactos/ fuera del contexto"; fi
if [ -e "$CTX/untracked.txt" ]; then mal "untracked dentro del contexto"; else ok "untracked fuera del contexto"; fi
if [ -e "$CTX/.gitignore" ]; then ok ".gitignore rastreado si viaja (esperado)"; fi

# ── Guardas del propio mecanismo ─────────────────────────────────────────────
if exportar_contexto_exacto "$REPO" "$COMMIT" "$PATCHES" "$CTX" 2>/dev/null; then
  mal "acepto un destino NO vacio (reuso de contexto = contaminacion posible)"
else
  ok "rechaza destino no vacio"
fi
PATCH_MALO="$TMP/patches-malos"
mkdir -p "$PATCH_MALO"
cat > "$PATCH_MALO/01-no-aplica.patch" <<'EOF'
--- a/src/codigo.txt
+++ b/src/codigo.txt
@@ -1 +1 @@
-linea que no existe
+otra cosa
EOF
CTX2="$TMP/ctx2"; mkdir -p "$CTX2"
if exportar_contexto_exacto "$REPO" "$COMMIT" "$PATCH_MALO" "$CTX2" 2>/dev/null; then
  mal "acepto un patch que no aplica sobre el commit"
else
  ok "falla cerrado con patch que no aplica"
fi

if [ "$fallos" -eq 0 ]; then echo "probar-contexto-imagen: TODO OK"; else echo "probar-contexto-imagen: $fallos fallos"; exit 1; fi
