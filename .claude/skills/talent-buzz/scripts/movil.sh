#!/usr/bin/env bash
# Fase movil (Entrega 2): construye el APK Android de Buzz desde el export
# limpio de pin+patches (misma doctrina M3 que la imagen del relay: el APK no
# sale del checkout de trabajo) e inyecta la autoridad de trafico en claro.
#
#   movil.sh construir --host <magicdns> --build-number N \
#       [--ip <ip-tailnet>]... [--fuente <repo-git>]
#   movil.sh portal [--puerto N]
#
# --host se ACREDITA (M11): *.ts.net y resolucion integra en 100.64.0.0/10;
# --build-number es obligatorio y debe subir en cada build distribuida.
#
# La UNICA fuente del host autorizado es --host: movil.sh la inyecta a la vez
# en la constante Dart (RelayUrlPolicy) y en network_security_config.xml, y
# despues VERIFICA sobre el APK final que el placeholder no sobrevivio y que
# el manifest referencia el network security config. Firma con keystore
# propio que nace 0600; el MISMO keystore debe firmar todas las builds
# futuras (Android rechaza actualizaciones con otra firma): respaldalo.
set -euo pipefail
umask 077   # secretos (keystore, signing.env) 0600 de nacimiento
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$DIR/../assets"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=00-config.sh
source "$DIR/00-config.sh"
# shellcheck source=SCRIPTDIR/lib-contexto.sh
source "$DIR/lib-contexto.sh"
# shellcheck source=SCRIPTDIR/lib-seguridad.sh
source "$DIR/lib-seguridad.sh"

PLACEHOLDER="TB_CLEARTEXT_HOST_PLACEHOLDER"
SIGNING_ENV="${TB_MOVIL_SIGNING_ENV:-$TB_HOME/android-signing.env}"
KEYSTORE="${TB_MOVIL_KEYSTORE:-$TB_HOME/android-upload.keystore}"
KEY_ALIAS="${TB_MOVIL_KEY_ALIAS:-buzz-upload}"
SALIDA_DIR="${TB_MOVIL_SALIDA:-$TB_HOME/movil}"

log() { printf '\n== %s ==\n' "$*"; }
fatal() { echo "FATAL: $*" >&2; exit 1; }

ip_tailnet_valida() { # 100.64.0.0/10
  local ip="$1" a b c d
  # Exactamente 4 octetos decimales; base 10 forzada (10#) para que un cero
  # inicial no se interprete como octal ni reviente la comparacion.
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] \
    && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

host_valido() { # MagicDNS exacto: minusculas, sin guion bajo (la guarda
  # fail-closed de RelayUrlPolicy descarta cualquier "autorizado" con '_',
  # que es como se neutraliza un placeholder sin sustituir)
  [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

host_acreditado() { # el host debe ACREDITARSE como MagicDNS del tailnet
  # (M11): --host autoriza cleartext en las dos capas, asi que un dominio
  # publico aqui rompe la frontera entera. Se exige (a) nombre MagicDNS
  # (*.ts.net) y (b) que TODAS sus IPv4 resuelvan dentro de 100.64.0.0/10.
  # Sin resolucion no hay acreditacion: fail-closed.
  local host="$1" ips ip
  case "$host" in
    *.ts.net) ;;
    *) echo "host_acreditado: '$host' no es un nombre MagicDNS (*.ts.net)" >&2; return 1 ;;
  esac
  ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)" || true
  if [ -z "$ips" ]; then
    echo "host_acreditado: '$host' no resuelve desde esta maquina (¿tailscale con MagicDNS activo?)" >&2
    return 1
  fi
  while IFS= read -r ip; do
    if ! ip_tailnet_valida "$ip"; then
      echo "host_acreditado: '$host' resuelve a $ip, fuera de 100.64.0.0/10" >&2
      return 1
    fi
  done <<<"$ips"
}

# exigir_0600 vive en lib-seguridad.sh (compartido con montar.sh).

