// tools/lib/paths.cjs

/**
 * ==============================================================================
 * MODULE: Tooling Shared-Tree Paths
 * DESCRIPTION:
 * The single source of truth for the cross-platform _shared/ tree location used
 * by every dev tool (codegen, tests, linters, build scripts). Tools used to
 * each hardcode the literal "static/ergopti_plus/_shared/..." string; this module
 * centralises it so a future rename of the _shared/ tree only needs editing
 * SHARED_REL on the one line below.
 *
 * FEATURES & RATIONALE:
 * 1. One literal: SHARED_REL is the only place the folder name appears across the
 *    whole toolchain. Everything else derives from it.
 * 2. Both forms: SHARED_DIR (absolute) for filesystem access, SHARED_REL
 *    (repo-relative, forward-slash) for tools that resolve against their own
 *    REPO_ROOT or emit the path into generated-file banners.
 * 3. CJS + ESM: a plain CommonJS module so .cjs tools `require()` it directly and
 *    ESM .js tools `import` its default export.
 * ==============================================================================
 */

'use strict';

const path = require('path');

// Repo root is two levels up from tools/lib/.
const REPO_ROOT = path.resolve(__dirname, '..', '..');

// THE single source of truth for the shared-tree location. Forward-slash,
// repo-relative — a future rename of the _shared/ tree is a one-token edit here.
const SHARED_REL = 'static/ergopti_plus/_shared';

// Absolute path to the _shared/ tree.
const SHARED_DIR = path.join(REPO_ROOT, SHARED_REL);

/**
 * Resolves an absolute path inside the _shared/ tree.
 * @param {...string} segments - Path segments under _shared/, e.g. "ports", "contracts.json".
 * @returns {string} Absolute filesystem path.
 */
function shared(...segments) {
	return path.join(SHARED_DIR, ...segments);
}

/**
 * Resolves a repo-relative (forward-slash) path inside the _shared/ tree. Useful
 * for tools that join against their own REPO_ROOT or print the path verbatim.
 * @param {...string} segments - Path segments under _shared/.
 * @returns {string} Repo-relative path, e.g. "static/ergopti_plus/_shared/ports/contracts.json".
 */
function sharedRel(...segments) {
	return [SHARED_REL, ...segments].join('/');
}

module.exports = { REPO_ROOT, SHARED_REL, SHARED_DIR, shared, sharedRel };
