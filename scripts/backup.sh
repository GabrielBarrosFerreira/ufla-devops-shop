#!/usr/bin/env bash
set -euo pipefail
umask 077

DIR_BACKUP="/var/backups/ufla-shop/"
ARQUIVO="${DIR_BACKUP}loja-$(date +%Y-%m-%d-%H%M).sql.gz"

mkdir -p "$DIR_BACKUP"

trap 'rm -f "${ARQUIVO}.tmp"' EXIT
pg_dump "${DATABASE_URL:?DATABASE_URL nao definida}" | gzip > "${ARQUIVO}.tmp"
mv "${ARQUIVO}.tmp" "${ARQUIVO}"

TAMANHO=$(du -h "${ARQUIVO}" | cut -f1)
logger -t backup "Backup gerado: ${ARQUIVO} (${TAMANHO})"

# rotacao: mantem os 7 mais recentes. O ls e seguro aqui porque os nomes sao
# gerados pelo proprio script (loja-AAAA-MM-DD-HHMM.sql.gz, sem espacos)
# shellcheck disable=SC2012
ls -1tr "${DIR_BACKUP}"/loja-*.sql.gz | head -n -7 | xargs -r rm --