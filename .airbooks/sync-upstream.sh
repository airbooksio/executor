#!/usr/bin/env bash

# Rebase this fork's configuration commits onto upstream, in a branch.
#
# We do not carry upstream's .github/workflows: RWX is the CI system here, we
# never run their Actions, and keeping the files means every sync needs the
# GitHub App's workflows permission — which is org-wide, and would let agents
# add Actions to any Airbooks repo. So the rebase deletes them again, and this
# script resolves the modify/delete conflicts that causes whenever upstream has
# edited a workflow we removed.
#
# Usage: .airbooks/sync-upstream.sh [upstream-ref]   (default: upstream/main)

set -euo pipefail

cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

target="${1:-upstream/main}"
branch="upstream-sync-$(date +%Y%m%d-%H%M)"

git fetch upstream --quiet
git fetch origin --quiet
git checkout --quiet -b "$branch" origin/main

# Remembering the resolution makes repeat syncs quieter.
git config rerere.enabled true

drop_upstream_workflows() {
  # Conflicts where upstream changed a file we deleted: stay deleted.
  local paths
  paths="$(git diff --name-only --diff-filter=U | grep '^\.github/workflows/' || true)"
  [[ -n "$paths" ]] || return 1
  printf '%s\n' "$paths" | xargs git rm -q --
  return 0
}

if ! git rebase "$target"; then
  while true; do
    if drop_upstream_workflows; then
      printf 'dropped upstream workflow changes; continuing\n'
    else
      printf 'unresolved conflict outside .github/workflows — resolve by hand, then:\n' >&2
      printf '  git rebase --continue && .airbooks/guard.sh\n' >&2
      exit 1
    fi
    GIT_EDITOR=true git rebase --continue || continue
    break
  done
fi

# Belt and braces: a clean rebase can still leave them if upstream ADDED one.
if [[ -d .github/workflows ]]; then
  git rm -rq .github/workflows
  git commit -q --amend --no-edit
fi

./.airbooks/guard.sh

# Make the branch mergeable into a protected main.
#
# Rebasing replays our config commits with new SHAs, and earlier syncs also
# replayed upstream's own commits — main carries dozens of rebased COPIES of
# upstream work. Git sees two lineages holding the same changes and conflicts
# on upstream files we never touched (85 of them on the 2026-08-19 sync). main
# cannot be force-pushed, so the branch has to absorb it instead.
#
# `-s ours` keeps this branch's tree verbatim and records main as a parent.
# That is only safe while main holds nothing of ours that the rebase did not
# carry forward, so prove it first and refuse rather than discard.
fork_paths=(
  .rwx
  .airbooks
  AIRBOOKS.md
  apps/host-cloudflare/wrangler.jsonc
)

divergent=()
for p in "${fork_paths[@]}"; do
  git diff --quiet origin/main HEAD -- "$p" || divergent+=("$p")
done

if (( ${#divergent[@]} )); then
  printf 'refusing to absorb main: it differs from this branch under\n' >&2
  printf '  %s\n' "${divergent[@]}" >&2
  printf 'A `-s ours` merge would discard that. Rebase picked up something\n' >&2
  printf 'incompletely, or main changed while this ran — reconcile by hand:\n' >&2
  printf '  git diff origin/main HEAD -- %s\n' "${divergent[*]}" >&2
  exit 1
fi

tree_before="$(git rev-parse HEAD^{tree})"
git merge -s ours --no-edit origin/main \
  -m "Merge main into the upstream sync

main and this branch hold the same fork configuration under different commit
SHAs, because rebasing rewrites them. Keeping this branch's tree and recording
main as a parent lets the protected branch move forward without a force push;
every fork-owned path was verified identical first." >/dev/null

if [[ "$(git rev-parse HEAD^{tree})" != "$tree_before" ]]; then
  printf 'the ours-merge changed the tree, which it must never do\n' >&2
  exit 1
fi

./.airbooks/guard.sh >/dev/null
printf 'ok - %s rebased onto %s, main absorbed\n' "$branch" "$target"
printf 'next: push the branch and open a PR\n'
