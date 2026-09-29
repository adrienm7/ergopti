// tools/test/test-format-gate.cjs

/**
 * ==============================================================================
 * MODULE: Formatting Gate Guard
 * DESCRIPTION:
 * Pins how the repository keeps one format per language: Prettier for
 * JavaScript, Svelte, CSS, HTML, JSON, Markdown and YAML, Ruff for Python,
 * both through tools/lint/format.cjs.
 *
 * FEATURES & RATIONALE:
 * 1. Enforced twice: the pre-commit hook formats the staged files, and CI
 *    checks the whole tree with the Ruff release format.cjs pins, so a commit
 *    made without the hook still cannot land unformatted.
 * 2. Generated output stays out: every output tools/build/generators.cjs
 *    declares with a Prettier extension is ignored, or reformatting it would
 *    break the generator drift gate.
 * 3. Stable output: formatting the staged files of a scratch repository twice
 *    changes nothing the second time, and a partially staged file is refused.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');

const Format = require(path.join(ROOT, 'tools', 'lint', 'format.cjs'));
const { allOutputs } = require(path.join(ROOT, 'tools', 'build', 'generators.cjs'));

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

console.log('Formatting gate');

check('the pre-commit hook formats the staged files before the convention lint', () => {
	const hook = read('.husky/pre-commit');
	const format = hook.indexOf('node tools/lint/format.cjs --staged');
	assert.ok(format >= 0, 'the hook does not run format.cjs --staged');
	assert.ok(format < hook.indexOf('node tools/lint/lint-conventions.js'));
});

check('CI installs the pinned Ruff and checks the whole tree', () => {
	const workflow = read('.github/workflows/ci.yml');
	assert.ok(
		workflow.includes(
			'python3 -m pip install --disable-pip-version-check "ruff==$(node tools/lint/format.cjs --ruff-version)"'
		)
	);
	assert.ok(workflow.includes('node tools/lint/format.cjs --check'));
	assert.match(Format.RUFF_VERSION, /^\d+\.\d+\.\d+$/);
});

check('npm scripts go through format.cjs', () => {
	const scripts = JSON.parse(read('package.json')).scripts;
	assert.strictEqual(scripts.format, 'node ./tools/lint/format.cjs --write');
	assert.strictEqual(scripts['format:check'], 'node ./tools/lint/format.cjs --check');
});

check('Ruff is configured at the Prettier width', () => {
	const pyproject = read('pyproject.toml');
	const prettier = JSON.parse(read('.prettierrc'));
	assert.ok(pyproject.includes(`line-length = ${prettier.printWidth}`));
	assert.ok(pyproject.includes('**/_generated/**') && pyproject.includes('**/vendor/**'));
});

check('every generated output Prettier would format is ignored', () => {
	const ignore = read('.prettierignore')
		.split('\n')
		.map((line) => line.trim())
		.filter((line) => line && !line.startsWith('#'));
	assert.ok(ignore.includes('**/_generated/') && ignore.includes('**/vendor/'));
	for (const output of allOutputs()) {
		if (!Format.PRETTIER_EXTENSIONS.has(path.extname(output))) continue;
		const ignored = ignore.includes(output) || output.split('/').includes('_generated');
		assert.ok(ignored, `${output} is generated but not in .prettierignore`);
	}
});

check('--staged formats staged files once, re-stages them, and refuses partial staging', () => {
	const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-format-'));
	const git = (...args) => {
		const result = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
		assert.strictEqual(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
		return result.stdout;
	};
	try {
		git('init', '-q');
		git('config', 'user.email', 'test@example.invalid');
		git('config', 'user.name', 'test');
		for (const file of ['.prettierrc', '.prettierignore']) {
			fs.copyFileSync(path.join(ROOT, file), path.join(repo, file));
		}
		fs.symlinkSync(path.join(ROOT, 'node_modules'), path.join(repo, 'node_modules'), 'junction');
		fs.mkdirSync(path.join(repo, 'tools', 'lint'), { recursive: true });
		fs.copyFileSync(
			path.join(ROOT, 'tools', 'lint', 'format.cjs'),
			path.join(repo, 'tools', 'lint', 'format.cjs')
		);
		fs.writeFileSync(path.join(repo, 'a.js'), 'const  x = {a:1}\n');
		git('add', 'a.js');
		const run = () =>
			spawnSync(process.execPath, ['tools/lint/format.cjs', '--staged'], {
				cwd: repo,
				encoding: 'utf8'
			});
		const first = run();
		assert.strictEqual(first.status, 0, first.stderr);
		const formatted = git('show', ':a.js');
		assert.strictEqual(
			formatted,
			'const x = { a: 1 };\n',
			'the index must hold the formatted file'
		);
		assert.strictEqual(fs.readFileSync(path.join(repo, 'a.js'), 'utf8'), formatted);
		assert.strictEqual(run().status, 0);
		assert.strictEqual(git('show', ':a.js'), formatted, 'a second pass must change nothing');

		fs.writeFileSync(path.join(repo, 'a.js'), 'const x = { a: 2 };\n');
		const partial = run();
		assert.notStrictEqual(partial.status, 0, 'a partially staged file must be refused');
		assert.match(partial.stderr, /a\.js/);
	} finally {
		fs.rmSync(repo, { recursive: true, force: true });
	}
});

if (failures > 0) {
	console.error(`\n${failures} formatting gate check(s) failed.`);
	process.exit(1);
}
console.log('\nAll formatting gate checks passed.');
