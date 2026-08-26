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

Each push to `main` rematerializes `ACCESS_SERVICE_TOKEN_SUBJECTS` from
Doppler `executor-gateway` / `deploy` onto the Worker (`wrangler deploy
--var`). `keep_vars` preserves the other Access bindings; it does not
refresh that mapping unless this deploy lane runs.

```sh
bunx wrangler deployments list   # what Cloudflare is actually serving
```

## Absorbing upstream

```sh
.airbooks/sync-upstream.sh      # rebases onto upstream/main in a branch
git push origin HEAD            # then open a PR
```

`main` cannot be force-pushed, so the sync lands as a pull request.

The script finishes by absorbing `main` with `git merge -s ours`, which keeps
the rebased tree verbatim and records `main` as a parent. That step is not
cosmetic: rebasing rewrites our config commits, and earlier syncs also replayed
upstream's own commits, so `main` carries dozens of rebased *copies* of upstream
work. Git sees two lineages holding the same changes and conflicts on upstream
files we never touched — 85 of them on the 2026-08-19 sync. Since `main` cannot
be force-pushed, the branch absorbs it instead.

`-s ours` discards whatever the other side has, so the script first proves
`main` holds nothing of ours that the rebase missed: it compares `.rwx`,
`.airbooks`, `AIRBOOKS.md`, and `apps/host-cloudflare/wrangler.jsonc` against
the branch and refuses if any differ, rather than silently dropping a change.
It also asserts the merge left the tree byte-identical.

The gating check is `.airbooks/guard.sh`, which asserts the edits this fork
exists to carry — the custom-domain route and our D1 database id — plus that
`keep_vars` stays on and the live Access variables are never committed. Any of
those regressing would deploy cleanly and fail in production.

**This fork does not carry `.github/workflows`.** RWX is the CI system; we
never run upstream's Actions, and their `Deploy` targets upstream's own
infrastructure. Carrying the files also made every sync require the GitHub
App's `workflows` permission, which is org-wide — granting it would let agents
add Actions workflows to any Airbooks repo. `sync-upstream.sh` deletes them
again and resolves the modify/delete conflicts that causes when upstream edits
one; the guard fails if any reappear.

## Remotes

```
origin    https://github.com/airbooksio/executor.git   (this fork)
upstream  https://github.com/UsefulSoftwareCo/executor.git
```

## Deploying

The full runbook — what Terraform owns, the Access model, the integration
catalog — lives in `docs/executor.md` of
[`airbooksio/omega-network-infrastructure`](https://github.com/airbooksio/omega-network-infrastructure).

Once the sync above is merged, deploy from `main`:

```sh
bun install
cd apps/host-cloudflare
bunx wrangler login                 # one-click OAuth; only needed if logged out
bunx vite build
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

- Cloudflare **infrastructure** (D1, R2, the Zero Trust Access application
  and its policy) is Terraform-owned in the `executor/` root of
  `omega-network-infrastructure`. Never create those by hand or with wrangler.
  There is deliberately no shared service token: agents authenticate as their
  own operator through Cloudflare Access.
- **Integrations, connections, and tool policies** are runtime state in the
  Executor console and its D1 database — not in this repo, not in Terraform.
