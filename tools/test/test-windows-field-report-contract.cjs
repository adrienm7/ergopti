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
const { escapeRegExp } = require('../lib/text-escape.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/collect-windows-field-report.ps1';
const IDENTIFIERS = 'static/ergopti_plus/_shared/core/text/data/identifiers.json';
const APP_DIRS = 'static/ergopti_plus/_shared/core/fs/data/paths/app_dirs.toml';
const LOG_SCRUB = 'tools/dev/field-log-scrub.py';
const REPORT_REDACT = 'tools/dev/field-report-redact.py';
const COLLISIONS = 'tools/dev/hotstring-collisions.py';
// The analyser and the declarations it reads its budgets from.
const ANALYSER = 'tools/dev/field-log-analyse.py';
// The machine facts and timeline builder the analysis reads first.
const FACTS = 'tools/dev/field-report-facts.py';
// The field run protocol every driver shares, and the Windows steps.
const FIELD_RUN_PROTOCOL = 'static/ergopti_plus/_shared/diagnostics/data/field_run_protocol.json';
const FIELD_RUN_STEPS = 'static/ergopti_plus/windows/diagnostics/data/field_run_steps.json';
const BUNDLED_SAMPLE =
	'static/ergopti_plus/_shared/hotstrings/data/catalogue/french/autocorrection.toml';
const GUARD =
	"if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Fail 'This collector runs on Windows only.' }\n";

const source = fs.readFileSync(path.join(ROOT, SCRIPT), 'utf8');
const code = source
	.split('\n')
	.filter((line) => !/^\s*#/.test(line))
	.join('\n');
const names = JSON.parse(fs.readFileSync(path.join(ROOT, IDENTIFIERS), 'utf8')).field_report;
const appDirs = fs.readFileSync(path.join(ROOT, APP_DIRS), 'utf8');
/** A report file wherever field-report-tidy.py sorted it (0_main, 1_logs, 2_digests, 3_system), else at the root. */
function reportFile(folder, name) {
	for (const sub of ['', '0_main', '1_logs', '2_digests', '3_system']) {
		const candidate = path.join(folder, sub, name);
		if (fs.existsSync(candidate)) return candidate;
	}
	return path.join(folder, name);
}

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
	for (const section of ['app', 'logs', 'logs.files', 'logs.windows', 'config.windows'])
		assert.match(code, new RegExp(`Read-TomlSection '${section.replace('.', '\\.')}'`));
	for (const literal of [LOG.main, LOG.bootstrap, `\\${LOG.folder}\\logs`])
		assert(!code.includes(literal), `the collector spells ${literal} itself`);
	const resolver = code.match(/^function Resolve-LogsDir \{\n([\s\S]*?)^\}$/m);
	assert(resolver, 'no Resolve-LogsDir');
	assert.doesNotMatch(resolver[1], /LOCALAPPDATA/, 'the logs base is the declared one');
	assert.match(resolver[1], /Join-AppDir \$LogsBase \$LogsSegments/);
	const joiner = code.match(/^function Join-AppDir\(.*\) \{\n([\s\S]*?)^\}$/m);
	assert(joiner, 'no Join-AppDir');
	assert.match(joiner[1], /GetEnvironmentVariable\(\$Base\)/);
	for (const key of [
		'unified_prefix',
		'errors_prefix',
		'extension',
		'bootstrap_log',
		'base',
		'segments',
		'paths_file'
	])
		assert.match(code, new RegExp(`Get-AppDir \\$\\w+ '[\\w.]+' '${key}'`));
});

