// tools/test/test-updater-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Updater Constants Single-Source Gate
 * DESCRIPTION:
 * Drift gate: verifies that the owner/repo/timing literals in
 * windows/modules/updater/core.ahk and macos/modules/updater/init.lua agree with the
 * canonical values in _shared/modules/updater/defaults.json. A mismatch here
 * means someone edited a per-driver literal without updating the shared JSON
 * (or vice versa).
 *
 * FEATURES & RATIONALE:
 * 1. Parity enforcement: AHK keeps inline literals (AHK parse complexity),
 *    macOS identity and Linux update values read from JSON — this gate keeps
 *    every live value in sync with it.
 * 2. Additive: does not remove any existing checks; purely a new gate.
 *
 * THE THIRD DRIVER, AND THE FALLBACKS NOBODY WAS WATCHING:
 * Linux has a full updater with repository and timing fallbacks. macOS reads its
 * timing through the shared schedule in modules/updater/auto_check.lua and retains
 * only a repository identity fallback. Every surviving fallback scalar is pinned
 * to defaults.json.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED_ROOT = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const DEFAULTS = path.join(SHARED_ROOT, 'modules', 'updater', 'defaults.json');
const AHK_CORE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'modules',
	'updater',
	'core.ahk'
);
const LUA_UPDATER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'modules',
	'updater',
	'init.lua'
);
const LINUX_UPDATER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'linux',
	'modules',
	'updater',
	'manager.lua'
);

let exitCode = 0;

function fail(msg) {
	console.error('  FAIL  ' + msg);
	exitCode = 1;
}

function pass(msg) {
	console.log('  pass  ' + msg);
}

// ─── Load defaults.json ───────────────────────────────────────────────────────

if (!fs.existsSync(DEFAULTS)) {
	fail('_shared/modules/updater/defaults.json not found — file was deleted or moved');
	process.exit(1);
}

let defaults;
try {
	defaults = JSON.parse(fs.readFileSync(DEFAULTS, 'utf8'));
} catch (e) {
	fail('_shared/modules/updater/defaults.json is not valid JSON: ' + e.message);
	process.exit(1);
}

const owner = defaults.github && defaults.github.owner;
const repo = defaults.github && defaults.github.repo;
const interval = defaults.timing && defaults.timing.default_check_interval_sec;
const boot = defaults.timing && defaults.timing.boot_check_delay_sec;

if (!owner || !repo || !interval || !boot) {
	fail(
		'defaults.json missing required fields: github.owner, github.repo, timing.default_check_interval_sec, timing.boot_check_delay_sec'
	);
	process.exit(1);
}
pass('defaults.json has all required scalar fields');

// ─── Check AHK core.ahk literals match defaults.json ────────────────────────

const ahkSrc = fs.readFileSync(AHK_CORE, 'utf8');

const ahkOwnerRe = /UPDATER_GH_OWNER\s*:=\s*"([^"]+)"/;
const ahkRepoRe = /UPDATER_GH_REPO\s*:=\s*"([^"]+)"/;

const ahkOwnerM = ahkSrc.match(ahkOwnerRe);
const ahkRepoM = ahkSrc.match(ahkRepoRe);

if (!ahkOwnerM) {
	fail('core.ahk: could not find UPDATER_GH_OWNER literal');
} else if (ahkOwnerM[1] !== owner) {
	fail(
		`core.ahk UPDATER_GH_OWNER="${ahkOwnerM[1]}" does not match defaults.json github.owner="${owner}"`
	);
} else {
	pass(`core.ahk UPDATER_GH_OWNER matches defaults.json ("${owner}")`);
}

if (!ahkRepoM) {
	fail('core.ahk: could not find UPDATER_GH_REPO literal');
} else if (ahkRepoM[1] !== repo) {
	fail(
		`core.ahk UPDATER_GH_REPO="${ahkRepoM[1]}" does not match defaults.json github.repo="${repo}"`
	);
} else {
	pass(`core.ahk UPDATER_GH_REPO matches defaults.json ("${repo}")`);
}

