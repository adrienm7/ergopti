// tools/test/test-linux-canonical-pack-upgrade.cjs

/**
 * ==============================================================================
 * MODULE: Linux Canonical-Pack Upgrade Gate
 * DESCRIPTION:
 * Replays a standalone N to N+1 upgrade. Intact installer seeds must retire so
 * the new bundle supplies additions, corrections, and removals, while any
 * modified user pack remains the active explicit override.
 * ==============================================================================
 */

'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const INSTALLER = path.join(DRIVER, 'install.sh');
const MIGRATOR = path.join(DRIVER, 'install', 'canonical_packs.sh');
const CONFIG_MANAGER = path.join(DRIVER, 'modules', 'hotstrings', 'hotstrings_config.lua');

function fail(message) {
	throw new Error(message);
}

function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function bashPath(value) {
	const normalized = path.resolve(value).replaceAll('\\', '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):\//, (_, drive) => `/${drive.toLowerCase()}/`);
}

function bashExecutable() {
	if (process.platform !== 'win32') return 'bash';
	const candidates = [
		path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe'),
		path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Git', 'bin', 'bash.exe'),
	];
	const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
	if (!found) fail('Git Bash is required to replay the Linux standalone migration on Windows');
	return found;
}

function write(file, content) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, content, 'utf8');
}

function runMigration(sourceDir, installedDir, configDir) {
	const command = [
		'set -euo pipefail',
		`source ${shellQuote(bashPath(MIGRATOR))}`,
		`migrate_canonical_packs ${shellQuote(bashPath(sourceDir))} ${shellQuote(bashPath(installedDir))} ${shellQuote(bashPath(configDir))}`,
	].join('; ');
	const result = childProcess.spawnSync(bashExecutable(), ['-lc', command], {
		cwd: ROOT,
		encoding: 'utf8',
	});
	if (result.status !== 0) {
		fail(`canonical-pack migration failed (${result.status}): ${result.stderr || result.stdout}`);
	}
}

function copyBundle(sourceDir, installedDir) {
	fs.mkdirSync(installedDir, { recursive: true });
	for (const name of fs.readdirSync(sourceDir)) {
		if (name.endsWith('.toml')) fs.copyFileSync(path.join(sourceDir, name), path.join(installedDir, name));
	}
}

const installer = fs.readFileSync(INSTALLER, 'utf8');
const migrationCall = installer.indexOf('migrate_canonical_packs');
const sharedCopy = installer.indexOf('cp -r "${SRC_SHARED}/." "${DEST_SHARED}/"');
if (migrationCall < 0 || sharedCopy < 0 || migrationCall >= sharedCopy) {
	fail('install.sh must classify legacy seeds against the old installed bundle before replacing it');
}
if (installer.includes('install -m 0644 "${toml}" "${dest}"')) {
	fail('install.sh must not seed complete canonical packs into the user override directory');
}
const configManager = fs.readFileSync(CONFIG_MANAGER, 'utf8');
const bundledResolution = configManager.indexOf('Loader.find_toml_files(bundled)');
const userResolution = configManager.indexOf('Loader.find_toml_files(_config_dir)');
if (bundledResolution < 0 || userResolution < 0 || bundledResolution >= userResolution) {
	fail('fresh runtime resolution must load the bundle first and overlay explicit user packs second');
}

const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-canonical-upgrade-'));
const sourceN2 = path.join(sandbox, 'source-n2');
const installed = path.join(sandbox, 'installed');
const config = path.join(sandbox, 'config');

