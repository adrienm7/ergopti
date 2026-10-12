// tools/test/test-diagnostic-ui-integrity.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostic UI Integrity Validation
 * DESCRIPTION:
 * Holds the three diagnostics hosts and the shared page to one design:
 * 1. the page loads the model, the redactor and the translations, and gives
 *    the hosts one entry point, window.receiveDiagnostics;
 * 2. rows that once rendered wrong still render right through the model: the
 *    macOS tap telemetry, the commit's origin and the two folders under their
 *    own labels, a missing permission as a failure, the Linux system rows, the
 *    source of the recent issues, and the module check as collapsed developer
 *    details;
 * 3. no host keeps the previous design: the macOS copy button injected into
 *    the page and polled every 200 ms, the Windows native copy button, a
 *    subprocess or WMI query on the thread or the event loop that serves the
 *    keyboard, on any of the three drivers.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const DRIVER_ROOT = path.join(REPO_ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(DRIVER_ROOT, '_shared');

let totalPass = 0;
let totalFail = 0;

/**
 * Records one named check.
 * @param {string} label
 * @param {boolean} ok
 * @param {string} violation Shown when the check fails.
 */
function report(label, ok, violation) {
	if (ok) {
		totalPass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
		return;
	}
	totalFail++;
	console.log(`  ${FAIL_SYMBOL}  ${label}`);
	console.log(`       Violation: ${violation}`);
}

/**
 * Reads a repository file.
 * @param {string} rel Path under static/ergopti_plus/.
 * @returns {string}
 */
function read(rel) {
	return fs.readFileSync(path.join(DRIVER_ROOT, rel), 'utf8');
}

/**
 * Every file of a folder, concatenated.
 * @param {string} rel Folder under static/ergopti_plus/.
 * @returns {string}
 */
function readFolder(rel) {
	const dir = path.join(DRIVER_ROOT, rel);
	return fs
		.readdirSync(dir)
		.filter((name) => /\.(lua|ahk)$/.test(name))
		.map((name) => fs.readFileSync(path.join(dir, name), 'utf8'))
		.join('\n');
}

/**
 * Removes Lua and AHK line comments, so a comment naming a forbidden call is
 * not mistaken for one.
 * @param {string} source
 * @returns {string}
 */
function withoutComments(source) {
	return source
		.split('\n')
		.map((line) => line.replace(/^\s*(--|;).*$/, ''))
		.join('\n');
}

console.log('\n=== Diagnostic UI Integrity Validation ===');

// ==============================
// ==============================
// ======= 1/ The Page ==========
// ==============================
// ==============================

const html = read('_shared/ui/healthcheck/index.html');
const script = read('_shared/ui/healthcheck/script.js');
const style = read('_shared/ui/healthcheck/style.css');
const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
const needed = [
	'../dom_utils.js',
	'../host_bridge.js',
	'../i18n.js',
	'../redact.js',
	'model.js',
	'checks.js',
	'script.js'
];
report(
	'Shared: the page loads its helpers, the model and the redactor before its script',
	JSON.stringify(scripts) === JSON.stringify(needed),
	`scripts are ${JSON.stringify(scripts)}`
);
report(
	'Shared: the page has one host entry point, window.receiveDiagnostics',
	/window\.receiveDiagnostics\s*=\s*function/.test(script) && !/renderHealthcheck/.test(script),
	'script.js must define receiveDiagnostics and drop renderHealthcheck'
);
report(
	'Shared: the page follows a dark system appearance',
	/@media \(prefers-color-scheme: dark\)/.test(style),
	'style.css has no dark appearance'
);

// ===================================
// ===================================
// ======= 2/ Rows Through The Model =
// ===================================
// ===================================

const Model = (() => {
	const sandbox = { window: {} };
	for (const rel of ['ui/dom_utils.js', 'ui/healthcheck/model.js']) {
		const file = path.join(SHARED, rel);
		vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	}
	return sandbox.window.ErgoptiDiagnostics;
})();
const schema = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8')
);
const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
const t = (key, ...args) => {
	let index = 0;
	return typeof en[key] === 'string' ? en[key].replace(/%s/g, () => String(args[index++])) : key;
};