// The AHK default and presets come from the generated schedule data
// (windows/_generated/update_schedule.ahk, kept fresh by
// test-update-schedule-contract.cjs), never from a literal in the updater.
const AHK_SCHEDULE_DATA = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'_generated',
	'update_schedule.ahk'
);
if (
	!/UPDATER_DEFAULT_INTERVAL\s*:=\s*UpdateSchedule_Timing\(\)\["default_check_interval_sec"\]/.test(
		ahkSrc
	)
) {
	fail(
		'core.ahk UPDATER_DEFAULT_INTERVAL must read the shared default through UpdateSchedule_Timing()'
	);
} else if (!fs.existsSync(AHK_SCHEDULE_DATA)) {
	fail('windows/_generated/update_schedule.ahk is missing; run npm run codegen:update-schedule');
} else {
	const generatedDefault = fs
		.readFileSync(AHK_SCHEDULE_DATA, 'utf8')
		.match(/"default_check_interval_sec",\s*(\d+)/);
	if (!generatedDefault || Number(generatedDefault[1]) !== interval) {
		fail(
			`the generated AHK schedule data does not carry defaults.json timing.default_check_interval_sec=${interval}`
		);
	} else {
		pass(`core.ahk UPDATER_DEFAULT_INTERVAL reads the generated shared default (${interval})`);
	}
}

// The first background check used to fire min(30000 ms, interval) after every
// boot, a literal no gate pinned. The delay now comes from the shared schedule.
const AHK_SELF_UPDATE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'modules',
	'updater',
	'self_update.ahk'
);
const selfUpdateSrc = fs.readFileSync(AHK_SELF_UPDATE, 'utf8');
const startBody = selfUpdateSrc.match(/\nUpdater_StartBackgroundChecks\([^)]*\) \{([\s\S]*?)\n\}/);
if (!startBody) {
	fail('self_update.ahk: could not find Updater_StartBackgroundChecks');
} else if (
	/\b30000\b|boot_check_delay_sec\s*\*/.test(startBody[1]) ||
	!startBody[1].includes('_Updater_ScheduleDecision()')
) {
	fail(
		'Updater_StartBackgroundChecks must arm its first check from _Updater_ScheduleDecision(), not a boot-delay literal'
	);
} else {
	pass('Updater_StartBackgroundChecks arms its first check from the shared schedule');
}

// A preset table spelled in a driver is the hand copy this gate retired: the
// Windows and Linux updaters each carried one (1m ... 7d) while the shared
// defaults said the presets "stay driver-specific".
const presetLiteral = /(?:Code:\s*"|code\s*=\s*")(?:1m|5m|10m|1h|24h|1d|7d|never)"/;
for (const [label, source] of [
	['windows/modules/updater/core.ahk', ahkSrc],
	[
		'windows/ui/menu/menu_init.ahk',
		fs.readFileSync(
			path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'ui', 'menu', 'menu_init.ahk'),
			'utf8'
		)
	],
	['linux/modules/updater/manager.lua', fs.readFileSync(LINUX_UPDATER, 'utf8')]
]) {
	if (presetLiteral.test(source)) {
		fail(
			`${label} spells a frequency preset by hand; read timing.check_interval_presets from defaults.json`
		);
	} else {
		pass(`${label} spells no frequency preset`);
	}
}

