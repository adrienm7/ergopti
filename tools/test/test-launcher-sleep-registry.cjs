// tools/test/test-launcher-sleep-registry.cjs

/**
 * ==============================================================================
 * MODULE: Launcher Sleep Registry Gate
 * DESCRIPTION:
 * Every sleep of the Swift launcher, its fixtures and its tests takes its
 * duration from LauncherTimings.generated.swift, the [launcher] section of the
 * timing registry, and every generated duration is used.
 *
 * WHY THIS EXISTS:
 * The launcher spelled about seventy usleep and Thread.sleep durations as
 * literals, some through a named constant, so a retuned poll interval had no
 * single place to change and two copies of one interval (the launcher log and
 * logger datagram lock retries) could drift apart.
 *
 * RULES:
 * 1. A usleep, sleep, Thread.sleep or Task.sleep argument holds no duration
 *    literal (0 and 1 are floors and counts, not durations), directly or through
 *    a `let` constant of the same file.
 * 2. Every LauncherTimings member is referenced by a launcher source or test.
 * 3. Files whose sleeps another change owns are held to
 *    launcher-sleep-literal-baseline.json, which may only go down
 *    (`--shrink` writes a lower count back).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LAUNCHER = 'static/ergopti_plus/macos/launcher';
const GENERATED = `${LAUNCHER}/Sources/ErgoptiPlus/LauncherTimings.generated.swift`;
const BASELINE = path.join(__dirname, 'launcher-sleep-literal-baseline.json');
const BASELINE_COMMENT =
	'Launcher Swift files whose sleeps still spell a duration literal (tools/test/test-launcher-sleep-registry.cjs). Counts may only go down; lower them with --shrink.';
const MIN_SWIFT_FILES = 100;

const SLEEP_CALL = /\b(?:usleep|sleep|Thread\.sleep|Task\.sleep)\(/g;
// A numeric literal of 2 or more (with Swift digit separators or a fraction).
const DURATION_LITERAL = /(?<![\w.])(?:[2-9]|[1-9][\d_]+|\d*\.\d+)(?![\w.])/;

/**
 * The text between the parenthesis opening at `open` and its match.
 * @param {string} text Source line.
 * @param {number} open Index of "(".
 * @returns {string} The argument text.
 */
function argumentOf(text, open) {
	let depth = 0;
	for (let i = open; i < text.length; i++) {
		if (text[i] === '(') depth++;
		else if (text[i] === ')' && --depth === 0) return text.slice(open + 1, i);
	}
	return text.slice(open + 1);
}

/**
 * Sleeps whose duration is a literal, directly or through one `let` of the file.
 * @param {string} text Swift source.
 * @returns {number[]} One-based line numbers.
 */
function literalSleeps(text) {
	const code = text.split('\n').map((line) => line.replace(/\/\/.*$/, ''));
	const constants = new Map();
	for (const line of code) {
		const m = line.match(/\blet\s+([A-Za-z_]\w*)\b[^=]*=\s*(.+)$/);
		if (m) constants.set(m[1], m[2]);
	}
	const hits = [];
	code.forEach((line, index) => {
		for (const m of line.matchAll(SLEEP_CALL)) {
			const argument = argumentOf(line, m.index + m[0].length - 1);
			const names = argument.match(/[A-Za-z_]\w*/g) ?? [];
			const literal =
				DURATION_LITERAL.test(argument) ||
				names.some((name) => constants.has(name) && DURATION_LITERAL.test(constants.get(name)));
			if (literal) hits.push(index + 1);
		}
	});
	return hits;
}

/** Every Swift file of the launcher, repository-relative. */
function swiftFiles() {
	const out = [];
	const walk = (rel) => {
		for (const entry of fs.readdirSync(path.join(ROOT, rel), { withFileTypes: true })) {
			const child = `${rel}/${entry.name}`;
			if (entry.isDirectory()) {
				if (entry.name !== '.build') walk(child);
			} else if (entry.name.endsWith('.swift')) out.push(child);
		}
	};
	walk(`${LAUNCHER}/Sources`);
	walk(`${LAUNCHER}/Tests`);
	return out.sort();
}

