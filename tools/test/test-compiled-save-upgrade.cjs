// tools/test/test-compiled-save-upgrade.cjs

/** Independent saved-file and compiled generation/upgrade admission controls. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
	verifyUpgrade,
	inspectSavedProfile,
	prepareInstalledUserProfile
} = require('./compiled-upgrade-contract.cjs');

/** Authored native-input data; no native process runs in these portable controls. */
function healthyUpgrade(sha = 'a'.repeat(40), digest = 'b'.repeat(64)) {
	const executable = 'C:\\private\\ErgoptiPlus.exe';
	return {
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
			saved_profile: {
				sha256: '9'.repeat(64),
				preserved_records: 5,
				schema_version: 6
			},
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
			const nonce = (index ? 'e' : 'd').repeat(32);
			const pid = 43 + index;
			const bundle_identity = '0.0.0-dev\n' + sha;
			return {
				native_startup: {
					nonce,
					pid,
					executable,
					launched_sha256: digest,
					exit_code: 0,
					log_files: 1,
					logged_errors: [],
					receipt: {
						schema_version: 1,
						nonce,
						pid,
						executable,
						compiled: true,
						build_commit: sha,
						bundle_identity,
						phase: 'ready',
						driver_ready: true,
						menu_ready: true,
						logs_flushed: true
					}
				},
				created_utc: `2026-10-07T12:00:0${index + 1}.0000000Z`,
				full_save: {
					schema_version: 1,
					nonce,
					pid,
					executable,
					compiled: true,
					build_commit: sha,
					bundle_identity,
					requested: 1,
					committed: 1,
					settled: 1,
					pending: false
				},
				tree_closed: true,
				wal_absent: true,
				bundle_workspace_absent: true,
				saved_profile: {
					sha256: (index ? 'f' : 'c').repeat(64),
					preserved_records: 5,
					schema_version: 11
				}
			};
		})
	};
}

