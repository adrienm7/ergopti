// tools/test/test-update-schedule-contract.cjs

/**
 * ==============================================================================
 * MODULE: Automatic Update-Check Schedule Contract Test
 * DESCRIPTION:
 * When an automatic update check is due is decided once, by
 * _shared/modules/updater/schedule.js over the timing of
 * _shared/modules/updater/defaults.json, and replayed by a Lua port (macOS and
 * Linux) and an AHK port (Windows).
 *
 * ROOT CAUSE ENCODED:
 * No driver persisted when it last checked. Windows and Linux fired a check
 * min(30 s, interval) after every boot and counted the interval from process
 * start, so a machine powered off every evening checked at every boot even on a
 * weekly setting and never on a daily one if it ran less than a day; Linux's
 * monotonic timers also stopped during suspend. The presets were copied by hand
 * into each driver (1m ... 7d), and the defaults.json comment said they "stay
 * driver-specific".
 *
 * FEATURES & RATIONALE:
 * 1. schedule.js replays schedule_vectors.json: fresh install, catch-up after a
 *    power-off, mid-interval, a clock moved back, never, failure backoff,
 *    bounded deterministic jitter, the snap of a retired interval, the state
 *    record and the bounded timer delay.
 * 2. Jitter stays within its span for every preset and is deterministic.
 * 3. The timing data is validated: a malformed preset list is refused.
 * 4. Every preset has a translated label in all 21 locales, and no locale keeps
 *    a label for a preset that no longer exists.
 * 5. The generated Windows data equals a fresh render of defaults.json.
 * 6. The Lua and AHK ports and their vector tests exist and are wired into
 *    their suites, so the three interpreters stay pinned to one table.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const UPDATER = path.join(SP, '_shared', 'modules', 'updater');
const DEFAULTS_PATH = path.join(UPDATER, 'defaults.json');
const VECTORS_PATH = path.join(UPDATER, 'schedule_vectors.json');
const SCHEDULE_PATH = path.join(UPDATER, 'schedule.js');
const LOCALES_DIR = path.join(SP, '_shared', 'data', 'locales');
const GENERATOR_PATH = path.join(ROOT, 'tools', 'codegen', 'codegen-update-schedule.cjs');
const LOCALE_COUNT = 21;
const MIN_VECTORS = { due: 15, jitter: 8, snap: 10, sanitize: 6, record: 4, delay: 4 };

// Each port and the suite entry that runs its vector test.
const PORTS = [
	{
		port: '_shared/lua/updater/schedule.lua',
		test: 'macos/tests/unit/modules/updater/test_update_schedule_vectors.lua',
		wiring: null
	},
	{
		port: '_shared/lua/updater/schedule.lua',
		test: 'linux/tests/unit/meta/test_update_schedule_vectors.lua',
		wiring: {
			file: 'linux/tests/test_manifest.lua',
			needle: '"tests.unit.meta.test_update_schedule_vectors"'
		}
	},
	{
		port: 'windows/modules/updater/schedule.ahk',
		test: 'windows/tests/unit/test_updater_schedule_vectors.ahk',
		wiring: {
			file: 'windows/tests/run_all.ahk',
			needle: '#Include unit/test_updater_schedule_vectors.ahk'
		}
	}
];

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

function readJson(file) {
	return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/** Compares two plain records key by key, independent of key order. */
function sameRecord(a, b) {
	const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
	for (const key of keys) {
		if (JSON.stringify(a[key]) !== JSON.stringify(b[key])) return false;
	}
	return true;
}

// ==========================================
// ==========================================
// ======= 1/ Vectors ======================
// ==========================================
// ==========================================

