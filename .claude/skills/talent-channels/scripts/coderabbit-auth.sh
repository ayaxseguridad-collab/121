#!/usr/bin/env bash
# Método compartido para canal y estación: secreto solo en memoria del shell y fichero 0600.
tc_coderabbit_auth() (
  set +x
  set -euo pipefail
  export PATH="$HOME/.local/bin:$PATH"
  local env_file="$1" key quote temp
  tc_auth_error() { printf 'CodeRabbit: %s; fichero=%s\n' "$1" "$2" >&2; return 1; }
  [ -f "$env_file" ] && [ ! -L "$env_file" ] && [ -O "$env_file" ] && [ "$(stat -c '%a' "$env_file")" = 600 ] || {
    tc_auth_error 'origen ausente, ajeno o modo inseguro' "$env_file"; return 1;
  }
  key="$(grep -m1 '^CODERABBIT_API_KEY=' "$env_file" | cut -d= -f2-)" || key=''
  quote="$(printf '\047')"
  key="${key%\"}"; key="${key#\"}"; key="${key%"$quote"}"; key="${key#"$quote"}"
  [ -n "$key" ] || { tc_auth_error 'clave ausente' "$env_file"; return 1; }
  case "$key" in *\"*|*\\*|*[[:cntrl:]]*) tc_auth_error 'caracteres no serializables' "$env_file"; return 1 ;; esac
  [ ! -L "$HOME/.coderabbit" ] && [ ! -L "$HOME/.coderabbit/auth.json" ] || {
    tc_auth_error 'destino enlazado' "$HOME/.coderabbit/auth.json"; return 1;
  }
  mkdir -p "$HOME/.coderabbit" && chmod 700 "$HOME/.coderabbit" || {
    tc_auth_error 'no se pudo preparar el directorio' "$HOME/.coderabbit"; return 1;
  }
  temp="$(mktemp "$HOME/.coderabbit/.auth.XXXXXX")" || {
    tc_auth_error 'escritura temporal fallida' "$HOME/.coderabbit/auth.json"; return 1;
  }
  trap 'rm -f "$temp"' EXIT
  (umask 077; printf '{"type":"api_key","apiKey":"%s"}\n' "$key" > "$temp") &&
    chmod 600 "$temp" && mv -f "$temp" "$HOME/.coderabbit/auth.json" || {
      tc_auth_error 'escritura de autenticación fallida' "$HOME/.coderabbit/auth.json"; return 1;
    }
  unset key
  timeout 30 coderabbit auth status >/dev/null 2>&1 || {
    tc_auth_error 'estado del CLI no autenticado' "$HOME/.coderabbit/auth.json"; return 1;
  }
)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 1 ] || exit 2
  tc_coderabbit_auth "$1"
fi
