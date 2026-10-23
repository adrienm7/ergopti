// tools/test/scan-log-leaks.cjs

/**
 * ==============================================================================
 * MODULE: Real Log Leak Scanner
 * DESCRIPTION:
 * Runs the page-side redactor (_shared/ui/redact.js) over the real daily logs of
 * this machine and counts, per leak class, what the raw logs hold and what is
 * still there after redaction. It prints counts only, never log content, so its
 * output can be pasted into an issue. A class that survives redaction is a rule
 * the shared redaction.json lacks: add a vector to redaction_vectors.json and
 * the rule to the three ports.
 *
 * USAGE:
 *   node tools/test/scan-log-leaks.cjs [logs-directory]
 * Without an argument it scans the log folder of the current platform. This is
 * a maintainer tool, not a CI gate: CI has no personal logs, and the gate that
 * pins each rule is test-diagnostics-redaction-vectors.cjs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');

/**
 * Loads the page-side redactor exactly as the diagnostics page does.
 * @returns {{apply: function(string, object, object): string}}
 */
function loadRedactor() {
	const file = path.join(SHARED, 'ui', 'redact.js');
	const sandbox = { window: {} };
	vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	if (!sandbox.window.ErgoptiRedact)
		throw new Error('redact.js did not define window.ErgoptiRedact');
	return sandbox.window.ErgoptiRedact;
}

/**
 * Resolves the default log folder of this platform.
 * @returns {string}
 */
function defaultLogDir() {
	if (process.platform === 'win32')
		return path.join(process.env.LOCALAPPDATA || '', 'ergopti_plus', 'logs');
	if (process.platform === 'darwin')
		return path.join(os.homedir(), 'Library', 'Logs', 'ergopti_plus');
	return path.join(os.homedir(), '.local', 'state', 'ergopti_plus', 'logs');
}

// The leak classes, as detectors over one line. The account and home classes
// are built from the running user, so they only mean something on the machine
// that wrote the logs.
const user = os.userInfo().username;
const home = os.homedir();
const folded = process.platform === 'win32';
const classes = {
	email: /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/,
	url_credential: /:\/\/[A-Za-z0-9._~%+:=!*-]+@/,
	token_prefix: /\b(sk-|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|hf_|AIza)[A-Za-z0-9_-]{16,}/,
	bearer: /bearer[ \t]+[A-Za-z0-9._~+/=-]{8,}/i,
	other_profile:
		/(\\Users\\|\/Users\/|\/home\/)(?!<user>|Public\b|Default\b|Shared\b)[A-Za-z0-9_.-]+/i,
	ip_address: /\b\d{1,3}(\.\d{1,3}){3}\b/,
	home_folder: new RegExp(home.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), folded ? 'i' : ''),
	account_name:
		user.length >= 3
			? new RegExp('\\b' + user.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', folded ? 'i' : '')
			: null
};

/**
 * Counts, per class, the lines of `lines` that match.
 * @param {string[]} lines
 * @returns {Object<string, number>}
 */
function count(lines) {
	const totals = {};
	for (const name of Object.keys(classes)) totals[name] = 0;
	for (const line of lines)
		for (const [name, pattern] of Object.entries(classes))
			if (pattern && pattern.test(line)) totals[name]++;
	return totals;
}

const dir = process.argv[2] || defaultLogDir();
if (!fs.existsSync(dir)) {
	console.error(`[FAIL] log folder not found: ${path.basename(dir)}`);
	process.exit(1);
}
const Redact = loadRedactor();
const rules = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'redaction.json'), 'utf8')
);
const context = { home, user, case_insensitive: folded };
const raw = [];
for (const name of fs.readdirSync(dir))
	if (name.endsWith('.log'))
		raw.push(...fs.readFileSync(path.join(dir, name), 'utf8').split(/\r?\n/));
const redacted = raw.map((line) => Redact.apply(line, rules, context));
const before = count(raw);
const after = count(redacted);
console.log(`lines scanned: ${raw.length}`);
for (const name of Object.keys(classes))
	console.log(`${name.padEnd(16)} raw ${String(before[name]).padStart(7)}  after ${after[name]}`);
const leaked = Object.entries(after).filter(([, n]) => n > 0);
if (leaked.length > 0) {
	console.error(
		`[FAIL] classes still present after redaction: ${leaked.map(([k]) => k).join(', ')}`
	);
	process.exit(1);
}
console.log('[OK] no scanned leak class survives redaction.');
