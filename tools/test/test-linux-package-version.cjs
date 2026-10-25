// tools/test/test-linux-package-version.cjs

/**
 * MODULE: Linux Package Version Identity Regression
 * Builds real DEB archives and runs the RPM/Flatpak staging owners using the
 * release stamp the daemon reads. Native dpkg ordering and refused metadata
 * ensure an unrelated web version or malformed stamp cannot report success.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const BUILD = path.join(ROOT, 'build/linux');
const shared = path.join(BUILD, '_shared');
const writer = path.join(ROOT, 'tools/build/write_build_stamp.sh');
const projector = path.join(ROOT, 'tools/build/linux-package-version.cjs');
const sourcePackage = path.join(ROOT, 'package.json');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "ergopti-version-' "));
const env = { ...process.env, DPKG_DEB_COMPRESSOR_TYPE: 'none' };
delete env.ERGOPTI_BUILD_VERSION;
let refused = 0;
let archives = 0;

function run(file, args, versionEnv = env) {
	return spawnSync(file, args, {
		cwd: ROOT,
		env: versionEnv,
		encoding: 'utf8',
		timeout: 120000,
		maxBuffer: 4 * 1024 * 1024
	});
}
function success(result) {
	assert.equal(result.status, 0, result.stderr || result.stdout || result.error?.message);
	return result;
}
function bash(file, args = [], versionEnv = env) {
	return success(run(bashExecutable(), [file, ...args], versionEnv));
}
function projected(format, directory, json = sourcePackage, versionEnv = env) {
	return run(process.execPath, [projector, format, directory, json], versionEnv);
}
function inventory(directory, relative = '') {
	const entries = [];
	for (const item of fs
		.readdirSync(path.join(directory, relative), { withFileTypes: true })
		.sort((left, right) => left.name.localeCompare(right.name))) {
		const name = relative ? `${relative}/${item.name}` : item.name;
		const filename = path.join(directory, name);
		if (item.isDirectory()) entries.push(['directory', name], ...inventory(directory, name));
		else if (item.isSymbolicLink()) entries.push(['symlink', name, fs.readlinkSync(filename)]);
		else {
			assert.ok(item.isFile(), `unexpected payload node: ${name}`);
			entries.push([
				'file',
				name,
				createHash('sha256').update(fs.readFileSync(filename)).digest('hex')
			]);
		}
	}
	return entries;
}
function refusal(label, directory, json = sourcePackage, versionEnv = env) {
	const result = projected('deb', directory, json, versionEnv);
	assert.notEqual(result.status, 0, label);
	assert.equal(result.stdout, '', `${label} must not publish metadata`);
	assert.match(result.stderr, /ERROR:/, `${label} must diagnose refusal`);
	refused++;
}
try {
	assert.equal(process.platform, 'linux', 'native DEB metadata requires Linux');
	bash(path.join(ROOT, 'tools/build/build-linux-driver.sh'), [], {
		...env,
		ERGOPTI_BUILD_VERSION: '1.0.3'
	});
	for (const [release, native] of [
		['1.0.3', '1.0.3'],
		['0.0.0-dev.9', '0.0.0~dev.9'],
		['0.0.0-dev.10', '0.0.0~dev.10'],
		['', JSON.parse(fs.readFileSync(sourcePackage, 'utf8')).version]
	]) {
		const versionEnv = { ...env, ERGOPTI_BUILD_VERSION: release };
		bash(writer, ['write', shared], versionEnv);
		for (const format of ['deb', 'rpm', 'appimage', 'flatpak']) {
			const result = success(projected(format, shared, sourcePackage, versionEnv));
			assert.equal(
				result.stdout.trim(),
				format === 'deb' || format === 'rpm' ? native : release || native
			);
			assert.match(
				result.stderr,
				release ? /from copied release stamp/ : /from source-validation package/
			);
		}
		for (const [format, args] of [
			['deb', []],
			['rpm', ['--skip-rpm']],
			['flatpak', ['--skip-flatpak']]
		]) {
			const result = bash(
				path.join(ROOT, `tools/build/build-linux-${format}.sh`),
				args,
				versionEnv
			);
			const expected = format === 'flatpak' ? release || native : native;
			assert.ok(
				result.stdout.includes(`Package: ergopti ${expected}${format === 'rpm' ? '-1' : ''} (`),
				result.stdout
			);
			if (format === 'deb') {
				const archive = path.join(BUILD, `ergopti_${native}_amd64.deb`);
				const field = success(run('dpkg-deb', ['--field', archive, 'Version']));
				assert.equal(
					field.stdout.trim(),
					native,
					'actual DEB control metadata must identify its staged runtime'
				);
				fs.unlinkSync(archive);
				archives++;
			}
			if (format === 'rpm') {
				const spec = fs.readFileSync(path.join(BUILD, 'rpm/SPECS/ergopti.spec'), 'utf8');
				assert.equal(spec.match(/^Version:\s+(\S+)$/m)?.[1], native);
				const source = spec.match(/^Source0:\s+(\S+)$/m)?.[1];
				assert.ok(source, 'the actual recipe must declare its owned source archive');
				const archiveName = source
					.replaceAll('%{name}', 'ergopti')
					.replaceAll('%{version}', native);
				const sourceArchive = path.join(BUILD, 'rpm/SOURCES', archiveName);
				const relocated = path.join(scratch, `rpm-${archives}/BUILD/ergopti-${native}-build`);
				fs.mkdirSync(relocated, { recursive: true });
				success(run('tar', ['-xzf', sourceArchive, '-C', relocated]));
				const extracted = path.join(relocated, `ergopti-${native}/usr/lib/ergopti`);
				assert.deepEqual(
					inventory(path.join(relocated, `ergopti-${native}`)),
					inventory(path.join(BUILD, `rpm/BUILD/ergopti-${native}`)),
					'the declared RPM source archive must preserve the entire staged tree without checkout fallback'
				);
				assert.deepEqual(
					fs.readFileSync(path.join(extracted, 'bin/libergopti_archive_publication.so')),
					fs.readFileSync(path.join(BUILD, 'linux/bin/libergopti_archive_publication.so'))
				);
				assert.deepEqual(
					fs.readFileSync(path.join(extracted, '_shared/build_stamp.txt')),
					fs.readFileSync(path.join(shared, 'build_stamp.txt'))
				);
				assert.ok(fs.statSync(path.join(extracted, 'install/launch.sh')).isFile());
				assert.ok(
					fs.existsSync(
						path.join(BUILD, `rpm/BUILD/ergopti-${native}/usr/lib/ergopti/_shared/build_stamp.txt`)
					)
				);
			}
			if (format === 'flatpak') assert.ok(result.stdout.includes(`ergopti-${expected}.flatpak`));
		}
		console.log(`PASS package-version-native-and-staging-${release || 'source-validation'}`);
	}
	for (const [before, after] of [
		['0.0.0~dev.9', '0.0.0~dev.10'],
		['0.0.0~dev.10', '0.0.0'],
		['1.0.3', '1.0.4']
	])
		success(run('dpkg', ['--compare-versions', before, 'lt', after]));
	assert.notEqual(
		run('dpkg', ['--compare-versions', '0.0.0-dev.10', 'lt', '0.0.0']).status,
		0,
		'negative ordering control must expose raw SemVer prerelease inversion'
	);
	const fixture = path.join(scratch, "shared '\n");
	fs.mkdirSync(fixture);
	const stampPath = path.join(fixture, 'build_stamp.txt');
	const jsonPath = path.join(scratch, "source '\n.json");
	const missingJson = path.join(scratch, 'missing.json');
	refusal('missing stamp', fixture);
	bash(writer, ['write', fixture], { ...env, ERGOPTI_BUILD_VERSION: '1.0.3' });
	const canonical = fs.readFileSync(stampPath, 'utf8');
	assert.equal(
		success(projected('deb', fixture, missingJson)).stdout,
		'1.0.3\n',
		'release metadata must not depend on unrelated source JSON'
	);
	for (const [label, mutated] of [
		['invalid commit', canonical.replace(/^commit=.+$/m, 'commit=bad')],
		['malformed release', canonical.replace('version=1.0.3', 'version=broken')],
		['duplicate release', canonical + 'version=1.0.3\n'],
		['unknown release channel', canonical.replace('version=1.0.3', 'version=1.0.3-dev.2')],
		['release build metadata', canonical.replace('version=1.0.3', 'version=1.0.3+local')]
	]) {
		fs.writeFileSync(stampPath, mutated);
		refusal(label, fixture);
	}
	fs.writeFileSync(stampPath, canonical);
	refusal('release expectation mismatch', fixture, sourcePackage, {
		...env,
		ERGOPTI_BUILD_VERSION: '1.0.4'
	});
	bash(writer, ['write', fixture]);
	for (const [label, json] of [
		['malformed JSON', '{'],
		['missing source version', '{}'],
		['nonstring source version', '{"version":3}'],
		['noncanonical source version', '{"version":"01.0.0"}'],
		['unknown source channel', '{"version":"1.0.3-unknown.1"}']
	]) {
		fs.writeFileSync(jsonPath, json);
		refusal(label, fixture, jsonPath);
	}
	refusal('missing source package', fixture, missingJson);
	fs.writeFileSync(jsonPath, '{"version":"3.0.0"}');
	assert.equal(
		success(projected('deb', fixture, jsonPath)).stdout,
		'3.0.0\n',
		'source paths with apostrophes/newlines must remain literal'
	);
	console.log(
		`PASS package-version-native archives=${archives} formats=4 refused=${refused} native-order-pairs=3`
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
