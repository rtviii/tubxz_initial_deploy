#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone source repos (fresh each time to ensure latest code)
rm -rf "$SCRIPT_DIR/tubulinxyz_src"
rm -rf "$SCRIPT_DIR/tubulinxyz_fend_src"

git clone https://github.com/rtviii/tubulinxyz.git      "$SCRIPT_DIR/tubulinxyz_src"
git clone https://github.com/rtviii/tubulinxyz_fend.git "$SCRIPT_DIR/tubulinxyz_fend_src"

# Copy the Linux MUSCLE binary into the backend source
# (Backend Dockerfile lives in the source repo, no injection needed)
cp "$SCRIPT_DIR/muscle_linux" "$SCRIPT_DIR/tubulinxyz_src/muscle3.8.1"
chmod +x "$SCRIPT_DIR/tubulinxyz_src/muscle3.8.1"

# Frontend Dockerfile still lives in the deploy repo (TODO: move to frontend source repo)
cp "$SCRIPT_DIR/tubulinxyz_fend/Dockerfile"    "$SCRIPT_DIR/tubulinxyz_fend_src/Dockerfile"
cp "$SCRIPT_DIR/tubulinxyz_fend/.dockerignore" "$SCRIPT_DIR/tubulinxyz_fend_src/.dockerignore"

mkdir -p "$SCRIPT_DIR/deploy/nginx/certs"

# --- Environment file handling ---
ENV_FILE="$SCRIPT_DIR/deploy/.env"

if [ ! -f "$ENV_FILE" ]; then
    cp "$SCRIPT_DIR/deploy/.env.example" "$ENV_FILE"
    echo "Created deploy/.env from .env.example -- fill it in before running setup.sh again."
    exit 0
fi

# Source the env file
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    export "$key=$val"
done < "$ENV_FILE"

# --- Validate required variables ---
required_vars=(
    NEO4J_USER
    NEO4J_PASSWORD
    NEO4J_CURRENTDB
    SECRET_KEY
    TUBETL_DATA_HOST
    NEXT_PUBLIC_API_URL
)

missing=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing+=("$var")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: The following required variables are not set in deploy/.env:"
    for v in "${missing[@]}"; do
        echo "  $v"
    done
    exit 1
fi

# --- Security: auto-generate SECRET_KEY if it's still the placeholder ---
if [ "$SECRET_KEY" = "changeme" ]; then
    NEW_KEY=$(openssl rand -hex 32)
    sed -i.bak "s/SECRET_KEY=changeme/SECRET_KEY=$NEW_KEY/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    echo "Generated random SECRET_KEY (replaced 'changeme' in .env)."
fi

# --- Ensure data directory exists on the host ---
mkdir -p "$TUBETL_DATA_HOST"

echo "All required variables present. Rebuilding containers..."
cd "$SCRIPT_DIR/deploy" && docker compose down && docker compose build --no-cache && docker compose up -d

echo ""
echo "Deployment started. Services:"
echo "  - neo4j:     waiting for health check..."
echo "  - init:      will run DB bootstrap (first deploy may take 2-3 hours to collect all structures)"
echo "  - backend:   starts after init completes"
echo "  - scheduler: weekly ingestion cron (Sundays 3am UTC)"
echo "  - frontend:  starts after backend is healthy"
echo "  - nginx:     http on port 80"
echo ""
echo "Monitor progress: docker compose -f deploy/docker-compose.yml logs -f init"
echo "Check health:     curl http://localhost/api/health"
echo "Check ingestion:  curl http://localhost/api/ingest-status"
