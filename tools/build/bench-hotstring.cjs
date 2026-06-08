// scripts/bench-hotstring.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Scan Performance Benchmark
 * DESCRIPTION:
 * Node.js benchmark for the hotstring matching algorithm. Measures the latency
 * of the O(1) tail-char bucket lookup that drives the per-keystroke hot path,
 * using the same algorithmic complexity as the Lua registry implementation.
 *
 * FEATURES & RATIONALE:
 * 1. Baseline Management: Writes a baseline on first run; subsequent runs
 *    compare against it and fail when p95 regresses more than 20%.
 * 2. Absolute Gate: Always fails when p95 > 5 ms regardless of baseline.
 * 3. Fixture Registry: Builds a synthetic registry mirroring the real one so
 *    the benchmark runs without a Lua runtime in CI.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ===========================
// ===========================
// ======= 1/ Constants =======
// ===========================
// ===========================

// Absolute p95 latency ceiling in milliseconds
const P95_LIMIT_MS = 5;

// Maximum allowed p95 regression vs stored baseline (fractional, 0.20 = 20%)
const REGRESSION_THRESHOLD = 0.2;

// Number of scan iterations per benchmark run
const ITERATION_COUNT = 10_000;

// Number of synthetic triggers in the fixture registry
const FIXTURE_TRIGGER_COUNT = 3_300;

// Maximum trigger body length when generating fixtures
const MAX_TRIGGER_LEN = 8;

// Baseline file written on first run and compared on subsequent runs
const BASELINE_PATH = path.join(__dirname, 'bench-baseline.json');

// ===========================
// ===========================
// ======= 2/ Registry =======
// ===========================
// ===========================

/**
 * Returns the last UTF-8 character of a string using JS surrogate-pair awareness.
 * Mirrors the tail_codepoint() function in registry.lua.
 * @param {string} s - Input string.
 * @returns {string} Last code-point character, or "" for empty strings.
 */
function tailCodepoint(s) {
	if (!s) return '';
	// Use Array.from so multi-byte emoji / surrogate pairs count as one unit
	const codepoints = Array.from(s);
	return codepoints[codepoints.length - 1] ?? '';
}

/**
 * Builds a fixture registry that mirrors the real hotstring engine's data
 * structures. Each trigger is bucketed by its last UTF-8 codepoint, preserving
 * the O(1) lookup property of the Lua implementation.
 * @returns {{ byTail: Map<string, Array<{trigger: string, triggerBytes: number}>>, mappings: Array }} Registry object.
 */
function buildFixtureRegistry() {
	// Common French/English trigger bodies representative of the real TOML corpus
	const BODIES = [
		'qd',
		'dc',
		'pr',
		'av',
		'ap',
		'ds',
		'en',
		'et',
		'le',
		'la',
		'les',
		'des',
		'une',
		'un',
		'ces',
		'ses',
		'que',
		'qui',
		'pas',
		'mais',
		'donc',
		'car',
		'qqch',
		'qqn',
		'pdt',
		'pdv',
		'rdv',
		'stp',
		'svp',
		'bjr',
		'bsr',
		'mdr',
		'lol',
		'asap',
		'fyi',
		'tjs',
		'bcp',
		'tjrs',
		'ns',
		'vs',
		'cad',
		'ie',
		'eg',
		'nb'
	];
	// Alphabet used to generate additional unique trigger bodies
	const ALPHA = 'abcdefghijklmnopqrstuvwxyz';

	const mappings = [];
	const byTail = new Map();

	let seq = 0;

	const addEntry = (trigger) => {
		seq++;
		const tail = tailCodepoint(trigger);
		const entry = {
			trigger,
			triggerBytes: Buffer.byteLength(trigger, 'utf8'),
			tlen: Array.from(trigger).length,
			tail,
			seq,
			auto: false,
			isWord: false
		};
		mappings.push(entry);
		if (!byTail.has(tail)) byTail.set(tail, []);
		byTail.get(tail).push(entry);
	};

	// Add the representative body triggers first
	for (const body of BODIES) addEntry(body);

	// Fill remaining slots with generated triggers to reach FIXTURE_TRIGGER_COUNT
	outer: for (let len = 2; len <= MAX_TRIGGER_LEN; len++) {
		for (let i = 0; i < ALPHA.length ** 2; i++) {
			const a = ALPHA[Math.floor(i / ALPHA.length)];
			const b = ALPHA[i % ALPHA.length];
			const t = a.repeat(Math.max(1, len - 1)) + b;
			addEntry(t);
			if (mappings.length >= FIXTURE_TRIGGER_COUNT) break outer;
		}
	}

	// Sort each bucket longest-first, mirroring sort_mappings() in registry.lua
	for (const bucket of byTail.values()) {
		bucket.sort((a, b) => b.tlen - a.tlen || a.seq - b.seq);
	}

	return { byTail, mappings };
}