try {
	const oldCanonical = '[pack]\ncorrected = "old"\nremoved = true\n';
	const newCanonical = '[pack]\ncorrected = "new"\nadded = true\n';
	const oldCustomized = '[pack]\nvalue = "old default"\n';
	const userCustomized = '[pack]\nvalue = "my explicit override"\n';

	write(path.join(installed, 'canonical.toml'), oldCanonical);
	write(path.join(installed, 'customized.toml'), oldCustomized);
	write(path.join(sourceN2, 'canonical.toml'), newCanonical);
	write(path.join(sourceN2, 'customized.toml'), '[pack]\nvalue = "new default"\n');
	write(path.join(sourceN2, 'fresh.toml'), '[pack]\nadded_in_n2 = true\n');
	write(path.join(config, 'canonical.toml'), oldCanonical);
	write(path.join(config, 'customized.toml'), userCustomized);

	runMigration(sourceN2, installed, config);

	const marker = path.join(config, '.ergopti-canonical-packs-v2');
	const backup = path.join(config, '.ergopti-migrations', 'canonical-seeds', 'canonical.toml.legacy-seed');
	if (fs.existsSync(path.join(config, 'canonical.toml'))) fail('an intact legacy seed still masks the bundle');
	if (fs.readFileSync(backup, 'utf8') !== oldCanonical) fail('the retired legacy seed was not retained byte-for-byte');
	if (fs.readFileSync(marker, 'utf8') !== '2\n') fail('the one-time migration marker was not committed');
	if (fs.readFileSync(path.join(config, 'customized.toml'), 'utf8') !== userCustomized) {
		fail('a modified user pack was not preserved as an explicit override');
	}
	if (fs.existsSync(path.join(config, 'fresh.toml'))) fail('a fresh install still seeded a canonical user copy');

	copyBundle(sourceN2, installed);
	const resolvedCanonical = fs.readFileSync(path.join(installed, 'canonical.toml'), 'utf8');
	if (!resolvedCanonical.includes('corrected = "new"')) fail('N+1 correction did not become active');
	if (!resolvedCanonical.includes('added = true')) fail('N+1 addition did not become active');
	if (resolvedCanonical.includes('removed = true')) fail('removed N content remained active after upgrade');
	if (fs.readFileSync(path.join(config, 'customized.toml'), 'utf8') !== userCustomized) {
		fail('fresh resolution no longer gives the explicit user override precedence');
	}

	const freshResolver = String.raw`
		const fs = require('fs');
		const path = require('path');
		const [installed, config] = process.argv.slice(1);
		const byStem = {};
		function walk(dir) {
			if (!fs.existsSync(dir)) return [];
			return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
				const absolute = path.join(dir, entry.name);
				return entry.isDirectory() ? walk(absolute) : [absolute];
			});
		}
		for (const root of [installed, config]) {
			for (const file of walk(root).filter((candidate) => candidate.endsWith('.toml'))) {
				byStem[path.basename(file, '.toml')] = file;
			}
		}
		process.stdout.write(JSON.stringify(byStem));
	`;
	const freshProcess = childProcess.spawnSync(process.execPath, ['-e', freshResolver, installed, config], {
		encoding: 'utf8',
	});
	if (freshProcess.status !== 0) fail(`fresh resolver process failed: ${freshProcess.stderr}`);
	const resolved = JSON.parse(freshProcess.stdout);
	if (path.resolve(resolved.canonical) !== path.resolve(installed, 'canonical.toml')) {
		fail('a fresh process did not resolve the migrated category from N+1');
	}
	if (path.resolve(resolved.customized) !== path.resolve(config, 'customized.toml')) {
		fail('a fresh process did not resolve the modified pack as an explicit override');
	}
	if (path.resolve(resolved.fresh) !== path.resolve(installed, 'fresh.toml')) {
		fail('a fresh process did not resolve the newly added N+1 category');
	}

	// After the marker commits, even a deliberate override byte-identical to the
	// installed pack is user-owned and must never be inferred away again.
	write(path.join(config, 'canonical.toml'), newCanonical);
	write(path.join(sourceN2, 'canonical.toml'), '[pack]\ncorrected = "n3"\n');
	runMigration(sourceN2, installed, config);
	if (fs.readFileSync(path.join(config, 'canonical.toml'), 'utf8') !== newCanonical) {
		fail('a post-migration explicit override was reclassified as an installer seed');
	}

	console.log('ok - intact N seed retired, N+1 delta active, modified and future overrides preserved');
} finally {
	const resolvedSandbox = path.resolve(sandbox);
	const resolvedTemp = path.resolve(os.tmpdir());
	if (!resolvedSandbox.startsWith(`${resolvedTemp}${path.sep}`)) {
		fail(`refusing to remove a non-temporary fixture: ${resolvedSandbox}`);
	}
	fs.rmSync(resolvedSandbox, { recursive: true, force: true });
}
