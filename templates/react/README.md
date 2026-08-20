# React App Starter Template

Starter template for a React app on the home platform. Pre-wired with CI/CD, a Dockerfile, and the Postgres/Authentik/Traefik integration points from the [platform contract](../../docs/app-platform.md) — see that doc for what each piece means and how onboarding actually works. This template doesn't re-explain platform mechanics; it just implements them.

## Stack

React + Vite (frontend), Express (backend, serves the built frontend and the API), `pg` (Postgres), `express-openid-connect` (Authentik OIDC), Vitest + Supertest + Testing Library (tests), ESLint.

One container, two roles: Vite only builds the frontend into static files (`npm run build` → `dist/`); Express serves that `dist/` directory *and* the API from a single Node process (`server/index.js`) — there's no separate frontend server in production, matching the platform's one-container-per-app model.

## Using this template

1. Copy this directory's contents into a new app repo (`github.com/bcalaway/<app-name>`).
2. Replace every `REPLACE_WITH_APP_NAME` (in `deploy/docker-compose.yml` and `.github/workflows/cd.yml`) with the app's real name — it must match the ECR repo / IAM role name from `terraform/aws/apps.tf` in `nyc_pa_aws_gitops`.
3. Set `APP_NAME` in the deploy environment to the same value (comes from SSM per the platform's secrets convention, or just hardcode it as a plain env var in `deploy/docker-compose.yml` since it's not a secret).
4. Follow the onboarding checklist in `docs/app-platform.md` (database, Authentik client, Route53 record, IAM role) — these are platform-side steps, not something this template does for you.
5. Build out `src/` (frontend) and `server/` (backend) into the real app. `/health`, `/db-check`, `/login`, `/auth/callback` are working examples, not requirements — replace or extend them.

## Local development

Two processes, same as any Vite + API split — the dev server proxies API calls to the backend so you get hot-reload on the frontend while testing against the real Express routes:

```
npm install
npm run dev:server   # Express on :8000
npm run dev           # Vite dev server, separate terminal
```

`POSTGRES_PASSWORD` / `AUTHENTIK_CLIENT_ID` / `AUTHENTIK_CLIENT_SECRET` are all optional locally — the app degrades gracefully (see `server/db.js` and the `/login` 501 behavior in `server/index.js`) rather than requiring live Postgres/Authentik to run.

To exercise the real production path (Express serving the built frontend, no Vite dev server involved):

```
npm run build
npm start
```

## Auth gating

Once `AUTHENTIK_CLIENT_ID`/`AUTHENTIK_CLIENT_SECRET` are set, every route except `/health`, `/login`, and `/auth/callback` requires an authenticated session — `/api/*` calls get a `401` JSON response, page loads redirect to `/login`. See `server/index.js`'s `RequireAuth`-equivalent middleware. Before those credentials are set (a fresh, not-yet-onboarded app), the app stays fully open rather than locking itself out.

## Tests and lint

```
npm test
npm run lint
```

Both also run inside Docker via the `test` / `lint` build stages — `docker build --target test .` / `docker build --target lint .` — which is what `app-ci.yml` actually runs in CI. Note `test` builds the frontend first (extends the `frontend-build` stage, not `base` directly) since the backend's catch-all route serves `dist/index.html`, and a test exercising that route needs it to actually exist.
