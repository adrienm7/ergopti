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

- **AID-1, macOS's inner quick retry.** It ran outside `max_attempts`: one
  prediction at multiplier 2 sent four requests on macOS when every attempt
  failed, two on Windows and Linux. Decided by the maintainer on 2026-11-11:
  the quick retry spends an attempt; macOS now sends two
  (`test_sequential_retry_request_fence.lua`).
- **AID-2, a token exchange answering 400 (`invalid_grant`).** Windows marked
  it `key_refused` but its classifier ignored the flag: retried on all three.
  Decided by the maintainer on 2026-11-11: never retried, failing at once with
  the service's message. Shared: `failure_class` reads the exchange's 400
  refusal as a refused key and `api_token_exchange.read` carries the service's
  message (both corpora updated). Linux fails the chat with
  « HTTP 400: the token exchange answered HTTP 400: <message> »; macOS already
  failed an unresolved entry as `no_credential` (never retried) and now logs
  the message. **Windows counterpart (maintainer):** `LLM_TokenExchange_Read`
  appends the same message, `api_common.ahk` takes the phrase « the token
  exchange answered http 400 »; `test_llm_shared_vectors.ahk` and
  `test_llm_api_token_exchange.ahk` replay the new vectors.
- **AID-3, a settings change while a request is in flight.** Windows retires
  the request by its semantic signature (temperature, count, word bounds,
  profile, auto-type); Linux and macOS did only on a model or backend change.
  Decided by the maintainer on 2026-11-11: a change of the model, key,
  provider or endpoint retires it on macOS and Linux too, and the next request
  uses the new settings (shared `llm.request_settings`; regressions
  `settings-retire-inflight` in `test_prediction_backend.lua` and
  `test_prediction_settings_change_retires.lua`). Windows already retires.

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
  AIM-001 fixed (taken on the coordinator's decision of 2026-11-11, to review
  by the maintainer): the quick retry ran inside the backend, so
  `streaming_handler` never learned the streamed attempt failed and kept its
  `_is_stream_placeholder` rows on offer, and Tab typed the abandoned
  completion. `api_ollama` and `api_mlx_fetch` now withdraw the failed stream
  through `on_partial(false, identity)` and the handler drops its rows, back to
  the loading surface when nothing else is on offer; `api_remote` never
  streams. Regression `stream-retry-withdraw`: a replay through the real
  engine, handler and backend sequential fetch.
- **Linux:** deterministic refusals before sending (no model, empty base URL,
  no account address) are retried synchronously; not compared with Windows.
- **Native receiving:** no live provider, AHK or Hammerspoon run.
