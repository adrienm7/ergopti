# Shared UI vendors

These browser bundles are committed so privileged native webviews never execute
mutable CDN code and remain functional offline. `vendor-manifest.json` pins each
immutable upstream URL and SHA-256 digest. `test-linux-webview-security.cjs`
verifies every byte before changes can pass the repository gate.

Do not replace a bundle without updating its exact version, source, digest, and
license notice in the same commit.
