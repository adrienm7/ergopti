// tools/test/test-shell-identifiers-sourcing.cjs

/**
 * ==============================================================================
 * MODULE: Shell Identifiers Are Sourced Fail-Fast
 * DESCRIPTION:
 * The build scripts, installers and bootstrap scripts read the application
 * names, bundle ids and hosts from _shared/core/text/data/identifiers.sh. This gate keeps
 * that dependency honest:
 * 1. every script sources the file in one of two recognised forms:
 *    - BUILD: from the checkout root ($REPO_ROOT or $PROJECT_ROOT), for the
 *      tools/ scripts that only run in a checkout;
 *    - RUNTIME: relative to the script's own location ($SCRIPT_DIR, the Linux
 *      installer's ${DRIVERS_ROOT} or the sourced file's BASH_SOURCE folder),
 *      directly or through IDENTIFIERS_FILE, for the scripts that run from the
 *      macOS bundle or a Linux package, which keep the _shared tree at its
 *      repository layout. The relative path must reach the real file;
 * 2. the sourcing stops on a missing file: after `set -e`, or, in a sourced
 *    fragment, through `|| return N`. No `|| true` or default turns a missing
 *    file into an empty value, and a script run without the file stops;
 * 3. a runtime script finds the file where it runs: the macOS payload ships it
 *    beside every staged script that sources it, and the Linux bundle requires
 *    it among the files build-linux-driver.sh checks;
 * 4. the AppImage build and smoke containers mount the whole checkout, so the
 *    file is there in the container (a container that mounted only part of the
 *    tree would stop at (2), never fall back to a literal).
 *
 * No Ergopti script runs standalone without the _shared tree (for instance
 * piped from curl): one that did would need its generator to inline the
 * values, with a drift check, instead of sourcing the file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const payload = require('../build/macos-bundle-payload.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const IDENTIFIERS_REL = 'static/ergopti_plus/_shared/core/text/data/identifiers.sh';
const DRIVERS_ROOT_REL = 'static/ergopti_plus';
const BUILD_LINE =
	/^\. "\$(?:REPO_ROOT|PROJECT_ROOT)\/static\/ergopti_plus\/_shared\/core\/text\/data\/identifiers\.sh"$/m;
const ANCHOR = String.raw`(\$\{?(?:SCRIPT_DIR|DRIVERS_ROOT)\}?|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\))`;
const RELATIVE = String.raw`((?:\/\.\.)*(?:\/_shared)?\/core\/text\/data\/identifiers\.sh)`;
const PROPAGATE = String.raw`( \|\| return [1-9][0-9]*)?`;
const RUNTIME_LINE = new RegExp(String.raw`^\. "${ANCHOR}${RELATIVE}"${PROPAGATE}$`, 'm');
const RUNTIME_ASSIGNMENT = new RegExp(String.raw`^IDENTIFIERS_FILE="${ANCHOR}${RELATIVE}"$`, 'm');
const RUNTIME_VARIABLE_LINE = new RegExp(String.raw`^\. "\$IDENTIFIERS_FILE"${PROPAGATE}$`, 'm');

/**
 * Recognises how one script sources identifiers.sh.
 * @param {string} file Repository-relative script path.
 * @param {string} text Script text.
 * @returns {{form: string, match: RegExpExecArray, assignment?: string, anchor?: string, resolved?: string}|null}
 */
function classify(file, text) {
	const build = BUILD_LINE.exec(text);
	if (build) return { form: 'build', match: build };
	let match = RUNTIME_LINE.exec(text);
	let anchor;
	let relative;
	let assignment;
	if (match) {
		[, anchor, relative] = match;
	} else {
		const assigned = RUNTIME_ASSIGNMENT.exec(text);
		match = RUNTIME_VARIABLE_LINE.exec(text);
		if (!assigned || !match || assigned.index > match.index) return null;
		[assignment, anchor, relative] = assigned;
	}
	const base = anchor.includes('DRIVERS_ROOT') ? DRIVERS_ROOT_REL : path.posix.dirname(file);
	const resolved = path.posix.normalize(base + relative);
	return { form: 'runtime', match, assignment, anchor, resolved };
}

