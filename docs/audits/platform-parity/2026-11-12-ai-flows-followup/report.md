# AI predictions and assistants: drift since the AI-flows campaign, selection actions

Audited source: `67ac8860` (`claude/ergopti-todo-parity-audit`), against the
[AI-flows campaign](../2026-11-11-ai-flows/report.md) at `ef3c7f71`. Date:
November 12, 2026.

## Scope

- **Drift since `ef3c7f71`, apart from the campaign's own fixes:**
  - the Linux API entries, the new background API key migration, the token
    store and the remote API;
  - the macOS remote and Ollama backends, the token crypto and the streaming
    handler refactor;
  - the shared `llm/` modules.
- **Selection actions:** the tone steps and the selection translation.
- **The campaign's leftover Linux row:** deterministic refusals before
  sending are retried synchronously.

The campaign's fixes, AID-1 to 3, its refuted list and the network report's
findings are not repeated.

Checked and kept:

- **Leftover Linux row:** Windows retries the same refusals through
  `_LLMRemote_FailReserved` and `_LLM_Engine_ArmRetry`, so this is parity.
- **Key migration, safe paths:**
  - the key reaches secret-tool through the child's environment, never as
    an argument or in a log;
  - the plaintext copy stays until the file names its reference;
  - an uncertain publication keeps its keys.
- **macOS Keychain:** an absent item is told apart from a locked one.
- **Stream watchdog removal:** it leaves no dangling reference.
- **Selection actions:** on all three OSes they share:
  - the same prompts (the shared `translate.lua` and `tone.lua`);
  - the same reselection and failure notices;
  - the same refusal of a secure field before the selection is read;
  - the same supersession by generation.

## Fixed

| Id      | OS                                             | Sequence                                                                                           | Windows                                                                            | Before                                                                          | Regression                           |
| ------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------ |
| AIX-001 | Linux (tone, translation), macOS (translation) | In an app listed in « disabled for AI generation », select text and shift the tone or translate it | Refused before the selection is read (`_LLM_Engine_ShouldSuppressForDisabledApps`) | The selected text was sent to the provider and the answer offered or typed back | `aix-001-excluded-app-selection`     |
| AIX-002 | Linux                                          | Save an API entry while the background key migration runs                                          | — (no background migration)                                                        | « 2 API key(s) stay in plaintext for now », backoff doubled, state waiting      | `aix-002-migration-overtaken`        |
| AIX-003 | Linux                                          | The daemon stops while the migration stores its second key                                         | —                                                                                  | The keys it had already stored stayed in the secret service, named by no file   | `aix-003-migration-shutdown-orphans` |

On Linux the new check is `M._focused_app_excluded`, a field rather than a
local, because `prediction_engine.lua` is at Lua's 200-locals limit. It reads
the focused app as `_is_secure_context` does. On macOS,
`selection_action_excluded` gives the translation the same check the tone
rewrite already made.

## Open

None in this module. Native receiving is unqualified: no live provider,
secret service or Hammerspoon run.
