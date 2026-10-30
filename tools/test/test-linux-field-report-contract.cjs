// tools/test/test-linux-field-report-contract.cjs

/**
 * ==============================================================================
 * MODULE: Linux Field Report Collector Tests
 * DESCRIPTION:
 * Runs the real tools/dev/collect-linux-field-report.sh in fixture clones with
 * a file:// origin, a stand-in luajit that names a fixture logs folder, and
 * shims for the session commands. Pins the contract it shares with the macOS
 * collector:
 * 1. the field report names come from the shared identifiers, and the logs
 *    folder from the driver's own resolver;
 * 2. from dev the report goes to field/linux-<today>-dev, the base is
 *    recorded in git config and in base.txt, only the report folder is
 *    committed (logs included with -f), and the branch is pushed;
 * 3. on that field branch a later run reads the recorded base, brings the
 *    base's new commit from origin and reuses the branch;
 * 4. a base that is not on origin is not updated and still reports;
 * 5. Ctrl-C still commits the evidence, marked interrupted;
 * 6. tracked changes are refused before anything is switched.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/collect-linux-field-report.sh';
const FIELD_GIT = 'tools/dev/field-report-git.sh';
const MAC_SCRIPT = 'tools/dev/collect-macos-field-report.sh';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.sh';
const IDENTIFIERS_JSON = 'static/ergopti_plus/_shared/data/identifiers.json';
const APP_DIRS = 'static/ergopti_plus/_shared/lua/app_dirs.lua';
const LOG_SCRUB = 'tools/dev/field-log-scrub.py';
const COLLISIONS = 'tools/dev/hotstring-collisions.py';
const BUNDLED_SAMPLE = 'static/ergopti_plus/_shared/modules/hotstrings/french/autocorrection.toml';

if (process.platform === 'win32') {
	console.log('[SKIP] The Linux field report collector is a Linux shell tool; not run on Windows.');
	process.exit(0);
}

const names = JSON.parse(fs.readFileSync(path.join(ROOT, IDENTIFIERS_JSON), 'utf8')).field_report;
const collector = fs.readFileSync(path.join(ROOT, SCRIPT), 'utf8');
const helper = fs.readFileSync(path.join(ROOT, FIELD_GIT), 'utf8');
const appDirs = fs.readFileSync(path.join(ROOT, APP_DIRS), 'utf8');
const appDir = (key) => appDirs.match(new RegExp(`\\b${key} = "([^"]+)"`))[1];
const LOG_FILES = {
	main: appDir('unified_prefix'),
	errors: appDir('errors_prefix'),
	extension: appDir('extension'),
	bootstrap: appDir('bootstrap_log'),
	crashes: appDir('crash_reports_dir')
};
let checks = 0;

/** Runs one named check. */
async function check(name, body) {
	await body();
	checks++;
	console.log(`PASS ${name}`);
}

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-linux-field-')));

const GIT_IDENTITY = {
	GIT_AUTHOR_NAME: 'Fixture',
	GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
	GIT_COMMITTER_NAME: 'Fixture',
	GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
	GIT_CONFIG_GLOBAL: '/dev/null',
	GIT_CONFIG_NOSYSTEM: '1'
};

/** Runs git in a folder and fails on error. */
function git(cwd, ...args) {
	const result = spawnSync('git', args, {
		cwd,
		encoding: 'utf8',
		env: { ...process.env, ...GIT_IDENTITY }
	});
	assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
	return result.stdout.trim();
}

