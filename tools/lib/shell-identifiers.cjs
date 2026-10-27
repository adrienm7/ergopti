// tools/lib/shell-identifiers.cjs

/**
 * ==============================================================================
 * MODULE: Shell Identifier Expansion
 * DESCRIPTION:
 * The build scripts read the application names, bundle ids and hosts from
 * _shared/data/identifiers.sh (generated from identifiers.json) instead of
 * spelling them. Tests that read a script's text to check a value expand those
 * references with this helper, so they compare the value the script resolves to
 * rather than the shell syntax that fetches it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const IDENTIFIERS_SH = path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.sh');

/** Reads the NAME="value" assignments of the generated shell file. */
function readAssignments() {
	const values = new Map();
	for (const line of fs.readFileSync(IDENTIFIERS_SH, 'utf8').split('\n')) {
		const match = /^(ERGOPTI_[A-Z0-9_]+)="([^"]*)"$/.exec(line);
		if (match) values.set(match[1], match[2]);
	}
	if (values.size === 0) throw new Error('identifiers.sh declares no ERGOPTI_ assignment');
	return values;
}

/**
 * Replaces $ERGOPTI_NAME and ${ERGOPTI_NAME} in a shell script's text by the value.
 * Any other ERGOPTI_ variable (the version, the channel…) is an environment
 * variable of the script, not an identifier, and is left as written.
 * @param {string} text Script text.
 * @returns {string} Text with the identifiers resolved.
 */
function expandIdentifiers(text) {
	const values = readAssignments();
	return text.replace(/\$\{?(ERGOPTI_[A-Z0-9_]+)\}?/g, (_match, name) => {
		return values.has(name) ? values.get(name) : _match;
	});
}

module.exports = { expandIdentifiers };
