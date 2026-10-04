// tools/test/test-macos-bundle-layout.cjs

/**
 * ==============================================================================
 * MODULE: macOS Bundle-Layout Guard
 * DESCRIPTION:
 * Regression guard for the .app bundle's internal driver layout. The
 * static/drivers -> static/ergopti_plus reorg migrated the Lua code to expect
 * the driver at static/ergopti_plus/macos (guarded by the Lua suite's
 * test_download_window_assets_dir and test_config_repo_root), but the macOS
 * packaging kept shipping the driver under the legacy
 * Contents/Resources/static/drivers/hammerspoon prefix. That divergence meant
 * hs.configdir-relative resolution and every gsub("/static/ergopti_plus/macos$")
 * only worked via resilient fallbacks in the bundle, silently differing from a
 * dev checkout.
 *
 * ROOT CAUSE ENCODED:
 * The bundle must mirror the repo layout exactly: the payload manifest
 * (tools/build/macos-bundle-manifest.json, staged by build_macos_app.sh into
 * Contents/Resources/static) maps the driver to static/ergopti_plus/macos and
 * _shared to static/ergopti_plus/_shared, and main.swift points MJConfigDir at
 * the same path. This guard fails if either reverts to the legacy drivers/
 * prefix or the two stop agreeing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const os = require('node:os');
const Archives = require('../build/macos-release-archives.cjs');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const build = read('tools/build/build_macos_app.sh');
const manifest = JSON.parse(read('tools/build/macos-bundle-manifest.json'));
const swift = read('static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/main.swift');

const errors = [];

// 1. The build script must not bundle under the legacy drivers/ prefix...
if (/drivers\/hammerspoon/.test(build)) {
	errors.push(
		'build_macos_app.sh: still bundles the driver under drivers/hammerspoon — must be ergopti_plus/macos.'
	);
}
if (/drivers\/_shared/.test(build)) {
	errors.push(
		'build_macos_app.sh: still bundles _shared under drivers/_shared — must be ergopti_plus/_shared.'
	);
}
// ...and the payload manifest must place both at the repo-mirroring location,
// below the Contents/Resources/static root the build stages it into.
const mirrors = (source, target) =>
	manifest.trees.some((tree) => tree.source === source && tree.target === target);
if (!mirrors('static/ergopti_plus/macos', 'ergopti_plus/macos')) {
	errors.push(
		'macos-bundle-manifest.json: must map static/ergopti_plus/macos to ergopti_plus/macos.'
	);
}
if (!mirrors('static/ergopti_plus/_shared', 'ergopti_plus/_shared')) {
	errors.push(
		'macos-bundle-manifest.json: must map static/ergopti_plus/_shared to ergopti_plus/_shared.'
	);
}
if (
	!build.includes('local static_root="$res/static"') ||
	!build.includes('local res="$APP_PATH/Contents/Resources"') ||
	!build.includes('macos-bundle-payload.cjs" stage "$REPO_ROOT" "$static_root"')
) {
	errors.push(
		'build_macos_app.sh: must stage the payload manifest into Contents/Resources/static.'
	);
}

// 2. The Swift launcher's MJConfigDir must agree with that layout.
if (/static\/drivers\/hammerspoon/.test(swift)) {
	errors.push(
		'main.swift: still points the bundled config dir at static/drivers/hammerspoon — must be static/ergopti_plus/macos.'
	);
}
if (!/static\/ergopti_plus\/macos/.test(swift)) {
	errors.push('main.swift: must point the bundled config dir at static/ergopti_plus/macos.');
}

// 3. Every bundled tool the launcher points the driver at must be one the build
// creates, and every launcher key the boot trail reports must still be exported:
// the launcher kept exporting ERGOPTI_KARABINER_INSTALLER, and the boot trail
// kept reporting it present, after the build stopped vendoring that installer.
const launcherSources = path.join(ROOT, 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus');
const launcherSwift = fs
	.readdirSync(launcherSources)
	.filter((name) => name.endsWith('.swift'))
	.map((name) => fs.readFileSync(path.join(launcherSources, name), 'utf8'))
	.join('\n');
const launcherTools = [
	...launcherSwift.matchAll(/Contents\/Resources\/Tools\/([A-Za-z0-9_-]+)\//g)
].map((match) => match[1]);
// The app now bundles no tool at all (Karabiner-Elements and Ollama are both
// installed on demand), so an empty scan is proven rather than blind only while
// the build creates no Tools folder either.
if (launcherTools.length === 0 && /\$tools_dir\b|Resources\/Tools\/[A-Za-z]/.test(build)) {
	errors.push(
		'main.swift points at no Contents/Resources/Tools path while build_macos_app.sh still ' +
			'bundles one; the tool scan went blind.'
	);
}
for (const tool of new Set(launcherTools)) {
	if (!build.includes(`"$tools_dir/${tool}/`)) {
		errors.push(
			`launcher: points at Contents/Resources/Tools/${tool}, which build_macos_app.sh never bundles.`
		);
	}
}
const environmentLua = read('static/ergopti_plus/macos/infra/launcher_environment.lua');
const reportedKeys = [...environmentLua.matchAll(/^\t"(ERGOPTI_[A-Z_]+)",$/gm)].map(
	(match) => match[1]
);
if (reportedKeys.length === 0) {
	errors.push('launcher_environment.lua: no exported key found; the key scan went blind.');
}
for (const key of reportedKeys) {
	if (!launcherSwift.includes(`"${key}"`)) {
		errors.push(`launcher_environment.lua: reports ${key}, which the Swift launcher never sets.`);
	}
}

// The full producer and source-only helper have separate actual call paths.
const functionBody = (source, name) => {
	const match = [...source.matchAll(/^([a-z_]+)\(\) \{\n([\s\S]*?)^\}/gm)].find(
		(entry) => entry[1] === name
	);
	assert(match, `The actual shell owner ${name} must exist`);
	return match[2].replace(/^\s*#.*$/gm, '');
};
const mainBody = functionBody(build, 'main');
const helperBody = functionBody(build, 'build_native_helper');
assert(
	mainBody.includes('\tverify_app_signature "$APP_PATH/Contents/Frameworks/Hammerspoon.app"'),
	'The full build retains the nested application signature preflight'
);
const producerCall =
	'\tnode "$REPO_ROOT/tools/build/macos-release-archives.cjs" "$APP_PATH" "$BUILD_DIR"';
assert(
	mainBody.includes(producerCall),
	'The full build must invoke the real dual archive producer'
);
assert(
	mainBody.indexOf(producerCall) >
		mainBody.indexOf('verify_app_signature "$APP_PATH/Contents/Frameworks/Hammerspoon.app"'),
	'Full native signatures are verified before archiving'
);
assert(helperBody.includes('\tzip_app\n'), 'The native helper retains its actual ZIP call');
assert(
	!helperBody.includes('macos-release-archives.cjs'),
	'The native helper does not acquire a release archive dependency'
);
assert(
	functionBody(build, 'zip_app').includes('zip -qry -9'),
	'Native helper compression retains its original maximum-deflate contract'
);

const defaults = JSON.parse(fs.readFileSync(shared('modules/updater/defaults.json'), 'utf8'));
assert.deepEqual(Archives.resolveArchives(defaults), [
	{ name: 'ErgoptiPlus.app.tar.xz', format: 'tar.xz' },
	{ name: 'ErgoptiPlus.app.zip', format: 'zip' }
]);
const declaredSingle = structuredClone(defaults);
declaredSingle.release_install.macos_archives = [declaredSingle.release_install.macos_archives[1]];
assert.deepEqual(
	Archives.resolveArchives(declaredSingle),
	[{ name: 'ErgoptiPlus.app.zip', format: 'zip' }],
	'The shared declaration owns production formats; native capability counts are not a second policy'
);
const sparse = structuredClone(defaults);
delete sparse.release_install.macos_archives[1];
sparse.release_install.macos_archives.future = {};
assert.throws(
	() => Archives.resolveArchives(sparse),
	'A hole plus a foreign key cannot masquerade as a dense declaration'
);
for (const mutate of [
	(value) => {
		delete value.release_install;
	},
	(value) => {
		value.release_install.macos_archives = [];
	},
	(value) => {
		value.release_install.macos_archives.future = {};
	},
	(value) => {
		value.release_install.macos_archives[0] = null;
	},
	(value) => {
		value.release_install.macos_archives[0].format = 'unowned';
	},
	(value) => {
		value.release_install.macos_archives[0].asset_key = 'missing';
	},
	(value) => {
		value.release_install.macos_archives[0].format = 'zip';
	},
	(value) => {
		value.release_assets.macos_bundle_tar_xz = '../foreign.tar.xz';
	},
	(value) => {
		value.release_assets.macos_bundle_tar_xz = 'Wrong.zip';
	},
	(value) => {
		value.release_install.macos_archives.push({ asset_key: 'future', format: 'future' });
	}
]) {
	const altered = structuredClone(defaults);
	mutate(altered);
	assert.throws(
		() => Archives.resolveArchives(altered),
		'Malformed producer policy does not choose another format'
	);
}

// Execute the actual producer with a recording native tool boundary. This
// checks argument identity, publication, refusal and source preservation;
// native XCTest supplies real Mac extraction, signatures and metadata proof.
function verifyArchiveProducerContracts(fs, Archives) {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ErgoptiNativeArchiveContracts-'));
	try {
		const app = path.join(scratch, 'ErgoptiPlus.app');
		const resources = path.join(app, 'Contents', 'Resources');
		fs.mkdirSync(resources, { recursive: true });
		fs.writeFileSync(path.join(resources, 'données.txt'), 'Independent Unicode bytes: café 😀\n');
		fs.chmodSync(path.join(resources, 'données.txt'), 0o751);
		fs.symlinkSync('données.txt', path.join(resources, 'owned-link'));
		const native = (events, mutation) => (executable, args, cwd) => {
			assert.equal(cwd, mutation.output);
			if (executable === '/usr/bin/codesign') {
				if (args[0] === '-d') {
					events.push('requirement');
					if (mutation.displayFailure) throw new Error('owned native requirement display refusal');
					if (mutation.display) return mutation.display;
					return { stdout: 'designated => identifier "com.owned.fixture"\n', stderr: '' };
				}
				assert.deepEqual(args.slice(0, 3), ['--verify', '--deep', '--strict']);
				if (args.includes('-R')) {
					if (mutation.requirement) assert.equal(args[4], '=' + mutation.requirement);
					else assert.equal(args[4], '=identifier "com.owned.fixture"');
					events.push('verify-restored');
				} else {
					assert.equal(args[3], app);
					events.push('verify-source');
				}
				return { stdout: '', stderr: '' };
			}
			const zip = executable === '/usr/bin/ditto';
			assert(
				zip || executable === '/usr/bin/tar',
				'No alternate native archive process is admitted'
			);
			const create = args[0] === '-c' || args[0] === '-cJf';
			if (create) {
				if (zip)
					assert.deepEqual(args.slice(0, 7), [
						'-c',
						'-k',
						'--sequesterRsrc',
						'--keepParent',
						'--zlibCompressionLevel',
						'9',
						app
					]);
				else {
					assert.deepEqual(
						args.slice(2, 4),
						['--options', 'xz:compression-level=9'],
						'The actual native producer must request the maximum exposed Apple libarchive XZ preset'
					);
					assert.deepEqual(args.slice(4), ['-C', scratch, '--', 'ErgoptiPlus.app']);
				}
				events.push(zip ? 'create-zip' : 'create-xz');
				fs.writeFileSync(zip ? args[7] : args[1], zip ? 'owned ZIP bytes' : 'owned XZ bytes');
			} else {
				assert.equal(
					args[0],
					zip ? '-x' : '-xJpf',
					'Tar must restore permissions independently of umask'
				);
				if (zip) assert.equal(args[1], '-k');
				else assert.equal(args[2], '-C');
				events.push(zip ? 'extract-zip' : 'extract-xz');
				const restored = path.join(args[3], 'ErgoptiPlus.app');
				fs.cpSync(app, restored, { recursive: true, verbatimSymlinks: true });
				if (mutation.kind === 'bytes')
					fs.appendFileSync(path.join(restored, 'Contents', 'Resources', 'données.txt'), 'foreign');
				if (mutation.kind === 'mode')
					fs.chmodSync(path.join(restored, 'Contents', 'Resources', 'données.txt'), 0o700);
				if (mutation.kind === 'link') {
					fs.unlinkSync(path.join(restored, 'Contents', 'Resources', 'owned-link'));
					fs.symlinkSync('foreign', path.join(restored, 'Contents', 'Resources', 'owned-link'));
				}
			}
			return { stdout: '', stderr: '' };
		};
		const output = path.join(scratch, 'valid');
		fs.mkdirSync(output);
		const events = [];
		const produced = Archives.createArchives(app, output, {
			defaults,
			execute: native(events, { output })
		});
		assert.deepEqual(events, [
			'verify-source',
			'requirement',
			'create-xz',
			'extract-xz',
			'verify-restored',
			'create-zip',
			'extract-zip',
			'verify-restored'
		]);
		assert.deepEqual(
			produced.map(({ name, format }) => ({ name, format })),
			Archives.resolveArchives(defaults)
		);
		assert.equal(
			fs.readFileSync(path.join(output, 'ErgoptiPlus.app.tar.xz'), 'utf8'),
			'owned XZ bytes'
		);
		assert.equal(
			fs.readFileSync(path.join(output, 'ErgoptiPlus.app.zip'), 'utf8'),
			'owned ZIP bytes'
		);
		assert.deepEqual(
			fs.readdirSync(output).sort(),
			['ErgoptiPlus.app.tar.xz', 'ErgoptiPlus.app.zip'],
			'Successful producer retires only its own temporary directory'
		);
		// The native Mac display packet uses this exact commented prefix. Execute
		// the real archive owner so parsing must reach both strict -R readbacks.
		const ownedRequirement =
			'cdhash H"f4b0db2f3ac57d0549d20a3881cd297234fd2e55" or cdhash H"f486f124189b5b56aadf11f0c157456d93c0b6cd"';
		const bareDesignation = 'designated => ' + ownedRequirement + '\n';
		const commentedDesignation = '# designated => ' + ownedRequirement + '\n';
		const displayCases = [
			['bare-stdout', { stdout: bareDesignation, stderr: '' }, true],
			['bare-stderr', { stdout: '', stderr: bareDesignation }, true],
			['commented-stdout', { stdout: commentedDesignation, stderr: '' }, true],
			['commented-stderr', { stdout: '', stderr: commentedDesignation }, true],
			['missing', { stdout: 'owned unrelated output\n', stderr: '' }, false],
			['empty-bare', { stdout: 'designated => \n', stderr: '' }, false],
			['empty-commented', { stdout: '# designated => \n', stderr: '' }, false],
			['duplicate-bare', { stdout: bareDesignation + bareDesignation, stderr: '' }, false],
			[
				'duplicate-commented',
				{ stdout: commentedDesignation + commentedDesignation, stderr: '' },
				false
			],
			['mixed-duplicate', { stdout: bareDesignation, stderr: commentedDesignation }, false],
			[
				'trailing-empty-commented',
				{ stdout: bareDesignation + '# designated => \n', stderr: '' },
				false
			],
			[
				'trailing-empty-bare',
				{ stdout: commentedDesignation + 'designated => \n', stderr: '' },
				false
			],
			[
				'unknown-prefix',
				{ stdout: '## designated => ' + ownedRequirement + '\n', stderr: '' },
				false
			],
			[
				'indented-comment',
				{ stdout: ' # designated => ' + ownedRequirement + '\n', stderr: '' },
				false
			],
			[
				'missing-separator',
				{ stdout: '#designated => ' + ownedRequirement + '\n', stderr: '' },
				false
			]
		];
		for (const [name, display, accepted] of displayCases) {
			const target = path.join(scratch, 'designation-' + name);
			fs.mkdirSync(target);
			const seen = [];
			const invoke = () =>
				Archives.createArchives(app, target, {
					defaults,
					execute: native(seen, { output: target, display, requirement: ownedRequirement })
				});
			if (accepted) {
				assert.deepEqual(
					invoke().map(({ name, format }) => ({ name, format })),
					Archives.resolveArchives(defaults)
				);
				assert.deepEqual(
					seen,
					events,
					name + ' preserves every native signature/archive/readback phase'
				);
				assert.deepEqual(fs.readdirSync(target).sort(), [
					'ErgoptiPlus.app.tar.xz',
					'ErgoptiPlus.app.zip'
				]);
			} else {
				assert.throws(invoke, /no unique designated requirement/, name);
				assert.deepEqual(
					seen,
					['verify-source', 'requirement'],
					name + ' refuses before creating archives'
				);
				assert.deepEqual(fs.readdirSync(target), [], name + ' publishes no output');
			}
		}
		const refusedDisplay = path.join(scratch, 'designation-native-refusal');
		fs.mkdirSync(refusedDisplay);
		const displayEvents = [];
		assert.throws(
			() =>
				Archives.createArchives(app, refusedDisplay, {
					defaults,
					execute: native(displayEvents, {
						output: refusedDisplay,
						displayFailure: true,
						display: { stdout: commentedDesignation, stderr: '' }
					})
				}),
			/owned native requirement display refusal/
		);
		assert.deepEqual(displayEvents, ['verify-source', 'requirement']);
		assert.deepEqual(
			fs.readdirSync(refusedDisplay),
			[],
			'Native display failure cannot authorize comment parsing'
		);
		for (const kind of ['bytes', 'mode', 'link']) {
			const refused = path.join(scratch, kind);
			fs.mkdirSync(refused);
			assert.throws(
				() =>
					Archives.createArchives(app, refused, {
						defaults,
						execute: native([], { output: refused, kind })
					}),
				/changed bundle/,
				kind
			);
			assert.deepEqual(
				fs.readdirSync(refused),
				[],
				'Neither archive is published when native readback changes source semantics'
			);
		}
		for (const kind of ['dangling-link', 'directory']) {
			const collision = path.join(scratch, 'collision-' + kind);
			fs.mkdirSync(collision);
			const held = path.join(collision, 'ErgoptiPlus.app.tar.xz');
			if (kind === 'dangling-link') fs.symlinkSync('foreign-absent', held);
			else fs.mkdirSync(held);
			let started = false;
			assert.throws(
				() =>
					Archives.createArchives(app, collision, {
						defaults,
						execute: () => {
							started = true;
						}
					}),
				/already exists/
			);
			assert.equal(started, false, 'A foreign output never starts a native writer');
			assert.equal(fs.lstatSync(held).isSymbolicLink(), kind === 'dangling-link');
		}
		const aliased = path.join(scratch, 'foreign-root.app');
		fs.symlinkSync(app, aliased);
		assert.throws(
			() =>
				Archives.createArchives(aliased, output, {
					defaults,
					execute: () => {
						throw new Error('No native tool may start');
					}
				}),
			/physical directory/
		);
		const rejectedSignature = path.join(scratch, 'rejected-signature');
		fs.mkdirSync(rejectedSignature);
		assert.throws(
			() =>
				Archives.createArchives(app, rejectedSignature, {
					defaults,
					execute: () => {
						throw new Error('owned native signature refusal');
					}
				}),
			/owned native signature refusal/
		);
		assert.deepEqual(
			fs.readdirSync(rejectedSignature),
			[],
			'Input signature refusal creates no archive or extraction stage'
		);
		const racedOutput = path.join(scratch, 'raced-publication');
		fs.mkdirSync(racedOutput);
		const raceEvents = [];
		const runRace = native(raceEvents, { output: racedOutput });
		assert.throws(
			() =>
				Archives.createArchives(app, racedOutput, {
					defaults,
					execute: (...args) => {
						const result = runRace(...args);
						if (raceEvents.filter((event) => event === 'verify-restored').length === 2)
							fs.writeFileSync(
								path.join(racedOutput, 'ErgoptiPlus.app.zip'),
								'foreign publication'
							);
						return result;
					}
				}),
			{ code: 'EEXIST' },
			'Publication cannot replace a foreign file created after preflight'
		);
		assert.equal(
			fs.readFileSync(path.join(racedOutput, 'ErgoptiPlus.app.zip'), 'utf8'),
			'foreign publication'
		);
		const preexisting = path.join(output, 'ErgoptiPlus.app.zip');
		const held = fs.readFileSync(preexisting);
		assert.throws(
			() =>
				Archives.createArchives(app, output, {
					defaults,
					execute: () => {
						throw new Error('Native process must not start');
					}
				}),
			/already exists/
		);
		assert.deepEqual(
			fs.readFileSync(preexisting),
			held,
			'The producer never replaces an existing output'
		);
		assert.equal(
			fs.readFileSync(path.join(resources, 'données.txt'), 'utf8'),
			'Independent Unicode bytes: café 😀\n'
		);
		assert.equal(fs.lstatSync(path.join(resources, 'données.txt')).mode & 0o777, 0o751);
		assert.equal(fs.readlinkSync(path.join(resources, 'owned-link')), 'données.txt');
	} finally {
		fs.rmSync(scratch, { recursive: true });
	}
}

const {
	ArchiveContractFilesystem,
	loadArchiveProducer,
	verifyArchiveFilesystemModel
} = require('./fixtures/archive-contract-filesystem.cjs');
verifyArchiveFilesystemModel(os.tmpdir());
const ContractFilesystem = new ArchiveContractFilesystem(os.tmpdir());
const ProducerPath = path.join(ROOT, 'tools', 'build', 'macos-release-archives.cjs');
verifyArchiveProducerContracts(
	ContractFilesystem,
	loadArchiveProducer(ProducerPath, ContractFilesystem)
);
if (process.platform !== 'win32') {
	verifyArchiveProducerContracts(fs, Archives);
} else {
	console.log(
		'[INFO] Physical POSIX archive filesystem checks require POSIX; mandatory model contracts passed.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS bundle layout diverges from the repo layout:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] macOS .app bundle mirrors the static/ergopti_plus layout (build script + launcher agree).\x1b[0m'
);
