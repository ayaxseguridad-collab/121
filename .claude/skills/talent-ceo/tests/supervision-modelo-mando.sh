#!/usr/bin/env bash
# Registro propio del mando; operador sin cuenta ni registro de modelos.
# Ley del lead (7-nov, issue 10264): el revisor es SIEMPRE Codex. El doctor mide el modelo del desarrollo (Claude) y NO mide el
# modelo de un auditor: un auditor que no es Codex da FALLA del auditor (rc 1) y no genera ninguna línea «modelo-auditor».
# shellcheck shell=bash
# shellcheck disable=SC2034 # fixtures compartidos con test-supervision.sh

printf '== modelos del canal: registro propio del mando ==\n'
for caso in coding plan auditor-claude coding-distinto plan-distinto ausente invalido captura codex etiqueta-descripcion; do
  fx_nuevo
  printf '[Sonnet 5]\n' > "$FX/desarrollo.cap"
  printf '501 1 bash\n502 501 codex\n' > "$FX/aud-ps.cont-canal-1"
  audit_cli=codex; dev_cli=claude; esperado_rc=0
  esperado='OK modelo-desarrollo'
  case "$caso" in
    plan) printf '[Opus 4.8]\n' > "$FX/desarrollo.cap" ;;
    auditor-claude)
      printf '501 1 bash\n502 501 claude\n' > "$FX/aud-ps.cont-canal-1"
      audit_cli=claude; esperado_rc=1
      esperado='OK modelo-desarrollo' ;;
    coding-distinto)
      printf '[Sonnet 6]\n' > "$FX/desarrollo.cap"; esperado_rc=1
      esperado='FALLA modelo-desarrollo' ;;
    plan-distinto)
      printf '[Opus 6]\n' > "$FX/desarrollo.cap"; esperado_rc=1
      esperado='FALLA modelo-desarrollo' ;;
    ausente|invalido)
      if [ "$caso" = ausente ]; then rm "$T/home/.config/talent-channel-operation/modelos.conf"
      else printf 'OPUS_MODEL="invalido"\n' > "$T/home/.config/talent-channel-operation/modelos.conf"; fi
      esperado_rc=1
      esperado='NOVERIF modelo-desarrollo: registro del mando ausente o inválido' ;;
    captura)
      rm "$FX/desarrollo.cap"; esperado_rc=1
      esperado='NOVERIF modelo-desarrollo: captura de desarrollo no comprobable' ;;
    codex)
      audit_cli=/opt/bin/codex ;;
    etiqueta-descripcion)
      printf '[Sonnet 6 · anterior Sonnet 5]\n' > "$FX/desarrollo.cap"; esperado_rc=1
      esperado='FALLA modelo-desarrollo' ;;
  esac
  dr TCO_AUDIT_CLI="$audit_cli" TCO_DEV_CLI="$dev_cli"
  assert_eq "canal $caso rc" "$esperado_rc" "$RC"
  # Los mensajes de NOVERIF deben ser exactos, sin pedir resolución al operador.
  # Conserva la categoría antes de retirar el prefijo de la línea. Nunca aparece «modelo-auditor».
  observado="$(printf '%s\n' "$OUT" | awk '$2 ~ /^modelo-(auditor|desarrollo)$/ { categoria=$2; if ($1=="NOVERIF") { sub(/^[^:]*: /, ""); print "NOVERIF " categoria ": " $0 } else print $1 " " $2 }' | paste -sd '|' -)"
  assert_eq "canal $caso categorías y diagnóstico" "$esperado" "$observado"
  assert_eq "canal $caso sudo no lee registros del operador sin registro" '0|sin-registro' \
    "$(grep -Ec '^bin\|.*(lib-modelos|tco_modelo_read|modelos.conf)' "$FX/sudo.log")|$(if [ ! -e "$RUN/homes/bin/.config/talent-channel-operation/modelos.conf" ]; then echo sin-registro; else echo con-registro; fi)"
done
assert_eq 'modelos del canal conservan solo lectura' 0 "$READONLY_FAIL"
