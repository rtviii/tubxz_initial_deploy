# tubxz_deploy

Deployment wrapper for [tube.xyz](https://tube.xyz) -- a structural biology database for tubulin structures. This repo contains no application code. It clones the source repos, builds Docker images, and orchestrates everything.

## Quick start

```bash
./setup.sh              # first run: creates .env, tells you to fill it in
# edit .env 
# (The only variable that really matters for prototyping locally or on a VM is that TUBETL_HOST is a valid path )
./setup.sh              # second run: clones repos, builds, deploys
```

That's it. The site is live at `http://localhost` within ~30 seconds. Database population happens automatically in the background (takes about an hour or two for the ETL on a fresh deploy depedning on memory/download speed).

## What happens on first deploy

1. `setup.sh` validates your `.env`, clones source repos, builds 4 Docker images
2. Neo4j starts and passes a health check (~10s)
3. Backend API starts (~15s)
4. Frontend + nginx come up -- site is browsable immediately
5. A `bootstrap` service runs in the background:
   - Creates database constraints and indexes
   - Downloads ~809 tubulin structures from PDB
   - Runs the ETL pipeline (classification, alignment, binding sites)
   - Uploads everything to Neo4j
6. Structures appear in the catalogue as they are uploaded
7. A `scheduler` service runs weekly ingestion (Sundays 3am UTC) to pick up new PDB deposits

Monitor bootstrap progress:
```bash
curl http://localhost/api/bootstrap-status
docker compose logs -f bootstrap
```

## What's in here

```
tubxz_deploy/
  .env.example          -- template config (copy to .env)
  docker-compose.yml    -- all services
  setup.sh              -- the only script you run
  muscle_linux          -- precompiled MUSCLE binary for sequence alignment
  nginx/
    nginx.conf          -- reverse proxy config
    certs/              -- drop cert.pem + key.pem here for HTTPS
```

## Environment variables

Copy `.env.example` to `.env`. Required:

```
NEO4J_USER            default: neo4j
NEO4J_PASSWORD        at least 8 characters
NEO4J_CURRENTDB       must be "neo4j" (Community Edition only supports the default database)
SECRET_KEY            auto-generated on first deploy if left as "changeme"
TUBETL_DATA_HOST      absolute path on host for structure data (~4GB). Created automatically.
NEXT_PUBLIC_API_URL   URL the browser uses to reach the API:
                        local:  http://localhost/api
                        VM:     http://<ip>/api
                        prod:   https://your.domain/api
```

## Services

| Service | Purpose | Ports |
|---------|---------|-------|
| neo4j | Graph database | internal only (bolt://neo4j:7687) |
| backend | FastAPI API | internal only (:8000) |
| frontend | Next.js UI | internal only (:3000) |
| nginx | Reverse proxy | 80, 443 |
| bootstrap | One-time DB init + data collection | none |
| scheduler | Weekly cron for new PDB structures | none |

All traffic goes through nginx: `/api/*` routes to the backend, everything else to the frontend.

## setup.sh flags

```bash
./setup.sh              # clone from GitHub, build, deploy
./setup.sh --local      # use local source repos instead of cloning (for development)
./setup.sh --hard       # tear down everything, delete volumes + repos, archive .env
```

`--local` copies from the local repos at `/Users/rtviii/dev/tubulinxyz` and `/Users/rtviii/dev/fend_tubulinxyz`. Override with `LOCAL_BACKEND` and `LOCAL_FRONTEND` env vars.

## Checking health

```bash
curl http://localhost/api/health            # neo4j connectivity
curl http://localhost/api/bootstrap-status   # init progress (fresh deploy)
curl http://localhost/api/ingest-status      # last weekly ingestion result
```

## Ad-hoc CLI access

The `ingest` service is a profile-gated container for manual operations:

```bash
docker compose run --rm ingest collect-missing     # fetch new structures from PDB
docker compose run --rm ingest upload-missing       # push to neo4j
docker compose run --rm ingest weekly-ingest        # both at once
docker compose run --rm ingest db-stats             # show database counts
docker compose run --rm ingest init-db              # re-run schema init (idempotent)
```

## HTTPS

1. Drop `cert.pem` and `key.pem` into `nginx/certs/`
2. Uncomment the HTTPS server block and HTTP-to-HTTPS redirect in `nginx/nginx.conf`
3. Update `NEXT_PUBLIC_API_URL` in `.env` to `https://...`
4. Rebuild frontend (the URL is baked at build time): `docker compose build --no-cache frontend`
5. Restart: `docker compose down && docker compose up -d`

## Updating

To deploy new code:

```bash
./setup.sh          # re-clones repos, rebuilds images, restarts services
```

Neo4j data persists in a Docker volume across restarts. Structure profiles persist in `TUBETL_DATA_HOST` on the host filesystem.

To completely start over:

```bash
./setup.sh --hard   # nukes everything (asks for confirmation)
./setup.sh          # fresh deploy
```
