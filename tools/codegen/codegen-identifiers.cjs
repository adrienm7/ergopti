// tools/codegen/codegen-identifiers.cjs

/**
 * ==============================================================================
 * MODULE: Identifiers and Hosts Codegen
 * DESCRIPTION:
 * Emits _shared/core/text/engine/identifiers.lua, the shell, Python, Swift, AutoHotkey and
 * browser counterparts from _shared/core/text/data/identifiers.json: the
 * ErgoptiPlus file and bundle names, the bundle ids, the service labels and the
 * external hosts (GitHub, Ollama, Hugging Face) that the macOS and Linux Lua
 * drivers used to spell in dozens of files, and the field report names the
 * macOS, Linux and Windows collectors share (tools/dev/collect-*-field-report).
 *
 * WHY THIS EXISTS:
 * The parity audit (K4, K9) counted the `ErgoptiPlus.app` name 459 times, the
 * launcher bundle id 49 times and the Hugging Face host 388 times. A rename or
 * a mirror switch had no single place to start from. The generated file is
 * committed so no driver parses JSON for a constant.
 *
 * USAGE:  node tools/codegen/codegen-identifiers.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared/core/text/data/identifiers.json');
const OUTPUT = path.join(SP, '_shared/core/text/engine/identifiers.lua');
const OUTPUT_JS = path.join(SP, '_shared/ui/_generated/identifiers.js');
const OUTPUT_SH = path.join(SP, '_shared/core/text/data/identifiers.sh');
const OUTPUT_PY = path.join(SP, '_shared/core/text/data/identifiers.py');
const OUTPUT_AHK = path.join(SP, 'windows/_generated/identifiers.ahk');
const OUTPUT_SWIFT = path.join(
	SP,
	'macos/launcher/Sources/ErgoptiPlus/Identifiers.generated.swift'
);

const GROUPS = [
	'app',
	'bundle_ids',
	'signing_ids',
	'service_labels',
	'hosts',
	'dev_source',
	'field_report',
	'bytecode_package',
	'macos_notifications',
	'linux_stage',
	'locales'
];
// Groups only the Lua drivers read stay out of the shell, Python, JS, Swift and
// AutoHotkey projections: the bytecode package is the LuaJIT daemon's alone, and
// so is the name its atomic-write stages carry (linux/infra/stage_owner.lua). The
// catalogue shown for a system language without one also reaches AutoHotkey.
const LUA_ONLY_GROUPS = new Set(['bytecode_package', 'linux_stage', 'locales']);
// Groups the macOS launcher and its Lua runtime share reach Lua and Swift only:
// the launcher's quit request to its embedded runtime (MLC-002).
const MACOS_ONLY_GROUPS = new Set(['macos_notifications']);
const PROJECTED_GROUPS = GROUPS.filter(
	(group) => !LUA_ONLY_GROUPS.has(group) && !MACOS_ONLY_GROUPS.has(group)
);
const SWIFT_GROUPS = GROUPS.filter((group) => !LUA_ONLY_GROUPS.has(group));
// The system-language fallback reaches AutoHotkey too: Windows falls back to the
// same catalogue as the Lua drivers (core/i18n/engine/i18n.ahk _I18nDetectSystemLocale, I18W-001).
const AHK_GROUPS = [...PROJECTED_GROUPS, 'locales'];
const VALUE_SHAPE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
// The field report names are repository paths and a branch prefix: slash-
// separated plain segments, with an optional final slash for a prefix.
const PATH_SHAPE = /^[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9._-]+)*\/?$/;
// The bytecode package's file names, wire markers and the compiler's root-relative
// path (linux/infra/bytecode_package.lua, modules/updater/installer.lua).
const GROUP_SHAPE = { field_report: PATH_SHAPE, bytecode_package: PATH_SHAPE };

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
		if (typeof value !== 'string' || !(GROUP_SHAPE[group] ?? VALUE_SHAPE).test(value))
			fail(`${group}.${key}: ${JSON.stringify(value)} is not a plain identifier, host or path.`);
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

const lua = `--- _shared/core/text/engine/identifiers.lua
--- AUTO-GENERATED from _shared/core/text/data/identifiers.json.
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
	`${comment} AUTO-GENERATED from _shared/core/text/data/identifiers.json.\n` +
	`${comment} DO NOT EDIT BY HAND — run \`npm run codegen:identifiers\` to refresh.`;

/** The upper-case shell prefix of a group. */
const SHELL_PREFIX = {
	app: 'ERGOPTI_APP',
	bundle_ids: 'ERGOPTI_BUNDLE_ID',
	signing_ids: 'ERGOPTI_SIGNING_ID',
	service_labels: 'ERGOPTI_SERVICE_LABEL',
	hosts: 'ERGOPTI_HOST',
	dev_source: 'ERGOPTI_DEV_SOURCE',
	field_report: 'ERGOPTI_FIELD_REPORT'
};

