# Linux repeat timing: contradictory follow-up

Audited SHA: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`.

**Observed difference, no additional confirmed finding:** Linux's public Main
callback repeats after a one- or two-second gap while idle reset is explicitly
disabled. The ordinary expansion timing gate still works; an expired ordinary
match can fall through to this untimed repeat. Intent is unresolved rather than
inferred from the existing shared pure-rule corpus.

`probe.lua` executes Main's actual complete `handle_char` body, the real
Linux/shared engine, RepeatKey, WordReset, Config resolution, preferences,
ExpansionDelay, magic-key setter, injector and focus guard. The configuration
owner is not a fabricated resolver: it reads a private canonical source via its
file seam. Real setters acknowledge the shorter/unlimited base and changed
magic key. Repeat and idle values are decoded from that source and acknowledged
by their own runtime adoption APIs. Those leaves are not falsely queried through
the separate preference owner's narrower key inventory.

The baseline has empty catalogue metadata; the synthetic ordinary comparison row
has no declared category delay, so the actual resolver uses its base. This is not
a complete startup/menu/profile-loading test. Native keyboard output, XKB mapping,
resident focus observations and the monotonic clock are recording ports. The
actual injector runs, and clipboard entry points throw if accidentally reached.
No native app receiving, keyboard, clipboard or user settings were touched.

Actual defaults read by the program: base delay **0.75 seconds**, complex-key
multiplier **2**, previous-complex-key carry **300 ms**. The shared owner widens
the allowed ordinary interval; it does not change the measured gap. Here the
complex positive control makes the completing keystroke complex, so a one-second
ordinary match is admitted by the real gate. Runtime clock resolution is the
explicit zero-resolution observation port in this proof.

| Actual Main case                             | Gap   | Effective base       | Issued replacement                            |
| -------------------------------------------- | ----- | -------------------- | --------------------------------------------- |
| `po`, default magic                          | 1 s   | 0.75 s               | `o` (repeat)                                  |
| `po`, default magic                          | 2 s   | 0.75 s               | `o` (repeat)                                  |
| Registered `po★ → z`, completing key late    | 1 s   | 0.75 s               | `o` (expired mapping falls through to repeat) |
| Same ordinary row, admitted key              | 0.2 s | 0.75 s               | `z`                                           |
| Same ordinary row, complex completing key    | 1 s   | 0.75 s, multiplier 2 | `z`                                           |
| Actual setter changes magic to `§`           | 2 s   | 0.75 s               | `o` with `§`                                  |
| Old `★` after acknowledged change to `§`     | 2 s   | 0.75 s               | No synthetic output; old key remains literal  |
| Actual setter shortens base                  | 1 s   | 0.1 s                | `o` (repeat)                                  |
| Actual setter makes ordinary delay unlimited | 2 s   | 0                    | `z`                                           |

The source mechanism is explicit: Main first asks the ordinary matcher and
applies `within_delay` to any result. It then runs `RepeatKey.resolve` when the
result is nil. The synthesized repeat result has no timing receipt and is not
sent through `within_delay` again. The pure repeat module accepts buffer/magic/
boundary inputs, not a clock or delay. Its 19-vector corpus says only cases
where the three drivers agree belong there; that corpus does not establish
public timing parity.

The shared expansion-delay definition describes the reference-to-expander gap,
and all TOML mappings are time-gated. Repeat is an engine fallback, not a TOML
mapping. No explicit cross-platform product decision was located requiring or
forbidding a deadline on that fallback. The safe audit result is an available
feature with a **timing-policy difference pending a decision**, not a forced G2
or a claim that the other platform's gate is necessarily wrong. macOS/Windows
public-path conclusions belong to their reviewers' own evidence.

Two complete bounded dry sweeps revisit effective settings, all nine timing and
magic-key cases, ordinary/complex controls, output acknowledgment and the scope
of the policy evidence. Both execute nine cases under genuine LuaJIT and Lua 5.4,
with zero new distinct roots. `receipt.json` retains commands, source/program
hashes and four stdout hashes. No earlier completed audit artifact was changed.

```sh
PATH=/workspace/scratch/parity-toolchain/ci-bin:$PATH LOGNAME=agent \
  luajit probe.lua /path/to/ergopti
```

The same command with `lua` selects Lua 5.4. These are actual business-owner
observations over recording native ports, not measured desktop delivery or
latency evidence.
