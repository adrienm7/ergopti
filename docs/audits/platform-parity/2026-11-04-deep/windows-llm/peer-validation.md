# WL-001 self-countercheck after macOS acceptance investigation

This is a **self-countercheck by the original finding author**, not independent
peer validation. Audited source remains
`89b0b774c8c960c7ad458ac3cb98d5c97598e518`.
Original report/findings/reproducer retained unchanged as requested. This note
supersedes their certainty classification for integration purposes.

## Disposition: bounded policy candidate; not independently confirmed defect

The source mechanism is real: a user-accepted agent handler is placed on an
untracked one-shot timer and has no pause/AI-enabled/current-flow check when it
starts. No downstream guard or cancellation owner was found. However the original
finding treated that fact as sufficient proof that the user's accepted action
must be cancelled. That inference is too strong. Existing code explicitly retires
the _offer as accepted_ before handing the connector off, and the repository also
preserves already accepted operations across some later retirement boundaries.
There is no focused product contract/test settling whether a queued accepted
agent action is cancellable by a subsequent pause or AI-off.

Recommendation: do **not** integrate WL-001 as a newly confirmed missing feature
or proven stale-flow bug without a narrower acceptance policy or a native
boundary reproduction that establishes the intended invalidation. Retain the
behavior as an unresolved policy asymmetry/test gap. It is not refuted as
impossible; its user-visible incorrectness is unproven.

## Mechanism re-read

Paths relative to `static/ergopti_plus/`:

1. `windows/modules/llm/agent_action.ahk:598` binds `Flow` and `Action` in each
   slot's `OnAccept`. The visible offer has a render guard at `:605`, ultimately
   requiring current flow generation and `!A_IsSuspended` at `:701`.
2. `windows/modules/keymap/llm_bridge.ahk:672` claims the presented offer through
   the canonical acceptance policy before reaching `LLM_Bridge_OnAccept:2004`.
   This is an explicit user acceptance, not a callback from an unaccepted model
   proposal.
3. `llm_bridge.ahk:2012` stops ordinary prediction generation. At `:2024` it calls
   `_LLM_Bridge_OnInjectComplete(Transaction, true)` for a self-applying agent
   slot, then `:2025` schedules `SetTimer(Handler, -1)`. The source comment
   explicitly says the offer is retired like a typed one and the handler runs on
   a fresh thread, off the Tab key's thread. Thus the timer represents work after
   an already committed acceptance lifecycle.
4. `_LLM_Agent_Accept:622` optionally learns acceptance, logs dispatch, and calls
   the connector. It checks neither current flow generation nor AI/pause.
5. `LLM_AgentConnector_Execute` in `windows/modules/llm/agent_connectors.ahk:92`
   cleans earlier temp files then directly dispatches calendar/reminder/mail/tool.
   The native Outlook/import/mailto/tool paths have no agent-flow/pause guard.
   No hidden guard repairs the timer boundary.
6. Real pause routing at `windows/infra/lifecycle.ahk:609` calls
   `LLM_Agent_OnSuspend:1093`; AI-off at
   `windows/ui/menu/menu_llm/actions.ahk:144` calls `LLM_Agent_OnAiSwitchedOff`.
   Both use `_LLM_Agent_Withdraw:1114`, which increments flow generation, cancels
   the automatic typing-pause timer and clears its offer/feed. It does not retain
   or cancel the fresh acceptance timer. Native Suspend itself does not stop it.

This establishes a possible schedule: a valid user acceptance queues handler;
pause/AI-off executes before that timer; the timer later runs the accepted
connector. It does not establish that this schedule is forbidden after explicit
acceptance. No native AHK timer ordering was executed in this environment.

## Why the original normative inference needs qualification

Evidence favoring cancellation:

- `docs/memory/windows-ahk.md:443` says every timer callback doing input/UI/network
  work must honor `A_IsSuspended`.
- `agent_action.ahk:1085` calls pause “tout éteint”; `:1100` says nothing of the AI
  runs when switched off. No explicit accepted-agent exception is documented.
- Ordinary accepted text does have a real final output admission that rejects
  pause, HWND/control change and physical/content/context generations
  (`llm_bridge.ahk:192`, then the TextSender path after `:2035`).

Evidence against assuming every retirement cancels explicit acceptance:

- The agent acceptance lifecycle is completed **before** timer creation. The
  accepted Action and Flow config are deliberately retained by the bound handler.
  Generation retirement previously prevented old selection/triage/answer results
  from painting; a generation mismatch alone does not prove an already accepted
  external action is stale.
- `agent_action.ahk:1085` explains its pause step specifically as retiring an
  in-flight _answer_, armed typing-pause timer and typing feed. It does not
  explicitly describe cancellation of accepted connector work.
- macOS ordinary text acceptance explicitly preserves the user's accepted text
  after native cleanup refusal (`macos/modules/keymap/llm_bridge.lua:1754`), with
  regression coverage. That is not a blanket permission to output while paused,
  but refutes the simplistic rule “generation cleanup/refusal implies accepted
  work must be dropped”.
- Accepted updater transactions explicitly continue after later pause/page
  retirement (`macos/ui/changelog/init.lua:573` and managed-admission tests).
  They are a different subsystem, so their policy cannot simply be transferred
  to agent connectors; they do show the broad timer/pause wording has intentional
  acceptance-qualified exceptions in this codebase.
- macOS `agent_runner.lua:531` starts its connector from accepted action without
  a flow-generation predicate. Linux also executes accepted connector directly.
  Windows adds a detached turn, while its product contract may intentionally
  preserve the same accepted external action. Synchronous counterparts are not
  proof of intended Windows cancellation.

Accordingly neither interpretation is proved by source alone. A guard requiring
`_LLM_Agent_IsCurrent(Flow)` could discard an explicitly accepted action merely
because another flow began before the timer got CPU. That would be a behavior
change requiring an explicit policy, not an automatic audit fix.

## Reproducer limits and next useful validation

The existing `repro-retired-agent-accept.ahk` extracts the production handler and
invokes it while paused with an old flow. It was never executed natively. Even
if it prints one connector call as source predicts, it would establish dispatch,
not the intended acceptance contract; it also bypasses the genuine bridge queue.

A useful focused regression should begin from a genuine accepted offer and retain
its real queued callback through a controlled scheduler seam. Observe the exact
acceptance commit, pause/AI-off boundary, connector start and any completion UI.
Then pin the chosen policy separately for:

- acceptance still only a proposal / claim not committed;
- accepted action queued but connector not yet launched;
- connector already launched and potentially irreversible;
- late completion/learning/notice after pause or after another offer.

If committed accepted actions must survive, document that exception and give the
queued work its own explicit owner; flow generation must not accidentally cancel
it. If pause must veto not-yet-launched accepted actions, use a final pause/AI
admission at dispatch and settle the earlier lifecycle consistently. Completion
notices may need a separate pause policy even when the external action survives.

No new runtime/native tests, repository changes, or changes to prior reports were
made for this countercheck. The original “confirmed actionable” label should be
read with the bounded disposition above.
