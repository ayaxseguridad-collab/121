#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A&&ok||mal: ok()/mal() nunca fallan (printf+contador); comillas simples deliberadas (patrones literales)
# probar-salvaguarda.sh — el snapshot RESTAURA de verdad (extraccion a destino
# temporal + hashes restaurados == manifiesto), permisos restrictivos, y el
# criterio git es fail-closed (untracked/dirty → snapshot obligatorio).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
# shellcheck source=/dev/null
. "$SKILL/scripts/lib.sh"
PASA=0; FALLA=0
ok()  { echo "  OK    $*"; PASA=$((PASA+1)); }
mal() { echo "  FALLO $*"; FALLA=$((FALLA+1)); }

echo "==== probar-salvaguarda: restauracion + permisos + criterio git ===="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp -r "$HERE/corpus-fake" "$T/corpus"

# 1. crear salvaguarda
bash "$SKILL/scripts/salvaguarda.sh" "$T/corpus" "$T/snap" >/dev/null 2>&1
TAR="$(find "$T/snap" -name 'snapshot-*.tar.gz' | head -1)"
[ -n "$TAR" ] && [ -f "$T/snap/manifest.txt" ] && ok "snapshot + manifiesto creados" || mal "faltan snapshot/manifiesto"

# 2. permisos restrictivos
perms_dir="$(stat -c %a "$T/snap" 2>/dev/null || stat -f %Lp "$T/snap")"
perms_tar="$(stat -c %a "$TAR" 2>/dev/null || stat -f %Lp "$TAR")"
[ "$perms_dir" = "700" ] && ok "directorio 700" || mal "directorio con permisos $perms_dir"
[ "$perms_tar" = "600" ] && ok "tar 600" || mal "tar con permisos $perms_tar"

# 3. EXTRACCION a destino temporal + hashes restaurados == manifiesto
mkdir "$T/restaurado"
tar -xzf "$TAR" -C "$T/restaurado"
restaurado_manifest="$(tm_manifest "$T/restaurado")"
if [ "$restaurado_manifest" = "$(cat "$T/snap/manifest.txt")" ]; then
  ok "restauracion verificada: hashes restaurados == manifiesto ($(wc -l < "$T/snap/manifest.txt" | tr -d ' ') ficheros)"
else
  mal "los hashes restaurados NO coinciden con el manifiesto"
fi

# 4. no pisa salvaguardas previas
set +e
SAL2="$(bash "$SKILL/scripts/salvaguarda.sh" "$T/corpus" "$T/snap" 2>&1)"; RC2=$?
set -e
[ "$RC2" -ne 0 ] && printf '%s' "$SAL2" | grep -q "ya existe" && ok "no pisa un destino existente (fail-closed)" || mal "piso o acepto un destino existente"

# 5. criterio git fail-closed: untracked → snapshot obligatorio; limpio → git valido
if command -v git >/dev/null 2>&1; then
  mkdir "$T/repo" && cp -r "$HERE/corpus-fake" "$T/repo/memoria"
  git -C "$T/repo" init -q
  git -C "$T/repo" -c user.email=t@t -c user.name=t add memoria
  git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm base
  printf 'nota nueva sin rastrear\n' > "$T/repo/memoria/nota-untracked.md"
  INFO="$(tm_git_baseline "$T/repo/memoria")"
  printf '%s' "$INFO" | grep -q "snapshot-obligatorio: fichero sin rastrear" && ok "git: untracked → snapshot obligatorio" || mal "git: untracked NO forzo snapshot ($INFO)"
  git -C "$T/repo" -c user.email=t@t -c user.name=t add memoria && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm mas
  INFO2="$(tm_git_baseline "$T/repo/memoria")"
  [ "$INFO2" = "git-valido" ] && ok "git: rastreado+limpio+HEAD → baseline valido" || mal "git: limpio no dio valido ($INFO2)"
  printf 'cambio dirty\n' >> "$T/repo/memoria/decision-gestor-paquetes.md"
  INFO3="$(tm_git_baseline "$T/repo/memoria")"
  printf '%s' "$INFO3" | grep -q "snapshot-obligatorio" && ok "git: dirty → snapshot obligatorio" || mal "git: dirty NO forzo snapshot ($INFO3)"
else
  echo "  OMIT  criterio git (git no instalado)"
fi