// Every update channel reads one release list (never /releases/latest, which
// answers 404 while a channel has no release). AHK cannot read JSON at include
// time, so its template literal is pinned here.
const checkUrl = defaults.update_check && defaults.update_check.releases_url;
const ahkCheckUrlM = ahkSrc.match(/UPDATER_RELEASES_API_URL_TEMPLATE\s*:=\s*"([^"]+)"/);
if (
	typeof checkUrl !== 'string' ||
	!checkUrl.includes('{owner}/{repo}') ||
	checkUrl.includes('/releases/latest')
) {
	fail('defaults.json update_check.releases_url must be an {owner}/{repo} release-list template');
} else if (!ahkCheckUrlM) {
	fail('core.ahk: could not find UPDATER_RELEASES_API_URL_TEMPLATE');
} else if (ahkCheckUrlM[1] !== checkUrl) {
	fail(
		`core.ahk UPDATER_RELEASES_API_URL_TEMPLATE="${ahkCheckUrlM[1]}" does not match defaults.json update_check.releases_url="${checkUrl}"`
	);
} else {
	pass(
		'core.ahk UPDATER_RELEASES_API_URL_TEMPLATE matches defaults.json update_check.releases_url'
	);
}
const ahkApiLatest = ahkSrc
	.split('\n')
	.filter((line) => !/^\s*;/.test(line))
	.filter((line) => line.includes('api.github.com') && line.includes('/releases/latest'));
if (ahkApiLatest.length > 0) {
	fail(
		"core.ahk still requests the API's /releases/latest, which answers 404 while a channel has no release"
	);
} else {
	pass('core.ahk requests no /releases/latest endpoint');
}

// ─── Check Lua updater.lua no longer has bare literals ───────────────────────

const luaSrc = fs.readFileSync(LUA_UPDATER, 'utf8');

// The Lua file must read from defaults.json — the old bare literals
// ("adrienm7", "ergopti" as standalone local assignments) should be gone.
// We look for the old pattern: `local GH_OWNER   = "adrienm7"` (not inside FALLBACK).
const luaOldOwnerLiteral = /^local\s+GH_OWNER\s*=\s*"adrienm7"/m;
const luaOldRepoLiteral = /^local\s+GH_REPO\s*=\s*"ergopti"/m;

if (luaOldOwnerLiteral.test(luaSrc)) {
	fail(
		'updater.lua still has bare `local GH_OWNER = "adrienm7"` — should now read from defaults.json'
	);
} else {
	pass('updater.lua no longer has bare GH_OWNER literal (reads from defaults.json)');
}

if (luaOldRepoLiteral.test(luaSrc)) {
	fail(
		'updater.lua still has bare `local GH_REPO = "ergopti"` — should now read from defaults.json'
	);
} else {
	pass('updater.lua no longer has bare GH_REPO literal (reads from defaults.json)');
}

// ─── Lua offline fallbacks must equal defaults.json ─────────────────────────

const macFallback = luaSrc.match(
	/DEFAULT_GITHUB\s*=\s*\{\s*owner\s*=\s*"([^"]+)",\s*repo\s*=\s*"([^"]+)"\s*\}/
);
if (!macFallback) {
	fail('macos/modules/updater/init.lua: could not find DEFAULT_GITHUB');
} else {
	if (macFallback[1] === owner) pass('macOS repository fallback owner matches defaults.json');
	else fail(`macOS repository fallback owner=${macFallback[1]} does not match defaults.json`);
	if (macFallback[2] === repo) pass('macOS repository fallback repo matches defaults.json');
	else fail(`macOS repository fallback repo=${macFallback[2]} does not match defaults.json`);
}
// The macOS cadence is the Lua driver's (modules/updater/auto_check.lua), which
// reads the shared timing through the shared schedule port; the identity facade
// keeps no timing literal of its own.
const MAC_AUTO_CHECK = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'modules',
	'updater',
	'auto_check.lua'
);
if (/start_background_checks|default_check_interval_sec|boot_check_delay_sec/.test(luaSrc)) {
	fail(
		'macOS identity facade must not carry update-check timing; auto_check.lua reads the shared schedule'
	);
} else if (!fs.existsSync(MAC_AUTO_CHECK)) {
	fail(
		'macos/modules/updater/auto_check.lua is missing: nothing owns the macOS update-check cadence'
	);
} else {
	const autoSrc = fs.readFileSync(MAC_AUTO_CHECK, 'utf8');
	if (
		!/defaults\.json/.test(autoSrc) ||
		!autoSrc.includes('require("updater.schedule")') ||
		/\b86400\b/.test(autoSrc)
	) {
		fail(
			'macOS auto_check.lua must read defaults.json through the shared schedule, without timing literals'
		);
	} else {
		pass('macOS automatic checks read the shared timing through the shared schedule');
	}
}

