// tools/test/test-linux-rpm-publish.cjs

/**
 * MODULE: RPM Main Artifact Publication Regression
 * Real packager staging and filesystem publication run here. Only the external
 * RPM toolchain is modelled for the common suite; separate genuine native runs
 * qualify its real metadata, complete package payloads and release selection.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { requiredComponents, stageAppDir } = require('./lib/linux-private-runtime-fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-rpm-publish-'));
const expected = { name: 'ergopti', version: '1.0.3', arch: 'x86_64' };
// The test owns its build directory: packaging tests that run at the same time never share one folder.
const BUILD = path.join(scratch, 'build');
const env = {
	...process.env,
	ERGOPTI_BUILD_VERSION: expected.version,
	ERGOPTI_LINUX_BUILD_DIR: BUILD
};
function bash(filename, args = [], childEnv = env) {
	return spawnSync(bashExecutable(), [filename, ...args], {
		cwd: ROOT,
		env: childEnv,
		encoding: 'utf8',
		timeout: 120000,
		maxBuffer: 4 * 1024 * 1024
	});
}
function success(result) {
	assert.equal(result.status, 0, result.stderr || result.stdout || result.error?.message);
	return result;
}
function findPackages(directory, childEnv = env) {
	return success(
		spawnSync('find', [directory, '-name', '*.rpm', '-type', 'f'], {
			env: childEnv,
			encoding: 'utf8'
		})
	)
		.stdout.trim()
		.split('\n')
		.filter(Boolean);
}
try {
	assert.equal(process.platform, 'linux', 'RPM package staging requires Linux');
	success(bash(path.join(ROOT, 'tools/build/build-linux-driver.sh')));
	const bin = path.join(scratch, 'bin');
	fs.mkdirSync(bin);
	// These programs model only RPM's native build/query boundary. The actual
	// producer, canonical source archive, Node publisher and GNU find remain real.
	const collaborator = `#!/usr/bin/env node
'use strict';
const fs = require('node:fs'); const path = require('node:path');
const args = process.argv.slice(2);
if (process.env.ERGOPTI_RPM_PRODUCER_LOG) fs.appendFileSync(process.env.ERGOPTI_RPM_PRODUCER_LOG, path.basename(process.argv[1]) + '\\n');
if (path.basename(process.argv[1]) === 'rpm') {
 if (args.length !== 4 || args[0] !== '-qp' || args[1] !== '--queryformat') throw new Error('unexpected RPM metadata request');
 const record = JSON.parse(fs.readFileSync(args[3], 'utf8'));
 if (process.env.ERGOPTI_RPM_TEST_DIAGNOSTIC) process.stderr.write('native metadata diagnostic\\n');
 process.stdout.write(record.name+'\\n'+record.version+'\\n'+record.arch+'\\n');
} else {
 const defines = {}; let spec;
 for(let i=0;i<args.length;i++) {
  if(args[i] === '--define') { const value=args[++i]; const split=value.indexOf(' '); defines[value.slice(0,split)]=value.slice(split+1); }
  else if(args[i] === '-bb') spec=args[++i]; else throw new Error('unexpected native build argument');
 }
 const text=fs.readFileSync(spec,'utf8');
 const field=(name)=>{const value=text.match(new RegExp('^'+name+':\\\\s+(\\\\S+)$','m'))?.[1]; if(!value) throw new Error('missing native spec identity'); return value;};
 const identity={name:field('Name'),version:field('Version'),arch:field('BuildArch')};
 const top=defines._topdir; if(!top) throw new Error('missing topdir');
 if(!fs.existsSync(path.join(top,'SOURCES',identity.name+'-'+identity.version+'.tar.gz'))) throw new Error('missing real Source0');
 // RPMS is RPM's documented default when no explicit native-output override exists.
 const output=path.join(defines._rpmdir || path.join(top,'RPMS'),identity.arch); fs.mkdirSync(output,{recursive:true});
 fs.writeFileSync(path.join(output,'00-debug.rpm'),JSON.stringify({...identity,name:identity.name+'-debuginfo',payload:['debug-only']}));
 fs.writeFileSync(path.join(output,'99-runtime.rpm'),JSON.stringify({...identity,payload:['usr/bin/ergopti','usr/lib/ergopti/ergopti_hotstrings.lua']}));
}
`;
	for (const program of ['rpm', 'rpmbuild'])
		fs.writeFileSync(path.join(bin, program), collaborator, { mode: 0o755 });
	const modelEnv = {
		...env,
		PATH: bin + path.delimiter + env.PATH,
		ERGOPTI_RPM_TEST_DIAGNOSTIC: '1'
	};
	const producer = path.join(ROOT, 'tools/build/build-linux-rpm.sh');
	// The genuine runtime is staged and admitted on the oldest supported LTS by
	// the AppImage stager; the packager only carries that prefix.
	const producerLog = path.join(scratch, 'native-producers.log');
	const priorOutput = path.join(BUILD, 'ErgoptiPlus-linux-x86_64.rpm');
	fs.writeFileSync(priorOutput, 'previous release output\n');
	const unstaged = bash(producer, [], { ...modelEnv, ERGOPTI_RPM_PRODUCER_LOG: producerLog });
	assert.notEqual(unstaged.status, 0, 'a package without the staged private runtime must refuse');
	assert.match(unstaged.stderr, /private runtime/i, 'refusal names the missing runtime');
	assert.equal(fs.existsSync(producerLog), false, 'native RPM build/query must not run');
	assert.equal(fs.readFileSync(priorOutput, 'utf8'), 'previous release output\n');
	fs.rmSync(path.join(BUILD, 'rpm'), { recursive: true, force: true });
	stageAppDir(BUILD);
	const direct = success(bash(producer, [], modelEnv));
	// ROOT CAUSE ENCODED: the .rpm took LuaJIT, curl, openssl and sqlite3 from
	// Fedora and compiled only its own luv, so the host decided what ran (owned
	// runtimes, PIN). Replay the actual wrapper, minus its exec, on the staged tree.
	const payload = path.join(BUILD, `rpm/BUILD/ergopti-${expected.version}`);
	const driverRoot = path.join(payload, 'usr/lib/ergopti');
	const runtime = path.join(driverRoot, 'runtime');
	for (const component of requiredComponents())
		assert.ok(fs.existsSync(path.join(runtime, component)), `the package carries ${component}`);
	assert.ok(!fs.existsSync(path.join(driverRoot, 'native_modules')), 'no second luv binding');
	const wrapper = fs.readFileSync(path.join(payload, 'usr/bin/ergopti'), 'utf8').split('\n');
	assert.match(wrapper.at(-2), /^exec bash "\$DRIVER_ROOT\/install\/launch\.sh" "\$@"$/);
	const environment = wrapper
		.slice(0, -2)
		.join('\n')
		.replace('DRIVER_ROOT="/usr/lib/ergopti"', 'DRIVER_ROOT="$ERGOPTI_TEST_DRIVER_ROOT"');
	const replay = () =>
		spawnSync(
			bashExecutable(),
			['-c', environment + '\nprintf "%s\\n%s" "$LUA_CPATH" "$ERGOPTI_RUNTIME_PREFIX"'],
			{
				env: {
					...env,
					ERGOPTI_TEST_DRIVER_ROOT: driverRoot,
					LUA_CPATH: '',
					CURL_CA_BUNDLE: 'owned explicit trust, no TLS request'
				},
				encoding: 'utf8'
			}
		);
	const admitted = success(replay());
	assert.equal(admitted.stdout, `${path.join(runtime, 'lib/lua/5.1')}/?.so;;\n${runtime}`);
	fs.rmSync(path.join(runtime, 'bin/sqlite3'));
	const missing = replay();
	assert.notEqual(missing.status, 0, 'a package missing a runtime program must refuse to start');
	assert.match(missing.stderr, /Required installed native package component unavailable/);
	fs.writeFileSync(path.join(runtime, 'bin/sqlite3'), 'fixture', { mode: 0o755 });
	console.log('PASS rpm-wrapper-admits-its-private-runtime');
	const selected = direct.stdout.match(/^Package: (.+\.rpm)$/m)?.[1];
	assert.ok(selected, 'actual producer must report its selected runtime package');
	assert.equal(
		JSON.parse(fs.readFileSync(selected, 'utf8')).name,
		expected.name,
		'debug-first native outputs must not replace the runtime package'
	);
	assert.match(
		direct.stderr,
		/native metadata diagnostic/,
		'successful native metadata diagnostics must remain visible'
	);
	const published = path.join(BUILD, 'rpm/RPMS');
	assert.deepEqual(
		findPackages(published),
		[selected],
		'the release consumer must see exactly one admitted main'
	);
	const nativeRoot = path.join(BUILD, 'rpm/native-rpms');
	assert.equal(
		findPackages(nativeRoot).length,
		2,
		'all raw/debug native outputs must remain retained'
	);
	const mainBytes = fs.readFileSync(selected);
	const staged = success(bash(producer, ['--skip-rpm'], modelEnv));
	assert.deepEqual(
		fs.readFileSync(path.join(BUILD, 'rpm/publish-linux-rpm.cjs')),
		fs.readFileSync(path.join(ROOT, 'tools/build/publish-linux-rpm.cjs')),
		'prepared manual builds must carry the canonical publisher bytes'
	);
	const command = staged.stdout.match(/^  (rpmbuild .+)$/m)?.[1];
	assert.ok(command, 'the native manual recipe must include its publication phase');
	success(
		spawnSync(bashExecutable(), ['-euc', command], {
			cwd: ROOT,
			env: modelEnv,
			encoding: 'utf8',
			timeout: 120000
		})
	);
	assert.deepEqual(findPackages(published), [selected]);
	assert.deepEqual(
		fs.readFileSync(selected),
		mainBytes,
		'direct and manual handoff must publish the same complete main bytes'
	);
	assert.equal(findPackages(nativeRoot).length, 2);
	console.log('PASS rpm-direct-and-manual-publish-one-main-and-retain-debug');

	// Import after the behavioral producer regression: the old implementation
	// fails by choosing debug output, rather than merely lacking this new module.
	const { publishRpmPackage } = require('../build/publish-linux-rpm.cjs');
	let cases = 0;
	function fixture(label, records) {
		const base = path.join(scratch, label);
		const native = path.join(base, 'native');
		const target = path.join(base, 'published');
		fs.mkdirSync(native, { recursive: true });
		fs.mkdirSync(target);
		for (let i = 0; i < records.length; i++)
			fs.writeFileSync(path.join(native, `${i}.rpm`), JSON.stringify(records[i]));
		return {
			nativeRoot: native,
			publishedRoot: target,
			expected,
			readIdentity: (filename) => JSON.parse(fs.readFileSync(filename, 'utf8'))
		};
	}
	function refused(label, records, pattern, mutate) {
		const options = fixture(label, records);
		if (mutate) mutate(options);
		const prior = fs.readdirSync(options.publishedRoot);
		const priorNative = fs.readdirSync(options.nativeRoot);
		assert.throws(() => publishRpmPackage(options), pattern, label);
		assert.deepEqual(
			fs.readdirSync(options.publishedRoot),
			prior,
			`${label}: publication must not use or replace prior output`
		);
		assert.deepEqual(
			fs.readdirSync(options.nativeRoot),
			priorNative,
			'refusal must preserve all native outputs'
		);
		cases++;
	}
	const debug = { ...expected, name: expected.name + '-debuginfo' };
	refused('zero', [], /exactly one main RPM/);
	refused('debug-only', [debug], /exactly one main RPM/);
	refused('multiple', [expected, expected], /exactly one main RPM/);
	refused('foreign-name', [expected, { ...expected, name: 'foreign' }], /foreign RPM identity/);
	refused('stale-version', [expected, { ...debug, version: '1.0.2' }], /foreign RPM identity/);
	refused('foreign-arch', [{ ...expected, arch: 'aarch64' }], /foreign RPM identity/);
	refused('invalid-metadata', [{ ...expected, version: null }], /invalid version/);
	refused('query-failure', [expected], /native query failed/, (options) => {
		options.readIdentity = () => {
			throw new Error('native query failed');
		};
	});
	refused('same-output-root', [expected], /disjoint/, (options) => {
		options.publishedRoot = options.nativeRoot;
	});
	refused('unexpected-output', [expected], /unexpected native RPM output/, (options) => {
		fs.writeFileSync(path.join(options.nativeRoot, 'not-a-package'), 'unexpected');
	});
	refused('symlink-output', [expected], /unexpected native RPM output/, (options) => {
		fs.symlinkSync(
			path.join(options.nativeRoot, '0.rpm'),
			path.join(options.nativeRoot, 'alias.rpm')
		);
	});
	refused('prior-published', [expected], /prior output/, (options) => {
		fs.writeFileSync(path.join(options.publishedRoot, 'stale.rpm'), 'prior artifact');
	});
	refused('copied-identity-changed', [expected], /copied RPM identity/, (options) => {
		const read = options.readIdentity;
		options.readIdentity = (filename) =>
			filename.includes('.ergopti-rpm-publish-') ? debug : read(filename);
	});
	{
		const options = fixture('retry-after-link-failure', [expected]);
		const originalLink = fs.linkSync;
		try {
			fs.linkSync = () => {
				throw new Error('injected publication failure');
			};
			assert.throws(() => publishRpmPackage(options), /injected publication failure/);
		} finally {
			fs.linkSync = originalLink;
		}
		assert.deepEqual(
			fs.readdirSync(options.publishedRoot),
			[],
			'failed link must leave no empty output'
		);
		const retried = publishRpmPackage(options);
		assert.ok(fs.existsSync(retried.artifact), 'publication can be retried without manual cleanup');
	}
	{
		const options = fixture('foreign-during-link-failure', [expected]);
		const originalLink = fs.linkSync;
		const foreign = path.join(options.publishedRoot, expected.arch, 'foreign');
		try {
			fs.linkSync = () => {
				fs.writeFileSync(foreign, 'keep');
				throw new Error('injected publication failure');
			};
			assert.throws(() => publishRpmPackage(options), /publication and cleanup failed/);
		} finally {
			fs.linkSync = originalLink;
		}
		assert.equal(fs.readFileSync(foreign, 'utf8'), 'keep', 'foreign content must survive refusal');
	}
	const positive = fixture('valid-debug-and-main', [
		debug,
		{ ...expected, name: expected.name + '-debugsource' },
		expected
	]);
	const result = publishRpmPackage(positive);
	assert.equal(result.retained, 3);
	assert.equal(findPackages(positive.publishedRoot).length, 1);
	assert.deepEqual(
		fs.readFileSync(result.artifact),
		fs.readFileSync(path.join(positive.nativeRoot, '2.rpm'))
	);
	assert.equal(fs.readdirSync(positive.nativeRoot).length, 3);
	console.log(`PASS rpm-publish-boundary refused=${cases} retained-debug-kinds=2`);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
