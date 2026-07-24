#!/usr/bin/env bash
# Requests a real Let's Encrypt certificate if one isn't already in place.
#
# Safe to run on every deploy (and the infra deploy.yml does): by default
# this uses --keep-until-expiring, so certbot only talks to Let's Encrypt
# the first time (or once the cert is actually close to expiry) — every
# other run is a fast local no-op. Don't change that to --force-renewal for
# routine use, it'll burn through Let's Encrypt's ~5-duplicate-certs-per-week
# rate limit after a handful of deploys.
#
# CERTBOT_EMAIL can come from the environment (the deploy pipeline passes it
# from a GitHub secret) or from a local .env file for manual runs.
#
# To force a fresh certificate (e.g. after changing the domain list), run
# with FORCE=1 ./ensure-cert.sh instead.
set -euo pipefail

if [ -z "${CERTBOT_EMAIL:-}" ] && [ -f .env ]; then
  set -a
  source .env
  set +a
fi

domains=(nerdifica.com www.nerdifica.com)
email="${CERTBOT_EMAIL:?Set CERTBOT_EMAIL (env var, GitHub secret, or .env — see .env.example)}"
staging="${STAGING:-0}"
force="${FORCE:-0}"

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

renewal_arg="--keep-until-expiring"
if [ "$force" != "0" ]; then
  renewal_arg="--force-renewal"
fi

# cert-init (docker-compose.yml) writes a throwaway self-signed cert (CN=
# localhost) straight into live/<domain> so nginx always has something to
# start with. Certbot won't reuse that path for a real lineage unless we
# clear it first — checking the cert's own issuer is what actually tells us
# it's the dummy (a missing renewal config isn't reliable: certbot has been
# observed to silently fall back to a "<domain>-0001" lineage instead of
# reusing the name, which nginx.conf doesn't know to look for).
primary_domain="${domains[0]}"
cert_path="./certbot/conf/live/$primary_domain/fullchain.pem"
if [ -f "$cert_path" ] && openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | grep -q "CN *= *localhost"; then
  echo "### Clearing the dummy certificate so certbot can create a real lineage ..."
  docker compose run --rm --entrypoint "\
    rm -rf /etc/letsencrypt/live/$primary_domain \
           /etc/letsencrypt/archive/$primary_domain \
           /etc/letsencrypt/renewal/$primary_domain.conf" certbot
fi

echo "### Requesting a certificate from Let's Encrypt (if needed) ..."
docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $domain_args \
    --cert-name $primary_domain \
    --email $email \
    --agree-tos \
    --no-eff-email \
    $renewal_arg" certbot

echo "### Reloading nginx ..."
docker compose exec nginx nginx -s reload