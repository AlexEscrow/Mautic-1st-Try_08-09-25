#!/bin/bash
set -e

# -----------------------------
# Variables (replace placeholders)
# -----------------------------
IP_ADDRESS="{{IP_ADDRESS}}"
PORT="{{PORT}}"
EMAIL_ADDRESS="{{EMAIL_ADDRESS}}"
MAUTIC_PASSWORD="{{MAUTIC_PASSWORD}}"
DOMAIN="{{DOMAIN_NAME}}"

# -----------------------------
# Move to project folder
# -----------------------------
cd /var/www

# -----------------------------
# Build & start database & web containers
# -----------------------------
docker compose build
docker compose up -d db --wait
docker compose up -d mautic_web --wait

# -----------------------------
# Wait for mautic_web container to be fully running
# -----------------------------
echo "## Waiting for basic-mautic_web-1 to be ready..."
while ! docker exec basic-mautic_web-1 sh -c 'echo "Container running"' >/dev/null 2>&1; do
    echo "### Waiting..."
    sleep 2
done

# -----------------------------
# Check if Mautic is installed
# -----------------------------
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php && \
   docker compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic already installed."
else
    # Stop worker if running to avoid issue #270
    if docker ps --filter "name=basic-mautic_worker-1" --filter "status=running" -q | grep -q .; then
        echo "Stopping basic-mautic_worker-1..."
        docker stop basic-mautic_worker-1
        while docker ps -q --filter name=basic-mautic_worker-1 | grep -q .; do
            sleep 2
        done
    fi

    # Install Mautic
    echo "## Installing Mautic..."
    docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:install \
        --force \
        --admin_email "$EMAIL_ADDRESS" \
        --admin_password "$MAUTIC_PASSWORD" \
        "http://$IP_ADDRESS:$PORT"
fi

# -----------------------------
# Start all containers
# -----------------------------
docker compose up -d

# -----------------------------
# Configure Nginx if DOMAIN is set
# -----------------------------
if [[ "$DOMAIN" != "" && "$DOMAIN" != "DOMAIN_NAME" ]]; then
    DROPLET_IP=$(curl -s http://icanhazip.com)
    DOMAIN_IP=$(dig +short $DOMAIN)

    if [ "$DOMAIN_IP" != "$DROPLET_IP" ]; then
        echo "## $DOMAIN does not point to this server ($DROPLET_IP). Exiting."
        exit 1
    fi

    echo "## Configuring Nginx for $DOMAIN