# 6. M3: destino DENTRO del corpus → exit 2 y CERO delta en el corpus
mkdir "$T/c2" && cp "$HERE"/corpus-fake/*.md "$T/c2/"
antes="$(tm_manifest "$T/c2")"
set +e
SAL3="$(bash "$SKILL/scripts/salvaguarda.sh" "$T/c2" "$T/c2/snap-interno" 2>&1)"; RC3=$?
set -e
despues="$(tm_manifest "$T/c2")"
if [ "$RC3" -eq 2 ] && printf '%s' "$SAL3" | grep -q "DENTRO del corpus"; then
  ok "destino interno rechazado (exit 2)"
else
  mal "destino interno NO rechazado (rc=$RC3)"
fi
[ "$antes" = "$despues" ] && [ ! -e "$T/c2/snap-interno" ] && ok "cero delta en el corpus tras el rechazo" || mal "el intento contamino el corpus"

# 7. M2: symlink en el corpus → exit 2 (fail-closed)
mkdir "$T/c3" && cp "$HERE"/corpus-fake/*.md "$T/c3/"
if ln -s /etc/hostname "$T/c3/enlace.md" 2>/dev/null; then
  set +e
  SAL4="$(bash "$SKILL/scripts/salvaguarda.sh" "$T/c3" "$T/snap3" 2>&1)"; RC4=$?
  set -e
  [ "$RC4" -eq 2 ] && printf '%s' "$SAL4" | grep -q "symlinks no soportados" && ok "symlink → salvaguarda exit 2" || mal "symlink NO rechazado (rc=$RC4)"
else
  echo "  OMIT  symlink (ln no disponible)"
fi

# 8. TOCTOU tar<->manifiesto: shim de `tar` que, TRAS invocar el tar real, muta
# el corpus vivo. Sin staging inmutable el tar (1a lectura) capturaria el
# ANTES y el manifiesto (2a lectura, ya con el corpus mutado) el DESPUES:
# verificar.sh cantaria "intacto OK" sobre un fichero que si cambio. Con el
# fix, tar y manifiesto salen del MISMO artefacto en staging: la mutacion del
# corpus vivo, posterior al staging, no puede colarse en ninguno de los dos.
REAL_TAR="$(command -v tar)"
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/tar" <<SHIM
#!/usr/bin/env bash
"$REAL_TAR" "\$@"
rc=\$?
if [ -n "\${TM_TEST_TOCTOU_CORPUS:-}" ] && [ -f "\$TM_TEST_TOCTOU_CORPUS/decision-gestor-paquetes.md" ]; then
  printf 'MUTACION TOCTOU inyectada tras el tar\n' >> "\$TM_TEST_TOCTOU_CORPUS/decision-gestor-paquetes.md"
fi
exit \$rc
SHIM
chmod +x "$SHIMDIR/tar"

mkdir -p "$T/toctou" && cp -r "$HERE/corpus-fake" "$T/toctou/corpus"
PATH="$SHIMDIR:$PATH" TM_TEST_TOCTOU_CORPUS="$T/toctou/corpus" \
  bash "$SKILL/scripts/salvaguarda.sh" "$T/toctou/corpus" "$T/toctou/snap" >/dev/null 2>&1

TAR_TOCTOU="$(find "$T/toctou/snap" -name 'snapshot-*.tar.gz' | head -1)"
mkdir "$T/toctou/restaurado"
tar -xzf "$TAR_TOCTOU" -C "$T/toctou/restaurado"
manifest_extraido="$(tm_manifest "$T/toctou/restaurado")"
if [ "$manifest_extraido" = "$(cat "$T/toctou/snap/manifest.txt")" ]; then
  ok "TOCTOU: tar y manifiesto describen el MISMO artefacto pese a la mutacion post-tar"
else
  mal "TOCTOU: manifiesto y tar divergen (la mutacion coló en uno solo de los dos)"
fi
rm -rf "$SHIMDIR"

# 9. .git en la raiz del corpus (worktree): NI el tar NI el manifiesto lo arrastran,
# y la exclusion es SIMETRICA — verificar.sh sobre el corpus vivo (que SI tiene .git)
# debe dar VERDE sin cantar los objetos de git como deltas fantasma.
mkdir -p "$T/c4" && cp "$HERE"/corpus-fake/*.md "$T/c4/"
mkdir -p "$T/c4/.git/objects" && printf 'ref: refs/heads/main\n' > "$T/c4/.git/HEAD"
bash "$SKILL/scripts/salvaguarda.sh" "$T/c4" "$T/snap4" >/dev/null 2>&1
TAR4="$(find "$T/snap4" -name 'snapshot-*.tar.gz' | head -1)"
if tar -tzf "$TAR4" | grep -q '\.git/'; then mal ".git se colo en el tar"; else ok ".git excluido del tar"; fi
if grep -q '\.git/' "$T/snap4/manifest.txt"; then mal ".git se colo en el manifiesto"; else ok ".git excluido del manifiesto"; fi
printf 'decision-gestor-paquetes.md\tintacto\t-\n' > "$T/c4.tsv"
set +e
SAL9="$(bash "$SKILL/scripts/verificar.sh" "$T/snap4" "$T/c4" "$T/c4.tsv" 2>&1)"; RC9=$?
set -e
[ "$RC9" -eq 0 ] && ok "simetria: verificar en VERDE con .git presente en el corpus vivo" \
  || { mal "verificar canto deltas fantasma de .git (rc=$RC9)"; printf '%s\n' "$SAL9" | tail -5 | sed 's/^/      | /'; }

# 10. WORKTREE como raiz del corpus: ahi .git es un FICHERO (gitdir:), no un
# directorio — el censo del baseline no debe capturarlo (daba falso "sin rastrear:
# ./.git" y hacia git-valido inalcanzable en worktrees).
if command -v git >/dev/null 2>&1; then
  mkdir "$T/repo2" && cp "$HERE"/corpus-fake/*.md "$T/repo2/"
  git -C "$T/repo2" init -q
  git -C "$T/repo2" -c user.email=t@t -c user.name=t add -A
  git -C "$T/repo2" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$T/repo2" worktree add -q "$T/wt2" -b rama-wt 2>/dev/null
  [ -f "$T/wt2/.git" ] || mal "precondicion: .git del worktree no es fichero"
  INFO_WT="$(tm_git_baseline "$T/wt2")"
  [ "$INFO_WT" = "git-valido" ] && ok "worktree (.git fichero) → baseline git-valido" \
    || mal "worktree: el censo capturo .git ($INFO_WT)"
else
  echo "  OMIT  worktree (git no instalado)"
fi

echo "---- resultado: PASA=$PASA FALLA=$FALLA ----"
[ "$FALLA" -eq 0 ]
