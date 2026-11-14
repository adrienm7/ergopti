# Pre-move Linux ownership helpers

Byte-for-byte copies of `static/ergopti_plus/linux/install/ownership.sh` and
`ownership_schema.sh` from the published tags `v1.0.9` and `v1.0.10-dev.175`,
the last releases before the structure move. An installed updater runs its own
copy of this helper against every new tarball, so these copies are a record of
shipped code and are never edited. The `.frozen` extension keeps them out of
the source lints, which would otherwise ask for a header that the published
bytes do not have. `tools/test/test-linux-legacy-update-probes.cjs` pins their
SHA-256 and runs them against the tarball this checkout packs.

Delete this folder together with `tools/build/add-linux-legacy-update-probes.sh`
(TODO.md « Legacy Linux updater probes »).
