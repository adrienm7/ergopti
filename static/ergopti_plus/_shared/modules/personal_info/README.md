# `_shared/modules/personal_info/fields.toml` — Which Personal Values Are Secrets

## Purpose

`fields.toml` is the **single source of truth** for two questions every driver
has to answer identically:

1. Which `personal_info.toml` fields are financial or identity **secrets**.
2. **How much** of such a value may appear on screen before it is typed.

It exists because the same four fields — IBAN, BIC, credit card, social-security
number — were already hand-repeated at four unrelated sites, with no gate
between them:

| Driver  | Site                                                       |
| ------- | ---------------------------------------------------------- |
| macOS   | `modules/dynamic_hotstrings/rules_engine.lua`              |
| Linux   | `modules/dynamic_hotstrings/prefix_rules.lua`              |
| Windows | `modules/dynamic_hotstrings/dynamic_hotstrings.ahk`        |
| shared  | `lua/dynamic_hotstrings/init.lua` (`compute_prefix_counts`) |

Four hand-written lists is four chances for one to drift, and the failure is
silent in the worst direction: a field that stops being classified as a secret
does not error, it just starts being shown.

---

## What this file is NOT

**It is not a privacy setting.** Nothing here changes what the driver **types**.
A masked value is masked in the preview bubble only; the expansion is always the
full value, and a test at each driver's injection seam pins that.

**It is not the `is_private` flag.** `is_private` answers "may this be
persisted", and its answer is always no for anything built from
`personal_info.toml`. This file answers a different question — "may this be
*shown*" — and the two disagree deliberately: the phone number is private
(never logged) and unmasked (shown in full), because a log is read later by
whoever has the file and a bubble is read now by the person who typed it.

**It is not a list of "personal data".** Every field in `personal_info.toml` is
personal. The question is narrower: does seeing this value, over a shoulder or
in a screen share, hand someone something they can use. A first name does not.
An IBAN does.

---

## Why every field is listed, including the unmasked ones

`masked = false` is written out rather than left implicit, because absence is
ambiguous. A field missing from this file and a field misspelled in one driver's
own list look exactly the same from here — and the second one reveals a value
nobody decided to reveal. Listing all of them makes a missing entry a
detectable state rather than a default.

---

## The reveal policy

| Key                    | Meaning                                                     |
| ---------------------- | ----------------------------------------------------------- |
| `mask_char`            | The glyph a hidden position is drawn as (U+2022).            |
| `reveal_head`          | Characters kept visible at the start.                        |
| `reveal_tail`          | Characters kept visible at the end.                          |
| `min_length_to_reveal` | Below this length, nothing is revealed.                      |
| `preserve_separators`  | Spaces stay as spaces instead of becoming mask characters.   |

The tail is the larger of the two because the tail is what a user **checks**:
the last four digits are how a bank, a card issuer and a phone company all ask
you to identify an account, and the bubble exists to confirm *which* of your
values is about to be typed. The head exists so the row still reads as an IBAN
rather than as a row of dots.

`min_length_to_reveal` is not theoretical. A BIC is eight characters, and
head 2 + tail 4 would show six of them.

---

## How a driver consumes it

Through its own fail-fast reader, in the same shape as
`_shared/modules/timings/constants.toml`: resolve the shared path, parse, and
**error** if the file is missing. No driver keeps a fallback copy — a fallback
is the second source this file exists to remove.

The masking itself is `_shared/lua/personal_info/mask.lua` for the two Lua
drivers. Windows needs a hand-written AutoHotkey twin, and the shared README
obliges any such twin to be pinned by a corpus: that corpus is
`_shared/tests/corpus/personal_info/mask_vectors.json`, replayed unmodified by
every driver's suite.

---

## Windows is not wired to this yet

The fields this file classifies are not in the Windows preview index at all:
`@iban★`, `@cb★` and `@ss★` are registered by direct `CreateHotstring` calls in
AutoHotkey code, while the index is built exclusively from the TOML categories
listed in `_PREFIX_WATCHER_CATEGORIES`. There is nothing on screen there for a
mask to attach to, so making the requirement *observable* on Windows is its own
piece of work and is tracked separately. This file is written for three drivers
because the answer must not differ between them once the third arrives.
