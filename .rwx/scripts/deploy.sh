#!/usr/bin/env bash

# Deploy the Cloudflare host Worker to executor.omega-markets.com.
#
# Credentials: a scoped Cloudflare API token fetched from Doppler over OIDC at
# run time. No static cloud credentials live in this repo or in the RWX vault,
# and nothing is written to disk outside the ephemeral Doppler scope.
#
# This publishes Worker CODE only. D1, R2, the Zero Trust Access application,
# its policies, and the service token are Terraform-owned in the executor/ root
# of omega-network-infrastructure. The Access variables (ACCESS_AUD,
# ACCESS_TEAM_DOMAIN, ADMIN_EMAILS) are live Worker vars preserved across
# deploys by `keep_vars: true` in wrangler.jsonc — this script never sets them,
# so it cannot silently widen who reaches the gateway.

set -euo pipefail

: "${EXECUTOR_CONFIRM:?EXECUTOR_CONFIRM is required}"
: "${EXECUTOR_HOSTNAME:?EXECUTOR_HOSTNAME is required}"
: "${EXECUTOR_DOPPLER_PROJECT:?EXECUTOR_DOPPLER_PROJECT is required}"
: "${EXECUTOR_DOPPLER_CONFIG:?EXECUTOR_DOPPLER_CONFIG is required}"
: "${RWX_DOPPLER_OIDC_TOKEN:?RWX_DOPPLER_OIDC_TOKEN is required}"
: "${DOPPLER_OIDC_IDENTITY_ID:?DOPPLER_OIDC_IDENTITY_ID is required}"

if [[ "$EXECUTOR_CONFIRM" != "true" ]]; then
  printf 'Refusing to deploy without confirm=true.\n' >&2
  exit 78
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

doppler oidc login \
  --identity "$DOPPLER_OIDC_IDENTITY_ID" \
  --token "$RWX_DOPPLER_OIDC_TOKEN" \
  --scope "$PWD"

cleanup() {
  doppler oidc logout --scope "$PWD" >/dev/null 2>&1 || true
  doppler configure unset token --scope "$PWD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

CLOUDFLARE_API_TOKEN="$(
  doppler secrets get CLOUDFLARE_API_TOKEN --plain \
    --project "$EXECUTOR_DOPPLER_PROJECT" --config "$EXECUTOR_DOPPLER_CONFIG"
)"
CLOUDFLARE_ACCOUNT_ID="$(
  doppler secrets get CLOUDFLARE_ACCOUNT_ID --plain \
    --project "$EXECUTOR_DOPPLER_PROJECT" --config "$EXECUTOR_DOPPLER_CONFIG"
)"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

# Presence checks only — never echo a credential.
[[ -n "$CLOUDFLARE_API_TOKEN" ]] || { printf 'CLOUDFLARE_API_TOKEN is empty.\n' >&2; exit 78; }
[[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || {
  printf 'CLOUDFLARE_ACCOUNT_ID is not a 32-character account id.\n' >&2
  exit 78
}

# The committed wrangler.jsonc must already point at our D1 database; a
# placeholder id would deploy a Worker bound to someone else's database.
#
# Parsed with grep, not jq: wrangler.jsonc is JSONC — `//` comments and
# trailing commas — which jq rejects outright ("Invalid numeric literal"),
# leaving the id empty and failing this check on a perfectly good config.
# .airbooks/guard.sh asserts the same thing the same way.
configured_db="$(
  grep -E '"database_id"' apps/host-cloudflare/wrangler.jsonc |
    grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
    head -n1
)"
if [[ -z "$configured_db" ]]; then
  printf 'wrangler.jsonc has no concrete D1 database_id.\n' >&2
  exit 78
fi

cd apps/host-cloudflare

printf '==> build\n'
bun run build

# A deploy whose SPA did not build would serve a gateway with a 404 console
# while /mcp still answers — a confusing half-broken state to debug live.
if [[ ! -s dist/index.html ]]; then
  printf 'build produced no dist/index.html\n' >&2
  exit 78
fi

printf '==> deploy\n'

# Capture wrangler's output rather than letting it stream to the task log,
# because we have to assert on it.
#
# On 2026-08-19 (run 00c91798) `wrangler deploy` printed its banner, exited 0
# after 1.3 seconds, uploaded nothing, and the run went green — Cloudflare
# recorded no new version at all. A zero exit does not prove a deploy happened,
# so require wrangler's own report of the version it published. Debug logging
# is on so that a silent no-op is diagnosable from the failure output instead
# of needing another round trip.
deploy_out="$(mktemp)"
set +e
WRANGLER_LOG=debug bunx wrangler deploy >"$deploy_out" 2>&1
wrangler_status=$?
set -e

version_id="$(sed -n 's/.*Current Version ID:[[:space:]]*\([0-9a-f-]\{36\}\).*/\1/p' "$deploy_out" | tail -n1)"

if [[ "$wrangler_status" -ne 0 || -z "$version_id" ]]; then
  printf '==> wrangler deploy output\n' >&2
  cat "$deploy_out" >&2
  printf '\nwrangler deploy published no version (exit %s).\n' "$wrangler_status" >&2
  printf 'The gateway is still serving whatever it served before this run.\n' >&2
  exit 78
fi

tail -n 20 "$deploy_out"
printf '==> published version %s\n' "$version_id"

# This proves the gate is intact, not that anything was deployed: it passes
# just as happily against the previously running Worker. The version assertion
# above is what proves a deploy happened.
printf '==> verify the Access gate still answers with an OAuth challenge\n'
challenge="$(curl -sS -o /dev/null -D - "https://${EXECUTOR_HOSTNAME}/mcp" | tr -d '\r' | grep -i '^www-authenticate:' || true)"
if [[ "$challenge" != *"Bearer"* ]]; then
  printf 'Post-deploy check failed: %s/mcp did not return an OAuth challenge.\n' "$EXECUTOR_HOSTNAME" >&2
  printf 'The Worker may be serving unauthenticated. Investigate immediately.\n' >&2
  exit 78
fi

printf 'ok - deployed and Access gate verified\n'
