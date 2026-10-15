# macOS Nav source close acknowledgement

The original user and shipped loading callbacks read source bytes but ignored
stream-close acknowledgement. They now delegate to the unchanged shared
`toml_codec.writer.read_classified`, also used by the delivered Linux correction.
Windows already uses its strict reader. This changes only the two original
Mac loading helpers and removes their unused errno constant.

A genuinely absent user file remains absent; failed reads or false/nil close
ACKs cannot supply bindings. A refused user file keeps the existing isolated
empty bindings/wheel and START/WARN/ERROR log sequence. Refused or absent shipped
context remains fatal before START. Keyboard form, defaults, recommendation,
wheel, generation and lease owners are preserved. The reader stays lazy so
build-only imports do not load the writer.

## Focused causal receiving

The original complete test file is an exact byte prefix. Four handwritten cases
use a real valid user file or the genuine shipped registry. Each intercepted
stream is actually opened, read and physically closed exactly once before
returning the controlled false/nil close ACK. No classified result, schema or
loader is substituted. IO, module cache, logger and globals are restored before
assertions; the added cases report owned cleanup failures.

The genuine existing Lua 5.4 runner receives the exact existing module with
private retained-source preloads, sequentially, without changing canonical
source coordinates or asking discovery to find absent new case names:

| Cohort                         | Original cases | Four added cases | Actual exit |
| ------------------------------ | -------------- | ---------------- | ----------- |
| Original module                | 18 PASS        | absent           | 0           |
| Original producer, added tests | 18 PASS        | 4 FAIL           | 1           |
| Candidate                      | 18 PASS        | 4 PASS           | 0           |
| Original producer restored     | 18 PASS        | 4 FAIL           | 1           |
| Candidate restored             | 18 PASS        | 4 PASS           | 0           |

All source/logical-index/HEAD/status frames remain exact, and the private packet
is unchanged. The two original import tests still print their existing rmdir
warnings for empty persistent writer-lock files; those warnings are retained
separately and are not attributed to the new four cases. This is portable Lua
software evidence with existing Hammerspoon doubles, not native macOS receiving
or a physical close failure.

Production preimage SHA256 `af2d2cf86c4ed87b3778158940514c69fcff3385f48f232ff3bb78f7b2d7b4a7`
becomes `77952bfd4c1c82f6a72d73a734d85ef6e32d3a9d373ae0e06b0887e7b2338300`.
The complete original test preimage `a1695a14589b0a30d27e7430e55be94fc6d9e520de003fa770d060500af27611`
becomes `bde3dde93a009e364aded029f0bd14b9eb918654fd83658c7fcb7fe51676382b`.
G5's freshly fetched published tip `9760c84568947a89792a10054ca3e95160e55135`
has the same original pair. Narrow source ownership was coordinated in
[issue 86](https://github.com/adrienm7/ergopti/issues/86#issuecomment-6188394974).

## Joined local receiving

The selected sequential run completes with formatting PASS, 19,863/0 portable
Mac unit cases across 1,604 modules and 101/0 simulated E2E checks, with one
explicit driver-specific vector skipped. The original cleanup warnings above
remain visible. The full Common run is **failed**, with 433 PASS and two bounded
subprocess timeouts: Sparkle transport controls at 30 seconds and the independent
clock receiver called by Ollama at 60 seconds.

Both exact unchanged checks subsequently pass directly, with their original
budgets and assertions: Sparkle exits zero in 7.2 seconds, and the complete
Ollama control exits zero in 118.6 seconds. Every source/HEAD/logical-index/status
frame remains exact. Those successful focused replays do not explain the first
timeouts or turn the failed full invocation into a successful one. Its raw
failures remain retained. The latest maintainer instruction permits focused
receiving for atomic fixes and batches the next broad qualification at an
integration checkpoint; no assertion, timeout or native acceptance is waived.

## Remaining scope

Original-load provenance and Navigation collision reservations are separate
work. This read-contract repair grants no source lease, native installation,
input/output authority or physical availability. Current default Mac source
profile/operational enrollment and native unit/E2E/package/install receiving
stay with their existing owners; no stopped experiment is replayed. New dev
publication remains queued during Root's release integration window. No Group 3
TODO item or transverse 16/38 requirement is removed.
