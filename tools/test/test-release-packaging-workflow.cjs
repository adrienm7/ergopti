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
			'if (-not $proc.HasExited -or $crashedEarly -or -not $markerSeen -or $dialogSeen) {'
		);
		if (
			!/^throw\s/.test(
				verdict
					.slice(1, -1)
					.map((line) => line.trim())
					.filter(Boolean)
					.at(-1) ?? ''
			)
		) {
			errors.push(
				'the Windows exe smoke must end its failed readiness branch with an unconditional throw'
			);
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
const WINDOWS_SMOKE_VERDICT =
	'if (-not $proc.HasExited -or $crashedEarly -or -not $markerSeen -or $dialogSeen) {';
const WINDOWS_SMOKE_WAIT_OPENER = 'while ($clock.Elapsed.TotalSeconds -lt $hangBoundSeconds) {';
// Process completion and a dialog end the wait. The extraction marker is
// diagnostic only: its presence cannot prove input/menu readiness.
const WINDOWS_SMOKE_WAIT_EXITS = [
	'if ($proc.HasExited) { break }',
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
				`the Windows exe smoke wait must end only on process exit or a dialog: ` +
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
		const lastStatement = verdict
			.slice(1, -1)
			.map((line) => line.trim())
			.filter(Boolean)
			.at(-1);
		if (!/^throw\s/.test(lastStatement ?? '')) {
			problems.push('the failed readiness verdict must end with an unconditional throw');
		}
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
			'an extraction marker admitted before readiness',
			(lines) =>
				lines.map((line) =>
					line.replace(
						'if (Test-Path -LiteralPath $markerFile) { $markerSeen = $true }',
						'if (Test-Path -LiteralPath $markerFile) { $markerSeen = $true; break }'
					)
				)
		],
		[
			'a failure without a failing process status',
			(lines) =>
				lines.filter(
					(line) =>
						!line.trimStart().startsWith('throw "ErgoptiPlus.exe did not complete native readiness')
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
		'node tools/build/macos-release-archives.cjs --ci-install',
		'python3 tools/diagnostics/macos-release-launch.py /Applications/ErgoptiPlus.app'
	]) {
		if (!macosSmokeStep.includes(token)) {
			errors.push(`the macOS smoke test must exercise the extracted package: ${token}`);
		}
	}
}

// NATIVE_SPARKLE_FIXTURE_BEGIN
/** The real keyless CI tool owner must be available before native XCTest. */
function nativeSparkleFixtureProblems(steps, fixture) {
	const problems = [];
	const install = steps.filter((step) => step.name === 'Install Sparkle signing tool');
	const tests = steps.filter((step) => step.name === 'Run Swift launcher tests');
	if (
		install.length !== 1 ||
		tests.length !== 1 ||
		steps.indexOf(install[0]) >= steps.indexOf(tests[0])
	)
		problems.push('The native Sparkle fixture needs exactly one installer before XCTest.');
	if (install.length === 1) {
		if (
			pipeline.stepField(install[0].body, 'if') !== null ||
			pipeline.stepField(install[0].body, 'continue-on-error') !== null
		)
			problems.push(
				'The public native signing tool must be installed unconditionally and strictly.'
			);
		for (const token of [
			"SPARKLE_VERSION: '2.9.2'",
			'curl -fsSLo /tmp/Sparkle.tar.xz',
			'tar -xJf /tmp/Sparkle.tar.xz -C /tmp/sparkle-dist',
			'SIGN_UPDATE=/tmp/sparkle-dist/bin/sign_update'
		]) {
			if (!install[0].body.includes(token))
				problems.push('The pinned native signing tool owner changed.');
		}
	}
	if (!fixture.includes('import Security'))
		problems.push('The native seed requires the actual Security owner.');
	const ownedFixture = fixture.slice(fixture.indexOf('private func privateSparkleChild('));
	for (const token of [
		'SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)',
		'[UInt8](repeating: 0, count: 32)',
		'attributes: [.posixPermissions: 0o600]',
		'.posixPermissions: 0o700',
		'try child(executable, arguments, root: root)',
		'guard fixtureCanRetire else',
		'guard testRun?.failureCount == failuresBefore else',
		'["node", owner.path, "sign", directory.path, signer, key.path]',
		'["--verify", "-f", key.path, payload.path, signature]',
		'["--verify", "-f", key.path, payload.path, signatures[1 - index]]',
		'["--verify", "-f", key.path, modified.path, signatures[index]]',
		'changed[changed.startIndex] ^= 1',
		'XCTAssertEqual(crossed.status, 1',
		'XCTAssertEqual(refused.status, 1',
		'Error: failed to pass signing verification.',
		'XCTAssertEqual(stillOwned.status, 0',
		'XCTAssertEqual(decoded.count, 64)',
		'XCTAssertEqual(signatures[0].count, signatures[1].count)',
		'XCTAssertEqual(try Data(contentsOf: payload), before[index])'
	]) {
		if (!ownedFixture.includes(token))
			problems.push('The actual private native signing fixture lost an owned control.');
	}
	return problems;
}
const nativeSparkleFixturePath = path.join(
	root,
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ReleaseArchiveStagingTests.swift'
);
const nativeSparkleFixture = fs.readFileSync(nativeSparkleFixturePath, 'utf8');
const nativeSparkleSteps = pipeline.steps(pipeline.job(PACKAGE_JOB[MACOS_BOX]));
errors.push(...nativeSparkleFixtureProblems(nativeSparkleSteps, nativeSparkleFixture));
// Portable controls prove the actual CI prerequisite and control guards only;
// actual Sparkle cryptography and child retirement remain macOS XCTest work.
const nativeSparkleControls = [
	['installed prerequisite', nativeSparkleSteps, nativeSparkleFixture, false],
	[
		'release-only installer',
		nativeSparkleSteps.map((step) =>
			step.name === 'Install Sparkle signing tool'
				? {
						...step,
						body: step.body.replace(/^ {8}if:.*\n/gm, '') + '\n        if: inputs.release\n'
					}
				: step
		),
		nativeSparkleFixture,
		true
	],
	[
		'missing installer',
		nativeSparkleSteps.filter((step) => step.name !== 'Install Sparkle signing tool'),
		nativeSparkleFixture,
		true
	],
	[
		'late installer',
		[
			...nativeSparkleSteps.filter((step) => step.name !== 'Install Sparkle signing tool'),
			...nativeSparkleSteps.filter((step) => step.name === 'Install Sparkle signing tool')
		],
		nativeSparkleFixture,
		true
	],
	[
		'duplicate installer',
		[
			...nativeSparkleSteps,
			...nativeSparkleSteps.filter((step) => step.name === 'Install Sparkle signing tool')
		],
		nativeSparkleFixture,
		true
	],
	[
		'unpinned tool',
		nativeSparkleSteps.map((step) => ({
			...step,
			body: step.body.replace("SPARKLE_VERSION: '2.9.2'", "SPARKLE_VERSION: 'unqualified'")
		})),
		nativeSparkleFixture,
		true
	],
	[
		'crossed signature removed',
		nativeSparkleSteps,
		nativeSparkleFixture.replace(
			'payload.path, signatures[1 - index]',
			'payload.path, signatures[index]'
		),
		true
	],
	[
		'private key flag removed',
		nativeSparkleSteps,
		nativeSparkleFixture.replace(
			'["--verify", "-f", key.path, payload.path, signature]',
			'["--verify", key.path, payload.path, signature]'
		),
		true
	],
	[
		'byte mutation removed',
		nativeSparkleSteps,
		nativeSparkleFixture.replace(
			'changed[changed.startIndex] ^= 1',
			'changed[changed.startIndex] ^= 0'
		),
		true
	],
	[
		'retirement debt bypassed',
		nativeSparkleSteps,
		nativeSparkleFixture.replace(
			'private func privateSparkleRetire(_ root: URL) {\n\t\tguard fixtureCanRetire else',
			'private func privateSparkleRetire(_ root: URL) {\n\t\tguard true else'
		),
		true
	]
];
for (const [name, steps, fixture, refuses] of nativeSparkleControls) {
	if (nativeSparkleFixtureProblems(steps, fixture).length > 0 !== refuses)
		errors.push(`Native Sparkle fixture prerequisite control failed: ${name}`);
}
// NATIVE_SPARKLE_FIXTURE_END

