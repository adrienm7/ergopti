<!-- tools/build/fixtures/remap_runtime_vhd_fixture.README.md -->

# Genuine portable VHD test inputs

`remap_runtime_vhd_pristine.tar.gz` is a fixed, independently authenticated,
vendored test input. Its 1,019 ordinary files contain 10,339,208 unmodified source
bytes from the pinned upstream tree, including the complete vendor include tree
and both original `LICENSE.md` files. The independent canonical manifest records
the original bytes and Git blob identities. It is frozen before the exporter and
never regenerated from the implementation under test.

The archive is 1,414,078 bytes, SHA-256
`6389c53e3adb6cdfd13a80e0580758ac6cff4c985a26ff18dcec204be2aa5877`.
Its gzip header uses an empty filename, mtime zero and OS byte 255. The canonical
manifest is 267,668 bytes, SHA-256
`b7ac1a92ca736a957116d032774a3182e32303bcef055e37863a366195026869`.

## Explicit import/export ownership

`tools/build/generate_remap_runtime_vhd_fixture.py` is this fixed input's explicit
import/export provenance owner. It reads the genuine original source checkout,
verifies the independently frozen file digests and actual pinned Git roots,
produces the deterministic source archive, and copies the original canonical
manifest byte-for-byte. Export never creates new expected source rows. It never
uses its own output archive as a substitute for independently authenticated
original input.

This is a narrow approved exception to the generator registry's general prose
about listing every repository generator. The archive and canonical manifest
are fixed independent corpus inputs, imported explicitly from upstream; they
are outside the ordinary product-generation traversal in
`tools/build/generators.cjs`. They do not depend on the current implementation and
must not be rewritten by `npm run gen` or a normal product drift probe.

The actual registry controls compare declared product outputs and fixed product
targets (`test-features-manifest-no-drift.cjs`), require one execution owner per
registered output (`test-generator-output-ownership.cjs`), and derive formatting
exclusions from registered outputs (`test-format-gate.cjs`). They do not discover
or automatically register this corpus input. The registry prose remains a real
general requirement; this documented input-export classification is its explicit
scoped exception. The registry and its existing entries remain unchanged.

Normal fixture validation verifies both fixed input hashes and each member's
independent source identity. An integrity-only check is validation, not generator
execution, and must not be registered as a fake product generator. A fresh export
requires the genuine checkout; its absence is an explicit prerequisite failure.

## Reproduce an authentic export

Use the prepared, canonical, caller-owned pristine checkout with these actual
Git pins, including the genuine initialized submodules:

- main source: `9312593e1a3bf72b94c63c524ebabe2637442e8a`;
- VirtualHIDDevice: `bdfcb459b2eaca8ccda680a73b0dc898f330f4bb`;
- license-version package lock: `6a8b2d64b993746d489432b45455e33b7fb8e09f`.

The main and VirtualHIDDevice roots must be clean, including ignored and
untracked files. The exporter verifies their actual Git heads before reading all
fixed source files. Run the export into a new empty private directory on macOS
or Linux. For example, after setting `fixture_source_root` to that canonical
absolute checkout path:

```bash
fixture_export_root=$(python -c 'from pathlib import Path; import tempfile; print(Path(tempfile.mkdtemp(prefix="vhd-export-")).resolve())')
python tools/build/generate_remap_runtime_vhd_fixture.py \
  --source-root "$fixture_source_root" --output-root "$fixture_export_root"
python tools/build/generate_remap_runtime_vhd_fixture.py \
  --source-root "$fixture_source_root" --output-root "$fixture_export_root" --check
```

The export refuses drift and copies the canonical manifest without regenerating
its expectations. Both output files must match the published byte hashes above.
The private export directory belongs to this invocation and may be retired after
inspection. Offline validation consumes the frozen input directly; it needs no
190 MB checkout, download, native build or ordinary product generator traversal.

## License supplement and validation scope

`remap_runtime_vhd_fixture.LICENSES.md` contains twelve complete original texts
from locked upstream packages, covering the fifteen vendor include roots. The
shared Boost 1.0 text covers retained Asio, Boost/ut and PQRs references and matches
the official Boost repository license byte-for-byte. Every original copyright
notice stays in its source file.
It also includes Abseil's Apache 2.0 license and exact original copyright/license
preamble from commit `10cb35e459f5ecca5b2ff107635da0bfa41011b4`, which the retained
nlohmann helper names explicitly. `remap_runtime_vhd_fixture.licenses.json`
records the actual package-lock declarations, immutable commit URLs, source
hashes and exact original-text byte ranges. The license supplement is additive;
the frozen 1,019-row manifest and archive remain unchanged. Original copyright
notices and bundled fmt's permission text and exception remain whole inside the
archive.

The adapter runs the existing 13 portable source and C++ controls, unchanged,
in four selections: ten source controls, one timer control, one callback control,
and one composed lower-peer control. It preserves normal or optimized Python
mode and the existing compilation/executable budgets. Its fixture controls use
independently frozen refusal expectations and real filesystem/archive mutations.
The tests exercise genuine portable Asio/PQRs behavior with the original disclosed
native leaf models.

This input supplies source-byte provenance for portable controls. It supplies no
Darwin API, protected daemon, audit-token, native principal, installed artifact,
physical device or capture authority. Actual native source custody, full pristine
runtime checks, the original native build deadline, packaging and installation
remain separate acceptance requirements.
