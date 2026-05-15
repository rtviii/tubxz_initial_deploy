# Bootstrap and ETL pipeline reference

This document describes what happens when `./setup.sh` runs, where state lives,
how to observe progress, and the issues we've already hit so future sessions
don't rediscover them.

For the user-facing deploy story (env vars, flags) see `README.md`. This
document covers the internals.

## Architecture

Seven Docker services orchestrated by `docker-compose.yml`. Three custom
images, the rest stock.

| Service    | Image                                              | What it does |
|------------|----------------------------------------------------|--------------|
| neo4j      | `neo4j:5`                                          | Graph DB. Stores Structure, Entity, Instance, Variant, Modification, PhylogenyNode nodes. |
| backend    | `ghcr.io/rtviii/tubulinxyz:latest`                 | FastAPI on port 8000. Read-only API the frontend talks to. |
| bootstrap  | `ghcr.io/rtviii/tubulinxyz:latest` (same image)    | One-shot init script. Runs `scripts/init_and_seed.sh` once at deploy time, then sleeps forever. |
| scheduler  | `ghcr.io/rtviii/tubulinxyz:latest` (same image)    | `cron -f` daemon. Runs `weekly-ingest` every Sunday 3am UTC. |
| frontend   | `ghcr.io/rtviii/tubulinxyz-frontend:latest`        | Next.js on port 3000. Talks to backend via relative `/api/*` (no env baked at build time). |
| nginx      | `nginx:alpine`                                     | Reverse proxy on 80/443. `/api/*` → backend:8000; everything else → frontend:3000. |
| ingest     | (same as backend)                                  | Profile-gated; not auto-started. For ad-hoc CLI access via `docker compose run --rm ingest <cmd>`. |

Bootstrap, backend, scheduler, and ingest all use the **same** backend image
and differ only in entrypoint. That image bakes:

- `bin/muscle3.8.1` (Linux ELF) for sequence alignment
- All HMM profiles (`data/hmms/*`)
- Per-family master alignments (`data/*_tubulin/*.afasta`)
- Morisette mutation/PTM CSVs (`data/*_tubulin/*.csv`)
- `xvfb` + Mesa software-rendering drivers for headless thumbnail rendering
- `scripts_and_artifacts/render_thumbnail.tsx` (mol* headless renderer)
- A pre-populated NCBI taxonomy SQLite (built at image-build time via ete3)

## State locations

What persists, what doesn't, and where each thing lives:

- **`neo4j_data` (Docker volume)** — the graph database itself. Survives
  container restarts and image swaps. Destroyed by `docker compose down -v`
  or `setup.sh --hard`.
- **`neo4j_logs` (Docker volume)** — Neo4j's own logs. Same lifecycle.
- **`ingest_logs` (Docker volume)** — `/var/log/tubxz` inside the container.
  Holds the status JSON files the API reads:
  - `bootstrap_status.json` (live progress of the bootstrap)
  - `last_ingest_status.json` (last weekly-ingest result)
- **`${TUBETL_DATA_HOST}` (host bind mount)** — structure profiles on the
  host filesystem (~4 GB for ~800 structures). Mounted at `/mnt/tubetl_data`
  inside containers. Persists independently of any Docker volume.
  `setup.sh --hard` does NOT touch this; to truly start fresh you also need
  `rm -rf $TUBETL_DATA_HOST/*` by hand.

Per-structure dir layout under `TUBETL_DATA`:

```
<PDB_ID>/
  <PDB_ID>.cif                            # raw structure from RCSB
  <PDB_ID>.json                           # assembled profile (THE marker of a complete structure)
  <PDB_ID>_classification_report.json     # HMM classification per chain
  <PDB_ID>_ligand_binding_sites.json      # ligand neighborhoods
  <PDB_ID>_molstar_raw.json               # mol* CIF extraction output
  <PDB_ID>_variants.json                  # sequence variants vs canonical
  <PDB_ID>_thumbnail.png                  # rendered preview (optional)
```

A structure is considered "complete" iff `<PDB_ID>.json` exists. The other
files are intermediate artifacts. `GlobalOps.list_profiles()`
(`lib/etl/assets.py`) walks the dir and counts only structures with a
complete profile.

## Bootstrap pipeline (`scripts/init_and_seed.sh`)

Fires once when the `bootstrap` container starts. Idempotent: re-running it
on an existing deployment safely resumes whatever's incomplete.

Step 1. Initialize Neo4j schema. Runs `python cli.py init-db`, which creates
constraints/indexes and seeds the phylogeny tree. Uses `CREATE CONSTRAINT IF
NOT EXISTS` so it's safe to re-run.

