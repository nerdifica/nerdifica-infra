#!/usr/bin/env bash
# One-time bootstrap to obtain the first real Let's Encrypt certificate.
#
# Run this manually on the production host, once, after DNS for the
# domains below already resolves to this host's public IP (Let's Encrypt
# validates ownership over HTTP). `docker compose up -d` alone is safe to
# run before this — the `cert-init` service in docker-compose.yml already
# guarantees nginx has *a* certificate (a throwaway self-signed one) to
# start with; this script replaces it with the real thing.
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
email="${CERTBOT_EMAIL:?Set CERTBOT_EMAIL (see .env.example) before running this script}"
staging="${STAGING:-0}"

echo "### Making sure nginx and its dependencies are up ..."
docker compose up -d

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