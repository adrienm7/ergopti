// tools/test/test-log-export-contract.cjs

/**
 * ==============================================================================
 * MODULE: Log Export Contract
 * DESCRIPTION:
 * Holds the shared data behind « Export the logs (zip) » together: the
 * generated driver copies of _shared/core/logger/data/log_export.toml match it,
 * every scrub rule is exercised by a vector of
 * _shared/tests/corpus/logger/log_export_vectors.json, and the field report's
 * own scrubber (tools/dev/field-log-scrub.py) withholds every secret those
 * vectors list. The Lua and AutoHotkey suites replay the same vectors through
 * the runtime ports.
 *
 * ROOT CAUSE ENCODED:
 * The exported archive leaves the machine like a field report, but the drivers
 * cannot run the Python scrubber. A runtime rule set that drifted from it, or a
 * rule no vector exercises, would ship typed text without any test noticing.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const toml = require('smol-toml');
const { reportNotExecuted } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');
const SOURCE = path.join(SP, '_shared/core/logger/data/log_export.toml');
const VECTORS = path.join(SP, '_shared/tests/corpus/logger/log_export_vectors.json');
const SCRUB = path.join(ROOT, 'tools/dev/field-log-scrub.py');
const BUNDLED = path.join(SP, '_shared/hotstrings/data/catalogue');

const data = toml.parse(fs.readFileSync(SOURCE, 'utf8'));
const vectors = JSON.parse(fs.readFileSync(VECTORS, 'utf8'));

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`  ok   ${name}`);
}

check('the generated Lua and AutoHotkey data carry every declared rule', () => {
	const lua = fs.readFileSync(
		path.join(SP, '_shared/core/logger/engine/log_export_data.lua'),
		'utf8'
	);
	const ahk = fs.readFileSync(path.join(SP, 'windows/_generated/log_export_data.ahk'), 'utf8');
	assert(lua.includes(`days = ${data.archive.days},`), 'Lua days');
	assert(ahk.includes(`"days", ${data.archive.days},`), 'AHK days');
	for (const rule of data.scrub.rules) {
		const luaRow = `{ marker = ${JSON.stringify(rule.marker)}, cut = ${JSON.stringify(rule.cut)} }`;
		const ahkRow = `Map("marker", ${JSON.stringify(rule.marker)}, "cut", ${JSON.stringify(rule.cut)})`;
		assert(lua.includes(luaRow), `Lua is missing ${luaRow}; run npm run codegen:log-export`);
		assert(ahk.includes(ahkRow), `AHK is missing ${ahkRow}; run npm run codegen:log-export`);
	}
	assert.equal(lua.split('{ marker = ').length - 1, data.scrub.rules.length, 'Lua rule count');
	assert.equal(ahk.split('Map("marker", ').length - 1, data.scrub.rules.length, 'AHK rule count');
});

check('every scrub rule is exercised by a vector, and every vector lists what it hides', () => {
	assert(vectors.scrub.length >= 10, 'the corpus must hold its scrub vectors');
	const inputs = vectors.scrub.map((v) => v.input.join('\n')).join('\n');
	const unexercised = data.scrub.rules
		.map((r) => r.marker)
		.filter((marker) => !inputs.includes(marker));
	// A rule nobody exercises can stop matching without a red test anywhere.
	assert.deepEqual(unexercised, [], 'every scrub rule needs a vector');
	for (const vector of vectors.scrub) {
		for (const secret of vector.secrets) {
			assert(
				vector.input.join('\n').includes(secret),
				`${vector.name}: ${secret} is not in its input`
			);
			assert(!vector.expected.join('\n').includes(secret), `${vector.name}: ${secret} is expected`);
		}
	}
	assert(
		vectors.scrub.some((v) => v.secrets.length === 0),
		'a vector must prove that an ordinary record is kept'
	);
});

check('the selection vectors never select a retired topical file', () => {
	const appDirs = toml.parse(
		fs.readFileSync(path.join(SP, '_shared/core/fs/data/paths/app_dirs.toml'), 'utf8')
	);
	const retired = new Set(appDirs.logs.files.retired_topical_logs);
	const offered = vectors.selection.flatMap((v) => v.logs).filter((n) => retired.has(n));
	assert(offered.length >= 2, 'the vectors must offer retired topical files to the selection');
	for (const vector of vectors.selection) {
		for (const entry of vector.expected) assert(!retired.has(entry.name), vector.name);
	}
});

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
	reportNotExecuted('log export scrub cross-check', 'no Python interpreter runs on this host');
} else {
	check('the field report scrubber withholds every secret the vectors list', () => {
		const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-log-export-'));
		try {
			for (const vector of vectors.scrub) {
				const source = path.join(dir, 'source.log');
				const target = path.join(dir, 'target.log');
				fs.writeFileSync(source, vector.input.join('\n') + '\n');
				const run = spawnSync(python, ['-I', SCRUB, source, target, BUNDLED], {
					encoding: 'utf8'
				});
				assert.equal(run.status, 0, run.stderr);
				const copy = fs.readFileSync(target, 'utf8');
				for (const secret of vector.secrets) {
					assert(!copy.includes(secret), `${vector.name}: field-log-scrub.py keeps ${secret}`);
				}
			}
		} finally {
			fs.rmSync(dir, { recursive: true, force: true });
		}
	});
}

console.log(`[OK] log export contract: ${checks} check(s).`);
