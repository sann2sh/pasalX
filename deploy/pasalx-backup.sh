#!/usr/bin/env bash
set -euo pipefail
umask 077

BACKUP_DIR="/var/backups/pasalx"
PASS_FILE="/etc/pasalx/backup.pass"
ENV_FILE="/etc/pasalx/pasalx.env"
ADMIN_BIN="/opt/pasalx/current/pasalx-admin"
RETENTION_DAYS=7
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${BACKUP_DIR}/pasalx_${TS}.dump.gpg"

if [[ ! -r "${PASS_FILE}" ]]; then
  echo "Missing backup passphrase file: ${PASS_FILE}" >&2
  exit 1
fi

# Purge closed stores whose 30-day retention window has elapsed (Task 2.8)
if [[ -x "${ADMIN_BIN}" && -r "${ENV_FILE}" ]]; then
  (
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    "${ADMIN_BIN}" purge-closed-stores
  ) || echo "Warning: purge-closed-stores failed; continuing backup" >&2
fi

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Run pg_dump as postgres user and encrypt symmetrically with AES-256
sudo -u postgres pg_dump -Fc pasalx_db \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "${PASS_FILE}" -o "${OUT_FILE}.tmp"

mv "${OUT_FILE}.tmp" "${OUT_FILE}"
chmod 600 "${OUT_FILE}"

# Prune backups older than retention window
find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'pasalx_*.dump.gpg' -mtime "+${RETENTION_DAYS}" -delete

echo "Backup completed: ${OUT_FILE} ($(stat -c%s "${OUT_FILE}") bytes)"