/** Rejects independently authored mutations through the actual new admission API. */
function runContractCases(verifyStartup) {
	const sha = 'a'.repeat(40);
	const digest = 'b'.repeat(64);
	const healthy = healthyUpgrade();
	const validate = (subject) => verifyUpgrade(subject, sha, digest, verifyStartup, 11);
	validate(healthy);
	let refused = 0;
	for (const mutate of [
		(s) => {
			delete s.prior_install;
		},
		(s) => {
			s.prior_install.package_sha256 = digest;
		},
		(s) => {
			s.prior_install.package_sha256 = 'c'.repeat(64);
		},
		(s) => {
			s.prior_install.asset_id++;
		},
		(s) => {
			s.prior_install.bundle_identity = '0.0.0-dev\n' + sha;
		},
		(s) => {
			s.prior_install.exit_code = 1;
		},
		(s) => {
			s.prior_install.tree_closed = false;
		},
		(s) => {
			delete s.prior_install.saved_profile;
		},
		(s) => {
			s.prior_install.saved_profile.schema_version = 11;
		},
		(s) => {
			s.prior_install.saved_profile.preserved_records = 4;
		},
		(s) => {
			s.prior_install.extracted_assets.pop();
		},
		(s) => {
			s.prior_install.extracted_assets[0].sha256 = 'c'.repeat(64);
		},
		(s) => {
			s.launches.pop();
		},
		(s) => {
			s.launches[1] = structuredClone(s.launches[0]);
		}
	]) {
		const changed = structuredClone(healthy);
		mutate(changed);
		assert.throws(() => validate(changed));
		refused++;
	}
	for (const index of [0, 1]) {
		for (const mutate of [
			(l) => {
				delete l.full_save;
			},
			(l) => {
				l.full_save.nonce = 'a'.repeat(32);
			},
			(l) => {
				l.full_save.pid = 999;
			},
			(l) => {
				l.full_save.executable = 'C:\\foreign\\ErgoptiPlus.exe';
			},
			(l) => {
				l.full_save.compiled = false;
			},
			(l) => {
				l.full_save.build_commit = 'f'.repeat(40);
			},
			(l) => {
				l.full_save.bundle_identity = 'old\n' + sha;
			},
			(l) => {
				l.full_save.requested = 0;
			},
			(l) => {
				l.full_save.requested = '1';
			},
			(l) => {
				l.full_save.committed = 0;
				l.full_save.settled = 1;
			},
			(l) => {
				l.full_save.settled = 0;
			},
			(l) => {
				l.full_save.pending = true;
			},
			(l) => {
				l.tree_closed = false;
			},
			(l) => {
				l.wal_absent = false;
			},
			(l) => {
				l.bundle_workspace_absent = false;
			},
			(l) => {
				l.saved_profile.preserved_records = 4;
			},
			(l) => {
				l.saved_profile.schema_version = 10;
			},
			(l) => {
				l.saved_profile.sha256 = '';
			},
			(l) => {
				l.native_startup.receipt.phase = 'extracting';
			}
		]) {
			const changed = structuredClone(healthy);
			mutate(changed.launches[index]);
			assert.throws(() => validate(changed));
			refused++;
		}
	}
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-upgrade-profile-'));
	try {
		const file = path.join(root, 'config.toml');
		const source =
			'[_meta]\nschema_version = 11\n\n# retained installed dashboard bindings\n[metrics]\n' +
			'metrics_shortcut_typing = "Ctrl+Alt+M" # retained typing\n' +
			'metrics_shortcut_apps = "Ctrl+Alt+A" # retained apps\n' +
			'future_dashboard = { keep = 9, enabled = false } # retained foreign extension\n';
		fs.writeFileSync(file, '\uFEFF' + source + '\n[unrelated]\nowned = true\n');
		assert.equal(inspectSavedProfile(file, 11).preserved_records, 5);
		for (const mutate of [
			(s) => s.replace(' # retained typing', ''),
			(s) => s.replace('# retained installed dashboard bindings\n', ''),
			(s) => s.replace('Ctrl+Alt+A', 'Ctrl+Alt+B'),
			(s) => s.replace('keep = 9', 'keep = 10'),
			(s) => s.replace('enabled = false', 'enabled = 0'),
			(s) => s.replace('schema_version = 11', 'schema_version = 6'),
			(s) => s + '# retained installed dashboard bindings\n',
			(s) => s + '\n[broken\n'
		]) {
			fs.writeFileSync(file, mutate(source));
			assert.throws(() => inspectSavedProfile(file, 11));
			refused++;
		}
		fs.unlinkSync(file);
		assert.throws(() => inspectSavedProfile(file, 11));
		refused++;
	} finally {
		fs.rmSync(root, { recursive: true });
	}
	assert.equal(
		refused,
		61,
		'All authored generation, real saved-file and installation controls execute'
	);
	return refused;
}

