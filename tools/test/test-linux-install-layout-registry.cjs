// tools/test/test-linux-install-layout-registry.cjs

/**
 * ==============================================================================
 * MODULE: Linux Checkout Install Ships The Layout Registry
 * DESCRIPTION:
 * SFB reduction, rolls and the magic key's repeat corrections live in the
 * Ergopti layout extension, inside the layout registry. The Linux daemon finds
 * that registry only below its driver root (modules/keymap/layout_registry.lua
 * bundled_dir), where the release tarball and every package carry it.
 *
 * ROOT CAUSE ENCODED:
 * install.sh run from a source checkout (the documented path) copied only the
 * driver and _shared/ trees, and the registry sits outside both. The installed
 * daemon therefore discovered no Ergopti extension and the three groups vanished
 * from the catalogue and the menu, with a single WARN line as the only trace.
 *
 * This gate replays the checkout install with the installer's own helper, then
 * EXECUTES the installed driver's extension discovery and loader in that tree:
 * reading the scripts cannot tell whether the daemon will find the files.
 * ==============================================================================
 */

'use strict';

const childProcess = require('child_process');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVER = path.join(DRIVERS, 'linux');
const SHARED = path.join(DRIVERS, '_shared');
const INSTALLER = path.join(DRIVER, 'install.sh');
const HELPER = path.join(DRIVER, 'install', 'layout_registry.sh');
const OWNERSHIP = path.join(DRIVER, 'install', 'ownership.sh');
const DEFAULTS = path.join(SHARED, 'modules', 'layouts', 'defaults.json');
const DRIVER_BUILDER = path.join(ROOT, 'tools', 'build', 'build-linux-driver.sh');

// The files the Ergopti extension supplies in place of the shared folder.
const MOVED = [
	'sfbsreduction.toml',
	'rolls.toml',
	'repeatcorrections.toml',
	'suffixes_a.toml',
	'magickeyreplace.toml'
];
const LUA_CANDIDATES = ['luajit', 'lua5.4', 'lua'];
const MARK = '@@';

const errors = [];

