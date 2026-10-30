#!/usr/bin/env node
// tools/test/test-field-log-scrub.cjs

/**
 * ==============================================================================
 * MODULE: Field Log Scrubber Tests
 * DESCRIPTION:
 * A field report is pushed to a public repository, so tools/dev/field-log-scrub.py
 * must remove the user's typed text from every driver's log. The lines below are
 * built from the log templates of the driver sources, read here: a template that
 * changes fails this gate, because the scrubber matches its spelling. No line comes
 * from a real log: every value is a canary.
 *
 * Also pins the collectors: the Windows and Linux ones copy logs through the
 * scrubber only, and read the digests from the scrubbed copies.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { reportNotExecuted } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRUB = path.join(ROOT, 'tools/dev/field-log-scrub.py');
const BUNDLED = path.join(ROOT, 'static/ergopti_plus/_shared/modules/hotstrings');
const WINDOWS = path.join(ROOT, 'static/ergopti_plus/windows');
const LINUX = path.join(ROOT, 'static/ergopti_plus/linux');
const CANARY = 'TYPEDCANARY';
const STAMP = '2026-10-30 10:00:00:000';

/**
 * One log template, read from its source so that a changed spelling fails here.
 * @param {string} driver The driver folder.
 * @param {string} file The source file, relative to it.
 * @param {string} template The template as the source writes it.
 * @param {string[]} values What each placeholder receives.
 * @param {string} [expected] A fragment the scrubbed line must still hold.
 */
const CASES = [
	[
		WINDOWS,
		'modules/keymap/llm_bridge.ahk',
		"KEEP: keystroke '{1}' ignored — prediction still in min-display window.",
		[CANARY]
	],
	[
		WINDOWS,
		'modules/keymap/llm_bridge.ahk',
		"DISMISS: keystroke '{1}' typed while a prediction was shown.",
		[CANARY]
	],
	[
		WINDOWS,
		'infra/hotstrings/hotstring_inputhook.ahk',
		"OnChar error for char '{1}': {2}.",
		[CANARY, 'boom'],
		': boom.'
	],
	[
		WINDOWS,
		'infra/hotstrings/hotstring_inputhook.ahk',
		"UIA wrap error for char '{1}': {2}.",
		[CANARY, 'boom'],
		': boom.'
	],
	[
		WINDOWS,
		'infra/hotstrings/hotstring_inputhook.ahk',
		"DBG calling TooltipShow: {1} item(s), first='{2}'.",
		['1', CANARY],
		'1 item(s)'
	],
	[
		WINDOWS,
		'modules/llm/api_ollama/ollama_streaming.ahk',
		'Prediction received ({1} chars): «{2}».',
		['11', CANARY],
		'(11 chars)'
	],
	[
		WINDOWS,
		'modules/llm/api_ollama/ollama_streaming.ahk',
		'Ollama returned an empty prediction (parse miss). Body: «{1}».{2}',
		[CANARY, ` Payload: «${CANARY}».`],
		'parse miss'
	],
	[
		WINDOWS,
		'modules/llm/parser.ahk',
		'ProcessPrediction crashed on model output — variant dropped: {1} | block: «{2}».',
		['boom', CANARY],
		'boom'
	],
	[
		WINDOWS,
		'modules/llm/api_ollama/ollama_payload.ahk',
		'JSON parse failed in ChatResponse: {1}. Raw (200c): {2}',
		['boom', CANARY],
		'boom'
	],
	[
		WINDOWS,
		'modules/shortcuts/win.ahk',
		"Opening the selected {1} '{2}'…",
		['url', CANARY],
		'selected url'
	],
	[
		WINDOWS,
		'modules/shortcuts/win.ahk',
		"Handed the selected {1} '{2}' to the shell.",
		['path', CANARY],
		'to the shell.'
	],
	[
		WINDOWS,
		'modules/shortcuts/win.ahk',
		"Registry navigation to '{1}' did not launch Regedit.",
		[CANARY],
		'did not launch'
	],
	[
		WINDOWS,
		'modules/keystats/keystats_hotstring_log.ahk',
		"KL_LogHotstring: trigger='{1}' cat='{2}' sec='{3}' init={4}",
		[CANARY, 'c', 's', '1'],
		"cat='c'"
	],
	[
		WINDOWS,
		'infra/hotstrings/hotstring_inputhook.ahk',
		"Fire-log drain failed for trigger '{1}': {2}.",
		[CANARY, 'boom'],
		': boom.'
	],
	[
		LINUX,
		'modules/hotstrings/injector.lua',
		"Cannot deliver '%s' — not typable on this layout and no clipboard route.",
		[CANARY],
		'not typable'
	],
	[
		LINUX,
		'modules/hotstrings/injector.lua',
		"Cannot deliver '%s' before erasing its trigger: %s.",
		[CANARY, 'boom'],
		'before erasing'
	],
	[
		LINUX,
		'modules/hotstrings/injector.lua',
		"inject(): bc=%d text='%s'…",
		['3', `${CANARY}'…\n${CANARY} second line`],
		'inject(): bc=3 '
	],
	[
		LINUX,
		'modules/shortcuts/wrap_on_type.lua',
		"PRIMARY unchanged since the selection window opened — typing '%s'.",
		[CANARY],
		'selection window opened'
	]
];

/** Fills a template's {n}, %s or %d placeholders with values. */
function render(template, values) {
	let next = 0;
	return template.replace(/\{(\d+)\}|%[sd]/g, (_, index) =>
		index ? values[Number(index) - 1] : values[next++]
	);
}

