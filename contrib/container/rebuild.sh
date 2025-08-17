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

echo "\nDetecting and removing InvenTree images..."

# Detect if we're using locally built images or pulled images
USES_BUILD=$(docker compose config | grep -E "inventree-(server|worker):" -A 10 | grep -c "build:" || echo "0")

# Get all InvenTree-related images that exist, but NEVER touch DB images
INVENTREE_IMAGES=""

if [ "$USES_BUILD" -gt 0 ]; then
    echo "ℹ️  Detected locally built InvenTree images"
    # Find actual locally built images (they follow compose project naming)
    PROJECT_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    
    # Look for images that match the local build pattern - only server and worker
    # This includes patterns like: inventree-inventree-server, inventree-inventree-worker, container-inventree-server, etc.
    LOCAL_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(${PROJECT_NAME}[_-]?inventree[_-]?(server|worker)|inventree[_-]inventree[_-](server|worker))" | grep -vE "(db|database|postgres|mysql|mariadb)" || echo "")
    
    # Also check for pulled InvenTree images that might be present alongside local builds
    PULLED_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^inventree/inventree:" | grep -vE "(db|database|postgres|mysql|mariadb)" || echo "")
    
    # Combine both local and pulled images
    INVENTREE_IMAGES="$LOCAL_IMAGES $PULLED_IMAGES"
else
    echo "ℹ️  Detected pulled InvenTree images"
    # Look for standard InvenTree images - exclude any with db/database keywords
    PULLED_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^inventree/inventree:" | grep -vE "(db|database|postgres|mysql|mariadb)" || echo "")
    INVENTREE_IMAGES="$PULLED_IMAGES"
fi

# Clean up the list and remove empty entries
INVENTREE_IMAGES=$(echo "$INVENTREE_IMAGES" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

if [ -z "$INVENTREE_IMAGES" ]; then
    echo "ℹ️  No InvenTree images found to remove"
else
    echo "ℹ️  Found InvenTree images to remove: $INVENTREE_IMAGES"
fi

# Extra safety: Verify these are NOT critical system images (NEVER TOUCH DATABASE!)
CRITICAL_IMAGES="postgres redis caddy nginx mysql mariadb db database inventree-db inventree-cache"
for inventree_img in $INVENTREE_IMAGES; do
    for critical in $CRITICAL_IMAGES; do
        if echo "$inventree_img" | grep -qi "$critical"; then
            echo "🚨 ERROR: Refusing to remove critical image containing '$critical': $inventree_img"
            echo "🛑 Script aborted for safety! DATABASE PROTECTION ACTIVATED!"
            exit 1
        fi
    done
done

# Additional safety: Only proceed if we have actual InvenTree application images
if [ -n "$INVENTREE_IMAGES" ]; then
    echo "✅ Safety check passed - proceeding with InvenTree application images only"
else
    echo "ℹ️  No InvenTree application images to remove - skipping removal step"
fi

# Remove the InvenTree images based on detection
for inventree_img in $INVENTREE_IMAGES; do
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${inventree_img}$"; then
        echo "🗑️  Removing InvenTree image: $inventree_img"
        docker rmi -f "$inventree_img" || echo "Failed to remove $inventree_img (may not exist)"
    else
        echo "ℹ️  Image not found: $inventree_img"
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
