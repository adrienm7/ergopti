// tools/test/test-macos-launcher-universal.cjs

/**
 * ==============================================================================
 * MODULE: macOS Launcher Architecture and Framework Guard
 * DESCRIPTION:
 * Regression guard for the host executable of ErgoptiPlus.app. The published
 * v0.0.0-dev.127 archive shipped Contents/MacOS/ErgoptiPlus as an arm64-only
 * Mach-O because build_macos_app.sh ran a plain `swift build`, which targets the
 * build host only (the Apple-silicon release runner). Every other executable
 * in the bundle (Hammerspoon, Sparkle, LuaSocket) is universal, so the CI launch
 * smoke test on arm64 stayed green while an Intel Mac refused to open the app
 * before the launcher could write a single log line.
 *
 * ROOT CAUSE ENCODED:
 * The launcher must be compiled for every architecture the embedded runtime
 * supports, and the build must fail fast when the produced binary lacks one.
 * This guard fails if the build or bin-path query drops an architecture, or if
 * the post-build lipo verification disappears. Framework assembly also replays
 * strict-shell discovery: a missing preferred SPM layout must reach the next
 * supported layout instead of aborting silently through grep under pipefail.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const build = fs.readFileSync(path.join(ROOT, 'tools/build/build_macos_app.sh'), 'utf8');

const REQUIRED_ARCHS = ['arm64', 'x86_64'];
const errors = [];

const archDeclaration = build.match(/^LAUNCHER_ARCHS=\(([^)]*)\)$/m);
if (!archDeclaration) {
	errors.push('build_macos_app.sh: LAUNCHER_ARCHS array declaration is missing.');
} else {
	const declared = archDeclaration[1].trim().split(/\s+/).sort();
	if (JSON.stringify(declared) !== JSON.stringify([...REQUIRED_ARCHS].sort())) {
		errors.push(
			`build_macos_app.sh: LAUNCHER_ARCHS must be exactly ${REQUIRED_ARCHS.join(' ')}, got ${declared.join(' ')}.`
		);
	}
}

const buildFunction = build.match(/^build_launcher\(\) \{[\s\S]*?^\}/m);
if (!buildFunction) {
	errors.push('build_macos_app.sh: build_launcher() function is missing.');
} else {
	const body = buildFunction[0];
	const swiftCalls = body.split(/\r?\n/).filter((line) => /\bswift build\b/.test(line));
	if (swiftCalls.length !== 2) {
		errors.push(
			`build_launcher(): expected the build and --show-bin-path swift calls, found ${swiftCalls.length}.`
		);
	}
	for (const call of swiftCalls) {
		if (!call.includes('"${LAUNCHER_ARCH_FLAGS[@]}"')) {
			errors.push(
				`build_launcher(): swift call does not pass every launcher architecture: ${call.trim()}`
			);
		}
	}
	if (!/lipo -archs "\$built_bin"/.test(body)) {
		errors.push('build_launcher(): the produced binary is no longer verified with lipo -archs.');
	}
}

if (
	!/for arch in "\$\{LAUNCHER_ARCHS\[@\]\}"; do\s*\n\s*LAUNCHER_ARCH_FLAGS\+=\(--arch "\$arch"\)/.test(
		build
	)
) {
	errors.push('build_macos_app.sh: LAUNCHER_ARCH_FLAGS must be derived from LAUNCHER_ARCHS.');
}

// Behavioural replay: run the real declaration and build_launcher() with stubbed
// toolchain commands, so a flag or verification regression cannot hide behind
// matching source text.
const archStart = build.indexOf('LAUNCHER_ARCHS=(');
const archEnd = build.indexOf('\ndone\n', archStart);
if (buildFunction && archStart >= 0 && archEnd > archStart) {
	const archBlock = build.slice(archStart, archEnd + 6);
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-launcher-archs-'));
	try {
		fs.writeFileSync(path.join(tmp, 'ErgoptiPlus'), 'product');
		const replay = (lipoOutput) =>
			spawnSync(
				bashExecutable(),
				[
					'-c',
					`
set -e
LAUNCHER_DIR="$1"
log() { :; }
fail() { printf 'FAIL:%s\\n' "$*" >&2; exit 1; }
swift() {
	printf 'SWIFT:%s\\n' "$*" >&2
	if [[ "$*" == *--show-bin-path* ]]; then printf '%s\\n' "$LAUNCHER_DIR"; fi
}
lipo() { printf '%s\\n' "$LIPO_OUTPUT"; }
${archBlock}
${buildFunction[0]}
build_launcher
`,
					'fixture',
					tmp.replaceAll('\\', '/')
				],
				{ encoding: 'utf8', timeout: 10000, env: { ...process.env, LIPO_OUTPUT: lipoOutput } }
			);

		const universal = replay('x86_64 arm64');
		if (universal.error || universal.status !== 0) {
			errors.push(`build_launcher() rejected a universal binary: ${universal.stderr.trim()}`);
		}
		const swiftLines = universal.stderr.split(/\r?\n/).filter((line) => line.startsWith('SWIFT:'));
		if (
			swiftLines.length !== 2 ||
			!swiftLines.every((line) => line.includes('--arch arm64 --arch x86_64'))
		) {
			errors.push(
				`build_launcher() did not pass both architectures to every swift call: ${swiftLines.join(' | ')}`
			);
		}
		const thin = replay('arm64');
		if (thin.error || thin.status === 0 || !thin.stderr.includes('lacks the x86_64 slice')) {
			errors.push('build_launcher() accepted an arm64-only launcher (the dev.127 defect).');
		}
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

// Replay the complete assembly under the builder's strict shell options. SPM
// layouts vary: an empty preferred search must reach the documented alternatives.
const assemblyFunction = build.match(/^assemble_native_runtime\(\) \{[\s\S]*?^\}/m);
if (!assemblyFunction) {
	errors.push('assemble_native_runtime() function is missing.');
} else {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti sparkle discovery-'));
	try {
		const launcher = path.join(fixture, 'launcher');
		const buildRoot = path.join(launcher, '.build');
		const product = path.join(fixture, 'ErgoptiPlus');
		fs.mkdirSync(launcher, { recursive: true });
		fs.writeFileSync(product, 'launcher');
		fs.writeFileSync(path.join(launcher, 'com.ergoptiplus.remap-guardian.plist'), 'plist');
		const replay = (frameworks, failTraversal = false) => {
			fs.rmSync(buildRoot, { recursive: true, force: true });
			fs.rmSync(path.join(fixture, 'app'), { recursive: true, force: true });
			fs.mkdirSync(buildRoot);
			for (const framework of frameworks) {
				const folder = path.join(buildRoot, framework);
				fs.mkdirSync(folder, { recursive: true });
				fs.writeFileSync(path.join(folder, 'origin'), framework);
			}
			return spawnSync(
				bashExecutable(),
				[
					'-c',
					`
set -euo pipefail
REPO_ROOT="$1"
LAUNCHER_DIR="$1/launcher"
BUILD_DIR="$1/build"
APP_PATH="$1/app"
log() { :; }
fail() { printf 'FAIL:%s\\n' "$*" >&2; exit 1; }
xcrun() { :; }
lipo() { :; }
plutil() { :; }
${failTraversal ? 'find() { return 13; }' : ''}
${assemblyFunction[0]}
assemble_native_runtime "$1/ErgoptiPlus"
`,
					'fixture',
					fixture.replaceAll('\\', '/')
				],
				{ encoding: 'utf8', timeout: 10000 }
			);
		};
		const artifact = 'artifacts/sparkle/Sparkle.framework';
		const preferred = 'artifacts/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework';
		const source = 'checkouts/Sparkle/build/Sparkle.framework';
		for (const [slug, frameworks, expected] of [
			['sparkle-artifact-fallback', [artifact], artifact],
			['sparkle-source-fallback', [source], source],
			['sparkle-preferred-slice', [artifact, preferred, source], preferred],
			['sparkle-artifact-before-source', [source, artifact], artifact]
		]) {
			const result = replay(frameworks);
			if (result.error || result.status !== 0) {
				errors.push(`(${slug}) assembly refused a valid framework: ${result.stderr.trim()}`);
				continue;
			}
			const actual = fs.readFileSync(
				path.join(fixture, 'app/Contents/Frameworks/Sparkle.framework/origin'),
				'utf8'
			);
			if (actual !== expected) errors.push(`(${slug}) selected ${actual}, expected ${expected}.`);
		}
		const missing = replay([]);
		if (
			missing.error ||
			missing.status === 0 ||
			!missing.stderr.includes('Sparkle.framework not found')
		) {
			errors.push(
				'(sparkle-missing-diagnostic) absent framework must fail with the named build diagnostic.'
			);
		}
		const traversal = replay([preferred], true);
		if (
			traversal.error ||
			traversal.status === 0 ||
			!traversal.stderr.includes('Cannot inspect Sparkle.framework candidates')
		) {
			errors.push(
				'(sparkle-traversal-diagnostic) failed enumeration must preserve the named build failure.'
			);
		}
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS launcher architecture or framework assembly failed:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] macOS launcher verifies universal slices and assembles every supported Sparkle layout.\x1b[0m'
);