/** Proves the scan rejects what it exists to reject. */
function selfTest() {
	const failures = [];
	const expect = (name, text, count) => {
		const found = literalSleeps(text).length;
		if (found !== count) failures.push(`${name}: expected ${count}, found ${found}`);
	};
	expect('a literal usleep', 'usleep(10_000)', 1);
	expect('a literal Thread.sleep', 'Thread.sleep(forTimeInterval: 0.25)', 1);
	expect('a literal through a constant', 'private let k: useconds_t = 50_000\nusleep(k)', 1);
	expect('a literal array through a constant', 'let d: [useconds_t] = [5, 6]\nsleep(d[i])', 1);
	expect('a generated duration', 'usleep(LauncherTimings.testPoll.microseconds)', 0);
	expect('a floor of one', 'sleep(max(1, microseconds))', 0);
	expect('an injected sleep', 'sleep: { usleep($0) }', 0);
	expect('a literal in a comment', 'f() // usleep(10_000)', 0);
	return failures;
}

function main() {
	const errors = selfTest().map((f) => `self-test: ${f}`);
	const files = swiftFiles();
	if (files.length < MIN_SWIFT_FILES)
		errors.push(`walked only ${files.length} Swift file(s) under ${LAUNCHER}: the walk is broken`);

	const counts = {};
	const lines = {};
	for (const rel of files) {
		if (rel === GENERATED) continue;
		const hits = literalSleeps(fs.readFileSync(path.join(ROOT, rel), 'utf8'));
		if (hits.length > 0) {
			counts[rel] = hits.length;
			lines[rel] = hits;
		}
	}

	if (process.argv.includes('--shrink')) {
		const frozen = JSON.parse(fs.readFileSync(BASELINE, 'utf8')).files;
		const grown = Object.keys(counts).filter((rel) => counts[rel] > (frozen[rel] ?? 0));
		if (grown.length > 0) {
			console.error(`refusing to shrink: ${grown.join(', ')} grew. Read a LauncherTimings key.`);
			process.exit(1);
		}
		fs.writeFileSync(
			BASELINE,
			JSON.stringify({ _comment: BASELINE_COMMENT, files: counts }, null, '\t') + '\n'
		);
		console.log('launcher sleep baseline rewritten');
		return;
	}

	const frozen = JSON.parse(fs.readFileSync(BASELINE, 'utf8')).files;
	for (const [rel, count] of Object.entries(counts)) {
		if (count > (frozen[rel] ?? 0))
			errors.push(
				`${rel}:${lines[rel].join(',')}: a sleep spells its duration. Fix: declare a [launcher] ` +
					'key in _shared/modules/timings/constants.toml, run npm run codegen:registry-constants ' +
					'and sleep for LauncherTimings.<name>.<unit>.'
			);
	}
	for (const [rel, count] of Object.entries(frozen)) {
		if ((counts[rel] ?? 0) < count)
			errors.push(`${rel} is below its baseline count: run this gate with --shrink.`);
	}

	const generated = fs.readFileSync(path.join(ROOT, GENERATED), 'utf8');
	const members = [...generated.matchAll(/^\tstatic let (\w+) = RegistryDuration\(/gm)].map(
		(m) => m[1]
	);
	if (members.length === 0) errors.push(`${GENERATED} declares no LauncherTimings member`);
	const consumers = files
		.filter((rel) => rel !== GENERATED)
		.map((rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8'))
		.join('\n');
	for (const member of members)
		if (!new RegExp(`\\bLauncherTimings\\.${member}\\b`).test(consumers))
			errors.push(
				`LauncherTimings.${member} is read by no launcher source or test: remove its key`
			);

	if (errors.length > 0) {
		console.error('\x1b[31m[ERROR] Launcher sleep durations bypass the timing registry:\x1b[0m');
		for (const e of errors) console.error('    ' + e);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] Launcher sleeps — ${members.length} registry duration(s), ` +
			`${files.length} Swift file(s) scanned.\x1b[0m`
	);
}

main();