// The builds before the single folder name read paths.toml from Roaming AppData
// and defaulted the configuration to %USERPROFILE%\.config: the collector now
// resolves both from [config.windows], like apps/engine/folders.ahk.
check('the paths.toml and configuration defaults come from app_dirs.toml', () => {
	const resolver = code.match(/^function Resolve-ConfigDir \{\n([\s\S]*?)^\}$/m);
	assert(resolver, 'no Resolve-ConfigDir');
	assert.doesNotMatch(
		resolver[1],
		/APPDATA|USERPROFILE|\.config/,
		'no folder is spelled by the collector'
	);
	assert.match(resolver[1], /Join-AppDir \$ConfigBase \$PathsFileSegments/);
	assert.match(resolver[1], /Join-AppDir \$ConfigBase \$ConfigSegments/);
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

check('the field run speaks the shared protocol and never starts a driver', () => {
	const body = code.match(/^function Invoke-FieldRun \{\n([\s\S]*?)^\}$/m);
	assert(body, 'no Invoke-FieldRun');
	const protocol = JSON.parse(fs.readFileSync(path.join(ROOT, FIELD_RUN_PROTOCOL), 'utf8'));
	assert.match(body[1], /'data', 'field_run_protocol\.json'/);
	assert.match(body[1], /\$Protocol\.steps_file\.windows/);
	assert.match(body[1], /\$Protocol\.folder\.clone/);
	for (const name of Object.values(protocol.files))
		assert(!code.includes(`'${name}'`), `the collector spells the file name ${name} itself`);
	for (const kind of ['ready', 'request', 'refused', 'accepted', 'done', 'results'])
		assert.match(body[1], new RegExp(`\\$Files\\.${kind}\\b`), `the ${kind} file`);
	assert.match(body[1], /\$Protocol\.result_file_pattern/);
	assert.doesNotMatch(
		code,
		/run-windows-dev\.ps1'|& .*run-windows-dev/,
		'it never starts a driver'
	);
	// Every outcome is one verdict line the analysis marks.
	for (const line of [
		'check=field_run verdict=skip codes=no_ready_driver',
		'check=field_run verdict=fail codes=not_accepted',
		'check=field_run verdict=timeout codes=no_done_marker',
		'check=field_run verdict=fail codes=driver_gone'
	])
		assert(body[1].includes(line), line);
	assert.match(body[1], /check=\$\(\$Result\.step\) verdict=\$\(\$Result\.verdict\)/);
	assert(
		code.indexOf('try { Invoke-FieldRun }') > code.indexOf("Invoke-Step 'collector_checks'"),
		'the field run comes after the facts it would otherwise delay'
	);
});

check('every step is timed with progress and a heartbeat, and the instances are sampled', () => {
	const step = code.match(/^function Invoke-Step\(.*\) \{\n([\s\S]*?)^\}$/m);
	assert(step, 'no Invoke-Step');
	assert.match(
		step[1],
		/Log "> step \$\(\$script:StepIndex\)\/\$\(\$script:StepTotal\) \$Name\$Eta"/
	);
	assert.match(
		step[1],
		/\[ErgoptiFieldHeartbeat\]::Start\(\$Name, \$HeartbeatSeconds, \$script:StepHint\)/
	);
	assert.match(step[1], /\[ErgoptiFieldHeartbeat\]::Stop\(\)/);
	assert.match(step[1], /Add-StepTime \$Name 'collector' \$Started \(Get-Epoch\)/);
	assert.match(step[1], /Log " {2}\[OK\] \$Name \(\$Seconds s\)"/);
	assert.match(
		code,
		/function Get-Epoch \{[^\n]*ToString\('F3', \$Invariant\)/,
		'a decimal point on every locale'
	);
	const fieldRun = code.match(/^function Invoke-FieldRun \{\n([\s\S]*?)^\}$/m)[1];
	assert.match(fieldRun, /Get-FieldInstances 'sample'/, 'the field run samples the instances');
	assert.match(fieldRun, /field run still running: /, 'the field run has a heartbeat');
	for (const phase of ['start', 'before_run', 'end'])
		assert.match(
			code,
			new RegExp(`Get-FieldInstances '${phase}'\\n\\t\\tShow-MultipleDrivers \\$Lines '${phase}'`)
		);
	// WMI took 2.4 s a query on the maintainer's PC: never a whole-machine scan.
	const instances = code.match(/^function Get-FieldInstances\(.*\) \{\n([\s\S]*?)^\}$/m)[1];
	assert.doesNotMatch(instances, /LIKE/, 'Get-Process finds the candidates');
	assert.match(instances, /\$script:ProcessDetails/);
});

// The maintainer's PC (2026-11-17) has no MSFT_MpComputerStatus class: the
// step failed instead of saying so, and named no antivirus at all.
check(
	'the antivirus step reports a missing Defender class and the Security Center products',
	() => {
		const step = code.match(/Invoke-Step 'antivirus' \{\n([\s\S]*?)\n\t\}\n/)[1];
		assert.match(step, /catch \[Microsoft\.Management\.Infrastructure\.CimException\]/);
		assert.match(
			step,
			/-notmatch '0x80041010'\) \{ throw \}/,
			'any other failure still fails the step'
		);
		assert.match(step, /root\/SecurityCenter2' -ClassName AntiVirusProduct/);
	}
);

check('the proxy facts say set or unset, never an address', () => {
	const winhttp = code.match(/Invoke-Step 'proxy_winhttp' \{\n([\s\S]*?)\n\t\}\n/)[1];
	assert.match(winhttp, /'WinHTTP: direct' \} else \{ 'WinHTTP: set' \}/);
	assert.doesNotMatch(winhttp, /netsh/, 'its wording follows the display language');
	assert.match(winhttp, /'WinHttpSettings'/, 'the answer is the registry flags');
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
		'The field run needs a developer driver',
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

// The maintainer's PC (2026-11-17): a personal trigger « ★… » shared with a
// bundled one killed the step with UnicodeEncodeError under the console's
// cp1252 stdout.
check('the hotstring collisions print a non-ANSI trigger under a cp1252 console', () => {
	const folder = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-collisions-')));
	try {
		const bundled = path.join(folder, 'bundled');
		fs.mkdirSync(bundled);
		fs.writeFileSync(
			path.join(bundled, 'symbols.toml'),
			'[[symbols]]\n"★x" = { output = "a", is_word = true }\n'
		);
		fs.writeFileSync(
			path.join(folder, 'personal.toml'),
			'[[mine]]\n"★x" = { output = "b", is_word = false }\n'
		);
		const result = spawnSync(
			python,
			[path.join(ROOT, COLLISIONS), path.join(folder, 'personal.toml'), bundled],
			{ encoding: 'utf8', env: { ...process.env, PYTHONIOENCODING: 'cp1252', PYTHONUTF8: '0' } }
		);
		assert.equal(result.status, 0, result.stderr);
		assert.match(result.stdout, /'★x' personal is_word=False/);
		assert.match(result.stdout, /1 personal trigger\(s\) shared with a bundled one/);
	} finally {
		fs.rmSync(folder, { recursive: true, force: true });
	}
});

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
	// The configuration folder is resolved from LOCALAPPDATA ([config.windows]).
	// APPDATA and USERPROFILE still point into the fixture, so nothing the
	// collector runs can read the runner's own profile.
	const roaming = path.join(base, 'appdata');
	const profile = path.join(base, 'profile');
	fs.mkdirSync(roaming, { recursive: true });
	fs.mkdirSync(profile, { recursive: true });
	const sources = JSON.parse(
		spawnSync(python, [path.join(ROOT, ANALYSER), '--repo', ROOT, '--describe'], {
			encoding: 'utf8'
		}).stdout
	).sources;
	for (const relative of [
		IDENTIFIERS,
		APP_DIRS,
		LOG_SCRUB,
		REPORT_REDACT,
		COLLISIONS,
		BUNDLED_SAMPLE,
		ANALYSER,
		FACTS,
		FIELD_RUN_PROTOCOL,
		FIELD_RUN_STEPS,
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
	return { base, clone, origin, local, roaming, profile, script };
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
		// The machine facts add about twenty seconds of WMI and event-log
		// queries; a loaded PC ran one collection past two minutes.
		timeout: 240000,
		windowsHide: true,
		env: {
			...process.env,
			...GIT_IDENTITY,
			// A one-second heartbeat and a three-second idle window: the idle step
			// then outlives one heartbeat, which the run must print.
			FIELD_HEARTBEAT_SECONDS_OVERRIDE: '1',
			FIELD_IDLE_SECONDS_OVERRIDE: '3',
			LOCALAPPDATA: paths.local,
			APPDATA: paths.roaming,
			USERPROFILE: paths.profile
		}
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
				fs.readFileSync(reportFile(folders[0], 'base.txt'), 'utf8'),
				`field_branch: ${expected}\nbase: dev\ncommit: ${head}\n`
			);
			const steps = fs.readFileSync(reportFile(folders[0], 'steps.txt'), 'utf8');
			for (const name of ['versions', 'toolchain', 'processes', 'proxy'])
				assert.match(steps, new RegExp(`^${name}\\s+exit=\\d+$`, 'm'));
			const dayLog = `${LOG.main}${today()}${LOG.extension}`;
			assert.match(steps, new RegExp(`^${escapeRegExp(dayLog)}\\s+copied \\(scrubbed\\)$`, 'm'));
			assert.match(steps, /^hotstring_collisions\s+exit=0$/m);
			assert.match(steps, /^proxy_winhttp\s+exit=0$/m);
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'proxy_winhttp.txt'), 'utf8'),
				/^WinHTTP: (direct|set)\s*$/
			);
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'hotstring_collisions.txt'), 'utf8'),
				/no personal hotstrings file at personal_hotstrings\.toml/,
				'the fixture profile holds no personal file'
			);
			const dayLogCopy = fs.readFileSync(reportFile(folders[0], dayLog), 'utf8');
			assert.doesNotMatch(dayLogCopy, /TYPEDCANARY/, 'the pushed day log keeps no typed text');
			assert.match(dayLogCopy, /keystroke <text withheld> typed while/);
			for (const file of fs.readdirSync(folders[0]))
				assert.doesNotMatch(
					fs.readFileSync(reportFile(folders[0], file), 'utf8'),
					/TYPEDCANARY/,
					`${file} holds no typed text`
				);
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'digest_field_checks.txt'), 'utf8'),
				/check=composer verdict=fail/
			);
			// The analysis marks the tray check of the day and the collector's own.
			assert.match(steps, /^collector_checks\s+exit=\d+$/m);
			assert.match(steps, /^analysis\s+exit=0$/m);
			const analysis = JSON.parse(fs.readFileSync(reportFile(folders[0], 'analysis.json'), 'utf8'));
			assert.equal(
				analysis.field_checks.items.find((item) => item.id === 'composer').verdict,
				'fail'
			);
			assert.equal(analysis.performance.find((row) => row.metric === 'boot.total').max, 900);
			assert.match(result.stdout, /Check verdicts summary: /);
			// No developer driver runs in the fixture: the field run is a skip, not a wait.
			assert.equal(
				fs.readFileSync(reportFile(folders[0], 'field_run_checks.txt'), 'utf8'),
				'check=field_run verdict=skip codes=no_ready_driver\n'
			);
			assert.doesNotMatch(fs.readFileSync(reportFile(folders[0], 'steps.txt'), 'utf8'), /\r/);
			// The machine facts, the timing and the live progress (2026-11-17).
			// The console writes CRLF on Windows.
			const terminal = result.stdout.replace(/\r\n/g, '\n');
			for (const name of [
				'instances_start',
				'remappers',
				'permissions',
				'keyboards',
				'environment',
				'app_folders',
				'instances_before_run',
				'instances_end',
				'idle_cpu',
				'event_log'
			])
				assert.match(steps, new RegExp(`^${name}\\s+exit=\\d+$`, 'm'), `step ${name}`);
			assert.match(steps, /^facts\s+exit=0$/m);
			assert.match(terminal, /^\[field-report\] > step 1\/\d+ versions$/m, 'step k/N');
			// Off Windows, pwsh has no Get-CimInstance: the fact step fails as a
			// recorded step (header), which the terminal says with its time.
			assert.match(
				terminal,
				process.platform === 'win32'
					? /^\[field-report\] {3}\[OK\] versions \(\d+ s\)$/m
					: /^\[field-report\] {3}\[FAIL\] versions exited \d+ \(\d+ s, kept in .+versions\.txt\)$/m
			);
			assert.match(
				terminal,
				/^\[field-report\] {3}\.\.\. idle_cpu still running \(\d+ s\)$/m,
				'heartbeat'
			);
			assert.match(terminal, /waiting for you: keep your hands off the keyboard/);
			const env = JSON.parse(fs.readFileSync(reportFile(folders[0], 'env.json'), 'utf8'));
			assert.equal(env.os, 'win');
			if (process.platform === 'win32') {
				assert(env.environment.os_name, 'the environment facts reach env.json');
			} else {
				// Off Windows the environment step stops on Get-CimInstance before
				// its fact line: a recorded failure, and no invented machine.
				assert.match(steps, /^environment\s+exit=1$/m, 'the environment step failed as recorded');
				assert.equal(env.environment?.os_name, undefined, 'no environment fact off Windows');
			}
			if (process.platform === 'win32') {
				assert(
					env.permissions.some((row) => row.name === 'uac'),
					'the UAC fact'
				);
			} else {
				// WindowsIdentity is Windows-only: the permissions step stops first.
				assert.match(steps, /^permissions\s+exit=1$/m, 'the permissions step failed as recorded');
			}
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'instances_start.txt'), 'utf8'),
				/^fact\tsample\tphase=start\tt=\d+\.\d{3}$/m
			);
			const timeline = fs.readFileSync(reportFile(folders[0], 'timeline.txt'), 'utf8');
			assert.match(timeline, /^## Slowest steps$/m);
			assert.match(timeline, /\[collector\] idle_cpu/);
			const times = fs.readFileSync(reportFile(folders[0], 'step_times.tsv'), 'utf8');
			// The versions step fails off Windows (Get-CimInstance), as above.
			assert.match(
				times,
				process.platform === 'win32'
					? /^versions\tcollector\t\d+\.\d{3}\t\d+\.\d{3}\t0\t30$/m
					: /^versions\tcollector\t\d+\.\d{3}\t\d+\.\d{3}\t1\t30$/m,
				'invariant epoch seconds'
			);
			assert.match(times, /^field_run\tphase\t/m);
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'analysis.md'), 'utf8'),
				/^## Slowest steps$/m
			);
			assert.match(
				fs.readFileSync(reportFile(folders[0], 'analysis.md'), 'utf8'),
				/^## Machine and instances$/m
			);
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
			fs.readFileSync(reportFile(folders[1], 'base.txt'), 'utf8'),
			new RegExp(`^field_branch: ${expected}\nbase: feature/x\n`)
		);
	});

	check('tracked changes are stashed and the clone reset before the run', () => {
		const paths = fixture('dirty');
		fs.appendFileSync(path.join(paths.clone, '.gitignore'), '# edit\n');
		const result = runCollector(paths);
		assert.doesNotMatch(result.stderr, /could not be stashed/);
		assert.match(result.stdout, /Tracked changes found/);
		assert.match(git(paths.clone, 'stash', 'list'), /field-report auto-stash/);
		assert.doesNotMatch(fs.readFileSync(path.join(paths.clone, '.gitignore'), 'utf8'), /# edit\n$/);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
	fs.rmSync(path.dirname(emptyConfig), { recursive: true, force: true });
}
console.log(`[OK] Windows field report collector (${checks} checks).`);
