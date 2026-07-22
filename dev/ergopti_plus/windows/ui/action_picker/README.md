# action_picker (AHK)

## Purpose

Provides all gesture-slot and keyboard-shortcut action pickers. `init.ahk` (the main entry) hosts a WebView2-based searchable, hierarchical picker (with TOC and fold support) that loads the shared `_shared/ui/action_picker/` frontend. A legacy native ListBox fallback is kept for systems without WebView2. A separate `webview` sub-component handles the WebView2 lifetime and bridge messages (`ready` / `confirm` / `cancel`).

## Key files

| File               | Description                                                               |
| ------------------ | ------------------------------------------------------------------------- |
| `init.ahk`         | Public API: `ShowActionPicker(opts, on_confirm)` — singleton host         |
| `action_picker_webview.ahk` | WebView2 bridge: creates window, injects `initData`, routes bridge messages |

## Usage

```ahk
ShowActionPicker({title: "Choisir une action", items: actionList, current: curId}, (id) => {
    ; handle confirmed selection
})
```

The caller is responsible for building the `items` array (headings and action entries); the picker is action-catalogue-agnostic.
