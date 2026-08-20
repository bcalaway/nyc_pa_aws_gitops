# Multi-stage build following the convention app-ci.yml (nyc_pa_aws_gitops)
# relies on: a `lint` stage and a `test` stage ahead of the final runtime
# stage, so the platform's CI workflow stays language-agnostic instead of
# hardcoding per-language tooling. `docker build` with no --target builds
# the last stage (`final`) -- exactly what app-build-push.yml pushes to ECR.
#
# `test` extends `frontend-build` rather than `base` directly: the server's
# catch-all route serves the built frontend from dist/, so a test asserting
# that route's behavior needs dist/ to already exist -- extending `base`
# alone (skipping the build) would make that test fail for a reason that
# has nothing to do with the test itself.

FROM node:24-slim AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .

FROM base AS lint
RUN npm run lint

FROM base AS frontend-build
RUN npm run build

FROM frontend-build AS test
RUN npm test

FROM node:24-slim AS final
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY server/ server/
COPY --from=frontend-build /app/dist dist/
EXPOSE 8000
CMD ["node", "server/index.js"]
