<!-- docs/audits/2026-10-24-keystats-sql-census.md -->

# Census: keystats SQL across the three drivers (PAR-67)

Run on 2026-10-24 against `dev` with `node tools/audit/keystats-sql-census.cjs`, which scans the
keystats source trees of each driver (`windows/modules/keystats`, `macos/modules/keystats`,
`linux/modules/keystats`, `_shared/lua/keystats` and `_shared/lua/sqlite`), keeps the literal
parts of every concatenation chain that opens with an SQL keyword, and replaces each spliced
expression by `?`. Statements are grouped by exact normalized text and by shape (the same text
without the Linux CLI's `json_quote(x) AS x_json` transport wrapper and without column aliases).
Re-run the script before quoting a number: the counts move with every change.

| Driver  | Statements | Distinct exact | Distinct shapes |
| ------- | ---------- | -------------- | --------------- |
| windows | 157        | 144            | 144             |
| macos   | 125        | 99             | 87              |
| linux   | 78         | 65             | 64              |
| shared  | 14         | 14             | 14              |

The parity audit's rough counts (85 macOS, 73 Linux, 66 Windows) predate the scanner and count a
narrower file set; the order of magnitude is the same.

## Families shared by the drivers

- **Manifest projection** (15 statements per driver, one per aggregate table): the same shape on
  all three for `agg_app_day`, `_buckets`, `_burst`, `_session`, `_chars_class`, `_errors`,
  `_layouts`, `_kc_hold`, `_titles`, `_hourly`, `_hourly_min5`; Windows and macOS spell them
  identically, Linux differs only by the CLI transport (`json_quote`) and alias names. These are
  the first entries of the named-query catalogue `_shared/data/db/queries.sql`.
- **Aggregate UPSERTs of the walker flush** (`INSERT INTO agg_app_day_* … ON CONFLICT … DO UPDATE`):
  Windows `keystats_walker_sql.ahk` and macOS `aggregator/sql.lua` are textually identical for
  buckets, burst, chars_class, errors, kc_hold, layouts and session; Linux `sqlite_writer.lua`
  writes the same tables with its own column lists (fewer bucket columns, see the walker
  findings) and a different literal quoting.
- **Event inserts** (`events_*`): Windows and macOS identical; Linux batches multi-row
  `INSERT OR IGNORE` statements.
- **Transactions and metadata** (`BEGIN`, `COMMIT`, `meta` reads and writes): driver-specific
  ownership (Linux `BEGIN IMMEDIATE` through the CLI, macOS ingest transactions, the Windows
  reader cache); not catalogue material.
- **N-gram reads**: Windows and macOS share the shortcut and keycode reads; the token reads
  differ on all three (see finding 7).

## Parity findings in the manifest projection

Each finding names the behaviour that is right under the maintainer's rule (the same behaviour on
all three OS unless there is a good reason) and the side that follows it.

1. **Key hold projection keys (macOS).** The shared dashboard reads `kc_hold[kc].s` and `.n`
   (`_shared/ui/metrics_apps/script.js`); Windows and Linux project `{ s, n, m, tap, hold }`,
   macOS projected `{ sum, count, max, tap, hold }`, so the macOS modifier hold mean read zero.
   Right: the Windows and Linux keys; the macOS reader follows them.
2. **Window titles field (Linux).** The dashboard reads `win_titles`; Windows and macOS project
   it, Linux projected `titles`, so the Linux window-title panel stayed empty. Right:
   `win_titles`; the Linux reader follows it.
3. **Focus-to-first-key latency (macOS, Windows).** macOS and Linux write
   `focus_to_first_key_sum_ms` and `_count` into `agg_app_day_ergo`; only Linux read them back,
   so the macOS focus-latency panel read zero. Right: read them (catalogue `manifest.ergo`).
   Windows writes no focus latency at all: its manifest query stays as is and the gap is the
   Windows side of the metric, not of the query.
4. **System day.** Windows folds `agg_system_day` into `manifest[day]._system`, which both
   dashboards read, and counts battery extrema only over rows that sampled the battery. Linux
   had a `read_system_days` with plain `MIN`/`MAX` and no production caller; macOS writes the
   table and never reads it. Right: the Windows query (catalogue `manifest.system_day`).
5. **Application switches.** Linux aliases the source application inside a subquery so the
   date and application filter applies; Windows and macOS group by `app_from` with a date-only
   filter. Equivalent results under a date-only filter; the catalogue keeps the subquery form,
   which serves both.
