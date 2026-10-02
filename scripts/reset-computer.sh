#!/usr/bin/env bash
# Runs on the Dexto computer (brokered gh/git). Idempotent: closes feature PRs, deletes
# feature branches, removes task worktrees, and fast-forwards the base clones.
set -euo pipefail

org=brahma-dexto-demo
repos=(accounts-api risk-engine ops-console)
base_root=/workspace/repos/$org
task_root=/workspace/tasks

is_feature_branch() {
  case "$1" in dexto/* | dexto-evidence/*) return 0 ;; *) return 1 ;; esac
}

for repo in "${repos[@]}"; do
  closed=0
  deleted=0
  while IFS=$'\t' read -r number head; do
    [ -n "$number" ] || continue
    is_feature_branch "$head" || continue
    gh api --method PATCH "repos/$org/$repo/pulls/$number" -f state=closed >/dev/null
    closed=$((closed + 1))
  done < <(gh api --paginate "repos/$org/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | [.number, .head.ref] | @tsv')

  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    is_feature_branch "$branch" || continue
    gh api --method DELETE "repos/$org/$repo/git/refs/heads/$branch" >/dev/null
    deleted=$((deleted + 1))
  done < <(gh api --paginate "repos/$org/$repo/branches?per_page=100" --jq '.[].name')

  base=$base_root/$repo
  removed=0
  if [ -d "$base/.git" ]; then
    while IFS= read -r worktree; do
      case "$worktree" in
        "$task_root"/*)
          git -C "$base" worktree remove --force -- "$worktree"
          removed=$((removed + 1))
          ;;
      esac
    done < <(git -C "$base" worktree list --porcelain | sed -n 's/^worktree //p')
    git -C "$base" worktree prune
    if [ -n "$(git -C "$base" status --porcelain)" ]; then
      echo "$repo: base clone has uncommitted changes; stopping" >&2
      exit 1
    fi
    git -C "$base" checkout --quiet main
    while IFS= read -r branch; do
      if is_feature_branch "$branch"; then git -C "$base" branch --quiet -D -- "$branch"; fi
    done < <(git -C "$base" for-each-ref --format='%(refname:short)' refs/heads)
    git -C "$base" fetch --quiet --prune origin
    git -C "$base" merge --quiet --ff-only origin/main
  fi
  echo "$repo: closed $closed PRs, deleted $deleted branches, removed $removed worktrees, main=$(git -C "$base" rev-parse --short HEAD 2>/dev/null || echo missing)"
done
