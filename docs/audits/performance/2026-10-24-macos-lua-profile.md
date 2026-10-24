# macOS driver: pure-Lua profile, measured off-Mac (2026-10-24)

This pass explains the Lua share of the macOS field timings listed in the
handover of 2026-10-24 (menu rebuild 113-247 ms, boot stages, preview 21-29 ms
per key, preferences writes of 300 operations, ingest tick 1.0-1.5 s). The
Hammerspoon runtime is Lua 5.4, so every number below is `lua5.4` running the
real driver modules under the stubbed Hammerspoon test harness. Native work
(Accessibility, `hs.task`, canvas, `hs.menubar`, SQLite, Karabiner) is not
reproduced and is listed at the end as needing the Mac's log lines.

## Provenance

- Host: Linux container, 4 vCPU, Lua 5.4.6, lua-luv for wall time. Absolute
  numbers are not Mac numbers; ratios and operation counts are what transfer.
- Workload: the shipped hotstring packs (`_shared/modules/hotstrings/`
  `magickey.toml`, `autocorrection.toml`, `french/magickey.toml`,
  `french/autocorrection.toml`, 4280 registered mappings), the generated
  `macos/_generated/config_template.toml` (11 KB, 332 leaves) and French typing
  with one continuity-breaking pause per sentence.
- Method: median, minimum and maximum of 7 or 9 runs, CPU (`os.clock`) and wall
  (`luv.hrtime`), after a full GC. Attribution through a clock-weighted
  `debug.sethook` sampler (hook overhead inflates absolute sampled time; only
  shares are read from it), and through call-counting wrappers.
- Noise: the final A/B ran while two full test suites used the other cores.
  Untouched paths (TOML parse, keystats walk) moved by up to 40 % between
  identical runs, so both medians and minima are given, and the counted
  operations (decodes, scans, `string.lower` calls) are the stable evidence.

## Reproduce

From `static/ergopti_plus/macos` (POSIX shell, `apt install lua5.4 lua-luv`):

```sh
lua5.4 tests/bench/bench_lua_paths.lua                       # every workload
lua5.4 tests/bench/bench_lua_paths.lua --only=preferences_save --runs=9
lua5.4 tests/bench/bench_lua_paths.lua --profile=hotstring_load_warm
```

For an A/B, export the base revision (`git archive origin/dev | tar -x -C

<dir>`), copy the bench file into the export's `tests/bench/`, and alternate
the two trees.

## Results per field timing

| Path (workload)                                          | Before: median / min | After: median / min | Lever |
| -------------------------------------------------------- | -------------------- | ------------------- | ----- |
| One-toggle preferences save (`preferences_save`)         | 164-192 / 140 ms     | 101-140 / 89 ms     | 1, 3  |
| Inline parent scan, 300 rows (`inline_parents_300_rows`) | 46-73 / 43 ms        | 11-18 / 11 ms       | 2     |
| `trig_lower`, 100000 calls (`trig_lower_100k`)           | 141-208 / 120 ms     | 57-80 / 52 ms       | 4     |
| Warm four-pack hotstring load (`hotstring_load_warm`)    | 289-327 / 219 ms     | 259-278 / 204 ms    | 4     |
| Cold `magickey.toml` parse (`toml_parse_magickey`)       | 60-86 / 50 ms        | unchanged           | none  |
| One 5 s ingest walk, 40 keys (`keystats_walk_tick`)      | 1.1-1.9 ms           | unchanged           | none  |
| 30000-key ingest backlog walk (`keystats_walk_backlog`)  | 958-996 ms           | unchanged           | none  |
| Compile all 689 driver and shared sources, 11.3 MB       | 332-412 ms           | unchanged           | none  |

Quiet-host single measurements taken while developing: preferences save
246 ms before, 120 ms after lever 1, 69-77 ms after lever 3.

### Preferences writes

One menu toggle saved the full loaded state as 83 batch operations. Counting
the work showed the same `config.toml` text decoded 17 times and scanned by
`RecordScanner.scan_records` 10 times per save, by independent owners
(preferences, record list, wrap pairs, inline parents, batch writer, personal
metadata). Separately, `TomlWriter.source_inline_scalar_parents` compared every
pair of rows and lowercased segments on each comparison: 181 200
`string.lower` calls for 300 rows. The field's "300 operations" save pays that
quadratic term in full.

The pure-Lua part of a save is now about 70-100 ms here. The remaining share is
spread across `prepare_batch` (row validation and rendering), the memo copies
and `RecordList.prepare`; none dominates. The field's `Slow preferences save`
line splits `prepare` from `write`: `write` is the native atomic publication
and must be read from the Mac.

### Boot: hotstring load

