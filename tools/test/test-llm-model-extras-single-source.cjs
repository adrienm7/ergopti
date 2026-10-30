// tools/test/test-llm-model-extras-single-source.cjs

/**
 * ==============================================================================
 * MODULE: API Model-Extras And Thinking-Off Single-Source Guard
 * DESCRIPTION:
 * Per-model body fields live in exactly ONE place —
 * _shared/modules/llm/api_providers.json: providers.<id>.model_extras, and
 * providers.<id>.thinking_dialect, how each provider carries the reasoning
 * controls of the model families of thinking_off.json (e.g.
 * reasoning_effort:none for the qwen3 family, which covers Cerebras'
 * qwen-3.8-27b: it otherwise reasons at xhigh effort by default and stalls
 * tiny probes). Every driver merges them generically from data; none may
 * restate a field name in shipped code, or a tuning fix on one driver
 * silently stops applying to the others.
 *
 * ROOT CAUSE ENCODED:
 * A provider quirk fixed with a literal in one payload builder (say AHK)
 * stays broken in the twin (Hammerspoon) with no failure anywhere — the
 * request still goes out, the model just never answers in time. This guard
 * fails if a model_extras or thinking_off field name appears in shipped
 * driver sources, if a payload builder stops consuming model_extras or
 * thinking_off, or if either JSON
 * section is malformed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SSOT_FILE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'llm',
	'api_providers.json'
);

// Shipped driver sources that must consume model_extras and thinking_off
// generically. Test files are excluded: asserting merged output legitimately
// names fields.
const SHIPPED = [
	'static/ergopti_plus/windows/modules/llm/api_remote.ahk',
	'static/ergopti_plus/macos/modules/llm/api_remote.lua',
	'static/ergopti_plus/linux/modules/llm/api_remote.lua'
];

// Other shipped sources that build or complete request bodies: they may not
// restate a rule field either.
const BODY_SOURCES = [
	'static/ergopti_plus/_shared/lua/llm/thinking_off.lua',
	'static/ergopti_plus/_shared/modules/llm/thinking_off.ahk',
	'static/ergopti_plus/_shared/lua/llm/vision.lua',
	'static/ergopti_plus/windows/modules/llm/vision.ahk',
	'static/ergopti_plus/windows/modules/llm/vision_action.ahk',
	'static/ergopti_plus/windows/modules/llm/agent_action.ahk',
	'static/ergopti_plus/linux/modules/llm/vision_request.lua'
];

// Nested thinking_dialect names too generic to be a restated rule (an object's
// "type"), and the Gemini envelope every Gemini body builder owns.
const GENERIC_FIELDS = new Set(['type', 'effort', 'enabled', 'generationConfig']);

// The reasoning control kinds of thinking_off.json.
const KINDS = new Set([
	'toggle',
	'effort',
	'anthropic_thinking',
	'anthropic_effort',
	'gemini_budget',
	'gemini_level'
]);

// The glob alphabet both resolvers accept, `*` being the only wildcard.
const GLOB = /^[A-Za-z0-9._:/@+*-]+$/;
const FIELD = /^[A-Za-z_][A-Za-z0-9_]*$/;

let failed = false;
const fail = (msg) => {
	console.error(`\x1b[31m[ERROR] ${msg}\x1b[0m`);
	failed = true;
};

let root;
try {
	root = JSON.parse(fs.readFileSync(SSOT_FILE, 'utf8'));
} catch (err) {
	fail(`could not read api_providers.json: ${err.message}`);
}

const fieldNames = new Set();
const ruleFieldNames = new Set();

// Validates a thinking_dialect fields template and records its names at every depth.
function checkRuleFields(where, fields, allowEmpty) {
	if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
		fail(`${where} must be an object.`);
		return;
	}
	if (!allowEmpty && Object.keys(fields).length === 0) fail(`${where} must not be empty.`);
	for (const [name, value] of Object.entries(fields)) {
		if (!FIELD.test(name)) fail(`${where} has an unshippable field name: ${name}.`);
		if (!GENERIC_FIELDS.has(name)) ruleFieldNames.add(name);
		if (value && typeof value === 'object') checkRuleFields(`${where}.${name}`, value, false);
		else if (!['string', 'number', 'boolean'].includes(typeof value)) {
			fail(`${where}.${name} must be a string, number, boolean or object.`);
		}
	}
}

if (root && typeof root === 'object') {
	const providers = root.providers;
	if (!providers || typeof providers !== 'object') {
		fail('api_providers.json has no providers object.');
	} else {
		for (const [pid, desc] of Object.entries(providers)) {
			if (!desc || typeof desc !== 'object') continue;
			const extras = desc.model_extras;
			const dialect = desc.thinking_dialect;
			if (dialect !== undefined) {
				if (!dialect || typeof dialect !== 'object' || Array.isArray(dialect)) {
					fail(`providers.${pid}.thinking_dialect must be an object.`);
				}
				for (const [kind, fields] of Object.entries(dialect || {})) {
					if (kind.startsWith('_')) continue;
					if (!KINDS.has(kind))
						fail(`providers.${pid}.thinking_dialect has an unknown kind ${kind}.`);
					checkRuleFields(`providers.${pid}.thinking_dialect.${kind}`, fields, false);
				}
			}
			if (extras === undefined) continue;
			if (!extras || typeof extras !== 'object' || Array.isArray(extras)) {
				fail(`providers.${pid}.model_extras must be an object.`);
				continue;
			}
			for (const [model, fields] of Object.entries(extras)) {
				if (model.startsWith('_')) continue;
				if (typeof model !== 'string' || model === '') {
					fail(`providers.${pid}.model_extras has an invalid model key.`);
					continue;
				}
				if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
					fail(`providers.${pid}.model_extras.${model} must be an object.`);
					continue;
				}
				for (const [field, value] of Object.entries(fields)) {
					if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(field)) {
						fail(`providers.${pid}.model_extras.${model} has an unshippable field name: ${field}.`);
						continue;
					}
					if (typeof value !== 'string' && typeof value !== 'number') {
						fail(`providers.${pid}.model_extras.${model}.${field} must be a string or number.`);
						continue;
					}
					fieldNames.add(field);
				}
			}
		}
	}
}

function stripLineComments(src, isAhk) {
	return src
		.split('\n')
		.map((line) => (isAhk ? line.replace(/(^|\s);.*$/, '$1') : line.split('--')[0]))
		.join('\n');
}

// A rule field restated as a body field: a Lua key (`name =`, `.name`,
// `["name"]`) or a quoted name followed by `:` or `,` (JSON text, Map()).
function restatesField(code, name) {
	const quoted = `["']${name}["']\\s*[:,\\]]`;
	const bare = `(^|[^A-Za-z0-9_.])${name}\\s*=[^=]|\\.${name}(?![A-Za-z0-9_])`;
	return new RegExp(`${quoted}|${bare}`).test(code);
}

for (const rel of BODY_SOURCES.concat(SHIPPED)) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		fail(`shipped file missing: ${rel}.`);
		continue;
	}
	const code = stripLineComments(fs.readFileSync(abs, 'utf8'), rel.endsWith('.ahk'));
	for (const name of ruleFieldNames) {
		if (restatesField(code, name)) {
			fail(
				`${rel} restates the shared thinking_dialect field '${name}' (keep it in api_providers.json only).`
			);
		}
	}
}

for (const rel of SHIPPED) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) continue;
	const src = fs.readFileSync(abs, 'utf8');
	const code = stripLineComments(src, rel.endsWith('.ahk'));
	for (const field of fieldNames) {
		if (code.includes(field)) {
			fail(
				`${rel} restates the shared model_extras field '${field}' (keep it in api_providers.json only).`
			);
		}
	}
	if (!src.includes('model_extras')) {
		fail(`${rel} no longer consumes model_extras — generic merge deleted?`);
	}
	if (!/ThinkingOff/.test(code)) {
		fail(`${rel} no longer applies thinking_off — reasoning would stay on.`);
	}
}

if (ruleFieldNames.size === 0) fail('api_providers.json holds no thinking_dialect field.');

// The model families: one home for what each family needs.
const FAMILIES_FILE = path.join(path.dirname(SSOT_FILE), 'thinking_off.json');
let familiesRoot = null;
try {
	familiesRoot = JSON.parse(fs.readFileSync(FAMILIES_FILE, 'utf8'));
} catch (err) {
	fail(`could not read thinking_off.json: ${err.message}`);
}
const families = familiesRoot && Array.isArray(familiesRoot.families) ? familiesRoot.families : [];
if (familiesRoot && families.length === 0) fail('thinking_off.json holds no families.');
for (const [index, family] of families.entries()) {
	const where = `thinking_off.json families[${index}]`;
	if (!Array.isArray(family.models) || family.models.length === 0) fail(`${where} names no model.`);
	for (const glob of family.models || [])
		if (typeof glob !== 'string' || !GLOB.test(glob)) fail(`${where} has an invalid glob.`);
	if (!Array.isArray(family.controls)) fail(`${where} has no controls array.`);
	for (const control of family.controls || []) {
		if (!KINDS.has(control.kind)) fail(`${where} has an unknown kind ${control.kind}.`);
	}
}

// Every Ollama chat body the drivers write sends think, resolved from the
// model family (thinking_off.json ollama_think): false turns a hybrid model's
// reasoning off, but gpt-oss ignores it and needs its lowest level, so a
// literal false would leave it reasoning through a warmup's single token or a
// screenshot's transcription. A body is found by keep_alive or num_predict:
// in Lua, a table literal holding messages (an options table counts for its
// parent); in AHK, JSON text built in one function. The think it sends must
// be an expression, never a literal, and its file must reach the resolver.
const OLLAMA_ROOTS = [
	'static/ergopti_plus/macos/modules',
	'static/ergopti_plus/macos/ui',
	'static/ergopti_plus/linux/modules',
	'static/ergopti_plus/linux/infra',
	'static/ergopti_plus/_shared/lua/llm',
	'static/ergopti_plus/windows/modules/llm'
];

function sourceFiles(dir) {
	const out = [];
	for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
		const rel = `${dir}/${entry.name}`;
		if (entry.isDirectory()) out.push(...sourceFiles(rel));
		else if (/\.(lua|ahk)$/.test(entry.name)) out.push(rel);
	}
	return out;
}

// The table literal around a position: from its unmatched { to the matching }.
function enclosingTable(code, at) {
	let depth = 0;
	let start = at;
	while (start > 0) {
		start -= 1;
		if (code[start] === '}') depth += 1;
		else if (code[start] === '{') {
			if (depth === 0) break;
			depth -= 1;
		}
	}
	let end = start;
	depth = 0;
	for (; end < code.length; end += 1) {
		if (code[end] === '{') depth += 1;
		else if (code[end] === '}' && --depth === 0) break;
	}
	return code.slice(start, end + 1);
}

// A Lua table literal starting at a position whose key is options.
function isOptionsTable(code, start) {
	return /(^|[^A-Za-z0-9_.])options\s*=\s*$/.test(code.slice(Math.max(0, start - 40), start));
}

// A Lua body table around an anchor: an options table stands for its parent.
function luaBody(code, at) {
	let table = enclosingTable(code, at);
	const start = code.lastIndexOf(table, at);
	if (isOptionsTable(code, start)) table = enclosingTable(code, start);
	return table;
}

const RESOLVER = /ollama_think|OllamaThink|spec\.think|Spec\.Get\("think"/;
const LUA_LITERAL_THINK = /(^|[^A-Za-z0-9_])think\s*=\s*(false|true)\b/;
const AHK_LITERAL_THINK = /"think":\s*(false|true)/;
const LUA_RESOLVED_THINK = /(^|[^A-Za-z0-9_.])think\s*=\s*(?!(false|true)\b)[A-Za-z_]/;
const AHK_RESOLVED_THINK = /"think":'\s*(\.\s*)?[A-Za-z_]/;

let ollamaBodies = 0;
for (const rel of OLLAMA_ROOTS.flatMap(sourceFiles)) {
	const isAhk = rel.endsWith('.ahk');
	const code = stripLineComments(fs.readFileSync(path.join(ROOT, rel), 'utf8'), isAhk);
	const lineOf = (index) => code.slice(0, index).split('\n').length;
	const literal = (isAhk ? AHK_LITERAL_THINK : LUA_LITERAL_THINK).exec(code);
	if (literal) {
		fail(
			`${rel}:${lineOf(literal.index)} sends a literal think: resolve it (thinking_off ollama_think).`
		);
	}
	const anchor = isAhk
		? /"(keep_alive|num_predict)":['"]/g
		: /(^|[^A-Za-z0-9_.])(keep_alive|num_predict)\s*=[^=]/g;
	const seen = new Set();
	for (const match of code.matchAll(anchor)) {
		const body = isAhk
			? code.slice(code.lastIndexOf('\n}', match.index) + 1, code.indexOf('\n}', match.index))
			: luaBody(code, match.index);
		if (!isAhk && !/(^|[^A-Za-z0-9_.])messages\s*=/.test(body)) continue;
		if (seen.has(body)) continue;
		seen.add(body);
		ollamaBodies += 1;
		if (!(isAhk ? AHK_RESOLVED_THINK : LUA_RESOLVED_THINK).test(body)) {
			fail(`${rel}:${lineOf(match.index)} writes an Ollama chat body without its resolved think.`);
		} else if (!RESOLVER.test(code)) {
			fail(`${rel} sends an Ollama think that does not come from thinking_off ollama_think.`);
		}
	}
}
if (ollamaBodies < 9)
	fail(`found only ${ollamaBodies} Ollama chat bodies: the scan lost its anchor.`);

if (failed) process.exit(1);
console.log(
	'\x1b[32m[OK] API model extras and thinking-off rules are single-sourced (api_providers.json).\x1b[0m'
);
