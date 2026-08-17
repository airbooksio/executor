#!/usr/bin/env bash

# PR gate for the Cloudflare host: typecheck, unit tests, and a real build.
# Scoped to apps/host-cloudflare and its workspace deps — this fork exists to
# deploy that one app, and running the whole upstream monorepo suite here would
# gate our deploys on upstream's unrelated tests.

set -euo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."

bun install --frozen-lockfile >/dev/null

cd apps/host-cloudflare

printf '==> typecheck\n'
bun run typecheck

printf '==> unit tests\n'
bun run test

printf '==> build\n'
bun run build

# The build must produce the SPA the Worker serves; an empty dist would deploy
# a gateway whose console 404s while /mcp still answers, which is a confusing
# half-broken state to debug in production.
if [[ ! -s dist/index.html ]]; then
  printf 'build produced no dist/index.html\n' >&2
  exit 78
fi

printf 'ok - host-cloudflare verified\n'