// The preferred archive is smoked, then declared archives are signed; the
// upload must follow every file it carries. A signature or keylayout step
// moved past the upload leaves its file out, and the release preflight then
// stops the whole release after every box has run.
const MACOS_ORDER = [
	'Install Sparkle signing tool',
	'Run Swift launcher tests',
	'Build ErgoptiPlus.app',
	'Record signed CI archive source',
	'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
	'Sign declared archives with Sparkle EdDSA key',
	'Generate Sparkle appcast',
	'Upload the independent CI archive source',
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
	['Install Sparkle signing tool', null],
	['Sign declared archives with Sparkle EdDSA key', 'inputs.release'],
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

/** Negative launch evidence must survive the original strict native verdict. */
function windowsFailureEvidenceProblems(smoke, upload) {
	const problems = [];
	if (pipeline.stepField(upload, 'if') !== 'always()') {
		problems.push('Windows launch evidence must upload on success or failure with always()');
	}
	if (pipeline.stepField(upload, 'continue-on-error') !== null) {
		problems.push('Windows launch evidence must not forgive publication failure');
	}
	if (
		pipeline.stepField(upload, 'uses') !== 'actions/upload-artifact@v4' ||
		!/^ {10}path: \$\{\{ runner\.temp \}\}\/evidence\.json$/m.test(upload) ||
		!/^ {10}if-no-files-found: error$/m.test(upload)
	) {
		problems.push(
			'Windows launch evidence must retain only its exact owned JSON and refuse absence'
		);
	}
	try {
		const code = (pipeline.runOf(smoke) ?? []).filter((line) => !line.trimStart().startsWith('#'));
		const trimmed = code.map((line) => line.trim());
		const initial = pipeline.scriptBlock(code, '$startupEvidence = [ordered]@{');
		for (const statement of [
			"failures = @('startup_incomplete')",
			"failure_phase = 'probe_setup'",
			'package_sha256 = $null',
			'readiness_acknowledged = $false',
			'native_exit_code = $null',
			'native_descendant_observations = @()'
		]) {
			if (!initial.some((line) => line.trim() === statement)) {
				problems.push(`Windows incomplete startup evidence lost ${statement}`);
			}
		}
		const save = pipeline.scriptBlock(code, 'function Save-StartupFailureEvidence');
		if (
			!save.some(
				(line) =>
					line.trim() ===
					'$startupEvidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$env:RUNNER_TEMP/evidence.json" -Encoding utf8'
			)
		) {
			problems.push('Windows startup failure evidence must persist its owned bounded JSON');
		}
		if (
			!save.some((line) =>
				line.includes(
					"Write-Warning 'Startup failure evidence publication failed (detail omitted).' -WarningAction Continue"
				)
			)
		) {
			problems.push('Windows startup failure evidence must retain the primary native error');
		}
		if (save.some((line) => /Exception\.Message|CommandLine|\$stdout|\$stderr/.test(line))) {
			problems.push('Windows startup failure publication must not expose raw private output');
		}
		const firstSave = trimmed.indexOf('Save-StartupFailureEvidence');
		const probeSetup = trimmed.findIndex((line) => line.startsWith('Add-Type '));
		const spawn = trimmed.findIndex((line) => line.startsWith('$proc = Start-Process '));
		if (
			firstSave < 0 ||
			probeSetup < 0 ||
			spawn < 0 ||
			firstSave >= probeSetup ||
			probeSetup >= spawn
		) {
			problems.push(
				'Windows negative startup evidence must be fresh before probe setup and compiled spawn'
			);
		}
		const parent = pipeline.scriptBlock(code, 'if ($launchOwner.identity_qualified) {');
		if (
			!parent.some(
				(line) =>
					line.trim() ===
					'$startupEvidence.native_parent.observed_executable = $launchOwner.expected_executable'
			)
		) {
			problems.push('Windows failure evidence must disclose only the qualified owned executable');
		}
		for (const statement of [
			'$startupEvidence.native_parent.pid = $launchOwner.pid',
			'$startupEvidence.native_parent.start_utc = $launchOwner.start_utc',
			'$startupEvidence.native_parent.identity_qualified = $launchOwner.identity_qualified',
			'pid = $receipt.pid',
			'parent_pid = $receipt.parent_pid',
			'created_utc = $receipt.created_utc',
			'lineage_qualified = $receipt.lineage_qualified',
			'same_executable = $receipt.same_executable',
			'depth = $receipt.depth'
		]) {
			if (!trimmed.includes(statement))
				problems.push(`Windows closed native observation lost ${statement}`);
		}
		if (
			trimmed.some((line) =>
				/\$startupEvidence.*(?:CommandLine|\.Exception\.Message|\$tail|\$stdout|\$stderr|ready\s*=\s*\$true)/.test(
					line
				)
			)
		) {
			problems.push('Windows failure evidence must not copy private output or authorize readiness');
		}
		const failure = pipeline.scriptBlock(code, WINDOWS_SMOKE_VERDICT).map((line) => line.trim());
		const saves = failure
			.map((line, index) => (line === 'Save-StartupFailureEvidence' ? index : -1))
			.filter((index) => index >= 0);
		const diagnostics = failure.indexOf('Write-LaunchDiagnostics $proc $seconds $stagingSeconds');
		const stop = failure.indexOf('Stop-LaunchedApp $proc');
		const error = failure.findIndex((line) => line.startsWith('Write-Error '));
		if (
			saves.length !== 2 ||
			diagnostics < 0 ||
			stop < 0 ||
			error < 0 ||
			saves[0] >= diagnostics ||
			saves[1] <= stop ||
			saves[1] >= error
		) {
			problems.push(
				'Windows failure receipt must precede diagnostics and retain observations before its original error'
			);
		}
		for (const statement of [
			"$startupEvidence.failures = @('startup_guard_failed')",
			"$startupEvidence.failure_phase = 'verdict'",
			'$startupEvidence.marker_seen = $markerSeen',
			'$startupEvidence.crashed_early = $crashedEarly',
			'$startupEvidence.native_exit_code = $exitCode',
			'$startupEvidence.elapsed_seconds = [math]::Round($seconds, 3)',
			'$startupEvidence.staging_seconds = $stagingSeconds',
			'$startupEvidence.dialog_seen = $dialogSeen'
		]) {
			if (!failure.includes(statement))
				problems.push(`Windows failed startup evidence lost ${statement}`);
		}
	} catch (error) {
		problems.push(`Windows startup failure evidence is absent or ambiguous: ${error.message}`);
	}
	return problems;
}

let windowsLaunchUpload = null;
try {
	const found = pipeline.findStep('Upload mandatory launch evidence');
	if (found.file !== WINDOWS_BOX || found.job !== 'launch-windows') {
		errors.push('Windows mandatory launch evidence must belong to its actual launch job');
	} else windowsLaunchUpload = found.body;
} catch (error) {
	errors.push(`Windows mandatory launch evidence is missing: ${error.message}`);
}
if (windowsSmokeStep !== null && windowsLaunchUpload !== null) {
	errors.push(...windowsFailureEvidenceProblems(windowsSmokeStep, windowsLaunchUpload));
	for (const [name, before, after, target] of [
		['implicit success upload', '        if: always()\n', '', 'upload'],
		['conditional failure upload', '        if: always()\n', '        if: failure()\n', 'upload'],
		['conditional success upload', '        if: always()\n', '        if: success()\n', 'upload'],
		[
			'forgiven evidence publication',
			'        uses: actions/upload-artifact@v4',
			'        continue-on-error: true\n        uses: actions/upload-artifact@v4',
			'upload'
		],
		[
			'unowned raw payload upload',
			'${{ runner.temp }}/evidence.json',
			'${{ runner.temp }}/*',
			'upload'
		],
		[
			'success-only evidence',
			'          Save-StartupFailureEvidence\n\n          # Compiled',
			'\n          # Compiled',
			'smoke'
		],
		[
			'positive incomplete receipt',
			"failures = @('startup_incomplete')",
			'failures = @()',
			'smoke'
		],
		['lost failure publication', '              Save-StartupFailureEvidence\n', '', 'smoke'],
		[
			'guessed parent qualification',
			'$startupEvidence.native_parent.identity_qualified = $launchOwner.identity_qualified',
			'$startupEvidence.native_parent.identity_qualified = $true',
			'smoke'
		],
		[
			'lost native exit',
			'$startupEvidence.native_exit_code = $exitCode',
			'$startupEvidence.native_exit_code = 0',
			'smoke'
		],
		[
			'copied foreign executable',
			'$startupEvidence.native_parent.observed_executable = $launchOwner.expected_executable',
			'$startupEvidence.native_parent.observed_executable = $actualLaunchPath',
			'smoke'
		],
		['private argv receipt', 'pid = $receipt.pid', 'pid = $receipt.CommandLine', 'smoke'],
		[
			'private publication exception',
			"Write-Warning 'Startup failure evidence publication failed (detail omitted).'",
			'Write-Warning $_.Exception.Message',
			'smoke'
		],
		[
			'claimed readiness',
			'readiness_acknowledged = $false',
			'readiness_acknowledged = $true',
			'smoke'
		]
	]) {
		const original = target === 'upload' ? windowsLaunchUpload : windowsSmokeStep;
		const changed = original.replaceAll(before, after);
		const problems =
			target === 'upload'
				? windowsFailureEvidenceProblems(windowsSmokeStep, changed)
				: windowsFailureEvidenceProblems(changed, windowsLaunchUpload);
		if (changed === original || problems.length === 0)
			errors.push(`Windows failure-artifact guard missed ${name}`);
	}
}

// The actual aggregate must reject incomplete/failed receipts even if a caller
// incorrectly supplies green jobs or observes a same-executable descendant.
{
	const assert = require('node:assert/strict');
	const desktop = require('./desktop-ci-evidence.cjs');
	const needs = Object.fromEntries(
		['test-ahk', 'e2e-ahk', 'package-windows', 'launch-windows'].map((name) => [
			name,
			{ result: 'success' }
		])
	);
	const sha = 'a'.repeat(40);
	const positive = {
		schema_version: 1,
		platform: 'windows',
		sha,
		runner: 'windows-latest',
		scenario: 'startup',
		package_sha256: 'b'.repeat(64),
		marker_seen: true,
		crashed_early: false,
		marker_seconds: 1,
		failures: [],
		native_startup: {
			nonce: 'c'.repeat(32),
			pid: 42,
			executable: 'C:\\private\\ErgoptiPlus.exe',
			launched_sha256: 'b'.repeat(64),
			exit_code: 0,
			log_files: 1,
			logged_errors: [],
			receipt: {
				schema_version: 1,
				nonce: 'c'.repeat(32),
				pid: 42,
				executable: 'C:\\private\\ErgoptiPlus.exe',
				compiled: true,
				build_commit: sha,
				bundle_identity: '0.0.0-dev\n' + sha,
				phase: 'ready',
				driver_ready: true,
				menu_ready: true,
				logs_flushed: true
			}
		}
	};
	// Independent authored observations, including the authenticated historical
	// release and two current-process full saves. Never ask the producer to make
	// its own positive expectation or borrow ready as a save acknowledgment.
	positive.compiled_upgrade = {
		schema_version: 1,
		prior_install: {
			package_sha256: '210d737ab9ebb9a65d54d98aafe05cba78fe961de00e75cce660ce0067b09caf',
			asset_id: 601771276,
			version: '0.0.0-dev.155',
			commit: 'c9e4c64abb6448243252201dffec0c248e2c24ac',
			bundle_identity: '0.0.0-dev.155',
			pid: 20,
			executable: 'C:\\private\\prior\\ErgoptiPlus.exe',
			created_utc: '2026-10-07T12:00:00.0000000Z',
			exit_code: 0,
			tree_closed: true,
			native_profile_before_edit: {
				sha256: '4'.repeat(64),
				schema_version: 6,
				metrics_enabled: false,
				metrics_shortcut_typing: 'Ctrl+Alt+M',
				metrics_shortcut_apps: 'Ctrl+Alt+A',
				future_dashboard: { keep: 9, enabled: false },
				source_records_observed: 1
			},
			installed_user_edit: {
				schema_version: 1,
				contract: 'offline-installed-user-edit',
				before_sha256: '4'.repeat(64),
				after_sha256: '9'.repeat(64),
				untouched_before_sha256: '6'.repeat(64),
				untouched_after_sha256: '6'.repeat(64),
				profile_schema_version: 6,
				preserved_records: 5,
				changed: true
			},
			saved_profile: { sha256: '9'.repeat(64), preserved_records: 5, schema_version: 6 },
			extracted_assets: [
				{
					path: 'static/ergopti_plus/_shared/core/config_schema/migrations.toml',
					bytes: 33897,
					sha256: '39b35d65f2c3e2dc01a2c32f762b56ec8b16aaff55495d86d12529ab298b4bf4'
				},
				{
					path: 'static/ergopti_plus/_shared/data/locales/en.json',
					bytes: 209494,
					sha256: 'eaff8ce0e2bb4d7ec539ad92dc77067b5c740e9eedf4c5e698d7ddad51659e43'
				}
			]
		},
		launches: [0, 1].map((index) => {
			const nonce = (index === 0 ? 'd' : 'e').repeat(32);
			const pid = 43 + index;
			const native_startup = structuredClone(positive.native_startup);
			native_startup.nonce = native_startup.receipt.nonce = nonce;
			native_startup.pid = native_startup.receipt.pid = pid;
			return {
				native_startup,
				created_utc: `2026-10-07T12:00:0${index + 1}.0000000Z`,
				full_save: {
					schema_version: 1,
					nonce,
					pid,
					executable: 'C:\\private\\ErgoptiPlus.exe',
					compiled: true,
					build_commit: sha,
					bundle_identity: '0.0.0-dev\n' + sha,
					requested: 3,
					committed: 3,
					settled: 3,
					pending: false
				},
				tree_closed: true,
				wal_absent: true,
				bundle_workspace_absent: true,
				saved_profile: {
					sha256: (index === 0 ? 'f' : '8').repeat(64),
					preserved_records: 5,
					schema_version: 12
				}
			};
		})
	};
	const verify = (record, jobs = needs) =>
		desktop.verify({
			platform: 'windows',
			needs: jobs,
			evidence: [record],
			sha,
			scenarios: [],
			release: false
		});
	assert.doesNotThrow(() => verify(positive), 'the complete successful receipt still passes');
	const missingUpgrade = structuredClone(positive);
	delete missingUpgrade.compiled_upgrade;
	assert.throws(
		() => verify(missingUpgrade),
		/Missing compiled upgrade evidence/,
		'green jobs and fresh readiness cannot replace mandatory installed-upgrade evidence'
	);
	const uncommittedUpgrade = structuredClone(positive);
	uncommittedUpgrade.compiled_upgrade.launches[1].full_save.committed = 2;
	assert.throws(
		() => verify(uncommittedUpgrade),
		/Full save is uncommitted/,
		'a settled warm launch cannot replace its committed full-save generation'
	);
	const foreignPriorUpgrade = structuredClone(positive);
	foreignPriorUpgrade.compiled_upgrade.prior_install.package_sha256 = '7'.repeat(64);
	assert.throws(
		() => verify(foreignPriorUpgrade),
		/Prior package is not the trusted release/,
		'complete startup and save observations cannot authenticate a foreign prior package'
	);
	const missingReadiness = structuredClone(positive);
	const missingEditBoundary = structuredClone(positive);
	delete missingEditBoundary.compiled_upgrade.prior_install.installed_user_edit;
	assert.throws(
		() => verify(missingEditBoundary),
		/Missing offline installed-user edit boundary/,
		'old ready and current saves cannot replace an admitted installed-user boundary'
	);
	const damagedUnrelatedSource = structuredClone(positive);
	damagedUnrelatedSource.compiled_upgrade.prior_install.installed_user_edit.untouched_after_sha256 =
		'5'.repeat(64);
	assert.throws(
		() => verify(damagedUnrelatedSource),
		/Offline edit lost unrelated native bytes/,
		'the setup cannot repair comment loss by replacing the observed installed profile'
	);
	delete missingReadiness.native_startup;
	assert.throws(
		() => verify(missingReadiness),
		/Missing native Windows readiness evidence/,
		'an extraction marker cannot replace the native readiness receipt'
	);
	for (const record of [
		{
			...positive,
			marker_seen: false,
			crashed_early: null,
			failures: ['startup_incomplete'],
			failure_phase: 'probe_setup',
			native_exit_code: null
		},
		{
			...positive,
			marker_seen: false,
			crashed_early: true,
			failures: ['startup_guard_failed'],
			native_exit_code: 0,
			native_descendant_observations: [
				{ pid: 2, parent_pid: 1, lineage_qualified: true, same_executable: true }
			],
			readiness_acknowledged: false
		},
		{ ...positive, marker_seen: false, dialog_seen: true, failures: ['startup_guard_failed'] },
		{ ...positive, marker_seen: false, elapsed_seconds: 120, failures: ['startup_guard_failed'] },
		{
			...positive,
			marker_seen: false,
			crashed_early: true,
			failures: [],
			native_descendant_observations: [{ lineage_qualified: true, same_executable: true }],
			readiness_acknowledged: true
		},
		{ ...positive, package_sha256: null, marker_seen: false, failures: ['startup_incomplete'] }
	])
		assert.throws(
			() => verify(record),
			'actual mandatory aggregate refuses failed/incomplete native observations'
		);
	assert.throws(
		() => verify(positive, { ...needs, 'launch-windows': { result: 'failure' } }),
		/launch-windows did not succeed/,
		'an artifact cannot override the original failed launch job'
	);
}

// CI_ARCHIVE_WORKFLOW_TESTS_BEGIN
{
	const assert = require('node:assert/strict');
	const ownerPipeline = require('./ci-pipeline.cjs');
	/** Require the consumed CI policy, separate source authority and installed evidence. */
	function ciArchiveWorkflowProblems(text) {
		const problems = [];
		const jobs = ownerPipeline.jobsOfText(text);
		const job = (id) => {
			const matches = jobs.filter((candidate) => candidate.id === id);
			assert.equal(matches.length, 1);
			return matches[0].body;
		};
		const packageJob = job('package-macos'),
			launchJob = job('launch');
		const step = (body, name) => ownerPipeline.step(body, name);
		const script = (body, name) => ownerPipeline.runOf(step(body, name)).join('\n');
		const packageSteps = ownerPipeline.steps(packageJob).map((candidate) => candidate.name);
		const ordered = [
			'Build ErgoptiPlus.app',
			'Record signed CI archive source',
			'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
			'Upload the independent CI archive source',
			'Upload the package'
		];
		if (
			ordered.some(
				(name, index) =>
					packageSteps.indexOf(name) < 0 ||
					(index > 0 && packageSteps.indexOf(name) <= packageSteps.indexOf(ordered[index - 1]))
			)
		)
			problems.push('source_order');
		const source = step(packageJob, 'Record signed CI archive source');
		if (
			ownerPipeline.stepField(source, 'if') !== null ||
			ownerPipeline.stepField(source, 'continue-on-error') !== null ||
			!script(packageJob, 'Record signed CI archive source')
				.replace(/\s+/g, ' ')
				.includes('--ci-receipt "$PWD/build/macos/ErgoptiPlus.app" "$PWD/build/macos"')
		)
			problems.push('source_owner');
		const smoke = script(packageJob, 'Smoke test built ErgoptiPlus.app (crash-on-launch guard)');
		if (
			!smoke.includes('--ci-install "$PWD/build/macos" /Applications') ||
			smoke.includes('ditto -x -k') ||
			!smoke.includes('test ! -e /Applications/ErgoptiPlus.app')
		)
			problems.push('package_install');
		const sourceUpload = step(packageJob, 'Upload the independent CI archive source');
		if (
			!sourceUpload.includes('name: ci-macos-archive-source') ||
			!sourceUpload.includes('if-no-files-found: error') ||
			!sourceUpload.includes('path: build/macos/ErgoptiPlus.app.ci-receipt.json') ||
			step(packageJob, 'Upload the package').includes('.ci-receipt.json')
		)
			problems.push('ci_only_authority');
		const sourceDownload = step(launchJob, 'Download the independent CI archive source');
		if (
			!sourceDownload.includes('name: ci-macos-archive-source') ||
			!sourceDownload.includes('path: ${{ runner.temp }}/package')
		)
			problems.push('source_download');
		const launchSteps = ownerPipeline.steps(launchJob).map((candidate) => candidate.name);
		if (
			launchSteps.indexOf('Download the independent CI archive source') >=
			launchSteps.indexOf('Install the package the way a user does')
		)
			problems.push('download_order');
		const install = script(launchJob, 'Install the package the way a user does');
		if (
			!install.includes('--ci-install "$RUNNER_TEMP/package" /Applications "$stamp"') ||
			install.includes('ditto -x -k') ||
			!install.includes(
				"process.stdout.write('MACOS_INSTALL_ARCHIVE=' + receipt.archive + '\\n')"
			) ||
			!install.includes('test ! -e /Applications/ErgoptiPlus.app')
		)
			problems.push('launch_install');
		const evidence = script(launchJob, 'Record mandatory launch evidence');
		if (!evidence.includes('"$MACOS_INSTALL_ARCHIVE"') || evidence.includes('ErgoptiPlus.app.zip'))
			problems.push('installed_evidence');
		return problems;
	}
	const workflow = ownerPipeline.file('.github/workflows/ci-macos.yml');
	assert.deepEqual(ciArchiveWorkflowProblems(workflow), []);
	const faults = [
		[
			'source_owner',
			'"$PWD/build/macos/ErgoptiPlus.app" "$PWD/build/macos"',
			'"$PWD/build/macos/Foreign.app" "$PWD/build/macos"'
		],
		[
			'package_install',
			'--ci-install "$PWD/build/macos" /Applications',
			'ditto -x -k build/macos/ErgoptiPlus.app.zip /Applications'
		],
		[
			'launch_install',
			'--ci-install "$RUNNER_TEMP/package" /Applications "$stamp"',
			'ditto -x -k "$zip" /Applications'
		],
		[
			'installed_evidence',
			'"$MACOS_INSTALL_ARCHIVE"',
			'"$RUNNER_TEMP/package/ErgoptiPlus.app.zip"'
		],
		[
			'source_download',
			'name: ci-macos-archive-source\n          path: ${{ runner.temp }}/package',
			'name: foreign-source\n          path: ${{ runner.temp }}/package'
		],
		[
			'ci_only_authority',
			'path: build/macos/ErgoptiPlus.app.ci-receipt.json',
			'path: build/macos/foreign.json'
		]
	];
	for (const [expected, before, after] of faults) {
		assert.ok(workflow.includes(before), expected + ' mutation must change the actual source');
		assert.ok(
			ciArchiveWorkflowProblems(workflow.replace(before, after)).includes(expected),
			expected
		);
	}
	console.log(`CI installed-archive workflow cases: ${faults.length + 1}`);
}
// CI_ARCHIVE_WORKFLOW_TESTS_END

// CI_ARCHIVE_OWNED_TESTS_BEGIN
{
	const assert = require('node:assert/strict');
	const os = require('node:os');
	const {
		ArchiveContractFilesystem,
		loadArchiveProducer,
		verifyArchiveFilesystemModel
	} = require('./fixtures/archive-contract-filesystem.cjs');
	const producerPath = path.resolve(__dirname, '../build/macos-release-archives.cjs');
	const defaultsBytes = fs.readFileSync(
		require('../lib/paths.cjs').shared('modules/updater/defaults.json'),
		'utf8'
	);
	function verifyCIArchiveOwnedContracts(fs, owner) {
		const defaults = JSON.parse(defaultsBytes);
		const bindings = owner.resolveArchives(defaults);
		const basename = bindings[0].name.slice(0, -'.tar.xz'.length);
		let cases = 0;
		const fixture = (body) => {
			const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-archive-owned-'));
			try {
				const app = path.join(root, basename),
					input = path.join(root, 'archives'),
					destination = path.join(root, 'installed');
				for (const dir of [app, input, destination]) fs.mkdirSync(dir);
				fs.writeFileSync(path.join(app, 'independent.txt'), 'Independent source bytes: café\n', {
					mode: 0o751
				});
				fs.symlinkSync('independent.txt', path.join(app, 'relative-link'));
				for (const item of bindings)
					fs.writeFileSync(path.join(input, item.name), Buffer.from('source-' + item.format));
				const calls = [];
				let fault;
				const execute = (executable, args) => {
					calls.push({ executable, args: [...args] });
					if (fault) {
						const reason = fault(executable, args);
						if (reason) throw Error(reason);
					}
					if (args[0] === '-d')
						return { stdout: '', stderr: '# designated => identifier "independent-source"\n' };
					if (executable.endsWith('/tar') || executable.endsWith('/ditto')) {
						const target = args.at(-1);
						fs.cpSync(app, path.join(target, basename), {
							recursive: true,
							verbatimSymlinks: true
						});
					}
					return { stdout: '', stderr: '' };
				};
				const options = { defaults, execute };
				const context = {
					app,
					input,
					destination,
					calls,
					options,
					setFault: (value) => {
						fault = value;
					},
					receipt: path.join(input, basename + '.ci-receipt.json')
				};
				body(context);
				cases++;
			} finally {
				fs.rmSync(root, { recursive: true });
			}
		};
		fixture((c) => {
			owner.createCIReceipt(c.app, c.input, c.options);
			const receipt = JSON.parse(fs.readFileSync(c.receipt));
			assert.equal(receipt.requirement, 'identifier "independent-source"');
			assert.equal(c.calls[0].executable, '/usr/bin/codesign');
			assert.deepEqual(c.calls[0].args.slice(0, 3), ['--verify', '--deep', '--strict']);
			const result = owner.installCIArchive(c.input, c.destination, c.options);
			assert.equal(
				result.format,
				'tar.xz',
				'the actual CI owner selects XZ instead of the old ZIP install'
			);
			assert.equal(path.basename(result.archive), bindings[0].name);
			assert.equal(fs.readFileSync(result.archive, 'utf8'), 'source-tar.xz');
			assert.equal(
				fs.readFileSync(path.join(c.destination, basename, 'independent.txt'), 'utf8'),
				'Independent source bytes: café\n'
			);
			assert.equal(
				fs.readlinkSync(path.join(c.destination, basename, 'relative-link')),
				'independent.txt'
			);
			const verifier = c.calls.find((call) => call.args.includes('-R'));
			assert.ok(verifier, 'the restored app must use the independent signed source requirement');
			assert.equal(verifier.args[verifier.args.indexOf('-R') + 1], '=' + receipt.requirement);
			assert.equal(c.calls.filter((call) => call.executable.endsWith('/ditto')).length, 0);
		});
		fixture((c) => {
			fs.unlinkSync(path.join(c.input, bindings[0].name));
			owner.createCIReceipt(c.app, c.input, c.options);
			assert.equal(owner.installCIArchive(c.input, c.destination, c.options).format, 'zip');
			assert.equal(c.calls.filter((call) => call.executable.endsWith('/tar')).length, 0);
		});
		fixture((c) => {
			owner.createCIReceipt(c.app, c.input, c.options);
			const result = owner.installCIArchive(c.input, c.destination, {
				...c.options,
				quarantine: 'controlled-quarantine'
			});
			const stamp = c.calls.find((call) => call.executable.endsWith('/xattr'));
			const extract = c.calls.find((call) => call.executable.endsWith('/tar'));
			assert.ok(stamp);
			assert.deepEqual(stamp.args, [
				'-w',
				'com.apple.quarantine',
				'controlled-quarantine',
				result.archive
			]);
			assert.ok(c.calls.indexOf(stamp) < c.calls.indexOf(extract));
		});
		fixture((c) => {
			owner.createCIReceipt(c.app, c.input, c.options);
			const before = c.calls.length;
			assert.throws(() =>
				owner.installCIArchive(c.input, c.destination, {
					...c.options,
					quarantine: 'invalid\nstamp'
				})
			);
			assert.equal(c.calls.length, before);
			assert.equal(
				fs.readdirSync(c.input).some((name) => name.startsWith('.ci-install-')),
				false
			);
		});
		for (const kind of ['empty', 'directory', 'symlink', 'digest', 'unrecorded'])
			fixture((c) => {
				owner.createCIReceipt(c.app, c.input, c.options);
				const preferred = path.join(c.input, bindings[0].name);
				if (kind === 'empty') fs.writeFileSync(preferred, '');
				if (kind === 'directory' || kind === 'symlink') fs.unlinkSync(preferred);
				if (kind === 'directory') fs.mkdirSync(preferred);
				if (kind === 'symlink') fs.symlinkSync(path.join(c.input, bindings[1].name), preferred);
				if (kind === 'digest') fs.writeFileSync(preferred, 'changed');
				if (kind === 'unrecorded') {
					const receipt = JSON.parse(fs.readFileSync(c.receipt));
					receipt.archives.shift();
					fs.writeFileSync(c.receipt, JSON.stringify(receipt));
				}
				const before = c.calls.length;
				assert.throws(() => owner.installCIArchive(c.input, c.destination, c.options));
				assert.equal(
					c.calls.length,
					before,
					'present refused XZ cannot acquire native extraction or fallback'
				);
				assert.equal(fs.existsSync(path.join(c.destination, basename)), false);
			});
		for (const kind of [
			'extract',
			'signature',
			'readback',
			'verified-bundle-race',
			'payload-race',
			'destination-race'
		])
			fixture((c) => {
				owner.createCIReceipt(c.app, c.input, c.options);
				let extracts = 0;
				c.setFault((executable, args) => {
					if (executable.endsWith('/tar')) {
						extracts++;
						if (kind === 'extract') return 'native extraction refused';
					}
					if (args.includes('-R')) {
						if (kind === 'signature') return 'native signing refused';
						if (kind === 'verified-bundle-race')
							fs.writeFileSync(
								path.join(args.at(-1), 'independent.txt'),
								'foreign after native verify'
							);
						if (kind === 'readback')
							fs.writeFileSync(path.join(c.app, 'independent.txt'), 'changed');
						if (kind === 'payload-race')
							fs.writeFileSync(
								c.calls.find((call) => call.executable.endsWith('/tar')).args[1],
								'changed after extraction'
							);
						if (kind === 'destination-race') fs.mkdirSync(path.join(c.destination, basename));
					}
					return null;
				});
				if (kind === 'readback')
					c.setFault((executable) => {
						if (executable.endsWith('/tar')) {
							extracts++;
							fs.writeFileSync(path.join(c.app, 'independent.txt'), 'changed');
						}
						return null;
					});
				assert.throws(() => owner.installCIArchive(c.input, c.destination, c.options));
				assert.equal(extracts, 1);
				assert.equal(c.calls.filter((call) => call.executable.endsWith('/ditto')).length, 0);
				assert.equal(
					fs.readdirSync(c.input).some((name) => name.startsWith('.ci-install-')),
					false
				);
				assert.equal(
					fs.existsSync(path.join(c.destination, basename)),
					kind === 'destination-race',
					'an independently acquired destination survives the refused install'
				);
			});
		for (const kind of [
			'missing',
			'malformed',
			'foreign-bundle',
			'unknown-fields',
			'duplicate-binding'
		])
			fixture((c) => {
				owner.createCIReceipt(c.app, c.input, c.options);
				const receipt = JSON.parse(fs.readFileSync(c.receipt));
				if (kind === 'missing') fs.unlinkSync(c.receipt);
				else {
					if (kind === 'foreign-bundle') receipt.bundle = 'Foreign.app';
					if (kind === 'unknown-fields') receipt.extra = true;
					if (kind === 'duplicate-binding') receipt.archives.push(receipt.archives[0]);
					fs.writeFileSync(c.receipt, kind === 'malformed' ? '[' : JSON.stringify(receipt));
				}
				const before = c.calls.length;
				assert.throws(() => owner.installCIArchive(c.input, c.destination, c.options));
				assert.equal(c.calls.length, before);
			});
		fixture((c) => {
			owner.createCIReceipt(c.app, c.input, c.options);
			const originalOpen = fs.openSync;
			let ownedRefusals = 0;
			let refused = false;
			try {
				fs.openSync = (filename, ...args) => {
					if (filename === path.join(c.input, bindings[0].name)) {
						ownedRefusals++;
						const error = Error('controlled read refusal');
						error.code = 'EACCES';
						throw error;
					}
					return originalOpen.call(fs, filename, ...args);
				};
				try {
					owner.installCIArchive(c.input, c.destination, c.options);
				} catch {
					refused = true;
				}
			} finally {
				fs.openSync = originalOpen;
			}
			assert.equal(refused, true);
			assert.equal(ownedRefusals, 1);
			assert.equal(
				c.calls.filter(
					(call) => call.executable.endsWith('/tar') || call.executable.endsWith('/ditto')
				).length,
				0
			);
			assert.equal(
				fs.readdirSync(c.input).some((name) => name.startsWith('.ci-install-')),
				false
			);
		});
		fixture((c) => {
			c.setFault(() => 'independent source signature refused');
			assert.throws(() => owner.createCIReceipt(c.app, c.input, c.options));
			assert.equal(fs.existsSync(c.receipt), false);
		});
		return cases;
	}
	verifyArchiveFilesystemModel(os.tmpdir());
	const model = new ArchiveContractFilesystem(os.tmpdir());
	const modelCases = verifyCIArchiveOwnedContracts(model, loadArchiveProducer(producerPath, model));
	assert.equal(model.descriptors.size, 0, 'every actual archive read retires its descriptor');
	assert.deepEqual(model.readdirSync(os.tmpdir()), [], 'every fixture retires its owned namespace');
	if (process.platform !== 'win32') {
		const physicalCases = verifyCIArchiveOwnedContracts(fs, require(producerPath));
		assert.equal(
			physicalCases,
			modelCases,
			'physical POSIX files exercise the same complete contract'
		);
	}
	console.log(`CI archive native-owner portable cases: ${modelCases}`);
}
// CI_ARCHIVE_OWNED_TESTS_END

// PUBLIC_MACOS_PUBLICATION_WIRING_BEGIN
// Fresh signing/feed/cask consumers all invoke the one canonical publication owner.
{
	const publication = require('../build/macos-release-publication.cjs');
	const job = pipeline.job('package-macos');
	const signer = pipeline
		.runOf(pipeline.step(job, 'Sign declared archives with Sparkle EdDSA key'))
		.join('\n');
	if (
		!signer.includes('node tools/build/macos-release-publication.cjs sign') ||
		!signer.includes('build/macos "$SIGN_UPDATE" /tmp/sparkle_priv.key')
	)
		errors.push(
			'the release signer must invoke the actual declared-archive owner with an explicit key file'
		);
	const appcast = pipeline.step(job, 'Generate Sparkle appcast');
	if (!appcast.includes('ARCHIVE_DIR: build/macos') || appcast.includes('ZIP_PATH:'))
		errors.push('fresh appcasts must consume the actual publication signing receipt');
	const upload = pipeline.step(job, 'Upload the package');
	if (
		!upload.includes(`build/macos/${publication.RECEIPT}`) ||
		!upload.includes('build/macos/_*.sig')
	)
		errors.push('the exact signing receipt and declared fragments must reach release preflight');
	const cask = pipeline.step(pipeline.job('release'), 'Publish Homebrew cask');
	if (
		!cask.includes('node tools/build/macos-release-publication.cjs download') ||
		!cask.includes('"$tap" "$archive"')
	)
		errors.push('the cask must receive the actual admitted published archive name and hash');
}
// PUBLIC_MACOS_PUBLICATION_WIRING_END

// PUBLISHED_ARCHIVE_POLICY_TESTS_BEGIN
// The published diagnostic consumes the producer's canonical archive bindings.
// Its current-build and retained-helper branches remain independent ZIP users.
function publishedArchiveWorkflowProblems(source) {
	const failures = [];
	const jobs = pipeline.jobsOfText(source, '.github/workflows/macos-release-launch.yml');
	const observe = jobs.find((job) => job.id === 'observe');
	if (!observe) return ['the published archive diagnostic must retain its observe job'];
	const download = pipeline.step(observe.body, 'Download and verify the published application');
	if (
		pipeline.stepField(download, 'if') !==
		"inputs.scenario == 'published' || inputs.scenario == 'published_with_dependency'"
	)
		failures.push('the published archive preference must remain scoped to published scenarios');
	const commands = pipeline.runOf(download)?.filter((line) => line.trim() !== '') ?? [];
	if (
		commands.length !== 2 ||
		commands[0] !== 'python3 tools/diagnostics/macos_release_launch_test.py' ||
		commands[1] !== 'python3 tools/diagnostics/macos-release-launch.py --install-published'
	)
		failures.push('the published download must qualify and invoke its actual archive helper');
	const observeLaunch = pipeline.step(
		observe.body,
		'Observe the installed release without a waiting open helper'
	);
	const launch = pipeline.runOf(observeLaunch) ?? [];
	if (
		!launch.includes(
			'python3 tools/diagnostics/macos-release-launch.py /Applications/ErgoptiPlus.app "$RUNNER_TEMP/release-launch"'
		)
	)
		failures.push('the installed published archive must retain the actual strict launch observer');
	return failures;
}
errors.push(
	...publishedArchiveWorkflowProblems(
		fs.readFileSync(path.join(root, '.github/workflows/macos-release-launch.yml'), 'utf8')
	)
);
// PUBLISHED_ARCHIVE_POLICY_TESTS_END

if (errors.length > 0) {
	console.error('[ERROR] Release packaging workflow is unsafe:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log('[OK] Release packaging stamps live sources and avoids pipefail/SIGPIPE traps.');
