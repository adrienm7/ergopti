# onboarding (Hammerspoon)

## Purpose

WKWebView-based first-run wizard shown automatically when `config.toml` is absent. Features live locale preview in step 1 (`previewLocale` → `applyStrings()` re-renders the wizard in the chosen language before the user advances), page-as-destroy navigation for clean per-step state, and a single atomic write of `config.toml` at the end via `toml_writer.batch_write()` followed by `hs.reload()`.

## Key files

| File      | Description                                                             |
| --------- | ----------------------------------------------------------------------- |
| `init.lua`| `M.start()` — detects absent config, opens wizard; bridge message router |

## Shared frontend

`_shared/ui/onboarding/` — HTML/CSS/JS shared with the Windows driver; locale strings injected by the host.
