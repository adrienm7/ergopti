// tools/test/test-release-packaging-workflow.cjs

/**
 * Regression guard for release-only packaging commands that the ordinary
 * driver and package tests do not execute. The Windows bundle implementation
 * moved from lib/ to infra/, while the release stamp retained the old path.
 * Separately, `tar | head` under `pipefail` makes a successful archive listing
 * fail when head closes the pipe early. The macOS bundle smoke test also used
 * the inner Mach-O directly, bypassing the Launch Services context that Finder
 * and `open` provide and causing AppKit to terminate its embedded GUI child.
 * Early log creation subsequently masked a missing LuaSocket dependency: the
 * published app died immediately after the smoke test had declared success.
 * The Windows compile step ran Ahk2Exe, a GUI-subsystem binary, through the
 * call operator: PowerShell returned before the compiler finished and left
 * $LASTEXITCODE unset, so `exit $LASTEXITCODE` exited 0 ahead of the output
 * check and a failed compile passed.
 * These defects surfaced only after every functional CI job had passed.
 *
 * The pipeline now spans ci.yml and one reusable workflow per OS. Each step is
 * looked up through tools/test/ci-pipeline.cjs and must exist exactly once, in
 * the package job of the OS box that builds that artifact, so a moved or
 * duplicated release step fails here instead of silently escaping the check.
 * The Windows exe job must also wait for test-ahk and never run its suites or
 * touch Defender (B1), and each release-only macOS step must run on every
 * release under its exact condition. A review then moved Sign after the
 * upload and Stamp after Compile, and removed the exe smoke's failing exit,
 * with every test green: the job's step order and the smoke's verdict are
 * pinned too, and so is the order of the macOS package job.
 * The exe smoke later failed a healthy launch because a 20 s wall clock was
 * its only dialog detector while the first-launch extraction takes up to
 * 19 s on a hosted runner: its wait must end on a dialog window of the
 * launched process, keep a hang bound well above the measured extraction and
 * print what tells a slow extraction from a stuck one.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const pipeline = require('./ci-pipeline.cjs');

const root = path.resolve(__dirname, '..', '..');
const WINDOWS_BOX = '.github/workflows/ci-windows.yml';
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const MACOS_BOX = '.github/workflows/ci-macos.yml';
const windowsToolchainContractPath = path.join(
	root,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'updater',
	'windows_release_toolchain.json'
);
const windowsToolchainContract = JSON.parse(fs.readFileSync(windowsToolchainContractPath, 'utf8'));
const errors = [];

// The one job of each box that builds its release artifact.
const PACKAGE_JOB = {
	[WINDOWS_BOX]: 'package-windows',
	[LINUX_BOX]: 'package-linux',
	[MACOS_BOX]: 'package-macos'
};
const releaseSteps = new Map();

/**
 * Returns the body of the one step named `name`, which must live in the package
 * job of `rel`, or null after recording why it could not be found there. A name
 * is resolved once, so a check that reads it again adds no second error.
 * @param {string} name Exact step name.
 * @param {string} rel Repository-relative workflow that must own the step.
 * @returns {string|null}
 */
function releaseStep(name, rel) {
	if (releaseSteps.has(name)) return releaseSteps.get(name);
	const job =
		name === 'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)'
			? 'launch-windows'
			: PACKAGE_JOB[rel];
	let body = null;
	try {
		const found = pipeline.findStep(name);
		if (found.file === rel && found.job === job) {
			body = found.body;
		} else {
			errors.push(
				`step '${name}' runs in ${found.file} (job ${found.job}); it belongs in job ${job} of ${rel}`
			);
		}
	} catch (error) {
		errors.push(`${error.message}; job ${job} of ${rel} must run it exactly once`);
	}
	releaseSteps.set(name, body);
	return body;
}

// B1: the release exe is bundled, stamped, compiled, signed, smoked and
// uploaded by its own job on a fresh checkout. The unit and E2E suites of
// test-ahk write runtime caches next to tracked sources, and
// build_static_bundle.py bundles those directories, so any of these steps in
// test-ahk would ship test leftovers inside the signed exe; the smoke there
// would also run under the Defender configuration the test job alters.
for (const name of [
	'Build static asset bundle',
	'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL',
	'Download the authenticated compiler toolchain',
	'Compile ErgoptiPlus.ahk',
	'Sign and verify ErgoptiPlus.exe',
	'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)',
	'Rename the keyboard layout for upload'
]) {
	releaseStep(name, WINDOWS_BOX);
}
const windowsUpload = releaseStep('Upload the application and layout', WINDOWS_BOX);
if (windowsUpload !== null && !/^\s+name:\s*assets-windows\s*$/m.test(windowsUpload)) {
	errors.push(
		'the Windows release exe must be uploaded as assets-windows, the artifact release attaches'
	);
}
const packageWindows = pipeline.job(PACKAGE_JOB[WINDOWS_BOX]);
if (!pipeline.needsOf(packageWindows).includes('e2e-ahk')) {
	errors.push(
		`${PACKAGE_JOB[WINDOWS_BOX]} must need e2e-ahk: a release exe is built only after the suites passed`
	);
}
const codeOf = (body) =>
	body
		.split('\n')
		.filter((line) => !line.trimStart().startsWith('#'))
		.join('\n');
const testAhkCode = codeOf(pipeline.job('test-ahk')) + codeOf(pipeline.job('e2e-ahk'));
for (const token of ['run_all.ahk', 'run_e2e.ahk', 'MpPreference']) {
	// The token must still exist where it belongs, so the ban reads live text.
	if (!testAhkCode.includes(token)) {
		errors.push(`test-ahk no longer mentions ${token}; re-derive the B1 separation check`);
	}
	if (codeOf(packageWindows).includes(token)) {
		errors.push(
			`${PACKAGE_JOB[WINDOWS_BOX]} must not run ${token}: the release exe job neither tests nor touches Defender`
		);
	}
}

