#!/usr/bin/env bash

# Validity check for the Airbooks fork of Executor.
#
# This fork exists to carry deployment configuration, and the ways it can be
# silently wrong are specific: an upstream rebase can revert our wrangler.jsonc
# edits, leaving a Worker that deploys to the wrong hostname or binds someone
# else's D1 database. Both would deploy cleanly and fail in production, so they
# are worth gating on.
#
# Deliberately dependency-free and credential-free: it must run anywhere,
# including on a PR from a fork, without secrets.

set -euo pipefail

cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

config="apps/host-cloudflare/wrangler.jsonc"
deploy_script=".rwx/scripts/deploy.sh"
upstream_placeholder_d1="ae748ca1-032c-4427-a1a0-fe39db77d1a9"
expected_hostname="executor.omega-markets.com"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[[ -f AIRBOOKS.md ]] || fail 'AIRBOOKS.md is missing: the fork must document why it diverges'
[[ -f "$config" ]] || fail "$config is missing"
[[ -f "$deploy_script" ]] || fail "$deploy_script is missing"

grep -qF "\"pattern\": \"$expected_hostname\"" "$config" \
  || fail "$config lost the $expected_hostname custom-domain route (an upstream rebase may have reverted it)"

grep -qF 'custom_domain' "$config" \
  || fail "$config declares the route but not custom_domain: true"

d1_line="$(grep -E '"database_id"' "$config" || true)"
[[ -n "$d1_line" ]] || fail "$config has no database_id"

grep -qF "$upstream_placeholder_d1" "$config" \
  && fail "$config still carries upstream's placeholder database_id; it would bind the wrong D1 database"

printf '%s' "$d1_line" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  || fail "$config database_id is not a concrete uuid: $d1_line"

# The Access variables are live Worker vars preserved by keep_vars; committing
# them here would let a deploy silently change who can reach the gateway.
grep -qE '"(ACCESS_AUD|ACCESS_TEAM_DOMAIN|ADMIN_EMAILS)"[[:space:]]*:' "$config" \
  && fail "$config must not commit Access variables; they are live vars preserved by keep_vars"

grep -qF '"keep_vars": true' "$config" \
  || fail "$config must keep keep_vars enabled or a deploy will drop the live Access variables"

grep -qF 'doppler secrets get ACCESS_SERVICE_TOKEN_SUBJECTS' "$deploy_script" \
  || fail "$deploy_script must load the service-token subject map from Doppler"

grep -qF 'ACCESS_SERVICE_TOKEN_SUBJECTS:${ACCESS_SERVICE_TOKEN_SUBJECTS}' "$deploy_script" \
  || fail "$deploy_script must publish the service-token subject map with the Worker"

# We never run upstream's GitHub Actions: RWX is the CI system here. Carrying
# the files means a push needs the workflows permission, and leaves nine
# workflows one click away from acting on our infrastructure — including their
# Deploy. An upstream sync must not quietly reintroduce them.
if [[ -d .github/workflows ]]; then
  fail 'this fork must not carry .github/workflows; a sync reintroduced upstream'"'"'s Actions'
fi

printf 'ok - airbooks fork configuration is intact\n'
