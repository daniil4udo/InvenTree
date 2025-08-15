#!/bin/bash

# InvenTree Rebuild Script
# Rebuilds InvenTree application containers while preserving database and volumes

set -e

echo "Starting InvenTree rebuild..."

# Change to the container directory
# cd "$(dirname "$0")/contrib/container"

echo "Stopping services...\n"
docker compose down

echo "Removing application containers...\n"
docker compose rm -f inventree-server inventree-worker || true

echo "Removing InvenTree images...\n"
docker rmi -f "inventree/inventree:stable" 2>/dev/null || echo "Image not found\n"

# Get the exact InvenTree image used by our services
INVENTREE_IMAGE=$(docker compose config | grep -A 5 "inventree-server:" | grep "image:" | awk '{print $2}' | tr -d '"' || echo "\n")

# Safety checks before removal
if [ -z "$INVENTREE_IMAGE" ]; then
    # If no image specified in compose, it means it's built locally
    INVENTREE_IMAGE="contrib-container-inventree-server"
    echo "ℹ️  No explicit image found - looking for locally built image\n"
fi

# Extra safety: Verify this is NOT a critical system image
CRITICAL_IMAGES="postgres redis caddy nginx mysql mariadb"
for critical in $CRITICAL_IMAGES; do
    if echo "$INVENTREE_IMAGE" | grep -qi "$critical"; then
        echo "🚨 ERROR: Refusing to remove critical image containing '$critical': $INVENTREE_IMAGE"
        echo "🛑 Script aborted for safety!\n"
        exit 1
    fi
done

# Actually remove the InvenTree image only
if docker images | grep -q "inventree/inventree.*stable"; then
    docker rmi -f "inventree/inventree:stable" || echo "Failed to remove image (may not exist)\n"
fi

# Remove any locally built InvenTree images (safer pattern matching)
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep -E "(contrib-container|inventree)" | grep -v "inventree/inventree" | while read image_info; do
    image_tag=$(echo "$image_info" | awk '{print $1}')
    if [ ! -z "$image_tag" ]; then
        echo "🗑️  Removing locally built image: $image_tag\n"
        docker rmi -f "$image_tag" || echo "Failed to remove $image_tag\n"
    fi
done

echo "Rebuilding...\n"
docker compose build --no-cache inventree-server inventree-worker
docker compose run --rm inventree-server /bin/invoke update

echo "Starting services...\n"
docker compose up -d

echo "Fixing database collation warnings...\n"
DB_USER=$(grep INVENTREE_DB_USER .env | cut -d'=' -f2)
docker compose exec -T inventree-db psql -U $DB_USER -d inventree -c "ALTER DATABASE inventree REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d postgres -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d template1 -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d inventree -c "REINDEX DATABASE inventree;" > /dev/null 2>&1 || true

echo "Rebuild completed.\n"
docker compose ps