// The exe embeds the bundle when it is compiled, so the bundle is built and
// stamped first; it is signed and smoked before it is uploaded. Reordered, the
// job still runs every step and ships `__BUNDLE_VERSION__` placeholders, which
// the updater reads as a dev build, or an unsigned or unsmoked exe. That no
// step of the job can be skipped is pinned pipeline-wide by
// tools/test/test-ci-pipeline-wiring.cjs.
const WINDOWS_ORDER = [
	'Build static asset bundle',
	'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL',
	'Compile ErgoptiPlus.ahk',
	'Sign and verify ErgoptiPlus.exe',
	'Rename the keyboard layout for upload',
	'Upload the application and layout'
];
const packageWindowsSteps = pipeline.steps(packageWindows).map((candidate) => candidate.name);
const windowsOrder = WINDOWS_ORDER.map((name) => packageWindowsSteps.indexOf(name));
if (windowsOrder.some((at, index) => at < 0 || (index > 0 && at <= windowsOrder[index - 1]))) {
	errors.push(
		`${PACKAGE_JOB[WINDOWS_BOX]} must run ${WINDOWS_ORDER.join(' < ')}; got: ${packageWindowsSteps.join(' | ')}`
	);
}
if (
	!(
		packageWindowsSteps.indexOf('Download the authenticated compiler toolchain') >= 0 &&
		packageWindowsSteps.indexOf('Download the authenticated compiler toolchain') <
			packageWindowsSteps.indexOf('Compile ErgoptiPlus.ahk')
	)
) {
	errors.push(
		`${PACKAGE_JOB[WINDOWS_BOX]} must download the authenticated toolchain before it compiles`
	);
}

// The smoke's verdict is behavioural (the runtime bundle extracted, no early
// exit): its failure branch must end the step with a failing exit, or a
// crashing exe only prints an error.
const windowsSmokeStep = releaseStep(
	'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)',
	WINDOWS_BOX
);
if (windowsSmokeStep !== null) {
	try {
		const verdict = pipeline.scriptBlock(
			pipeline.runOf(windowsSmokeStep) ?? [],
			'if ($crashedEarly -or -not $markerSeen) {'
		);
		if (!pipeline.blockExits(verdict, '1')) {
			errors.push('the Windows exe smoke must end its crash branch with exit 1');
		}
	} catch (error) {
		errors.push(`the Windows exe smoke lost its crash verdict: ${error.message}`);
	}
}

// Run 613 failed this smoke with "did not extract its runtime bundle within
// 20s — a blocking startup dialog is likely" and passed on re-run: the 20 s
// wall clock was its only dialog detector. The first launch extracts about 550
// files through Windows PowerShell while Defender scans each one, and the green
// smokes of runs 582-613 took 8-19 s, so the slow end of a healthy extraction
// read as a dialog. The wait now ends on what it names: the marker, the process
// exiting, or a dialog window (class #32770) of the launched process. Its wall
// clock only bounds a hang that raises no dialog, so it must stay well above
// the measured extraction time, and a failure prints the timings, windows,
// child processes and bundle tree that tell a slow extraction from a stuck one.
const SLOWEST_GREEN_WINDOWS_SMOKE_SECONDS = 19;
const WINDOWS_SMOKE_HANG_HEADROOM = 3;
// The step's time outside the wait: the Add-Type compile of the dialog probe
// before it, and the diagnostics, which can wait on a hung window, after it.
const WINDOWS_SMOKE_STEP_MARGIN_SECONDS = 60;
// PowerShell names are case-insensitive, so $seconds is the same parameter.
const WINDOWS_SMOKE_PRINTS_ELAPSED = /Write-Host .*\$Seconds\b/i;
const WINDOWS_SMOKE_VERDICT = 'if ($crashedEarly -or -not $markerSeen) {';
const WINDOWS_SMOKE_WAIT_OPENER = 'while ($clock.Elapsed.TotalSeconds -lt $hangBoundSeconds) {';
// The only ways out of the wait, in order. Any other exit, such as a
// wall-clock deadline, turns a slow extraction back into a false failure.
const WINDOWS_SMOKE_WAIT_EXITS = [
	'if ($proc.HasExited) { break }',
	'if (Test-Path -LiteralPath $markerFile) { $markerSeen = $true; break }',
	'if ([SmokeWindows]::HasDialog($proc.Id)) { $dialogSeen = $true; break }'
];

/**
 * Lists why a Windows exe smoke script would read a slow first-launch
 * extraction as a blocking dialog, or fail without the evidence that tells
 * the two apart.
 * @param {string[]} script Script lines, such as pipeline.runOf() returns.
 * @param {string|null} timeoutMinutes The step's `timeout-minutes`, such as
 *   pipeline.stepField() returns.
 * @returns {string[]}
 */
