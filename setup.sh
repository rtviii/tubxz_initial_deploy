#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TRASH_DIR="$SCRIPT_DIR/.trash"

# --- --hard flag: nuke everything and start fresh ---
if [ "$1" = "--hard" ]; then
    echo "This will:"
    echo "  - Stop and remove all containers and volumes (neo4j data, logs, etc.)"
    echo "  - Delete locally-cloned source repos (if present)"
    echo "  - Move .env to .trash/ (recoverable)"
    echo ""
    read -p "Are you sure? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    echo "Tearing down containers and volumes..."
    cd "$SCRIPT_DIR" && docker compose down -v 2>/dev/null || true

    echo "Removing local source dirs (if any)..."
    rm -rf "$SCRIPT_DIR/tubulinxyz_src" "$SCRIPT_DIR/tubulinxyz_fend_src"

    if [ -f "$ENV_FILE" ]; then
        mkdir -p "$TRASH_DIR"
        mv "$ENV_FILE" "$TRASH_DIR/.env.$(date +%Y%m%d_%H%M%S)"
        echo "Moved .env to $TRASH_DIR/"
    fi

    echo "Hard reset complete. Run ./setup.sh to start fresh."
    exit 0
fi

# --- Step 1: Environment file (before anything else) ---
if [ ! -f "$ENV_FILE" ]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    echo ""
    echo "Created .env from .env.example."
    echo "Edit it now:  $ENV_FILE"
    echo "Then re-run:  ./setup.sh"
    echo ""
    exit 0
fi

# Source and validate env
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    export "$key=$val"
done < "$ENV_FILE"

required_vars=(
    NEO4J_USER
    NEO4J_PASSWORD
    NEO4J_CURRENTDB
    SECRET_KEY
    TUBETL_DATA_HOST
)

missing=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing+=("$var")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: The following required variables are not set in .env:"
    for v in "${missing[@]}"; do
        echo "  $v"
    done
    exit 1
fi

# Auto-generate SECRET_KEY if placeholder
if [ "$SECRET_KEY" = "changeme" ]; then
    NEW_KEY=$(openssl rand -hex 32)
    sed -i.bak "s/SECRET_KEY=changeme/SECRET_KEY=$NEW_KEY/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    echo "Generated random SECRET_KEY."
fi

mkdir -p "$TUBETL_DATA_HOST"
mkdir -p "$SCRIPT_DIR/nginx/certs"

# --- Step 2: Decide path: pull pre-built images, or build from local source ---
USE_LOCAL=false
for arg in "$@"; do
    [ "$arg" = "--local" ] && USE_LOCAL=true
done

cd "$SCRIPT_DIR"

if [ "$USE_LOCAL" = true ]; then
    LOCAL_BACKEND="${LOCAL_BACKEND:-/Users/rtviii/dev/tubulinxyz}"
    LOCAL_FRONTEND="${LOCAL_FRONTEND:-/Users/rtviii/dev/fend_tubulinxyz}"

    echo "Local mode: building images from $LOCAL_BACKEND and $LOCAL_FRONTEND"

    rm -rf "$SCRIPT_DIR/tubulinxyz_src" "$SCRIPT_DIR/tubulinxyz_fend_src"
    mkdir -p "$SCRIPT_DIR/tubulinxyz_src" "$SCRIPT_DIR/tubulinxyz_fend_src"

    rsync -a --exclude='.git' --exclude='node_modules' --exclude='venv' \
              --exclude='TUBETL_DATA' --exclude='.etetoolkit' \
              "$LOCAL_BACKEND/" "$SCRIPT_DIR/tubulinxyz_src/"
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='.next' \
              "$LOCAL_FRONTEND/" "$SCRIPT_DIR/tubulinxyz_fend_src/"

    docker compose -f docker-compose.yml -f docker-compose.dev.yml down
    docker compose -f docker-compose.yml -f docker-compose.dev.yml build
    docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
else
    echo "Pulling pre-built images from registry..."
    docker compose pull
    docker compose down
    docker compose up -d
fi

echo ""
echo "Deployment started. All services come up immediately."
echo ""
echo "  neo4j:      database"
echo "  backend:    API (starts after neo4j healthy)"
echo "  frontend:   UI (starts after backend healthy)"
echo "  nginx:      reverse proxy on port 80"
echo "  bootstrap:  background DB init + structure collection"
echo "  scheduler:  weekly ingestion cron (Sundays 3am UTC)"
echo ""
echo "Monitor bootstrap: curl http://localhost/api/bootstrap-status"
echo "Check health:      curl http://localhost/api/health"
echo "Watch logs:        docker compose logs -f bootstrap"
