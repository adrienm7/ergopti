// tools/codegen/codegen-update-channels.cjs

/**
 * ==============================================================================
 * MODULE: Update Channel Registry Codegen
 * DESCRIPTION:
 * Emits the shared update-channel registry
 * (_shared/modules/updater/channels.json) for the consumers that cannot read the
 * JSON file themselves: the WebView pages (a script that defines the data), the
 * Windows driver (a data function the AHK matcher interprets) and the macOS
 * launcher (the appcast of every channel, the only ids its commands accept).
 *
 * WHY THIS EXISTS:
 * The channels were spelled by hand in every driver — "main"/"dev" literals in
 * the AHK updater, two hardcoded buttons in the Versions page, a '-dev.' test on
 * macOS and a 'stable'/'dev' vocabulary on Linux. A compiled AHK build and an
 * inlined page have no JSON reader at include time, so they get a generated
 * copy instead of a hand-maintained one; the macOS and Linux drivers decode the
 * JSON at runtime. The registry is validated through the canonical matcher
 * (_shared/ui/update_channels.js) before anything is written, so a malformed
 * registry cannot reach a driver.
 *
 * USAGE:  node tools/codegen/codegen-update-channels.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared', 'modules', 'updater', 'channels.json');
const MATCHER = path.join(SP, '_shared', 'ui', 'update_channels.js');
const PAGE_OUTPUT = path.join(SP, '_shared', 'ui', '_generated', 'update_channel_registry.js');
const AHK_OUTPUT = path.join(SP, 'windows', '_generated', 'update_channels.ahk');
const SWIFT_OUTPUT = path.join(
	SP,
	'macos',
	'launcher',
	'Sources',
	'ErgoptiPlus',
	'UpdateChannels.generated.swift'
);
const RUN_HINT = 'npm run codegen:update-channels';

// ==========================================
// ==========================================
// ======= 1/ Validation ===================
// ==========================================
// ==========================================

/** Validates the registry through the canonical matcher; throws when invalid. */
function validate(registry) {
	const sandbox = {};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(MATCHER, 'utf8'), sandbox, { filename: MATCHER });
	sandbox.createUpdateChannels(registry);
}

/** The registry without its documentation field, as the consumers read it. */
function payload(registry) {
	const data = {};
	for (const [key, value] of Object.entries(registry)) {
		if (key !== '_comment') data[key] = value;
	}
	return data;
}

// ==========================================
// ==========================================
// ======= 2/ Emitters =====================
// ==========================================
// ==========================================

