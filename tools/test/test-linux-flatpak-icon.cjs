// tools/test/test-linux-flatpak-icon.cjs

/**
 * MODULE: Flatpak Desktop Icon Staging Regression
 * Runs the real package staging owner and replays its icon install command
 * with GNU install into a private app prefix. No SDK build is claimed here.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parse } = require('yaml');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-flatpak-icon-'));
// This test owns its build directory: another packaging test building at once cannot collide with it.
const BUILD = path.join(scratch, 'build');
const env = { ...process.env, ERGOPTI_BUILD_VERSION: '1.0.3', ERGOPTI_LINUX_BUILD_DIR: BUILD };
function bash(file, args = []) {
	const result = spawnSync(bashExecutable(), [file, ...args], {
		cwd: ROOT,
		env,
		encoding: 'utf8',
		timeout: 120000,
		maxBuffer: 4 * 1024 * 1024
	});
	assert.equal(result.status, 0, result.stderr || result.stdout || result.error?.message);
}
try {
	assert.equal(process.platform, 'linux', 'native GNU install replay requires Linux');
	bash(path.join(ROOT, 'tools/build/build-linux-driver.sh'));
	bash(path.join(ROOT, 'tools/build/build-linux-flatpak.sh'), ['--skip-flatpak']);
	const staging = path.join(BUILD, 'flatpak');
	const payload = path.join(staging, 'payload');
	const manifest = parse(fs.readFileSync(path.join(staging, 'org.ergopti.Ergopti.yml'), 'utf8'));
	const id = manifest['app-id'];
	// The manifest and AppStream file take the host and repository from their single
	// sources (identifiers.sh, the updater defaults); both must expand to real URLs.
	const github = JSON.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/core/text/data/identifiers.json'),
			'utf8'
		)
	).hosts.github;
	const updater = JSON.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/updater/data/defaults.json'),
			'utf8'
		)
	).github;
	// LuaJIT is built from the commit the runtime catalogue pins (owned runtimes
	// PIN), never from a moving branch.
	const pinned = JSON.parse(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/core/network/data/linux_native_runtime.json'),
			'utf8'
		)
	).network_runtime.portable.flatpak_sources.luajit;
	const luajit = manifest.modules.find((module) => module.name === 'luajit');
	assert.equal(luajit?.sources?.[0]?.url, `https://${github}/LuaJIT/LuaJIT.git`);
	assert.equal(luajit.sources[0].url, pinned.url);
	assert.equal(luajit.sources[0].commit, pinned.commit);
	assert.equal(luajit.sources[0].branch, undefined, 'a branch would move under the pin');
	const metainfo = fs.readFileSync(path.join(payload, `share/metainfo/${id}.metainfo.xml`), 'utf8');
	assert.equal(
		metainfo.match(/<url type="homepage">([^<]+)<\/url>/)?.[1],
		`https://${github}/${updater.owner}/${updater.repo}`
	);
	const desktop = fs.readFileSync(path.join(payload, `share/applications/${id}.desktop`), 'utf8');
	assert.equal(desktop.match(/^Icon=(.+)$/m)?.[1], id);
	const canonical = fs.readFileSync(path.join(BUILD, '_shared/tray/data/ergopti_tray.png'));
	const width = canonical.readUInt32BE(16),
		height = canonical.readUInt32BE(20);
	const relative = `share/icons/hicolor/${width}x${height}/apps/${id}.png`;
	const actual = fs.readFileSync(path.join(payload, relative));
	assert.deepEqual(
		actual,
		canonical,
		'the exported desktop icon must use the real canonical tray logo'
	);
	const commands = manifest.modules.flatMap((module) => module['build-commands'] || []);
	const install = commands.filter(
		(command) => command.startsWith('install ') && command.includes('share/icons/')
	);
	assert.equal(
		install.length,
		1,
		'the actual SDK recipe must install exactly one exported desktop icon'
	);
	// Only the installation prefix is relocated; the manifest command, staged
	// source bytes, flags and actual GNU install status remain production-owned.
	const command =
		'install() { local -a args=("$@"); local last=$((${#args[@]} - 1)); ' +
		'[[ "${args[$last]}" == /app/* ]] || return 92; ' +
		'args[$last]="$ERGOPTI_ICON_TEST_APP_ROOT/${args[$last]#/app/}"; command install "${args[@]}"; }; ' +
		install[0];
	const installEnv = { ...env, ERGOPTI_ICON_TEST_APP_ROOT: path.join(scratch, 'app') };
	const deployed = spawnSync(bashExecutable(), ['-euc', command], {
		cwd: payload,
		env: installEnv,
		encoding: 'utf8',
		timeout: 15000
	});
	assert.equal(deployed.status, 0, deployed.stderr || deployed.error?.message);
	assert.deepEqual(fs.readFileSync(path.join(scratch, 'app', relative)), canonical);
	fs.unlinkSync(path.join(payload, relative));
	const missing = spawnSync(bashExecutable(), ['-euc', command], {
		cwd: payload,
		env: installEnv,
		encoding: 'utf8',
		timeout: 15000
	});
	fs.writeFileSync(path.join(payload, relative), canonical);
	assert.notEqual(
		missing.status,
		0,
		'a missing exported icon must fail its genuine install command'
	);
	const asset = path.join(BUILD, '_shared/tray/data/ergopti_tray.png');
	// Rename must stay on the asset's filesystem even when the install replay's
	// private TMPDIR belongs to another device. Retain the original inode and
	// metadata instead of copying a replacement over the package fixture.
	const heldDirectory = fs.mkdtempSync(path.join(path.dirname(asset), '.ergopti-icon-'));
	const heldAsset = path.join(heldDirectory, 'canonical.png');
	const originalMetadata = fs.statSync(asset, { bigint: true });
	fs.renameSync(asset, heldAsset);
	try {
		const absentAsset = spawnSync(
			bashExecutable(),
			[path.join(ROOT, 'tools/build/build-linux-flatpak.sh'), '--skip-flatpak'],
			{
				cwd: ROOT,
				env,
				encoding: 'utf8',
				timeout: 120000,
				maxBuffer: 4 * 1024 * 1024
			}
		);
		assert.notEqual(
			absentAsset.status,
			0,
			'the actual packager must refuse a missing canonical asset'
		);
		assert.match(absentAsset.stderr, /ergopti_tray\.png/);
	} finally {
		fs.renameSync(heldAsset, asset);
		fs.rmdirSync(heldDirectory);
	}
	assert.deepEqual(
		fs.readFileSync(asset),
		canonical,
		'the original icon bytes must survive the refusal'
	);
	const restoredMetadata = fs.statSync(asset, { bigint: true });
	for (const key of ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs']) {
		assert.equal(restoredMetadata[key], originalMetadata[key], `original icon ${key} must survive`);
	}
	bash(path.join(ROOT, 'tools/build/build-linux-flatpak.sh'), ['--skip-flatpak']);
	console.log(
		'PASS flatpak-real-canonical-icon staging=1 native-install=1 missing-source-refusals=2'
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
