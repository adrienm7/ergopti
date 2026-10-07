// tools/test/compiled-upgrade-contract.cjs

/** Admits native compiled upgrade/save observations independently of ready. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { parse } = require('smol-toml');
const prior = require('./fixtures/windows-upgrade-prior.json');

const retainedRecords = [
	'# retained installed dashboard bindings',
	'[metrics]',
	'metrics_shortcut_typing = "Ctrl+Alt+M" # retained typing',
	'metrics_shortcut_apps = "Ctrl+Alt+A" # retained apps',
	'future_dashboard = { keep = 9, enabled = false } # retained foreign extension'
];
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** Observes genuine old output without claiming that its serializer kept comments. */
function inspectNativePriorProfile(file, schemaVersion) {
	const bytes = fs.readFileSync(file);
	const source = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
	const model = parse(source.replace(/^\uFEFF/, ''));
	assert.equal(schemaVersion, 6, 'Installed prior registry is not the pinned schema');
	assert.equal(model._meta?.schema_version, schemaVersion, 'Native prior profile schema differs');
	assert.equal(model.metrics?.metrics_enabled, false, 'Native prior Metrics enabled value differs');
	assert.equal(model.metrics?.metrics_shortcut_typing, 'Ctrl+Alt+M');
	assert.equal(model.metrics?.metrics_shortcut_apps, 'Ctrl+Alt+A');
	assert.deepEqual(model.metrics?.future_dashboard, { keep: 9, enabled: false });
	const rows = source.replace(/^\uFEFF/, '').split(/\r?\n/);
	return {
		sha256: hash(bytes),
		schema_version: schemaVersion,
		metrics_enabled: model.metrics.metrics_enabled,
		metrics_shortcut_typing: model.metrics.metrics_shortcut_typing,
		metrics_shortcut_apps: model.metrics.metrics_shortcut_apps,
		future_dashboard: model.metrics.future_dashboard,
		source_records_observed: retainedRecords.filter((record) => rows.includes(record)).length
	};
}

