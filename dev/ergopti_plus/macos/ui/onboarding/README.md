# onboarding (Hammerspoon)

## Purpose

WKWebView host of the shared first-run wizard, opened automatically when
`config.toml` is absent and from Configuration > setup wizard. After the
language and configuration-folder steps, the page asks one opt-in question per
configuration scope (every answer starts at No) and offers the manifest's
recommended items to import. The page answers with manifest paths and values;
the shared `onboarding_answers` contract validates them against the generated
catalogue, and they reach `config.toml` in one versioned `batch_write` before
`hs.reload()`. A re-run shows the values in force.

## Key files

| File       | Description                                                                               |
| ---------- | ----------------------------------------------------------------------------------------- |
| `init.lua` | `M.should_run()` / `M.run()` — opens the wizard; bridge message router; commit and reload |

## Shared frontend and data

- `_shared/ui/onboarding/` — HTML/CSS/JS shared with the Windows and Linux hosts.
- `_shared/ui/_generated/onboarding_catalogue.{js,json}` — the pages, generated
  from the manifest's `[onboarding]` block by `npm run codegen:onboarding-catalogue`.
- `_shared/lua/onboarding_answers.lua` — the validation contract every Lua host uses.