function checkVectors(schedule, timing, vectors) {
	for (const [group, minimum] of Object.entries(MIN_VECTORS)) {
		expect(
			Array.isArray(vectors[group]) && vectors[group].length >= minimum,
			`schedule_vectors.json must hold at least ${minimum} "${group}" vectors`
		);
	}
	for (const v of vectors.due || []) {
		const got = schedule.nextDue({
			now: v.now,
			startedAt: v.started_at,
			interval: v.interval,
			state: v.state,
			timing
		});
		const want = { reason: v.expect.reason, dueAt: 'due_at' in v.expect ? v.expect.due_at : null };
		expect(
			got.reason === want.reason && got.dueAt === want.dueAt,
			`due ${v.id}: got ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`
		);
	}
	for (const v of vectors.jitter || []) {
		const got = schedule.jitterSeconds(v.seed, v.anchor, v.interval, timing);
		expect(got === v.expect, `jitter ${v.id}: got ${got}, expected ${v.expect}`);
	}
	for (const v of vectors.snap || []) {
		const got = schedule.snapInterval(v.seconds, timing);
		expect(
			got.seconds === v.expect && got.code === v.code && got.snapped === v.snapped,
			`snap ${v.id}: got ${JSON.stringify(got)}, expected ${v.expect}/${v.code}/${v.snapped}`
		);
	}
	for (const v of vectors.sanitize || []) {
		const got = schedule.sanitizeState(v.raw);
		expect(
			sameRecord(got.state, v.expect) && JSON.stringify(got.dropped) === JSON.stringify(v.dropped),
			`sanitize ${v.id}: got ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)} dropping ${JSON.stringify(v.dropped)}`
		);
	}
	for (const v of vectors.record || []) {
		const before = JSON.stringify(v.state);
		const got = schedule.recordCheck(v.state, v.now, v.ok);
		expect(
			sameRecord(got, v.expect),
			`record ${v.id}: got ${JSON.stringify(got)}, expected ${JSON.stringify(v.expect)}`
		);
		expect(
			JSON.stringify(v.state) === before,
			`record ${v.id}: recordCheck must not mutate the state it is given`
		);
	}
	for (const v of vectors.delay || []) {
		const got = schedule.delayUntil(v.due_at, v.now, timing);
		expect(got === v.expect, `delay ${v.id}: got ${got}, expected ${v.expect}`);
	}
}

/** Jitter is bounded by its span for every preset and deterministic. */
function checkJitterBounds(schedule, timing) {
	let samples = 0;
	for (const preset of timing.check_interval_presets) {
		if (preset.seconds === 0) continue;
		const span = Math.min(
			Math.floor((preset.seconds * timing.jitter_percent) / 100),
			timing.jitter_max_sec
		);
		for (let anchor = 1700000000; anchor < 1700000000 + 400; anchor += 1) {
			const value = schedule.jitterSeconds('7f3a9c21e5b04d68', anchor, preset.seconds, timing);
			samples += 1;
			if (!(Number.isInteger(value) && value >= 0 && value <= span)) {
				expect(false, `jitter for ${preset.code} at ${anchor} is ${value}, outside [0, ${span}]`);
				return;
			}
			if (value !== schedule.jitterSeconds('7f3a9c21e5b04d68', anchor, preset.seconds, timing)) {
				expect(false, `jitter for ${preset.code} at ${anchor} is not deterministic`);
				return;
			}
		}
	}
	expect(samples >= 3000, `the jitter bound check must sample every preset, sampled ${samples}`);
}

// ==========================================
// ==========================================
// ======= 2/ Timing Validation ============
// ==========================================
// ==========================================

function checkTimingValidation(schedule, timing) {
	expect(schedule.validateTiming(timing) === true, 'the timing of defaults.json must validate');
	const clone = () => JSON.parse(JSON.stringify(timing));
	const cases = [
		[
			'no presets',
			(t) => {
				t.check_interval_presets = [];
			}
		],
		[
			'no never preset',
			(t) => {
				t.check_interval_presets = t.check_interval_presets.filter((p) => p.seconds !== 0);
			}
		],
		[
			'a duplicate code',
			(t) => {
				t.check_interval_presets[1].code = t.check_interval_presets[0].code;
			}
		],
		[
			'presets out of order',
			(t) => {
				t.check_interval_presets.reverse();
			}
		],
		[
			'a fractional preset',
			(t) => {
				t.check_interval_presets[0].seconds = 1.5;
			}
		],
		[
			'a default outside the presets',
			(t) => {
				t.default_check_interval_sec = 7200;
			}
		],
		[
			'a negative boot delay',
			(t) => {
				t.boot_check_delay_sec = -1;
			}
		],
		[
			'a jitter above 100 percent',
			(t) => {
				t.jitter_percent = 150;
			}
		],
		[
			'an empty backoff',
			(t) => {
				t.failure_backoff_sec = [];
			}
		],
		[
			'a zero re-evaluation period',
			(t) => {
				t.reevaluate_sec = 0;
			}
		]
	];
	for (const [name, mutate] of cases) {
		const candidate = clone();
		mutate(candidate);
		let refused = false;
		try {
			schedule.validateTiming(candidate);
		} catch (error) {
			refused = true;
		}
		expect(refused, `timing with ${name} must be refused`);
	}
}

