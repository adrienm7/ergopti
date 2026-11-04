# Hotstring TOML Schema

## Entry fields

| Field         | Type            | Required | Default | Description                                                |
| ------------- | --------------- | -------- | ------- | ---------------------------------------------------------- |
| `trigger`     | string          | yes      | —       | The typed abbreviation to expand. UTF-8.                   |
| `replacement` | string          | yes      | —       | The replacement text. May contain the output tokens below. |
| `flags`       | array\<string\> | no       | `[]`    | See flag table below.                                      |

## Flag values

| Flag             | Effect                                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------------------------ |
| `word`           | Only fires when the trigger is preceded by a non-word character (space, punctuation, start-of-buffer). |
| `case_sensitive` | Exact-case match required (default is case-insensitive).                                               |
| `auto`           | Fires without a terminator keystroke (the trigger itself is the terminator).                           |
| `final`          | Skips further substitution passes after expansion.                                                     |

## Output tokens in replacements

All three drivers read one grammar, pinned by
`_shared/tests/corpus/hotstrings/output_token_vectors.json`.

| Token                                | Effect                                                                                  |
| ------------------------------------ | --------------------------------------------------------------------------------------- |
| `{Left}`, `{enter}`, `{F5}`...       | Presses a key of `_shared/modules/actions/send_keys.json`, by id or alias, in any case. |
| `{Left 2}`                           | Presses it that many times, up to `output_key_max_repeat`.                              |
| `{U+27C3}`                           | Types that code point.                                                                  |
| `{{}`, `{}}`                         | Types a brace. `{{}Left}` types the six characters `{Left}`.                            |
| A line break or a tab                | The Enter key or the Tab key.                                                           |
| Anything else in braces, `+ ^ ! # ~` | Literal text.                                                                           |

An output with a key token leaves the caret where the engine cannot read it, so the
driver forgets its typing buffer and the AI context, and the output takes no part in
a cascade. Dates and times come from the dynamic hotstrings, not from a token.

## Category metadata (category.toml)

Each category folder MAY contain a `category.toml` file with display metadata:

```toml
[category]
id          = "autocorrection"
color       = "#00838f"
delay       = 0.5          # time_activation_seconds default for this category
description = "Automatic correction of common typos and accent errors."
```

If absent, defaults from `hotstrings_config.toml` (or its equivalent in each driver) apply.
