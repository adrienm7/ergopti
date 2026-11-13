// tools/lib/identifiers.cjs

/**
 * ==============================================================================
 * MODULE: Tooling Identifiers
 * DESCRIPTION:
 * The application names, bundle ids, service labels and external hosts of
 * _shared/core/text/data/identifiers.json, for the Node build, CI and developer tools.
 * Reading the declaration through one module keeps those tools from spelling
 * the values again (tools/test/test-repo-url-single-source.cjs holds them to a
 * shrinking baseline of typed copies).
 *
 * FEATURES & RATIONALE:
 * 1. Fail fast: a missing group or a non-string value stops the tool at load
 *    time instead of building a name or URL around `undefined`.
 * 2. Frozen: a caller cannot mutate the shared declaration for its neighbours.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const { shared } = require('./paths.cjs');

const SOURCE = shared('core', 'text', 'data', 'identifiers.json');
const GROUPS = ['app', 'bundle_ids', 'service_labels', 'hosts'];

const identifiers = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
for (const group of GROUPS) {
	const table = identifiers[group];
	if (!table || typeof table !== 'object')
		throw new Error(`identifiers.json declares no "${group}" group.`);
	for (const [key, value] of Object.entries(table))
		if (typeof value !== 'string' || value === '')
			throw new Error(`identifiers.json: ${group}.${key} is not a non-empty string.`);
}
for (const value of Object.values(identifiers))
	if (value && typeof value === 'object') Object.freeze(value);

module.exports = Object.freeze(identifiers);
