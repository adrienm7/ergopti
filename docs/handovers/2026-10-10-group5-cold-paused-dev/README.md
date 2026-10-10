<!-- docs/handovers/2026-10-10-group5-cold-paused-dev/README.md -->

# Standalone retained-PAUSED startup probe

This correction receives genuine Dev
`9e370a3926f23ff09e0a272fae8fa841afdb4d0b` with explicit fixture prerequisite
`40bdca8a1ecc7c5351af0872a95907a5463af314` on
`feat/macos-input-logger-fixture`. The four production/test preimages are whole
identical to the independently reviewed Devb424 packet. It imports no full
feature initializer, controller, or helper implementation. The fixture
prerequisite corrects only daily-reset observation ownership; the production
logger is unchanged.

A genuine startup admitted while unpaused can retain a later PAUSE intent and
complete already in mode2. That matching PAUSE settles without a wire command;
it does not renew the native lease as an actual RESUME would. The native inner
READY deadline is 6.75 seconds, while the Lua five-second timer begins upon
READY delivery. Delivery delay D and tick latency L leave a conditional gap
when D + L exceeds 1.75 seconds. Those delays are unmeasured; this is a bounded
source rationale, not attribution of the original incident.

The retained-PAUSED initializer now requires one accepted serialized liveness
request before the original commit hook saves the enable preference. Exact
captured ownership is checked before and after that request, immediately after
the hook before global cleanup, and after cleanup. A refused request leaves the
preference OFF without transient ON. Reentrant owner loss preserves existing
compensation, authorization and exact joined-stop behavior. The request starts
the existing 3.75-second acknowledgement clock before synchronous save or
recovery authorization; a slow hook can therefore fail closed earlier. No
budget, fence, controller-wide startup PING, or ordinary ACTIVE/RESUME behavior
changes. Accepted request does not mean native PONG confirmation.

Actual fresh receiving on this dependency passes all 14 legacy and 26 composed
cases. Before production and with the whole production change omitted, the
composed suite passes 20 and fails six genuine assertions. The legacy BEFORE
passes 11 and fails three: two assertion failures and one unchanged nil
observation-list error, which is not credited as a causal assertion. Removing
the post-hook ownership guard passes 13 and fails its actual classifier count
assertion. All ten original legacy and nineteen original composed cases pass
in every variant, including the unchanged zero-save refusal assertion.
Filesystem, task, timer and controller-input ports are modeled. Historical
setup-only and required-gate failures remain in private receipts; no expected
result or assertion was weakened to pass.

The default change-scoped gates must pass before this standalone publication;
the actual terminal counts and exact source pins are retained in its receipt
and commit body. Hosted/native execution, physical input acceptance and the
initial PONG/READY/exit-73 cause remain unqualified by these software tests.
No TODO item was removed.
