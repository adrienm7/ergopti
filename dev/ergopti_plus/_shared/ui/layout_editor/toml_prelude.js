// _shared/ui/layout_editor/toml_prelude.js

/**
 * ==============================================================================
 * MODULE: Layout Editor TOML Prelude
 * DESCRIPTION:
 * Gives the vendored smol-toml build (vendor/smol-toml.js, the package's own
 * CommonJS file kept byte for byte so its pinned digest stays checkable) the
 * `exports` object it assigns to. source_io.js reads the codec from it.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page; the vendored file
// writes exports.parse and exports.stringify into it.
var exports = {};
