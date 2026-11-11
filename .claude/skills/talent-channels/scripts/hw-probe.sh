#!/usr/bin/env bash
# Perfil de hardware de un carril (cross-platform macOS / Linux).
# Uso: hw-probe.sh <ID>   (p. ej.  hw-probe.sh E9)
ID="${1:?uso: hw-probe.sh <ID> (p. ej. E9)}"
OS="$(uname -s)"; ARCH="$(uname -m)"
echo "## HARDWARE — carril ${ID}"
echo "- Arquitectura: ${ARCH}"
if [ "$OS" = "Darwin" ]; then
  echo "- SO: macOS $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
  echo "- Equipo: $(sysctl -n hw.model)"
  CHIP="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2; exit}')"
  [ -z "$CHIP" ] && CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "- Chip/CPU: ${CHIP}"
  echo "- Núcleos CPU: $(sysctl -n hw.physicalcpu) físicos / $(sysctl -n hw.logicalcpu) lógicos"
  echo "- RAM: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  echo "- GPU: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{m=$2} /Total Number of Cores/{c=$2} END{print m" ("c" GPU cores)"}')"
  echo "- Disco /: $(df -h / | awk 'NR==2{print $4" libres / "$2}')"
  echo "- mlx-whisper: $([ "$ARCH" = "arm64" ] && echo 'sí (Apple Silicon)' || echo 'no (Intel)')"
else
  # shellcheck source=/dev/null
  echo "- SO: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}") · kernel $(uname -r)"
  CPU="$(LC_ALL=C lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')"
  [ -z "$CPU" ] && CPU="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  echo "- Chip/CPU: ${CPU:-?}"
  PHYS="$(LC_ALL=C lscpu 2>/dev/null | awk -F': +' '/^Core\(s\) per socket/{c=$2}/^Socket\(s\)/{s=$2}END{if(c&&s)print c*s}')"
  [ -z "$PHYS" ] && PHYS="$(awk -F': ' '/^physical id/{p=$2}/^core id/{seen[p":"$2]=1}END{for(k in seen)n++; print n+0}' /proc/cpuinfo 2>/dev/null)"
  echo "- Núcleos CPU: ${PHYS:-?} físicos / $(nproc --all) lógicos"
  echo "- RAM: $(free -g 2>/dev/null | awk '/Mem:/{print $2}') GB"
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "- GPU: $(timeout 5 nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | paste -sd'; ' -)"
  else
    echo "- GPU: $(LC_ALL=C lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/.*: //' | paste -sd'; ' - || echo 'n/d')"
  fi
  echo "- Disco /: $(df -h / | awk 'NR==2{print $4" libres / "$2}')"
  echo "- mlx-whisper: no (no es Apple Silicon)"
fi
