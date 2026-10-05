#!/usr/bin/env bash
set -euo pipefail

# --- Configuracao ---
APP_DIR="/opt/ufla-shop"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Pre-requisito: rodar como root ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Rode com sudo: sudo $0" >&2
  exit 1
fi

# --- Pacotes do sistema ---
apt-get update -qq
apt-get install -y -qq python3-venv postgresql redis-server rsync nginx curl openssl

# --- Usuario de sistema da aplicacao ---
id ufla-shop > /dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin ufla-shop

# --- Codigo em /opt ---
mkdir -p "${APP_DIR}"
rsync -a --delete --chown=root:root --exclude '.git' --exclude '.venv' "${REPO_DIR}/" "${APP_DIR}/"

# --- Ambiente Python ---
cd "${APP_DIR}"
python3 -m venv --upgrade-deps .venv
.venv/bin/pip install -qr requirements.txt

# --- Configuracao e segredos (ANTES de subir o servico) ---
cp "${REPO_DIR}/ufla-shop.env.example" /etc/ufla-shop.env.example
[ -f /etc/ufla-shop.env ] || cp /etc/ufla-shop.env.example /etc/ufla-shop.env
chmod 600 /etc/ufla-shop.env

if grep -q "troque-esta-senha" /etc/ufla-shop.env; then
  echo "AVISO: /etc/ufla-shop.env usa a senha de exemplo. Troque-a fora de ambiente de teste." >&2
fi

# --- Banco: garante usuario e base com a senha do .env ---
# o arquivo so existe no servidor, entao o ShellCheck nao tem como segui-lo
# shellcheck source=/dev/null
source /etc/ufla-shop.env
SENHA="${DATABASE_URL#*://*:}"
SENHA="${SENHA%%@*}"

existe_role=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='loja'")
[ "${existe_role}" = "1" ] || sudo -u postgres psql -qc "CREATE USER loja"
sudo -u postgres psql -qc "ALTER USER loja WITH PASSWORD '${SENHA}'"

existe_db=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='loja'")
[ "${existe_db}" = "1" ] || sudo -u postgres createdb -O loja loja

# --- Units do systemd ---
cp "${REPO_DIR}"/systemd/ufla-shop.service \
   "${REPO_DIR}"/systemd/ufla-shop-backup.service \
   "${REPO_DIR}"/systemd/ufla-shop-backup.timer \
   /etc/systemd/system/
systemctl daemon-reload

systemctl enable ufla-shop
systemctl restart ufla-shop
systemctl enable --now ufla-shop-backup.timer

# --- Nginx: certificado, site e recarga ---
mkdir -p /etc/nginx/ssl
[ -f /etc/nginx/ssl/loja.key ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/loja.key -out /etc/nginx/ssl/loja.crt \
  -subj "/CN=localhost"
chmod 600 /etc/nginx/ssl/loja.key

cp "${REPO_DIR}/nginx/loja.conf" /etc/nginx/sites-available/loja
ln -sfn /etc/nginx/sites-available/loja /etc/nginx/sites-enabled/loja
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# --- Healthcheck ---
if curl -fsS --retry 9 --retry-delay 1 --retry-connrefused \
     http://localhost:8000/ready > /dev/null; then
  echo "Deploy concluido: /ready respondeu"
else
  echo "ERRO: /ready nao respondeu apos 10 tentativas" >&2
  exit 1
fi