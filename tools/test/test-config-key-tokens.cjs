// tools/test/test-config-key-tokens.cjs

/**
 * ==============================================================================
 * MODULE: Config-Key Constant Tokens
 * DESCRIPTION:
 * Source-shape gates pin the string a Lua call passes. When the call names the
 * generated constant instead, the shared tokenizer (tools/lib/script-source.cjs)
 * must read it as the same string, and must still refuse a constant that does
 * not exist or that stands for another key.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { scriptTokens } = require('../lib/script-source.cjs');
const { collapseConfigKeys, expandConfigKeys } = require('../lib/config-key-tokens.cjs');

/** The string values and identifier values of a Lua snippet, in order. */
function shape(source) {
	return collapseConfigKeys(scriptTokens(source, '.lua')).map(
		(token) => `${token.kind[0]}:${token.value}`
	);
}

const literal = shape('x = Manifest.default_for("llm.enabled")');

// 1. The full reference reads as the literal it generates.
assert.deepEqual(
	shape('x = Manifest.default_for(ConfigKeys.KEY.LLM_ENABLED)'),
	literal,
	'ConfigKeys.KEY.LLM_ENABLED is the literal "llm.enabled"'
);

// 2. A module alias reads the same; a bare table alias stays identifiers, because gates
//    already pin that spelling as it is.
assert.deepEqual(
	shape('local CK = require("config_keys")\nx = Manifest.default_for(CK.KEY.LLM_ENABLED)').slice(
		-literal.length
	),
	literal
);
assert.ok(
	shape('local KEY = ConfigKeys.KEY\nx = Manifest.default_for(KEY.LLM_ENABLED)').includes('i:KEY'),
	'a table alias is not rewritten'
);
assert.ok(
	shape('local COMMAND = require("config_keys").COMMAND\nx = f[COMMAND.SCOPE_RESTORE]').includes(
		'i:COMMAND'
	)
);

// 2b. A direct require of the module reads the same, for files with no local to spare.
assert.deepEqual(
	shape('x = Manifest.default_for(require("config_keys").KEY.LLM_ENABLED)'),
	literal
);
assert.ok(
	shape('x = f(require("config_keys").KEY.LLM_ENABLE)').includes('i:LLM_ENABLE'),
	'a wrong name through a direct require is refused'
);

// 3. LEAF and COMMAND tables resolve to their own strings.
assert.deepEqual(
	shape('x = S.get(ConfigKeys.LEAF.PRIVATE_FILTER_ENABLED)'),
	shape('x = S.get("private_filter_enabled")')
);
assert.deepEqual(shape('x = C[ConfigKeys.COMMAND.SCOPE_RESTORE]'), shape('x = C["scope_restore"]'));

// 4. A wrong constant name is refused: it stays identifier tokens no literal pin matches.
assert.notDeepEqual(shape('x = Manifest.default_for(ConfigKeys.KEY.LLM_ENABLE)'), literal);
assert.ok(
	shape('x = Manifest.default_for(ConfigKeys.KEY.LLM_ENABLE)').includes('i:LLM_ENABLE'),
	'an unknown name is left as identifiers'
);

// 5. A constant that stands for another key is refused: it reads as that key's string.
assert.notDeepEqual(shape('x = Manifest.default_for(ConfigKeys.KEY.LLM_MODELS)'), literal);
assert.ok(shape('x = Manifest.default_for(ConfigKeys.KEY.LLM_MODELS)').includes('s:llm.models'));

// 6. A table alias that was never declared, and a field access, are ordinary code.
assert.ok(shape('x = f(KEY.LLM_ENABLED)').includes('i:KEY'));
assert.ok(shape('x = f(obj.KEY.LLM_ENABLED)').includes('i:KEY'));
assert.ok(shape('x = f(M.ConfigKeys.KEY.LLM_ENABLED)').includes('i:ConfigKeys'));

// 7. The collapsed token keeps the span of the reference, so a gate slicing the source
//    by offset still gets the original text.
{
	const source = 'x = f(ConfigKeys.KEY.LLM_ENABLED)';
	const token = collapseConfigKeys(scriptTokens(source, '.lua')).find((t) => t.kind === 'string');
	assert.equal(source.slice(token.start, token.end), 'ConfigKeys.KEY.LLM_ENABLED');
}

// 7b. Text-level expansion for regular-expression gates: only resolvable references change.
assert.equal(
	expandConfigKeys(
		'local S = ConfigKeys.KEY.SHORTCUTS_KEYBOARD -- ConfigKeys.KEY.NOPE\nf("llm.enabled", ConfigKeys.KEY.NOPE)'
	),
	'local S = "shortcuts.keyboard" -- ConfigKeys.KEY.NOPE\nf("llm.enabled", ConfigKeys.KEY.NOPE)'
);

// 8. The source view returns expanded text for a driver Lua file and leaves other files alone.
{
	const fs = require('node:fs');
	const path = require('node:path');
	const root = path.resolve(__dirname, '..', '..');
	const raw = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/ui/menu/shortcuts_scope.lua'),
		'utf8'
	);
	assert.ok(
		/(ConfigKeys|require\("config_keys"\))\.(KEY|LEAF|COMMAND)\./.test(raw),
		'the probe file names constants'
	);
	require('../lib/config-key-source-view.cjs').install();
	const viewed = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/macos/ui/menu/shortcuts_scope.lua'),
		'utf8'
	);
	assert.ok(
		!/(ConfigKeys|require\("config_keys"\))\.(KEY|LEAF|COMMAND)\./.test(viewed),
		'the view resolves them'
	);
	const json = fs.readFileSync(path.join(root, 'package.json'), 'utf8');
	assert.ok(json.includes('"scripts"'), 'other files are returned untouched');
}

console.log(
	'[OK] generated config-key constants read as their literals, and wrong ones are refused.'
);
