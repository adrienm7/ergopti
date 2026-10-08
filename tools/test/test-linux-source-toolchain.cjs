// tools/test/test-linux-source-toolchain.cjs

/** Source-install toolchain acquisition, closed distro providers and real Linux compilation. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const pipeline = require('./ci-pipeline.cjs');
const root = path.resolve(__dirname, '../..');
const installer = fs.readFileSync(
	process.argv[2] || path.join(root, 'static/ergopti_plus/linux/install.sh'),
	'utf8'
);
const helper = path.join(root, 'static/ergopti_plus/linux/install/native_source_build.sh');
assert.ok(
	fs
		.readFileSync(path.join(root, 'tools/build/build-linux-driver.sh'), 'utf8')
		.includes('"linux/install/native_source_build.sh"'),
	'archive installer receives its mandatory helper definitions'
);
const posix = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
const dependencyStart = installer.indexOf('if $SKIP_DEPS; then\n');
const dependencyEnd = installer.indexOf('echo ""\necho "=== Ergopti', dependencyStart);
assert.ok(
	dependencyStart >= 0 && dependencyEnd > dependencyStart,
	'actual dependency owner region must exist'
);
const acquisition = installer.slice(dependencyStart, dependencyEnd) + ':\nfi\n';
const providers = {
	apt: ['gcc', 'libc6-dev', 'linux-libc-dev'],
	dnf: ['gcc', 'glibc-devel', 'kernel-headers'],
	zypper: ['gcc', 'glibc-devel', 'linux-glibc-devel'],
	pacman: ['gcc', 'glibc', 'linux-api-headers'],
	xbps: ['gcc', 'base-devel', 'kernel-libc-headers'],
	apk: ['gcc', 'musl-dev', 'linux-headers']
};
for (const [manager, packages] of Object.entries(providers)) {
	const result = spawnSync(
		bashExecutable(),
		[
			'-c',
			'source "$1"; native_source_build_packages "$2"',
			'owned-provider',
			posix(helper),
			manager
		],
		{ encoding: 'utf8' }
	);
	assert.equal(result.status, 0);
	assert.equal(result.stdout, packages.join('\n') + '\n');
	assert.equal(result.stderr, '');
}
const refusedProvider = spawnSync(
	bashExecutable(),
	['-c', 'source "$1"; native_source_build_packages "$2"', 'owned-provider', posix(helper), 'APT'],
	{ encoding: 'utf8' }
);
assert.equal(refusedProvider.status, 1);
assert.equal(refusedProvider.stdout, '');

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-source-toolchain-'));
try {
	const sourceDriver = path.join(scratch, 'model repository/static/ergopti_plus/linux');
	const archiveDriver = path.join(scratch, 'archive/linux');
	const sourceDirectory = path.join(sourceDriver, 'native/archive_output');
	fs.mkdirSync(sourceDirectory, { recursive: true });
	fs.mkdirSync(archiveDriver, { recursive: true });
	for (const file of ['archive_publication.c', 'archive_publication.h'])
		fs.copyFileSync(
			path.join(root, 'static/ergopti_plus/linux/native/archive_output', file),
			path.join(sourceDirectory, file)
		);
	for (const [label, driver, skip, repair, expected] of [
		['source acquisition', sourceDriver, false, true, 0],
		['manager success without compiler/header capability', sourceDriver, false, false, 1],
		['no-deps keeps acquisition disabled', sourceDriver, true, true, 1],
		['archive layout needs no compiler', archiveDriver, false, true, 0]
	]) {
		const owner = path.join(scratch, label.replace(/[^a-z0-9]+/g, '-'));
		fs.mkdirSync(owner);
		const compiler = path.join(owner, 'controlled-compiler');
		const calls = path.join(owner, 'packages');
		const args = path.join(owner, 'compiler-args');
		const script = `set -euo pipefail
source ${quote(posix(helper))}
SRC_DRIVER=${quote(posix(driver))}
SKIP_DEPS=${skip}
CC=${quote(posix(compiler))}
_detect_pkg_manager() { echo apt; }
_install_required_package() {
  printf '%s\\n' "$2" >> ${quote(posix(calls))}
  if [ "$2" = linux-libc-dev ] && ${repair}; then
    printf '%s\\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$@" > ${posix(args)}' 'exit 0' > "$CC"
    chmod 755 "$CC"
  fi
}
${acquisition}
if native_source_build_required "$SRC_DRIVER"; then native_source_compile_probe "$SRC_DRIVER/native/archive_output"; fi
`;
		const result = spawnSync(bashExecutable(), ['-c', script], { encoding: 'utf8' });
		assert.equal(
			result.status,
			expected,
			`${label}: actual checkout/dependency branch controls acquisition`
		);
		const observed = fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n') : [];
		assert.deepEqual(observed, driver === sourceDriver && !skip ? providers.apt : []);
		if (expected === 0 && driver === sourceDriver) {
			const compilerArgs = fs.readFileSync(args, 'utf8').trim().split('\n');
			assert.ok(compilerArgs.includes('-fsyntax-only'));
			assert.ok(
				compilerArgs.includes(posix(path.join(sourceDirectory, 'archive_publication.c'))),
				'probe must parse the actual native C source'
			);
			assert.ok(
				!fs.existsSync(path.join(sourceDriver, 'bin/libergopti_archive_publication.so')),
				'a syntax control cannot fake a native backend'
			);
		}
	}
	console.log(
		'Source acquisition branch models: 4 passed; compiler callback is a model, no native qualification.'
	);
	if (process.platform === 'linux') {
		const clone = path.join(scratch, 'genuine-git-clone');
		const cloned = spawnSync(
			'git',
			['clone', '--quiet', '--local', '--no-hardlinks', root, clone],
			{ encoding: 'utf8' }
		);
		assert.equal(cloned.status, 0, 'native control requires a genuine Git clone');
		const head = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: clone, encoding: 'utf8' });
		assert.equal(head.status, 0);
		assert.match(head.stdout.trim(), /^[0-9a-f]{40}$/);
		const driver = path.join(clone, 'static/ergopti_plus/linux');
		const actualSource = path.join(driver, 'native/archive_output');
		const compiler = spawnSync(bashExecutable(), ['-c', 'command -v cc'], { encoding: 'utf8' });
		assert.equal(
			compiler.status,
			0,
			'native control requires an actual compiler, never a stub backend'
		);
		const wrapper = path.join(scratch, 'native-compiler');
		const ready = path.join(scratch, 'native-headers-ready');
		fs.writeFileSync(
			wrapper,
			`#!/bin/bash\nif [ ! -f ${quote(ready)} ]; then exec ${quote(compiler.stdout.trim())} -nostdinc "$@"; fi\nexec ${quote(compiler.stdout.trim())} "$@"\n`
		);
		fs.chmodSync(wrapper, 0o755);
		const script = `set -euo pipefail
source ${quote(helper)}
SRC_DRIVER=${quote(driver)}
SKIP_DEPS=false
CC=${quote(wrapper)}
export CC
_detect_pkg_manager() { echo apt; }
_install_required_package() { if [ "$2" = linux-libc-dev ]; then touch ${quote(ready)}; fi; }
if native_source_compile_probe ${quote(actualSource)}; then exit 91; fi
${acquisition}
native_source_compile_probe ${quote(actualSource)}
bash ${quote(path.join(clone, 'tools/build/build-linux-native-output.sh'))} --source-directory ${quote(actualSource)} --output-directory ${quote(path.join(scratch, 'actual-output'))}
`;
		const result = spawnSync(bashExecutable(), ['-c', script], {
			encoding: 'utf8',
			timeout: 30000
		});
		assert.equal(
			result.status,
			0,
			'genuine checkout must acquire and parse actual headers then run unchanged builder'
		);
		const binary = fs.readFileSync(
			path.join(scratch, 'actual-output/libergopti_archive_publication.so')
		);
		assert.equal(
			binary.subarray(0, 4).toString('hex'),
			'7f454c46',
			'actual compiler emits ELF, never a placeholder'
		);
		console.log(
			'Actual Linux Git-clone compiler/header and unchanged native builder control: 1 passed; 0 skipped.'
		);
	} else {
		console.log(
			'Actual Linux Git-clone compiler/header build control: 1 skipped (Linux required).'
		);
	}
} finally {
	assert.ok(path.resolve(scratch).startsWith(path.resolve(os.tmpdir()) + path.sep));
	fs.rmSync(scratch, { recursive: true, force: true });
}

const job = pipeline.job('install-linux');
const rows = [...job.matchAll(/^          - id: (distro-[^\n]+)\n((?:            [^\n]*\n)+)/gm)];
assert.equal(rows.length, 5);
for (const row of rows) {
	assert.match(
		row[2],
		/prep: .*\bgit\b/,
		'Git is installed before checkout; REST archive fallback cannot qualify a clone'
	);
	const manager = row[2].match(/^            native_manager: (.+)$/m)?.[1];
	assert.ok(manager in providers, 'each no-deps source row declares a closed provider');
}
const prerequisite = pipeline.step(job, 'Prepare source compiler and headers');
assert.match(pipeline.runOf(prerequisite).join('\n'), /native_source_ensure_prerequisites/);
assert.match(pipeline.runOf(prerequisite).join('\n'), /git rev-parse HEAD/);
const install = pipeline.step(job, 'Install as an ordinary user without runtime dependencies');
assert.ok(job.indexOf(prerequisite) < job.indexOf(install));
assert.match(pipeline.runOf(install).join('\n'), /install\.sh --no-deps/);
console.log('Closed source toolchain providers and all five CI source rows: passed.');