// Linux still owns its updater and therefore retains the complete fallback.
const LUA_DRIVERS = [{ label: 'linux/modules/updater/manager.lua', file: LINUX_UPDATER }];

for (const drv of LUA_DRIVERS) {
	if (!fs.existsSync(drv.file)) {
		fail(`${drv.label}: not found — the updater moved, or this gate's path is stale`);
		continue;
	}
	const src = fs.readFileSync(drv.file, 'utf8');

	const block = src.match(/_DEFAULTS_FALLBACK\s*=\s*\{([\s\S]*?)\n\}/);
	if (!block) {
		fail(`${drv.label}: could not find the _DEFAULTS_FALLBACK table`);
		continue;
	}
	const body = block[1];

	const expectations = [
		{ name: 'github.owner', re: /owner\s*=\s*"([^"]+)"/, want: owner },
		{ name: 'github.repo', re: /repo\s*=\s*"([^"]+)"/, want: repo },
		{
			name: 'timing.default_check_interval_sec',
			re: /default_check_interval_sec\s*=\s*(\d+)/,
			want: interval
		},
		{ name: 'timing.boot_check_delay_sec', re: /boot_check_delay_sec\s*=\s*(\d+)/, want: boot }
	];

	for (const exp of expectations) {
		const m = body.match(exp.re);
		if (!m) {
			fail(`${drv.label}: _DEFAULTS_FALLBACK has no ${exp.name}`);
			continue;
		}
		const got = /^\d+$/.test(m[1]) ? Number(m[1]) : m[1];
		if (got !== exp.want) {
			fail(
				`${drv.label}: _DEFAULTS_FALLBACK ${exp.name}=${JSON.stringify(got)} does not match ` +
					`defaults.json ${exp.name}=${JSON.stringify(exp.want)} — on the offline path this driver ` +
					'would silently use the wrong value'
			);
		} else {
			pass(`${drv.label}: _DEFAULTS_FALLBACK ${exp.name} matches defaults.json`);
		}
	}

	// The live values must come from the JSON, not from the fallback directly.
	if (!/defaults\.json/.test(src)) {
		fail(
			`${drv.label}: does not reference _shared/modules/updater/defaults.json — it must read the canonical source`
		);
	} else {
		pass(`${drv.label}: reads _shared/modules/updater/defaults.json`);
	}
}

// ─── Check the Linux packaging recipes point at the real repository ──────────

// Regression guard: build-linux-deb.sh, build-linux-rpm.sh and PKGBUILD each
// carried "github.com/nizos/ergopti" — a different project. PKGBUILD used it as
// its `source=` clone URL, so `makepkg` would have built the wrong repository,
// and the .deb/.rpm advertised the wrong Homepage. The canonical owner/repo is
// already single-sourced in defaults.json, so these files must agree with it.
// Enumerated as a class rather than pinned per file: any new packaging recipe
// under tools/build/ is covered the moment it is added.
//
// A GitHub URL in a packaging recipe is one of two things, and the rule differs:
//   IDENTITY  — Homepage, source=, the release feed. Answers "which project is
//               this?" and must be ours. That is what nizos/ergopti got wrong.
//   DEPENDENCY — a third-party source the package BUILDS FROM. Legitimately not
//               ours, but never implicit: an unrestricted rule here would have
//               let the original bug back in under a different fork name.
// So dependencies are allowed only when declared below, with the reason. The
// declaration is itself checked for staleness — an exemption nobody uses is how
// an allow-list quietly becomes blanket permission.
const THIRD_PARTY_SOURCES = new Map([
	[
		'LuaJIT/LuaJIT',
		'build-linux-flatpak.sh: the Flatpak runtime ships no LuaJIT, so the manifest builds it from upstream'
	],
	[
		'sparkle-project/Sparkle',
		'automation_query_ci_publisher.py: validates only the canonical launcher Sparkle dependency before refusal-only public lockfile diagnostics'
	]
]);