// ==========================================
// ==========================================
// ======= 3/ Hot-Path Scan Simulation =======
// ==========================================
// ==========================================

/**
 * Simulates a single keystroke scan: look up the tail-char bucket and iterate
 * through it checking trigger suffix match. Identical algorithmic complexity
 * to run_trigger_checks() → Registry.mappings_for_tail() in the Lua engine.
 * @param {{ byTail: Map<string, Array> }} registry - Fixture registry.
 * @param {string} buffer - Current typing buffer.
 * @param {string} keystroke - Character just typed.
 * @returns {boolean} True if a trigger matched.
 */
function simulateScan(registry, buffer, keystroke) {
	const tail = tailCodepoint(keystroke);
	const bucket = registry.byTail.get(tail);
	if (!bucket) return false;

	const fullBuf = buffer + keystroke;
	const bufLen = fullBuf.length;

	for (const m of bucket) {
		// Suffix match: the buffer must end with the trigger
		if (bufLen < m.triggerBytes) continue;
		if (fullBuf.endsWith(m.trigger)) return true;
	}
	return false;
}

// ==============================
// ==============================
// ======= 4/ Measurement =======
// ==============================
// ==============================

/**
 * Computes a percentile value from a sorted numeric array.
 * @param {number[]} sorted - Array sorted in ascending order.
 * @param {number} p - Percentile in [0, 100].
 * @returns {number} Interpolated percentile value.
 */
