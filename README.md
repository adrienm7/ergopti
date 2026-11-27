# @ergopti/hotstrings-web

A small, dependency-free TypeScript hotstring engine for the browser, faithful
to Ergopti's own hotstring semantics. Ergopti's website uses it to emulate
hotstrings, and other editors (BookTool) import it. Its tests replay Ergopti's
shared cross-driver corpus (`static/ergopti_plus/_shared/tests/corpus/hotstrings/`)
live, so the engine stays held to the same contract as the macOS, Linux and
Windows drivers.

## API

```ts
import {
	HotstringMatcher,
	ExpansionUndo,
	expandOutput,
	parseHotstrings,
	serializeHotstrings
} from '@ergopti/hotstrings-web';

const { hotstrings, errors } = parseHotstrings(tomlText);
const matcher = new HotstringMatcher(hotstrings); // options: { terminators, consumed, magicKey }
const undo = new ExpansionUndo(500);

// On each key: `before` is the line's text before the caret.
const e = matcher.match(before, key); // key: a character, 'Enter', 'Tab' or a key name
if (e) {
	const { text, cursor } = expandOutput(e.insert, { selection, values: { title: 'My Book' } });
	// remove e.deleteCount UTF-16 units before the caret, insert `text`,
	// do not insert the key when e.consumedKey is true
	undo.record({ trigger: e.restore, insert: text, at: performance.now() });
} else if (key === 'Backspace') {
	const edit = undo.backspace(performance.now()); // null: delete one character as usual
} else {
	undo.clear();
}
```

- `parseHotstrings(text): { version: 1 | 2; hotstrings: Hotstring[]; errors: { line; message }[] }`
  reads v2 and Ergopti's v1 personal format; `serializeHotstrings(list): string` writes v2.
- `new HotstringMatcher(list, options?)`, `match(before, typed): Expansion | null` where
  `Expansion = { hotstring, deleteCount, insert, consumedKey, restore }`.
- `expandOutput(output, { date?, selection?, values? }): { text; cursor }`.
- `new ExpansionUndo(windowMs = 500)`, `record({ trigger, insert, at })`, `backspace(now)`, `clear()`.
- `HotstringEditor.svelte` (entry `@ergopti/hotstrings-web/HotstringEditor.svelte`): props
  `hotstrings` (bindable), `labels` (partial, English defaults in `DEFAULT_LABELS`), `onchange`.
  Its rules are exported as plain functions (`validateDraft`, `saveDraft`, `importToml`, ...).

## Semantics (Ergopti's contract)

- **When it fires.** `expand = "terminator"` (default) fires on a terminator typed after the
  trigger: Ergopti's defaults are space, Tab, Enter, `★`, `,` `;` `.` `!` `?` `:`.
  `immediate` fires on the trigger's own last character; `enter`, `tab`, `key` only on that key.
  When an immediate and a terminator trigger both fire, the terminator one wins only when it is
  strictly longer. Otherwise the longest trigger wins, then the higher `priority`, then the
  first listed.
- **Terminator.** `echo` (default) types it after the output, `consume` swallows it. The magic
  key `★` is always consumed. A no-break or narrow no-break space before `:` or `;` is tolerated.
  An echoed key with no character (a custom key such as `F2`) comes back with
  `consumedKey: false`, so the caller lets the key do its usual work.
- **Case.** By default the trigger fires typed in lower, Title or UPPER case and the output follows
  (`ppt` → `PowerPoint`, `Ppt` → `PowerPoint`, `PPT` → `POWERPOINT`); another casing fires nothing.
  `conform_case = false` folds the case and keeps the output verbatim (acronyms: `Adn` → `ADN`).
  `case_sensitive = true` fires only on the casing written. Placeholders are never re-cased.
- **Word start.** With `word_start = true` the character before the trigger must not be an ASCII
  letter, a digit, `_`, `@` or any non-ASCII character (the magic key included).
- An output equal to the typed trigger fires nothing.

## The Backspace rule

Within the window (500 ms by default, inclusive) after an expansion, a Backspace removes the
inserted text and gives back what was typed: the trigger as typed, casing included, without a
final magic key, then the terminator when it was echoed (`adn` + Space → `ADN ` → Backspace →
`adn `). A consumed terminator was never typed and does not come back (`btw★` → `btw`). Past the
window, after one undo, or after any other key (`clear()`), Backspace deletes only the output's
last character. This is `_shared/hotstrings/engine/backspace_restore.lua`.

## TOML v2

```toml
format = "ergopti-hotstrings/2"

[[hotstring]]
trigger = "btw"
output = "by the way"
expand = "terminator"     # terminator | immediate | enter | tab | key
terminator = "echo"       # echo | consume
case_sensitive = false
word_start = true
tags = ["common"]

[[hotstring]]
trigger = "sig"
output = "Best regards,\n{cursor}"
expand = "key"
key = "F2"
terminator = "consume"
case_sensitive = false
conform_case = false      # optional, default true
word_start = false
priority = 50             # optional
description = "Mail signature"
```

Omitted fields take the defaults above; an unknown key or a wrong type is reported with its line
and the entry is skipped. A file without `format` is read as v1 (`personal_hotstrings.toml`):
`is_word` → `word_start`, `auto_expand` → `immediate`, `is_case_sensitive_strict` →
`case_sensitive`, `is_case_sensitive` alone → `conform_case = false`, the section → a tag;
`final_result` (cascades) is not kept.

## Placeholders

`{cursor}` (caret position, removed), `{selection}`, `{date}` (yyyy-mm-dd), `{date:DD/MM/YYYY}`
(tokens YYYY, MM, DD), `{value:NAME}` from `values`, `{{` and `}}` for literal braces. Anything
else, such as Typst `#mention("id")[Name]`, is plain text.

## Tests

```sh
npm --prefix packages/hotstrings-web ci
npm --prefix packages/hotstrings-web run coverage   # vitest, 100 % thresholds
npm run test:hotstrings-web                          # from the repository root
```

MIT, see [LICENSE](LICENSE).