/** Literal boundary refusals complement every unchanged startup/save assertion. */
function runBoundaryCases(verifyStartup) {
	const healthy = healthyUpgrade();
	const validate = (subject) =>
		verifyUpgrade(subject, 'a'.repeat(40), 'b'.repeat(64), verifyStartup, 11);
	validate(healthy);
	for (const observed of [0, 1, 5]) {
		const input = structuredClone(healthy);
		input.prior_install.native_profile_before_edit.source_records_observed = observed;
		validate(input);
	}
	let refused = 0;
	for (const mutate of [
		(o) => {
			delete o.native_profile_before_edit;
		},
		(o) => {
			o.native_profile_before_edit.sha256 = '0';
		},
		(o) => {
			o.native_profile_before_edit.schema_version = 11;
		},
		(o) => {
			o.native_profile_before_edit.metrics_enabled = 0;
		},
		(o) => {
			o.native_profile_before_edit.metrics_shortcut_typing = 'Ctrl+Alt+Z';
		},
		(o) => {
			o.native_profile_before_edit.metrics_shortcut_apps = false;
		},
		(o) => {
			o.native_profile_before_edit.future_dashboard.enabled = 0;
		},
		(o) => {
			o.native_profile_before_edit.source_records_observed = 6;
		},
		(o) => {
			o.native_profile_before_edit.extra = true;
		},
		(o) => {
			delete o.installed_user_edit;
		},
		(o) => {
			o.installed_user_edit.before_sha256 = '2'.repeat(64);
		},
		(o) => {
			o.installed_user_edit.after_sha256 = '3'.repeat(64);
		},
		(o) => {
			o.installed_user_edit.untouched_before_sha256 = '';
		},
		(o) => {
			o.installed_user_edit.untouched_after_sha256 = '2'.repeat(64);
		},
		(o) => {
			o.installed_user_edit.contract = 'fresh-profile-copy';
		},
		(o) => {
			o.installed_user_edit.profile_schema_version = 11;
		},
		(o) => {
			o.installed_user_edit.preserved_records = 4;
		},
		(o) => {
			o.installed_user_edit.changed = false;
		},
		(o) => {
			o.installed_user_edit.extra = true;
		}
	]) {
		const bad = structuredClone(healthy);
		mutate(bad.prior_install);
		assert.throws(() => validate(bad));
		refused++;
	}
	assert.equal(refused, 19, 'Every independently authored installed-boundary refusal executes');
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-installed-user-edit-'));
	const native =
		'\uFEFF# actual native unrelated source\r\n[_meta]\r\nschema_version = 6\r\n' +
		'[script]\r\nlocale = "en" # keep verbatim\r\n[metrics]\r\nmetrics_enabled = false\r\n' +
		'metrics_shortcut_typing = "Ctrl+Alt+M"\r\nmetrics_shortcut_apps = "Ctrl+Alt+A"\r\n' +
		'future_dashboard = {enabled = false, keep = 9}\r\n' +
		'"extra key" = "日本 é <literal>" # retained unknown\r\n[unrelated]\r\nvalue = 7\r\n# final unknown';
	try {
		const file = path.join(root, 'config.toml');
		const nativeOutput = path.join(root, 'native.json');
		const editOutput = path.join(root, 'edit.json');
		fs.writeFileSync(file, native);
		const observed = prepareInstalledUserProfile(file, 6, nativeOutput, editOutput);
		assert.equal(
			observed.native_profile_before_edit.source_records_observed,
			1,
			'canonical old output admits its actual comment loss'
		);
		assert.deepEqual(fs.readFileSync(nativeOutput + '.toml'), Buffer.from(native));
		assert.equal(observed.installed_user_edit.changed, true);
		assert.equal(observed.saved_profile.preserved_records, 5);
		const edited = fs.readFileSync(file, 'utf8');
		const expected = native
			.replace('[metrics]\r\n', '# retained installed dashboard bindings\r\n[metrics]\r\n')
			.replace(
				'metrics_shortcut_typing = "Ctrl+Alt+M"\r\n',
				'metrics_shortcut_typing = "Ctrl+Alt+M" # retained typing\r\n'
			)
			.replace(
				'metrics_shortcut_apps = "Ctrl+Alt+A"\r\n',
				'metrics_shortcut_apps = "Ctrl+Alt+A" # retained apps\r\n'
			)
			.replace(
				'future_dashboard = {enabled = false, keep = 9}\r\n',
				'future_dashboard = { keep = 9, enabled = false } # retained foreign extension\r\n'
			);
		assert.deepEqual(
			Buffer.from(edited),
			Buffer.from(expected),
			'Every unrelated native byte, BOM, CRLF and final line survives'
		);
		assert.deepEqual(
			fs.readFileSync(editOutput + '.toml'),
			Buffer.from(expected),
			'the actual post-edit boundary bytes remain in evidence'
		);
		const digest = (text) =>
			require('node:crypto').createHash('sha256').update(Buffer.from(text)).digest('hex');
		assert.equal(observed.native_profile_before_edit.sha256, digest(native));
		assert.equal(observed.installed_user_edit.before_sha256, digest(native));
		assert.equal(observed.installed_user_edit.after_sha256, digest(expected));
		assert.equal(observed.saved_profile.sha256, digest(expected));
		const actualBoundary = healthyUpgrade();
		Object.assign(actualBoundary.prior_install, observed);
		validate(actualBoundary);
		const second = prepareInstalledUserProfile(
			file,
			6,
			path.join(root, 'second-native.json'),
			path.join(root, 'second-edit.json')
		);
		assert.equal(second.native_profile_before_edit.source_records_observed, 5);
		assert.equal(
			second.installed_user_edit.changed,
			false,
			'already preserved old source needs no invented change'
		);
		assert.equal(second.installed_user_edit.before_sha256, second.installed_user_edit.after_sha256);
		const registry = path.join(root, 'prior-registry.toml');
		const cliFile = path.join(root, 'actual-cli-config.toml');
		fs.writeFileSync(registry, '[registry]\ncurrent_version = 6\n');
		fs.writeFileSync(cliFile, native);
		const cli = require('node:child_process').spawnSync(
			process.execPath,
			[
				require.resolve('./compiled-upgrade-contract.cjs'),
				'prepare-installed-user-profile',
				cliFile,
				registry,
				path.join(root, 'cli-native.json'),
				path.join(root, 'cli-edit.json')
			],
			{ encoding: 'utf8' }
		);
		assert.equal(cli.status, 0, cli.stderr);
		assert.deepEqual(
			fs.readFileSync(cliFile),
			Buffer.from(expected),
			'the actual native-driver CLI keeps the same byte boundary'
		);
		assert.deepEqual(fs.readFileSync(path.join(root, 'cli-native.json.toml')), Buffer.from(native));
		assert.equal(
			JSON.parse(fs.readFileSync(path.join(root, 'cli-edit.json'))).preserved_records,
			5
		);
		const racedFile = path.join(root, 'raced-config.toml');
		fs.writeFileSync(racedFile, native);
		const changedExternally = native.replace('# final unknown', '# independently changed source');
		const open = fs.openSync;
		try {
			fs.openSync = function (target, ...args) {
				const descriptor = open.call(fs, target, ...args);
				if (String(target).startsWith(racedFile + '.installed-user-edit-')) {
					fs.writeFileSync(racedFile, changedExternally);
				}
				return descriptor;
			};
			assert.throws(
				() =>
					prepareInstalledUserProfile(
						racedFile,
						6,
						path.join(root, 'raced-native.json'),
						path.join(root, 'raced-edit.json')
					),
				/Installed source changed before edit/
			);
		} finally {
			fs.openSync = open;
		}
		assert.deepEqual(
			fs.readFileSync(racedFile),
			Buffer.from(changedExternally),
			'stale edit cannot overwrite independent native-source replacement'
		);
		for (const [index, source] of [
			native.replace('metrics_enabled = false', 'metrics_enabled = 0'),
			native.replace('schema_version = 6', 'schema_version = 11'),
			native.replace('Ctrl+Alt+M', 'Ctrl+Alt+Z'),
			native.replace('keep = 9', 'keep = 10'),
			native.replace('value = 7', 'value = """\n[metrics]\n"""'),
			native + '\r\n[metrics]\r\nmetrics_shortcut_typing = "Ctrl+Alt+M"'
		].entries()) {
			fs.writeFileSync(file, source);
			assert.throws(() =>
				prepareInstalledUserProfile(
					file,
					6,
					path.join(root, index + '.json'),
					path.join(root, index + '.edit.json')
				)
			);
			assert.deepEqual(
				fs.readFileSync(file),
				Buffer.from(source),
				'refused edit leaves actual source intact'
			);
		}
		assert.equal(
			fs.readdirSync(root).filter((name) => name.endsWith('.tmp')).length,
			0,
			'no offline staging debt'
		);
	} finally {
		fs.rmSync(root, { recursive: true });
	}
	return refused;
}

module.exports = { healthyUpgrade, runContractCases, runBoundaryCases };

if (require.main === module) {
	const { verifyWindowsStartup } = require('./desktop-ci-evidence.cjs');
	console.log(
		`Compiled upgrade admission: ${runContractCases(verifyWindowsStartup)} refusal controls passed (Win32 unexecuted).`
	);
	console.log(
		`Installed-user boundary: ${runBoundaryCases(verifyWindowsStartup)} refusals and actual byte-preserving file edits passed (Win32 unexecuted).`
	);
}
