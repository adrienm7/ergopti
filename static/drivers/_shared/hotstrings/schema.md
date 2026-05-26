# Hotstring TOML Schema

## Entry fields

| Field         | Type            | Required | Default | Description |
|---------------|-----------------|----------|---------|-------------|
| `trigger`     | string          | yes      | —       | The typed abbreviation to expand. UTF-8. |
| `replacement` | string          | yes      | —       | The replacement text. May contain `{date}`, `{time}` template tokens. |
| `flags`       | array\<string\> | no       | `[]`    | See flag table below. |

## Flag values

| Flag              | Effect |
|-------------------|--------|
| `word`            | Only fires when the trigger is preceded by a non-word character (space, punctuation, start-of-buffer). |
| `case_sensitive`  | Exact-case match required (default is case-insensitive). |
| `auto`            | Fires without a terminator keystroke (the trigger itself is the terminator). |
| `final`           | Skips further substitution passes after expansion. |

## Template tokens in replacements

| Token    | Replaced with |
|----------|---------------|
| `{date}` | Today's date in ISO-8601 format (YYYY-MM-DD). |
| `{time}` | Current time in HH:MM format. |

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
