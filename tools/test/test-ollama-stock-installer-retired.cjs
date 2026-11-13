// tools/test/test-ollama-stock-installer-retired.cjs

/**
 * ============================================================================
 * MODULE: Stock Ollama Installer Retired - Behavioral Guard
 * DESCRIPTION:
 * The owned-runtimes rows "Ollama" (PIN) and "Ollama installers (legacy)"
 * (DELETE): the macOS driver runs only Ergopti's own pinned runtime. The stock
 * official release was still downloadable through ensure-ollama-deps.sh when a
 * check carried install_for_selection()'s grant, ollama_binary.lua still listed
 * Ollama.app, Homebrew, PATH and the former on-demand copy, and the shared
 * ollama_install.sh still held curl | sh, brew and ollama serve.
 *
 * The verifier is executed in a hermetic HOME with a recording curl double on
 * PATH: it verifies a resolved executable, refuses an empty one with EX_USAGE,
 * and never reaches the network or writes a file. The sources are held to the
 * retirement: no download entry, no stock candidate, no legacy installer.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const LLM_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'modules', 'llm');
const VERIFIER = path.join(LLM_ROOT, 'ensure-ollama-deps.sh');

const results = [];

/** Records one TAP case. */
function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

/** Lists every file under a folder, relative to it. */
function listFiles(root) {
	const found = [];
	for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
		const full = path.join(root, entry.name);
		if (entry.isDirectory())
			found.push(...listFiles(full).map((rel) => path.join(entry.name, rel)));
		else found.push(entry.name);
	}
	return found;
}

/** Runs the verifier in a fresh HOME whose PATH starts with a recording curl. */
function runVerifier(resolved) {
	const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-retired-'));
	const bin = path.join(home, 'bin');
	fs.mkdirSync(bin);
	const record = path.join(home, 'network-attempts');
	for (const tool of ['curl', 'brew']) {
		const double = path.join(bin, tool);
		fs.writeFileSync(double, `#!/bin/sh\nprintf '%s\\n' "${tool} $*" >> '${record}'\nexit 0\n`, {
			mode: 0o755
		});
	}
	const before = listFiles(home).sort();
	const run = spawnSync(bashExecutable(), [VERIFIER, resolved, ''], {
		encoding: 'utf8',
		env: { HOME: home, PATH: `${bin}:/usr/bin:/bin` },
		timeout: 10000
	});
	const after = listFiles(home).sort();
	fs.rmSync(home, { recursive: true, force: true });
	return {
		run,
		networked: fs.existsSync(record) || after.includes('network-attempts'),
		before,
		after
	};
}

const executable = path.join(os.tmpdir(), `ergopti-ollama-retired-${process.pid}`);
fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
const plain = `${executable}.plain`;
fs.writeFileSync(plain, '', { mode: 0o644 });

try {
	const empty = runVerifier('');
	test('an empty resolution is refused with EX_USAGE', empty.run.status === 64, empty.run.stderr);
	test(
		'an empty resolution reaches no network and writes nothing',
		!empty.networked && JSON.stringify(empty.before) === JSON.stringify(empty.after),
		JSON.stringify(empty.after)
	);
	const resolved = runVerifier(executable);
	test('a resolved executable is verified', resolved.run.status === 0, resolved.run.stderr);
	test('verifying reaches no network', !resolved.networked);
	const stale = runVerifier(plain);
	test(
		'a resolved path that lost its execute bit is refused',
		stale.run.status === 1,
		stale.run.stderr
	);
} finally {
	fs.rmSync(executable, { force: true });
	fs.rmSync(plain, { force: true });
}

const verifier = fs.readFileSync(VERIFIER, 'utf8');
const code = (text, comment) =>
	text
		.split('\n')
		.filter((line) => !line.trimStart().startsWith(comment))
		.join('\n');
test(
	'the verifier holds no download, brew or serve',
	!/\b(curl|brew|tar|shasum)\b|ollama serve|releases\/download/.test(code(verifier, '#')),
	'ensure-ollama-deps.sh'
);
test(
	'the shared stock installer is gone',
	!fs.existsSync(path.join(ROOT, 'static/ergopti_plus/_shared/ai/data/install/ollama_install.sh'))
);
const checker = code(fs.readFileSync(path.join(LLM_ROOT, 'ollama_deps_checker.lua'), 'utf8'), '--');
test(
	'the checker has no stock download entry or grant',
	!/\binstall_for_selection|_install_granted|\bmanaged_install_dir/.test(
		checker.replace(/native_managed_install_dir/g, '')
	)
);
const resolver = code(fs.readFileSync(path.join(LLM_ROOT, 'ollama_binary.lua'), 'utf8'), '--');
test(
	'the resolver names no stock candidate',
	!/Ollama\.app|homebrew|HOMEBREW|os\.getenv\("PATH"\)|candidates|find_user_installation|managed_install_dir\(/.test(
		resolver.replace(/native_managed_install_dir/g, '')
	)
);

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
const failed = results.filter((result) => !result.ok).length;
console.log(`# passed: ${results.length - failed}/${results.length}`);
if (failed > 0) process.exit(1);
