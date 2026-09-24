// tools/codegen/codegen-update-schedule.cjs

/**
 * ==============================================================================
 * MODULE: Update-Check Schedule Codegen
 * DESCRIPTION:
 * Emits the automatic update-check timing of _shared/modules/updater/
 * defaults.json (presets, boot delay, jitter, failure backoff, re-evaluation
 * period and the key of the persisted check record) as the data the Windows
 * schedule port (windows/modules/updater/schedule.ahk) interprets.
 *
 * WHY THIS EXISTS:
 * The frequency presets were copied by hand into the AHK updater and the Linux
 * manager, and the 30 s boot delay was an unpinned literal in the AHK timer. A
 * compiled AHK build has no JSON reader at include time, so it gets a generated
 * copy instead of a hand-maintained one; macOS and Linux decode the JSON at
 * runtime. The timing is validated by the canonical schedule module
 * (_shared/modules/updater/schedule.js) before anything is written.
 *
 * USAGE:  node tools/codegen/codegen-update-schedule.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared', 'modules', 'updater', 'defaults.json');
const SCHEDULE = path.join(SP, '_shared', 'modules', 'updater', 'schedule.js');
const AHK_OUTPUT = path.join(SP, 'windows', '_generated', 'update_schedule.ahk');
const RUN_HINT = 'npm run codegen:update-schedule';

// ==========================================
// ==========================================
// ======= 1/ Emitters =====================
// ==========================================
// ==========================================

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(value) {
	return '"' + String(value).replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

/** A whole number, refused otherwise so a malformed value cannot reach AHK. */
function ahkInt(value, name) {
	if (!Number.isInteger(value))
		throw new Error(`${name} must be a whole number, got ${JSON.stringify(value)}`);
	return String(value);
}

function emitAhk(defaults) {
	const timing = defaults.timing;
	const presets = timing.check_interval_presets
		.map(
			(preset) =>
				`\t\t\tMap("code", ${ahkStr(preset.code)}, "seconds", ${ahkInt(preset.seconds, `preset ${preset.code}`)})`
		)
		.join(',\n');
	const backoff = timing.failure_backoff_sec
		.map((s) => ahkInt(s, 'failure_backoff_sec'))
		.join(', ');
	return (
		'﻿; _generated/update_schedule.ahk\n' +
		'; AUTO-GENERATED from _shared/modules/updater/defaults.json.\n' +
		`; DO NOT EDIT BY HAND — run \`${RUN_HINT}\` to refresh.\n` +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Update-Check Schedule Data (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The automatic update-check timing of the shared defaults, as the data\n' +
		'; modules/updater/schedule.ahk interprets. A compiled build has no JSON reader\n' +
		'; at include time, and a hand-maintained copy would drift.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter:\n' +
		'; the schedule port reads it on first use, after every #Include was processed.\n' +
		'UpdateScheduleData() {\n' +
		'\treturn Map(\n' +
		`\t\t"default_check_interval_sec", ${ahkInt(timing.default_check_interval_sec, 'default_check_interval_sec')},\n` +
		`\t\t"boot_check_delay_sec", ${ahkInt(timing.boot_check_delay_sec, 'boot_check_delay_sec')},\n` +
		'\t\t"check_interval_presets", [\n' +
		presets +
		'\n\t\t],\n' +
		`\t\t"jitter_percent", ${ahkInt(timing.jitter_percent, 'jitter_percent')},\n` +
		`\t\t"jitter_max_sec", ${ahkInt(timing.jitter_max_sec, 'jitter_max_sec')},\n` +
		`\t\t"failure_backoff_sec", [${backoff}],\n` +
		`\t\t"reevaluate_sec", ${ahkInt(timing.reevaluate_sec, 'reevaluate_sec')},\n` +
		`\t\t"state_storage_key", ${ahkStr(defaults.check_state.storage_key)})\n` +
		'}\n'
	);
}

// ==========================================
// ==========================================
// ======= 2/ Public API & Main ============
// ==========================================
// ==========================================

/**
 * Renders every generated artifact of the defaults without writing anything.
 * @param {Object} defaults - Decoded defaults.json.
 * @return {{path: string, content: string}[]}
 */
function renderOutputs(defaults) {
	return [{ path: AHK_OUTPUT, content: emitAhk(defaults) }];
}

async function main() {
	const defaults = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	const { validateTiming } = await import(pathToFileURL(SCHEDULE).href);
	validateTiming(defaults.timing);
	for (const output of renderOutputs(defaults)) {
		fs.mkdirSync(path.dirname(output.path), { recursive: true });
		// LF everywhere, per the repository's source-encoding rule; the AHK payload
		// already carries its required UTF-8 BOM as the first character.
		fs.writeFileSync(output.path, output.content.replace(/\r\n/g, '\n'), 'utf8');
		console.log(`  wrote ${path.relative(ROOT, output.path).split(path.sep).join('/')}`);
	}
	console.log(
		`[OK] update-check schedule generated: ${defaults.timing.check_interval_presets.length} preset(s).`
	);
}

if (require.main === module) {
	main().catch((error) => {
		console.error(`[ERROR] ${error.message}`);
		process.exit(1);
	});
}

module.exports = { renderOutputs };
