=== Dockerfile ===
# Define the Mautic version as an argument
ARG MAUTIC_VERSION=6.0.4-apache
FROM mautic/mautic:${MAUTIC_VERSION}
=== docker-compose.yml ===
x-mautic-volumes:
  &mautic-volumes
  - ./mautic/config:/var/www/html/config:z
  - ./mautic/logs:/var/www/html/var/logs:z
  - ./mautic/media/files:/var/www/html/docroot/media/files:z
  - ./mautic/media/images:/var/www/html/docroot/media/images:z
  - ./cron:/opt/mautic/cron:z

services:
  db:
    image: mysql:8.0
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    volumes: 
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: mysqladmin --user=$$MYSQL_USER --password=$$MYSQL_PASSWORD ping
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - default

  mautic_web:
    build:
      context: .
      dockerfile: Dockerfile
    links:
      - db:mysql
    ports:
      - ${MAUTIC_PORT:-8001}:80
    volumes: *mautic-volumes
    environment:
      - DOCKER_MAUTIC_LOAD_TEST_DATA=${DOCKER_MAUTIC_LOAD_TEST_DATA}
      - DOCKER_MAUTIC_RUN_MIGRATIONS=${DOCKER_MAUTIC_RUN_MIGRATIONS}
    env_file:
      - .mautic_env
    healthcheck:
      test: curl http://localhost
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 100
    depends_on:
      db:
        condition: service_healthy
    networks:
      - default

  mautic_cron:
      build:
        context: .
        dockerfile: Dockerfile
      links:
        - db:mysql
      volumes: *mautic-volumes
      environment:
        - DOCKER_MAUTIC_ROLE=mautic_cron
      env_file:
        - .mautic_env
      depends_on:
        mautic_web:
          condition: service_healthy
      networks:
        - default

  mautic_worker:
    build:
      context: .
      dockerfile: Dockerfile
    links:
      - db:mysql
    volumes: *mautic-volumes
    environment:
      - DOCKER_MAUTIC_ROLE=mautic_worker
    env_file:
      - .mautic_env
    depends_on:
      mautic_web:
        condition: service_healthy
    networks:
      - default
    deploy:
      replicas: 1

volumes:
  mysql-data:

networks:
  default:
    name: ${COMPOSE_PROJECT_NAME}-docker
=== setup-dc.sh ===
cd /var/www
docker-compose build
docker-compose up -d db --wait && docker-compose up -d mautic_web --wait

echo "## Wait for basic-mautic_web-1 container to be fully running"
while ! docker exec basic-mautic_web-1 sh -c 'echo "Container is running"'; do
    echo "### Waiting for basic-mautic_web-1 to be fully running..."
    sleep 2
done

echo "## Check if Mautic is installed"
if docker-compose exec -T mautic_web test -f /var/www/html/config/local.php && docker-compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
else
    # Check if the container exists and is running
    if docker ps --filter "name=basic-mautic_worker-1" --filter "status=running" -q | grep -q .; then
        echo "Stopping basic-mautic_worker-1 to avoid https://github.com/mautic/docker-mautic/issues/270"
        docker stop basic-mautic_worker-1
        echo "## Ensure the worker is stopped before installing Mautic"
        while docker ps -q --filter name=basic-mautic_worker-1 | grep -q .; do
            echo "### Waiting for basic-mautic_worker-1 to stop..."
            sleep 2
        done
    else
        echo "Container basic-mautic_worker-1 does not exist or is not running."
    fi
    echo "## Installing Mautic..."
    docker-compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:install --force --admin_email ContactUs+AutoCreatedAdmin@CallThatAgent.com --admin_password 0Mautic0@ http://138.197.199.81:8001
fi

echo "## Starting all the containers"
docker-compose up -d

DOMAIN="engine.call-that.com"

if [[ "$DOMAIN" == *"DOMAIN_NAME"* ]]; then
    echo "The DOMAIN variable is not set yet."
    exit 0
fi

DROPLET_IP=$(curl -s http://icanhazip.com)

echo "## Checking if $DOMAIN points to this DO droplet..."
DOMAIN_IP=$(dig +short $DOMAIN)
if [ "$DOMAIN_IP" != "$DROPLET_IP" ]; then
    echo "## $DOMAIN does not point to this droplet IP ($DROPLET_IP). Exiting..."
    exit 1
fi

echo "## $DOMAIN is available and points to this droplet. Nginx configuration..."

SOURCE_PATH="/var/www/nginx-virtual-host-$DOMAIN"
TARGET_PATH="/etc/nginx/sites-enabled/nginx-virtual-host-$DOMAIN"

# Remove the existing symlink if it exists
if [ -L "$TARGET_PATH" ]; then
    rm $TARGET_PATH
    echo "Existing symlink for $DOMAIN configuration removed."
fi

# Create a new symlink
ln -s $SOURCE_PATH $TARGET_PATH
echo "Symlink created for $DOMAIN configuration."

if ! nginx -t; then
    echo "Nginx configuration test failed, stopping the script."
    exit 1
fi

# Check if Nginx is running and reload to apply changes
if ! pgrep -x nginx > /dev/null; then
    echo "Nginx is not running, starting Nginx..."
    systemctl start nginx
else
    echo "Reloading Nginx to apply new configuration."
    nginx -s reload
fi

echo "## Configuring Let's Encrypt for $DOMAIN..."

# Use Certbot with the Nginx plugin to obtain and install a certificate
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m ContactUs+AutoCreatedAdmin@CallThatAgent.com

# Nginx will be reloaded automatically by Certbot after obtaining the certificate
echo "## Let's Encrypt configured for $DOMAIN"

# Check if the cron job for renewal is already set
if ! crontab -l | grep -q 'certbot renew'; then
    echo "## Setting up cron job for Let's Encrypt certificate renewal..."
    (crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --post-hook 'systemctl reload nginx'") | crontab -
else
    echo "## Cron job for Let's Encrypt certificate renewal is already set"
fi

echo "## Check if Mautic is installed"
if docker-compose exec -T mautic_web test -f /var/www/html/config/local.php && docker-compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
    
    # Replace the site_url value with the domain
    echo "## Updating site_url in Mautic configuration..."
    docker-compose exec -T mautic_web sed -i "s|'site_url' => '.*',|'site_url' => 'https://$DOMAIN',|g" /var/www/html/config/local.php
fi

echo "## Script execution completed"
root@mautic-vps:/var/www# # Display just the Dockerfile content
echo "=== Dockerfile ==="
cat Dockerfile
=== Dockerfile ===
ARG MAUTIC_VERSION=6.0.4-apache
FROM mautic/mautic:${MAUTIC_VERSION}
