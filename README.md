# tubxz_deploy

This repo is a self-contained deployment wrapper for the tubulinxyz application. It doesn't contain any application source code -- it clones the two source repos, injects Dockerfiles into them, and orchestrates everything via docker compose. 

## what's in here

```
tubxz_deploy/
  setup.sh                  -- the only script you run to get started
  muscle_linux              -- precompiled MUSCLE binary, copied into the backend
  deploy/
    .env                    -- local config (never committed)
    .env.example            -- template to copy from
    docker-compose.yml
    nginx/
      nginx.conf
      certs/                -- drop cert.pem and key.pem here for HTTPS
  tubulinxyz/
    Dockerfile              -- backend image definition
    .dockerignore
  tubulinxyz_fend/
    Dockerfile              -- frontend image definition
    .dockerignore
```

`setup.sh` clones `github.com/rtviii/tubulinxyz` and `github.com/rtviii/tubulinxyz_fend` into `tubulinxyz_src/` and `tubulinxyz_fend_src/` respectively, copies the Dockerfiles in, then builds and starts everything. Those `_src` directories are gitignored throwaway clones -- don't edit them directly.

## containers

Four containers run as the main stack:

`neo4j` -- the database. Stores all structure data as a graph. Data lives in a named docker volume (`neo4j_data`) so it persists across restarts. The neo4j browser UI is not exposed externally -- only bolt (7687) is accessible inside the docker network, which is all the backend needs. 

`backend` -- a FastAPI/uvicorn Python app on port 8000. Not exposed directly; nginx proxies to it. Has two host paths mounted into it: the TUBETL_DATA directory (structure profiles on disk) and the NCBI taxonomy sqlite file. These are read-only reference data for the ETL pipeline.

`frontend` -- a Next.js app on port 3000. Also not exposed directly. The `NEXT_PUBLIC_API_URL` is baked in at build time (Next.js requirement), so if the public URL changes you need to rebuild the frontend image.

`nginx` -- the only container with external ports (80, 443). Routes `/api/*` to the backend and everything else to the frontend. HTTPS is commented out in `nginx.conf` -- see the HTTPS section below. This is more of a stub and will probably have to change significantly based on what works for you guys networking wise etc. 

## environment variables

Copy `.env.example` to `.env` and fill it in before running `setup.sh`. The required vars are:

```
NEO4J_USER          neo4j username (default: neo4j)
NEO4J_PASSWORD      at least 8 characters
NEO4J_CURRENTDB     name of the neo4j database (default: tubxz)
SECRET_KEY          FastAPI secret, set to anything non-empty
TUBETL_DATA_HOST    absolute path on the host machine to the TUBETL_DATA directory
NCBI_TAXA_SQLITE_HOST  absolute path on the host to ncbi_taxonomy.sqlite
NEXT_PUBLIC_API_URL the URL the browser uses to reach the backend API
                    (http://localhost/api for local, http://<ip>/api for a VM,
                     https://tubulinxyz.institution.edu/api for prod)
```

## first-time database setup

The neo4j database starts empty. Before the application is useful you need to initialize the schema and load data. I can very well take a bit more time and make it absolutely automatic (self-updating, ingestion runnin on a biweekly schedule for example), but for starters if it's at all possible i would love to have access to the VM to do it via my backend's CLI which send the data to the `neo4j` database.


The alternative i've been suggested is a semi-separate `ingest` service, which is a profile-gated container that reuses the backend image and has access to the same mounts:

```bash
# create constraints, indexes, and seed the phylogeny tree from TUBETL_DATA
docker compose --profile ingest run --rm --no-deps ingest init-db

# upload all structure profiles from TUBETL_DATA into neo4j
docker compose --profile ingest run --rm --no-deps ingest upload-all
```

`--no-deps` tells compose not to spin up a separate neo4j instance, since the main stack is already running. The ingest container connects to the existing neo4j over the `deploy_default` docker network using the service name `neo4j` as the hostname.

## HTTPS

I think this is a conversation for a bit later and depends very much on how the app will be exposed from the PSI network to the internet. In any case, this may be a bare nginx running in the VM or a dockerized nginx like so... it really doesn't matter as long as it's secure i suppose. 

1. Drop `cert.pem` and `key.pem` into `deploy/nginx/certs/`
2. Uncomment the HTTPS server block and the HTTP→HTTPS redirect block in `nginx.conf`
3. Update `NEXT_PUBLIC_API_URL` in `.env` to the `https://` URL
4. Rebuild the frontend (since that var is baked in at build time): `docker compose build --no-cache frontend`
5. `docker compose down && docker compose up -d`