6. **Application filter on the manifest.** Linux filters the manifest by application, Windows
   and macOS by date only (their dashboards filter applications in the page). The catalogue
   takes the filter as a parameter, so each driver keeps its own filter builder.
7. **N-gram token reads.** macOS summed with `SUM`, which overflows and sums a malformed counter
   as the number its text starts with (and aborted the family when the text held no number);
   Linux used `TOTAL` and returned such a row raw for the reader to read as zero; Windows
   aggregates the source map in SQL through `json_each`. Right: the Linux form, now the catalogue's
   `ngram.tokens` and `ngram.tokens_by_app`, which macOS and Linux both render. Windows keeps its
   own reads.
8. **Semantic media keys.** Windows validates the grouped rows through temporary tables built
   from the shared `media_schema.sql`; macOS and Linux select them directly. The catalogue
   holds the direct form used by the two Lua drivers.

## Parity findings in the walkers

The Windows walker (`keystats_walker_events.ahk`) is the reference the corpus
`_shared/tests/corpus/keystats/aggregation_vectors.json` pins; macOS and Linux now walk through
`_shared/lua/keystats/walker.lua` and replay the corpus with one shared checker. Each finding is
pinned by the vector named in brackets.

1. **Correction history bound (macOS).** macOS kept every erasable entry of a run without a long
   pause and persists that context; Windows and Linux keep eight (`HIST_CAP`, now a shared
   constant). The outputs are the same (each backspace pops one entry and pushes one); the
   persisted context no longer grows. [`long_run_bounds_the_correction_history`]
2. **Word separators (Linux).** Linux ended a word on space, tab and newline only; Windows and
   macOS also on punctuation and the no-break spaces. [`punctuation_ends_a_word`]
3. **Driver output and streaks (Linux).** Linux broke the same-finger and same-hand runs on every
   synthetic character and every backspace; Windows and macOS let driver output neither extend
   nor break a run, and only a typed backspace breaks it.
   [`synthetic_output_keeps_the_finger_streak`]
4. **Synthetic corrections (Linux).** Linux counted a hotstring erasing its trigger neither as a
   synthetic correction (`es`) nor in the trigger-input pause buckets, and its writer had no
   column for those buckets. [`synthetic_correction_is_not_a_typing_error`]
5. **Typed minutes (Linux).** Linux recorded the exact first and last minute; Windows and macOS
   record the five-minute slot the activity histogram uses.
   [`typed_minutes_use_five_minute_slots`]
6. **Layout count (Linux).** Linux counted the layout once per keystroke; Windows and macOS once
   per typing entry (on Linux, once per flushed application stream).
   [`layout_counts_one_per_typing_entry`]
7. **Manual marker (macOS).** macOS read `meta.s = 0` as synthetic (Lua treats 0 as true);
   Windows reads it as typed, and so does the shared walker.
8. **Activity rows (accepted).** Windows creates an entry's hour and five-minute rows before its
   first keystroke; the shared walker creates them with the first keystroke of each slot, because
   Linux places every keystroke in its own slot. The only difference is an all-zero row that no
   page shows.
9. **Day rollover (macOS, left).** Linux credits the open word, correction, burst and session of a
   context when its gap has passed or the day ends (`settle`, now in the shared walker); macOS
   resets the context at rollover and drops them. Not aligned in this change.
10. **Finger keys (accepted).** Windows keys its finger map on virtual-key codes (the deliberate
    third map of the cross-driver-parity skill); the corpus names macOS keycodes, so the Windows
    replay translates the three keys of the streak vector.

## Status after PAR-67

- The catalogue holds the sixteen manifest queries. macOS and Linux render all of them; Windows
  renders the eleven that were textually identical (`manifest.ergo`, the two media queries,
  `manifest.switches_to` and `manifest.system_day` keep their Windows text: findings 3, 8, 5 and
  4 above).
- The census now counts the migrated statements as catalogue call sites: 11 on Windows, 16 on
  macOS and 17 on Linux (its system-day query is rendered by the manifest and by
  `read_system_days`). The table at the top is the census before the migration.
- The n-gram token reads (finding 7) are catalogued and rendered by macOS and Linux.
- Not catalogued yet: the walker flush upserts (identical on
  Windows and macOS, a different column list and quoting on Linux), the event inserts.