Step 1.5. Ingest Morisette literature data. Runs
`python -m lib.etl.ingest_morisette --family tubulin_alpha` and the same for
`tubulin_beta`. This creates the `:Modification` and `:Variant` nodes the
PTM/mutations panel reads. Idempotent (MERGE). Marked non-fatal — if it
fails for some reason, the structural ETL still proceeds. The data source is
Morisette et al. 2023 (doi:10.1371/journal.pone.0295279); CSVs are baked
into the image at `data/<family>_tubulin/*_mutations.csv` and
`*_modifications.csv`. This step is fast (a few seconds).

Step 2. Collect and upload missing structures.
Runs `python cli.py collect-missing --upload`. `--upload` makes the command
ingest each structure into Neo4j right after collecting it, so the catalogue
fills in incrementally over the multi-hour run instead of staying empty
until the end. Single-threaded by design — collect and upload share one
Neo4j writer and must not race. `missing_profiles()` (`lib/etl/assets.py`)
computes the work list as `current_rcsb_structs() - list_profiles()`, so
structures with a complete profile on disk are skipped fast and a previously
interrupted run cleanly resumes.

Step 3. Catch any stragglers. Runs `python cli.py upload-missing --workers 4`.
Computes `local_complete_profiles - structures_in_neo4j` and uploads the
difference. Usually a fast no-op now that Step 2 uploads as it goes; useful
when a Step-2 upload transiently fails (Neo4j hiccup, lock contention) but
the disk profile was written successfully.

Done. Writes `{ "phase": "done", "done": true, ... }` to the status JSON
and `tail -f /dev/null` to keep the container alive. The scheduler container
takes over from here for weekly updates.

Total time on a fresh deploy: ~2-3 hours for ~800 structures. On a redeploy
where most data is already collected, seconds to minutes.

## Per-structure ETL phases (`lib/etl/collector.py`)

What happens inside one `generate_profile()` call:

Phase 1. Acquire raw data. Download CIF from RCSB, fetch entity metadata,
run mol* CIF extraction (TypeScript via tsx) to produce
`<id>_molstar_raw.json`. The mol* extraction is parsing-only (no rendering)
so it doesn't need a GL context.

Phase 2. Classification. For each polypeptide entity, run pyhmmer against
the tubulin and MAP HMM profiles (`data/hmms/*`). Each entity gets assigned
a `PolymerClass` (`tubulin_alpha`, `tubulin_beta`, `map_tau`, etc.) or
remains `unclassified`. Writes `<id>_classification_report.json`.

Phase 2.5. Isotype calling. For entities classified as tubulin_alpha or
tubulin_beta, align against curated isotype reference sequences
(`lib/etl/isotype.py`) to identify the specific isotype (TUBA1A, TUBB3, ...).

Phase 3. Sequence alignment. Profile-align each canonical entity sequence
against the family master alignment using MUSCLE 3.8.1:
`muscle3.8.1 -profile -in1 <family>.afasta -in2 <query>.fasta -out <out>`.
Produces master-alignment indices for every observed residue.

Phase 4. Variant detection. Compare observed sequences against the
classified-family canonical to identify substitutions, insertions, and
deletions. Writes `<id>_variants.json`.

Phase 5. Binding site analysis. For each ligand, compute the neighborhood
(residues within a contact distance) and produce
`<id>_ligand_binding_sites.json`.

Phase 6. Thumbnail render (optional, non-fatal). Runs
`scripts_and_artifacts/render_thumbnail.tsx` via tsx, wrapped in `xvfb-run`
so headless mol* + headless-gl have a display server to attach to. Renders
a transparent 480x320 PNG. Failure here is logged as a warning but doesn't
abort the structure; the upload still happens.

Final. Assemble `<id>.json` (the complete profile) from all the intermediate
artifacts. With `--upload`, immediately call
`adapter.add_total_structure(rcsb_id)` which writes the Structure, Entity,
Instance, Variant, and Chemical nodes plus their relationships to Neo4j.

A structure can fail at any phase. Common failure modes:

- Phase 1: mol* extraction OOM on very large complexes (50+ chains)
- Phase 3: MUSCLE binary not found, or the family afasta missing
- Phase 6: GL context creation fails (no xvfb, missing Mesa drivers)
- Final upload: Neo4j transient errors, schema violations

A failure at any phase before final leaves the dir with the files produced
up to that point but no `<id>.json`. The next `collect-missing` run picks it
up again (`missing_profiles()` returns it) and retries from Phase 1.

