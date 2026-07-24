#!/usr/bin/env bash
# One-time bootstrap to obtain the first Let's Encrypt certificate.
#
# Run this manually on the production host, once, after DNS for the
# domains below already resolves to this host's public IP (Let's Encrypt
# validates ownership over HTTP, so the deploy's regular `docker compose
# pull && up -d` is not enough by itself — nginx needs a certificate to
# even start its 443 server block, which is the chicken-and-egg problem
# this script works around with a throwaway self-signed cert).
#
# After this runs once, the `certbot` service in docker-compose.yml renews
# the real certificate automatically — no need to run this again unless
# the domain list changes.
set -euo pipefail

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

domains=(nerdifica.com www.nerdifica.com)
rsa_key_size=4096
data_path="./certbot"
email="${CERTBOT_EMAIL:?Set CERTBOT_EMAIL (see .env.example) before running this script}"
staging="${STAGING:-0}"

if [ -d "$data_path/conf/live/${domains[0]}" ]; then
  read -r -p "Certificate for ${domains[0]} already exists. Replace it? (y/N) " decision
  if [ "$decision" != "y" ] && [ "$decision" != "Y" ]; then
    exit 0
  fi
fi

echo "### Creating a dummy certificate so nginx can start ..."
mkdir -p "$data_path/conf/live/${domains[0]}"
docker compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1 \
    -keyout '/etc/letsencrypt/live/${domains[0]}/privkey.pem' \
    -out '/etc/letsencrypt/live/${domains[0]}/fullchain.pem' \
    -subj '/CN=localhost'" certbot

echo "### Starting nginx ..."
docker compose up -d nginx

echo "### Deleting the dummy certificate ..."
docker compose run --rm --entrypoint "\
  rm -rf /etc/letsencrypt/live/${domains[0]} \
         /etc/letsencrypt/archive/${domains[0]} \
         /etc/letsencrypt/renewal/${domains[0]}.conf" certbot

domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

staging_arg=""
if [ "$staging" != "0" ]; then
  staging_arg="--staging"
fi

echo "### Requesting the real certificate from Let's Encrypt ..."
docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $domain_args \
    --email $email \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --no-eff-email \
    --force-renewal" certbot

echo "### Reloading nginx ..."
docker compose exec nginx nginx -s reload