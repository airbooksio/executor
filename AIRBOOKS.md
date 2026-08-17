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

## Remotes

```
origin    https://github.com/airbooksio/executor.git   (this fork)
upstream  https://github.com/UsefulSoftwareCo/executor.git
```

## Deploying through RWX (preferred)

`.rwx/deploy.yml` defines two lanes so deploys need no personal Cloudflare
OAuth grant:

- **`Executor / Verify`** — every PR: typecheck, unit tests, and a real build
  of `apps/host-cloudflare`, with an assertion that the build produced a SPA.
  No credentials.
- **`Deploy the Executor gateway`** — an RWX **dispatch** on `main` with an
  explicit `confirm` parameter. It builds, runs `wrangler deploy` with a
  scoped Cloudflare API token fetched from Doppler over OIDC, then verifies
  that `/mcp` still answers with an OAuth challenge and fails loudly if it
  does not.

Deploy is deliberately **not** automatic on push to `main`: our `main` tracks
upstream, so an unattended deploy would ship upstream changes nobody reviewed.

### One-time setup (manual, and not yet done)

The lane is inert until these exist. Nothing here can be automated — each step
is a console action or a credential issuance:

1. **Connect `airbooksio/executor` to RWX** and point it at `.rwx/deploy.yml`.
2. **Create the RWX vault `executor-deploy`**, locked to this repo, with a
   Doppler OIDC provider and a var `DOPPLER_OIDC_IDENTITY_ID`.
3. **Create the Doppler project `executor-gateway`, config `deploy`**, holding
   `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, plus a Doppler OIDC
   identity trusted by that vault.
4. **Issue the Cloudflare API token** — account-scoped, minimum viable set:
   Workers Scripts **Edit**, Workers Routes **Edit** (the custom domain), D1
   **Read**, Workers R2 Storage **Read**, Account Settings **Read**. It needs
   no Access, DNS, WAF, or account-membership authority. Per the governance
   repo's ownership of Cloudflare token policy, declare its permission scope
   in `omega-cloud-governance` (`stacks/cloudflare-access`) alongside the
   existing network tokens; issuance and secret storage stay manual.

Until then, deploy from a laptop with the fallback below.

## Upgrading the gateway (laptop fallback)

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