function bashPath(value) {
	const normalized = path.resolve(value).replaceAll('\\', '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):\//, (_, drive) => `/${drive.toLowerCase()}/`);
}

function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

/** Runs a Bash script body and returns the child result. */
function bash(lines) {
	return childProcess.spawnSync(bashExecutable(), ['-c', lines.join('\n')], {
		cwd: ROOT,
		encoding: 'utf8'
	});
}

/** The first Lua runtime on PATH; the probe must execute, never be skipped. */
function luaRuntime() {
	for (const bin of LUA_CANDIDATES) {
		const probe = childProcess.spawnSync(bin, ['-v'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return bin;
	}
	return null;
}

/** Windows runs installed discovery with real bytes, not Linux-only fd aliases. */
function installedReaderPort(lib) {
	if (process.platform !== 'win32') return [];
	const admitted = [];
	const owned = path.resolve(lib);
	const identity = (filename) => path.resolve(filename).toLowerCase();
	function requireOwnedPhysicalPath(filename) {
		const literal = path.resolve(filename);
		const native = fs.realpathSync(filename);
		if (
			identity(native) !== identity(literal) ||
			(identity(literal) !== identity(owned) &&
				!identity(literal).startsWith(identity(owned) + path.sep))
		)
			throw new Error('The installed reader fixture refuses a substituted native path.');
	}
	requireOwnedPhysicalPath(lib);
	function visit(directory) {
		for (const name of fs.readdirSync(directory)) {
			const filename = path.join(directory, name);
			requireOwnedPhysicalPath(filename);
			const stat = fs.lstatSync(filename);
			if (stat.isDirectory()) visit(filename);
			else if (stat.isFile()) admitted.push(path.resolve(filename).replaceAll('\\', '/'));
			else
				throw new Error(
					'The installed reader fixture requires physical regular files: ' + filename
				);
		}
	}
	// A real owned junction must not turn a foreign tree into installed input.
	const foreign = fs.mkdtempSync(path.join(path.dirname(lib), 'reader-foreign-'));
	const junction = path.join(lib, '.reader-junction-control');
	const sentinel = path.join(foreign, 'sentinel.txt');
	fs.writeFileSync(sentinel, 'Independent foreign fixture bytes\n');
	let acquired = false;
	try {
		fs.symlinkSync(foreign, junction, 'junction');
		acquired = true;
		let refused = false;
		try {
			requireOwnedPhysicalPath(junction);
		} catch (error) {
			if (error.message !== 'The installed reader fixture refuses a substituted native path.')
				throw error;
			refused = true;
		}
		if (!refused) throw new Error('The installed reader admitted an external junction.');
		if (fs.readFileSync(sentinel, 'utf8') !== 'Independent foreign fixture bytes\n')
			throw new Error('The foreign fixture sentinel changed.');
	} finally {
		try {
			if (acquired) fs.unlinkSync(junction);
		} finally {
			fs.rmSync(foreign, { recursive: true });
		}
	}
	visit(lib);
	assertInstalledReaderInputs(admitted, lib);
	return [
		'local installed_reader_files = {',
		...admitted.map(
			(filename) => `  [${JSON.stringify(filename.toLowerCase())}] = ${JSON.stringify(filename)},`
		),
		'}',
		'local function installed_reader_key(filename)',
		'  if type(filename) ~= "string" then return nil end',
		'  local normalized = filename:gsub("\\\\", "/")',
		'  local drive, tail = normalized:match("^([A-Za-z]):/(.*)$")',
		'  if not drive then return nil end',
		'  local parts = {}',
		'  for part in tail:gmatch("[^/]+") do',
		'    if part == ".." then',
		'      if #parts == 0 then return nil end',
		'      table.remove(parts)',
		'    elseif part ~= "." then parts[#parts + 1] = part end',
		'  end',
		'  return (drive .. ":/" .. table.concat(parts, "/")):lower()',
		'end',
		'package.preload["infra.regular_file_reader"] = function()',
		'  return { open = function(filename)',
		'    local admitted_filename = installed_reader_files[installed_reader_key(filename)]',
		'    if not admitted_filename then',
		'      return nil, "outside the admitted installed fixture", 5',
		'    end',
		'    return io.open(admitted_filename, "r")',
		'  end }',
		'end',
		'local fixture_reader = require("infra.regular_file_reader")',
		`assert(fixture_reader.open(${JSON.stringify(path.resolve(lib).replaceAll('\\', '/'))}) == nil, "directories cannot acquire read admission")`,
		`assert(fixture_reader.open(${JSON.stringify(path.resolve(lib, '../unowned.txt').replaceAll('\\', '/'))}) == nil, "existing foreign fixture files cannot acquire read admission")`,
		`assert(fixture_reader.open(${JSON.stringify(path.resolve(lib).replaceAll('\\', '/') + '/../unowned.txt')}) == nil, "traversal cannot acquire read admission")`,
		`local admitted_stream = assert(fixture_reader.open(${JSON.stringify(path.resolve(lib, '_shared/modules/layouts/defaults.json').replaceAll('\\', '/'))}))`,
		'assert(type(admitted_stream:read("*a")) == "string"); assert(admitted_stream:close())',
		'local equivalent_filenames = {',
		...[
			path.resolve(lib).replaceAll('\\', '/') + '/linux/../_shared/modules/layouts/defaults.json',
			path.resolve(lib, '_shared/modules/layouts/defaults.json'),
			path.resolve(lib, '_shared/modules/layouts/defaults.json').toUpperCase()
		].map((filename) => `  ${JSON.stringify(filename)},`),
		'}',
		'for _, filename in ipairs(equivalent_filenames) do',
		'  local stream = assert(fixture_reader.open(filename), "owned equivalent paths must read the admitted physical defaults")',
		`  assert(stream:read("*a") == ${JSON.stringify(fs.readFileSync(DEFAULTS, 'utf8'))}, "equivalent paths preserve exact physical bytes")`,
		'  assert(stream:close())',
		'end'
	];
}

/** The actual copy must contain the exact shared discovery defaults. */
function assertInstalledReaderInputs(admitted, lib) {
	const defaults = path.resolve(lib, '_shared/modules/layouts/defaults.json').replaceAll('\\', '/');
	if (!admitted.includes(defaults) || !fs.readFileSync(defaults).equals(fs.readFileSync(DEFAULTS)))
		throw new Error('The installed defaults must be physical and byte-exact before discovery.');
	fs.writeFileSync(
		path.resolve(lib, '../unowned.txt'),
		'Owned negative fixture: never admitted.\n'
	);
}

// ==========================================
// ==========================================
// ======= 1/ The installer's own steps =======
// ==========================================
// ==========================================

// The helper names the folder the daemon probes: the registry settings own it.
const settings = JSON.parse(fs.readFileSync(DEFAULTS, 'utf8')).registry;
const constants = bash([
	'set -euo pipefail',
	`source ${shellQuote(bashPath(HELPER))}`,
	'printf "%s\\n%s\\n" "$LAYOUT_REGISTRY_FOLDER" "$LAYOUT_REGISTRY_INDEX"'
]);
if (constants.status !== 0) {
	errors.push(`layout_registry.sh cannot be sourced: ${constants.stderr}`);
} else {
	const [folder, index] = constants.stdout.trim().split('\n');
	if (folder !== settings.folder || index !== settings.index_file) {
		errors.push(
			`layout_registry.sh installs to ${folder}/${index}, but the daemon reads ` +
				`${settings.folder}/${settings.index_file} (_shared/modules/layouts/defaults.json).`
		);
	}
}

// install.sh resolves the registry before replacing anything, copies it after
// the driver tree and records it as its own.
const installer = fs.readFileSync(INSTALLER, 'utf8');
const resolved = installer.indexOf(
	'SRC_REGISTRY="$(layout_registry_source "${SRC_DRIVER}" "${DRIVERS_ROOT}")"'
);
// Both copies preserve the original source/destination contract. The current
// tar pipeline additionally excludes only the ignored checkout-local backend.
const sourcePayloadCopy =
	'tar -C "$SRC_DRIVER" --exclude=\'./bin/libergopti_archive_publication.so\' -cf - . \\\n\t| tar -C "${LIB_DIR}/linux" -xf -';
function driverPayloadCopyIndex(source) {
	const legacy = source.indexOf('cp -r "${SRC_DRIVER}/." "${LIB_DIR}/linux/"');
	return legacy >= 0 ? legacy : source.indexOf(sourcePayloadCopy);
}
assert.equal(driverPayloadCopyIndex(sourcePayloadCopy), 0, 'exact target/source tar copy admits');
assert.equal(
	driverPayloadCopyIndex('cp -r "${SRC_DRIVER}/." "${LIB_DIR}/linux/"'),
	0,
	'original copy contract remains'
);
for (const [before, after] of [
	['"$SRC_DRIVER"', '"$FOREIGN_DRIVER"'],
	['"${LIB_DIR}/linux"', '"${LIB_DIR}/other"'],
	["--exclude='./bin/libergopti_archive_publication.so'", "--exclude='./modules'"],
	['-cf - .', '-cf - native'],
	['-xf -', '-tf -']
]) {
	assert.ok(sourcePayloadCopy.includes(before), 'copy mutation must hit its real protocol');
	const mutated = sourcePayloadCopy.replace(before, after);
	assert.equal(driverPayloadCopyIndex(mutated), -1, 'changed copy authority must refuse');
}
const driverCopy = driverPayloadCopyIndex(installer);
const registryCopy = installer.indexOf(
	'install_layout_registry "${SRC_REGISTRY}" "${LIB_DIR}/linux"'
);
const firstInstall = installer.indexOf('install -d "${LIB_DIR}/linux"');
if (!installer.includes('source "${SRC_DRIVER}/install/layout_registry.sh"')) {
	errors.push('install.sh must source install/layout_registry.sh.');
}
if (resolved < 0 || firstInstall < 0 || resolved > firstInstall) {
	errors.push('install.sh must resolve the layout registry before it touches the installation.');
}
if (driverCopy < 0 || registryCopy < 0 || registryCopy < driverCopy) {
	errors.push('install.sh must copy the layout registry below the installed driver tree.');
}
if (!installer.includes('"${SRC_REGISTRY}" "linux/${LAYOUT_REGISTRY_FOLDER}"')) {
	errors.push('install.sh must record the copied layout registry in the ownership manifest.');
}

// Every package build requires the extension files, so none ships without them.
const builder = fs.readFileSync(DRIVER_BUILDER, 'utf8');
for (const file of [
	'ergopti/manifest.toml',
	...MOVED.map((name) => `ergopti/hotstrings/${name}`)
]) {
	if (!builder.includes(`"linux/${settings.folder}/${file}"`)) {
		errors.push(`build-linux-driver.sh must require linux/${settings.folder}/${file}.`);
	}
}

// ============================================
// ============================================
// ======= 2/ A replayed checkout install =======
// ============================================
// ============================================

const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-install-registry-'));
try {
	const lib = path.join(sandbox, 'lib', 'ergopti');
	const replay = bash([
		'set -euo pipefail',
		// Force the GNU binary marker on every host, including Linux CI.
		'sha256sum() { command sha256sum --binary "$@"; }',
		'export -f sha256sum',
		`source ${shellQuote(bashPath(HELPER))}`,
		`SRC_REGISTRY="$(layout_registry_source ${shellQuote(bashPath(DRIVER))} ${shellQuote(bashPath(DRIVERS))})"`,
		`install -d ${shellQuote(bashPath(path.join(lib, 'linux')))} ${shellQuote(bashPath(path.join(lib, '_shared')))}`,
		`tar -C ${shellQuote(bashPath(DRIVER))} --exclude='./bin/libergopti_archive_publication.so' -cf - . | tar -C ${shellQuote(bashPath(path.join(lib, 'linux')))} -xf -`,
		`cp -r ${shellQuote(bashPath(SHARED))}/. ${shellQuote(bashPath(path.join(lib, '_shared')))}/`,
		`install_layout_registry "$SRC_REGISTRY" ${shellQuote(bashPath(path.join(lib, 'linux')))}`,
		`bash ${shellQuote(bashPath(OWNERSHIP))} ${shellQuote(bashPath(DRIVER))} ${shellQuote(bashPath(SHARED))} ` +
			`${shellQuote(bashPath(lib))} "$SRC_REGISTRY" "linux/$LAYOUT_REGISTRY_FOLDER"`,
		'printf "%s" "$SRC_REGISTRY"'
	]);
	if (replay.status !== 0) {
		errors.push(`the checkout install replay failed: ${replay.stderr || replay.stdout}`);
	} else {
		const installed = path.join(lib, 'linux', ...settings.folder.split('/'), 'ergopti');
		for (const name of MOVED) {
			if (!fs.existsSync(path.join(installed, 'hotstrings', name))) {
				errors.push(`a checkout install does not ship the Ergopti extension's ${name}.`);
			}
		}

		// The receipt owns every registry file once, with its digest, so
		// uninstall.sh removes exactly what the installer copied.
		const receipt = fs.readFileSync(path.join(lib, '.ergopti-owned-files'), 'utf8');
		const owned = new Map();
		for (const line of receipt.split('\n').filter(Boolean)) {
			const [digest, relative] = line.split('\t');
			if (owned.has(relative)) errors.push(`the ownership receipt lists ${relative} twice.`);
			owned.set(relative, digest);
		}
		for (const name of MOVED) {
			const relative = `linux/${settings.folder}/ergopti/hotstrings/${name}`;
			const file = path.join(installed, 'hotstrings', name);
			const digest = fs.existsSync(file)
				? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
				: null;
			if (!digest || owned.get(relative) !== digest) {
				errors.push(`the ownership receipt does not own ${relative} with its digest.`);
			}
		}

		// The installed daemon's own discovery and loader, run in the installed tree.
		const lua = luaRuntime();
		if (!lua) {
			errors.push(
				`no Lua runtime found (tried ${LUA_CANDIDATES.join(', ')}); the probe must execute.`
			);
		} else {
			const probe = path.join(sandbox, 'probe.lua');
			// Native Windows Lua owns cmd.exe pipes. Keep production shell commands
			// intact but execute their exact bytes through the same real Bash.
			const shellBridge =
				process.platform === 'win32'
					? [
							`local bash = ${JSON.stringify(bashExecutable().replaceAll('\\', '/'))}`,
							`local command_file = ${JSON.stringify(path.join(sandbox, 'command.sh').replaceAll('\\', '/'))}`,
							'local native_popen = io.popen',
							'io.popen = function(command, mode)',
							'  local file = assert(io.open(command_file, "wb"))',
							'  assert(file:write(command .. "\\n")); assert(file:close())',
							`  return native_popen('""' .. bash .. '" -s < "' .. command_file .. '""', mode)`,
							'end',
							'local native_execute = os.execute',
							'os.execute = function(command)',
							'  local file = assert(io.open(command_file, "wb"))',
							'  assert(file:write(command .. "\\n")); assert(file:close())',
							`  return native_execute('""' .. bash .. '" -s < "' .. command_file .. '""')`,
							'end'
						]
					: [];
			fs.writeFileSync(
				probe,
				[
					...shellBridge,
					...installedReaderPort(lib),
					'local root = arg[1]',
					'package.path = root .. "/linux/?.lua;" .. root .. "/linux/?/init.lua;"',
					'	.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path',
					'local Paths = require("infra.paths")',
					'local Config = require("modules.hotstrings.hotstrings_config")',
					'local Loader = require("modules.hotstrings.loader")',
					...(process.platform === 'win32'
						? [
								'local Shell = require("adapters.shell_runner")',
								`assert(Shell.run(${JSON.stringify('test -e ' + shellQuote(path.join(lib, 'linux', settings.folder, settings.index_file).replaceAll('\\', '/')) + ' 2>/dev/null')}), "the actual installed registry exists through the real Bash status port")`,
								`assert(not Shell.run(${JSON.stringify('test -e ' + shellQuote(path.join(lib, '__absent_shell_control__').replaceAll('\\', '/')) + ' 2>/dev/null')}), "the real Bash status port preserves a missing-path failure")`
							]
						: []),
					'local found = Config.discover_extensions()',
					'for _, pack in ipairs(found) do',
					'	for _, file in ipairs(pack.bound_files) do',
					`		print("${MARK}BOUND\\t" .. pack.id .. "\\t" .. file.stem .. "\\t" .. file.path)`,
					'	end',
					'end',
					'local paths = {}',
					'for _, p in ipairs(Loader.find_toml_files(Paths.shared("modules/hotstrings"))) do',
					'	if not p:find("/french/", 1, true) then paths[#paths + 1] = p end',
					'end',
					'local catalogue = Loader.load_catalogue(Config.route_bound_sources(paths, found))',
					'local cats = catalogue.categories',
					`print("${MARK}COUNT\\tsfbsreduction\\t" .. tostring(cats.sfbsreduction and cats.sfbsreduction.count))`,
					`print("${MARK}COUNT\\trolls\\t" .. tostring(cats.rolls and cats.rolls.count))`,
					'local repeat_corrections = cats.magickey and cats.magickey.sections.repeat_corrections',
					`print("${MARK}COUNT\\trepeat_corrections\\t" .. tostring(repeat_corrections and repeat_corrections.count))`
				].join('\n'),
				'utf8'
			);
			const home = path.join(sandbox, 'home');
			fs.mkdirSync(home);
			// Native Lua receives host paths; MSYS paths belong only to Bash.
			const run = childProcess.spawnSync(lua, [probe, path.resolve(lib).replaceAll('\\', '/')], {
				cwd: path.join(lib, 'linux'),
				encoding: 'utf8',
				env: {
					...process.env,
					HOME: home,
					XDG_CONFIG_HOME: path.join(home, '.config'),
					XDG_DATA_HOME: path.join(home, '.local', 'share'),
					XDG_STATE_HOME: path.join(home, '.local', 'state'),
					XDG_CACHE_HOME: path.join(home, '.cache')
				}
			});
			const bound = new Map();
			const counts = new Map();
			for (const line of String(run.stdout).split(/\r?\n/)) {
				if (!line.startsWith(MARK)) continue;
				const [kind, a, b, c] = line.slice(MARK.length).split('\t');
				if (kind === 'BOUND' && a === 'ergopti') bound.set(`${b}.toml`, c);
				if (kind === 'COUNT') counts.set(a, b);
			}
			if (run.status !== 0) {
				errors.push(`the installed discovery probe failed (${run.status}): ${run.stderr}`);
			}
			for (const name of MOVED) {
				const file = bound.get(name);
				if (!file || !path.resolve(file).startsWith(path.resolve(installed))) {
					errors.push(
						`the installed daemon does not discover ${name} in its shipped Ergopti extension ` +
							`(found ${file || 'nothing'}).`
					);
				}
			}
			for (const [group, expected] of [
				['sfbsreduction', '34'],
				['rolls', '35'],
				['repeat_corrections', '14']
			]) {
				if (counts.get(group) !== expected) {
					errors.push(
						`the installed daemon loads ${counts.get(group)} ${group} hotstrings, expected ${expected}.`
					);
				}
			}
		}
	}

	// ======================================
	// ======================================
	// ======= 3/ The other two sources =======
	// ======================================
	// ======================================

	// A release tarball carries the registry below linux/: nothing to copy.
	const tarball = path.join(sandbox, 'tarball');
	fs.mkdirSync(path.join(tarball, 'linux', ...settings.folder.split('/')), { recursive: true });
	fs.writeFileSync(
		path.join(tarball, 'linux', ...settings.folder.split('/'), settings.index_file),
		'{}'
	);
	const packaged = bash([
		'set -euo pipefail',
		`source ${shellQuote(bashPath(HELPER))}`,
		`layout_registry_source ${shellQuote(bashPath(path.join(tarball, 'linux')))} ${shellQuote(bashPath(tarball))}`
	]);
	if (packaged.status !== 0 || packaged.stdout !== '') {
		errors.push(
			`a tarball's own registry must need no copy (status ${packaged.status}, "${packaged.stdout}").`
		);
	}

	// A source with no registry at all is refused before anything is copied.
	const bare = path.join(sandbox, 'bare', 'ergopti_plus');
	fs.mkdirSync(path.join(bare, 'linux'), { recursive: true });
	const refused = bash([
		'set -euo pipefail',
		`source ${shellQuote(bashPath(HELPER))}`,
		`layout_registry_source ${shellQuote(bashPath(path.join(bare, 'linux')))} ${shellQuote(bashPath(bare))}`
	]);
	if (refused.status === 0 || !/Layout registry not found/.test(refused.stderr)) {
		errors.push('a source without a layout registry must be refused with a message.');
	}
} finally {
	const resolvedSandbox = path.resolve(sandbox);
	if (!resolvedSandbox.startsWith(`${path.resolve(os.tmpdir())}${path.sep}`)) {
		throw new Error(`refusing to remove a non-temporary fixture: ${resolvedSandbox}`);
	}
	fs.rmSync(resolvedSandbox, { recursive: true, force: true });
}

if (errors.length > 0) {
	for (const error of errors) console.error(`FAIL: ${error}`);
	process.exit(1);
}
console.log(
	'ok - a checkout install ships the layout registry, owns it, and its daemon loads the Ergopti extension hotstrings'
);
