// tools/test/test-windows-field-report-contract.cjs

/**
 * ==============================================================================
 * MODULE: Windows Field Report Collector Tests
 * DESCRIPTION:
 * Pins tools/dev/collect-windows-field-report.ps1 to the contract of the macOS
 * and Linux collectors, in two layers:
 * 1. source: the field report names come from identifiers.json and the log
 *    names from app_dirs.toml, the branch is derived from the current one, the
 *    base is recorded and written to base.txt, the deepen loop, the commit of
 *    the report folder alone, the Ctrl-C closing block, ASCII for Windows
 *    PowerShell 5.1, a header that names what is not covered, the shared
 *    analyser run on the scrubbed copies, the collector's own checks in the
 *    verdict grammar, and proxy facts that never print an address;
 * 2. runtime: the real script runs in fixture clones with a file:// origin
 *    and a fixture LOCALAPPDATA, under Windows PowerShell 5.1 on Windows and
 *    pwsh elsewhere (a private copy without the unique platform guard; the
 *    Windows-only fact cmdlets then fail as recorded steps). From dev it
 *    reports on field/win-<today>-dev, names its base, commits the logs and
 *    pushes; on that branch a later run keeps the base and brings its new
 *    commit. A host without PowerShell reports the runtime layer as not
 *    executed; a CI host must have it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { reportNotExecuted } = require('./lib/host-capabilities.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/collect-windows-field-report.ps1';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.json';
const APP_DIRS = 'static/ergopti_plus/_shared/modules/paths/app_dirs.toml';
const LOG_SCRUB = 'tools/dev/field-log-scrub.py';
const COLLISIONS = 'tools/dev/hotstring-collisions.py';
// The analyser and the declarations it reads its budgets from.
const ANALYSER = 'tools/dev/field-log-analyse.py';
const BUNDLED_SAMPLE = 'static/ergopti_plus/_shared/modules/hotstrings/french/autocorrection.toml';
const GUARD =
	"if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Fail 'This collector runs on Windows only.' }\n";

const source = fs.readFileSync(path.join(ROOT, SCRIPT), 'utf8');
const code = source
	.split('\n')
	.filter((line) => !/^\s*#/.test(line))
	.join('\n');
const names = JSON.parse(fs.readFileSync(path.join(ROOT, IDENTIFIERS), 'utf8')).field_report;
const appDirs = fs.readFileSync(path.join(ROOT, APP_DIRS), 'utf8');
const tomlValue = (key) => appDirs.match(new RegExp(`^${key} = "([^"]+)"`, 'm'))[1];
const LOG = {
	main: tomlValue('unified_prefix'),
	extension: tomlValue('extension'),
	bootstrap: tomlValue('bootstrap_log'),
	folder: tomlValue('folder_name')
};
let checks = 0;

/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

check('the field report names come from identifiers.json, never a second literal', () => {
	assert.match(code, /'identifiers\.json'\)\) \| ConvertFrom-Json/);
	assert.match(code, /^\$Names = \$Identifiers\.field_report$/m);
	for (const value of Object.values(names))
		assert(!code.includes(value), `the collector spells ${value} instead of $Names`);
	assert.match(code, /\$Names\.branch_prefix/);
	assert.match(code, /\$Names\.folder/);
	assert.match(code, /\$\(\$Names\.base_config_key\)/);
});

check('the logs folder and names come from app_dirs.toml', () => {
	assert.match(code, /'app_dirs\.toml'\)\)$/m);
	for (const section of ['app', 'logs', 'logs.files', 'logs.windows'])
		assert.match(code, new RegExp(`Read-TomlSection '${section.replace('.', '\\.')}'`));
	for (const literal of [LOG.main, LOG.bootstrap, `\\${LOG.folder}\\logs`])
		assert(!code.includes(literal), `the collector spells ${literal} itself`);
	const resolver = code.match(/^function Resolve-LogsDir \{\n([\s\S]*?)^\}$/m);
	assert(resolver, 'no Resolve-LogsDir');
	assert.doesNotMatch(resolver[1], /LOCALAPPDATA/, 'the logs base is the declared one');
	assert.match(resolver[1], /GetEnvironmentVariable\(\$LogsBase\)/);
	for (const key of [
		'unified_prefix',
		'errors_prefix',
		'extension',
		'bootstrap_log',
		'base',
		'segments'
	])
		assert.match(code, new RegExp(`Get-AppDir \\$\\w+ '[\\w.]+' '${key}'`));
});

check('the field branch is derived from the current branch and the base is recorded', () => {
	assert.match(
		code,
		/\$Branch = \$Names\.branch_prefix \+ 'win-' \+ \(Get-Date -Format 'yyyy-MM-dd'\) \+ '-' \+ \(\$Base -replace '\/', '-'\)/
	);
	assert.match(code, /if \(\$Branch -and \$Branch\.StartsWith\(\$Names\.branch_prefix\)\)/);
	assert.match(code, /Get-Git config '--get' "branch\.\$Branch\.\$\(\$Names\.base_config_key\)"/);
	assert.match(code, /if \(\$script:GitStatus -ne 0 -or -not \$Base\) \{ \$Base = 'dev' \}/);
	assert.match(code, /Invoke-Git config "branch\.\$Branch\.\$\(\$Names\.base_config_key\)" \$Base/);
	assert.match(code, /Invoke-Git switch '-q' '-c' \$Branch/);
});

check('the base is brought from origin with the shallow-safe deepen loop', () => {
	assert.match(code, /Get-Git ls-remote '--exit-code' '--heads' origin \$Base/);
	assert.match(code, /Invoke-Git fetch '-q' '--depth' \$Depth origin \$Base/);
	assert.match(code, /Get-Git merge-base HEAD \$BaseHead/);
	assert.match(code, /\$Depth = \$Depth \* 4/);
	assert.match(code, /is not a branch on origin: \$Branch is not updated\./);
});

check('base.txt names the field branch, the base and the commit before any step', () => {
	const baseTxt = code.indexOf("'base.txt'");
	assert(baseTxt > 0, 'no base.txt');
	assert.match(
		code,
		/Write-Text \(Join-Path \$script:Out 'base\.txt'\) "field_branch: \$Branch`nbase: \$Base`ncommit: \$Commit`n"/
	);
	assert(baseTxt < code.indexOf("Invoke-Step 'versions'"), 'base.txt is written first');
});

check('only the report folder is committed, logs included, and pushed unless -NoPush', () => {
	assert.match(code, /Invoke-Git add '-f' \$OutRelative/);
	assert.match(code, /Invoke-Git commit '-q' '-m' \$Subject \$OutRelative/);
	assert.match(code, /Invoke-Git push '-u' origin HEAD/);
	assert.match(code, /param\(\s*\[switch\]\$NoPush,/);
});

check('Ctrl-C still commits what was collected, marked interrupted', () => {
	assert.match(
		code,
		/\} finally \{\n[\s\S]*\$script:Interrupted = \$true[\s\S]*Complete-Report\n\t\}\n\}/
	);
	assert.match(code, /if \(\$script:Interrupted\) \{ \$Subject = "\$Subject \(interrupted\)" \}/);
	assert.match(code, /-not \$script:Failing -and -not \$script:Finalized/);
});

check('the shared analyser reads the scrubbed copies, after every other step', () => {
	assert.match(
		code,
		/\(Join-Path \$DevTools 'field-log-analyse\.py'\), '--repo', \$RepoRoot, '--out', \$script:Out/
	);
	assert.match(code, /& \$script:Python @Analyser @DayLogs/);
	assert.match(code, /\$DayLog = Join-Path \$script:Out "\$MainPrefix\$Day\$Extension"/);
	assert(
		code.indexOf('@Analyser @DayLogs') > code.indexOf("Invoke-Step 'hotstring_collisions'"),
		'the analysis reads the verdicts of every step before it'
	);
	assert(code.indexOf('@Analyser @DayLogs') < code.indexOf("Invoke-Git add '-f' $OutRelative"));
});

check("the collector's own checks print one verdict line each", () => {
	const block = code.match(/Invoke-Step 'collector_checks' \{\n([\s\S]*?)\n\t\}\n/);
	assert(block, 'no collector_checks step');
	for (const id of ['autohotkey', 'driver_running', 'python', 'webview2']) {
		assert.match(block[1], new RegExp(`'check=${id} verdict=pass codes=[a-z0-9_]+'`));
		assert.match(block[1], new RegExp(`'check=${id} verdict=fail codes=[a-z0-9_]+'`));
	}
	for (const name of [
		'runtimes',
		'memory',
		'input_devices',
		'autostart',
		'privileges',
		'crash_dumps',
		'proxy_winhttp'
	])
		assert.match(code, new RegExp(`Invoke-Step '${name}' \\{`));
});

check('the proxy facts say set or unset, never an address', () => {
	const winhttp = code.match(/Invoke-Step 'proxy_winhttp' \{\n([\s\S]*?)\n\t\}\n/)[1];
	assert.match(winhttp, /'WinHTTP: direct' \} else \{ 'WinHTTP: set' \}/);
	assert.doesNotMatch(winhttp, /\$Text\s*$/m, 'the netsh output itself is never printed');
	const proxy = code.match(/Invoke-Step 'proxy' \{\n([\s\S]*?)\n\t\}\n/)[1];
	// Only the two switches print their value; the server and the PAC say "set".
	assert.equal(proxy.split('$Value.Value').length, 2);
	assert.match(
		proxy,
		/elseif \(\$Name -in 'ProxyEnable', 'AutoDetect'\) \{ "\$\{Name\}: \$\(\$Value\.Value\)" \}\n\t+else \{ "\$\{Name\}: set" \}/
	);
});

check('the header names what the collector does not cover', () => {
	assert.match(source, /^# NOT COVERED, AND WHY:$/m);
	for (const topic of [
		'No field run.',
		'No diagnostics export.',
		'Not the live checks.',
		'LogsDirPath'
	])
		assert(source.includes(topic), `the header does not cover: ${topic}`);
});

check('Windows PowerShell 5.1 reads it: ASCII, LF, and one platform guard', () => {
	assert(/^[\x09\x0a\x20-\x7e]*$/.test(source), 'non-ASCII byte or CR in the script');
	assert.equal(source.split(GUARD).length, 2, 'the platform guard must be unique and exact');
	assert.doesNotMatch(code, /\?\?|\?\.|&&|\|\|/, 'no PowerShell 7-only operator');
});

// An empty global configuration on every OS: a developer's signing or hook
// settings must not reach the fixture commits.
const emptyConfig = path.join(
	fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-git-config-')),
	'config'
);
fs.writeFileSync(emptyConfig, '');
const GIT_IDENTITY = {
	GIT_AUTHOR_NAME: 'Fixture',
	GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
	GIT_COMMITTER_NAME: 'Fixture',
	GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
	GIT_CONFIG_GLOBAL: emptyConfig,
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

/** A file:// URL git accepts for a local path, drive letter included. */
function fileUrl(folder) {
	const slashed = folder.split(path.sep).join('/');
	return process.platform === 'win32' ? `file:///${slashed}` : `file://${slashed}`;
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

const interpreter =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
		: 'pwsh';
const probe = spawnSync(
	interpreter,
	['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()'],
	{ encoding: 'utf8', timeout: 20000, windowsHide: true }
);
if (probe.error && probe.error.code === 'ENOENT' && process.env.GITHUB_ACTIONS !== 'true') {
	reportNotExecuted(
		'Windows field report collector runtime',
		`${interpreter} is not installed on this host; the source contract above ran`
	);
	console.log(`[OK] Windows field report collector (${checks} source checks).`);
	fs.rmSync(path.dirname(emptyConfig), { recursive: true, force: true });
	process.exit(0);
}
assert.ifError(probe.error);
assert.equal(probe.status, 0, probe.stdout + probe.stderr);
console.log(`[runtime] PowerShell ${probe.stdout.trim()}`);

// The interpreter the collector finds: it names the analyser's budget sources.
const python = ['python3', 'python', 'py'].find(
	(name) => spawnSync(name, ['--version'], { encoding: 'utf8' }).status === 0
);
assert(python, 'the collector runtime needs a Python interpreter');

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-windows-field-')));

/**
 * Builds a fixture clone whose origin holds dev, checked out on `start`.
 * @param {string} name Fixture folder name.
 * @param {string} [start] Starting branch, pushed to origin.
 */
function fixture(name, start = 'dev') {
	const base = path.join(scratch, name);
	const clone = path.join(base, 'clone');
	const origin = path.join(base, 'origin.git');
	const local = path.join(base, 'localappdata');
	const sources = JSON.parse(
		spawnSync(python, [path.join(ROOT, ANALYSER), '--repo', ROOT, '--describe'], {
			encoding: 'utf8'
		}).stdout
	).sources;
	for (const relative of [
		IDENTIFIERS,
		APP_DIRS,
		LOG_SCRUB,
		COLLISIONS,
		BUNDLED_SAMPLE,
		ANALYSER,
		...sources
	]) {
		fs.mkdirSync(path.dirname(path.join(clone, relative)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), path.join(clone, relative));
	}
	const script = path.join(clone, SCRIPT);
	fs.mkdirSync(path.dirname(script), { recursive: true });
	// Off Windows the platform guard alone is left out of a private copy.
	fs.writeFileSync(script, process.platform === 'win32' ? source : source.replace(GUARD, ''));
	fs.writeFileSync(path.join(clone, '.gitignore'), '*.log\n');
	const logs = path.join(local, LOG.folder, 'logs');
	fs.mkdirSync(logs, { recursive: true });
	fs.writeFileSync(
		path.join(logs, `${LOG.main}${today()}${LOG.extension}`),
		'2026-10-28 10:00:00 [INFO] [BootProfile] Boot complete in 900 ms (since process start).\n' +
			'2026-10-28 10:01:00 [INFO] [ComposerCheck] check=composer verdict=fail steps=2 load=pass type=fail\n' +
			'2026-10-28 10:02:00 [ERROR] [Fixture] an error\n' +
			"2026-10-28 10:03:00 [DEBUG] [LLM.tt] DISMISS: keystroke 'TYPEDCANARY' typed while a prediction was shown.\n"
	);
	fs.writeFileSync(path.join(logs, LOG.bootstrap), 'yield second_instance\n');
	git(clone, 'init', '-q', '-b', 'dev');
	git(clone, 'add', '-A');
	git(clone, 'commit', '-q', '-m', 'fixture');
	git(base, 'init', '-q', '--bare', origin);
	git(clone, 'remote', 'add', 'origin', fileUrl(origin));
	git(clone, 'push', '-q', 'origin', 'dev');
	if (start !== 'dev') {
		git(clone, 'switch', '-q', '-c', start);
		git(clone, 'push', '-q', 'origin', start);
	}
	return { base, clone, origin, local, script };
}

/** Runs the real collector inside a fixture. */
function runCollector(paths, { push = false } = {}) {
	const args = [
		'-NoProfile',
		'-NonInteractive',
		'-ExecutionPolicy',
		'Bypass',
		'-File',
		paths.script
	];
	if (!push) args.push('-NoPush');
	return spawnSync(interpreter, args, {
		cwd: paths.clone,
		encoding: 'utf8',
		timeout: 120000,
		windowsHide: true,
		env: { ...process.env, ...GIT_IDENTITY, LOCALAPPDATA: paths.local }
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

try {
	check(
		'started on dev, the report goes to field/win-<today>-dev, names its base and is pushed',
		() => {
			const paths = fixture('from-dev');
			const devBefore = git(paths.clone, 'rev-parse', 'dev');
			const result = runCollector(paths, { push: true });
			assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
			const expected = `${names.branch_prefix}win-${today()}-dev`;
			assert.equal(git(paths.clone, 'branch', '--show-current'), expected);
			assert.equal(git(paths.clone, 'rev-parse', 'dev'), devBefore, 'dev must not move');
			assert.equal(
				git(paths.clone, 'config', '--get', `branch.${expected}.${names.base_config_key}`),
				'dev'
			);
			const folders = reportFolders(paths);
			assert.equal(folders.length, 1);
			assert.match(path.basename(folders[0]), /^win-\d{4}-\d{2}-\d{2}_\d{6}$/);
			const head = git(paths.clone, 'rev-parse', '--short', 'HEAD~1');
			assert.equal(
				fs.readFileSync(path.join(folders[0], 'base.txt'), 'utf8'),
				`field_branch: ${expected}\nbase: dev\ncommit: ${head}\n`
			);
			const steps = fs.readFileSync(path.join(folders[0], 'steps.txt'), 'utf8');
			for (const name of ['versions', 'toolchain', 'processes', 'proxy'])
				assert.match(steps, new RegExp(`^${name}\\s+exit=\\d+$`, 'm'));
			const dayLog = `${LOG.main}${today()}${LOG.extension}`;
			assert.match(
				steps,
				new RegExp(`^${dayLog.replace(/\./g, '\\.')}\\s+copied \\(scrubbed\\)$`, 'm')
			);
			assert.match(steps, /^hotstring_collisions\s+exit=0$/m);
			const dayLogCopy = fs.readFileSync(path.join(folders[0], dayLog), 'utf8');
			assert.doesNotMatch(dayLogCopy, /TYPEDCANARY/, 'the pushed day log keeps no typed text');
			assert.match(dayLogCopy, /keystroke <text withheld> typed while/);
			for (const file of fs.readdirSync(folders[0]))
				assert.doesNotMatch(
					fs.readFileSync(path.join(folders[0], file), 'utf8'),
					/TYPEDCANARY/,
					`${file} holds no typed text`
				);
			assert.match(
				fs.readFileSync(path.join(folders[0], 'digest_field_checks.txt'), 'utf8'),
				/check=composer verdict=fail/
			);
			// The analysis marks the tray check of the day and the collector's own.
			assert.match(steps, /^collector_checks\s+exit=\d+$/m);
			assert.match(steps, /^analysis\s+exit=0$/m);
			const analysis = JSON.parse(fs.readFileSync(path.join(folders[0], 'analysis.json'), 'utf8'));
			assert.equal(
				analysis.field_checks.items.find((item) => item.id === 'composer').verdict,
				'fail'
			);
			assert.equal(analysis.performance.find((row) => row.metric === 'boot.total').max, 900);
			assert.match(result.stdout, /Check verdicts summary: /);
			assert.doesNotMatch(fs.readFileSync(path.join(folders[0], 'steps.txt'), 'utf8'), /\r/);
			const committed = git(paths.clone, 'show', '--name-only', '--format=', 'HEAD').split('\n');
			assert(
				committed.every((file) => file.startsWith(`${names.folder}/`)),
				committed.join(', ')
			);
			assert(
				committed.some((file) => file.endsWith(`/${dayLog}`)),
				'the ignored log is committed'
			);
			assert(committed.some((file) => file.endsWith(`/${LOG.bootstrap}`)));
			for (const name of ['analysis.md', 'analysis.json'])
				assert(
					committed.some((file) => file.endsWith(`/${name}`)),
					`${name} is committed`
				);
			assert.equal(git(paths.origin, 'rev-parse', expected), git(paths.clone, 'rev-parse', 'HEAD'));
			assert.equal(git(paths.clone, 'status', '--porcelain', '--untracked-files=no'), '');
		}
	);

	check('on its field branch a later run keeps the recorded base and brings its new commit', () => {
		const paths = fixture('recorded-base', 'feature/x');
		const first = runCollector(paths);
		assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
		const expected = `${names.branch_prefix}win-${today()}-feature-x`;
		assert.equal(git(paths.clone, 'branch', '--show-current'), expected);
		const other = path.join(paths.base, 'other');
		git(paths.base, 'clone', '-q', '--branch', 'feature/x', fileUrl(paths.origin), other);
		fs.writeFileSync(path.join(other, 'later.txt'), 'later\n');
		git(other, 'add', 'later.txt');
		git(other, 'commit', '-q', '-m', 'later');
		git(other, 'push', '-q', 'origin', 'feature/x');
		// A report folder is named to the second: a run in the same one is refused.
		spawnSync(process.execPath, ['-e', 'setTimeout(() => {}, 1100)']);
		const second = runCollector(paths);
		assert.equal(second.status, 0, `${second.stdout}\n${second.stderr}`);
		assert.equal(git(paths.clone, 'branch', '--show-current'), expected, 'the branch is reused');
		assert(fs.existsSync(path.join(paths.clone, 'later.txt')), "the base's new commit is merged");
		const folders = reportFolders(paths);
		assert.equal(folders.length, 2);
		assert.match(
			fs.readFileSync(path.join(folders[1], 'base.txt'), 'utf8'),
			new RegExp(`^field_branch: ${expected}\nbase: feature/x\n`)
		);
	});

	check('tracked changes are refused before any branch is switched', () => {
		const paths = fixture('dirty');
		fs.appendFileSync(path.join(paths.clone, '.gitignore'), '# edit\n');
		const result = runCollector(paths);
		assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`);
		assert.match(result.stderr, /Commit or discard the tracked changes first/);
		assert.equal(git(paths.clone, 'branch', '--show-current'), 'dev');
		assert.deepEqual(reportFolders(paths), []);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
	fs.rmSync(path.dirname(emptyConfig), { recursive: true, force: true });
}
console.log(`[OK] Windows field report collector (${checks} checks).`);
