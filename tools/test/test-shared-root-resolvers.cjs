// tools/test/test-shared-root-resolvers.cjs

/**
 * ==============================================================================
 * MODULE: Shared-Root Resolver Execution Guard
 * DESCRIPTION:
 * Runs the real `infra/paths.lua` resolver of every driver, asks it for every
 * `_shared` path the codebase actually requests, and stats the answer. A target
 * that does not exist on disk fails, and so does a resolver that returns nil.
 *
 * WHY EXECUTION AND NOT INSPECTION:
 * test-linux-shared-path-resolver.cjs already enforces *routing* — no module may
 * reach the tree by counting `..` itself. Routing is not reachability. Once every
 * call goes through `Paths.shared("data/locales")`, the resolver is a single
 * point of failure that no static check can evaluate: the argument is a string,
 * the root is computed at runtime from `debug.getinfo` (Linux) or by walking up
 * from `hs.configdir` (macOS), and neither is visible to a reader.
 *
 * Both failure modes are silent by construction. `M.shared()` returns **nil**
 * when the tree is unreachable, and a nil path does not raise — it flows into an
 * `io.open` that returns nil, into a pcall that swallows it, into a fallback that
 * looks deliberate. That is exactly how the language menu came to offer 2 locales
 * of 21 while every test passed. A wrong *literal* degrades the same way: nothing
 * reads the file, nothing says so.
 *
 * So this guard resolves each expression through the production function and
 * asserts the file is there — never merely that the module loaded. Loading is
 * what the broken versions did too.
 *
 * THE USER-DIRECTORY RESOLVER, SAME RULE:
 * `linux/infra/config_paths.lua` is executed with HOME present, HOME absent, and
 * both HOME and TMPDIR absent, because the fallback is the part that shipped
 * wrong: nineteen sites once derived $HOME themselves with six different answers
 * for a missing one, including `"~"` (never expanded by io.open, so it addressed
 * a literal directory named `~` beside the process — the keylogger wrote its
 * database there) and `"/home/user"` (a plausible path belonging to nobody, so a
 * write there looks like it worked). Those two cannot be caught by reading a
 * return value's type; they need the value.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(DRIVERS, '_shared');

// Floors. A guard that inspects nothing passes for free, so each phase declares
// the minimum it must have seen for its silence to mean anything.
const MIN_TARGETS = 40; // Distinct _shared paths requested repo-wide (56 today).
const MIN_DRIVERS = 2; // Linux and macOS both own a resolver.
const MIN_HOME_CASES = 3; // HOME set, HOME absent, HOME + TMPDIR absent.

const errors = [];

// A sentinel keeps the probe's answers apart from anything the driver's logger
// writes to stdout — the macOS resolver logs a WARNING on a failed walk, and
// that line must not be parsed as a result.
const MARK = '@@';

/** Interpreter names to try, in order. CI installs lua5.4; dev boxes have lua. */
const LUA_CANDIDATES = ['lua', 'lua5.4', 'lua5.3', 'luajit'];

let LUA = null;
for (const bin of LUA_CANDIDATES) {
	const probe = spawnSync(bin, ['-v'], { encoding: 'utf8' });
	if (!probe.error && probe.status === 0) {
		LUA = bin;
		break;
	}
}




// ==========================================
// ==========================================
// ======= 1/ Collecting the requests =======
// ==========================================
// ==========================================

/** Every non-vendor Lua file under the driver tree. */
function walkLua(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'vendor' && e.name !== 'node_modules') walkLua(p, acc);
		} else if (e.name.endsWith('.lua')) {
			acc.push(p);
		}
	}
	return acc;
}

// `Paths.shared("x")` and the llm convenience wrapper, which prefixes its own
// directory. Only string literals can be checked; a computed argument is
// reported separately rather than skipped, so the gate cannot be evaded by
// building the path one line earlier.
const LITERAL_CALL = /\.(shared|shared_llm_path)\(\s*"([^"]*)"\s*\)/g;

const targets = new Map(); // shared-relative path -> [call sites]
const luaFiles = walkLua(DRIVERS);

if (luaFiles.length < 200) {
	errors.push(`walked only ${luaFiles.length} .lua file(s) — the scan is broken and would report nothing`);
}