/**
 * Renders one driver's snapshot through the model.
 * @param {string} driver
 * @param {object} sections
 * @returns {string}
 */
function render(driver, sections) {
	return Model.renderHtml(
		{
			schema_version: 2,
			driver,
			generated_at: '2026-09-24T10:00:00Z',
			detailed: false,
			sections,
			probes: {}
		},
		schema,
		t
	);
}

/** The escaped text of a table row: its label cell, then its value. */
function rowPattern(label, value) {
	return new RegExp(`<th scope="row">${label}</th><td><span class="[a-z]+">${value}</span>`);
}

{
	const html = render('macos', {
		developer: { event_tap_telemetry: 'unavailable — native contract marker' }
	});
	report(
		'macOS: the native tap telemetry status is rendered in the developer details',
		html.includes('unavailable — native contract marker') && /id="section-developer"/.test(html),
		'the telemetry did not reach the collapsed developer section'
	);
}

{
	const html = render('macos', {
		versions: { commit: 'f58d15798 (build)' },
		paths: {
			config_dir: '/Volumes/Fixture/alice/Chosen/ergopti_plus',
			app_dir: '/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos'
		}
	});
	report(
		'Shared: commit origin, config dir and app dir render under their own labels',
		rowPattern(t('healthcheck.field.commit'), 'f58d15798 \\(build\\)').test(html) &&
			html.includes('/Volumes/Fixture/alice/Chosen/ergopti_plus') &&
			rowPattern(
				t('healthcheck.field.app_dir'),
				'/Applications/ErgoptiPlus\\.app/Contents/Resources/static/ergopti_plus/macos'
			).test(html),
		'a commit, config or app folder row is missing'
	);
}

{
	const html = render('macos', {
		permissions: {
			items: [
				{ id: 'accessibility', state: 'granted' },
				{ id: 'screen_recording', state: 'missing' }
			]
		}
	});
	report(
		'macOS: a missing permission renders as a failure with its settings button',
		/<tr class="fail"><td>Screen Recording<\/td>/.test(html) &&
			/<tr class="ok"><td>Accessibility<\/td>/.test(html) &&
			html.includes('data-action="open_settings" data-id="screen_recording"'),
		'the permission rows lack their state class or the settings button'
	);
}

{
	const html = render('linux', {
		system: {
			os: 'Fedora Linux 41',
			kernel: '6.11.4',
			display_server: 'wayland',
			desktop: 'GNOME'
		},
		hardware: { cpu: 'AMD Ryzen 7', cpu_cores: 16, ram_total: 33285996544, arch: 'x86_64' }
	});
	const missing = [
		rowPattern(t('healthcheck.field.os'), 'Fedora Linux 41'),
		rowPattern(t('healthcheck.field.kernel'), '6\\.11\\.4'),
		rowPattern(t('healthcheck.field.cpu'), 'AMD Ryzen 7'),
		rowPattern(t('healthcheck.field.ram_total'), '31\\.0 GB'),
		rowPattern(t('healthcheck.field.display_server'), 'wayland')
	].filter((pattern) => !pattern.test(html));
	report(
		'Linux: the system rows render their values',
		missing.length === 0,
		`missing ${missing.join(', ')}`
	);
}

{
	const html = render('windows', {
		issues: { recent_source: 'ring', recent: ['2026-09-23 10:00:01:002 [ERROR] [Probe] boom'] }
	});
	report(
		'Shared: recent issues name their source (errors-file-issues)',
		html.includes(t('healthcheck.recent_source.ring')) && html.includes('[ERROR] [Probe] boom'),
		'the ring fallback is not named or the entry is missing'
	);
}

{
	const html = render('linux', {
		developer: {
			modules_ok: ['engine'],
			modules_failed: ['keylogger (not wired)'],
			modules_disabled: ['llm']
		}
	});
	report(
		'Shared: module checks sit in collapsed developer details and a failure reaches the summary',
		/<details class="section" id="section-developer">/.test(html) &&
			html.includes(t('healthcheck.problem.modules', 1)) &&
			html.includes('keylogger (not wired)'),
		'the developer section is not collapsed or its failure is not summarised'
	);
}

// =================================
// =================================
// ======= 3/ The Hosts ============
// =================================
// =================================