function windowsSmokeWaitProblems(script, timeoutMinutes) {
	const problems = [];
	const code = script.filter((line) => !line.trimStart().startsWith('#'));
	const bounds = code
		.map((line) => /^\$hangBoundSeconds = (\d+)$/.exec(line.trim()))
		.filter((match) => match !== null);
	const floor = SLOWEST_GREEN_WINDOWS_SMOKE_SECONDS * WINDOWS_SMOKE_HANG_HEADROOM;
	if (bounds.length !== 1) {
		problems.push('the Windows exe smoke must set its hang bound $hangBoundSeconds exactly once');
	} else if (Number(bounds[0][1]) < floor) {
		problems.push(
			`the Windows exe smoke hang bound (${bounds[0][1]} s) must be at least ` +
				`${WINDOWS_SMOKE_HANG_HEADROOM} x the slowest green smoke ` +
				`(${SLOWEST_GREEN_WINDOWS_SMOKE_SECONDS} s): it bounds a hang, it does not detect a dialog`
		);
	} else if (!/^\d+$/.test(timeoutMinutes ?? '')) {
		problems.push(
			`the Windows exe smoke step must set timeout-minutes to a whole number, got ${timeoutMinutes}`
		);
	} else if (
		Number(bounds[0][1]) + WINDOWS_SMOKE_STEP_MARGIN_SECONDS >
		Number(timeoutMinutes) * 60
	) {
		// GitHub cancels a step at its timeout without running the rest of
		// the script, so a hang bound it cuts short prints no diagnostics.
		problems.push(
			`the Windows exe smoke hang bound (${bounds[0][1]} s) plus ` +
				`${WINDOWS_SMOKE_STEP_MARGIN_SECONDS} s for the probe compile and the diagnostics ` +
				`must fit the step's timeout-minutes (${timeoutMinutes})`
		);
	}
	if (
		code.filter((line) => line.trim() === 'private const string DialogClass = "#32770";').length !==
		1
	) {
		problems.push('the Windows exe smoke must recognise a dialog by its window class #32770');
	}
	// A token anywhere in the probe proves nothing: the class could be compared
	// to another constant, or the windows of another process read.
	for (const [opener, required, what] of [
		[
			'public static bool HasDialog(int processId)',
			[
				'foreach (var window in TopLevelWindows(processId))',
				'if (ClassOf(window) == DialogClass) return true;'
			],
			'compare each window of the process to DialogClass'
		],
		[
			'private static List<IntPtr> TopLevelWindows(int processId)',
			[
				'GetWindowThreadProcessId(window, out owner);',
				'if (owner == (uint)processId) found.Add(window);'
			],
			'keep only the windows of the launched process'
		]
	]) {
		try {
			const method = pipeline.scriptBlock(code, opener).map((line) => line.trim());
			if (!required.every((statement) => method.includes(statement))) {
				problems.push(`the Windows exe smoke dialog probe must ${what}`);
			}
		} catch (error) {
			problems.push(`the Windows exe smoke lost its dialog probe: ${error.message}`);
		}
	}
	try {
		const wait = pipeline.scriptBlock(code, 'while (');
		if (wait[0].trim() !== WINDOWS_SMOKE_WAIT_OPENER) {
			problems.push(
				`the Windows exe smoke wait must be bounded by $hangBoundSeconds alone: ${WINDOWS_SMOKE_WAIT_OPENER}`
			);
		}
		const body = wait.slice(1, -1).map((line) => line.trim());
		const exits = body.filter((line) =>
			/\b(?:break|exit|return|throw)\b|\bWrite-Error\b/i.test(line)
		);
		if (exits.join('\n') !== WINDOWS_SMOKE_WAIT_EXITS.join('\n')) {
			problems.push(
				`the Windows exe smoke wait must end only on a crash, the marker or a dialog: ` +
					`expected ${WINDOWS_SMOKE_WAIT_EXITS.join(' | ')}; got ${exits.join(' | ')}`
			);
		}
		const clockReads = body.filter(
			(line) =>
				/\bElapsed\b|Get-Date|\[DateTime\]|\bTicks\b|\bTickCount|\bTotal(?:Milli)?Seconds\b/i.test(
					line
				) && line !== '$stagingSeconds = $clock.Elapsed.TotalSeconds'
		);
		if (clockReads.length > 0) {
			problems.push(
				`the Windows exe smoke wait may read the clock only to time the staging directory: ${clockReads.join(' | ')}`
			);
		}
	} catch (error) {
		problems.push(`the Windows exe smoke lost its wait loop: ${error.message}`);
	}
	try {
		// The opener declares the parameters, so a token found there proves
		// nothing is printed: only the body counts.
		const diagnostics = pipeline.scriptBlock(code, 'function Write-LaunchDiagnostics').slice(1);
		const descendants = diagnostics.some(
			(line) => line.trim() === 'Write-StartupOwnershipEvidence $Process'
		)
			? pipeline.scriptBlock(code, 'function Write-StartupOwnershipEvidence')
			: [];
		for (const [pattern, what] of [
			[WINDOWS_SMOKE_PRINTS_ELAPSED, 'the elapsed time'],
			[/\[SmokeWindows\]::Describe\(/, 'the windows of the process'],
			[/\bWin32_Process\b/, 'its child processes'],
			[/\$ergoptiDir\b/, 'the bundle tree']
		]) {
			if (![...diagnostics, ...descendants].some((line) => pattern.test(line))) {
				problems.push(`the Windows exe smoke diagnostics must print ${what} (${pattern.source})`);
			}
		}
		const verdict = pipeline.scriptBlock(code, WINDOWS_SMOKE_VERDICT);
		const callInVerdict = verdict.findIndex((line) => /^\s*Write-LaunchDiagnostics\b/.test(line));
		if (callInVerdict < 0) {
			problems.push('the Windows exe smoke must print its diagnostics before it fails');
		} else {
			// Write-LaunchDiagnostics reads the live process: once the app is
			// stopped, the dialog text, windows and children it prints are gone,
			// and the step still fails, so nothing else would notice the loss.
			const call =
				code.findIndex((line) => line.trimStart().startsWith(WINDOWS_SMOKE_VERDICT)) +
				callInVerdict;
			const stopperAt = code.findIndex((line) =>
				line.trimStart().startsWith('function Stop-LaunchedApp')
			);
			const stopper = pipeline.scriptBlock(code, 'function Stop-LaunchedApp');
			const early = code.filter(
				(line, index) =>
					index < call &&
					(index < stopperAt || index >= stopperAt + stopper.length) &&
					/\bStop-LaunchedApp\b|\bStop-Process\b|\.Kill\(/.test(line)
			);
			if (early.length > 0) {
				problems.push(
					`the Windows exe smoke must print its diagnostics before it stops the app: ${early
						.map((line) => line.trim())
						.join(' | ')}`
				);
			}
		}
	} catch (error) {
		problems.push(`the Windows exe smoke lost its failure diagnostics: ${error.message}`);
	}
	if (!code.some((line) => /^\s*marker_seconds = /.test(line))) {
		problems.push('the Windows exe smoke evidence must record how long the marker took');
	}
	return problems;
}

if (windowsSmokeStep !== null) {
	const script = pipeline.runOf(windowsSmokeStep) ?? [];
	const timeoutMinutes = pipeline.stepField(windowsSmokeStep, 'timeout-minutes');
	errors.push(...windowsSmokeWaitProblems(script, timeoutMinutes));
	// Each rule must be able to fail on the live script, or it proves nothing.
	for (const [what, mutate, timeout = timeoutMinutes] of [
		[
			'a 20 s hang bound',
			(lines) =>
				lines.map((line) => line.replace(/^\$hangBoundSeconds = \d+$/, '$hangBoundSeconds = 20'))
		],
		[
			'a hang bound the step timeout cuts short',
			(lines) =>
				lines.map((line) => line.replace(/^\$hangBoundSeconds = \d+$/, '$hangBoundSeconds = 300'))
		],
		['a step timeout shorter than the hang bound', (lines) => lines, '2'],
		['a step without a timeout', (lines) => lines, null],
		[
			'a wait blind to dialogs',
			(lines) => lines.filter((line) => !line.includes('[SmokeWindows]::HasDialog($proc.Id)'))
		],
		[
			'a disabled dialog exit',
			(lines) =>
				lines.map((line) =>
					line.replace(
						'if ([SmokeWindows]::HasDialog($proc.Id))',
						'if ($false -and [SmokeWindows]::HasDialog($proc.Id))'
					)
				)
		],
		[
			'the 20 s wall clock back inside the wait',
			(lines) =>
				lines.flatMap((line) =>
					line.trim() === WINDOWS_SMOKE_WAIT_OPENER
						? [line, '    if ($clock.Elapsed.TotalSeconds -gt 20) { break }']
						: [line]
				)
		],
		[
			'a second deadline in the wait condition',
			(lines) =>
				lines.map((line) =>
					line.replace(
						'-lt $hangBoundSeconds) {',
						'-lt $hangBoundSeconds -and $clock.Elapsed.TotalSeconds -lt 20) {'
					)
				)
		],
		[
			'a dialog probe that tests another window class',
			(lines) =>
				lines.map((line) =>
					line.replace(
						'if (ClassOf(window) == DialogClass) return true;',
						'if (ClassOf(window) == "AutoHotkeyGUI") return true;'
					)
				)
		],
		[
			'a dialog class other than #32770',
			(lines) =>
				lines.map((line) =>
					line.replace('DialogClass = "#32770";', 'DialogClass = "AutoHotkeyGUI";')
				)
		],
		[
			'a dialog probe that ignores the launched process',
			(lines) =>
				lines.map((line) =>
					line.replace('if (owner == (uint)processId) found.Add(window);', 'found.Add(window);')
				)
		],
		[
			'a failure without diagnostics',
			(lines) => lines.filter((line) => !/^\s*Write-LaunchDiagnostics\b/.test(line))
		],
		[
			'diagnostics that never print the elapsed time',
			(lines) => lines.filter((line) => !WINDOWS_SMOKE_PRINTS_ELAPSED.test(line))
		],
		[
			'diagnostics read after the failure branch stops the app',
			(lines) => {
				const call = lines.findIndex((line) => /^\s*Write-LaunchDiagnostics\b/.test(line));
				const stop = lines.findIndex(
					(line, index) => index > call && /^\s*Stop-LaunchedApp\b/.test(line)
				);
				const swapped = [...lines];
				[swapped[call], swapped[stop]] = [lines[stop], lines[call]];
				return swapped;
			}
		],
		[
			'the app stopped before the verdict',
			(lines) =>
				lines.flatMap((line) =>
					line.trimStart().startsWith(WINDOWS_SMOKE_VERDICT)
						? ['Stop-LaunchedApp $proc', line]
						: [line]
				)
		],
		[
			'evidence without the marker time',
			(lines) => lines.filter((line) => !/^\s*marker_seconds = /.test(line))
		]
	]) {
		if (windowsSmokeWaitProblems(mutate(script), timeout).length === 0) {
			errors.push(`the Windows exe smoke wait check cannot detect ${what}`);
		}
	}
}

/** The failure observer must retain actual process identity after the parent exits. */
function windowsStartupEvidenceProblems(script) {
	const problems = [];
	const code = script.filter((line) => !line.trimStart().startsWith('#'));
	try {
		const diagnostic = pipeline.scriptBlock(code, 'function Write-LaunchDiagnostics');
		const call = diagnostic.findIndex(
			(line) => line.trim() === 'Write-StartupOwnershipEvidence $Process'
		);
		const exited = diagnostic.findIndex((line) => line.includes('if ($Process.HasExited)'));
		if (call < 0 || exited < 0 || call >= exited) {
			problems.push(
				'startup identity/descendant/log evidence must run even after the tracked parent exits'
			);
		}
		const body = pipeline
			.scriptBlock(code, 'function Write-StartupOwnershipEvidence')
			.map((line) => line.trim());
		for (const statement of [
			'Write-Host ($launchOwner | ConvertTo-Json -Compress)',
			'$rows = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, ExecutablePath -OperationTimeoutSec 2 -ErrorAction Stop)',
			'$parentExitUtc = if ($Process.HasExited) { $Process.ExitTime.ToUniversalTime() } else { [DateTime]::UtcNow }',
			'for ($depth = 0; $depth -lt 4 -and $frontier.Count -gt 0; $depth++) {',
			'if ($observed -ge 16) { $truncated = $true; continue }',
			'$qualified = $parent.Qualified -and $null -ne $parent.Created -and $null -ne $created -and $created -ge $parent.Created -and $created -le $parent.Until',
			'$sameExecutable = $null -ne $row.ExecutablePath -and [string]::Equals($row.ExecutablePath, $launchOwner.expected_executable, [StringComparison]::OrdinalIgnoreCase)',
			'$count = [int][Math]::Min(4096, $length)',
			'$read = $stream.Read($bytes, 0, $count)',
			'if ($null -ne $stream) { $stream.Dispose() }'
		]) {
			if (!body.includes(statement))
				problems.push(`startup evidence lost its bounded native statement: ${statement}`);
		}
		for (const field of [
			'parent_pid =',
			'created_utc =',
			'lineage_qualified =',
			'same_executable =',
			'read_bytes =',
			'truncated =',
			"status = 'unavailable'",
			'modified_since_launch ='
		]) {
			if (!body.some((line) => line.includes(field)))
				problems.push(`startup evidence lost truthful field ${field}`);
		}
		if (body.some((line) => /CommandLine|\.Kill\(|Stop-Process|ready\s*=\s*\$true/.test(line))) {
			problems.push(
				'diagnostic observations must neither print argv nor authorize readiness/retirement'
			);
		}
		const formatter = pipeline.scriptBlock(code, 'function Format-StartupEvidenceText').join('\n');
		if (
			!formatter.includes('$Limit = 2048') ||
			!formatter.includes('$Text.Substring(0, $Limit)') ||
			!formatter.includes('[truncated]')
		) {
			problems.push(
				'native errors/foreign paths must be explicitly bounded and marked when truncated'
			);
		}
		for (const capture of [
			'$launchOwner.start_utc = $proc.StartTime.ToUniversalTime()',
			'$actualLaunchPath = $proc.MainModule.FileName',
			'$launchOwner.observed_executable = Format-StartupEvidenceText $actualLaunchPath',
			'$launchOwner.identity_qualified = [string]::Equals($actualLaunchPath, $launchOwner.expected_executable, [StringComparison]::OrdinalIgnoreCase)'
		]) {
			if (!code.some((line) => line.trim() === capture))
				problems.push(`native initial owner receipt lost ${capture}`);
		}
	} catch (error) {
		problems.push(`native startup evidence is missing: ${error.message}`);
	}
	return problems;
}

if (windowsSmokeStep !== null) {
	const script = pipeline.runOf(windowsSmokeStep) ?? [];
	errors.push(...windowsStartupEvidenceProblems(script));
	for (const [name, before, after] of [
		[
			'disabled collector',
			'Write-StartupOwnershipEvidence $Process',
			'if ($false) { Write-StartupOwnershipEvidence $Process }'
		],
		['missing native initial start', '$proc.StartTime.ToUniversalTime()', '$null'],
		['missing native initial executable', '$proc.MainModule.FileName', '$exe'],
		[
			'guessed initial identity',
			'$launchOwner.identity_qualified = [string]::Equals',
			'$launchOwner.identity_qualified = $true; [string]::Equals'
		],
		['unbounded CIM wait', '-OperationTimeoutSec 2', ''],
		['missing parent lifetime end', '$created -le $parent.Until', '$true'],
		['missing parent lifetime start', '$created -ge $parent.Created', '$true'],
		['unbounded descendant count', '$observed -ge 16', '$false'],
		['unbounded descendant depth', '$depth -lt 4', '$true'],
		['unbounded log read', '[Math]::Min(4096, $length)', '$length'],
		['lost file-handle cleanup', '$stream.Dispose()', '$null'],
		['lost observation error', "status = 'unavailable'", "status = 'observed'"],
		['lost path/error truncation', '$Text.Substring(0, $Limit)', '$Text'],
		['private argv', 'executable = $observedPath;', 'executable = $row.CommandLine;']
	]) {
		const source = script.join('\n');
		const changed = source.replaceAll(before, after);
		if (changed === source || windowsStartupEvidenceProblems(changed.split('\n')).length === 0) {
			errors.push(`startup evidence regression guard missed ${name}`);
		}
	}
	// Exercise the actual embedded catalogue reader against an independent parser.
	// The Windows function is diagnostic only; no simulated process qualifies it.
	const program = /\$catalogJson = & python -c '([^']+)'/.exec(script.join('\n'))?.[1];
	if (!program) {
		errors.push(
			'native startup logs must resolve the existing shared application directory catalogue'
		);
	} else {
		const { spawnSync } = require('node:child_process');
		const TOML = require('smol-toml');
		const catalogPath = path.join(root, 'static/ergopti_plus/_shared/modules/paths/app_dirs.toml');
		const catalog = TOML.parse(fs.readFileSync(catalogPath, 'utf8'));
		const expected = {
			base: catalog.logs.windows.base,
			segments: catalog.logs.windows.segments.map((value) =>
				value.replaceAll('{app}', catalog.app.folder_name)
			),
			prefix: catalog.logs.files.unified_prefix,
			extension: catalog.logs.files.extension
		};
		const result = spawnSync(
			process.platform === 'win32' ? 'python' : 'python3',
			['-c', program, catalogPath],
			{ encoding: 'utf8', timeout: 5000 }
		);
		try {
			if (
				result.error ||
				result.status !== 0 ||
				JSON.stringify(JSON.parse(result.stdout)) !== JSON.stringify(expected)
			) {
				errors.push(
					'the actual native startup catalogue program disagrees with the independent shared TOML reader'
				);
			}
		} catch {
			errors.push(
				'the actual native startup catalogue program did not return a complete JSON receipt'
			);
		}
	}
}

const stampStep = releaseStep(
	'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL',
	WINDOWS_BOX
);
if (stampStep !== null) {
	if (!/windows\\infra\\bundle\.ahk/.test(stampStep)) {
		errors.push('the Windows release must stamp the live infra/bundle.ahk implementation');
	}
	if (/windows\\lib\\bundle\.ahk/.test(stampStep)) {
		errors.push('the Windows release still stamps the removed lib/bundle.ahk path');
	}
}

const windowsToolchainStep = releaseStep(
	'Download the authenticated compiler toolchain',
	WINDOWS_BOX
);
if (windowsToolchainStep !== null) {
	const body = windowsToolchainStep;
	if (!body.includes('windows_release_toolchain.json') || !body.includes('ConvertFrom-Json')) {
		errors.push('the Windows compiler toolchain must consume its shared authenticated contract');
	}
	for (const token of [
		'$contract.runtime.url',
		'$contract.runtime.sha256',
		'$contract.compiler.url',
		'$contract.compiler.sha256',
		'Get-FileHash'
	]) {
		if (!body.includes(token)) {
			errors.push(`the Windows compiler toolchain is missing pinned token ${token}`);
		}
	}
	if (/gh release download|--pattern\s+['"]?\*\.zip|Select-Object\s+-First\s+1/i.test(body)) {
		errors.push('the Windows compiler toolchain must not select a mutable or ambiguous archive');
	}
}

// The AHK suites must run on the interpreter the exe ships with. They
// downloaded a hardcoded 2.0.19 of their own, so a runtime bump in the contract
// would have left every measured hook behaviour unchecked on the new base.
// The test job reads the same contract, keys its cache on it and checks the
// archive digest.
try {
	const contractStep = pipeline.findStep('Read AutoHotkey runtime contract');
	const cacheStep = pipeline.findStep('Cache AutoHotkey runtime');
	const downloadStep = pipeline.findStep('Download AutoHotkey v2 runtime');
	for (const found of [contractStep, cacheStep, downloadStep]) {
		if (found.file !== WINDOWS_BOX || found.job !== 'test-ahk') {
			errors.push(
				`the AHK test runtime step runs in ${found.file} (job ${found.job}); it belongs in test-ahk of ${WINDOWS_BOX}`
			);
		}
	}
	if (
		!contractStep.body.includes('windows_release_toolchain.json') ||
		!contractStep.body.includes('ConvertFrom-Json')
	) {
		errors.push('the AHK test job must read its runtime from the shared release contract');
	}
	const cacheKey = (/^\s+key:\s*(.*)$/m.exec(cacheStep.body) ?? [])[1] ?? '';
	if (
		!cacheKey.includes('steps.ahk-contract.outputs.version') ||
		!cacheKey.includes('steps.ahk-contract.outputs.sha256')
	) {
		errors.push(
			`the AHK test runtime cache must be keyed on the contract version and digest, got: ${cacheKey}`
		);
	}
	for (const token of [
		'steps.ahk-contract.outputs.url',
		'steps.ahk-contract.outputs.sha256',
		'Get-FileHash'
	]) {
		if (!downloadStep.body.includes(token)) {
			errors.push(`the AHK test runtime download is missing contract token ${token}`);
		}
	}
	if (/releases\/download\/v\d/.test(downloadStep.body) || /ahk-v\d/.test(cacheKey)) {
		errors.push('the AHK test runtime must not pin its own AutoHotkey version');
	}
} catch (error) {
	errors.push(`the AHK test runtime steps are missing: ${error.message}`);
}

// The AHK suite enforces that runtime itself, but only under CI: a developer's
// self-updating AutoHotkey turned every local run red with nothing wrong in the
// code (runtime-contract-local-2026-09-26). The test keys on GITHUB_ACTIONS,
// which GitHub sets to "true" for every step, so the Windows box must never
// set it, and the test must stay in the suite the test-ahk job runs.
try {
	const suiteStep = pipeline.findStep('Run AHK test suite');
	if (suiteStep.file !== WINDOWS_BOX || suiteStep.job !== 'test-ahk') {
		errors.push(
			`the AHK suite runs in ${suiteStep.file} (job ${suiteStep.job}); it belongs in test-ahk of ${WINDOWS_BOX}`
		);
	}
	if (/GITHUB_ACTIONS/.test(pipeline.file(WINDOWS_BOX))) {
		errors.push(
			`${WINDOWS_BOX} must not set GITHUB_ACTIONS: the AHK runtime-contract test enforces the pinned runtime only when GitHub's own value ("true") reaches it`
		);
	}
	const testsDir = path.join(root, 'static', 'ergopti_plus', 'windows', 'tests');
	const runtimeTest = fs.readFileSync(
		path.join(testsDir, 'unit', 'test_runtime_contract_version.ahk'),
		'utf8'
	);
	if (
		!runtimeTest.includes('EnvGet("GITHUB_ACTIONS") = "true"') ||
		!runtimeTest.includes(
			'_RCV_CheckRuntime(_RCV_ContractRuntimeVersion(), A_AhkVersion, _RCV_IsCi())'
		)
	) {
		errors.push(
			'the AHK runtime-contract test must hold the suite to the contract runtime whenever GITHUB_ACTIONS is "true"'
		);
	}
	if (
		!/^#Include unit\/test_runtime_contract_version\.ahk$/m.test(
			fs.readFileSync(path.join(testsDir, 'run_all.ahk'), 'utf8')
		)
	) {
		errors.push('run_all.ahk must include the AHK runtime-contract test');
	}
} catch (error) {
	errors.push(`the AHK runtime-contract enforcement cannot be checked: ${error.message}`);
}

for (const [component, expected] of Object.entries({
	runtime: {
		version: '2.0.26',
		asset: 'AutoHotkey_2.0.26.zip',
		sha256: '43522aa3122a57784ac5db30abf85c2244475c36acd7796e2c993355f9e926ae'
	},
	compiler: {
		tag: 'Ahk2Exe1.1.37.02a2',
		asset: 'Ahk2Exe1.1.37.02a2.zip',
		sha256: 'c29b8c3a5124850d79fc9e66e2ca79677c377d7f31631ad3022ba159c5d9e3be'
	}
})) {
	for (const [field, value] of Object.entries(expected)) {
		if (windowsToolchainContract[component]?.[field] !== value) {
			errors.push(`the Windows ${component} contract must pin ${field}=${value}`);
		}
	}
	if (!/^https:\/\/github\.com\/AutoHotkey\//.test(windowsToolchainContract[component]?.url)) {
		errors.push(`the Windows ${component} contract must use an exact official GitHub URL`);
	}
}

// The compile step as it stood before the fix: it exited 0 on a syntax error.
const PRE_FIX_COMPILE_RUN = [
	'          & $ahk2exe /in $in /out $out /base $runtime /icon $icon /silent',
	'          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }',
	'          if (-not (Test-Path $out)) {',
	'              Write-Error "Ahk2Exe reported success but $out was not created."',
	'              exit 1',
	'          }'
].join('\n');

/**
 * Lists every way a compile step body could report success for a failed
 * compile; an empty list means the step fails whenever Ahk2Exe does.
 * @param {string} stepBody Step body.
 * @returns {string[]}
 */
function compileStepProblems(stepBody) {
	const problems = [];
	// Comments may name the forbidden forms to explain them; only code counts.
	const body = stepBody
		.split('\n')
		.filter((line) => !line.trimStart().startsWith('#'))
		.join('\n');
	if (/^ {8}(?:if|continue-on-error):/m.test(body)) {
		problems.push('the compile step must be neither skippable nor allowed to fail');
	}
	if (/&\s*\$ahk2exe\b/.test(body)) {
		problems.push(
			'Ahk2Exe must not run through the call operator, which does not wait for a GUI binary'
		);
	}
	if (body.includes('$LASTEXITCODE')) {
		problems.push('the compile step must not read $LASTEXITCODE, which a GUI binary never sets');
	}
	const lines = body.split('\n');
	const launchAt = lines.findIndex((line) =>
		/\$\w+\s*=\s*Start-Process\s+-FilePath\s+\$ahk2exe\b/.test(line)
	);
	if (launchAt < 0) {
		problems.push('Ahk2Exe must run through `$proc = Start-Process -FilePath $ahk2exe`');
		return problems;
	}
	let launchEnd = launchAt;
	while (launchEnd + 1 < lines.length && lines[launchEnd].trimEnd().endsWith('`')) launchEnd++;
	const launch = lines.slice(launchAt, launchEnd + 1).join('\n');
	for (const flag of ['-Wait', '-PassThru']) {
		if (!new RegExp(`\\s${flag}\\b`).test(launch)) {
			problems.push(
				`Start-Process must pass ${flag} so the step reads the compiler's real exit code`
			);
		}
	}
	const proc = /\$(\w+)\s*=\s*Start-Process/.exec(launch)[1];
	const after = lines.slice(launchEnd + 1).join('\n');
	const exitAt = after.search(
		new RegExp(`if\\s*\\(\\s*\\$${proc}\\.ExitCode\\s+-ne\\s+0\\s*\\)\\s*\\{[^}]*\\bexit\\s+[1-9]`)
	);
	if (exitAt < 0) problems.push(`a non-zero $${proc}.ExitCode must exit the step non-zero`);
	const outputAt = after.search(
		/if\s*\([^\n]*Test-Path\b[^\n]*\$out\b[^\n]*\.Length\s+-(?:eq\s+0|le\s+0|lt\s+1)[^\n]*\{[^}]*\bexit\s+[1-9]/
	);
	if (outputAt < 0) {
		problems.push('a missing or empty ErgoptiPlus.exe must exit the step non-zero');
	} else if (exitAt >= 0 && outputAt < exitAt) {
		problems.push('the output check must follow the exit-code check');
	}
	return problems;
}

/**
 * Applies `replacement` to the first code line of `body` that matches
 * `pattern`, leaving comments alone; returns `body` unchanged when none does.
 * @param {string} body Step body.
 * @param {RegExp} pattern Non-global pattern.
 * @param {string} replacement
 * @returns {string}
 */
function mutateCode(body, pattern, replacement) {
	const lines = body.split('\n');
	const at = lines.findIndex((line) => !line.trimStart().startsWith('#') && pattern.test(line));
	if (at < 0) return body;
	lines[at] = lines[at].replace(pattern, replacement);
	return lines.join('\n');
}

const compileStep = releaseStep('Compile ErgoptiPlus.ahk', WINDOWS_BOX);
if (compileStep !== null) {
	const problems = compileStepProblems(compileStep);
	for (const problem of problems) errors.push(`the Windows compile gate is unsafe: ${problem}`);
	// The guard must be able to fail: the pre-fix step, and the real step with
	// any one of its checks removed, has to be rejected.
	if (problems.length === 0) {
		for (const [what, mutated] of [
			['the pre-fix call-operator step', PRE_FIX_COMPILE_RUN],
			['dropping -Wait', mutateCode(compileStep, /\s-Wait\b/, '')],
			['dropping -PassThru', mutateCode(compileStep, /\s-PassThru\b/, '')],
			[
				'dropping the exit-code check',
				mutateCode(compileStep, /\.ExitCode\s+-ne\s+0/, '.ExitCode -lt 0')
			],
			[
				'dropping the empty-output check',
				mutateCode(compileStep, /\.Length\s+-(?:eq\s+0|le\s+0|lt\s+1)/, '.Length -lt 0')
			]
		]) {
			if (mutated === compileStep) {
				errors.push(`self-check: ${what} changed nothing, so the compile step drifted`);
			} else if (compileStepProblems(mutated).length === 0) {
				errors.push(`self-check: ${what} went unnoticed, so this guard cannot fail`);
			}
		}
	}
}

const windowsSigningStep = releaseStep('Sign and verify ErgoptiPlus.exe', WINDOWS_BOX);
if (windowsSigningStep !== null) {
	const body = windowsSigningStep;
	for (const token of [
		'ERGOPTI_RELEASE_PRERELEASE',
		'WINDOWS_SIGNING_CERTIFICATE_BASE64',
		'WINDOWS_SIGNING_CERTIFICATE_PASSWORD',
		'WINDOWS_SIGNER_SUBJECT',
		'$missing.Count -eq $required.Count',
		'$missing.Count -gt 0',
		'Stable Windows releases require every signing secret.',
		'Partial Windows signing configuration',
		'Publishing an unsigned Windows artifact for the dev prerelease channel.',
		'signtool',
		'Get-AuthenticodeSignature',
		"Status -ne 'Valid'",
		'SignerCertificate.Subject'
	]) {
		if (!body.includes(token)) {
			errors.push(`the Windows signing gate is missing ${token}`);
		}
	}
	if (!body.includes('ERGOPTI_RELEASE_PRERELEASE -ceq "true"')) {
		errors.push('only an explicit dev prerelease may omit every Windows signing secret');
	}
	// The release profile itself (`if: inputs.release`) is allowed; skipping the
	// step on the prerelease flag is not.
	if (/if:\s*\$\{\{[^\n]*prerelease/.test(body)) {
		errors.push('the Windows signing step must validate partial secret sets at runtime');
	}
}

const linuxBundleStep = releaseStep('Package the installable bundle', LINUX_BOX);
if (linuxBundleStep !== null && /tar -tzf[^\n|]*\|\s*head(?:\s|$)/.test(linuxBundleStep)) {
	errors.push(
		'the Linux release must not pipe tar into head under pipefail (tar exits on SIGPIPE)'
	);
}

// The package metadata used to be logged by the per-format CI jobs, so a wrong
// control field or %files stanza showed without a Debian or Fedora box. The
// same pipefail trap applies: rpm listing into head fails a good listing.
const linuxMetadataStep = releaseStep('Log the package metadata', LINUX_BOX);
if (linuxMetadataStep !== null) {
	for (const token of ['dpkg-deb --info', 'rpm -qip', 'rpm -qlp']) {
		if (!linuxMetadataStep.includes(token)) {
			errors.push(`the Linux packages must log their metadata: ${token}`);
		}
	}
	if (/\|\s*head(?:\s|$)/.test(linuxMetadataStep)) {
		errors.push('the Linux package metadata must not be piped into head under pipefail');
	}
}

const macosSmokeStep = releaseStep(
	'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
	MACOS_BOX
);
if (macosSmokeStep !== null) {
	for (const token of [
		'python3 tools/diagnostics/macos_release_launch_test.py',
		'ditto -x -k build/macos/ErgoptiPlus.app.zip /Applications',
		'python3 tools/diagnostics/macos-release-launch.py /Applications/ErgoptiPlus.app'
	]) {
		if (!macosSmokeStep.includes(token)) {
			errors.push(`the macOS smoke test must exercise the extracted package: ${token}`);
		}
	}
}

// The zip is smoked, then signed, and the appcast embeds that signature; the
// upload must follow every file it carries. A signature or keylayout step
// moved past the upload leaves its file out, and the release preflight then
// stops the whole release after every box has run.
const MACOS_ORDER = [
	'Build ErgoptiPlus.app',
	'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
	'Install Sparkle signing tool',
	'Sign zip with Sparkle EdDSA key',
	'Generate Sparkle appcast',
	'Upload the package'
];
const packageMacosSteps = pipeline
	.steps(pipeline.job(PACKAGE_JOB[MACOS_BOX]))
	.map((candidate) => candidate.name);
const macosOrder = MACOS_ORDER.map((name) => packageMacosSteps.indexOf(name));
if (macosOrder.some((at, index) => at < 0 || (index > 0 && at <= macosOrder[index - 1]))) {
	errors.push(
		`${PACKAGE_JOB[MACOS_BOX]} must run ${MACOS_ORDER.join(' < ')}; got: ${packageMacosSteps.join(' | ')}`
	);
}
if (
	!(
		packageMacosSteps.indexOf('Package latest keylayout bundle') >= 0 &&
		packageMacosSteps.indexOf('Package latest keylayout bundle') <
			packageMacosSteps.indexOf('Upload the package')
	)
) {
	errors.push(
		`${PACKAGE_JOB[MACOS_BOX]} must package the keylayout bundle before it uploads the macOS package`
	);
}

// package-macos builds on every run and adds these steps on a release. Each
// must run on every release: the smoke is the only macOS 26 launch, and a
// skipped keylayout step drops Ergopti_macOS.zip without any upload error. The
// startup evidence is kept even when the smoke fails, which is when it matters.
for (const [name, condition] of [
	['Smoke test built ErgoptiPlus.app (crash-on-launch guard)', 'inputs.release'],
	['Retain packaged application startup evidence', 'always() && inputs.release'],
	['Install Sparkle signing tool', 'inputs.release'],
	['Sign zip with Sparkle EdDSA key', 'inputs.release'],
	['Generate Sparkle appcast', 'inputs.release'],
	['Package latest keylayout bundle', 'inputs.release']
]) {
	const body = releaseStep(name, MACOS_BOX);
	if (body === null) continue;
	const actual = pipeline.stepField(body, 'if');
	if (actual !== condition) {
		errors.push(
			`the macOS release step '${name}' must run exactly if: ${condition}, got: ${actual}`
		);
	}
	if (pipeline.stepField(body, 'continue-on-error') !== null) {
		errors.push(`the macOS release step '${name}' must not set continue-on-error`);
	}
}

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