for (const abs of luaFiles) {
	const rel = path.relative(DRIVERS, abs).split(path.sep).join('/');
	// The shared tree holds no resolver calls of its own; skipping it keeps the
	// target list to what the drivers ask for.
	if (rel.startsWith('_shared/')) continue;
	const lines = fs.readFileSync(abs, 'utf8').split(/\r?\n/);
	lines.forEach((line, i) => {
		if (/^\s*--/.test(line)) return; // Prose cites paths it does not request
		for (const m of line.matchAll(LITERAL_CALL)) {
			const arg = m[2];
			if (arg === '') continue; // Documented "nil/empty → the root itself"
			const target = m[1] === 'shared_llm_path' ? `modules/llm/${arg}` : arg;
			if (!targets.has(target)) targets.set(target, []);
			targets.get(target).push(`${rel}:${i + 1}`);
		}
	});
}

if (targets.size < MIN_TARGETS) {
	errors.push(
		`collected only ${targets.size} distinct _shared target(s) (floor ${MIN_TARGETS}) — the call-site ` +
			'scan is broken, and this guard would then resolve almost nothing while still passing'
	);
}

const targetList = [...targets.keys()].sort();




// ==========================================
// ==========================================
// ======= 2/ Executing the resolvers =======
// ==========================================
// ==========================================

// The probe is the only way to learn what the resolver actually returns: the
// root is computed at runtime, so it cannot be read off the source.
const PROBE_LUA = `
local driver_root, targets_file, use_hs_stub = ...
package.path = driver_root .. "/?.lua;"
	.. driver_root .. "/?/init.lua;"
	.. driver_root .. "/tests/stubs/?.lua;"
	.. driver_root .. "/../_shared/lua/?.lua;"
	.. driver_root .. "/../_shared/lua/?/init.lua;"
	.. package.path

-- The macOS resolver walks up from hs.configdir and probes the real filesystem
-- through hs.fs.attributes. The driver's own stub is used rather than a bespoke
-- one so this guard exercises the same code path the macOS suite does.
if use_hs_stub == "1" then
	local ok_hs, stub = pcall(require, "hs")
	if not ok_hs then
		print("${MARK}FATAL\\tcannot load the hs stub: " .. tostring(stub))
		os.exit(0)
	end
	hs = stub
end

local ok, Paths = pcall(require, "lib.paths")
if not ok then
	print("${MARK}FATAL\\tcannot load lib.paths: " .. tostring(Paths))
	os.exit(0)
end

local root = Paths.shared_root()
print("${MARK}ROOT\\t" .. tostring(root))

local fh = io.open(targets_file, "r")
if not fh then
	print("${MARK}FATAL\\tcannot read the target list")
	os.exit(0)
end
for line in fh:lines() do
	if line ~= "" then
		local resolved = Paths.shared(line)
		print("${MARK}PATH\\t" .. line .. "\\t" .. tostring(resolved))
	end
end
fh:close()
print("${MARK}END")
`;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-resolvers-'));
const probePath = path.join(tmp, 'probe.lua');
const targetsPath = path.join(tmp, 'targets.txt');
fs.writeFileSync(probePath, PROBE_LUA, 'utf8');
fs.writeFileSync(targetsPath, targetList.join('\n'), 'utf8');

/** Parses the sentinel-marked lines out of a probe run. */
function parseProbe(stdout) {
	const out = { root: null, paths: [], fatal: null, ended: false };
	for (const line of String(stdout).split(/\r?\n/)) {
		if (!line.startsWith(MARK)) continue;
		const [kind, a, b] = line.slice(MARK.length).split('\t');
		if (kind === 'FATAL') out.fatal = a;
		else if (kind === 'ROOT') out.root = a;
		else if (kind === 'PATH') out.paths.push({ target: a, resolved: b });
		else if (kind === 'END') out.ended = true;
	}
	return out;
}

const RESOLVER_DRIVERS = [
	{ name: 'linux', stub: false },
	{ name: 'macos', stub: true }
];

let driversExecuted = 0;

