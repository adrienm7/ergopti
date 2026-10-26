// tools/codegen/codegen-identifiers.cjs

/**
 * ==============================================================================
 * MODULE: Identifiers and Hosts Codegen
 * DESCRIPTION:
 * Emits _shared/lua/identifiers.lua from _shared/data/identifiers.json: the
 * ErgoptiPlus file and bundle names, the bundle ids, the service labels and the
 * external hosts (GitHub, Ollama, Hugging Face) that the macOS and Linux Lua
 * drivers used to spell in dozens of files.
 *
 * WHY THIS EXISTS:
 * The parity audit (K4, K9) counted the `ErgoptiPlus.app` name 459 times, the
 * launcher bundle id 49 times and the Hugging Face host 388 times. A rename or
 * a mirror switch had no single place to start from. The generated file is
 * committed so no driver parses JSON for a constant; the Windows driver is not
 * generated here yet (see the PAR-83 note in docs/ERGOPTIPLUS_TODO.md).
 *
 * USAGE:  node tools/codegen/codegen-identifiers.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared/data/identifiers.json');
const OUTPUT = path.join(SP, '_shared/lua/identifiers.lua');

const GROUPS = ['app', 'bundle_ids', 'service_labels', 'hosts'];
const VALUE_SHAPE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** Stops generation with one exact reason. */
function fail(message) {
	console.error(`[ERROR] identifiers.json: ${message}`);
	process.exit(1);
}

const source = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
const seen = new Map();
for (const group of GROUPS) {
	const table = source[group];
	if (!table || typeof table !== 'object' || Object.keys(table).length === 0)
		fail(`"${group}" must be a non-empty object.`);
	for (const [key, value] of Object.entries(table)) {
		if (!/^[a-z][a-z0-9_]*$/.test(key)) fail(`${group}.${key}: key must be snake_case.`);
		if (typeof value !== 'string' || !VALUE_SHAPE.test(value))
			fail(`${group}.${key}: ${JSON.stringify(value)} is not a plain identifier or host.`);
		// Two keys with one value are two names for one thing: keep one.
		if (group !== 'app' && seen.has(value))
			fail(`${group}.${key} repeats ${seen.get(value)} (${value}).`);
		seen.set(value, `${group}.${key}`);
	}
}
for (const key of Object.keys(source))
	if (key !== '_comment' && !GROUPS.includes(key)) fail(`unknown group "${key}".`);

/** Renders one group as a Lua table. */
function emitGroup(group) {
	const rows = Object.entries(source[group]).map(([key, value]) => `\t\t${key} = "${value}",`);
	return `\t${group} = {\n${rows.join('\n')}\n\t},`;
}

const lua = `--- _shared/lua/identifiers.lua
--- AUTO-GENERATED from _shared/data/identifiers.json.
--- DO NOT EDIT BY HAND — run \`npm run codegen:identifiers\` to refresh.

--- ==============================================================================
--- DATA: Application Identifiers and External Hosts
--- DESCRIPTION:
--- The application file and bundle names, the bundle ids, the service labels and
--- the external hosts shared by the Lua drivers. Hosts are bare names: build a
--- URL as "https://" .. hosts.github .. "/...".
--- ==============================================================================

return {
${GROUPS.map(emitGroup).join('\n')}
}
`;

fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
fs.writeFileSync(OUTPUT, lua, 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUTPUT).split(path.sep).join('/')}`);
console.log(`[OK] identifiers generated: ${seen.size} value(s) in ${GROUPS.length} group(s).`);
