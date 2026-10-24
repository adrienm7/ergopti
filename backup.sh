#!/bin/sh
# Until 15:30 UTC, every 4 minutes: back up the local worktree branches and the coordinator state to origin
# agent/* refs (no CI listens on agent/*), so a container restart during the usage-limit pause loses nothing.
S=/tmp/claude-0/-home-user-ergopti/a1289939-fd47-5b65-a929-48c61fdb6fa0/scratchpad
R=/home/user/ergopti
end=$(date -u -d '2026-10-24 15:30' +%s)
last=
while [ "$(date +%s)" -lt "$end" ]; do
  refs=$(git -C "$R" for-each-ref --format='+%(refname):refs/heads/agent/%(refname:lstrip=2)' 'refs/heads/wt/' 'refs/heads/land/' | sed 's#agent/wt/#agent/wt-#; s#agent/land/#agent/land-#')
  git -C "$R" push -q origin $refs && echo "$(date -u +%T) branches ok"
  rm -f "$S/.coord-index"
  tree=$(cd "$S" && GIT_DIR="$R/.git" GIT_WORK_TREE="$S" GIT_INDEX_FILE="$S/.coord-index" sh -c 'git add -f COORD.md AGENT-BRIEF.md remote-preamble.txt land.sh todo.md remote local-prompts wf-review.js backup.sh && git write-tree')
  if [ -n "$tree" ] && [ "$tree" != "$last" ]; then
    c=$(git -C "$R" commit-tree "$tree" -m "chore: coordinator state backup")
    git -C "$R" push -q -f origin "$c:refs/heads/agent/coordinator-state" && last=$tree && echo "$(date -u +%T) state ok"
  fi
  sleep 240
done
