#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${PASALX_SSH_HOST:-pos}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${ROOT_DIR}/server"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

GIT_SHA="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'dev')"
RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-${GIT_SHA}"

echo "==> Cross-compiling pasalx-api and pasalx-admin (${RELEASE_ID})..."
(
  cd "${SERVER_DIR}"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.buildVersion=${RELEASE_ID}" -o "${BUILD_DIR}/pasalx-api" ./cmd/api
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o "${BUILD_DIR}/pasalx-admin" ./cmd/pasalx-admin
)

echo "==> Uploading release ${RELEASE_ID} to ${REMOTE_HOST}..."
ssh -o BatchMode=yes "${REMOTE_HOST}" "mkdir -p /tmp/pasalx-${RELEASE_ID}"
scp -q "${BUILD_DIR}/pasalx-api" "${BUILD_DIR}/pasalx-admin" "${REMOTE_HOST}:/tmp/pasalx-${RELEASE_ID}/"

echo "==> Running migrations & switching release on ${REMOTE_HOST}..."
ssh -o BatchMode=yes "${REMOTE_HOST}" "bash -s" <<EOF
set -euo pipefail
RELEASE_DIR="/opt/pasalx/releases/${RELEASE_ID}"
PREV_TARGET="\$(readlink -f /opt/pasalx/current 2>/dev/null || true)"

sudo mkdir -p "\${RELEASE_DIR}"
sudo mv "/tmp/pasalx-${RELEASE_ID}/pasalx-api" "/tmp/pasalx-${RELEASE_ID}/pasalx-admin" "\${RELEASE_DIR}/"
rmdir "/tmp/pasalx-${RELEASE_ID}" || true
sudo chown -R root:pasalx "\${RELEASE_DIR}"
sudo chmod 0750 "\${RELEASE_DIR}/pasalx-api" "\${RELEASE_DIR}/pasalx-admin"

# Run embedded migrations using owner credentials (never app role)
sudo bash -c 'set -a; source /etc/pasalx/pasalx.env; set +a; "'"\${RELEASE_DIR}"'/pasalx-admin" migrate up'

sudo ln -sfn "\${RELEASE_DIR}" /opt/pasalx/current.next
sudo mv -Tf /opt/pasalx/current.next /opt/pasalx/current
sudo systemctl restart pasalx-api

# Health verification with automatic rollback on failure
for i in {1..15}; do
  if curl -fsS http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
    echo "Health check passed!"
    curl -fsS http://127.0.0.1:8080/api/version
    echo ""
    # Keep last 5 releases
    sudo bash -c 'ls -1dt /opt/pasalx/releases/* 2>/dev/null | tail -n +6 | xargs -r rm -rf'
    exit 0
  fi
  sleep 1
done

echo "Health check failed! Rolling back..." >&2
if [[ -n "\${PREV_TARGET}" && -d "\${PREV_TARGET}" ]]; then
  sudo ln -sfn "\${PREV_TARGET}" /opt/pasalx/current.next
  sudo mv -Tf /opt/pasalx/current.next /opt/pasalx/current
  sudo systemctl restart pasalx-api || true
fi
sudo journalctl -u pasalx-api -n 30 --no-pager >&2
exit 1
EOF

