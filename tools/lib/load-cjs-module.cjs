// tools/lib/load-cjs-module.cjs

/**
 * ==============================================================================
 * MODULE: CommonJS-in-an-ESM-package Loader
 * DESCRIPTION:
 * Loads a `.js` file that exports via `module.exports` from a repo whose
 * package.json declares `"type": "module"`.
 *
 * WHY THIS IS NEEDED AT ALL:
 * `"type": "module"` makes every bare `.js` file ESM. A file whose only export
 * mechanism is `module.exports = {...}` therefore exports NOTHING — `require()`
 * rejects it and `import()` returns an empty namespace, silently. Measured
 * across `_shared/`: **32 modules** are in that state, including every
 * `core/ports/*.spec.js` and the whole `modules/tooltip/` set.
 *
 * The port specs are fine in practice because codegen-contracts-json.cjs
 * carried a private copy of this loader. The tooltip modules had no such
 * consumer, so `layoutTestVectors()` and `dequeueTestVectors()` — the declared
 * source of truth for the tooltip corpus — were unreachable from any tool. The
 * gate that claimed to compare the JSON corpus against them could not have, and
 * checked the JSON's shape instead.
 *
 * Extracted here so there is one loader rather than one per consumer: a second
 * private copy is how the first one came to be the only thing keeping 27 spec
 * files reachable.
 *
 * WHY NOT JUST CONVERT THE FILES TO ESM:
 * That is the better end state, and it is a bigger change: the specs are read
 * by the AHK and Lua toolchains as text in places, and `export` syntax would
 * have to land together with every reader. This loader makes the existing files
 * usable today without a flag day.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

/**
 * Evaluates a CommonJS-style module and returns its exports.
 *
 * @param {string} filePath Absolute path to the .js file.
 * @returns {object} The module's `module.exports`.
 * @throws {Error} If the file is missing, or evaluates to no exports — an empty
 *   result means the file uses a mechanism this loader does not emulate, and
 *   returning it silently is exactly the failure being fixed.
 */
function loadCjsModule(filePath) {
	if (!fs.existsSync(filePath)) {
		throw new Error(`loadCjsModule: no such file: ${filePath}`);
	}
	const src = fs.readFileSync(filePath, 'utf8');
	const sandbox = { exports: {} };
	// eslint-disable-next-line no-new-func
	const factory = new Function('module', 'exports', 'require', '__filename', '__dirname', src);
	factory(sandbox, sandbox.exports, require, filePath, path.dirname(filePath));

	if (!sandbox.exports || Object.keys(sandbox.exports).length === 0) {
		throw new Error(
			`loadCjsModule: ${path.basename(filePath)} exported nothing. Either it uses ESM ` +
				'`export` syntax (import it instead) or its exports are genuinely empty — both of ' +
				'which a caller must know about rather than receive as {}.'
		);
	}
	return sandbox.exports;
}

module.exports = { loadCjsModule };