const shell = `#!/bin/sh
# _shared/core/text/data/identifiers.sh
${BANNER('#')}

# Application names, bundle ids, service labels, external hosts and the field
# report names, for the shell tools and installers that source this file. Hosts
# are bare names: build a URL as "https://\${ERGOPTI_HOST_GITHUB}/...".
${PROJECTED_GROUPS.flatMap((group) =>
	Object.entries(source[group]).map(
		([key, value]) => `${SHELL_PREFIX[group]}_${key.toUpperCase()}="${value}"`
	)
).join('\n')}
`;

const python = `# _shared/core/text/data/identifiers.py
${BANNER('#')}
"""Application names, bundle ids, service labels and external hosts.

Hosts are bare names: build a URL as f"https://{HOSTS['github']}/...".
"""

${PROJECTED_GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(([key, value]) => `    "${key}": "${value}",`);
	return `${group.toUpperCase()} = {\n${rows.join('\n')}\n}`;
}).join('\n\n')}
`;

const js = `${BANNER('//')}

// Application names, bundle ids, service labels and external hosts for the
// classic-script pages. Hosts are bare names: build a URL as
// 'https://' + ERGOPTI_IDENTIFIERS.hosts.github + '/...'.
const ERGOPTI_IDENTIFIERS = Object.freeze({
${PROJECTED_GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(([key, value]) => `\t\t${key}: '${value}'`);
	return `\t${group}: Object.freeze({\n${rows.join(',\n')}\n\t})`;
}).join(',\n')}
});
`;

/** Swift enum name of a group. */
const SWIFT_ENUM = {
	app: 'App',
	bundle_ids: 'BundleIds',
	signing_ids: 'SigningIds',
	service_labels: 'ServiceLabels',
	hosts: 'Hosts',
	dev_source: 'DevSource',
	field_report: 'FieldReport',
	macos_notifications: 'MacosNotifications'
};
for (const group of SWIFT_GROUPS)
	if (!SWIFT_ENUM[group]) fail(`group "${group}" has no Swift enum name.`);
const camel = (key) => key.replace(/_([a-z0-9])/g, (_m, c) => c.toUpperCase());
const swift = `${BANNER('//')}

/// Application names, bundle ids, service labels and external hosts. Hosts are
/// bare names: build a URL as "https://\\(Identifiers.Hosts.github)/...".
enum Identifiers {
${SWIFT_GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(
		([key, value]) => `\t\tstatic let ${camel(key)} = "${value}"`
	);
	return `\tenum ${SWIFT_ENUM[group]} {\n${rows.join('\n')}\n\t}`;
}).join('\n')}
}
`;

/** AutoHotkey class name of a group. */
const AHK_CLASS = { ...SWIFT_ENUM, locales: 'Locales' };
const ahk = `\uFEFF; _generated/identifiers.ahk
${BANNER(';')}
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Application Identifiers and External Hosts
; DESCRIPTION:
; The application file names, bundle ids, service labels, external hosts and
; field report names, and the catalogue shown for a system language without
; one. A misspelt name fails at the first access. Hosts are bare names: build a
; URL as "https://" . Identifiers.Hosts.GITHUB . "/...".
; ==============================================================================

class Identifiers {
${AHK_GROUPS.map((group) => {
	const rows = Object.entries(source[group]).map(
		([key, value]) => `\t\tstatic ${key.toUpperCase()} := "${value}"`
	);
	return `\tclass ${AHK_CLASS[group]} {\n${rows.join('\n')}\n\t}`;
}).join('\n')}
}
`;

for (const [file, text] of [
	[OUTPUT, lua],
	[OUTPUT_JS, js],
	[OUTPUT_SH, shell],
	[OUTPUT_PY, python],
	[OUTPUT_SWIFT, swift],
	[OUTPUT_AHK, ahk]
]) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text, 'utf8');
	console.log(`  wrote ${path.relative(ROOT, file).split(path.sep).join('/')}`);
}
console.log(
	`[OK] identifiers generated: ${seen.size} value(s) in ${PROJECTED_GROUPS.length} group(s).`
);
