# `metrics_typing/_generated/` — Auto-generated JS files

All files in this directory are **auto-generated** and must not be edited manually.
Run the corresponding npm script to regenerate.

| File                | Generator script                  | Status                                                            |
| ------------------- | ---------------------------------- | ------------------------------------------------------------------ |
| `keycode_data.js`   | `npm run codegen:keycode-data:js` | ✅ Wired — `<script>`-included in `index.html` before `state.js` (DC-1) |

`keycode_data.js` is generated from `_shared/data/keycodes/azerty.json` — the
same canonical keycode→finger/hand/home map the macOS keylogger aggregator
(`macos/modules/keylogger/aggregator/core.lua`) derives its own `KC_TO_FINGER`
table from. Both consumers read the shared JSON instead of hand-copying it, so
a future layout correction only needs editing `azerty.json`.
