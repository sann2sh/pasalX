#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV="${ROOT_DIR}/.env.prod"
REMOTE_HOST="${PASALX_SSH_HOST:-pos}"

if [[ ! -f "${LOCAL_ENV}" ]]; then
  echo "ERROR: ${LOCAL_ENV} not found." >&2
  exit 1
fi

echo "==> Installing /etc/pasalx/pasalx.env over SSH stdin and restarting pasalx-api..."
ssh "${REMOTE_HOST}" '
  set -euo pipefail
  umask 077
  sudo -n install -m 0640 -o root -g pasalx /dev/stdin /etc/pasalx/pasalx.env.tmp
  sudo -n mv -f /etc/pasalx/pasalx.env.tmp /etc/pasalx/pasalx.env
  sudo -n systemctl restart pasalx-api
  sleep 1
  sudo -n systemctl is-active --quiet pasalx-api
  curl -fsS http://127.0.0.1:8080/api/health
  echo ""
' < "${LOCAL_ENV}"

echo "==> Done."
