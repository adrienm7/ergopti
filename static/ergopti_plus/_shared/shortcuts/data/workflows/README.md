# workflows (shared data)

## Purpose

The model of a user workflow: a named sequence of steps the user builds in the
« Workflows personnalisés… » window and assigns like any action (shortcut
slot, gesture, tap-hold key, hotstring). `steps.json` declares the file
layout, every step kind with its closed field set, the « if » conditions, the
screen targets and the bounds. It is the one source of:

| Reader                                               | Role                                             |
| ---------------------------------------------------- | ------------------------------------------------ |
| `_shared/ui/workflow_model.js`                       | canonical check of the editor and of an import   |
| `_shared/shortcuts/engine/workflows/model.lua`       | the same check, placeholders, shell digest (Lua) |
| `_shared/shortcuts/engine/workflows/interpreter.lua` | the run as a state machine of effects            |
| `_shared/shortcuts/engine/workflows/runner.lua`      | deadlines, single run, abort (macOS and Linux)   |
| `windows/modules/shortcuts/workflows/`               | the AutoHotkey port of the four above (Windows)  |

The vectors are `_shared/tests/corpus/workflows/`: `validation_vectors.json`
(the first refusal of a file, its closed reason and JSON Pointer) and
`interpreter_vectors.json` (the effects of a run and its outcome).
`tools/test/test-workflow-model-vectors.cjs` replays the first in JavaScript
and checks that both Lua suites and the AutoHotkey suite replay both.

## The file

`workflows.json` in the Ergopti config folder (`Ergopti` on macOS and
Windows, `ergopti` on Linux):

```json
{
	"schema_version": 1,
	"workflows": [
		{
			"id": "wf_3f9a",
			"name": "Fill the form",
			"origin": "local",
			"images": { "send": "iVBORw0KGgo…" },
			"steps": [
				{ "kind": "focus_app", "app": "Firefox" },
				{ "kind": "wait_for", "target": { "type": "image", "image": "send" }, "timeout_ms": 5000 },
				{ "kind": "clipboard_get", "into": "copied" },
				{ "kind": "type_text", "text": "Ref: {{copied}}" },
				{
					"kind": "if",
					"condition": { "type": "visible", "target": { "type": "text", "text": "Error" } },
					"then": [{ "kind": "notify", "text": "The form refused {{copied}}" }],
					"else": [{ "kind": "click_target", "target": { "type": "image", "image": "send" } }]
				},
				{ "kind": "repeat", "count": 3, "steps": [{ "kind": "send_keys", "combo": "ctrl+tab" }] }
			]
		}
	]
}
```

- Every object has a closed key set: an unknown key refuses the file, so a
  file from a newer editor never runs half-read.
- `send_keys.combo` follows the send_shortcut grammar of
  `actions/send_keys.json`.
- `{{name}}` in a text field marked `placeholders` is replaced by a variable
  set earlier (`into` of a step, `set_variable`); an unknown name stops the
  run with `unknown_variable`. A `{{` that opens no identifier stays text.
- Images are base64 PNG, embedded so an export carries them.
- Text conditions compare literally (equals, contains, starts with, empty):
  never a regular expression, whose dialects differ between the drivers.

## Running

A run asks the driver for one effect at a time, each with `deadline_ms` from
`[workflows]` of `_shared/core/timing/data/constants.toml`; a step past its
deadline, an adapter failure or an unknown variable stops the workflow with
a closed `run_reasons` value and the dotted path of the step (`3.then.2`),
which the driver's notice names. A workflow never runs twice at a time;
Escape and the emergency stop abort every run at once.

Steps marked `service` run on the per-OS screen vision service
([design](../../../../../../docs/design/screen-vision.md)) through
`_shared/shortcuts/engine/workflows/screen.lua`: a target is looked for in the
front window, an image target is the workflow's embedded PNG, a text target is
the shared fuzzy match of the OCR words, and `wait_for` polls every
`wait_for_poll_ms`. A `capture` stores the path of its PNG file (in the
driver's cache) in its variable, an `ocr` the text it read; the `region` mode
lets the user draw the area. A refusal of the service maps through
`screen_reasons` to one of four run reasons, so its notice says what to fix. A
driver without the service stops such a step with `screen_service_missing`.

### Security notes

- A shell step runs `/bin/sh -l -c` (macOS, Linux) or `cmd.exe /d /s /c`
  (Windows) with the user's rights, exactly like a `run_command` binding.
- Its command never takes placeholders: OCR or clipboard text would otherwise
  become shell syntax. The variables reach it as environment variables.
- A shell step of a workflow made or edited in the editor runs with no prompt
  (maintainer decision of 2026-11-25). An imported workflow stops at its
  first shell step until the editor approves it: the approval covers the
  SHA-256 of the workflow id and its shell commands in order
  (`model.shell_digest`), and editing a shell step there approves it too.
  Approvals live in their own file of the config folder, never in
  `workflows.json`, so an export carries none.
- The editor marks an imported workflow `origin = "import"`; its shell steps
  are refused at run time until the user approves them in the editor.
