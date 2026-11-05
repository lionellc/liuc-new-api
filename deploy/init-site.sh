#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077

site_name="${1:?Usage: init-site.sh SITE_NAME https://SITE_DOMAIN}"
site_origin="${2:?Usage: init-site.sh SITE_NAME https://SITE_DOMAIN}"

if [[ ! "$site_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Site name must contain lowercase letters, digits, and hyphens" >&2
  exit 1
fi

if [[ ! "$site_origin" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?$ ]]; then
  echo "Origin must be an HTTPS hostname with an optional port and no path" >&2
  exit 1
fi

if [[ -e node.env || -e app.env ]]; then
  echo "Existing node.env or app.env found; configuration will not be overwritten" >&2
  exit 1
fi

command -v openssl > /dev/null
postgres_password="$(openssl rand -hex 32)"
redis_password="$(openssl rand -hex 32)"
session_secret="$(openssl rand -hex 32)"
crypto_secret="$(openssl rand -hex 32)"
temporary_dir="$(mktemp -d .init-site.XXXXXX)"
trap 'rm -rf "$temporary_dir"' EXIT

sed \
  -e "s/REPLACE_POSTGRES_PASSWORD/$postgres_password/g" \
  -e "s/REPLACE_REDIS_PASSWORD/$redis_password/g" \
  node.env.example > "$temporary_dir/node.env"

sed \
  -e "s/REPLACE_SITE_NAME/$site_name/g" \
  -e "s|REPLACE_SITE_ORIGIN|$site_origin|g" \
  -e "s/REPLACE_SESSION_SECRET/$session_secret/g" \
  -e "s/REPLACE_CRYPTO_SECRET/$crypto_secret/g" \
  app.env.example > "$temporary_dir/app.env"

# Hard links fail rather than replace files created by another initializer.
ln "$temporary_dir/node.env" node.env
ln "$temporary_dir/app.env" app.env
mkdir -p data logs

printf 'Initialized %s for %s\n' "$site_name" "$site_origin"
echo "Check DOCKER_SUBNET/DOCKER_GATEWAY and TRUSTED_PROXIES before deployment."
echo "Keep node.env and app.env backed up; never regenerate existing site secrets."
