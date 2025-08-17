#!/bin/bash

# InvenTree Rebuild Script
# Rebuilds InvenTree application containers while preserving database and volumes

set -e

# Source environment variables
if [ -f .env ]; then
    . .env
else
    echo "Error: .env file not found"
    exit 1
fi

# Set default tag if not specified
INVENTREE_TAG=${INVENTREE_TAG:-stable}

echo "Starting InvenTree rebuild...\n"

# Change to the container directory
# cd "$(dirname "$0")/contrib/container"

echo "Stopping services...\n"
docker compose down --remove-orphans

echo "\nRemoving application containers..."
docker compose rm -f inventree-server inventree-worker || true

echo "\nRemoving InvenTree images..."
docker rmi -f "inventree/inventree:${INVENTREE_TAG}" 2>/dev/null || echo "Image not found\n"
docker rmi -f "inventree/inventree:${INVENTREE_TAG}-custom" 2>/dev/null || echo "Custom image not found\n"

# Get the exact InvenTree image used by our services
INVENTREE_IMAGE=$(docker compose config | grep -A 5 "inventree-server:" | grep "image:" | awk '{print $2}' | tr -d '"' || echo "")

# Safety checks before removal
if [ -z "$INVENTREE_IMAGE" ]; then
    # If no image specified in compose, it means it's built locally
    INVENTREE_IMAGE="contrib-container-inventree-server"
    echo "ℹ️  No explicit image found - looking for locally built image"
fi

# Extra safety: Verify this is NOT a critical system image
CRITICAL_IMAGES="postgres redis caddy nginx mysql mariadb"
for critical in $CRITICAL_IMAGES; do
    if echo "$INVENTREE_IMAGE" | grep -qi "$critical"; then
        echo "🚨 ERROR: Refusing to remove critical image containing '$critical': $INVENTREE_IMAGE"
        echo "🛑 Script aborted for safety!"
        exit 1
    fi
done

# Actually remove the InvenTree image only
if docker images | grep -q "inventree/inventree.*${INVENTREE_TAG}"; then
    docker rmi -f "inventree/inventree:${INVENTREE_TAG}" || echo "Failed to remove image (may not exist)"
fi
if docker images | grep -q "inventree/inventree.*${INVENTREE_TAG}-custom"; then
    docker rmi -f "inventree/inventree:${INVENTREE_TAG}-custom" || echo "Failed to remove custom image (may not exist)"
fi

# Remove any locally built InvenTree images (safer pattern matching)
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep -E "(contrib-container|inventree)" | grep -v "inventree/inventree" | while read image_info; do
    image_tag=$(echo "$image_info" | awk '{print $1}')
    if [ ! -z "$image_tag" ]; then
        echo "🗑️  Removing locally built image: $image_tag"
        docker rmi -f "$image_tag" || echo "Failed to remove $image_tag"
    fi
done

echo "\nRebuilding..."
docker compose run --rm inventree-server invoke update --skip-backup

echo "\nStarting services..."
docker compose up -d

echo "\nFixing database collation warnings..."
DB_USER=$(grep INVENTREE_DB_USER .env | cut -d'=' -f2)
docker compose exec -T inventree-db psql -U $DB_USER -d inventree -c "ALTER DATABASE inventree REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d postgres -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d template1 -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;" > /dev/null 2>&1 || true
docker compose exec -T inventree-db psql -U $DB_USER -d inventree -c "REINDEX DATABASE inventree;" > /dev/null 2>&1 || true

echo "Rebuild completed.\n"
docker compose ps
