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
bunx wrangler deploy

printf '==> verify the Access gate still answers with an OAuth challenge\n'
challenge="$(curl -sS -o /dev/null -D - "https://${EXECUTOR_HOSTNAME}/mcp" | tr -d '\r' | grep -i '^www-authenticate:' || true)"
if [[ "$challenge" != *"Bearer"* ]]; then
  printf 'Post-deploy check failed: %s/mcp did not return an OAuth challenge.\n' "$EXECUTOR_HOSTNAME" >&2
  printf 'The Worker may be serving unauthenticated. Investigate immediately.\n' >&2
  exit 78
fi

printf 'ok - deployed and Access gate verified\n'
