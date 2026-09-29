// tools/test/test-macos-sparkle-disarmed-bundles.cjs

/**
 * ==============================================================================
 * MODULE: macOS Disarmed Sparkle Bundles
 * DESCRIPTION:
 * Only the launcher's Sparkle may update ErgoptiPlus, and it never downloads
 * before consent (SUAllowsAutomaticUpdates false). The two other bundles the
 * macOS build ships with a Sparkle-aware Info.plist, the embedded Hammerspoon
 * and the Git-checkout helper, must be unable to update themselves at all.
 *
 * ROOT CAUSE ENCODED:
 * The embedded Hammerspoon lost its feed and scheduled checks but kept its
 * SUAllowsAutomaticUpdates untouched, and the feed removal ran as
 * `plutil -remove SUFeedURL ... 2>/dev/null || true`, so a failed edit shipped
 * silently. Both bundles now go through one disarm_bundle_sparkle function
 * that reads every edited key back. This guard runs that function against a
 * plist double holding Hammerspoon 1.1.1's Sparkle keys, and requires every
 * disarmed bundle to call it. Its first version also failed on a bundle that
 * never declared a feed or a check interval, although absence is the goal:
 * a later Hammerspoon without one of them would have broken the build while
 * the read-back already proves the key is gone.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const root = path.resolve(__dirname, '..', '..');
const buildScript = fs.readFileSync(
	path.join(root, 'tools', 'build', 'build_macos_app.sh'),
	'utf8'
);
const errors = [];

/**
 * Returns one top-level shell function, from its header to its closing brace.
 * @param {string} name Function name.
 * @returns {string} Function source, or an empty string when absent.
 */
function shellFunction(name) {
	const start = buildScript.indexOf(`\n${name}() {\n`);
	if (start < 0) return '';
	const end = buildScript.indexOf('\n}\n', start + 1);
	return end < 0 ? '' : buildScript.slice(start + 1, end + 2);
}

// Every bundle that must never update itself, with the variable naming its plist.
const DISARMED_BUNDLES = [
	{ owner: 'assemble_app', plist: '$hs_plist', label: 'embedded Hammerspoon.app' },
	{ owner: 'build_native_helper', plist: '$plist', label: 'Git-checkout native helper' }
];

const disarm = shellFunction('disarm_bundle_sparkle');
if (!disarm) {
	errors.push(
		'build_macos_app.sh must define disarm_bundle_sparkle for bundles that must not update themselves'
	);
}
for (const bundle of DISARMED_BUNDLES) {
	const body = shellFunction(bundle.owner);
	if (!body) {
		errors.push(`build_macos_app.sh no longer defines ${bundle.owner}`);
	} else if (!body.includes(`disarm_bundle_sparkle "${bundle.plist}"`)) {
		errors.push(
			`${bundle.owner} must disarm the Sparkle of the ${bundle.label} through disarm_bundle_sparkle`
		);
	}
}

// One owner for the switches: an edit outside the function is how the embedded
// app kept SUAllowsAutomaticUpdates, and a swallowed plutil failure is how a
// failed edit shipped.
const outside = buildScript.replace(disarm, '');
for (const line of outside.split('\n')) {
	if (
		/^\s*plutil\b.*\bSU(?:FeedURL|ScheduledCheckInterval|EnableAutomaticChecks|AllowsAutomaticUpdates)\b/.test(
			line
		)
	) {
		errors.push(`Sparkle keys must be edited only by disarm_bundle_sparkle, found: ${line.trim()}`);
	}
	if (/^\s*plutil\b.*\|\|\s*true\b/.test(line)) {
		errors.push(`a plutil failure must fail the build, found: ${line.trim()}`);
	}
}

// A plist double: one KEY=VALUE line per key, edited by a plutil shell function
// with the subcommands the build uses. IGNORE_REPLACE and IGNORE_REMOVE model an
// edit that reports success without changing the plist.
const PLUTIL_DOUBLE = [
	'plutil() {',
	'	local key file line',
	'	case "$1" in',
	'		-lint)',
	'			[ -f "$2" ] ;;',
	'		-remove)',
	'			key="$2"; file="$3"',
	'			grep -q "^$key=" "$file" || return 1',
	'			[ -z "${IGNORE_REMOVE:-}" ] || return 0',
	'			grep -v "^$key=" "$file" > "$file.next"',
	'			mv "$file.next" "$file" ;;',
	'		-replace)',
	'			key="$2"; file="$5"',
	'			[ -z "${IGNORE_REPLACE:-}" ] || return 0',
	'			grep -v "^$key=" "$file" > "$file.next"',
	'			printf \'%s=%s\\n\' "$key" "$4" >> "$file.next"',
	'			mv "$file.next" "$file" ;;',
	'		-extract)',
	'			key="$2"; file="$6"',
	'			line="$(grep "^$key=" "$file")" || return 1',
	'			printf \'%s\\n\' "${line#*=}" ;;',
	'		*) return 2 ;;',
	'	esac',
	'}'
].join('\n');