# inyectar_autoridad <export_dir> <host> [ip-tailnet]...
# Sustituye el placeholder en las DOS capas (constante Dart + network
# security config) desde la MISMA fuente, y falla cerrado si el placeholder
# no aparece exactamente una vez por fichero o si sobrevive alguno.
inyectar_autoridad() {
  local export_dir="$1" host="$2"; shift 2
  local dart_policy="$export_dir/mobile/lib/shared/relay/relay_url_policy.dart"
  local nsc="$export_dir/mobile/android/app/src/main/res/xml/network_security_config.xml"
  [ -f "$dart_policy" ] || { echo "inyectar_autoridad: falta relay_url_policy.dart (¿patch 02 aplicado?)" >&2; return 1; }
  [ -f "$nsc" ] || { echo "inyectar_autoridad: falta network_security_config.xml (¿patch 02 aplicado?)" >&2; return 1; }
  # El placeholder debe aparecer EXACTAMENTE una vez en cada fichero antes de
  # sustituir: mas de una (o cero) delata un patch desalineado.
  [ "$(grep -c "$PLACEHOLDER" "$dart_policy")" -eq 1 ] \
    || { echo "inyectar_autoridad: placeholder != 1 en relay_url_policy.dart" >&2; return 1; }
  [ "$(grep -c "$PLACEHOLDER" "$nsc")" -eq 1 ] \
    || { echo "inyectar_autoridad: placeholder != 1 en network_security_config.xml" >&2; return 1; }
  sed -i "s/$PLACEHOLDER/$host/" "$dart_policy" "$nsc"
  # El network security config de Android no expresa rangos CIDR: si vas a
  # emparejar contra una IP del tailnet en vez del nombre MagicDNS, esa IP
  # exacta se declara aqui (la politica Dart ya cubre 100.64/10).
  local ip
  for ip in "$@"; do
    [ -z "$ip" ] && continue
    sed -i "s|\(.*\)<domain includeSubdomains=\"false\">$host</domain>|&\n\1<domain includeSubdomains=\"false\">$ip</domain>|" "$nsc"
    # Un sed que no matchea NO falla: se verifica que la IP quedo de verdad
    # en el config, o la capa de plataforma la rechazaria en silencio.
    grep -q ">$ip<" "$nsc" || {
      echo "inyectar_autoridad: la IP $ip no quedo insertada en network_security_config.xml" >&2
      return 1
    }
  done
  if grep -q "$PLACEHOLDER" "$dart_policy" "$nsc"; then
    echo "inyectar_autoridad: la sustitucion dejo placeholders vivos" >&2
    return 1
  fi
  return 0
}

detectar_android_sdk() {
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ]; then return 0; fi
  if [ -d "$HOME/Android/Sdk" ]; then export ANDROID_HOME="$HOME/Android/Sdk"; return 0; fi
  fatal "no encuentro el Android SDK: exporta ANDROID_HOME o instala en ~/Android/Sdk"
}

