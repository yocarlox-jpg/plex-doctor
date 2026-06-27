#!/usr/bin/env bash

set -euo pipefail

PACKAGES=(
  smartmontools
  sysstat
  lm-sensors
  ethtool
)

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Ejecuta este instalador con sudo:"
  echo "sudo bash install.sh"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Este instalador está pensado para Ubuntu/Debian con apt-get."
  exit 1
fi

echo "Instalando dependencias opcionales para plex-doctor:"
printf -- "- %s\n" "${PACKAGES[@]}"
echo

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

echo
echo "Listo. Ahora puedes ejecutar:"
echo "sudo bash plex-doctor.sh"