## Monitoring

Live status (phase + counts), refreshed every 5 seconds:

```
watch -n 5 'curl -s http://localhost/api/bootstrap-status | jq .'
```

Per-structure log detail:

```
docker compose logs -f bootstrap
```

Just failures from the log:

```
docker compose logs bootstrap 2>&1 | grep -iE "failed|error" | tail -20
```

Neo4j node counts:

```
NEO4J_PASS=$(grep NEO4J_PASSWORD .env | cut -d= -f2)
docker compose exec -T neo4j cypher-shell -u neo4j -p "$NEO4J_PASS" \
  "MATCH (n) RETURN labels(n)[0] AS label, count(*) AS cnt ORDER BY cnt DESC;"
```

Thumbnails rendered so far:

```
docker compose exec -T bootstrap sh -c \
  'find /mnt/tubetl_data -name "*_thumbnail.png" | wc -l'
```

Structures on disk vs structures in DB (the gap is your work-remaining):

```
docker compose exec -T bootstrap sh -c \
  'find /mnt/tubetl_data -mindepth 2 -maxdepth 2 -name "????.json" | wc -l'

docker compose exec -T neo4j cypher-shell -u neo4j -p "$NEO4J_PASS" \
  "MATCH (s:Structure) RETURN count(s);"
```

## Common operations

Redeploy with the latest image, keeping data:

```
docker compose pull
docker compose up -d
```

The bootstrap container will re-run `init_and_seed.sh`. Steps 1, 1.5, and
2 are all idempotent, so this is safe. Resumes whatever's incomplete.

Force a fresh ETL from zero:

```
./setup.sh --hard                       # wipes Docker volumes + archives .env
rm -rf "$TUBETL_DATA_HOST"/*            # wipe the host data dir too
./setup.sh                              # fresh deploy, ~2-3h ETL
```

Backfill thumbnails without redeploying (existing structures that lack a
thumbnail):

```
docker compose exec bootstrap python cli.py render-thumbnails
```

Manually re-run a single phase or step:

```
# re-collect one structure
docker compose run --rm ingest collect-one 9MLF

# upload anything on disk not yet in DB
docker compose exec bootstrap python cli.py upload-missing --workers 4

# re-run Morisette ingest (idempotent)
docker compose exec bootstrap python -m lib.etl.ingest_morisette --family tubulin_alpha
docker compose exec bootstrap python -m lib.etl.ingest_morisette --family tubulin_beta

# re-init constraints (idempotent)
docker compose exec bootstrap python cli.py init-db
```

Stop and start without recreating containers:

```
docker compose stop
docker compose start
```

## Local dev mode

`./setup.sh --local` rsyncs the local backend and frontend source trees into
`./tubulinxyz_src/` and `./tubulinxyz_fend_src/` and builds the images
in-place using the `docker-compose.dev.yml` override. This bypasses the GHCR
images entirely. Used to test changes before they're committed and an image
is published.

The rsync respects `--exclude` but NOT `.gitignore`, so files that are
locally present but gitignored DO make it into a `--local` build. This is
a footgun: a `--local` build can succeed when the GHCR-built image silently
fails because some required asset is gitignored. See "Known footguns" below.

## Image build and release

GitHub Actions in each repo (`backend`, `frontend`) builds and publishes
images to GHCR on either:

- a git tag matching `v*` (`git push origin v1.2.3`) — produces `:1.2.3`,
  `:1.2`, `:1`, and `:latest` (the recommended path for handoff)
- manual `workflow_dispatch` from the Actions tab — produces `:latest` only
  (used during prototyping)

A push to `main` alone does nothing — there's no `branches: [main]` trigger.
Tag pushes are the canonical way to ship a version PSI will pin.

The deploy repo doesn't have a workflow; it's pure orchestration. After
changes there, you don't rebuild anything — just commit and (if applicable)
re-run `./setup.sh` on machines that have a working copy.

## Known footguns (history)

Several of these have bitten us. Listed so future sessions don't re-debug them.

The image only sees git-tracked files. `actions/checkout` and the Docker
build context together mean: if a file exists locally but isn't tracked in
git, it's NOT in the image. Three concrete instances:

- `*.png` in the frontend `.gitignore` was hiding the 9 vendor logos in
  `public/landing/`. The Next.js `_next/image` optimizer 400'd on missing
  files. Fix: `!public/landing/*.png` exception.
- `*fasta` in the backend `.gitignore` was hiding all the per-family master
  alignment files (`beta_tubulin.afasta`, `gamma_tubulin/*.afasta`, etc.)
  except `alpha_tubulin.afasta` (which predated the rule). Result: ETL
  failed for any structure containing a non-alpha tubulin chain. Fix:
  `!data/*_tubulin/*.afasta` exception.
