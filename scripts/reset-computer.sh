#!/usr/bin/env bash
# Runs on the Dexto computer (brokered gh/git). Idempotent: closes feature PRs, deletes
# feature branches, removes task worktrees, and fast-forwards the base clones.
set -euo pipefail

org=brahma-dexto-demo
repos=(accounts-api risk-engine ops-console)
base_root=/workspace/repos/$org
task_root=/workspace/tasks
# Task folders of earlier takes whose worktrees are already gone; their reports are stale.
task_dirs=("$task_root/account-risk-score" "$task_root/account-risk-redelivery" "$task_root/before-staging")

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
          task_dirs+=("$(dirname "$worktree")")
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
    # Drop the deleted branches' commits so a new take cannot pick them up again.
    git -C "$base" reflog expire --expire=now --all
    git -C "$base" gc --quiet --prune=now
  fi
  echo "$repo: closed $closed PRs, deleted $deleted branches, removed $removed worktrees, main=$(git -C "$base" rev-parse --short HEAD 2>/dev/null || echo missing)"
done

# Remove the takes' leftover task folders (old delivery reports and test output), but only
# when no git worktree of any repository is still inside them.
for dir in "${task_dirs[@]}"; do
  case "$dir" in "$task_root"/?*) ;; *) continue ;; esac
  [ -d "$dir" ] || continue
  if [ -n "$(find "$dir" -mindepth 2 -maxdepth 2 -name .git -print -quit)" ]; then
    echo "kept $dir: it still holds a worktree"
    continue
  fi
  rm -rf -- "$dir"
  echo "removed task folder $dir"
done