function percentile(sorted, p) {
	if (sorted.length === 0) return 0;
	const idx = (p / 100) * (sorted.length - 1);
	const lo = Math.floor(idx);
	const hi = Math.ceil(idx);
	if (lo === hi) return sorted[lo];
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

/**
 * Runs the benchmark and returns latency statistics in milliseconds.
 * @param {{ byTail: Map }} registry - Fixture registry.
 * @returns {{ p50: number, p95: number, p99: number, min: number, max: number, iterations: number }}
 */
function runBenchmark(registry) {
	// Pre-generate random inputs so generation cost is outside the hot loop
	const ALPHA = 'abcdefghijklmnopqrstuvwxyz,;.éàèùâêîôûç ';
	const buffers = [];
	const keystrokes = [];
	for (let i = 0; i < ITERATION_COUNT; i++) {
		// Buffer: 1–20 random chars
		const bufLen = 1 + Math.floor(Math.random() * 20);
		let buf = '';
		for (let j = 0; j < bufLen; j++) {
			buf += ALPHA[Math.floor(Math.random() * ALPHA.length)];
		}
		buffers.push(buf);
		keystrokes.push(ALPHA[Math.floor(Math.random() * ALPHA.length)]);
	}

	// Warm up the JIT — first 200 iterations are discarded
	for (let i = 0; i < 200; i++) {
		simulateScan(registry, buffers[i % buffers.length], keystrokes[i % keystrokes.length]);
	}

	// Measured iterations
	const latenciesNs = new Array(ITERATION_COUNT);
	for (let i = 0; i < ITERATION_COUNT; i++) {
		const t0 = process.hrtime.bigint();
		simulateScan(registry, buffers[i], keystrokes[i]);
		const t1 = process.hrtime.bigint();
		latenciesNs[i] = Number(t1 - t0);
	}

	latenciesNs.sort((a, b) => a - b);

	const toMs = (ns) => ns / 1_000_000;
	return {
		p50: toMs(percentile(latenciesNs, 50)),
		p95: toMs(percentile(latenciesNs, 95)),
		p99: toMs(percentile(latenciesNs, 99)),
		min: toMs(latenciesNs[0]),
		max: toMs(latenciesNs[latenciesNs.length - 1]),
		iterations: ITERATION_COUNT
	};
}

// ===============================
// ===============================
// ======= 5/ Baseline I/O =======
// ===============================
// ===============================

/**
 * Reads the stored baseline JSON from disk, or returns null when absent.
 * @returns {{ p50: number, p95: number, p99: number }|null}
 */
function readBaseline() {
	try {
		const raw = fs.readFileSync(BASELINE_PATH, 'utf8');
		return JSON.parse(raw);
	} catch {
		return null;
	}
}

/**
 * Writes benchmark results to the baseline file so future runs can compare.
 * @param {{ p50: number, p95: number, p99: number, min: number, max: number }} results
 */
function writeBaseline(results) {
	fs.writeFileSync(BASELINE_PATH, JSON.stringify(results, null, 2) + '\n', 'utf8');
}

// ==========================
// ==========================
// ======= 6/ Main Run =======
// ==========================
// ==========================

(function main() {
	console.log('=== Hotstring scan benchmark ===');
	console.log(`Building fixture registry (${FIXTURE_TRIGGER_COUNT} triggers)…`);

	const registry = buildFixtureRegistry();
	const bucketCount = registry.byTail.size;
	console.log(
		`Registry built: ${registry.mappings.length} mappings, ${bucketCount} tail-char buckets.`
	);

	console.log(`Running ${ITERATION_COUNT.toLocaleString()} iterations…`);
	const results = runBenchmark(registry);

	console.log('\nResults:');
	console.log(`  min  : ${results.min.toFixed(4)} ms`);
	console.log(`  p50  : ${results.p50.toFixed(4)} ms`);
	console.log(`  p95  : ${results.p95.toFixed(4)} ms`);
	console.log(`  p99  : ${results.p99.toFixed(4)} ms`);
	console.log(`  max  : ${results.max.toFixed(4)} ms`);

	// --- Absolute gate ---
	if (results.p95 > P95_LIMIT_MS) {
		console.error(
			`\nFAIL: p95 ${results.p95.toFixed(4)} ms exceeds absolute limit of ${P95_LIMIT_MS} ms.`
		);
		process.exit(1);
	}
	console.log(`\nAbsolute gate: p95 ${results.p95.toFixed(4)} ms ≤ ${P95_LIMIT_MS} ms  OK`);

	// --- Baseline comparison ---
	const baseline = readBaseline();
	if (!baseline) {
		console.log('\nNo baseline found — writing new baseline.');
		writeBaseline(results);
		console.log(`Baseline written to ${BASELINE_PATH}`);
		process.exit(0);
	}

	const regression = (results.p95 - baseline.p95) / baseline.p95;
	const pctLabel = (regression * 100).toFixed(1);

	if (regression > REGRESSION_THRESHOLD) {
		console.error(
			`\nFAIL: p95 regressed ${pctLabel}% vs baseline ` +
				`(${baseline.p95.toFixed(4)} ms → ${results.p95.toFixed(4)} ms). ` +
				`Threshold: ${(REGRESSION_THRESHOLD * 100).toFixed(0)}%.`
		);
		process.exit(1);
	}

	if (regression < 0) {
		console.log(
			`\nImprovement: p95 improved ${Math.abs(regression * 100).toFixed(1)}% vs baseline — updating baseline.`
		);
		writeBaseline(results);
	} else {
		console.log(
			`\nRegression check: p95 +${pctLabel}% vs baseline (limit: ${(REGRESSION_THRESHOLD * 100).toFixed(0)}%)  OK`
		);
	}

	console.log('\nAll checks passed.');
	process.exit(0);
})();