/** Locates only admitted scalar source records in the released writer's layout. */
function installedProfileRecords(bytes) {
	const source = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
	assert.ok(
		!source.includes('"""') && !source.includes("'''"),
		'Unsupported installed multiline source'
	);
	assert.ok(!/\r(?!\n)/.test(source), 'Unsupported installed line endings');
	const lines = source.match(/[^\r\n]*(?:\r\n|\n|$)/g).filter((line) => line !== '');
	let section = '',
		metrics = -1;
	const selected = [];
	const keys = new Set(['metrics_shortcut_typing', 'metrics_shortcut_apps', 'future_dashboard']);
	const seen = new Set();
	let comment = -1;
	for (const [index, line] of lines.entries()) {
		const text = line.replace(/\r?\n$/, '').replace(/^\uFEFF/, '');
		if (text === retainedRecords[0]) {
			assert.equal(comment, -1, 'Duplicate installed retained comment');
			comment = index;
		}
		if (/^\s*\[/.test(text)) {
			const header = text.match(/^\[([A-Za-z0-9_.-]+)\]$/);
			assert.ok(header, 'Unsupported installed section layout');
			section = header[1];
			if (section === 'metrics') {
				assert.equal(metrics, -1, 'Duplicate installed Metrics section');
				metrics = index;
			}
		} else if (section === 'metrics') {
			const key = text.match(/^([A-Za-z0-9_-]+)\s*=/)?.[1];
			if (keys.has(key)) {
				assert.ok(!seen.has(key), 'Duplicate installed target key');
				seen.add(key);
				selected.push([index, key]);
			}
		}
	}
	assert.ok(metrics >= 0 && seen.size === 3, 'Missing installed source records');
	assert.ok(
		comment === -1 || comment === metrics - 1,
		'Retained comment is outside its installed section'
	);
	assert.match(lines[metrics], /\r?\n$/, 'Installed Metrics section has no following line');
	const omitted = new Set(selected.map(([index]) => index));
	if (comment >= 0) omitted.add(comment);
	return {
		lines,
		metrics,
		selected,
		comment,
		untouched: Buffer.from(lines.filter((_, index) => !omitted.has(index)).join(''))
	};
}

/** Models an explicit offline user edit of the observed installed old profile. */
function prepareInstalledUserProfile(file, schemaVersion, nativeOutput, editOutput) {
	const info = fs.lstatSync(file, { bigint: true });
	assert.ok(info.isFile() && !info.isSymbolicLink(), 'Installed source is not a regular file');
	const before = fs.readFileSync(file);
	const native = inspectNativePriorProfile(file, schemaVersion);
	assert.equal(native.sha256, hash(before), 'Native profile changed before observation');
	fs.writeFileSync(nativeOutput + '.toml', before, { flag: 'wx', mode: 0o600 });
	fs.writeFileSync(nativeOutput, JSON.stringify(native) + '\n', { flag: 'wx', mode: 0o600 });
	const records = installedProfileRecords(before);
	const ending = records.lines[records.metrics].endsWith('\r\n') ? '\r\n' : '\n';
	const replacements = new Map([
		['metrics_shortcut_typing', retainedRecords[2]],
		['metrics_shortcut_apps', retainedRecords[3]],
		['future_dashboard', retainedRecords[4]]
	]);
	for (const [index, key] of records.selected) {
		const newline = records.lines[index].match(/\r?\n$/)?.[0] || '';
		records.lines[index] = replacements.get(key) + newline;
	}
	if (records.comment >= 0) records.lines[records.comment] = '';
	records.lines[records.metrics] = retainedRecords[0] + ending + records.lines[records.metrics];
	const after = Buffer.from(records.lines.join(''));
	const afterRecords = installedProfileRecords(after);
	assert.deepEqual(
		afterRecords.untouched,
		records.untouched,
		'Offline edit changed unrelated native source'
	);
	assert.deepEqual(
		parse(after.toString('utf8').replace(/^\uFEFF/, '')),
		parse(before.toString('utf8').replace(/^\uFEFF/, '')),
		'Offline comment edit changed installed values'
	);
	const staged = file + '.installed-user-edit-' + crypto.randomBytes(16).toString('hex') + '.tmp';
	let descriptor;
	try {
		descriptor = fs.openSync(staged, 'wx', 0o600);
		fs.writeFileSync(descriptor, after);
		fs.fsyncSync(descriptor);
		fs.closeSync(descriptor);
		descriptor = undefined;
		assert.deepEqual(fs.readFileSync(staged), after, 'Offline edit staging differs');
		const current = fs.lstatSync(file, { bigint: true });
		assert.ok(
			current.isFile() &&
				!current.isSymbolicLink() &&
				current.dev === info.dev &&
				current.ino === info.ino,
			'Installed source identity changed before edit'
		);
		assert.deepEqual(fs.readFileSync(file), before, 'Installed source changed before edit');
		fs.renameSync(staged, file);
		assert.deepEqual(fs.readFileSync(file), after, 'Offline edit publication differs');
	} finally {
		if (descriptor !== undefined) fs.closeSync(descriptor);
		if (fs.existsSync(staged)) fs.unlinkSync(staged);
	}
	const saved = inspectSavedProfile(file, schemaVersion);
	const published = fs.readFileSync(file);
	assert.equal(hash(published), saved.sha256, 'Edited source changed before retained evidence');
	fs.writeFileSync(editOutput + '.toml', published, { flag: 'wx', mode: 0o600 });
	const receipt = {
		schema_version: 1,
		contract: 'offline-installed-user-edit',
		before_sha256: native.sha256,
		after_sha256: saved.sha256,
		untouched_before_sha256: hash(records.untouched),
		untouched_after_sha256: hash(afterRecords.untouched),
		profile_schema_version: schemaVersion,
		preserved_records: 5,
		changed: !before.equals(after)
	};
	fs.writeFileSync(editOutput, JSON.stringify(receipt) + '\n', { flag: 'wx', mode: 0o600 });
	return { native_profile_before_edit: native, installed_user_edit: receipt, saved_profile: saved };
}

/** Binds the native old output to the independently observed upgrade input. */
function verifyInstalledUserBoundary(old) {
	const native = old.native_profile_before_edit;
	assert.ok(native && typeof native === 'object', 'Missing native prior profile before edit');
	assert.deepEqual(
		Object.keys(native).sort(),
		[
			'sha256',
			'schema_version',
			'metrics_enabled',
			'metrics_shortcut_typing',
			'metrics_shortcut_apps',
			'future_dashboard',
			'source_records_observed'
		].sort(),
		'Malformed native prior profile'
	);
	assert.match(native.sha256, /^[0-9a-f]{64}$/);
	assert.equal(native.schema_version, prior.config_schema_version);
	assert.equal(native.metrics_enabled, false);
	assert.equal(native.metrics_shortcut_typing, 'Ctrl+Alt+M');
	assert.equal(native.metrics_shortcut_apps, 'Ctrl+Alt+A');
	assert.deepEqual(native.future_dashboard, { keep: 9, enabled: false });
	assert.ok(
		Number.isSafeInteger(native.source_records_observed) &&
			native.source_records_observed >= 0 &&
			native.source_records_observed <= 5,
		'Invalid native source-record observation'
	);
	const edit = old.installed_user_edit;
	assert.ok(edit && typeof edit === 'object', 'Missing offline installed-user edit boundary');
	assert.deepEqual(
		Object.keys(edit).sort(),
		[
			'schema_version',
			'contract',
			'before_sha256',
			'after_sha256',
			'untouched_before_sha256',
			'untouched_after_sha256',
			'profile_schema_version',
			'preserved_records',
			'changed'
		].sort(),
		'Malformed installed-user edit boundary'
	);
	assert.equal(edit.schema_version, 1);
	assert.equal(edit.contract, 'offline-installed-user-edit');
	assert.equal(edit.before_sha256, native.sha256, 'Boundary borrowed another native profile');
	assert.equal(
		edit.after_sha256,
		old.saved_profile.sha256,
		'Upgrade input differs from the edited native profile'
	);
	assert.match(edit.untouched_before_sha256, /^[0-9a-f]{64}$/);
	assert.equal(
		edit.untouched_after_sha256,
		edit.untouched_before_sha256,
		'Offline edit lost unrelated native bytes'
	);
	assert.equal(edit.profile_schema_version, prior.config_schema_version);
	assert.equal(edit.preserved_records, 5);
	assert.equal(edit.changed, edit.before_sha256 !== edit.after_sha256);
}

/** Requires a fresh, strict generation acknowledgment from the ready process. */
function verifyFullSave(receipt, startup, sha) {
	assert.ok(receipt && typeof receipt === 'object', 'Missing compiled full-save receipt');
	assert.deepEqual(
		Object.keys(receipt).sort(),
		[
			'schema_version',
			'nonce',
			'pid',
			'executable',
			'compiled',
			'build_commit',
			'bundle_identity',
			'requested',
			'committed',
			'settled',
			'pending'
		].sort(),
		'Malformed compiled full-save receipt'
	);
	for (const [key, value] of Object.entries({
		schema_version: 1,
		nonce: startup.nonce,
		pid: startup.pid,
		compiled: true,
		build_commit: sha,
		bundle_identity: startup.receipt.bundle_identity,
		pending: false
	}))
		assert.equal(receipt[key], value, 'Foreign or incomplete compiled full save: ' + key);
	assert.equal(typeof receipt.executable, 'string');
	assert.equal(
		path.win32.normalize(receipt.executable).toLowerCase(),
		path.win32.normalize(startup.executable).toLowerCase(),
		'Full save came from another executable'
	);
	for (const key of ['requested', 'committed', 'settled'])
		assert.ok(
			Number.isSafeInteger(receipt[key]) && receipt[key] > 0,
			'Invalid full-save generation: ' + key
		);
	assert.ok(receipt.committed >= receipt.requested, 'Full save is uncommitted');
	assert.ok(receipt.settled >= receipt.requested, 'Full save is unsettled');
}

/** Checks the actual saved image, retaining unknown source independently of typing. */
function inspectSavedProfile(file, schemaVersion) {
	const bytes = fs.readFileSync(file);
	const source = bytes.toString('utf8').replace(/^\uFEFF/, '');
	const rows = source.split(/\r?\n/);
	const records = [
		'# retained installed dashboard bindings',
		'[metrics]',
		'metrics_shortcut_typing = "Ctrl+Alt+M" # retained typing',
		'metrics_shortcut_apps = "Ctrl+Alt+A" # retained apps',
		'future_dashboard = { keep = 9, enabled = false } # retained foreign extension'
	];
	for (const record of records)
		assert.equal(
			rows.filter((row) => row === record).length,
			1,
			'An installed retired Metrics source record was lost or duplicated'
		);
	const decoded = parse(source);
	assert.equal(decoded._meta?.schema_version, schemaVersion, 'Installed schema did not advance');
	assert.equal(decoded.metrics?.metrics_shortcut_typing, 'Ctrl+Alt+M');
	assert.equal(decoded.metrics?.metrics_shortcut_apps, 'Ctrl+Alt+A');
	assert.equal(decoded.metrics?.future_dashboard?.keep, 9);
	assert.equal(decoded.metrics?.future_dashboard?.enabled, false);
	return {
		sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
		preserved_records: records.length,
		schema_version: schemaVersion
	};
}

/** Requires the real prior-package boot and two different current-process launches. */
function verifyUpgrade(summary, sha, packageDigest, verifyStartup, schemaVersion) {
	assert.ok(summary && typeof summary === 'object', 'Missing compiled upgrade evidence');
	assert.equal(summary.schema_version, 1);
	assert.ok(
		Number.isSafeInteger(schemaVersion) && schemaVersion > prior.config_schema_version,
		'Missing current canonical configuration schema'
	);
	const old = summary.prior_install;
	assert.ok(old && typeof old === 'object', 'Missing genuine prior installation');
	assert.equal(old.package_sha256, prior.sha256, 'Prior package is not the trusted release');
	assert.notEqual(
		old.package_sha256,
		packageDigest,
		'The current binary cannot stand in for the old release'
	);
	assert.equal(old.asset_id, prior.asset_id);
	assert.equal(old.version, prior.version);
	assert.equal(old.commit, prior.commit);
	assert.equal(
		old.bundle_identity,
		prior.version,
		'The actual released old bundle was not installed'
	);
	assert.ok(Number.isSafeInteger(old.pid) && old.pid > 0);
	assert.ok(typeof old.executable === 'string' && path.win32.isAbsolute(old.executable));
	assert.equal(path.win32.basename(old.executable).toLowerCase(), 'ergoptiplus.exe');
	assert.match(old.created_utc, /^\d{4}-\d\d-\d\dT/);
	assert.equal(old.exit_code, 0);
	assert.equal(old.tree_closed, true, 'Prior installation process ownership is unresolved');
	assert.match(old.saved_profile?.sha256, /^[0-9a-f]{64}$/);
	assert.equal(old.saved_profile.preserved_records, 5);
	assert.equal(
		old.saved_profile.schema_version,
		prior.config_schema_version,
		'The edited installed upgrade input did not retain the pinned prior schema'
	);
	verifyInstalledUserBoundary(old);
	assert.deepEqual(
		old.extracted_assets,
		prior.extracted_assets,
		'Prior extracted assets differ from the verified released payload'
	);
	assert.equal(
		summary.launches?.length,
		2,
		'Both upgraded and installed warm launches are required'
	);
	const nonces = new Set();
	const identities = new Set();
	for (const launch of summary.launches) {
		verifyStartup(launch.native_startup, sha, packageDigest);
		verifyFullSave(launch.full_save, launch.native_startup, sha);
		assert.equal(launch.tree_closed, true, 'Compiled upgrade process tree is still owned');
		assert.equal(launch.wal_absent, true, 'Compiled save retained WAL debt');
		assert.equal(
			launch.bundle_workspace_absent,
			true,
			'Installed bundle retained staging or rollback debt'
		);
		assert.match(launch.saved_profile?.sha256, /^[0-9a-f]{64}$/);
		assert.equal(launch.saved_profile.preserved_records, 5);
		assert.equal(
			launch.saved_profile.schema_version,
			schemaVersion,
			'Installed saved profile differs from the current canonical schema'
		);
		nonces.add(launch.native_startup.nonce);
		assert.match(launch.created_utc, /^\d{4}-\d\d-\d\dT/);
		identities.add(launch.native_startup.pid + '/' + launch.created_utc);
	}
	assert.equal(nonces.size, 2, 'The installed warm launch borrowed an earlier nonce');
	assert.equal(identities.size, 2, 'The installed warm launch borrowed an earlier native process');
	assert.equal(
		summary.launches[0].saved_profile.schema_version,
		summary.launches[1].saved_profile.schema_version,
		'Installed schema changed between current launches'
	);
}

module.exports = {
	prior,
	verifyFullSave,
	inspectSavedProfile,
	verifyUpgrade,
	inspectNativePriorProfile,
	prepareInstalledUserProfile,
	verifyInstalledUserBoundary
};

if (require.main === module) {
	const [command, file, registryFile, output, editOutput] = process.argv.slice(2);
	if (command === 'prepare-installed-user-profile') {
		assert.equal(process.argv.length, 7);
		const registry = parse(fs.readFileSync(registryFile, 'utf8'));
		prepareInstalledUserProfile(file, registry.registry.current_version, output, editOutput);
		process.exit(0);
	}
	assert.equal(command, 'inspect-profile');
	assert.equal(process.argv.length, 6);
	const registry = parse(fs.readFileSync(registryFile, 'utf8'));
	const result = inspectSavedProfile(file, registry.registry.current_version);
	fs.writeFileSync(output, JSON.stringify(result) + '\n', { flag: 'wx' });
}
