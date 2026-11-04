# Recovery and lifecycle parity audit

Pinned source: 3a680d9f530a9af686fccc16d3f7611ec7fb034c.

Review six bounded OS/module scopes: Windows/macOS/Linux folder migration, and Windows/macOS/Linux updater/reload handoff. Six independent reviewers own separate scope artifacts. Root examines shared owners, challenges retained findings and consolidates cross-OS causes, intentional decisions and evidence limits. No production or registered test edits. Use private fixtures only; no actual user home, clipboard, service control, install or updater network request.

Each scope maps public entry through owner, native side effect, receipt and cleanup/recovery. A confirmed root resets its two-dry-pass counter. Preserve previous audit artifacts. Deliver new revision-pinned reports/manifests, actionable TODO entries and links; validate metadata and safe proofs, targeted repository checks, commit on dev and push as previously authorized. Native exclusions stay open. Aggregate counts describe OS manifestations, not distinct roots or runtime certifications.
