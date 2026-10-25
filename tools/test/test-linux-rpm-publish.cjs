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

const ROOT = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-rpm-publish-'));
const expected = { name: 'ergopti', version: '1.0.3', arch: 'x86_64' };
const env = { ...process.env, ERGOPTI_BUILD_VERSION: expected.version };
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
	const direct = success(bash(producer, [], modelEnv));
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
	const published = path.join(ROOT, 'build/linux/rpm/RPMS');
	assert.deepEqual(
		findPackages(published),
		[selected],
		'the release consumer must see exactly one admitted main'
	);
	const nativeRoot = path.join(ROOT, 'build/linux/rpm/native-rpms');
	assert.equal(
		findPackages(nativeRoot).length,
		2,
		'all raw/debug native outputs must remain retained'
	);
	const mainBytes = fs.readFileSync(selected);
	const staged = success(bash(producer, ['--skip-rpm'], modelEnv));
	assert.deepEqual(
		fs.readFileSync(path.join(ROOT, 'build/linux/rpm/publish-linux-rpm.cjs')),
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
