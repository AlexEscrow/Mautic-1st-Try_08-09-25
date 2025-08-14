#!/bin/bash
set -euo pipefail

cd /var/www

# Build and start database + web container
docker compose build
docker compose up -d db --wait || true
docker compose up -d mautic_web --wait || true

echo "## Waiting for mautic_web container to be fully running..."

# Timeout in seconds
TIMEOUT=60
ELAPSED=0
until docker compose ps --status=running | grep -q "^mautic_web"; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: mautic_web did not start within $TIMEOUT seconds."
        docker compose logs mautic_web
        exit 1
    fi
    echo "### Still waiting for mautic_web..."
done

# Quick test
docker compose exec mautic_web sh -c 'echo "Container is running"'

echo "## Check if Mautic is installed"
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php && \
   docker compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
else
    # Stop worker if it exists to avoid issue #270
    if docker compose ps --status=running | grep -q "^mautic_worker"; then
        echo "Stopping mautic_worker..."
        docker compose stop mautic_worker
        until ! docker compose ps --status=running | grep -q "^mautic_worker"; do
            echo "### Waiting for mautic_worker to stop..."
            sleep 2
        done
    fi

    echo "## Installing Mautic..."
    docker compose exec -T -u www-data -w /var/www/html mautic_web \
        php ./bin/console mautic:install \
        --force \
        --admin_email "{{EMAIL_ADDRESS}}" \
        --admin_password "{{MAUTIC_PASSWORD}}" \
        http://{{IP_ADDRESS}}:{{PORT}}
fi

echo "## Starting all containers..."
docker compose up -d

DOMAIN="{{DOMAIN_NAME}}"
if [[ "$DOMAIN" == *"DOMAIN_NAME"* ]]; then
    echo "The DOMAIN variable is not set yet."
    exit 0
fi

DROPLET_IP=$(curl -s http://icanhazip.com)
DOMAIN_IP=$(dig +short "$DOMAIN")

echo "## Checking DNS for $DOMAIN..."
if [ "$DOMAIN_IP" != "$DROPLET_IP" ]; then
    echo "## $DOMAIN does not point to this droplet IP ($DROPLET_IP). Exiting..."
    exit 1
fi

echo "## $DOMAIN points to this droplet. Configuring Nginx..."

SOURCE_PATH="/var/www/nginx-virtual-host-$DOMAIN"
TARGET_PATH="/etc/nginx/sites-enabled/nginx-virtual-host-$DOMAIN"
[ -L "$TARGET_PATH" ] && rm "$TARGET_PATH"
ln -s "$SOURCE_PATH" "$TARGET_PATH"

if ! nginx -t; then
    echo "Nginx configuration test failed."
    exit 1
fi

if ! pgrep -x nginx > /dev/null; then
    systemctl start nginx
else
    nginx -s reload
fi

echo "## Configuring Let's Encrypt for $DOMAIN..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "{{EMAIL_ADDRESS}}"

# Setup cron for renewal
if ! crontab -l | grep -q 'certbot renew'; then
    (crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --post-hook 'systemctl reload nginx'") | crontab -
fi

# Update Mautic config site_url
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php; then
    echo "## Updating site_url in Mautic config..."
    docker compose exec -T mautic_web \
        sed -i "s|'site_url' => '.*',|'site_url' => 'https://$DOMAIN',|g" /var/www/html/config/local.php
fi

echo "## Script execution completed"