// This exception is a fixed public dependency identity, never this project's
// identity. It applies only to the publisher's one privacy-allowlist literal,
// and only while the actual launcher manifest declares and links that exact pin.
const SPARKLE_PUBLISHER = 'automation_query_ci_publisher.py';
const SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle';
const SPARKLE_SLUG = 'sparkle-project/Sparkle';
const SPARKLE_MANIFEST = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'launcher',
	'Package.swift'
);
// A bounded literal manifest proof, not Swift evaluation. Strings and comments
// cannot contribute calls; only direct arrays in the canonical package and
// executable target count. Unsupported/computed structures refuse the exception.
function canonicalSparkleManifest(source) {
	try {
		if (source.length > 100000) return false;
		const tokens = [];
		let cursor = 0;
		while (cursor < source.length) {
			const rest = source.slice(cursor);
			if (/^\s/.test(rest)) {
				cursor++;
				continue;
			}
			if (rest.startsWith('//')) {
				const end = source.indexOf('\n', cursor + 2);
				cursor = end < 0 ? source.length : end + 1;
				continue;
			}
			if (rest.startsWith('/*')) {
				let depth = 1;
				cursor += 2;
				while (cursor < source.length && depth > 0) {
					if (source.startsWith('/*', cursor)) {
						depth++;
						cursor += 2;
					} else if (source.startsWith('*/', cursor)) {
						depth--;
						cursor += 2;
					} else cursor++;
				}
				if (depth !== 0) return false;
				continue;
			}
			const raw = rest.match(/^(#+)("""|")/);
			if (raw || rest.startsWith('"""')) {
				const opening = raw ? raw[0] : '"""';
				const closing = raw ? raw[2] + raw[1] : '"""';
				const end = source.indexOf(closing, cursor + opening.length);
				if (end < 0 || source.slice(cursor + opening.length, end).includes('\\')) return false;
				tokens.push({ kind: 'string', value: null });
				cursor = end + closing.length;
				continue;
			}
			if (rest.startsWith('"')) {
				let end = cursor + 1;
				while (end < source.length && source[end] !== '"') {
					if (source[end] === '\n' || source[end] === '\r' || source[end] === '\\') return false;
					end++;
				}
				if (end >= source.length) return false;
				tokens.push({ kind: 'string', value: source.slice(cursor + 1, end) });
				cursor = end + 1;
				continue;
			}
			const identifier = rest.match(/^[A-Za-z_][A-Za-z0-9_]*/);
			if (identifier) {
				tokens.push({ kind: 'identifier', value: identifier[0] });
				cursor += identifier[0].length;
			} else {
				if (rest[0] === '#') return false;
				tokens.push({ kind: 'symbol', value: rest[0] });
				cursor++;
			}
			if (tokens.length > 20000) return false;
		}
		if (tokens.length > 20000) return false;
		const is = (token, kind, value) => token && token.kind === kind && token.value === value;
		const closing = { '(': ')', '[': ']', '{': '}' };
		function split(items) {
			const result = [];
			let current = [];
			const stack = [];
			for (const token of items) {
				if (token.kind === 'symbol') {
					if (closing[token.value]) {
						stack.push(closing[token.value]);
						if (stack.length > 64) throw new Error('manifest depth');
					} else if ([')', ']', '}'].includes(token.value)) {
						if (stack.pop() !== token.value) throw new Error('manifest delimiter');
					} else if (token.value === ',' && stack.length === 0) {
						if (current.length === 0) throw new Error('manifest empty item');
						result.push(current);
						current = [];
						continue;
					}
				}
				current.push(token);
			}
			if (stack.length) throw new Error('manifest delimiter');
			if (current.length) result.push(current);
			return result;
		}
		function args(items) {
			const result = new Map();
			for (const item of split(items)) {
				if (
					item.length < 3 ||
					item[0].kind !== 'identifier' ||
					!is(item[1], 'symbol', ':') ||
					result.has(item[0].value)
				)
					throw new Error('manifest argument');
				result.set(item[0].value, item.slice(2));
			}
			return result;
		}
		function call(items, name) {
			if (
				!items ||
				!is(items[0], 'symbol', '.') ||
				!is(items[1], 'identifier', name) ||
				!is(items[2], 'symbol', '(') ||
				!is(items.at(-1), 'symbol', ')')
			)
				return null;
			return args(items.slice(3, -1));
		}
		function array(items) {
			if (!items || !is(items[0], 'symbol', '[') || !is(items.at(-1), 'symbol', ']')) return null;
			return split(items.slice(1, -1));
		}
		const literal = (items, value) => items && items.length === 1 && is(items[0], 'string', value);
		// Only supported immutable declarations may surround the direct initializer.
		// A PackageDescription Package is mutable even when its binding uses let:
		// ignoring later statements would admit a manifest that removes this join.
		function parenthesized(start) {
			if (!is(tokens[start], 'symbol', '(')) throw new Error('manifest call');
			const stack = [')'];
			let end = start + 1;
			for (; end < tokens.length && stack.length; end++) {
				const token = tokens[end];
				if (token.kind !== 'symbol') continue;
				if (closing[token.value]) stack.push(closing[token.value]);
				else if ([')', ']', '}'].includes(token.value) && stack.pop() !== token.value)
					throw new Error('manifest delimiter');
				if (stack.length > 64) throw new Error('manifest depth');
			}
			if (stack.length) throw new Error('manifest delimiter');
			return end;
		}
		const pureCalls = new Set([
			'macOS',
			'executable',
			'package',
			'target',
			'executableTarget',
			'testTarget',
			'product',
			'define',
			'when',
			'linkedFramework',
			'unsafeFlags'
		]);
		// The remaining SDK settings must also be direct literal construction, never
		// closures, member transformations or arbitrary executable expressions.
		function pureValue(items) {
			if (items.length === 1) return items[0].kind === 'string' && items[0].value !== null;
			if (is(items[0], 'symbol', '[') && is(items.at(-1), 'symbol', ']'))
				return split(items.slice(1, -1)).every(pureValue);
			if (!is(items[0], 'symbol', '.') || items[1]?.kind !== 'identifier') return false;
			if (items.length === 2) return ['v11', 'debug'].includes(items[1].value);
			if (
				!pureCalls.has(items[1].value) ||
				!is(items[2], 'symbol', '(') ||
				!is(items.at(-1), 'symbol', ')')
			)
				return false;
			return split(items.slice(3, -1)).every((item) => {
				const value =
					item[0]?.kind === 'identifier' && is(item[1], 'symbol', ':') ? item.slice(2) : item;
				return pureValue(value);
			});
		}
		if (
			!is(tokens[0], 'identifier', 'import') ||
			!is(tokens[1], 'identifier', 'PackageDescription')
		)
			return false;
		let index = 2;
		if (is(tokens[index], 'symbol', ';')) index++;
		if (
			!is(tokens[index], 'identifier', 'let') ||
			!is(tokens[index + 1], 'identifier', 'package') ||
			!is(tokens[index + 2], 'symbol', '=') ||
			!is(tokens[index + 3], 'identifier', 'Package')
		)
			return false;
		const end = parenthesized(index + 4);
		const packageArgs = args(tokens.slice(index + 5, end - 1));
		if (
			packageArgs.size !== 5 ||
			!['name', 'platforms', 'products', 'dependencies', 'targets'].every((key) =>
				packageArgs.has(key)
			) ||
			![...packageArgs.values()].every(pureValue) ||
			!literal(packageArgs.get('name'), 'ErgoptiPlus')
		)
			return false;
		index = end;
		const bindings = new Set(['package', 'Package', 'PackageDescription', 'Target']);
		// A detached, explicitly typed SDK product constant is harmless and cannot
		// supply the package's join. All other trailing statements are unsupported.
		while (index < tokens.length) {
			if (is(tokens[index], 'symbol', ';')) {
				index++;
				if (index === tokens.length) break;
			}
			const name = tokens[index + 1];
			if (
				!is(tokens[index], 'identifier', 'let') ||
				name?.kind !== 'identifier' ||
				bindings.has(name.value) ||
				!is(tokens[index + 2], 'symbol', ':') ||
				!is(tokens[index + 3], 'identifier', 'Target') ||
				!is(tokens[index + 4], 'symbol', '.') ||
				!is(tokens[index + 5], 'identifier', 'Dependency') ||
				!is(tokens[index + 6], 'symbol', '=') ||
				!is(tokens[index + 7], 'symbol', '.') ||
				!is(tokens[index + 8], 'identifier', 'product')
			)
				return false;
			const last = parenthesized(index + 9);
			const detached = call(tokens.slice(index + 7, last), 'product');
			if (
				!detached ||
				detached.size !== 2 ||
				!literal(detached.get('name'), 'Sparkle') ||
				!literal(detached.get('package'), 'Sparkle')
			)
				return false;
			bindings.add(name.value);
			index = last;
		}
		const dependencies = array(packageArgs.get('dependencies'));
		if (!dependencies || dependencies.length !== 1) return false;
		const dependency = call(dependencies[0], 'package');
		if (
			!dependency ||
			dependency.size !== 2 ||
			!literal(dependency.get('url'), SPARKLE_URL) ||
			!literal(dependency.get('exact'), '2.9.2')
		)
			return false;
		const outputs = array(packageArgs.get('products'));
		if (!outputs || outputs.length !== 1) return false;
		const output = call(outputs[0], 'executable');
		if (!output || output.size !== 2 || !literal(output.get('name'), 'ErgoptiPlus')) return false;
		const outputTargets = array(output.get('targets'));
		if (!outputTargets || outputTargets.length !== 1 || !literal(outputTargets[0], 'ErgoptiPlus'))
			return false;
		const targets = array(packageArgs.get('targets'));
		if (!targets) return false;
		const targetNames = new Set();
		for (const target of targets) {
			const declaration =
				call(target, 'target') || call(target, 'executableTarget') || call(target, 'testTarget');
			const name = declaration && declaration.get('name');
			if (
				!name ||
				name.length !== 1 ||
				name[0].kind !== 'string' ||
				name[0].value === null ||
				targetNames.has(name[0].value)
			)
				return false;
			targetNames.add(name[0].value);
		}
		const executables = targets
			.map((target) => call(target, 'executableTarget'))
			.filter((target) => target && literal(target.get('name'), 'ErgoptiPlus'));
		if (executables.length !== 1) return false;
		const linked = array(executables[0].get('dependencies'));
		if (!linked) return false;
		const products = [];
		for (const item of linked) {
			if (item.length === 1 && item[0].kind === 'string' && item[0].value !== null) continue;
			const product = call(item, 'product');
			if (
				!product ||
				product.size !== 2 ||
				!literal(product.get('name'), 'Sparkle') ||
				!literal(product.get('package'), 'Sparkle')
			)
				return false;
			products.push(product);
		}
		return products.length === 1;
	} catch {
		return false;
	}
}

let sparkleManifestCurrent = false;
if (!fs.existsSync(SPARKLE_MANIFEST) || !fs.lstatSync(SPARKLE_MANIFEST).isFile()) {
	fail('Sparkle dependency exception requires the actual regular launcher Package.swift');
} else {
	const manifest = fs.readFileSync(SPARKLE_MANIFEST, 'utf8');
	sparkleManifestCurrent = canonicalSparkleManifest(manifest);
	if (!sparkleManifestCurrent) {
		fail(
			'Sparkle dependency exception requires one canonical Sparkle2.9.2 package declaration and linked product'
		);
	} else {
		pass('Sparkle exception joins the actual canonical launcher dependency and linked product');
	}
}

const PACKAGING_DIR = path.join(ROOT, 'tools', 'build');
const GITHUB_URL_RE = /github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?(?=["'\s)#]|$)/g;

const thirdPartySeen = new Set();

let packagingFilesScanned = 0;
let packagingUrlsChecked = 0;

for (const entry of fs.readdirSync(PACKAGING_DIR, { withFileTypes: true })) {
	if (!entry.isFile()) continue;
	// Shell packagers plus the extensionless Arch recipe.
	if (!/\.(sh|cjs|js|py)$/.test(entry.name) && entry.name !== 'PKGBUILD') continue;

	const full = path.join(PACKAGING_DIR, entry.name);
	const src = fs.readFileSync(full, 'utf8');
	packagingFilesScanned++;

	for (const m of src.matchAll(GITHUB_URL_RE)) {
		packagingUrlsChecked++;
		const slug = `${m[1]}/${m[2]}`;
		if (m[1] === owner && m[2] === repo) continue;
		if (THIRD_PARTY_SOURCES.has(slug)) {
			if (slug === SPARKLE_SLUG) {
				const exactLiteral = /["']https:\/\/github\.com\/sparkle-project\/Sparkle["']/g;
				const sparkleUrls = [...src.matchAll(GITHUB_URL_RE)].filter(
					(url) => `${url[1]}/${url[2]}` === SPARKLE_SLUG
				);
				if (
					entry.name !== SPARKLE_PUBLISHER ||
					!sparkleManifestCurrent ||
					sparkleUrls.length !== 1 ||
					[...src.matchAll(exactLiteral)].length !== 1
				) {
					fail(
						`tools/build/${entry.name}: Sparkle exception is restricted to the publisher's one canonical public dependency literal`
					);
					continue;
				}
			}
			thirdPartySeen.add(slug);
			continue;
		}
		fail(
			`tools/build/${entry.name}: github.com/${slug} does not match ` +
				`defaults.json github.owner/repo (${owner}/${repo}). If it identifies ` +
				`this project, point it at ${owner}/${repo}; if it is a third-party ` +
				`dependency the package builds from, declare it in THIRD_PARTY_SOURCES ` +
				`with the reason.`
		);
	}
}

// A declared exemption that no recipe uses any more must be deleted, not left
// standing: the next third-party URL that happens to match it would be waved
// through on the strength of a reason that no longer applies anywhere.
for (const [slug, reason] of THIRD_PARTY_SOURCES) {
	if (!thirdPartySeen.has(slug)) {
		fail(
			`THIRD_PARTY_SOURCES declares github.com/${slug} but no recipe under ` +
				`tools/build/ references it — remove the stale exemption (${reason})`
		);
	}
}

if (packagingFilesScanned === 0) {
	fail('tools/build/ scan matched no packaging file — the selector is wrong, not the tree');
} else if (packagingUrlsChecked === 0) {
	fail(
		'tools/build/ contains no github.com URL — expected at least the packaging Homepage/source lines'
	);
} else if (exitCode === 0) {
	pass(
		`every github.com URL in tools/build/ matches defaults.json (${packagingUrlsChecked} URL(s) across ${packagingFilesScanned} file(s))`
	);
}

// ─── Verify dead constants.toml is gone ──────────────────────────────────────

const deadToml = path.join(SHARED_ROOT, 'modules', 'updater', 'constants.toml');
if (fs.existsSync(deadToml)) {
	fail(
		'_shared/modules/updater/constants.toml still exists — should have been deleted (dead code, §5.6)'
	);
} else {
	pass('dead constants.toml is absent');
}

// ─── Summary ─────────────────────────────────────────────────────────────────

if (exitCode === 0) {
	console.log('\n✅  updater-constants-single-source: all checks passed.');
} else {
	console.error('\n❌  updater-constants-single-source: one or more checks FAILED.');
}

process.exit(exitCode);
