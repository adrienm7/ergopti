// tools/test/test-shared-lua-helpers-single-use.cjs

/**
 * ==============================================================================
 * MODULE: Shared Lua Helpers Single-Use Ratchet
 * DESCRIPTION:
 * The macOS driver, the Linux driver and the shared Lua they both load copy,
 * count, trim, shell-quote and percent-encode only through the shared owners:
 * _shared/lua/table_util.lua and _shared/lua/text_utils/init.lua.
 *
 * ROOT CAUSE ENCODED:
 * The cross-OS parity audit (R16, K10) counted 26 deep-copy definitions, the
 * trim pattern in 54 places beside 9 local trim functions, 6 shell_quote
 * definitions and 4 percent-encoders. The copies had already drifted: trim(nil)
 * returned "nil" in one file, "" in another and raised in a third; one shell
 * quote turned false into '' and another into 'false'. A fix made in one copy
 * never reached the others.
 *
 * HOW THE RATCHET WORKS:
 * Each detector below recognises one inline spelling in comment-free source.
 * ALLOWED names the few sites that spell a pattern for a different job, each
 * with its reason. Every other site is a debt counted in
 * shared-lua-helpers-baseline.json, per file and per helper. A count above
 * the baseline fails (a new inline copy); a count below it also fails until
 * the baseline is lowered in the same change, so the baseline can only shrink.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { stripComments } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const BASELINE_FILE = path.join(__dirname, 'shared-lua-helpers-baseline.json');

// The three trees and the floor each walk must reach, so a broken walk cannot
// pass by reading nothing.
const TREES = [
	{ dir: 'macos', excluded: 'macos/tests/', minFiles: 300 },
	{ dir: 'linux', excluded: 'linux/tests/', minFiles: 200 },
	{ dir: '_shared/lua', excluded: '_shared/lua/test/', minFiles: 200 }
];

const TABLE_OWNER = '_shared/lua/table_util.lua';
const TEXT_OWNER = '_shared/lua/text_utils/init.lua';

// Reusable regex fragments over comment-free Lua source.
const NAME = String.raw`([\w.:]+)`;
const PARAM = String.raw`\(\s*(\w+)\s*\)`;
const TYPE_GUARD = String.raw`if\s+type\s*\(\s*\2\s*\)\s*~=\s*["']table["']\s+then\s+return\s+\2\s*;?\s*end\s*;?\s*`;
const CALL_ARGS = String.raw`\((?:[^()]|\([^()]*\))*\)`;

/** Builds a global regex from raw source fragments. */
function rx(...parts) {
	return new RegExp(parts.join(''), 'g');
}