if (!LUA) {
	// Skipping is the failure this repo hunts: a gate that quietly does nothing
	// reads exactly like a gate that found nothing wrong.
	errors.push(
		`no Lua interpreter found (tried ${LUA_CANDIDATES.join(', ')}). This guard must EXECUTE the ` +
			'resolvers; it cannot fall back to reading them, because reading is what missed both shipped ' +
			'bugs. Install lua5.4.'
	);
} else {
	for (const drv of RESOLVER_DRIVERS) {
		const driverRoot = path.join(DRIVERS, drv.name).split(path.sep).join('/');
		const resolver = path.join(DRIVERS, drv.name, 'infra', 'paths.lua');
		if (!fs.existsSync(resolver)) {
			errors.push(`${drv.name}/infra/paths.lua is missing — the driver has no shared-tree resolver`);
			continue;
		}

		const run = spawnSync(LUA, [probePath, driverRoot, targetsPath, drv.stub ? '1' : '0'], {
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 120000
		});

		if (run.error) {
			errors.push(`${drv.name}: could not run the resolver probe — ${run.error.message}`);
			continue;
		}

		const res = parseProbe(run.stdout);
		if (res.fatal) {
			errors.push(`${drv.name}: ${res.fatal}`);
			continue;
		}
		if (!res.ended) {
			errors.push(
				`${drv.name}: the probe did not run to completion (exit ${run.status}) — its results are ` +
					`partial and prove nothing.\n      stderr: ${String(run.stderr).trim().slice(0, 400)}`
			);
			continue;
		}

		driversExecuted++;

		if (!res.root || res.root === 'nil') {
			errors.push(
				`${drv.name}: shared_root() returned nil. Every Paths.shared(…) call in the driver is ` +
					'therefore nil, and a nil path does not raise — it flows into io.open and comes back ' +
					'as a silent fallback.'
			);
			continue;
		}
		if (!fs.existsSync(res.root)) {
			errors.push(`${drv.name}: shared_root() returned "${res.root}", which does not exist`);
			continue;
		}
		// The root must be THE shared tree, not merely some existing directory:
		// a walk that stops one level early still returns something that stats.
		if (path.resolve(res.root) !== path.resolve(SHARED)) {
			errors.push(
				`${drv.name}: shared_root() returned "${res.root}" but the tree is at "${SHARED}" — the ` +
					'walk lands somewhere else, so every resource read from it is the wrong file or missing'
			);
			continue;
		}

		if (res.paths.length !== targetList.length) {
			errors.push(
				`${drv.name}: resolved ${res.paths.length} of ${targetList.length} target(s) — the probe ` +
					'dropped requests, so a missing file could hide in the gap'
			);
		}

		for (const { target, resolved } of res.paths) {
			const sites = targets.get(target) || [];
			const where = sites.slice(0, 2).join(', ') + (sites.length > 2 ? `, +${sites.length - 2} more` : '');
			if (!resolved || resolved === 'nil') {
				errors.push(`${drv.name}: Paths.shared("${target}") returned nil — requested at ${where}`);
				continue;
			}
			if (!fs.existsSync(resolved)) {
				errors.push(
					`${drv.name}: Paths.shared("${target}") resolves to "${resolved}", which does not ` +
						`exist. Requested at ${where}. The read will fail silently at runtime.`
				);
			}
		}
	}

	if (driversExecuted < MIN_DRIVERS) {
		errors.push(
			`executed only ${driversExecuted} resolver(s) (floor ${MIN_DRIVERS}) — the drivers that did ` +
				'not run were not checked at all'
		);
	}
}




// ==============================================
// ==============================================
// ======= 3/ The user-directory resolver =======
// ==============================================
// ==============================================

// Shape assertions, not existence: these are the *user's* directories, which
// need not exist on a build machine. What shipped wrong was never the type —
// it was the value.
const HOME_PROBE_LUA = `
local driver_root = ...
package.path = driver_root .. "/?.lua;" .. driver_root .. "/?/init.lua;"
	.. driver_root .. "/../_shared/lua/?.lua;"
	.. driver_root .. "/../_shared/lua/?/init.lua;" .. package.path

local ok, CP = pcall(require, "lib.config_paths")
if not ok then
	print("${MARK}FATAL\\tcannot load lib.config_paths: " .. tostring(CP))
	os.exit(0)
end
print("${MARK}PATH\\thome\\t" .. tostring(CP.home()))
print("${MARK}PATH\\tconfig_home\\t" .. tostring(CP.config_home()))
print("${MARK}PATH\\tdata_home\\t" .. tostring(CP.data_home()))
print("${MARK}PATH\\tconfig\\t" .. tostring(CP.config("storage.json")))
print("${MARK}PATH\\tdata\\t" .. tostring(CP.data("keylog.db")))
print("${MARK}END")
`;