/** Writes one executable shim. */
function shim(bin, name, body) {
	fs.writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

/** Today in the collector's date format. */
function today() {
	const now = new Date();
	return [
		now.getFullYear(),
		String(now.getMonth() + 1).padStart(2, '0'),
		String(now.getDate()).padStart(2, '0')
	].join('-');
}

/**
 * Builds a fixture clone whose origin holds dev, checked out on `start`.
 * @param {string} name Fixture folder name.
 * @param {{start?: string, hang?: boolean}} [options] Starting branch (pushed
 *   to origin unless it is local-only), and whether a step hangs.
 */
function fixture(name, { start = 'dev', localOnly = false, hang = false } = {}) {
	const base = path.join(scratch, name);
	const clone = path.join(base, 'clone');
	const origin = path.join(base, 'origin.git');
	const bin = path.join(base, 'bin');
	const home = path.join(base, 'home');
	const logs = path.join(home, 'state/ergopti_plus/logs');
	for (const relative of [SCRIPT, FIELD_GIT, IDENTIFIERS, LOG_SCRUB, COLLISIONS, BUNDLED_SAMPLE]) {
		fs.mkdirSync(path.dirname(path.join(clone, relative)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), path.join(clone, relative));
	}
	fs.mkdirSync(path.join(clone, 'static/ergopti_plus/linux/bin'), { recursive: true });
	fs.writeFileSync(path.join(clone, 'static/ergopti_plus/linux/bin/.keep'), '');
	// The logs are ignored in the real clone too: the collector adds them with -f
	fs.writeFileSync(path.join(clone, '.gitignore'), '*.log\n');
	fs.mkdirSync(bin, { recursive: true });
	fs.mkdirSync(logs, { recursive: true });
	const day = today();
	fs.writeFileSync(
		path.join(logs, `${LOG_FILES.main}${day}${LOG_FILES.extension}`),
		'2026-10-28 10:00:00 [INFO] [BootProfile] Boot complete in 812 ms (cpu 300 ms).\n' +
			'2026-10-28 10:01:00 [INFO] [network_check] check=network verdict=pass steps=1 pac=pass\n' +
			'2026-10-28 10:01:10 [INFO] [composer_check] check=composer verdict=fail steps=2 build=fail\n' +
			'2026-10-28 10:01:20 [INFO] [field_check] check=layout_probe verdict=skip steps=0\n' +
			'2026-10-28 10:01:30 [INFO] [field_check] check=typing_probe verdict=needs_typing steps=1\n' +
			'2026-10-28 10:01:40 [INFO] [field_check] check=odd_probe verdict=partial steps=1\n' +
			'2026-10-28 10:02:00 [WARNING] [Fixture] a warning\n' +
			"2026-10-28 10:03:00 [ERROR] [injector] Cannot deliver 'TYPEDCANARY' before erasing its trigger: boom.\n" +
			"2026-10-28 10:04:00 [TRACE] [injector] inject(): bc=3 text='TYPEDCANARY'…\n"
	);
	fs.writeFileSync(path.join(logs, `${LOG_FILES.main}2000-01-01${LOG_FILES.extension}`), 'old\n');
	fs.writeFileSync(path.join(logs, LOG_FILES.bootstrap), 'refused session_lock\n');
	const env = { ...process.env, ...GIT_IDENTITY, HOME: home, USER: 'fixtureuser' };
	git(clone, 'init', '-q', '-b', 'dev');
	git(clone, 'add', '-A');
	git(clone, 'commit', '-q', '-m', 'fixture');
	spawnSync('git', ['init', '-q', '--bare', origin], { encoding: 'utf8', env });
	git(clone, 'remote', 'add', 'origin', `file://${origin}`);
	git(clone, 'push', '-q', 'origin', 'dev');
	if (start !== 'dev') {
		git(clone, 'switch', '-q', '-c', start);
		if (!localOnly) git(clone, 'push', '-q', 'origin', start);
	}
	shim(bin, 'uname', 'echo Linux');
	// The driver's resolver: the folder, then the app_dirs.lua file names.
	shim(
		bin,
		'luajit',
		`case "$*" in *get_logs_dir*) printf '%s\\n' "${logs}" "${LOG_FILES.main}" "${LOG_FILES.errors}" "${LOG_FILES.extension}" "${LOG_FILES.bootstrap}" "${LOG_FILES.crashes}" "${home}/personal_hotstrings.toml" ;; *) echo "LuaJIT fixture" ;; esac`
	);
	// A fact that names the home folder and the user: both must be masked.
	shim(bin, 'localectl', `echo "VC Keymap: fr in ${home}/keymaps for fixtureuser"`);
	const marker = path.join(base, 'hanging');
	shim(bin, 'ss', hang ? `: > "${marker}"\nsleep 30` : 'echo "LISTEN 127.0.0.1:11434 ollama"');
	for (const name of ['systemctl', 'pgrep', 'gsettings', 'setxkbmap', 'zenity'])
		shim(bin, name, `echo "${name} fixture"`);
	return { base, clone, origin, bin, home, env, logs, marker };
}

/**
 * Runs the real collector inside a fixture.
 * @param {object} paths Fixture paths.
 * @param {{push?: boolean, onStart?: (child: object) => void}} [options]
 */
function runCollector(paths, { push = false, onStart } = {}) {
	return new Promise((resolve) => {
		const args = [path.join(paths.clone, SCRIPT)];
		if (!push) args.push('--no-push');
		const child = spawn(bashExecutable(), args, {
			cwd: paths.clone,
			env: { ...paths.env, PATH: `${paths.bin}${path.delimiter}${process.env.PATH}` },
			detached: Boolean(onStart)
		});
		if (onStart) onStart(child);
		let stdout = '';
		let stderr = '';
		child.stdout.on('data', (chunk) => (stdout += chunk));
		child.stderr.on('data', (chunk) => (stderr += chunk));
		const timer = setTimeout(() => child.kill('SIGKILL'), 60000);
		child.on('close', (status) => {
			clearTimeout(timer);
			resolve({ status, stdout, stderr });
		});
	});
}

/** The report folders a fixture holds, oldest first. */
function reportFolders(paths) {
	const reports = path.join(paths.clone, names.folder);
	return fs.existsSync(reports)
		? fs
				.readdirSync(reports)
				.sort()
				.map((folder) => path.join(reports, folder))
		: [];
}

/** Reads one report file. */
function read(folder, name) {
	return fs.readFileSync(path.join(folder, name), 'utf8');
}

(async () => {
	try {
		await check('the field report names come from the shared identifiers', () => {
			assert.deepEqual(Object.keys(names).sort(), ['base_config_key', 'branch_prefix', 'folder']);
			const identifiers = fs.readFileSync(path.join(ROOT, IDENTIFIERS), 'utf8');
			assert.match(identifiers, /^ERGOPTI_FIELD_REPORT_BRANCH_PREFIX="field\/"$/m);
			for (const [file, text] of [
				[SCRIPT, collector],
				[FIELD_GIT, helper],
				[MAC_SCRIPT, fs.readFileSync(path.join(ROOT, MAC_SCRIPT), 'utf8')]
			]) {
				const code = text
					.split('\n')
					.filter((line) => !/^\s*#/.test(line))
					.join('\n');
				for (const value of Object.values(names))
					assert(!code.includes(value), `${file} spells ${value} instead of the shared name`);
			}
			for (const text of [collector, fs.readFileSync(path.join(ROOT, MAC_SCRIPT), 'utf8')]) {
				assert.match(
					text,
					/^\. "\$REPO_ROOT\/static\/ergopti_plus\/_shared\/data\/identifiers\.sh"$/m
				);
				assert.match(text, /^\. "\$REPO_ROOT\/tools\/dev\/field-report-git\.sh"$/m);
			}
			for (const key of ['BRANCH_PREFIX', 'FOLDER', 'BASE_CONFIG_KEY'])
				assert.match(helper, new RegExp(`\\$\\{ERGOPTI_FIELD_REPORT_${key}\\}`));
		});

		await check("the logs folder and file names are the driver's own", () => {
			assert.match(collector, /require\("infra\.config_paths"\)\.get_logs_dir\(\)/);
			assert.match(collector, /require\("app_dirs"\)/);
			assert.doesNotMatch(
				collector.replace(/^\s*#.*$/gm, ''),
				new RegExp(`${LOG_FILES.main}|\\.local/state|${LOG_FILES.bootstrap.replace('.', '\\.')}`),
				'no second copy of a log name or folder formula'
			);
		});

		await check('the header says what the collector does not cover and why', () => {
			assert.match(collector, /^# NOT COVERED, AND WHY:$/m);
			assert.match(collector, /No field run\. The Linux daemon has no request protocol/);
			assert.match(collector, /No diagnostics export\./);
		});

		await check(
			'started on dev, the report goes to field/linux-<today>-dev, names its base and is pushed',
			async () => {
				const paths = fixture('from-dev');
				const devBefore = git(paths.clone, 'rev-parse', 'dev');
				const result = await runCollector(paths, { push: true });
				assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
				const expected = `${names.branch_prefix}linux-${today()}-dev`;
				assert.equal(git(paths.clone, 'branch', '--show-current'), expected);
				assert.equal(git(paths.clone, 'rev-parse', 'dev'), devBefore, 'dev must not move');
				assert.equal(
					git(paths.clone, 'config', '--get', `branch.${expected}.${names.base_config_key}`),
					'dev'
				);
				const folders = reportFolders(paths);
				assert.equal(folders.length, 1);
				const folder = folders[0];
				assert.match(path.basename(folder), /^linux-\d{4}-\d{2}-\d{2}_\d{6}$/);
				const head = git(paths.clone, 'rev-parse', '--short', 'HEAD~1');
				assert.equal(
					read(folder, 'base.txt'),
					`field_branch: ${expected}\nbase: dev\ncommit: ${head}\n`
				);
				const steps = read(folder, 'steps.txt');
				for (const name of [
					'versions',
					'session',
					'toolchain',
					'input_access',
					'units',
					'listeners'
				])
					assert.match(steps, new RegExp(`^${name}\\s+exit=\\d+$`, 'm'));
				const dayLog = `${LOG_FILES.main}${today()}${LOG_FILES.extension}`;
				assert.match(
					steps,
					new RegExp(`^${dayLog.replace(/\./g, '\\.')}\\s+copied \\(scrubbed\\)$`, 'm')
				);
				assert.match(steps, /^hotstring_collisions\s+exit=0$/m);
				assert.doesNotMatch(
					read(folder, dayLog),
					/TYPEDCANARY/,
					'the pushed day log keeps no typed text'
				);
				assert.match(read(folder, dayLog), /Cannot deliver <text withheld> before erasing/);
				assert.match(read(folder, dayLog), /inject\(\): bc=3 text=<text withheld>$/m);
				assert(fs.existsSync(path.join(folder, LOG_FILES.bootstrap)));
				assert(
					!fs.existsSync(path.join(folder, `${LOG_FILES.main}2000-01-01${LOG_FILES.extension}`))
				);
				assert.match(read(folder, 'digest_field_checks.txt'), /check=network verdict=pass/);
				// The macOS marks, the verdict word kept after each, and one summary.
				const marked = read(folder, 'field_checks.txt');
				for (const line of [
					'✅ field check network: pass',
					'❌ field check composer: fail',
					'⏭️ field check layout_probe: skip',
					'⌨️ field check typing_probe: needs_typing',
					'⚠️ field check odd_probe: partial'
				]) {
					assert.ok(marked.includes(`  ${line}\n`), `field_checks.txt names ${line}`);
					assert.ok(
						result.stdout.includes(`[field-report]   ${line}`),
						`the terminal shows ${line}`
					);
				}
				const summary =
					'Field check summary: ✅ 1 pass, ❌ 1 fail, ⏭️ 1 skip, ⌨️ 1 needs_typing, ⚠️ 1 other.';
				assert.ok(marked.endsWith(`${summary}\n`), 'field_checks.txt ends with the summary');
				assert.ok(
					result.stdout.includes(`[field-report] ${summary}`),
					'the terminal shows the summary'
				);
				assert.match(read(folder, 'digest_boot.txt'), /Boot complete in 812 ms/);
				assert.match(read(folder, 'digest_errors.txt'), /\[WARNING\] \[Fixture\]/);
				const layout = read(folder, 'keyboard_layout.txt');
				assert.match(layout, /VC Keymap: fr in ~\/keymaps for <user>/);
				assert(!layout.includes(paths.home), 'the home folder is masked');
				const committed = git(paths.clone, 'show', '--name-only', '--format=', 'HEAD').split('\n');
				assert(
					committed.every((file) => file.startsWith(`${names.folder}/`)),
					committed.join(', ')
				);
				assert(
					committed.some((file) => file.endsWith(`/${dayLog}`)),
					'the ignored log is committed'
				);
				assert.match(
					git(paths.clone, 'log', '-1', '--format=%s'),
					/^docs\(field\): Linux field report .* on dev$/
				);
				assert.equal(
					git(paths.origin, 'rev-parse', expected),
					git(paths.clone, 'rev-parse', 'HEAD'),
					'the field branch is pushed'
				);
				assert.equal(git(paths.clone, 'status', '--porcelain', '--untracked-files=no'), '');
			}
		);

		await check(
			'on its field branch a later run keeps the recorded base and brings its new commit from origin',
			async () => {
				const paths = fixture('recorded-base', { start: 'feature/x' });
				const first = await runCollector(paths);
				assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
				const expected = `${names.branch_prefix}linux-${today()}-feature-x`;
				assert.equal(git(paths.clone, 'branch', '--show-current'), expected);
				// Someone pushes to the base meanwhile.
				const other = path.join(paths.base, 'other');
				git(paths.base, 'clone', '-q', '--branch', 'feature/x', `file://${paths.origin}`, other);
				fs.writeFileSync(path.join(other, 'later.txt'), 'later\n');
				// The new commit also changes the collector: the run must use it.
				const script = path.join(other, SCRIPT);
				const source = fs.readFileSync(script, 'utf8');
				const anchor = '\nfield_report_open_folder linux\n';
				assert(source.includes(anchor), 'the collector opens its folder after the update');
				fs.writeFileSync(
					script,
					source.replace(anchor, `${anchor}log "fixture: updated collector"\n`)
				);
				git(other, 'add', 'later.txt', SCRIPT);
				git(other, 'commit', '-q', '-m', 'later');
				git(other, 'push', '-q', 'origin', 'feature/x');
				// A report folder is named to the second: a run in the same one is refused.
				await new Promise((resolve) => setTimeout(resolve, 1100));
				const second = await runCollector(paths);
				assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
				assert.equal(
					git(paths.clone, 'branch', '--show-current'),
					expected,
					'the branch is reused'
				);
				assert(
					fs.existsSync(path.join(paths.clone, 'later.txt')),
					"the base's new commit is merged"
				);
				assert.match(second.stdout, /updated: running the updated collector/);
				assert.match(second.stdout, /fixture: updated collector/, 'the updated collector ran');
				const folders = reportFolders(paths);
				assert.equal(folders.length, 2);
				assert.match(
					read(folders[1], 'base.txt'),
					new RegExp(`^field_branch: ${expected}\nbase: feature/x\n`)
				);
			}
		);

		await check('a base that is not on origin is not updated and still reports', async () => {
			const paths = fixture('local-base', { start: 'local/only', localOnly: true });
			const result = await runCollector(paths);
			assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
			assert.match(result.stdout, /local\/only is not a branch on origin/);
			const folders = reportFolders(paths);
			assert.equal(folders.length, 1);
			assert.match(read(folders[0], 'base.txt'), /\nbase: local\/only\n/);
		});

		await check('Ctrl-C during a step still commits the evidence, marked interrupted', async () => {
			const paths = fixture('interrupted', { hang: true });
			const result = await runCollector(paths, {
				onStart: (child) => {
					const poll = setInterval(() => {
						if (!fs.existsSync(paths.marker)) return;
						clearInterval(poll);
						// The terminal sends Ctrl-C to the whole foreground group
						process.kill(-child.pid, 'SIGINT');
					}, 100);
					child.on('close', () => clearInterval(poll));
				}
			});
			assert.equal(result.status, 130, `${result.stdout}\n${result.stderr}`);
			const folders = reportFolders(paths);
			assert.equal(folders.length, 1);
			assert.match(read(folders[0], 'steps.txt'), /^collector\s+interrupted$/m);
			assert(fs.existsSync(path.join(folders[0], 'base.txt')));
			assert.match(git(paths.clone, 'log', '-1', '--format=%s'), /\(interrupted\)$/);
			const committed = git(paths.clone, 'show', '--name-only', '--format=', 'HEAD');
			assert.match(committed, new RegExp(`${LOG_FILES.main}\\d{4}-\\d{2}-\\d{2}\\.log`));
			assert.equal(git(paths.clone, 'status', '--porcelain', '--untracked-files=no'), '');
		});

		await check('tracked changes are refused before any branch is switched', async () => {
			const paths = fixture('dirty');
			fs.appendFileSync(path.join(paths.clone, '.gitignore'), '# edit\n');
			const result = await runCollector(paths);
			assert.equal(result.status, 1);
			assert.match(result.stderr, /Commit or discard the tracked changes first/);
			assert.equal(git(paths.clone, 'branch', '--show-current'), 'dev');
			assert.deepEqual(reportFolders(paths), []);
		});
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
	console.log(`[OK] Linux field report collector (${checks} checks).`);
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
