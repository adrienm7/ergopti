# AI request-to-output flows: Windows, macOS, Linux and shared

Audited source: `ef3c7f71` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The register's next module after metrics. Windows
(`windows/modules/llm/`) is the read-only reference; the Linux prediction
engine and remote API (`linux/modules/llm/`), the macOS remote API, Ollama
client and streaming handler (`macos/modules/llm/`) and the shared modules
(`_shared/lua/llm/`, the failure classification and token exchange) were
compared from the trigger to the typed output: request building, retry and
refill, streaming, cancellation and successors, model changes, acceptance and
error classification. Linux candidates were replayed through the real engine
and `api_remote` over a scripted HTTP client; no live provider, AHK or
Hammerspoon ran. Managed-runtime provisioning and live-provider
interoperability are out of scope.

## Fixed (Linux)

| Id      | Sequence                                                                           | Windows                                                                          | Linux before                                                                                     | Regression                   |
| ------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------- |
| AIL-001 | Backboard, invalid key, three predictions; the assistant creation answers 401      | `_LLMRemote_OnBackboardAssistantFail` passes the status: stops after one request | "the Backboard assistant could not be created: HTTP 401" is no refused key: six creations posted | `backboard-creation-refusal` |
| AIS-001 | watsonx or Vertex, the token exchange answers 401 or 403                           | `_LLMRemote_AccessFailInfo` carries the status: never retried                    | The bare reason is no refused key: the whole retry budget spent (one exchange, the 60 s pause)   | `access-refusal-status`      |
| AIL-002 | Ollama streaming, one prediction; the stream dies mid-answer, Tab during the retry | A retry never streams (`DispatchVariant`)                                        | The failed call's partial stayed on offer: Tab typed truncated text; the retry streamed again    | `stream-retry-partial`       |

The refusal producers now keep the HTTP status first, the form
`llm.failure_class` and the shared corpus already read, rather than teaching
the classifier a new form (Windows mirrors it and replays the same vectors).
The token exchange's own reason, which the shared corpus pins, is unchanged:
only the request it fails carries the status.

## Decisions pending (behaviour left unchanged)

- **AID-1, macOS's inner quick retry.** It runs outside `max_attempts`: one
  prediction at multiplier 2 sends four requests on macOS when every attempt
  fails, two on Windows and Linux (left « intent unresolved » by the deep
  macOS review, untracked until now).
- **AID-2, a token exchange answering 400 (`invalid_grant`).** Windows marks it
  `key_refused` but its classifier ignores the flag: retried on all three.
- **AID-3, a settings change while a request is in flight.** Windows retires
  the request by its semantic signature (temperature, count, word bounds,
  profile, auto-type); Linux and macOS only on a model or backend change. The
  activity rule usually cancels first; not replayed.

## Refuted

Duplicate refill and the extra-token retry, the compounding retry budget, a
plain HTTP 401/403 or « API key is missing or invalid » being retried, a model
change mid-request on Linux, an explicit shortcut while a request is in flight,
batch-mode retries, focus or privacy changes during retries.

## Remaining work

- **macOS:** AIS-001 does not reproduce there: `post_and_parse` fails any
  unresolved entry, a refused exchange included, with `reason =
"no_credential"`, which `llm.failure_class` reads as a refused credential (a
  transient 5xx exchange is not retried either, stricter than Windows).
  AIM-001 stands in source: the quick retry runs inside each backend
  (`api_ollama`, `api_mlx_fetch`, `api_remote`), so `streaming_handler` never
  learns the streamed attempt failed and keeps its `_is_stream_placeholder`
  rows on offer until a success or the final failure; a fix needs a withdraw
  signal through `on_partial` from the three backends and a handler path that
  drops the placeholders.
- **Linux:** deterministic refusals before sending (no model, empty base URL,
  no account address) are retried synchronously; not compared with Windows.
- **Native receiving:** no live provider, AHK or Hammerspoon run.
