// tools/test/test-native-menu-census-admission.cjs

/**
 * ==============================================================================
 * MODULE: Native Menu Census Migration Admission Tests
 * DESCRIPTION:
 * Exercises the real census child against compact source fixtures. Migrating
 * handwritten rows below twenty and ultimately to zero must preserve the frozen
 * historical detector proof and complete production-source traversal. Invalid
 * inputs and an increased debt ledger must fail before either mode can write.
 * Fixture source files are scanner controls, not driver runtime evidence.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = ['windows', 'macos', 'linux'];
const RETIRED = 'macos/ui/menu/menu_llm/live_mode_panel.lua';
const TOOL = 'tools/test/test-native-menu-rows.cjs';
const CORPUS = 'tools/test/fixtures/native-menu-census-legacy.json';
const BASELINE = 'tools/test/native-menu-rows-baseline.json';
const tool = fs.readFileSync(path.join(ROOT, TOOL), 'utf8');
const corpusBytes = fs.readFileSync(path.join(ROOT, CORPUS));
const legacy = JSON.parse(corpusBytes);
const registry = fs.readFileSync(path.join(ROOT, 'tools/test/run-js-suite.cjs'), 'utf8');
for (const name of ['test-native-menu-rows.cjs', 'test-native-menu-census-admission.cjs']) {
	assert.equal(
		registry.split(`args: ['tools/test/${name}']`).length - 1,
		1,
		`${name}: exactly one normal JS-suite registration`
	);
}

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-census-admission-'));
const sourceRoot = path.join(fixture, 'static', 'ergopti_plus');
const childPath = path.join(fixture, TOOL);
const baselinePath = path.join(fixture, BASELINE);
let checks = 0;

function write(rel, bytes) {
	const dest = path.join(fixture, rel);
	fs.mkdirSync(path.dirname(dest), { recursive: true });
	fs.writeFileSync(dest, bytes);
}

function reset() {
	fs.rmSync(sourceRoot, { recursive: true, force: true });
	for (const driver of DRIVERS) {
		for (const rel of legacy.drivers[driver].sourceFiles) {
			if (rel === RETIRED) continue;
			// Independent path coverage metadata supplies stand-ins only for the
			// traversal precondition; the real child still reads every actual file.
			write(`static/ergopti_plus/${rel}`, driver === 'windows' ? 'Anchor() {\n}\n' : 'return {}\n');
		}
	}
	write(TOOL, tool);
	write(CORPUS, corpusBytes);
	write(BASELINE, JSON.stringify(legacy.baseline, null, '\t') + '\n');
}

function rows(driver, count) {
	const known = legacy.drivers[driver].excerpts.flatMap((excerpt) =>
		excerpt.lines.map((entry) => ({ rel: excerpt.path, source: entry.source }))
	);
	for (let i = 0; i < count; i++) {
		const entry = known[i % known.length];
		fs.appendFileSync(path.join(sourceRoot, entry.rel), entry.source + '\n');
	}
}

function ledger(counts) {
	const baseline = structuredClone(legacy.baseline);
	for (const driver of DRIVERS) {
		baseline[driver].count = counts[driver];
		baseline[driver].sites = baseline[driver].sites.slice(0, counts[driver]);
	}
	write(BASELINE, JSON.stringify(baseline) + '\n');
}

function child(update = false) {
	return spawnSync(process.execPath, [childPath, ...(update ? ['--update-baseline'] : [])], {
		cwd: fixture,
		encoding: 'utf8',
		timeout: 15000
	});
}

function accepts(counts) {
	for (const driver of DRIVERS) rows(driver, counts[driver]);
	const before = fs.readFileSync(baselinePath);
	const normal = child();
	assert.equal(normal.status, 0, normal.stdout + normal.stderr);
	assert.deepEqual(fs.readFileSync(baselinePath), before, 'ordinary mode is read-only');
	for (const driver of DRIVERS) {
		assert.ok(
			normal.stdout.includes(`${driver} ${counts[driver]}/${legacy.baseline[driver].count}`),
			`${driver}: real child reports the intended migrated count`
		);
	}
	const update = child(true);
	assert.equal(update.status, 0, update.stdout + update.stderr);
	const recorded = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
	for (const driver of DRIVERS) {
		assert.equal(recorded[driver].count, counts[driver]);
		assert.equal(recorded[driver].sites.length, counts[driver]);
	}
	const repeat = child();
	assert.equal(repeat.status, 0, repeat.stdout + repeat.stderr);
	assert.deepEqual(
		fs.readFileSync(baselinePath),
		Buffer.from(JSON.stringify(recorded, null, '\t') + '\n'),
		'normal mode succeeds without modifying the newly lowered ledger'
	);
	checks += 3;
}

function refusesBoth(reason) {
	const before = fs.existsSync(baselinePath) ? fs.readFileSync(baselinePath) : null;
	for (const update of [false, true]) {
		const result = child(update);
		assert.equal(result.error, undefined, `${reason}: child must execute and terminate`);
		assert.equal(result.signal, null, `${reason}: failure must be an actual guard refusal`);
		assert.notEqual(result.status, 0, `${reason}: ${update ? 'update' : 'ordinary'} must refuse`);
		assert.match(result.stdout + result.stderr, reason);
		if (before === null)
			assert.equal(fs.existsSync(baselinePath), false, 'missing ledger stays missing');
		else
			assert.deepEqual(
				fs.readFileSync(baselinePath),
				before,
				'refusal precedes every ledger write'
			);
		checks++;
	}
}

try {
	for (const counts of [
		{ windows: 19, macos: 19, linux: 19 },
		{ windows: 26, macos: 19, linux: 25 },
		{ windows: 0, macos: 0, linux: 0 }
	]) {
		reset();
		accepts(counts);
	}

	for (const driver of DRIVERS) {
		const scanRoot = path.join(sourceRoot, driver, ...(driver === 'windows' ? [] : ['ui', 'menu']));
		reset();
		fs.renameSync(scanRoot, scanRoot + '-wrong');
		refusesBoth(/mandatory source root must exist/);

		reset();
		fs.rmSync(scanRoot, { recursive: true });
		fs.mkdirSync(scanRoot, { recursive: true });
		refusesBoth(/source coverage .* is incomplete/);

		reset();
		const mandatory = path.join(sourceRoot, legacy.drivers[driver].sourceFiles[0]);
		fs.rmSync(mandatory);
		refusesBoth(/source coverage .* is incomplete/);

		reset();
		fs.renameSync(
			mandatory,
			path.join(path.dirname(mandatory), 'replacement.' + (driver === 'windows' ? 'ahk' : 'lua'))
		);
		refusesBoth(/mandatory production source was not traversed/);

		for (const bytes of [
			'',
			driver === 'windows'
				? '; only comments\n/* block */\n'
				: '-- only comments\n--[=[ block ]=]\n'
		]) {
			reset();
			fs.writeFileSync(mandatory, bytes);
			refusesBoth(/production source must be nonempty/);
		}

		reset();
		// Restricting the old scanner to self-test paths still passes every
		// original small example; the independent legacy oracle must catch it.
		const historicalPath = legacy.drivers[driver].excerpts[0].path;
		const needle = 'if (comment.test(line)) return;';
		assert.equal(tool.split(needle).length - 1, 1, 'mutation targets exactly the scanner');
		write(
			TOOL,
			tool.replace(
				needle,
				`if (comment.test(line) || rel === ${JSON.stringify(historicalPath)}) return;`
			)
		);
		refusesBoth(/every recorded b06 legacy site must retain its original classification/);

		reset();
		rows(driver, legacy.baseline[driver].count + 1);
		refusesBoth(/native menu row site\(s\), baseline/);

		reset();
		ledger({ windows: 0, macos: 0, linux: 0 });
		rows(driver, 1);
		refusesBoth(/native menu row site\(s\), baseline 0/);

		reset();
		const raised = structuredClone(legacy.baseline);
		raised[driver].count++;
		raised[driver].sites.push(
			`${driver}/ui/menu/extra.${driver === 'windows' ? 'ahk' : 'lua'}:1 static`
		);
		write(BASELINE, JSON.stringify(raised));
		refusesBoth(/valid non-increasing count/);

		for (const mutate of [
			(recorded) => {
				recorded.count++;
			},
			(recorded) => {
				recorded.count = String(recorded.count);
			},
			(recorded) => {
				recorded.sites[0] = 'not a site';
			},
			(recorded) => {
				recorded.sites[1] = recorded.sites[0];
			}
		]) {
			reset();
			const bad = structuredClone(legacy.baseline);
			mutate(bad[driver]);
			write(BASELINE, JSON.stringify(bad));
			refusesBoth(/the baseline must/);
		}
	}

	reset();
	write(TOOL, tool.replace('/\\bRegisterMenuItem\\(/', '/NEVER_A_MENU_ROW/'));
	assert.notEqual(
		fs.readFileSync(childPath, 'utf8'),
		tool,
		'literal matcher mutation actually applied'
	);
	refusesBoth(/AssertionError/);

	reset();
	write(CORPUS, Buffer.concat([corpusBytes, Buffer.from(' ')]));
	refusesBoth(/independent b06 legacy oracle must remain unchanged/);

	reset();
	write('static/ergopti_plus/' + RETIRED, 'return {}\n');
	refusesBoth(/retired production source must remain absent/);
	reset();
	fs.rmSync(path.join(sourceRoot, 'macos/ui/menu/menu_llm/init.lua'));
	refusesBoth(/source coverage .* is incomplete/);

	reset();
	fs.rmSync(baselinePath);
	refusesBoth(/ENOENT/);

	reset();
	write(BASELINE, '{ malformed');
	refusesBoth(/SyntaxError/);

	reset();
	const missingDriver = structuredClone(legacy.baseline);
	delete missingDriver.macos;
	write(BASELINE, JSON.stringify(missingDriver));
	refusesBoth(/the baseline must record/);

	console.log(
		`Native menu census admission: ${checks} real-child controls passed; 19 and zero admit, damaged coverage/detection/ledger refuse before writes.`
	);
} finally {
	fs.rmSync(fixture, { recursive: true, force: true });
}