// Each helper: its owner, the function a site must call instead, and the
// inline spellings that redefine it. A copy that walks `next, t` instead of
// pairs(t) is not matched: it is a raw copy that never runs a __pairs
// metamethod, which pairs() would run under Lua 5.4.
const DETECTORS = {
	trim: {
		owner: TEXT_OWNER,
		use: 'require("text_utils").trim(text)',
		patterns: [
			/(["'])\^%s\*\(\.-\)%s\*\$\1/g,
			/gsub\(\s*(["'])\^%s[+*]\1\s*,\s*(?:""|'')\s*\)\s*:\s*gsub\(\s*(["'])%s[+*]\$\2\s*,\s*(?:""|'')\s*\)/g,
			/gsub\(\s*(["'])%s[+*]\$\1\s*,\s*(?:""|'')\s*\)\s*:\s*gsub\(\s*(["'])\^%s[+*]\2\s*,\s*(?:""|'')\s*\)/g,
			/while\s+[\w.]+\s*:\s*find\(\s*(["'])\^%s\1\s*,/g
		]
	},
	shell_quote: {
		owner: TEXT_OWNER,
		use: 'require("text_utils").shell_quote(value)',
		patterns: [/"'\\\\''"/g]
	},
	percent_encode: {
		owner: TEXT_OWNER,
		use: 'require("text_utils").percent_encode(text)',
		patterns: [/(["'])%%%02[Xx]\1/g]
	},
	shallow_copy: {
		owner: TABLE_OWNER,
		use: 'require("table_util").shallow_copy(source)',
		patterns: [
			rx(
				String.raw`function\s+`,
				NAME,
				String.raw`\s*`,
				PARAM,
				String.raw`\s*(?:`,
				TYPE_GUARD,
				String.raw`)?local\s+(\w+)\s*=\s*\{\s*\}\s*;?\s*for\s+(\w+)\s*,\s*(\w+)\s+in\s+`,
				String.raw`pairs\s*\(\s*\2(?:\s+or\s*\{\s*\})?\s*\)\s*do\s+`,
				String.raw`\3\s*\[\s*\4\s*\]\s*=\s*\5\s*;?\s*end\s*;?\s*return\s+\3\s*;?\s*end`
			)
		]
	},
	deep_copy: {
		owner: TABLE_OWNER,
		use: 'require("table_util").deep_copy(value) or .deep_copy_with_keys(value)',
		patterns: [
			rx(
				String.raw`function\s+`,
				NAME,
				String.raw`\s*`,
				PARAM,
				String.raw`\s*`,
				TYPE_GUARD,
				String.raw`local\s+(\w+)\s*=\s*\{\s*\}\s*;?\s*for\s+(\w+)\s*,\s*(\w+)\s+in\s+`,
				String.raw`pairs\s*\(\s*\2\s*\)\s*do\s+`,
				String.raw`\3\s*\[\s*(?:\4|\1\s*\(\s*\4\s*\))\s*\]\s*=\s*\1\s*\(\s*\5\s*\)\s*;?\s*end\s*;?\s*`,
				String.raw`return\s+\3\s*;?\s*end`
			)
		]
	},
	sorted_keys: {
		owner: TABLE_OWNER,
		use: 'require("table_util").sorted_keys(source)',
		patterns: [
			rx(
				String.raw`for\s+(\w+)\s+in\s+pairs\s*`,
				CALL_ARGS,
				String.raw`\s*do\s+(\w+)\s*\[\s*#\s*\2\s*\+\s*1\s*\]\s*=\s*\1\s*;?\s*end\s*;?\s*`,
				String.raw`table\s*\.\s*sort\s*\(\s*\2\s*[,)]`
			)
		]
	},
	count: {
		owner: TABLE_OWNER,
		use: 'require("table_util").count(source)',
		patterns: [
			rx(
				String.raw`for\s+\w+(?:\s*,\s*\w+)?\s+in\s+pairs\s*`,
				CALL_ARGS,
				String.raw`\s*do\s+([\w.]+)\s*=\s*\1\s*\+\s*1\s*;?\s*end`
			)
		]
	}
};

// Sites that spell a detected pattern for another job: path -> helper ->
// { count, reason }. These are not debt and are not expected to shrink.
const ALLOWED = {
	'macos/adapters/shell_runner.lua': {
		shell_quote: {
			count: 1,
			reason: "printf '%b' operand: backslashes and NUL are escaped before the quote"
		}
	},
	'linux/ui/webview_manager.lua': {
		percent_encode: {
			count: 1,
			reason: 'escapes every non-alphanumeric byte of a JS bridge payload, not a URL component'
		}
	}
};

// ==================================================
// ==================================================
// ======= 1/ Detector Controls =====================
// ==================================================
// ==================================================

/** Counts the matches of one helper's detectors in comment-free source. */
function countMatches(helper, code) {
	let count = 0;
	for (const pattern of DETECTORS[helper].patterns) {
		pattern.lastIndex = 0;
		count += [...code.matchAll(pattern)].length;
	}
	return count;
}

// Each detector must see the spellings the drivers actually used and stay
// silent on the owner calls that replace them; a detector that matches
// nothing would make the whole ratchet pass by seeing nothing.
const CONTROLS = [
	['trim', 'local line = raw:match("^%s*(.-)%s*$")', 1],
	['trim', "local s = x:gsub('^%s+', ''):gsub('%s+$', '')", 1],
	['trim', 'return (x:gsub("%s*$", ""):gsub("^%s*", ""))', 1],
	['trim', 'while value:find("^%s", last) do last = last - 1 end', 1],
	['trim', 'local line = TextUtils.trim(raw)', 0],
	['trim', 'local tail = raw:gsub("%s+$", "")', 0],
	['trim', '-- raw:match("^%s*(.-)%s*$")', 0],
	['shell_quote', `return "'" .. tostring(v):gsub("'", "'\\\\''") .. "'"`, 1],
	['shell_quote', 'return TextUtils.shell_quote(v)', 0],
	['percent_encode', 'return string.format("%%%02X", c:byte())', 1],
	['percent_encode', 'return string.format("#%02X%02X%02X", r, g, b)', 0],
	[
		'shallow_copy',
		'local function copy(a)local r={};for k,v in pairs(a)do r[k]=v end;return r end',
		1
	],
	[
		'shallow_copy',
		'local function copy(a)local r={};for k,v in next, a do r[k]=v end;return r end',
		0
	],
	[
		'shallow_copy',
		'local function shallow_copy(source)\n\tlocal result = {}\n\tfor key, value in pairs(source or {}) do result[key] = value end\n\treturn result\nend',
		1
	],
	[
		'shallow_copy',
		'local function copy_value(value)\n\tif type(value) ~= "table" then return value end\n\tlocal copy = {}\n\tfor key, item in pairs(value) do copy[key] = item end\n\treturn copy\nend',
		1
	],
	[
		'shallow_copy',
		'local function f(a) local r = {} for k, v in pairs(a) do r[v] = k end return r end',
		0
	],
	[
		'deep_copy',
		'local function clone(value)\n\tif type(value) ~= "table" then return value end\n\tlocal copy = {}\n\tfor key, child in pairs(value) do copy[key] = clone(child) end\n\treturn copy\nend',
		1
	],
	[
		'deep_copy',
		'local function deep_copy(value)\n\tif type(value) ~= "table" then return value end\n\tlocal copy = {}\n\tfor key, nested in pairs(value) do\n\t\tcopy[deep_copy(key)] = deep_copy(nested)\n\tend\n\treturn copy\nend',
		1
	],
	[
		'deep_copy',
		'local function copy(value)\n\tif type(value) ~= "table" then return value end\n\tlocal out = {}; for key, child in pairs(value) do out[key] = copy(child) end\n\treturn out\nend',
		1
	],
	['deep_copy', 'local copy = TableUtil.deep_copy(value)', 0],
	[
		'sorted_keys',
		'local keys = {}\nfor key in pairs(map) do keys[#keys + 1] = key end\ntable.sort(keys, function(a, b) return tostring(a) < tostring(b) end)',
		1
	],
	[
		'sorted_keys',
		'for key in pairs(type(t) == "table" and t or {}) do keys[#keys + 1] = key end table.sort(keys)',
		1
	],
	['sorted_keys', 'for key in pairs(map) do keys[#keys + 1] = key end', 0],
	['count', 'for _ in pairs(_map.apps) do count = count + 1 end', 1],
	['count', 'local n = 0; for _ in pairs(t) do n = n + 1 end', 1],
	['count', 'for _, v in pairs(t) do if v then n = n + 1 end end', 0],
	['count', 'local n = TableUtil.count(t)', 0]
];
for (const [helper, source, expected] of CONTROLS) {
	assert.equal(
		countMatches(helper, stripComments(source, '.lua')),
		expected,
		`${helper} detector control: ${source}`
	);
}

// ==================================================
// ==================================================
// ======= 2/ Source Scan ===========================
// ==================================================
// ==================================================

/** Lists the production Lua sources of one tree, relative to the drivers root. */
function collect(relative, excluded, out) {
	for (const entry of fs.readdirSync(path.join(DRIVERS, relative), { withFileTypes: true })) {
		const child = `${relative}/${entry.name}`;
		if (entry.isDirectory()) {
			if (`${child}/` !== excluded) collect(child, excluded, out);
		} else if (entry.isFile() && entry.name.endsWith('.lua')) out.push(child);
	}
	return out;
}

/** Returns the line number of an offset. */
function lineOf(text, offset) {
	let line = 1;
	for (let at = text.indexOf('\n'); at !== -1 && at < offset; at = text.indexOf('\n', at + 1))
		line++;
	return line;
}

const baseline = JSON.parse(fs.readFileSync(BASELINE_FILE, 'utf8'));
const errors = [];
const observed = {};
const seen = new Set();
let scanned = 0;

for (const tree of TREES) {
	const files = collect(tree.dir, tree.excluded, []);
	if (files.length < tree.minFiles)
		errors.push(`the ${tree.dir} walk found ${files.length} .lua files (floor ${tree.minFiles})`);
	for (const rel of files) {
		scanned++;
		seen.add(rel);
		const code = stripComments(fs.readFileSync(path.join(DRIVERS, rel), 'utf8'), '.lua');
		for (const helper of Object.keys(DETECTORS)) {
			if (DETECTORS[helper].owner === rel) continue;
			const found = countMatches(helper, code);
			const allowed = ALLOWED[rel]?.[helper]?.count ?? 0;
			const debt = baseline[rel]?.[helper] ?? 0;
			if (found > allowed) (observed[rel] ??= {})[helper] = found - allowed;
			if (found > allowed + debt) {
				const lines = [];
				for (const pattern of DETECTORS[helper].patterns) {
					pattern.lastIndex = 0;
					for (const match of code.matchAll(pattern)) lines.push(lineOf(code, match.index));
				}
				errors.push(
					`${rel}:${lines.sort((a, b) => a - b).join(',')}: ${found} inline ${helper} ` +
						`(allowed ${allowed}, baseline ${debt}). Call ${DETECTORS[helper].use} instead.`
				);
			} else if (found < allowed + debt) {
				errors.push(
					`${rel}: ${helper} now has ${found - allowed} inline site(s) but the baseline still ` +
						`counts ${debt}. Lower ${path.basename(BASELINE_FILE)} to match: it only shrinks.`
				);
			}
		}
	}
}

for (const [rel, helpers] of Object.entries(baseline)) {
	if (!seen.has(rel)) errors.push(`${rel}: listed in the baseline, but no such source`);
	for (const [helper, count] of Object.entries(helpers)) {
		if (!Object.hasOwn(DETECTORS, helper)) errors.push(`${rel}: unknown helper ${helper}`);
		if (!Number.isInteger(count) || count < 1)
			errors.push(`${rel}: ${helper} baseline must be a positive integer, got ${count}`);
	}
}
for (const rel of Object.keys(ALLOWED)) {
	if (!seen.has(rel)) errors.push(`${rel}: listed in ALLOWED, but no such source`);
}

// The owners must still define what every site is told to call.
const OWNER_DEFINITIONS = {
	[TEXT_OWNER]: ['trim', 'shell_quote', 'percent_encode'],
	[TABLE_OWNER]: [
		'shallow_copy',
		'deep_copy',
		'deep_copy_with_keys',
		'sorted_keys',
		'by_text',
		'count'
	]
};
for (const [owner, names] of Object.entries(OWNER_DEFINITIONS)) {
	const source = fs.readFileSync(path.join(DRIVERS, owner), 'utf8');
	for (const name of names) {
		if (!new RegExp(String.raw`^function M\.${name}\(`, 'm').test(source))
			errors.push(`${owner} no longer defines M.${name}`);
	}
}

if (process.argv.includes('--report')) console.log(JSON.stringify(observed, null, '\t'));

if (errors.length > 0) {
	console.error('Shared Lua helpers redefined inline:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
const debt = Object.values(baseline).reduce(
	(sum, helpers) => sum + Object.values(helpers).reduce((a, b) => a + b, 0),
	0
);
console.log(
	`Shared Lua helpers: ${scanned} sources scanned, ${debt} baselined inline site(s) left.`
);
