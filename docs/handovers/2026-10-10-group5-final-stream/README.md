<!-- docs/handovers/2026-10-10-group5-final-stream/README.md -->

# Group 5 final task stream correction

This standalone change starts directly from Root
`51a66d9c68d2e65e4d4576a7800374c543326c7f`. It does not depend on the separate
authentication-filter backport or import the feature branch controller.

The persistent lease worker explicitly requests the final-stream task role.
Successful acquisition retains legal final delivery after task completion.
Malformed roles, refused or foreign acquisition and explicit disposal retain
refusal. Ordinary task delivery, owned retirement, existing protocol deadlines
and generation fences remain unchanged.

Independent receiving uses the genuine Root ShellRunner, LeaseController,
TaskEnvironment and Storage with retained constructor-installed task callbacks.
Task methods, timers and identities are modeled. BEFORE reports 42 passing and
seven failing adapter cases plus five passing and three failing composed cases.
AFTER passes all 49 adapter and eight composed cases; every original adapter
case passes in each phase. Removing the disposal fence causes its four frozen
failures. Removing the caller role causes three composed failures rather than
the original prediction of two, because ordinary truthy foreign-start admission
also returns. The frozen prediction and overall receiving status 1 remain
recorded; expectations were not regenerated.

This correction covers the macOS Hammerspoon task callback contract. Windows
and Linux use different native task APIs and receive no source changes.

Selected final-source verification completed with overall status 1: formatting
passed for 364 files, JavaScript passed 406 checks and retained one historical
PAC source-projection failure, Lua E2E passed 101 scenarios with one existing
skip, and Lua units passed 18,216 cases with the same nine boot-fixture failures.
All seven source inputs stayed unchanged; the native subreaper retired every
adopted child with no pending or rescued process. This is partial source
qualification, not a green complete release gate.

The first local full run retained
JS 404 passing and three failing checks and Lua 18,215 passing and ten failing
cases. Two new header omissions and the changed original private-start guard
were owned regressions; exact repairs preserve executable bodies and the
original guard. All 49 adapter, eight composed and three unchanged raw-start
cases now pass. The unchanged omission failures remain recorded.

The private validation installation was stale despite its current lock file:
`smol-toml` 1.8.0 was installed while the lock pins 1.9.1. Frozen `npm ci` now
installs the exact private lock cohort; canonical dependencies were refreshed
separately without source or index changes. Earlier parser failures used the
stale installation and do not qualify the locked Root source. The historical
PAC projection and nine boot-fixture failures remain separate retained limits.
The boot fixture lacks the existing privacy-policy read port; the PAC projection
needs its owner's current source instrumentation enrolled. Neither was changed
by this standalone topic. Latest Root integration must receive the exact patch
against its actual current preimages; this topic intentionally keeps Root51 as
its sole parent.
The authentication test-style ratchet correction belongs to its separate topic.

Native task execution, physical keyboard input and complete release receiving
remain unqualified. This correction does not establish the cause or resolution
of the original PONG/READY/exit-73 incident. Native 165-case lease receiving and
its shared CI ownership are separate work.
