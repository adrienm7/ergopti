<!-- docs/design/linux-bytecode-package.md -->

# Linux: a precompiled bytecode package (proposal, maintainer decision)

Status: proposed on 2026-11-11 by the Linux performance pass, approved by the
maintainer the same day for the installed tree only, and implemented
(`infra/bytecode_package.lua`, `install/compile_bytecode.lua`; decision in
`docs/memory/maintainer-decisions.md`). The receipt question was settled by
excluding `.bytecode/` and admitting it by name. Measured after
implementation, in an installed tree under the container session (three runs of
7 boots, medians): spawn to `Daemon ready` 488 → 355 ms, load phase 200 → 90 ms,
boot clock 294 → 255 ms, boot CPU 216 → 180 ms. The manifest's parse costs
0.7 ms per boot.

## What it would save

Before the boot clock starts, the daemon's entry file requires about 440
modules. The boot summary reports that time as `load=` (process start to
`BootProfiler.begin`).

| Measure (Ubuntu 24.04 container, LuaJIT 2.1.1703358377)   | Value         |
| --------------------------------------------------------- | ------------- |
| Modules loaded before the boot clock                      | 439, 6.5 MB   |
| Their compile from source, alone                          | 126 ms        |
| Loading the same chunks as bytecode (debug info kept)     | 8 ms          |
| Process start to boot clock, from source (5 boots)        | 170 to 240 ms |
| Same, through an experimental bytecode searcher (5 boots) | 110 to 130 ms |
| Whole tree as bytecode (986 chunks), against its source   | 8.0 / 11.9 MB |

A boot, and therefore every Reload (a Reload restarts the daemon), would start
about 60 ms sooner. The rest of the compile share stays: the searcher's file
reads and each module's top-level work.

The experiment loaded `string.dump` output through a `package.searchers`
entry placed before the Lua searcher. `string.dump` keeps the chunk name the
chunk was loaded with (`@./infra/monotonic.lua`), so the source-identity checks
(`module_source_identity`, the configuration writer's canonical constructor)
see the names they see from source. The boot then logged the same 65 lines as
a source boot, up to the same refusal (no keyboard in that host). A full
session under bytecode was not run.

## What the decision must settle

1. **Who compiles.** LuaJIT bytecode is not portable across LuaJIT versions,
   nor between GC64 and non-GC64 builds, so the release cannot ship it built
   on the CI runner. Proposed: the installer and the updater compile the
   installed tree with the target's own `luajit` after the payload is placed,
   into `<root>/.bytecode/`, together with a manifest naming `luajit -v`, the
   GC64 flag and each source file's SHA-256.
2. **When bytecode is trusted.** Proposed: only in an installed tree, whose
   payload `install/ownership.sh` already hashes and which nothing edits in
   place, and only when the manifest's runtime line equals the running
   `luajit -v`. A developer run (`tools/dev/run-linux-dev.sh`, any checkout)
   never reads bytecode, so a saved source file always takes effect.
3. **What a mismatch does.** Proposed: the daemon loads from source, logs one
   warning naming the reason (runtime changed, manifest missing or partial),
   and the next updater run recompiles. No per-file fallback mixes the two.
4. **What the ownership receipt covers.** The `.bytecode/` tree is derived, so
   it is either added to the receipt after compiling or excluded and
   rebuilt by the updater. The receipt's hash time (about 9 s natively on a
   full tree) grows with 8 MB more if it is included.

## macOS (measured 2026-11-11, round 3, off-Mac)

Hammerspoon also compiles every module from source at each boot. Under Lua 5.4.6
the whole macOS tree (890 files, 14 MB with `_shared`) compiles in 331 ms
and loads as bytecode (`string.dump`, debug info kept, 9.3 MB) in 38 ms. A
headless boot's first two require stages (`Path: config dir + paths.toml`, 342
modules, and `Config-dependent module requires`, 166) cost 287 and 105 ms of
CPU there, most of it this compile
(`tests/bench/bench_boot_stages.lua`, `tests/bench/bench_lua_paths.lua
--only=compile_driver_sources`). Lua 5.4 bytecode is tied to the interpreter's
minor version and its integer and float sizes, not to the processor, so it
could be produced once per Hammerspoon build rather than per Mac; the same three
questions (who compiles, when bytecode is trusted, what a mismatch does) apply
to the app bundle and its updater.

## Not proposed

- Lazy requires of the optional modules: the 2026-10-24 measurement found 128
  of the boot modules unused before `BootProfiler.complete` but only 21 ms of
  compile, several of them carrying identity or test-seam contracts.
- Stripping debug info (`luajit -b -s`): log tracebacks, the crash reporter and
  the source-identity checks read source names and lines.