// Self-test: the runtime form must reach the real file from the script's folder.
for (const [file, line, expected] of [
	[
		'static/ergopti_plus/macos/modules/llm/x.sh',
		'. "$SCRIPT_DIR/../../../_shared/core/text/data/identifiers.sh"',
		IDENTIFIERS_REL
	],
	[
		'static/ergopti_plus/macos/modules/llm/x.sh',
		'. "$SCRIPT_DIR/../../_shared/core/text/data/identifiers.sh"',
		'static/ergopti_plus/macos/_shared/core/text/data/identifiers.sh'
	],
	[
		'static/ergopti_plus/_shared/modules/llm/install/x.sh',
		'. "$SCRIPT_DIR/../../../core/text/data/identifiers.sh"',
		IDENTIFIERS_REL
	],
	[
		'static/ergopti_plus/linux/x.sh',
		'. "${DRIVERS_ROOT}/_shared/core/text/data/identifiers.sh"',
		IDENTIFIERS_REL
	]
]) {
	assert.equal(classify(file, `set -e\n${line}\n`).resolved, expected, `${file}: ${line}`);
}
assert.equal(classify('x.sh', '. "$HOME/_shared/core/text/data/identifiers.sh"\n'), null);
assert.equal(
	classify('x.sh', '. "$SCRIPT_DIR/../_shared/core/text/data/identifiers.sh" || true\n'),
	null,
	'a tolerated failure is not a recognised form'
);

const scripts = execFileSync('git', ['ls-files', '-z', '--', 'tools', 'static'], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 64 * 1024 * 1024
})
	.split('\0')
	.filter((file) => file.endsWith('.sh') && !file.endsWith('identifiers.sh'))
	// A comment may name the file it relies on (field-report-git.sh documents that
	// its caller sources it), and a quoted list entry (the files build-linux-driver.sh
	// requires) names it as data; only an executable line is a sourcing to check.
	.filter((file) =>
		fs
			.readFileSync(path.join(ROOT, file), 'utf8')
			.split('\n')
			.some(
				(line) =>
					!/^\s*#/.test(line) &&
					!/^\s*"[^"$]*"$/.test(line) &&
					line.includes('core/text/data/identifiers.sh')
			)
	);

assert.ok(scripts.length >= 4, `only ${scripts.length} script(s) source identifiers.sh`);

const manifest = payload.loadManifest(ROOT);
const macosPayload = new Set(
	payload
		.resolvePayload(manifest, payload.trackedFiles(ROOT, manifest))
		.files.map((file) => file.source)
);
const linuxBundle = fs.readFileSync(path.join(ROOT, 'tools/build/build-linux-driver.sh'), 'utf8');
const linuxRequired = /^REQUIRED_FILES=\(\n([\s\S]*?)^\)$/m.exec(linuxBundle);
assert.ok(linuxRequired, 'build-linux-driver.sh: REQUIRED_FILES list not found');
// build-linux-driver.sh copies the linux/ and _shared/ trees into every Linux package.
const LINUX_BUNDLED = /^static\/ergopti_plus\/(?:linux|_shared)\//;

