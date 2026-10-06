<!-- docs/handovers/2026-10-04-parallel-containers/group3-native-publisher/README.md -->

# Inactive native publisher handoff

Group 3 owns these publisher additions; Group 2 owns the separate hotstring
controllers for personal metadata (102) and common migration (104). This
artifact preserves an independently reviewed source packet and its API. It does
not install the patch in the product or mark any TODO item complete.

- Base: `689d30293704093feab2e3caa077604e88560eb6`, verified against actual remote
  `origin/dev` when the packet was prepared.
- Source: [native-publisher-only.patch](native-publisher-only.patch).
- SHA-256: `e0fb4e31fd11a12ca46724bc1e10b5d9f6a29b447f5b3fab28ce0fa1ec6ba5a4`.
- Pre/post image identities, byte counts and modes: [metadata.json](metadata.json).
- Complete bounded API and consumer obligations: [interface-details.md](interface-details.md).

The packet contains only the new shared diagnostic reporter, shared TOML Writer
and macOS FileSystem publisher. Preferences and product controllers are outside
it. Recheck all preimages against current upstream before consuming the patch;
coordinate producer ownership and qualify each separately owned consumer.
An isolated preimage apply-check passed. Packet preparation did not change
production sources or run a separately installed packet test suite.

The composed source behind this packet passed 94 focused cases with independent
review: native publication 13, retained transaction 28, private diagnostics 8,
conditional remove 5 and providers 40. Receipt-mint omission failed 10 new cases;
observer omission failed 9. Actual temporary-file IO exercised the adapter,
Writer, Preferences and transaction, with controlled `hs.fs` lock/symlink
metadata. Real macOS interprocess locking and physical symlinks remain required.
Equal candidate bytes or parse success cannot settle physical lock debt.

Formatting and the selected JS gate cover this inactive documentation/artifact
commit. They do not execute the source packet. Full composed product gates,
hosted native macOS qualification and new controller-specific causal tests are
still pending. Advisory locks protect cooperating writers; public Darwin rename
does not provide pathname CAS against arbitrary noncooperating writers.