// ==========================================
// ==========================================
// ======= 3/ Locales ======================
// ==========================================
// ==========================================

function checkLocales(timing) {
	const files = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
	expect(
		files.length === LOCALE_COUNT,
		`expected ${LOCALE_COUNT} locale files, found ${files.length}`
	);
	const wanted = new Set(
		timing.check_interval_presets.map((p) => `menu.about.frequency.${p.code}`)
	);
	const english = readJson(path.join(LOCALES_DIR, 'en.json'));
	for (const file of files) {
		const strings = readJson(path.join(LOCALES_DIR, file));
		for (const key of wanted) {
			expect(
				typeof strings[key] === 'string' && strings[key].trim() !== '',
				`${file} must translate ${key}`
			);
			if (file !== 'en.json' && typeof strings[key] === 'string') {
				expect(
					strings[key] !== english[key],
					`${file} must translate ${key} rather than repeat the English label`
				);
			}
		}
		const stale = Object.keys(strings).filter(
			(k) => k.startsWith('menu.about.frequency.') && !wanted.has(k)
		);
		expect(
			stale.length === 0,
			`${file} still labels retired frequency presets: ${stale.join(', ')}`
		);
	}
}

// ==========================================
// ==========================================
// ======= 4/ Ports & Generated Data =======
// ==========================================
// ==========================================

function checkGeneratedData(defaults) {
	expect(fs.existsSync(GENERATOR_PATH), 'tools/codegen/codegen-update-schedule.cjs must exist');
	if (!fs.existsSync(GENERATOR_PATH)) return;
	// eslint-disable-next-line global-require
	const generator = require(GENERATOR_PATH);
	expect(
		typeof generator.renderOutputs === 'function',
		'the generator must export renderOutputs(defaults)'
	);
	if (typeof generator.renderOutputs !== 'function') return;
	const outputs = generator.renderOutputs(defaults);
	expect(outputs.length >= 1, 'the generator must render the Windows schedule data');
	for (const output of outputs) {
		const committed = fs.existsSync(output.path) ? fs.readFileSync(output.path, 'utf8') : null;
		expect(
			committed === output.content,
			`${path.relative(ROOT, output.path)} is stale; run npm run codegen:update-schedule`
		);
	}
}

function checkPorts() {
	for (const entry of PORTS) {
		expect(fs.existsSync(path.join(SP, entry.port)), `${entry.port} must exist`);
		const testPath = path.join(SP, entry.test);
		expect(fs.existsSync(testPath), `${entry.test} must exist`);
		if (fs.existsSync(testPath)) {
			const source = fs.readFileSync(testPath, 'utf8');
			expect(
				source.includes('schedule_vectors.json'),
				`${entry.test} must replay schedule_vectors.json`
			);
		}
		if (entry.wiring) {
			const wiring = fs.readFileSync(path.join(SP, entry.wiring.file), 'utf8');
			expect(wiring.includes(entry.wiring.needle), `${entry.wiring.file} must run ${entry.test}`);
		}
	}
}

// ==========================================
// ==========================================
// ======= 5/ Main =========================
// ==========================================
// ==========================================

(async () => {
	const defaults = readJson(DEFAULTS_PATH);
	const vectors = readJson(VECTORS_PATH);
	const timing = defaults.timing;
	expect(
		defaults.check_state &&
			typeof defaults.check_state.storage_key === 'string' &&
			defaults.check_state.storage_key !== '',
		'defaults.json must name check_state.storage_key'
	);
	let schedule = null;
	try {
		schedule = await import(pathToFileURL(SCHEDULE_PATH).href);
	} catch (error) {
		expect(false, `_shared/modules/updater/schedule.js must load: ${error.message}`);
	}
	if (schedule) {
		checkVectors(schedule, timing, vectors);
		checkJitterBounds(schedule, timing);
		checkTimingValidation(schedule, timing);
	}
	checkLocales(timing);
	checkGeneratedData(defaults);
	checkPorts();

	if (failures.length > 0) {
		console.error(
			`\x1b[31m[ERROR] Update-check schedule contract: ${failures.length} of ${checks} checks failed:\x1b[0m`
		);
		for (const failure of failures) console.error('  - ' + failure);
		process.exit(1);
	}
	console.log(`\x1b[32m[OK] Update-check schedule contract: ${checks} checks passed.\x1b[0m`);
})();
