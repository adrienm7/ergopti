// tools/codegen/codegen-identifiers.cjs

/**
 * ==============================================================================
 * MODULE: Identifiers and Hosts Codegen
 * DESCRIPTION:
 * Emits _shared/lua/identifiers.lua, the shell, Python, Swift and browser
 * counterparts from _shared/data/identifiers.json: the
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
const OUTPUT_JS = path.join(SP, '_shared/ui/_generated/identifiers.js');
const OUTPUT_SH = path.join(SP, '_shared/data/identifiers.sh');
const OUTPUT_PY = path.join(SP, '_shared/data/identifiers.py');
const OUTPUT_SWIFT = path.join(
	SP,
	'macos/launcher/Sources/ErgoptiPlus/Identifiers.generated.swift'
);

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

const BANNER = (comment) =>
	`${comment} AUTO-GENERATED from _shared/data/identifiers.json.\n` +
	`${comment} DO NOT EDIT BY HAND — run \`npm run codegen:identifiers\` to refresh.`;

/** The upper-case shell prefix of a group. */
const SHELL_PREFIX = {
	app: 'ERGOPTI_APP',
	bundle_ids: 'ERGOPTI_BUNDLE_ID',
	service_labels: 'ERGOPTI_SERVICE_LABEL',
	hosts: 'ERGOPTI_HOST'
};

const shell = `#!/bin/sh
${BANNER('#')}

# Application names, bundle ids, service labels and external hosts, for the shell
# tools and installers that source this file. Hosts are bare names: build a URL as
# "https://\${ERGOPTI_HOST_GITHUB}/...".
${GROUPS.flatMap((group) =>
	Object.entries(source[group]).map(
		([key, value]) => `${SHELL_PREFIX[group]}_${key.toUpperCase()}="${value}"`
	)
).join('\n')}
`;

const python = `${BANNER('#')}
"""Application names, bundle ids, service labels and external hosts.

Hosts are bare names: build a URL as f"https://{HOSTS['github']}/...".
"""

${GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(([key, value]) => `    "${key}": "${value}",`);
	return `${group.toUpperCase()} = {\n${rows.join('\n')}\n}`;
}).join('\n\n')}
`;

const js = `${BANNER('//')}

// Application names, bundle ids, service labels and external hosts for the
// classic-script pages. Hosts are bare names: build a URL as
// 'https://' + ERGOPTI_IDENTIFIERS.hosts.github + '/...'.
const ERGOPTI_IDENTIFIERS = Object.freeze({
${GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(([key, value]) => `\t\t${key}: '${value}'`);
	return `\t${group}: Object.freeze({\n${rows.join(',\n')}\n\t})`;
}).join(',\n')}
});
`;

/** Swift enum name of a group. */
const SWIFT_ENUM = {
	app: 'App',
	bundle_ids: 'BundleIds',
	service_labels: 'ServiceLabels',
	hosts: 'Hosts'
};
const camel = (key) => key.replace(/_([a-z0-9])/g, (_m, c) => c.toUpperCase());
const swift = `${BANNER('//')}

/// Application names, bundle ids, service labels and external hosts. Hosts are
/// bare names: build a URL as "https://\\(Identifiers.Hosts.github)/...".
enum Identifiers {
${GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(
		([key, value]) => `\t\tstatic let ${camel(key)} = "${value}"`
	);
	return `\tenum ${SWIFT_ENUM[group]} {\n${rows.join('\n')}\n\t}`;
}).join('\n')}
}
`;

for (const [file, text] of [
	[OUTPUT, lua],
	[OUTPUT_JS, js],
	[OUTPUT_SH, shell],
	[OUTPUT_PY, python],
	[OUTPUT_SWIFT, swift]
]) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text, 'utf8');
	console.log(`  wrote ${path.relative(ROOT, file).split(path.sep).join('/')}`);
}
console.log(`[OK] identifiers generated: ${seen.size} value(s) in ${GROUPS.length} group(s).`);