const macCore = withoutComments(readFolder('macos/ui/healthcheck'));
report(
	'macOS: the window registers the "healthcheck" message handler the page posts to',
	/hs\.webview\.usercontent\.new,\s*BRIDGE/.test(macCore) &&
		/local BRIDGE = "healthcheck"/.test(macCore),
	'no usercontent controller named healthcheck'
);
report(
	'macOS: nothing polls the page for a copy flag',
	!/__hs_copy_requested/.test(macCore) && !/TimerScheduler\.every\(/.test(macCore),
	'the injected copy button or its 200 ms poll is back'
);
// Any reference, not only a call: the old collectors ran pcall(hs.execute, "sysctl …"),
// which a pattern requiring "hs.execute(" never saw. The behaviour is pinned by
// macos/tests/unit/ui/test_healthcheck_phase_a_no_subprocess.lua.
report(
	'macOS: no synchronous subprocess in the diagnostics window',
	!/\bhs\.execute\b|\bio\.popen\b|\bos\.execute\b/.test(macCore) && macCore.length > 1000,
	'an hs.execute, io.popen or os.execute runs on the run loop that dispatches the event taps'
);

const winCore = withoutComments(readFolder('windows/ui/healthcheck'));
report(
	"Windows: the window subscribes to the page's messages, bound to its epoch",
	/WebMessageReceived\(_HC_OnWebMessage\.Bind\(WindowEpoch\)\)/.test(winCore),
	'no epoch-bound subscription'
);
report(
	'Windows: the native copy button is gone',
	!/healthcheck\.copy_and_close/.test(winCore) && !/_HealthCheck_CopyAndClose/.test(winCore),
	'the native copy-and-close button is back'
);
report(
	'Windows: no WMI or blocking child on the thread that serves the keyboard hook',
	!/WbemScripting|winmgmts|\bRunWait\b/i.test(winCore) && winCore.length > 1000,
	'a WMI query or a RunWait runs on the AHK thread'
);
report(
	'Windows: browser failure retains structured native diagnostics',
	/_HC_ShowNativeSnapshot\(G, Snapshot\)/.test(winCore) &&
		/G\.Add\("TreeView"/.test(winCore) &&
		/HealthCheck_Config\(\)\["schema"\]\["sections"\]/.test(winCore) &&
		!/_HealthCheck_LoadDocs/.test(winCore),
	'no schema-driven native view'
);

const linuxBridge = withoutComments(read('linux/ui/healthcheck/bridge.lua'));
report(
	'Linux: every page message goes through the shared action allowlist',
	/Actions\.validate\(payload/.test(linuxBridge),
	'the bridge does not validate page messages'
);
const linuxCollect = linuxBridge + withoutComments(read('linux/ui/healthcheck/probes.lua'));
report(
	'Linux: no blocking child in the collection or the probes',
	!/io\.popen\s*\(|os\.execute\s*\(|Shell\.(run|exec[a-z_]*)\s*\(/.test(linuxCollect),
	'a synchronous child runs on the event loop that reads the grabbed keyboard'
);

// A field filled by a probe reads "checking…" until its driver answers that
// probe: every probe the schema declares for a driver must be started by the
// driver's probe module, which names it when it starts and finishes it
{
	const schema = JSON.parse(
		fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8')
	);
	const probeModules = {
		windows: withoutComments(read('windows/ui/healthcheck/probes.ahk')),
		macos: withoutComments(read('macos/ui/healthcheck/probes.lua')),
		linux: withoutComments(read('linux/ui/healthcheck/probes.lua'))
	};
	let declared = 0;
	for (const [driver, source] of Object.entries(probeModules)) {
		for (const [id, probe] of Object.entries(schema.probes || {})) {
			if (Array.isArray(probe.platforms) && !probe.platforms.includes(driver)) continue;
			declared++;
			report(
				`${driver}: the ${id} probe is started`,
				source.includes(`"${id}"`),
				`${driver}/ui/healthcheck/probes never names the ${id} probe the schema declares for it`
			);
		}
	}
	report(
		"Shared: the probe check sees every driver's probes",
		declared >= 9,
		`only ${declared} probe(s) declared`
	);
}

const collectionContract = JSON.parse(read('_shared/modules/diagnostics/collection.json'));
for (const id of [
	'hotstrings',
	'ai',
	'capture_replay',
	'callbacks',
	'fifo',
	'modifiers',
	'native_render',
	'native_uia',
	'cleanup'
]) {
	report(
		`Collection: ${id} has an explicit result slot`,
		collectionContract.checks.includes(id),
		`${id} cannot disappear from incomplete collection`
	);
}
report(
	'Collection: every platform uses the same evidence classes',
	JSON.stringify(collectionContract.evidence_classes) ===
		JSON.stringify(['automatic', 'native_synthetic', 'physical', 'unexecuted']),
	'Evidence classes drifted'
);
report(
	'Collection: statuses preserve cancellation and nonexecution',
	JSON.stringify(collectionContract.statuses) === JSON.stringify(['PASS', 'FAIL', 'SKIP', 'UNRUN']),
	'Result statuses drifted'
);
// These source controls receive custody boundaries; only the native lane receives PowerShell.
const collectorSource = read('windows/vendor/ergopti_diagnostics.ps1').replace(/^\s*#.*$/gm, '');
/** Receives only source custody; stock native PowerShell remains a separate gate. */
function receiveEvidenceCustody(source) {
	const archive = source.slice(source.indexOf('$taskStagingArchive ='));
	return {
		'producer membership': archive.includes(
			'if (!$taskEvidenceReceipts.ContainsKey($taskEvidence)) { continue }'
		),
		'locked byte identity':
			archive.includes('[IO.FileShare]::Read)') &&
			archive.includes('$taskInput.Length -ne $taskProduced.bytes') &&
			archive.includes('(Get-CollectionStreamHash $taskInput) -cne $taskProduced.sha256') &&
			archive.includes('$taskInput.Position = 0') &&
			archive.indexOf('$taskInput.Position = 0') <
				archive.indexOf('$taskZip.CreateEntry($taskEvidence)'),
		'same stream copy':
			archive.includes('$taskInput.CopyTo($taskEntryStream)') &&
			archive.includes('finally { $taskInput.Dispose() }') &&
			!archive.includes('[IO.File]::OpenRead('),
		'private first creation':
			source.includes(
				"$taskImage = [IO.File]::Open((Join-Path $taskRoot 'synthetic-window.png'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)"
			) &&
			source.includes("$taskEvidenceReceipts['synthetic-window.png'] =") &&
			source.includes(
				'$taskOutput = [IO.File]::Open($taskStaging, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)'
			) &&
			source.includes("throw 'Foreign diagnostic output refused.'") &&
			source.includes('[IO.File]::Move($taskStaging, $taskTarget)'),
		'all text producers':
			source.includes('Write-CollectionText $Name $taskJson') &&
			source.includes("Write-CollectionText 'summary.md' $taskSummary") &&
			source.includes('$taskEvidenceReceipts[$Name] = [ordered]@{bytes=$taskBytes.Length; sha256=')
	};
}
const evidenceCustody = receiveEvidenceCustody(collectorSource);
for (const [name, required] of [
	['producer membership', 'if (!$taskEvidenceReceipts.ContainsKey($taskEvidence)) { continue }'],
	['locked byte identity', '(Get-CollectionStreamHash $taskInput) -cne $taskProduced.sha256'],
	['same stream copy', '$taskInput.CopyTo($taskEntryStream)'],
	[
		'private first creation',
		"$taskImage = [IO.File]::Open((Join-Path $taskRoot 'synthetic-window.png'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)"
	],
	['all text producers', 'Write-CollectionText $Name $taskJson']
]) {
	report(
		'Collection source: ' + name,
		evidenceCustody[name],
		'Produced evidence custody is missing.'
	);
	const withdrawn = collectorSource.replace(required, '');
	report(
		'Collection source inverse: ' + name,
		collectorSource.split(required).length === 2 && !receiveEvidenceCustody(withdrawn)[name],
		'The independently withdrawn actual custody boundary was still admitted.'
	);
}
/** Equal-byte foreign successors require native identity; path names cannot author updates. */
function receiveOwnedStream(source) {
	const body = source.slice(
		source.indexOf('function Write-CollectionText('),
		source.indexOf('function Write-CollectionJson(')
	);
	return {
		'exclusive acquired update':
			body.includes(
				'$taskOutput = [IO.File]::Open($taskTarget, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)'
			) &&
			body.includes('(Get-CollectionStreamHash $taskOutput) -cne $taskPrior.sha256') &&
			body.includes('$taskOutput.SetLength(0)') &&
			body.indexOf('(Get-CollectionStreamHash $taskOutput) -cne $taskPrior.sha256') <
				body.indexOf('$taskOutput.SetLength(0)') &&
			!body.includes('Move-Item'),
		'private native identity':
			body.includes('Test-CollectionFileIdentity $taskIdentity $taskPrior.identity') &&
			source.includes('information.NumberOfLinks != 1') &&
			source.includes('GetFileInformationByHandle(handle, out information)'),
		'busy progress read':
			collectionSource.includes(
				'if Reading && Err is OSError && (Err.Number == 32 || Err.Number == 33)'
			) &&
			collectionSource.indexOf('Reading := false') <
				collectionSource.indexOf('Value := JsonParse(Raw)')
	};
}
const collectionSource = read('windows/ui/healthcheck/collection.ahk');
const ownedStream = receiveOwnedStream(collectorSource);
for (const [name, required] of [
	['exclusive acquired update', '(Get-CollectionStreamHash $taskOutput) -cne $taskPrior.sha256'],
	['private native identity', 'Test-CollectionFileIdentity $taskIdentity $taskPrior.identity']
]) {
	report('Collection source: ' + name, ownedStream[name], 'Existing output ownership was lost.');
	report(
		'Collection source inverse: ' + name,
		collectorSource.split(required).length === 2 &&
			!receiveOwnedStream(collectorSource.replace(required, ''))[name],
		'The withdrawn exclusive update guard remained admitted.'
	);
}
report(
	'Collection source: busy progress read',
	ownedStream['busy progress read'],
	'Native producer sharing must retry without admitting invalid progress.'
);
/** Primary collection errors preserve a useful archive without claiming completion. */
function receiveCollectorFailure(source) {
	return {
		'primary exit': source.includes('if ($null -ne $taskFailure) { exit 1 }'),
		'primary progress': source.includes(
			"phase=$(if($null -ne $taskFailure){'failed'}else{'completed'})"
		)
	};
}
const collectorFailure = receiveCollectorFailure(collectorSource);
for (const [name, required] of [
	['primary exit', 'if ($null -ne $taskFailure) { exit 1 }'],
	['primary progress', "phase=$(if($null -ne $taskFailure){'failed'}else{'completed'})"]
]) {
	report('Collection source: ' + name, collectorFailure[name], 'Primary refusal was promoted.');
	report(
		'Collection source inverse: ' + name,
		collectorSource.split(required).length === 2 &&
			!receiveCollectorFailure(collectorSource.replace(required, ''))[name],
		'The missing primary outcome remained admitted.'
	);
}
if (process.argv.includes('--native-collection')) {
	if (process.platform !== 'win32') throw new Error('Native collection controls require Windows.');
	const { spawnSync } = require('node:child_process');
	const runtime = process.env.ERGOPTI_AHK_RUNTIME;
	if (!runtime || !fs.existsSync(runtime))
		throw new Error('Native collection controls require an explicit actual AHK runtime.');
	const powershell = path.join(
		process.env.SystemRoot,
		'System32/WindowsPowerShell/v1.0/powershell.exe'
	);
	const fixture = path.join(
		DRIVER_ROOT,
		'windows/tests/fixtures/diagnostic_collection_controls.ps1'
	);
	const result = spawnSync(
		powershell,
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			fixture,
			'-Checkout',
			REPO_ROOT,
			'-Runtime',
			runtime
		],
		{ encoding: 'utf8', windowsHide: true }
	);
	if (result.stdout) console.log(result.stdout);
	if (result.stderr) console.error(result.stderr);
	report(
		'Collection: actual stock Windows PowerShell archive controls',
		result.status === 0 && !result.error,
		`Native process exit ${result.status}: ${result.error || ''}`
	);
}
console.log(`\nResults: ${totalPass} passed, ${totalFail} failed.`);
if (totalFail > 0) process.exit(1);