function emitPage(registry) {
	const literal = JSON.stringify(payload(registry), null, '\t').replace(/\n/g, '\n\t');
	return (
		'// _shared/ui/_generated/update_channel_registry.js\n' +
		'\n' +
		'// ==========================================\n' +
		'// AUTO-GENERATED — do not edit manually\n' +
		'// Source: static/ergopti_plus/_shared/modules/updater/channels.json\n' +
		`// Run: ${RUN_HINT}\n` +
		'// ==========================================\n' +
		'\n' +
		'// The shared update-channel registry as page data. A page cannot read the\n' +
		'// JSON file, so it loads this script before ../update_channels.js, which\n' +
		'// interprets it.\n' +
		'(function (global) {\n' +
		"\t'use strict';\n" +
		'\n' +
		`\tglobal.UPDATE_CHANNEL_REGISTRY = ${literal};\n` +
		'})(window);\n'
	);
}

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(value) {
	return '"' + String(value).replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

function ahkBool(value) {
	return value ? 'true' : 'false';
}

function emitAhkChannel(channel) {
	const pre = channel.tag.prerelease;
	const prerelease =
		pre === false ? '0' : `Map("label", ${ahkStr(pre.label)}, "counter", ${ahkBool(pre.counter)})`;
	return (
		'\t\tMap(\n' +
		`\t\t\t"id", ${ahkStr(channel.id)},\n` +
		`\t\t\t"label_key", ${ahkStr(channel.label_key)},\n` +
		`\t\t\t"menu_label_key", ${ahkStr(channel.menu_label_key)},\n` +
		`\t\t\t"aliases", [${channel.aliases.map(ahkStr).join(', ')}],\n` +
		`\t\t\t"github_prerelease", ${ahkBool(channel.github_prerelease)},\n` +
		`\t\t\t"tag_core", ${ahkStr(channel.tag.core)},\n` +
		`\t\t\t"tag_prerelease", ${prerelease},\n` +
		`\t\t\t"sparkle_feed", ${ahkStr(channel.sparkle_feed)})`
	);
}

function emitAhk(registry) {
	return (
		'﻿; _generated/update_channels.ahk\n' +
		'; AUTO-GENERATED from _shared/modules/updater/channels.json.\n' +
		`; DO NOT EDIT BY HAND — run \`${RUN_HINT}\` to refresh.\n` +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Update Channel Registry Data (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The shared update-channel registry, in channel order (the stability rank),\n' +
		'; as the data modules/updater/channels.ahk interprets. A compiled build has no\n' +
		'; JSON reader at include time, and a hand-maintained copy would drift.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter:\n' +
		'; the matcher reads it on first use, after every #Include has been processed.\n' +
		'UpdateChannelRegistryData() {\n' +
		'\treturn Map(\n' +
		`\t\t"schema_version", ${Number(registry.schema_version)},\n` +
		`\t\t"unreleased_build_channel", ${ahkStr(registry.unreleased_build_channel)},\n` +
		'\t\t"channels", [\n' +
		registry.channels.map((channel) => '\t' + emitAhkChannel(channel).replace(/\n/g, '\n\t')).join(',\n') +
		'\n\t\t])\n' +
		'}\n'
	);
}

/** A Swift double-quoted string literal. */
function swiftStr(value) {
	return '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

function emitSwift(registry) {
	const rows = registry.channels.map(
		(channel) => `\t${swiftStr(channel.id)}: ${swiftStr(channel.sparkle_feed)},`
	);
	return (
		'// Sources/ErgoptiPlus/UpdateChannels.generated.swift\n' +
		'// AUTO-GENERATED from _shared/modules/updater/channels.json.\n' +
		`// DO NOT EDIT BY HAND -- run \`${RUN_HINT}\` to refresh.\n` +
		'\n' +
		'// ==============================================================================\n' +
		'// MODULE: Update Channel Feeds\n' +
		'// DESCRIPTION:\n' +
		'// The Sparkle appcast of every channel of the shared update-channel registry.\n' +
		'// The launcher accepts a channel command only for these ids and serves Sparkle\n' +
		"// the subscribed channel's appcast, so a new channel is a data edit.\n" +
		'// ==============================================================================\n' +
		'\n' +
		'let kUpdateChannelFeeds: [String: String] = [\n' +
		rows.join('\n') +
		'\n]\n'
	);
}

// ==========================================
// ==========================================
// ======= 3/ Public API & Main ============
// ==========================================
// ==========================================

/**
 * Renders every generated artifact of a registry without writing anything.
 * @param {Object} registry - Decoded channels.json.
 * @return {{path: string, content: string}[]}
 */
function renderOutputs(registry) {
	validate(registry);
	return [
		{ path: PAGE_OUTPUT, content: emitPage(registry) },
		{ path: AHK_OUTPUT, content: emitAhk(registry) },
		{ path: SWIFT_OUTPUT, content: emitSwift(registry) }
	];
}

function main() {
	const registry = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	const outputs = renderOutputs(registry);
	for (const output of outputs) {
		fs.mkdirSync(path.dirname(output.path), { recursive: true });
		// LF everywhere, per the repository's source-encoding rule; the AHK payload
		// already carries its required UTF-8 BOM as the first character.
		fs.writeFileSync(output.path, output.content.replace(/\r\n/g, '\n'), 'utf8');
		console.log(`  wrote ${path.relative(ROOT, output.path).split(path.sep).join('/')}`);
	}
	console.log(`[OK] update channel registry generated: ${registry.channels.length} channel(s).`);
}

if (require.main === module) main();

module.exports = { renderOutputs };