const counts = { build: 0, runtime: 0 };
for (const file of scripts) {
	const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	const found = classify(file, text);
	assert.ok(found, `${file}: sources identifiers.sh in an unrecognised way`);
	counts[found.form]++;
	const { match } = found;
	const propagated = / \|\| return ([1-9][0-9]*)$/.exec(match[0]);
	if (!propagated)
		assert.match(
			text.slice(0, match.index),
			/^set -[a-z]*e[a-z]*\b/m,
			`${file}: must set -e before sourcing identifiers.sh, or propagate its failure`
		);
	assert.ok(
		!/identifiers\.sh"\s*(\|\|(?!\s*return [1-9])|2>)/.test(text) &&
			!/\$IDENTIFIERS_FILE"\s*(\|\|(?!\s*return [1-9])|2>)/.test(text),
		`${file}: the identifiers.sh source must not tolerate failure`
	);

	if (found.form === 'runtime') {
		assert.equal(found.resolved, IDENTIFIERS_REL, `${file}: the relative path misses the file`);
		if (macosPayload.has(file))
			assert.ok(
				macosPayload.has(IDENTIFIERS_REL),
				`${file}: the macOS bundle ships it without ${IDENTIFIERS_REL}`
			);
		if (LINUX_BUNDLED.test(file))
			assert.match(
				linuxRequired[1],
				/^\t"_shared\/core\/text\/data\/identifiers\.sh"$/m,
				`${file}: build-linux-driver.sh must require _shared/core/text/data/identifiers.sh`
			);
	}

	// Run the script's own source line under `set -e`, with the file absent and present,
	// from the script's own folder in a scratch copy of the repository layout.
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-identifiers-'));
	try {
		const folder = path.join(scratch, path.dirname(file));
		const prologue = [
			'set -euo pipefail',
			`REPO_ROOT='${scratch}'`,
			`PROJECT_ROOT='${scratch}'`,
			`SCRIPT_DIR='${folder}'`,
			`DRIVERS_ROOT='${path.join(scratch, DRIVERS_ROOT_REL)}'`,
			...(found.assignment ? [found.assignment] : []),
			// A function lets a sourced fragment's `|| return N` run as it does in its caller.
			'probe() {',
			match[0],
			'echo REACHED',
			'}',
			'probe',
			''
		].join('\n');
		fs.mkdirSync(folder, { recursive: true });
		const probe = path.join(folder, 'probe.sh');
		fs.writeFileSync(probe, prologue);
		// Control: with the file present the same prologue must run to the end.
		const present = path.join(scratch, path.dirname(IDENTIFIERS_REL));
		fs.mkdirSync(present, { recursive: true });
		fs.copyFileSync(path.join(ROOT, IDENTIFIERS_REL), path.join(scratch, IDENTIFIERS_REL));
		const run = () =>
			spawnSync(bashExecutable(), [probe], {
				cwd: scratch,
				env: { PATH: process.env.PATH },
				encoding: 'utf8'
			});
		const control = run();
		assert.ok(
			control.stdout.includes('REACHED'),
			`${file}: the source line does not work even with the file: ${control.stderr}`
		);
		fs.rmSync(path.join(scratch, IDENTIFIERS_REL));
		const result = run();
		assert.notEqual(result.status, 0, `${file}: continued after identifiers.sh was missing`);
		if (propagated)
			assert.equal(result.status, Number(propagated[1]), `${file}: returned another status`);
		assert.ok(!result.stdout.includes('REACHED'), `${file}: ran past the missing identifiers.sh`);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}
// Two runtime scripts remain since the stock Ollama installers (ensure-ollama-deps.sh's
// download, ollama_install.sh) were retired; fewer means the listing broke.
assert.ok(counts.runtime >= 2, `only ${counts.runtime} runtime script(s) source identifiers.sh`);

const appimage = fs.readFileSync(path.join(ROOT, 'tools/build/appimage-oldest-lts.sh'), 'utf8');
const mounts = [...appimage.matchAll(/-v "\$PROJECT_ROOT:\/src(:ro)?"/g)];
assert.equal(
	mounts.length,
	2,
	'the AppImage build and smoke containers must mount the whole checkout at /src'
);
assert.ok(/-w \/src/.test(appimage), 'the containers must run from the mounted checkout');

console.log(
	`[OK] ${scripts.length} script(s) source identifiers.sh fail-fast (${counts.build} from the checkout, ` +
		`${counts.runtime} beside their runtime location, shipped there); the AppImage containers mount the checkout.`
);