- The macOS `muscle3.8.1` binary at the repo root was overwritten at deploy
  time by a Linux binary from the deploy repo. We restructured so the
  backend repo carries `bin/muscle3.8.1` (Linux ELF) and
  `bin/muscle3.8.1-darwin` (Mach-O), and `api.config.resolve_muscle_binary()`
  picks the right one at runtime via `platform.system()`.

Always check `git ls-files <path>` before assuming a file is in the image.

Headless WebGL in Docker needs both a software renderer and a display
server. The thumbnail renderer (`scripts_and_artifacts/render_thumbnail.tsx`)
uses mol*'s headless backend, which uses the `gl` npm package, which
dlopens `libX11.so.6` and creates a GL context against a display. In the
runtime image we need:

- `libgl1`, `libglx-mesa0`, `libgl1-mesa-dri`, `libx11-6`, `libxi6`,
  `libxext6`, `libxxf86vm1` for the libs `gl` links against
- `xvfb` to provide a virtual display, since the container has no GPU
- `xauth` because `xvfb-run` shells out to it to mint an X authority cookie
  before launching the server. It's a Recommends of `xvfb`, so
  `--no-install-recommends` strips it and must be listed explicitly.
- `molstar_bridge.run_thumbnail_render` wraps the subprocess in
  `xvfb-run -a -s "-screen 0 1024x768x24 -ac"` so each render gets an
  auto-allocated display number (so parallel renders don't collide)

When this is wrong you get one of:
- "libX11.so.6: cannot open shared object file" — missing X11 runtime libs
- "Cannot read properties of null (reading 'getExtension')" — libs present
  but no GL context, usually missing xvfb
- "xvfb-run: error: xauth command not found" — xvfb installed but xauth
  package missing under `--no-install-recommends`. Add `xauth` to the apt
  install list. (Bit us in May 2026.)

If we ever want to drop the X11 chain entirely, the alternative is to
rebuild `gl` against OSMesa (`npm_config_osmesa=true` at install time,
`libosmesa6-dev` build dep, `libosmesa6` runtime dep). That trades runtime
config (xvfb-run wrap, xauth, several X libs) for build config (one env
var, one extra apt pkg). Equivalent output PNG; not done yet.

Apple Silicon vs the published images. Images are built `linux/amd64` only
(matching PSI's VM). Pulling them on an M-series Mac without coercion fails
with "no matching manifest for linux/arm64/v8". Two ways to handle:

- `setup.sh` auto-detects Apple Silicon and exports
  `DOCKER_DEFAULT_PLATFORM=linux/amd64` for its own shell
- For direct `docker compose pull` / `docker compose up` calls, the user
  needs to set the env var in their shell (e.g. `export
  DOCKER_DEFAULT_PLATFORM=linux/amd64` in `~/.zshrc`)

The init_and_seed.sh branching used to orphan structures. The previous
script branched on "any `.json` exists in `TUBETL_DATA`" → "skip collection,
only upload-missing." Partially-collected structures have intermediate JSON
files but no complete profile, which tripped the check, so an interrupted
run permanently orphaned them. Current script always runs collect-missing
then upload-missing. Both idempotent. Don't reintroduce the branching.

Tilde in `.env` paths. `TUBETL_DATA_HOST=~/foo` does NOT get tilde-expanded
by docker-compose on Linux. Always use absolute paths.

## For the next session

If the deployment is running and something is wrong, the order to check:

1. `curl -s http://localhost/api/bootstrap-status` — what phase is it in?
2. `docker compose ps` — are all services up and healthy?
3. `docker compose logs --tail 50 bootstrap` — recent activity, last
   completion line, any errors
4. `docker compose logs --tail 50 backend` — API errors (probably the
   frontend would be complaining about specific endpoints)

If you need to change pipeline behavior:

- Most ETL logic lives in `lib/etl/` in the backend repo
- The bootstrap orchestration is `scripts/init_and_seed.sh` in the backend repo
- CLI commands are in `cli.py` (typer-based)
- The API is in `api/` (FastAPI)
- Anything you change needs a new image build (tag + workflow, or manual
  dispatch) before redeploy will see it

If a file you expect to be in the image isn't there, check `.gitignore` and
`.dockerignore` before anything else. See "Known footguns" above.

The single most common deploy bug pattern in this project: "works on
`--local`, broken on the GHCR-published image" — almost always means a file
is gitignored.
