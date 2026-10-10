<!-- docs/handovers/2026-10-10-group5-auth-backport/README.md -->

# Group5 authentication-filter backport

This isolated source slice starts from Root
`51a66d9c68d2e65e4d4576a7800374c543326c7f`. It changes the existing public
system-authentication filter setter and its existing accounting test only.
The original three-argument context tracker, policy classification, duration
constants, producer bindings and all 32 original test bodies remain intact.

The setter preserves included intervals when filtering is disabled. A newly
excluded interval settles the exact modifier owner, and a refused settlement
keeps accounting admission closed until a successful public retry. Nine frozen
controls exercise genuine public setters and production accounting with modeled
native application and task ports. Actual results are BEFORE 35 passed / 6
assertion failures, AFTER 41 / 0, settlement omission 35 / 6, and admission-gate
omission 39 / 2. The gate omission fails the admission assertion before the
later synthetic-input check; AFTER executes the complete no-enqueue and retry
witnesses. All 32 original cases pass in each qualified phase.

The isolated receiver initially lacked two required shared resources. Its
zero-business-assertion and fixture-setup failures remain separate evidence.
Qualification uses exact Root Git source and resource bytes, with no feature
helper substitution or regenerated expected outcomes. Selected verification ran serially: formatting passes 364 files, E2E passes
101 cases with one original host-specific skip, and the full Lua suite reports
18,197 passes / 9 failures across 1562 modules. JavaScript reports 404 passes /
3 failures out of 407 checks. Overall exit remains 1. Exact completely clean
Root baseline replays reproduce the menu parser assertion, historical PAC
source refusal, and all nine boot-fixture admission failures. The added test
inline recovery pcall triggered the third JS false-green ratchet; a separately
reviewed test-only measurement correction passes all 41 focused cases and the
ratchet. Full suites were not repeated after that correction. The source
image remains identical. These are local isolated validation outcomes, not
proof of underlying source defects. A hosted byte-identical predecessor has
a different reported JS result; context or environment differences remain
unknown and require reconciliation. The subreaper reaps 121 descendants with
no pending child or rescue. No native Swift, Hammerspoon, authentication UI or physical test
ran here. Other secure/private/configuration writers, full configuration
transaction atomicity and the user lease exit73 cause remain open.
