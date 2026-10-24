#!/bin/sh
# Usage: land.sh <branch>  -- rebase a worktree branch onto origin/dev, fast-forward the
# main checkout's dev to it and push each new commit one at a time (one CI run per commit).
set -eu
br="$1"; repo=/home/user/ergopti
cd "$repo"
git fetch -q origin dev
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{w=$2} $0=="branch "b{print w}')
[ -n "$wt" ] || { echo "no worktree for $br"; exit 1; }
git -C "$wt" rebase origin/dev
git merge --ff-only -q origin/dev
for c in $(git rev-list --reverse origin/dev.."$br"); do
  git push -q origin "$c:refs/heads/dev"
  echo "pushed $c $(git log -1 --format=%s "$c")"
done
git merge --ff-only -q "$br"