// Hammerspoon 1.1.1's Hammerspoon-Info.plist declares exactly these Sparkle keys.
const HAMMERSPOON_1_1_1_SPARKLE = [
	'CFBundleIdentifier=com.ergoptiplus.app.hammerspoon',
	'SUEnableAutomaticChecks=true',
	'SUFeedURL=https://raw.githubusercontent.com/Hammerspoon/hammerspoon/master/appcast.xml',
	'SUScheduledCheckInterval=21600'
];

const toPosix = (value) => value.replace(/^([A-Za-z]):/, '/$1').replaceAll('\\', '/');
const bash = bashExecutable();

/**
 * Runs disarm_bundle_sparkle on a plist double.
 * @param {string[]} entries Initial KEY=VALUE lines.
 * @param {object} env Extra environment for the double; MISSING_PLIST points the
 *   function at a path that does not exist.
 * @returns {{status: number|null, stderr: string, plist: Map<string, string>}}
 */
function runDisarm(entries, env = {}) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sparkle-disarm-'));
	try {
		const plistPath = path.join(dir, 'Info.plist');
		const scriptPath = path.join(dir, 'disarm.sh');
		fs.writeFileSync(plistPath, entries.map((entry) => `${entry}\n`).join(''));
		fs.writeFileSync(
			scriptPath,
			[
				'set -euo pipefail',
				'fail() { printf \'%s\\n\' "$*" >&2; exit 1; }',
				PLUTIL_DOUBLE,
				disarm,
				'disarm_bundle_sparkle "$1${MISSING_PLIST:+.missing}"',
				''
			].join('\n')
		);
		const run = spawnSync(bash, [toPosix(scriptPath), toPosix(plistPath)], {
			encoding: 'utf8',
			env: { ...process.env, ...env }
		});
		const plist = new Map(
			fs
				.readFileSync(plistPath, 'utf8')
				.split('\n')
				.filter(Boolean)
				.map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)])
		);
		return {
			status: run.status,
			stderr: `${run.stderr ?? ''}${run.error ? run.error.message : ''}`,
			plist
		};
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

if (disarm) {
	const disarmed = runDisarm(HAMMERSPOON_1_1_1_SPARKLE);
	if (disarmed.status !== 0) {
		errors.push(
			`disarm_bundle_sparkle refused Hammerspoon 1.1.1's Sparkle keys: ${disarmed.stderr.trim()}`
		);
	} else {
		for (const key of ['SUEnableAutomaticChecks', 'SUAllowsAutomaticUpdates']) {
			if (disarmed.plist.get(key) !== 'false') {
				errors.push(
					`a disarmed bundle must declare ${key} false, found ${disarmed.plist.get(key)}`
				);
			}
		}
		for (const key of ['SUFeedURL', 'SUScheduledCheckInterval']) {
			if (disarmed.plist.has(key)) errors.push(`a disarmed bundle must not declare ${key}`);
		}
		if (disarmed.plist.get('CFBundleIdentifier') !== 'com.ergoptiplus.app.hammerspoon') {
			errors.push("disarm_bundle_sparkle must leave keys other than Sparkle's untouched");
		}
	}

	// Absence is the goal: a bundle that never declared the feed or the check
	// interval is disarmed for that key, and must still get both switches off.
	for (const absent of ['SUFeedURL', 'SUScheduledCheckInterval']) {
		const without = runDisarm(
			HAMMERSPOON_1_1_1_SPARKLE.filter((entry) => !entry.startsWith(`${absent}=`))
		);
		if (without.status !== 0) {
			errors.push(
				`disarm_bundle_sparkle must accept a bundle that declares no ${absent}: ${without.stderr.trim()}`
			);
			continue;
		}
		for (const key of ['SUEnableAutomaticChecks', 'SUAllowsAutomaticUpdates']) {
			if (without.plist.get(key) !== 'false') {
				errors.push(`without ${absent}, a disarmed bundle must still declare ${key} false`);
			}
		}
		for (const key of ['SUFeedURL', 'SUScheduledCheckInterval']) {
			if (without.plist.has(key))
				errors.push(`without ${absent}, a disarmed bundle must not declare ${key}`);
		}
	}

	const unchanged = runDisarm(HAMMERSPOON_1_1_1_SPARKLE, { IGNORE_REPLACE: '1' });
	if (unchanged.status === 0) {
		errors.push(
			'disarm_bundle_sparkle must read each switch back and fail when an edit did not apply'
		);
	}

	const kept = runDisarm(HAMMERSPOON_1_1_1_SPARKLE, { IGNORE_REMOVE: '1' });
	if (kept.status === 0) {
		errors.push(
			'disarm_bundle_sparkle must read the feed back and fail when its removal did not apply'
		);
	}

	const unreadable = runDisarm(HAMMERSPOON_1_1_1_SPARKLE, { MISSING_PLIST: '1' });
	if (unreadable.status === 0) {
		errors.push(
			'disarm_bundle_sparkle must fail on a plist it cannot read, not treat every key as absent'
		);
	}
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log(
	'[OK] the embedded Hammerspoon and the native helper cannot update themselves through Sparkle.'
);
