# model_browser (AHK)

## Purpose

Sortable ListView window showing the curated LLM model catalogue with rich per-model specifications (parameter count, RAM requirement, speed tier, engine compatibility, tags). Catalogue-first design: all models in `_shared/modules/llm/models.json` are shown whether installed or not, letting users compare before downloading. Double-clicking a model triggers the same activation path as the LLM menu picker.

## Key files

| File      | Description                                                                 |
| --------- | --------------------------------------------------------------------------- |
| `init.ahk`| `ModelBrowser_Show()` — singleton; reads `models.json`, populates ListView  |

## Shared data

`_shared/modules/llm/models.json` — the model catalogue; updating the JSON file is the only step needed to add a new model to the browser.