/** The first interpreter that really runs: Windows has a python3 Store stub. */
function findPython() {
	for (const name of ['python3', 'python']) {
		const probe = spawnSync(name, ['--version'], { encoding: 'utf8' });
		if (probe.status === 0) return name;
	}
	return null;
}

const python = findPython();
if (!python) {
	reportNotExecuted('field log scrubber', 'no Python interpreter runs on this host');
	process.exit(0);
}

/** Scrubs a log's text through the real script; returns the copy's bytes. */
function runScrub(text) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-scrub-'));
	try {
		const source = path.join(dir, 'source.log');
		const target = path.join(dir, 'target.log');
		fs.writeFileSync(source, text);
		const run = spawnSync(python, [SCRUB, source, target, BUNDLED], { encoding: 'utf8' });
		assert.equal(run.status, 0, run.stderr);
		return fs.readFileSync(target, 'utf8');
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

for (const [driver, file, template, values, kept] of CASES) {
	check(`no typed text survives: ${template}`, () => {
		const source = fs.readFileSync(path.join(driver, file), 'utf8');
		assert(source.includes(template), `${file} no longer spells: ${template}`);
		const line = `${STAMP} [DEBUG] [Tag] ${render(template, values)}`;
		const copy = runScrub(`${line}\n`);
		assert(!copy.includes(CANARY), copy);
		assert(copy.startsWith(`${STAMP} [DEBUG] [Tag] `), 'the record keeps its prefix');
		if (kept) assert(copy.includes(kept), `the scrubbed line keeps "${kept}": ${copy}`);
	});
}

check('the continuation of a withheld multi-line body goes with it', () => {
	const copy = runScrub(
		`${STAMP} [INFO] [LLM.ollama] Prediction received (40 chars): «${CANARY} first\n` +
			`${CANARY} second\n\n${CANARY} third».\n` +
			`${STAMP} [INFO] [Next] the next record stays\n` +
			'===== 2026-10-30 10:00:00:000 session opened =====\n'
	);
	assert(!copy.includes(CANARY), copy);
	assert(copy.includes('[Next] the next record stays'), copy);
	assert(copy.includes('session opened'), copy);
});

check('a multi-line stack of an ordinary record is kept', () => {
	const copy = runScrub(`${STAMP} [ERROR] [Tag] boom\nstack line 1\n`);
	assert(copy.includes('stack line 1'), copy);
});

check('the macOS spellings stay scrubbed', () => {
	const copy = runScrub(
		`${STAMP} [DEBUG] [expander] Auto-expand: '${CANARY}' → '${CANARY}'.\n` +
			`${STAMP} [DEBUG] [llm] [ollama] #1 STREAM_PROMPT (9 chars) -> ${CANARY}\n` +
			`${STAMP} [DEBUG] [llm] [mlx] #1 STREAM chunk (9 bytes): '${CANARY}'\n`
	);
	assert(!copy.includes(CANARY), copy);
	assert(copy.includes('<personal trigger> → <personal>.'), copy);
});

check('a bundled trigger is public and stays named', () => {
	const toml = fs.readFileSync(path.join(BUNDLED, 'french/autocorrection.toml'), 'utf8');
	const match = /^"?([a-zé]{3,})"? = \{ *output/m.exec(toml);
	assert(match, 'a bundled trigger is needed for this check');
	const copy = runScrub(
		`${STAMP} [DEBUG] [WPMWidget] KL_LogHotstring: trigger='${match[1]}' cat='c' sec='s' init=1\n`
	);
	assert(copy.includes(`trigger='${match[1]}'`), copy);
});

check('a log with CRLF and a BOM is scrubbed and stored as LF', () => {
	const copy = runScrub(
		`﻿${STAMP} [DEBUG] [PrefixWatcher] DBG calling TooltipShow: 1 item(s), first='${CANARY}'.\r\n` +
			`${STAMP} [INFO] [Tag] kept\r\n`
	);
	assert(!copy.includes(CANARY), copy);
	assert(!copy.includes('\r'), 'a report is stored with LF');
	assert(!copy.startsWith('﻿'), 'the BOM does not travel');
});

check('the collectors copy logs through the scrubber only', () => {
	const windows = fs.readFileSync(
		path.join(ROOT, 'tools/dev/collect-windows-field-report.ps1'),
		'utf8'
	);
	assert.doesNotMatch(windows, /Copy-Item -LiteralPath \$Source/, 'a raw copy of a log');
	assert.match(windows, /Copy-ScrubbedLog \$Source/);
	assert.match(windows, /\$DayLog = Join-Path \$script:Out /, 'the digests read the scrubbed copy');
	assert.match(windows, /hotstring-collisions\.py/);
	assert.match(
		windows,
		/\$Rerun \+= @\('-ConfigDir', \$ConfigDir\)/,
		'the updated collector keeps the folder'
	);
	const linux = fs.readFileSync(path.join(ROOT, 'tools/dev/collect-linux-field-report.sh'), 'utf8');
	assert.doesNotMatch(linux, /\bcp "\$\{f\}"/, 'a raw copy of a log');
	assert.match(linux, /scrub_log "\$\{f\}"/);
	assert.match(linux, /day_logs\+=\("\$\{out\}\//, 'the digests read the scrubbed copy');
	assert.match(linux, /hotstring-collisions\.py/);
});

console.log(`[OK] field log scrubber (${checks} checks).`);