# ── portal: sirve el APK SOLO en la IP del tailnet ──────────────────────────
portal() {
  local puerto="${TB_MOVIL_PORTAL_PORT:-8099}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --puerto) [ $# -ge 2 ] || fatal "portal: $1 requiere un valor"; puerto="$2"; shift 2 ;;
      *) fatal "portal: argumento desconocido $1" ;;
    esac
  done
  command -v tailscale >/dev/null || fatal "portal: requiere tailscale (el APK solo se sirve dentro del tailnet)"
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$ts_ip" ] || fatal "portal: sin IP de tailnet (tailscale up primero)"
  ip_tailnet_valida "$ts_ip" \
    || fatal "portal: '$ts_ip' no esta en 100.64.0.0/10 — no abro el portal en una IP que no sea del tailnet"
  ls "$SALIDA_DIR"/*.apk >/dev/null 2>&1 || fatal "portal: no hay APK en $SALIDA_DIR (corre 'movil.sh construir' antes)"
  # El bind es EXCLUSIVAMENTE la IP del tailnet: desde la LAN no responde
  # (misma frontera M2 que el relay). El transporte lo cifra WireGuard.
  echo "sirviendo $SALIDA_DIR en http://$ts_ip:$puerto/ — descarga el .apk desde el movil (Ctrl-C para parar)"
  exec python3 -m http.server --bind "$ts_ip" --directory "$SALIDA_DIR" "$puerto"
}

# ── construir ───────────────────────────────────────────────────────────────
construir() {
  local host="" build_number="" fuente="${TB_BUZZ_GIT:-$TB_SRC}"
  local -a ips_extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --host|--ip|--build-number|--fuente)
        [ $# -ge 2 ] || fatal "construir: $1 requiere un valor" ;;
    esac
    case "$1" in
      --host) host="$2"; shift 2 ;;
      --ip) ips_extra+=("$2"); shift 2 ;;
      --build-number) build_number="$2"; shift 2 ;;
      --fuente) fuente="$2"; shift 2 ;;
      *) fatal "construir: argumento desconocido $1" ;;
    esac
  done

  [ -n "$host" ] || fatal "construir: falta --host <magicdns-exacto> (p. ej. maquina.tu-tailnet.ts.net)"
  host_valido "$host" \
    || fatal "construir: host invalido '$host' (minusculas, digitos, punto y guion; sin guion bajo)"
  host_acreditado "$host" \
    || fatal "construir: '$host' no se acredita como MagicDNS del tailnet — no autorizo cleartext hacia el"
  local ip
  for ip in "${ips_extra[@]:-}"; do
    [ -z "$ip" ] && continue
    ip_tailnet_valida "$ip" || fatal "construir: --ip $ip no esta en 100.64.0.0/10 (el rango del tailnet)"
  done
  # Obligatorio: sin versionCode creciente Android no actualiza, y un build
  # "por defecto" repetiria el del APK anterior sin que nadie lo note.
  [ -n "$build_number" ] || fatal "construir: falta --build-number <N> (debe SUBIR en cada build que distribuyas)"
  [[ "$build_number" =~ ^[0-9]+$ ]] || fatal "construir: --build-number debe ser entero"

  for c in git tar unzip keytool python3 strings; do
    command -v "$c" >/dev/null || fatal "construir: falta el comando $c"
  done
  detectar_android_sdk

  # Fuente del arbol pinneado (checkout de montar.sh, repo local o clone).
  if [ ! -d "$fuente/.git" ] || ! git -C "$fuente" cat-file -e "$TB_BUZZ_COMMIT^{commit}" 2>/dev/null; then
    log "clonando $TB_BUZZ_REPO_URL (no hay repo local con $TB_BUZZ_COMMIT)"
    fuente="$SALIDA_DIR/buzz-src-movil"
    if [ ! -d "$fuente/.git" ]; then
      mkdir -p "$fuente"
      git init -q "$fuente"
      git -C "$fuente" remote add origin "$TB_BUZZ_REPO_URL"
    fi
    git -C "$fuente" fetch -q --depth 1 origin "$TB_BUZZ_COMMIT"
  fi

  # ── Export limpio M3 + inyeccion de la autoridad ──────────────────────────
  local export_dir
  export_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$export_dir'" EXIT
  log "export limpio de $TB_BUZZ_COMMIT + patches"
  exportar_contexto_exacto "$fuente" "$TB_BUZZ_COMMIT" "$ASSETS/patches" "$export_dir" \
    || fatal "el export limpio fallo (¿patches no aplican sobre $TB_BUZZ_COMMIT?)"

  log "inyectando autoridad de cleartext: $host${ips_extra[0]:+ + IPs ${ips_extra[*]}}"
  inyectar_autoridad "$export_dir" "$host" "${ips_extra[@]:-}" \
    || fatal "la inyeccion de la autoridad fallo"

  # ── Keystore propio (0600 de nacimiento; el mismo para SIEMPRE) ───────────
  if [ -f "$SIGNING_ENV" ]; then
    log "firma: reutilizando $SIGNING_ENV (mismo keystore = las instalaciones actualizan)"
    # M12: los secretos reutilizados se verifican ANTES de tocarlos — un
    # backup que los dejara legibles por otros no se acepta en silencio.
    exigir_0600 "$SIGNING_ENV" || fatal "firma: $SIGNING_ENV no pasa la verificacion de secreto (0600, propietario)"
    # shellcheck source=/dev/null
    source "$SIGNING_ENV"
  else
    log "firma: generando keystore nuevo en $KEYSTORE"
    [ -f "$KEYSTORE" ] && fatal "existe $KEYSTORE pero no $SIGNING_ENV: no lo piso; recupera o retira el keystore"
    mkdir -p "$(dirname "$KEYSTORE")"
    local pass
    pass="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    keytool -genkeypair -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
      -keyalg RSA -keysize 4096 -validity 10000 \
      -storepass "$pass" -keypass "$pass" \
      -dname "CN=talent-buzz upload" >/dev/null
    cat > "$SIGNING_ENV" <<EOF
BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH=$KEYSTORE
BUZZ_ANDROID_UPLOAD_KEYSTORE_PASSWORD=$pass
BUZZ_ANDROID_UPLOAD_KEY_ALIAS=$KEY_ALIAS
BUZZ_ANDROID_UPLOAD_KEY_PASSWORD=$pass
EOF
    # shellcheck source=/dev/null
    source "$SIGNING_ENV"
    echo "keystore y $SIGNING_ENV creados (0600). RESPALDALOS: sin este keystore no hay actualizaciones, solo reinstalar."
  fi
  [ -f "$BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH" ] || fatal "el keystore de $SIGNING_ENV no existe: $BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH"
  exigir_0600 "$BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH" \
    || fatal "firma: el keystore no pasa la verificacion de secreto (0600, propietario)"
  export BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH BUZZ_ANDROID_UPLOAD_KEYSTORE_PASSWORD \
    BUZZ_ANDROID_UPLOAD_KEY_ALIAS BUZZ_ANDROID_UPLOAD_KEY_PASSWORD

  # ── Build (toolchain hermit del propio arbol) ─────────────────────────────
  log "flutter build apk --release"
  local -a build_args=(build apk --release)
  [ -n "$build_number" ] && build_args+=(--build-number "$build_number")
  (cd "$export_dir/mobile" && ../bin/flutter "${build_args[@]}")
  local apk="$export_dir/mobile/build/app/outputs/flutter-apk/app-release.apk"
  [ -f "$apk" ] || fatal "no aparecio $apk"

  # ── Verificacion del APK final (fail-closed) ──────────────────────────────
  # Ninguna comprobacion usa lectores que corten el pipe temprano (-q/head):
  # bajo pipefail un SIGPIPE del productor devolveria 141 y un `if` lo
  # confundiria con "no encontrado" — un falso limpio (misma familia que el
  # subshell del gate M5, ronda 4). Se cuenta hasta EOF o se lee de fichero.
  log "verificacion del APK"
  # V1: el placeholder NO sobrevive en ningun byte del APK. La extraccion se
  # separa del conteo: si unzip fallara dentro del pipe, el grep contaria 0
  # sobre un flujo truncado y el `|| true` lo taparia — V1 diria OK sin
  # haber leido el APK (finding CodeRabbit r-E2).
  local hits apk_contenido="$export_dir/apk-contenido.bin"
  unzip -p "$apk" > "$apk_contenido" || fatal "V1: no pude leer el contenido del APK"
  hits="$(grep -a -c "$PLACEHOLDER" "$apk_contenido" || true)"
  rm -f "$apk_contenido"
  [ "$hits" -eq 0 ] || fatal "V1: el APK contiene el placeholder sin sustituir ($hits hits)"
  echo "V1 OK: placeholder ausente del APK"

  # V2: el manifest fusionado DE LA APP referencia el network security
  # config. Se busca bajo build/app: el build tambien fusiona manifests de
  # cada libreria Flutter y el primero que devuelva un find global seria el
  # de una libreria (falso rojo cazado en el primer build real).
  local manifest
  manifest="$(find "$export_dir/mobile/build/app" -path '*merged_manifests*' -name AndroidManifest.xml -print -quit)"
  [ -n "$manifest" ] || fatal "V2: no encuentro el manifest fusionado en build/"
  grep -q 'networkSecurityConfig="@xml/network_security_config"' "$manifest" \
    || fatal "V2: el manifest fusionado no referencia network_security_config"
  if grep -q 'usesCleartextTraffic="true"' "$manifest"; then
    fatal "V2: el manifest fusionado permite cleartext global"
  fi
  echo "V2 OK: manifest con network_security_config y sin cleartext global"

  # V3: el host inyectado esta en los RECURSOS del APK. La optimizacion de
  # recursos de AGP renombra res/xml/network_security_config.xml a una ruta
  # corta (falso rojo cazado en el segundo build real), asi que se extrae
  # res/ entero y se busca el host en cualquier recurso — el unico recurso
  # que lo lleva es el network security config, y V2 ya probo que el
  # manifest lo referencia. El XML binario guarda strings en UTF-8 o
  # UTF-16: se prueban ambas, siempre sobre ficheros (sin cortes de pipe).
  local res_dir="$export_dir/res-del-apk" v3_hit=""
  mkdir -p "$res_dir"
  unzip -q "$apk" 'res/*' -d "$res_dir" || fatal "V3: no pude extraer res/ del APK"
  v3_hit="$(grep -r -a -l "$host" "$res_dir" || true)"
  if [ -z "$v3_hit" ]; then
    local f
    while IFS= read -r -d '' f; do
      if strings -e l "$f" 2>/dev/null | grep -c "$host" | grep -qv '^0$'; then
        v3_hit="$f"; break
      fi
    done < <(find "$res_dir" -type f -print0)
  fi
  [ -n "$v3_hit" ] || fatal "V3: '$host' no aparece en ningun recurso del APK"
  # Primer hit sin lectores tempranos de pipe (coherencia con la doctrina).
  local v3_primero="${v3_hit%%$'\n'*}"
  echo "V3 OK: '$host' presente en los recursos del APK ($(basename "$v3_primero"))"
  # V3b: cada --ip declarada tambien debe estar en los recursos finales — la
  # capa de plataforma no expresa CIDR y una IP que se cayo del config
  # rechazaria el cleartext hacia ella en runtime (finding CodeRabbit r-E2).
  for ip in "${ips_extra[@]:-}"; do
    [ -z "$ip" ] && continue
    v3_hit="$(grep -r -a -l "$ip" "$res_dir" || true)"
    if [ -z "$v3_hit" ]; then
      while IFS= read -r -d '' f; do
        if strings -e l "$f" 2>/dev/null | grep -c "$ip" | grep -qv '^0$'; then
          v3_hit="$f"; break
        fi
      done < <(find "$res_dir" -type f -print0)
    fi
    [ -n "$v3_hit" ] || fatal "V3b: la IP '$ip' no aparece en los recursos del APK"
    echo "V3b OK: '$ip' presente en los recursos del APK"
  done

  # V4: la firma del APK es la huella del certificado del keystore propio.
  local huella_ks huella_apk apksigner certs
  huella_ks="$(keytool -exportcert -alias "$BUZZ_ANDROID_UPLOAD_KEY_ALIAS" \
      -keystore "$BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH" \
      -storepass "$BUZZ_ANDROID_UPLOAD_KEYSTORE_PASSWORD" 2>/dev/null \
    | sha256sum | cut -d' ' -f1)"
  apksigner="$(find "$ANDROID_HOME/build-tools" -name apksigner -print 2>/dev/null | sort | tail -1)"
  if [ -n "$apksigner" ]; then
    certs="$("$apksigner" verify --print-certs "$apk" 2>/dev/null || true)"
    huella_apk="$(awk 'tolower($0) ~ /certificate sha-256/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{32,}$/) { print $i; exit }
      }' <<<"$certs")"
  else
    certs="$(keytool -printcert -jarfile "$apk" 2>/dev/null || true)"
    huella_apk="$(awk '/SHA256:/ { sub(/.*SHA256: */, ""); gsub(/:/, ""); print tolower($0); exit }' <<<"$certs")"
  fi
  [ -n "$huella_apk" ] || fatal "V4: no pude extraer la huella del certificado del APK"
  [ "$huella_ks" = "$huella_apk" ] || fatal "V4: la firma del APK no es la del keystore propio"
  echo "V4 OK: APK firmado con el keystore propio ($BUZZ_ANDROID_UPLOAD_KEY_ALIAS)"

  # ── Entrega ───────────────────────────────────────────────────────────────
  mkdir -p "$SALIDA_DIR"
  local version destino
  version="$(grep '^version:' "$export_dir/mobile/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
  destino="$SALIDA_DIR/buzz-movil-${version}${build_number:+-b$build_number}-$host.apk"
  install -m 0644 "$apk" "$destino"
  log "APK listo"
  echo "  $destino"
  echo "Siguiente: 'movil.sh portal' para servirlo SOLO dentro del tailnet, y"
  echo "el pairing con Buzz Desktop 0.5.1 (references/movil.md)."
}

# Guard de source (misma leccion que genkeys.py, INV-TB-002): sourcearlo para
# tests jamas ejecuta nada.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    construir) shift; construir "$@" ;;
    portal) shift; portal "$@" ;;
    *) sed -n '2,21p' "$0"; exit 1 ;;
  esac
fi
