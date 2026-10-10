<!-- docs/handovers/2026-10-10-group5-safe-off-backport/README.md -->

# Group 5 current-Dev Safe OFF receiving

The two runtime/test changes receive the already published local cleanup fix
from `6f8c6df041b5086ec041ccb7c16781e23cffe3cc` on genuine current Dev
`c4180d8d8d368e7e41a71c542b1edabdc0b36ee0`. The complete production preimage is
SHA256 `60e80a11114e2ab859cc5f89a3bff875dc774a3989528bd1d5ff064e6852856c`;
the complete original test preimage is
`5b22ec11668181c2ceeb05c3e2ad9ea5010b498e6ad5385a6c9b664b0bd3dd9e`.
The genuine current transaction fixture, controller, watchers, configuration,
and helpers remain in place. No broader feature history is required.

OFF completion keeps the original exact fence, guardian removal, preference
persistence, local cleanup, and owned-rule removal order. After successful
owned-rule removal, retained local cleanup debt refuses overall success with
`local-input-cleanup-pending`. The preference remains OFF. Use Remove Ergopti
from Karabiner to retry cleanup; toggling an already OFF preference requests ON.
An original rule-removal refusal keeps its error precedence. An exhausted native
fallback fence still refuses admission before guardian removal, OFF persistence,
or owned-rule removal; this fix does not bypass it.

Fresh actual focused receiving ran the unchanged original fifteen cases plus
four previously frozen controls: BEFORE 18 PASS / 1 FAIL, AFTER 19 PASS / 0 FAIL,
and whole production omission 18 PASS / 1 FAIL. Every original case passed in
all three phases. The meaningful red is the public OFF callback returning true
while the retained watcher cleanup refused, at test line 440; its expected false
assertion is unchanged. The AFTER case reaches the same-handle retry and second
successful completion. The later retry is unentered in the failing variants.

The receiving history also preserves the qualified logger fixture prerequisite
`40bdca8a1ecc7c5351af0872a95907a5463af314`. That fixture changes only test path
selection and its documentation. It is necessary for faithful full-suite
validation and has no semantic dependency on the Safe OFF runtime change.
Selected default gates run on the complete final receiving source before
publication; their terminal counts are recorded separately without rewriting
these frozen inputs afterward.

Healthy task, timer, guardian, and watcher ports in these controls are modeled.
The exhausted-fence negative uses genuine controller functions over modeled
native ports. No native OFF, physical input retirement, complete worker reaping,
installation, or original READY/PONG/exit73 cause is qualified. TODO item 24
remains partial, and all other owner blocks are preserved.
