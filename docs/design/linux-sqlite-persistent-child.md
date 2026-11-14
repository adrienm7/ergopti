<!-- docs/design/linux-sqlite-persistent-child.md -->

# Linux: a persistent sqlite3 child for the metrics store (proposal, maintainer decision)

Status: proposed on 2026-11-14 by worker L of the Linux performance pass; not
implemented. Workers D and L reached the same conclusion: the boot cost left in
the keystats stage is one process per SQL call, and only a long-lived child
removes it.

## What it would save

The Linux driver never links SQLite: every statement goes through the private
runtime's `sqlite3` CLI (`modules/keystats/sqlite_command.lua`), a shell
reading the script on its standard input, then `sqlite3`, then the shell's exit
receipt. Measured on 2026-11-14 (container, system sqlite3 3.45.1, the writer
alone, three sets of 21 warm boots):

| Measure                                              | Value      |
| ---------------------------------------------------- | ---------- |
| One call: shell, `sqlite3` start, script, receipt    | about 4 ms |
| Calls per warm store boot, after the 2026-11-13 cut  | 6          |
| Store boot (open, registration, migrations, walk)    | 29.5 ms    |
| Expected with one child (one start, six round trips) | 5 to 7 ms  |

The six calls are the open probe, the media schema transaction, the device
registration, the two migration checks and the open-walk read. Each later
synchronous read (the dashboard's `query_rows`, `get_meta`) pays the same 4 ms.

## Contract it must keep

- **No luv in the store** (`tests/hardware/run_sqlite_private_no_luv.lua`): the
  child is started with LuaJIT FFI (`pipe2`, `posix_spawn` with file actions,
  `read`, `write`, `waitpid`), as `infra/private_sqlite_file.lua` already uses
  FFI for its descriptors. Stock Lua keeps today's per-call path.
- **A refused statement rolls its batch back.** Today `-bail` makes the CLI exit
  on the first error, which closes the connection and rolls back an open
  `BEGIN`; the shell's `ERGOPTI_SQL_EXIT_STATUS=` line is the receipt. With one
  child, `-bail` still exits on error: an end of file before the receipt is the
  refusal, the child is reaped with `waitpid` for its status, and the next call
  starts a new child. A success is acknowledged by a `.print` line carrying a
  per-call random token after the script, so typed text cannot forge it.
- **Typed text never touches the disk**: the script still travels on a pipe.
- **Diagnostics stay categories** (`sanitise_error`): stderr is a second pipe
  read after the receipt or at exit.
- **Media terminal debt and the private-file debt** keep their exact owners:
  a child whose receipt was not observed is the same unresolved pipe owner as
  today and blocks a reopen.
- **The asynchronous flush transport** (luv, off the boot path) is unchanged.

## Risks to weigh

- A blocked read waits forever where `io.popen` did too; a busy lock still ends
  through `.timeout`, but a hung child would hang the daemon's loop. A deadline
  on the read (poll with a timeout) is needed, which today's path lacks too.
- One more long-lived process holds the store open; `close_db` must end it and
  wait for it, and the ledger import's separate writers must keep working
  through SQLite's own locking.
- The output framing must read results of unknown size until the token, so a
  query whose rows contain the token line is refused by construction (the
  token is drawn after the script is known, as `heredoc_token` does).

## Alternatives measured and set aside

- In-process folder creation through luv (worker D, 2026-11-13): 49 and 44 →
  45 and 43 ms, near the noise, and it broke the no-luv contract; reverted.
- Merging the migration reads into one query: it hands the public migration
  functions a value read before the registration, which their tests drive one
  query at a time.
- Linking `libsqlite3` through FFI: the driver's stated rule is never to link
  SQLite at runtime (`sqlite_writer.lua` header); this would be the largest
  saving and the largest change of contract.