At boot `init.lua` defers the sort and loads each common file through
`keymap.load_toml`; on a warm boot the TOML snapshot cache (`adapters/toml_cache`)
replaces the parse (17 ms instead of 65 ms for `magickey.toml`). What remains
is registration: `Registry.add` and its per-variant `add_raw` (about 60 %), the
single final sort (about 10 %, 12 ms for 4280 mappings) and the per-load
rollback snapshot (`registry_groups.snapshot_registry`, about 11 %, the single
hottest line). `trig_lower` was 11 % and is now a direct `string.lower` for
ASCII text.

### Boot: module compilation

Compiling the 689 non-test Lua files of the driver and `_shared/lua` (11.3 MB)
takes 330-410 ms here. Loading the 135 modules reachable from `init.lua`'s
direct requires under the stubs cost 100-160 ms including 53-88 ms of
compilation. If the Mac's `Boot stage requires:` lines show a comparable share,
the lever is fewer eager requires or precompiled chunks, not faster Lua.

### Keystats ingest

A normal tick (every 5 s, `keystats.ingest_tick_ms`) walks a few dozen keys:
about 1.5 ms of Lua plus 2 ms to JSON-encode the n-gram context, which happens
twice per tick (rollback snapshot and persistence). The walker costs about
20-30 µs per key (seven n-gram key concatenations, one key string per pause
bucket, a `table.remove(…, 1)` on a 50-entry list), so 1.0-1.5 s ticks match a
backlog of roughly 30 000-50 000 keys, the foreign `data.sql` rebuild
(`_rebuild_aggregates_from_raw`) or native SQLite work, not a steady state. The
`Slow ingest tick` line names the phase; read it before optimising.

The per-application backspace history (`ctx.hist`) is reset only by a pause of
at least `keystats.max_keystroke_delay_ms`. A synthetic stream without such a
pause grew it to 12.8 MB of JSON after 150 000 keys, encoded twice per tick.
Real typing pauses, so this is a hypothesis to check against the Mac's tick
lines, not a confirmed defect.

## Levers committed (branch `agent/macos-lua-perf`)

1. `perf(toml): reuse decoded config text across one preferences save` —
   `Codec.decode_with_shapes` keeps the four newest texts and returns a private
   deep copy with its receipts re-bound. 17 parses per save become 1.
2. `perf(toml): find nested batch rows in one walk per row` — a trie of folded
   segments replaces the pairwise overlap scan; 181 200 lowercase calls become
   3000 for 300 rows.
3. `perf(toml): reuse record scans of one text across a preferences save` —
   the same bounded memo for `scan_records`, keyed by text and header grammar;
   the memo and its graph clone live once in `toml_codec/source_memo.lua`.
4. `perf(text-utils): fold ascii-only text without a per-character callback` —
   `trig_lower` and `repl_upper` skip the per-codepoint gsub callback for ASCII
   input; a load-time assertion keeps every case-table key multibyte.

Each has a regression test that fails on the previous code (counted parses,
scans, `string.lower` or `gsub` calls) plus equivalence cases. Levers 1 to 3
are in `_shared/lua` and were also run under the Linux driver (LuaJIT).

## Candidates not taken

- Registry rollback snapshot per `load_toml`: it copies every mapping for every
  group loaded, so boot cost grows with groups x mappings. A copy-on-write
  journal would remove it, but the snapshot is part of the registry
  transaction and publication-owner protocol another agent is reworking.
  Reported, not changed.
- `Registry.add` / `add_raw`: per-mapping string keys, `pcall(utf8.offset)` for
  first and last codepoints, case variants. Each item is a few percent; an ASCII
  fast path for the codepoint helpers is the cheapest next step.
- Cold TOML hotstring parse (`toml_codec/reader.lua` `parse_entry` and
  `skip_ws`, 75 % of a cold parse): only paid when a pack changes, because the
  snapshot cache serves warm boots.
- Keystats walker: cache the pause-bucket keys per application-day and replace
  the shifting `recent_typing` list with a ring. Only backlogs would notice.

## Not measurable here: read these Mac log lines

- Menu rebuild 113-247 ms: `Menu tree rebuilt … Slowest:` and the `menu_item`
  phase family. The row builders are being moved to `_shared` (PAR-66) and were
  not profiled here; `hs.menubar` construction and the canvas badge are native.
- Preview 21-29 ms per key: the `preview` phase family splits providers,
  resolution and total. Resolution is a bucket scan; the tooltip canvas, the
  agent observer and LLM timer calls are native or belong to the LLM prediction
  orchestration, which this pass does not rewrite.
- Boot: `Boot stage requires:` and `Boot sub-stage:` for the compile share
  above, and `Common hotstring load:` for the registration share.
- Preferences: the `write=` part of `Slow preferences save`.
- Ingest: the phase split of `Slow ingest tick` (`foreign`, `commit`, `append`
  are native or file I/O).
- Every `held the main thread … Phases inside the hold:` line, for attribution
  of anything above that is not listed.
