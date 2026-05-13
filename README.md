# tubxz_deploy

Deployment wrapper for [tube.xyz](https://tube.xyz) -- a structural biology
database for tubulin structures. This repo contains no application code; it
pulls pre-built Docker images from the registry and orchestrates them.

## Quick start

```bash
./setup.sh              # first run: creates .env, tells you to fill it in
# edit .env
./setup.sh              # second run: pulls images, starts everything
```

That's it. No source clones, no local builds. The site is live at
`http://localhost` within ~30 seconds. Database population happens
automatically in the background (~1-2 hours on a fresh deploy depending on
memory and download speed).

## What happens on first deploy

1. `setup.sh` validates your `.env`
2. `docker compose pull` fetches pre-built images from GHCR:
   - `ghcr.io/rtviii/tubulinxyz` (backend, used by 4 services)
   - `ghcr.io/rtviii/tubulinxyz-frontend` (Next.js UI)
3. Neo4j starts and passes a health check (~10s)
4. Backend API starts (~15s)
5. Frontend + nginx come up -- site is browsable immediately
6. A `bootstrap` service runs in the background:
   - Creates database constraints and indexes
   - Downloads ~809 tubulin structures from PDB
   - Runs the ETL pipeline (classification, alignment, binding sites)
   - Uploads everything to Neo4j
7. Structures appear in the catalogue as they are uploaded
8. A `scheduler` service runs weekly ingestion (Sundays 3am UTC) to pick up
   new PDB deposits

Monitor bootstrap progress:
```bash
curl http://localhost/api/bootstrap-status
docker compose logs -f bootstrap
```

## What's in here

```
tubxz_deploy/
  .env.example            -- template config (copy to .env)
  docker-compose.yml      -- production: pulls images
  docker-compose.dev.yml  -- override for local-source builds (--local mode)
  setup.sh                -- the only script you run
  nginx/
    nginx.conf            -- reverse proxy config
    certs/                -- drop cert.pem + key.pem here for HTTPS
```

No binaries are shipped here -- the MUSCLE 3.8.1 alignment binary lives
inside the backend image.

## Environment variables

Copy `.env.example` to `.env`. Required:

```
NEO4J_USER            default: neo4j
NEO4J_PASSWORD        at least 8 characters
NEO4J_CURRENTDB       must be "neo4j" (Community Edition only)
SECRET_KEY            auto-generated on first deploy if left as "changeme"
TUBETL_DATA_HOST      absolute path on host for structure data (~4GB)
```

Optional:
```
CORS_ALLOWED_ORIGINS  comma-separated whitelist (typically not needed
                      since everything is same-origin behind nginx)
BACKEND_IMAGE         pin a specific backend image tag (default: :latest)
FRONTEND_IMAGE        pin a specific frontend image tag (default: :latest)
BACKEND_PULL_POLICY   "always" (default) | "missing" | "never"
FRONTEND_PULL_POLICY  "always" (default) | "missing" | "never"
```

The frontend uses a relative `/api` URL that nginx routes to the backend.
This means the same image works for any deployment domain (localhost, IP,
https://your.domain) -- no rebuild needed.

## Services

| Service   | Purpose                                | Ports                  |
|-----------|----------------------------------------|------------------------|
| neo4j     | Graph database                         | internal (bolt://7687) |
| backend   | FastAPI API                            | internal (:8000)       |
| frontend  | Next.js UI                             | internal (:3000)       |
| nginx     | Reverse proxy                          | 80, 443                |
| bootstrap | One-time DB init + data collection     | none                   |
| scheduler | Weekly cron for new PDB structures     | none                   |

All traffic goes through nginx: `/api/*` routes to the backend, everything
else to the frontend.

## setup.sh flags

```bash
./setup.sh              # pull pre-built images, start
./setup.sh --local      # build from local source repos (development)
./setup.sh --hard       # tear down everything, delete volumes, archive .env
```

`--local` rsyncs from `/Users/rtviii/dev/tubulinxyz` and
`/Users/rtviii/dev/fend_tubulinxyz` into `./tubulinxyz_src` and
`./tubulinxyz_fend_src`, then builds. Override the source paths with
`LOCAL_BACKEND` and `LOCAL_FRONTEND` env vars.

## Updating

To pull the latest images and restart:

```bash
./setup.sh              # docker compose pull && up -d
```

To pin a specific version (recommended for production), set
`BACKEND_IMAGE=ghcr.io/rtviii/tubulinxyz:v1.2.0` (and similarly for
`FRONTEND_IMAGE`) in `.env`.

Neo4j data persists in a Docker volume across restarts. Structure profiles
persist in `TUBETL_DATA_HOST` on the host filesystem.

To completely start over:

```bash
./setup.sh --hard       # nukes everything (asks for confirmation)
./setup.sh              # fresh deploy
```

## Checking health

```bash
curl http://localhost/api/health             # neo4j connectivity
curl http://localhost/api/bootstrap-status   # init progress (fresh deploy)
curl http://localhost/api/ingest-status      # last weekly ingestion result
```

## Ad-hoc CLI access

The `ingest` service is a profile-gated container for manual operations:

```bash
docker compose run --rm ingest collect-missing     # fetch new structures from PDB
docker compose run --rm ingest upload-missing      # push to neo4j
docker compose run --rm ingest weekly-ingest       # both at once
docker compose run --rm ingest db-stats            # show database counts
docker compose run --rm ingest init-db             # re-run schema init (idempotent)
```

## HTTPS

1. Drop `cert.pem` and `key.pem` into `nginx/certs/`
2. Uncomment the HTTPS server block and HTTP-to-HTTPS redirect in
   `nginx/nginx.conf`
3. Restart: `docker compose down && docker compose up -d`

The frontend does not need rebuilding for different domains -- it uses a
relative `/api` URL.
