// tools/test/test-linux-source-toolchain.cjs

/** Source capability probes, closed package projections and genuine Linux clone receiving. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const pipeline = require('./ci-pipeline.cjs');
const generator = require('../codegen/codegen-linux-native-runtime.cjs');
const root = path.resolve(__dirname, '../..');
const driver = path.join(root, 'static/ergopti_plus/linux');
const installer = fs.readFileSync(process.argv[2] || path.join(driver, 'install.sh'), 'utf8');
const helper = path.join(driver, 'install/native_source_build.sh');
const data = JSON.parse(fs.readFileSync(path.join(root, generator.SOURCE), 'utf8'));
const posix = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
function shellFunction(name) {
	const start = installer.indexOf(name + '() {\n');
	assert.equal(installer.split(name + '() {\n').length, 2, 'actual function definition is unique');
	const end = installer.indexOf('\n}\n', start);
	assert.ok(end > start);
	return installer.slice(start, end + 3);
}
const functions = ['_native_output_build_packages', '_ensure_native_output_toolchain']
	.map(shellFunction)
	.join('\n');
const start = 'NATIVE_OUTPUT_SOURCE="${SRC_DRIVER}/bin/libergopti_archive_publication.so"';
const end = '\tNATIVE_OUTPUT_STAGE="$(mktemp -d)"';
for (const boundary of [start, end]) assert.equal(installer.split(boundary).length, 2);
const acquisition = installer.slice(installer.indexOf(start), installer.indexOf(end)) + 'fi\n';
const scratchParent = fs.realpathSync(os.tmpdir());
const scratch = fs.mkdtempSync(path.join(scratchParent, 'ergopti-source-toolchain-'));
let childrenTerminal = true;
function run(script) {
	const result = spawnSync(bashExecutable(), ['-c', script], { encoding: 'utf8', timeout: 10000 });
	if (result.error || result.status === null || result.signal !== null) childrenTerminal = false;
	assert.ifError(result.error);
	assert.notEqual(result.status, null);
	assert.equal(result.signal, null);
	return result;
}
try {
	const sourceDriver = path.join(scratch, 'model repository/static/ergopti_plus/linux');
	const sourceDirectory = path.join(sourceDriver, 'native/archive_output');
	const builderRelative = 'tools/build/build-linux-native-output.sh';
	fs.mkdirSync(sourceDirectory, { recursive: true });
	for (const file of ['archive_publication.c', 'archive_publication.h'])
		fs.copyFileSync(
			path.join(driver, 'native/archive_output', file),
			path.join(sourceDirectory, file)
		);
	const copiedBuilder = path.join(scratch, 'model repository', builderRelative);
	fs.mkdirSync(path.dirname(copiedBuilder), { recursive: true });
	fs.copyFileSync(path.join(root, builderRelative), copiedBuilder);
	const archiveDriver = path.join(scratch, 'archive/linux');
	fs.mkdirSync(archiveDriver, { recursive: true });
	for (const [label, selectedDriver, manager, skip, repair, ready, packageStatus, expected] of [
		['package success without compiler capability', sourceDriver, 'apt', false, false, false, 0, 1],
		['source repair', sourceDriver, 'apt', false, true, false, 0, 0],
		['package refusal', sourceDriver, 'apt', false, true, false, 7, 1],
		['already capable source', sourceDriver, 'apt', false, false, true, 0, 0],
		['no-deps caller ownership', sourceDriver, 'apt', true, false, false, 0, 0],
		['archive layout', archiveDriver, 'apt', false, false, false, 0, 0],
		['null provider', sourceDriver, 'xbps', false, false, false, 0, 1],
		['unknown provider', sourceDriver, 'APT', false, false, false, 0, 1]
	]) {
		const owned = path.join(scratch, label.replaceAll(' ', '-'));
		fs.mkdirSync(owned);
		const compiler = path.join(owned, 'compiler'),
			calls = path.join(owned, 'packages'),
			args = path.join(owned, 'args');
		const compilerBody =
			'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > ' + quote(posix(args)) + '\nexit 0\n';
		if (ready) {
			fs.writeFileSync(compiler, compilerBody);
			fs.chmodSync(compiler, 0o755);
		}
		const script = `set -euo pipefail
source ${quote(posix(helper))}
${functions}
SRC_DRIVER=${quote(posix(selectedDriver))}
SKIP_DEPS=${skip}
CC=${quote(posix(compiler))}
_detect_pkg_manager() { echo ${manager}; }
_install_required_package() {
 printf '%s\\n' "$2" >> ${quote(posix(calls))}
 if [ ${packageStatus} -ne 0 ]; then return ${packageStatus}; fi
 if [ "$2" = linux-libc-dev ] && ${repair}; then
  printf '%s' ${quote(compilerBody)} > "$CC"
  chmod 755 "$CC"
 fi
}
${acquisition}`;
		const result = run(script);
		assert.equal(
			result.status,
			expected,
			label + ': real checkout acquisition branch must retain capability admission'
		);
		const observed = fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n') : [];
		const expectedPackages =
			selectedDriver === sourceDriver && !skip && !ready && manager === 'apt'
				? packageStatus
					? data.archive_build_packages.apt.slice(0, 1)
					: data.archive_build_packages.apt
				: [];
		assert.deepEqual(observed, expectedPackages);
		if (ready || (repair && packageStatus === 0 && selectedDriver === sourceDriver && !skip)) {
			const receivedArgs = fs.readFileSync(args, 'utf8').trim().split('\n');
			assert.ok(receivedArgs.includes('-fsyntax-only'));
			assert.ok(receivedArgs.includes(posix(path.join(sourceDirectory, 'archive_publication.c'))));
		}
		assert.ok(
			!fs.existsSync(path.join(sourceDriver, 'bin/libergopti_archive_publication.so')),
			'a model never supplies an archive backend'
		);
	}
	console.log('Actual checkout capability controls: 8 passed; compiler seam is a model.');
	if (process.platform === 'linux') {
		const clone = path.join(scratch, 'genuine-git-clone');
		const cloned = spawnSync(
			'git',
			['clone', '--quiet', '--local', '--no-hardlinks', root, clone],
			{ encoding: 'utf8' }
		);
		assert.ifError(cloned.error);
		assert.equal(cloned.status, 0);
		for (const checkout of [root, clone]) {
			const head = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: checkout, encoding: 'utf8' });
			assert.equal(head.status, 0);
			assert.match(head.stdout.trim(), /^[0-9a-f]{40}$/);
			if (checkout === root) data.control_head = head.stdout.trim();
			else assert.equal(head.stdout.trim(), data.control_head);
		}
		const clonedDriver = path.join(clone, 'static/ergopti_plus/linux');
		const actualSource = path.join(clonedDriver, 'native/archive_output');
		const compiler = run('command -v cc');
		assert.equal(compiler.status, 0, 'receiving requires a genuine compiler');
		const wrapper = path.join(scratch, 'native-compiler'),
			ready = path.join(scratch, 'headers-ready');
		fs.writeFileSync(
			wrapper,
			'#!/bin/bash\nif [ ! -f ' +
				quote(ready) +
				' ]; then exec ' +
				quote(compiler.stdout.trim()) +
				' -nostdinc "$@"; fi\nexec ' +
				quote(compiler.stdout.trim()) +
				' "$@"\n'
		);
		fs.chmodSync(wrapper, 0o755);
		const result = run(`set -euo pipefail
source ${quote(helper)}
${functions}
SRC_DRIVER=${quote(clonedDriver)}
SKIP_DEPS=false
export CC=${quote(wrapper)}
_detect_pkg_manager() { echo apt; }
_install_required_package() { if [ "$2" = linux-libc-dev ]; then touch ${quote(ready)}; fi; }
if native_source_compile_probe ${quote(actualSource)}; then exit 91; fi
${acquisition}
native_source_compile_probe ${quote(actualSource)}
bash ${quote(path.join(clone, builderRelative))} --source-directory ${quote(actualSource)} --output-directory ${quote(path.join(scratch, 'actual-output'))}`);
		assert.equal(
			result.status,
			0,
			'real cloned source must refuse missing headers then compile through unchanged builder'
		);
		assert.equal(
			fs
				.readFileSync(path.join(scratch, 'actual-output/libergopti_archive_publication.so'))
				.subarray(0, 4)
				.toString('hex'),
			'7f454c46'
		);
		console.log(
			'Genuine Linux clone/C/header/ELF control: 1 passed; probe/acquisition from candidate, C and builder from exact cloned HEAD.'
		);
	} else console.log('Genuine Linux clone/C/header/ELF control: 1 skipped (Linux required).');
} finally {
	assert.equal(path.dirname(scratch), scratchParent);
	if (childrenTerminal) fs.rmSync(scratch, { recursive: true, force: true });
	else console.error('Owned toolchain namespace retained: child retirement is unobserved.');
}
assert.equal(data.archive_build_packages.xbps, null);
assert.equal(data.network_runtime.providers.dnf, null);
assert.ok(data.network_runtime.source_luv_build_packages.dnf.includes('luajit-devel'));
const job = pipeline.job('install-linux');
const managers = {
	'distro-debian': 'apt',
	'distro-fedora': 'dnf',
	'distro-arch': 'pacman',
	'distro-alpine': 'apk',
	'distro-opensuse': 'zypper'
};
const rows = [...job.matchAll(/^          - id: (distro-[^\n]+)\n((?:            [^\n]*\n)+)/gm)];
assert.equal(rows.length, 5);
for (const row of rows) {
	const prep = row[2].match(/^            prep: (.*)$/m)[1];
	assert.match(prep, /\bgit\b/, 'pre-checkout Git is mandatory');
	assert.ok(
		prep.endsWith('git ' + data.archive_build_packages[managers[row[1]]].join(' ')),
		'CI caller prerequisites match the canonical package vector'
	);
}
const check = pipeline.step(job, 'Verify source compiler and checkout');
assert.match(pipeline.runOf(check).join('\n'), /git rev-parse HEAD/);
assert.match(pipeline.runOf(check).join('\n'), /native_source_compile_probe/);
assert.ok(job.indexOf(check) < job.indexOf(pipeline.step(job, 'Create the installation user')));
assert.ok(
	fs
		.readFileSync(path.join(root, 'tools/build/build-linux-driver.sh'), 'utf8')
		.includes('"linux/install/native_source_build.sh"')
);
const recipe = JSON.parse(fs.readFileSync(path.join(root, generator.SOURCE), 'utf8'));
const outputs = generator.render(recipe, (name) => fs.readFileSync(path.join(root, name), 'utf8'));
for (const [file, output] of Object.entries(outputs))
	assert.equal(
		fs.readFileSync(path.join(root, file), 'utf8'),
		output,
		'canonical generated output exact: ' + file
	);
console.log(
	'Canonical projections, source-only prerequisites and all five Git/CI caller controls: passed.'
);