const homeProbePath = path.join(tmp, 'home_probe.lua');
fs.writeFileSync(homeProbePath, HOME_PROBE_LUA, 'utf8');

const LINUX_ROOT = path.join(DRIVERS, 'linux').split(path.sep).join('/');
const CONFIG_PATHS = path.join(DRIVERS, 'linux', 'infra', 'config_paths.lua');

// Each scenario names the base the resolver must land on, so "it returned a
// string" is never enough to pass.
const HOME_CASES = [
	{
		label: 'HOME set',
		env: { HOME: '/home/tester', TMPDIR: '/var/tmp', XDG_CONFIG_HOME: '', XDG_DATA_HOME: '' },
		expectBase: '/home/tester'
	},
	{
		label: 'HOME unset, TMPDIR set',
		env: { HOME: '', TMPDIR: '/var/tmp', XDG_CONFIG_HOME: '', XDG_DATA_HOME: '' },
		expectBase: '/var/tmp'
	},
	{
		label: 'HOME and TMPDIR unset',
		env: { HOME: '', TMPDIR: '', XDG_CONFIG_HOME: '', XDG_DATA_HOME: '' },
		expectBase: '/tmp'
	}
];

let homeCasesRun = 0;

if (LUA && !fs.existsSync(CONFIG_PATHS)) {
	errors.push('linux/infra/config_paths.lua is missing — the user-directory SSOT is gone');
} else if (LUA) {
	for (const c of HOME_CASES) {
		// Inherit the real environment and override only the keys under test:
		// a from-scratch env breaks the interpreter's own lookup on Windows.
		const env = { ...process.env };
		for (const [k, v] of Object.entries(c.env)) {
			if (v === '') delete env[k];
			else env[k] = v;
		}

		const run = spawnSync(LUA, [homeProbePath, LINUX_ROOT], {
			cwd: ROOT,
			encoding: 'utf8',
			env,
			timeout: 120000
		});
		if (run.error) {
			errors.push(`config_paths [${c.label}]: could not run the probe — ${run.error.message}`);
			continue;
		}
		const res = parseProbe(run.stdout);
		if (res.fatal) {
			errors.push(`config_paths [${c.label}]: ${res.fatal}`);
			continue;
		}
		if (!res.ended) {
			errors.push(`config_paths [${c.label}]: the probe did not complete — its output proves nothing`);
			continue;
		}
		homeCasesRun++;

		for (const { target, resolved } of res.paths) {
			const what = `config_paths.${target}() [${c.label}]`;
			if (!resolved || resolved === 'nil') {
				errors.push(`${what} returned nil — callers concatenate this straight into a file path`);
				continue;
			}
			if (resolved.includes('~')) {
				errors.push(
					`${what} returned "${resolved}", which contains "~". io.open never expands it, so this ` +
						'addresses a literal directory named "~" beside the process — the keylogger wrote ' +
						'its database there once.'
				);
			}
			if (resolved.startsWith('/home/user')) {
				errors.push(
					`${what} returned "${resolved}" — /home/user belongs to nobody, so a write there looks ` +
						'like it worked and the data is gone'
				);
			}
			if (!resolved.startsWith('/')) {
				errors.push(
					`${what} returned "${resolved}", a relative path — it then resolves against whatever ` +
						"directory the process happens to be in, which is not the user's"
				);
			}
			if (!resolved.startsWith(c.expectBase)) {
				errors.push(
					`${what} returned "${resolved}", which is not under the expected base "${c.expectBase}"`
				);
			}
			if (/\/{2,}/.test(resolved.replace(/^\//, ''))) {
				errors.push(`${what} returned "${resolved}" with a doubled separator`);
			}
		}
	}

	if (homeCasesRun < MIN_HOME_CASES) {
		errors.push(
			`ran only ${homeCasesRun} of ${MIN_HOME_CASES} HOME scenario(s) — the unset-HOME fallback is ` +
				'the part that shipped wrong, so leaving it unexercised is the whole gap'
		);
	}
}

fs.rmSync(tmp, { recursive: true, force: true });




// ==========================
// ==========================
// ======= 4/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] shared-root resolver execution:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${driversExecuted} resolver(s) executed: all ${targetList.length} requested _shared ` +
		`path(s) resolve to files that exist; config_paths honest under ${homeCasesRun} HOME scenario(s).\x1b[0m`
);
