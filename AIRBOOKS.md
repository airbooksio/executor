# Airbooks fork of Executor

This is `airbooksio/executor`, a fork of
[UsefulSoftwareCo/executor](https://github.com/UsefulSoftwareCo/executor)
(MIT). It exists to hold our **deployment configuration** for the Executor
MCP gateway at `https://executor.omega-markets.com`, so upgrades are a
rebase-and-deploy instead of re-discovering local edits.

We do not carry product changes here. Keep this fork as close to upstream as
possible; anything of general value belongs in an upstream PR.

## What differs from upstream

Our `main` is upstream's `main` plus exactly one commit, touching one file —
`apps/host-cloudflare/wrangler.jsonc`:

1. `routes` — binds the Worker to the `executor.omega-markets.com` custom
   domain. The Workers platform owns that DNS record; the `dns/` root in
   `omega-network-infrastructure` deliberately does not manage it.
2. `d1_databases[0].database_id` — points at our Terraform-created `executor`
   D1 database instead of upstream's placeholder. Not a credential: using it
   requires authenticated access to our Cloudflare account.

Nothing else is modified. No secrets are committed here, ever: the at-rest
encryption key is a `wrangler secret`, and the Access variables
(`ACCESS_AUD`, `ACCESS_TEAM_DOMAIN`, `ADMIN_EMAILS`) are live Worker vars
preserved across deploys by `keep_vars: true`.

## What is actually deployed

The live Worker is **not** necessarily this branch's tip. As of 2026-08-16
the gateway runs a build of upstream `e9815289` plus the config commit
(Worker version `0e326c34-c9f6-4606-865e-d21ebfd74d60`), while this branch
has since been rebased onto upstream `1b5f931d`. A redeploy therefore also
ships every upstream change in that range — read the upstream log before
deploying, and update this section when you do.

```sh
bunx wrangler deployments list   # what Cloudflare is actually serving
```

## Branch protection

`main` is governed by a repository **ruleset**, not classic branch protection —
so the `/branches/main/protection` API returns 404 even though the branch is
protected. Read the ruleset instead:

```sh
gh api repos/airbooksio/executor/rulesets
```

It requires a pull request with one approving review, dismisses stale reviews
on push, requires review threads resolved, requires the `RWX: Executor / Verify`
status check with a branch that is up to date, and blocks deletions and
non-fast-forward pushes. Its bypass-actor list is empty, so the rules apply to
administrators too — nobody can push to `main` directly.

One consequence worth planning around: with one required approval and no
bypass, a single maintainer cannot merge their own pull request, because
GitHub does not allow self-approval.

This changes how upstream is absorbed: `main` can no longer be force-pushed,
so a rebase-and-force is out. Rebase onto upstream in a branch and open a PR:

```sh
git fetch upstream
git checkout -b upstream-sync-$(date +%Y%m%d) origin/main
git rebase upstream/main        # keep our wrangler.jsonc edits
git push origin HEAD
```

The gating check is RWX's `Executor / Verify`, which runs
`.airbooks/guard.sh` first: it asserts the two edits this fork exists to carry
— the custom-domain route and our D1 database id — plus that `keep_vars` stays
on and the live Access variables are never committed. Any of those regressing
would deploy cleanly and fail in production. It needs no dependencies, so it
fails in seconds rather than after a full install and build.

RWX is the only CI system for Airbooks repositories. Upstream's GitHub Actions
workflows (`Deploy`, `Release`, the publish jobs) are **disabled** on this
fork: they target upstream's own cloud deployment, so arming them here would
let a push to our `main` act on their infrastructure. Do not add GitHub
Actions workflows to this repository.

## Remotes

```
origin    https://github.com/airbooksio/executor.git   (this fork)
upstream  https://github.com/UsefulSoftwareCo/executor.git
```

## Upgrading the gateway

The full runbook — including what Terraform owns, the Access model, and the
integration catalog — lives in `docs/executor.md` of
[`airbooksio/omega-network-infrastructure`](https://github.com/airbooksio/omega-network-infrastructure).
Short version:

```sh
git fetch upstream
git rebase upstream/main            # resolve wrangler.jsonc conflicts in our favour
bun install
cd apps/host-cloudflare
bunx wrangler login                 # one-click OAuth; only needed if logged out
bunx wrangler vite build            # or: bunx vite build
bunx wrangler deploy
```

Then verify (no auth needed — an OAuth challenge proves the Access gate is
intact):

```sh
curl -sI https://executor.omega-markets.com/mcp | grep -i www-authenticate
```

Do **not** re-run `apps/host-cloudflare/scripts/deploy.sh` blindly: it rewrites
`database_id` in place, and its D1 lookup mis-parses `wrangler d1 list --json`
when the CLI prints a promo banner (it silently exits before provisioning).
The manual steps above are the supported path for this deployment.

## Boundaries

- Cloudflare **infrastructure** (D1, R2, the Zero Trust Access application,
  its policies, and the headless service token) is Terraform-owned in the
  `executor/` root of `omega-network-infrastructure`. Never create those by
  hand or with wrangler.
- **Integrations, connections, and tool policies** are runtime state in the
  Executor console and its D1 database — not in this repo, not in Terraform.
