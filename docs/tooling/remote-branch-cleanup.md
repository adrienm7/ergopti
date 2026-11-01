# Remote branch cleanup

A maintainer action, run on the maintainer's machine: the cloud container's
proxy refuses ref deletion and tag pushes. The fix/<os> integration is on dev
(2026-10-29), so it can run now.

The script first tags the three fix branches, because their audit handovers
cite their original commits and their `.bundle` archives need them as
prerequisites, and the tmp branches whose commits never landed on dev under
their own id. The Mac field branch is not kept,
since every problem it reported is fixed. It then deletes every remote branch
except `dev`, `main`, `sparkle-appcasts` and `gh-pages`.

```sh
git fetch origin --prune
for b in fix/macos fix/linux fix/windows \
    tmp/wip-todo-ae tmp/wip-todo-ae-par30 tmp/wip-todo-af tmp/wip-todo-ag tmp/wip-todo-ag2 tmp/wip-todo-ag3 \
    tmp/wip-todo-ah tmp/wip-ci-fix tmp/wip-fr-uncommitted tmp/wip-field-auto tmp/wip-field-run-checklist \
    tmp/wip-issue103 tmp/wip-issue104; do
  if git rev-parse -q --verify "origin/$b" >/dev/null; then
    git tag -f "archive/${b//\//-}" "origin/$b"
  fi
done
git push origin 'refs/tags/archive/*:refs/tags/archive/*'
git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin \
  | grep -vxE 'HEAD|dev|main|sparkle-appcasts|gh-pages' \
  | xargs -r -n 20 git push origin --delete
```

The resulting tags are `archive/fix-macos`, `archive/fix-linux`,
`archive/fix-windows` and one `archive/tmp-wip-<name>` per tmp branch. After
the cleanup, read the archived commits through those tags.

## What the tmp branches still hold

`git cherry -v origin/dev <branch>` on 2026-10-31, after removing what landed
under another id:

- `tmp/wip-todo-ah`: only a408a29790 (AHK shard split) is still to land; it is
  in TODO's "PC Windows todo". Its `hs.*` cache reset and the four Linux and
  macOS speed-ups landed on 2026-10-31 (`fix/todo-final-p4-ci`).
- `tmp/wip-todo-ag`, `-ag2`, `-ae`, `tmp/wip-field-auto`,
  `tmp/wip-field-run-checklist` and 358e211a10 are on dev. `tmp/wip-ci-fix` is
  on dev under other ids (2fb196a022, 767cf0cb7a, 9c496d384d with the
  fixture-owned machine id, 9b7abbe580, 7feb5a211b, 376b28db82).
- Reference only, replaced: `tmp/wip-issue103` b449da5713 (an old reseal),
  `tmp/wip-issue104` aec2fb58cb (by 2be257c9f5), `tmp/wip-fr-uncommitted`
  0d7e53b28b (by 708bc6671d), `tmp/wip-todo-ae-par30` 41f72525cf (the PAR-30
  Linux gate landed as cd824ccf8e).

Done on 2026-10-31: 262 branches deleted, 222 tips archived under the tag prefix `archive/2026-10-31/`.
