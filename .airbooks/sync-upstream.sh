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
printf 'ok - %s rebased onto %s\n' "$branch" "$target"
printf 'next: push the branch and open a PR\n'
