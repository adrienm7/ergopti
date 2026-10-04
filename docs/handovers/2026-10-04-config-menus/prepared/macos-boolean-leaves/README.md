# Obsolete macOS remap Boolean leaves — frozen, unapplied

This is a bounded TODO33 source candidate, not an integrated or natively
qualified feature. Root owns application, final composition, gates and delivery.
No shared checkout, index, branch, workflow or network mutation was performed.

- Base: 375de99fbfdaf0ecf4d4ba06e71be7940fe0470c.
- Patch: macos-obsolete-boolean-leaves.patch.
- SHA256: 8daad075bd4bd0ce806fddfc66fdf29c9c18938f87604cb06913844d2ad3f1f0.
- Exactly three paths: native remap config.lua, one newly discovered registered
  test module, and an insertion solely within TODO33.
- patch-manifest.json pins every old/new file; preimages/ and candidate/ contain
  exact source bytes. freeze.py verifies LF, old hashes, isolated patch application,
  unchanged original test modules and protected source owners.
- Config source postimage:
  4e2fdf0c59e075e5eac4cb0b74ca25563a2987db331b49e3f2f2428ddca99c3d.
- Config preimage:
  5545894500281de9c357b6f2bf2c82c7d58a5130e6b49471e98298a2a297c713.

## Problem and policy

The predecessor reads a wrong-type tap_holds.enabled or mod_combos.symmetric as
false without warning. An unrelated full-state save then deletes that obsolete
value; a changed true candidate silently replaces it. This violates the selected
policy: ignored obsolete data stays until explicit cleanup, and an implicit
non-neutral candidate is not evidence of repair intent.

The native owner extends its existing Boolean classification and preservation
policy. Absence, false and true retain their old sparse/default semantics.
Wrong-type string, integer, array and inline-table leaves get the canonical
neutral read and one shared warning per file/path/reason. An unrelated save
retains their complete models. A changed non-neutral switch refuses with the
exact file/path before calling the native writer. Manual source repair permits
the same candidate to retry. Existing explicit whole-file reset authority,
integration consent, malformed/unreadable refusal, known scalar bindings, timing
behavior, conditional publication and shared defaults remain unchanged.

The complete input and expected post-save TOML models are independently
handwritten in the new test module. Expectations were not generated from the
implementation. This preserves models, not arbitrary comments/lexical bytes;
refusal and source-fence cases assert exact source bytes.

## Evidence

| Owner selection                         | Passed | Failed |
| --------------------------------------- | -----: | -----: |
| Exact predecessor, same new module      |      6 |     22 |
| Candidate, new module                   |     28 |      0 |
| Seven unchanged selected config modules |     86 |      0 |

The seven original modules are byte-identical, including every assertion.
Their counts are 31/5/9/9/5/18/9. Detailed logs and receipt JSON are retained.
Cases exercise actual config owner, codec, real private file reads/writes and the
native conditional writer through the existing headless Hammerspoon test
harness. They include preserved complete source models, foreign/usable
neighbors, fresh readback, refused replacement, manual repair retry, valid sparse
values and an actual conditional publication fence against external replacement.
The Hammerspoon environment is controlled; this proves no hardware, Karabiner,
macOS application installation or real user session behavior.

Strict conventions pass (1774 AHK, 2743 Lua, 340 TOML).
Scoped canonical Prettier check of TODO passes. mac-bool-format.log records a
rejected unsupported path invocation of the formatter wrapper, not a passing
check; the subsequent canonical Prettier command is recorded separately.
Exported verify-change selectors and discovery prechecks passed. Its full
selected format/JS/macOS unit/macOS E2E gates were deliberately not run in this
subagent; root controls serial full-suite qualification. Hosted native
macOS/package/install qualification is also unrun. No cases were skipped.

Run focused owner checks from the isolated archive with:

```sh
source /workspace/tooling/activate-ergopti.sh
cd /tmp/ergopti-group1-todo33-domains
lua5.4 static/ergopti_plus/macos/tests/run.lua --only tests.unit.platform.remap.test_config_bool_leaf_policy
```

## Counterparts, remaining scope and dependency

Windows and Linux use tap_hold.toml with different per-key/root domains; neither
has the macOS combination-symmetry setting. Windows already rejects wrong-kind
per-key fields and its writer distinguishes Map from Array; native Windows
behavior was inspected only, not executed. Linux unrelated key setters preserve
an invalid global enabled leaf but do not warn; its scalar parent and array
binding writes have separate proven preservation/acknowledgement gaps, retained
as a proposal in LINUX-FOLLOW-UP.md rather than silently fixed here.

TODO33 stays partial. Known-slot domains, parent shapes, explicit leaf repair
intent, Linux writer gaps and the retired karabiner.enabled automatic deletion
still need separate source work and qualification. The existing legacy-deletion
assertion is not weakened in this candidate. Invalid schema stamps remain strict;
the centralized retirement exception remains in force.

conditional_layer_removal received the exact frozen config.lua postimage for
future serialized composition of native post-publication cleanup debt. That
distinct save_user_config third-receipt/bulk consumer work is not included in
this patch. Root/user currently prioritize integration of completed work and
precise follow-up handoff; this packet remains immutable and unapplied.
