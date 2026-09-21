// tools/test/test-macos-launcher-universal.cjs

/**
 * ==============================================================================
 * MODULE: macOS Launcher Architecture Guard
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
 * the post-build lipo verification disappears.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

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
		errors.push(`build_macos_app.sh: LAUNCHER_ARCHS must be exactly ${REQUIRED_ARCHS.join(' ')}, got ${declared.join(' ')}.`);
	}
}

const buildFunction = build.match(/^build_launcher\(\) \{[\s\S]*?^\}/m);
if (!buildFunction) {
	errors.push('build_macos_app.sh: build_launcher() function is missing.');
} else {
	const body = buildFunction[0];
	const swiftCalls = body.split(/\r?\n/).filter((line) => /\bswift build\b/.test(line));
	if (swiftCalls.length !== 2) {
		errors.push(`build_launcher(): expected the build and --show-bin-path swift calls, found ${swiftCalls.length}.`);
	}
	for (const call of swiftCalls) {
		if (!call.includes('"${LAUNCHER_ARCH_FLAGS[@]}"')) {
			errors.push(`build_launcher(): swift call does not pass every launcher architecture: ${call.trim()}`);
		}
	}
	if (!/lipo -archs "\$built_bin"/.test(body)) {
		errors.push('build_launcher(): the produced binary is no longer verified with lipo -archs.');
	}
}

if (!/for arch in "\$\{LAUNCHER_ARCHS\[@\]\}"; do\s*\n\s*LAUNCHER_ARCH_FLAGS\+=\(--arch "\$arch"\)/.test(build)) {
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
		const replay = (lipoOutput) => spawnSync('bash', ['-c', `
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
`, 'fixture', tmp.replaceAll('\\', '/')], { encoding: 'utf8', timeout: 10000, env: { ...process.env, LIPO_OUTPUT: lipoOutput } });

		const universal = replay('x86_64 arm64');
		if (universal.error || universal.status !== 0) {
			errors.push(`build_launcher() rejected a universal binary: ${universal.stderr.trim()}`);
		}
		const swiftLines = universal.stderr.split(/\r?\n/).filter((line) => line.startsWith('SWIFT:'));
		if (swiftLines.length !== 2 || !swiftLines.every((line) => line.includes('--arch arm64 --arch x86_64'))) {
			errors.push(`build_launcher() did not pass both architectures to every swift call: ${swiftLines.join(' | ')}`);
		}
		const thin = replay('arm64');
		if (thin.error || thin.status === 0 || !thin.stderr.includes('lacks the x86_64 slice')) {
			errors.push('build_launcher() accepted an arm64-only launcher (the dev.127 defect).');
		}
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS launcher is not built as a verified universal binary:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] macOS launcher builds for arm64 and x86_64 and verifies both slices.\x1b[0m');
