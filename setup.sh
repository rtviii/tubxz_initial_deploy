#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "$SCRIPT_DIR/tubulinxyz_src"
rm -rf "$SCRIPT_DIR/tubulinxyz_fend_src"

git clone https://github.com/rtviii/tubulinxyz.git      "$SCRIPT_DIR/tubulinxyz_src"
git clone https://github.com/rtviii/tubulinxyz_fend.git "$SCRIPT_DIR/tubulinxyz_fend_src"

cp "$SCRIPT_DIR/tubulinxyz/Dockerfile"         "$SCRIPT_DIR/tubulinxyz_src/Dockerfile"
cp "$SCRIPT_DIR/tubulinxyz/.dockerignore"      "$SCRIPT_DIR/tubulinxyz_src/.dockerignore"
cp "$SCRIPT_DIR/tubulinxyz_fend/Dockerfile"    "$SCRIPT_DIR/tubulinxyz_fend_src/Dockerfile"
cp "$SCRIPT_DIR/tubulinxyz_fend/.dockerignore" "$SCRIPT_DIR/tubulinxyz_fend_src/.dockerignore"
cp "$SCRIPT_DIR/muscle_linux" "$SCRIPT_DIR/tubulinxyz_src/muscle3.8.1"
chmod +x "$SCRIPT_DIR/tubulinxyz_src/muscle3.8.1"

mkdir -p "$SCRIPT_DIR/deploy/nginx/certs"

ENV_FILE="$SCRIPT_DIR/deploy/.env"

if [ ! -f "$ENV_FILE" ]; then
    cp "$SCRIPT_DIR/deploy/.env.example" "$ENV_FILE"
    echo "Created deploy/.env from .env.example -- fill it in before running setup.sh again."
    exit 0
fi

required_vars=(
    NEO4J_USER
    NEO4J_PASSWORD
    NEO4J_CURRENTDB
    SECRET_KEY
    TUBETL_DATA_HOST
    NCBI_TAXA_SQLITE_HOST
    NEXT_PUBLIC_API_URL
)

while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    export "$key=$val"
done < "$ENV_FILE"

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

echo "All required variables present. Rebuilding containers..."
cd "$SCRIPT_DIR/deploy" && docker compose down && docker compose build --no-cache && docker compose up -d