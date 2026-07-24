# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository structure

This directory (`nerdifica-infra`, remote `github.com/nerdifica/nerdifica-infra`) is a **deploy/infra-only repo** — it is not a monorepo. It contains just `docker-compose.yml`, `nginx/nginx.conf`, and the deploy workflow that runs on the production host. It intentionally does **not** track the application code: `nerdifica-site/` and `nerdifica-api/` are listed in `.gitignore` here because each is its own independent git repository with its own remote:

- `nerdifica-site/` — Nuxt 4 frontend, remote `github.com/nerdifica/nerdifica-site`
- `nerdifica-api/` — FastAPI backend, remote `github.com/nerdifica/nerdifica-api`
- this directory — `docker-compose.yml` + `nginx/` + infra deploy workflow, remote `github.com/nerdifica/nerdifica-infra`

Each of the three repos has its own CI in `.github/workflows/deploy.yml` and is developed/committed independently. Don't assume a single `git status`/`git log` at the root reflects app code changes — `cd` into the specific repo first.

`docker-compose.yml` here runs prebuilt images (`ghcr.io/nerdifica/nerdifica-site:latest`, `ghcr.io/nerdifica/nerdifica-api:latest`), not local builds — it's meant for the production host, not local development (see "Local development" below).

## Product context

nerdifica.com is a multi-niche tools site (calculators, converters, etc.) with a companion blog, monetized primarily via Google AdSense. This drives several deliberate decisions that aren't obvious from the code:

- No login/accounts — frictionless pageviews are prioritized over accounts; auth is an explicit future phase.
- Every niche must ship with **both** at least one tool and one blog article — tool-only content risks AdSense thin-content penalties.
- Launch locale order is **pt-br → es → en** (pt-br is the default locale), chosen for lower SEO competition rather than the highest CPM.
- Brand colors/fonts are sampled directly from the logo: primary blue `#005DFE`, ink `#111111` (see `nerdifica-site/app/assets/css/main.css` `@theme` block for the full scale).

## Local development

There is no single "run everything" command — run each service directly, not through the root `docker-compose.yml` (that file pulls production images from GHCR).

**Frontend** (`nerdifica-site/`, Nuxt 4):
```bash
npm install
npm run dev          # http://localhost:3000
npm run build        # production build to .output/
npm run preview      # serve the production build
npm run typecheck    # vue-tsc --noEmit — CI runs this before every deploy
```

**Backend** (`nerdifica-api/`, FastAPI):
```bash
python3 -m venv .venv && .venv/bin/pip install -e .[test]
.venv/bin/uvicorn src.main:app --reload --port 8000   # http://localhost:8000
.venv/bin/pytest                                       # run all tests
.venv/bin/pytest tests/financas/test_service.py::test_calculate_compound_interest  # single test
```

**Testing a container build locally**: there is no compose file that builds from local source — the root `docker-compose.yml` only pulls `:latest` images from GHCR. Build each Dockerfile directly instead:
```bash
docker build ./nerdifica-site -t nerdifica-site:local
docker build ./nerdifica-api -t nerdifica-api:local
```

## Deploy pipeline

Each app repo deploys independently on push to `master`:
1. `test` job — `npm run typecheck` (site) or `pytest` (api).
2. `build-and-push` — builds the Dockerfile and pushes to `ghcr.io/nerdifica/<repo>:latest` and `:<sha>`.
3. `deploy` — SSHes into the production host, `cd`s into `INFRA_DIR` (this repo, cloned there), runs `docker compose pull <service> && docker compose up -d --no-deps <service>`.

This infra repo's own `deploy.yml` runs on its own push to `master` and does a full `docker compose pull && up -d` for all services (used when `docker-compose.yml` or `nginx.conf` change here, not for app code changes).

Site build args (`NUXT_PUBLIC_API_BASE`, `NUXT_PUBLIC_ADSENSE_ID`) are baked in at image build time via GitHub Actions repo variables — changing them requires a rebuild, not just an env var change on the host.

`nginx/nginx.conf` proxies for `nerdifica.com`/`www.nerdifica.com` and terminates TLS on 443, redirecting 80 → 443 (except for the ACME challenge path). Certificates come from Let's Encrypt: `init-letsencrypt.sh` is a one-time manual bootstrap (run once via SSH on the host after DNS already resolves to it — see script comments for why the order matters), after which the `certbot` service in `docker-compose.yml` renews automatically and `nginx` reloads periodically to pick up renewed certs. Changing the domain means editing both `nginx/nginx.conf` and the `domains=(...)` list in `init-letsencrypt.sh`.

## nerdifica-site architecture (Nuxt 4)

Uses the Nuxt 4 `app/` source-directory convention (not the Nuxt 3 flat layout) — components, pages, composables all live under `app/`.

**Niche/tool registry** (`app/composables/useNiches.ts`): niches and tools are not centrally registered by hand. `import.meta.glob` eagerly loads every `app/niches/*/niche.config.ts` and `app/niches/*/tools/*/index.ts` at build time. Adding a new niche or tool means adding a folder in that shape — no router or index file needs editing. Each niche/tool config carries a `LocalizedText` (`{ 'pt-br', 'es', 'en' }`) for its slug, name, description, etc.; the slug itself is translated per locale (e.g. `financas`/`finanzas`/`finance`), not just the surrounding UI strings.

**Routing** (`app/pages/`): `@nuxtjs/i18n` with `strategy: 'prefix'` handles the `/pt-br|es|en/...` prefix automatically. Below that, routes are `[niche]/index.vue`, `[niche]/tool/[tool].vue`, `[niche]/blog/[...slug].vue` — the `tool`/`blog` path segments are **not currently locale-translated** (always English), only the `[niche]` and tool slugs are, via the registry above.

**Content** (`content.config.ts` + `content/<locale>/<niche>/blog/*.md`): three separate Nuxt Content collections (`blog_ptbr`, `blog_es`, `blog_en`), one per locale, each sourced from `<locale>/*/blog/**/*.md`. The blog page resolves which collection to query from the current locale, then does `queryCollection(collection).path(path).first()` where `path` is reconstructed as `/<locale>/<niche>/blog/<slug>`.

**Component auto-import gotcha**: Nuxt prefixes component names by their subfolder under `app/components/` (deduping repeated words), so `app/components/tool/ToolFaq.vue` → `<ToolFaq>` but a hypothetical `app/components/tool/AdSlot.vue` would be `<ToolAdSlot>`, not `<AdSlot>`. Shared components used across page types (header, footer, ad slots) live at the root of `app/components/`, not in a subfolder, specifically to get a predictable tag name. Moving a component between folders requires a full `npm run dev` restart — Vite HMR does not pick up the renamed auto-import.

**Styling**: Tailwind CSS v4, CSS-first config via `@theme` in `app/assets/css/main.css` (no `tailwind.config.js`). Brand color scale (`primary-50…950`) and fonts are defined there.

## nerdifica-api architecture (FastAPI)

Domain-based structure (one folder per niche under `src/`, matching the `nerdifica-site` niche names): each niche folder holds its own `router.py` / `schemas.py` / `service.py`. `src/main.py` just imports and `include_router()`s each niche's router under `/api/v1`. `src/core/` holds cross-domain code (currently just a base `NerdificaException`). Settings are centralized in `src/config.py` via `pydantic-settings`, reading from environment variables (see `.env.example`).
