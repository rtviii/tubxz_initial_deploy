#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TRASH_DIR="$SCRIPT_DIR/.trash"

# Apple Silicon: our images are built linux/amd64 only (matches PSI's VM).
# Force the platform so docker pulls the amd64 manifest and runs it via Rosetta.
# Harmless on Linux hosts (where the native arch is amd64 already).
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    export DOCKER_DEFAULT_PLATFORM=linux/amd64
fi

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
    chmod 600 "$ENV_FILE"
    echo ""
    echo "Created .env from .env.example."
    echo "Edit it now:  $ENV_FILE"
    echo "Then re-run:  ./setup.sh"
    echo ""
    exit 0
fi

# Lock down .env perms on every run. It holds NEO4J_PASSWORD, SECRET_KEY,
# and the LLM API key -- if the file was created by hand with a loose
# umask, this puts it back to owner-only.
chmod 600 "$ENV_FILE"

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

# Neo4j 5 refuses to start with a password under 8 chars; the symptom on
# startup is unhelpful ("backend can't reach neo4j"), so catch it early.
if [ ${#NEO4J_PASSWORD} -lt 8 ]; then
    echo "ERROR: NEO4J_PASSWORD must be at least 8 characters (Neo4j 5 requirement)."
    exit 1
fi

# Auto-generate SECRET_KEY if placeholder
if [ "$SECRET_KEY" = "changeme" ]; then
    NEW_KEY=$(openssl rand -hex 32)
    sed -i.bak "s/SECRET_KEY=changeme/SECRET_KEY=$NEW_KEY/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    chmod 600 "$ENV_FILE"   # preserve perms across the sed regen
    echo "Generated random SECRET_KEY."
fi

# Soft warn if no LLM key is set. The catalogue + structure pages work
# without it; only the natural-language search bar will 502.
if [ -z "$OPENROUTER_API_KEY" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
    echo ""
    echo "WARNING: No LLM API key set (OPENROUTER_API_KEY / OPENAI_API_KEY /"
    echo "         ANTHROPIC_API_KEY). The natural-language search bar will"
    echo "         return errors. The rest of the site will work normally."
    echo ""
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
    if [ -z "$LOCAL_BACKEND" ] || [ -z "$LOCAL_FRONTEND" ]; then
        echo "ERROR: --local mode requires LOCAL_BACKEND and LOCAL_FRONTEND env vars."
        echo "       Example:"
        echo "         LOCAL_BACKEND=/path/to/tubulinxyz \\"
        echo "         LOCAL_FRONTEND=/path/to/fend_tubulinxyz \\"
        echo "         ./setup.sh --local"
        exit 1
    fi

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

# --- Final summary ---
if [ -n "$OPENROUTER_API_KEY" ] || [ -n "$OPENAI_API_KEY" ]; then
    LLM_STATUS="enabled (OpenAI-compatible / OpenRouter)"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
    LLM_STATUS="enabled (Anthropic direct)"
else
    LLM_STATUS="DISABLED (no API key set; search bar will 502)"
fi

cat <<EOF

─────────────────────────────────────────────────────────────
  Deployment started.
─────────────────────────────────────────────────────────────

  SERVICES
    neo4j        graph database (internal network only)
    backend      FastAPI
    frontend     Next.js UI
    nginx        reverse proxy on 80/443
    bootstrap    background ETL (running, ~2-3h on fresh deploy)
    scheduler    weekly cron, Sundays 03:00 UTC

  STATUS
    Site         http://localhost/
    LLM search   ${LLM_STATUS}
    Bootstrap    first run takes ~2-3h; catalogue fills incrementally

  MONITOR
    curl http://localhost/api/health
    curl http://localhost/api/bootstrap-status | jq .
    docker compose logs -f bootstrap

─────────────────────────────────────────────────────────────

EOF
