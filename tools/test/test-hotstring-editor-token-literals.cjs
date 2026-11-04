// tools/test/test-hotstring-editor-token-literals.cjs

/** Exercise the actual hotstring editor parser and serializer with literal brace text. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(
	path.join(__dirname, '../../static/ergopti_plus/_shared/ui/hotstring_editor/script.js'),
	'utf8'
);
const marker = source.indexOf('// ======= 15/ Event Wiring');
assert.ok(marker > 0);
const document = {
	createTextNode: (text) => ({ nodeType: 3, textContent: text }),
	createElement: (tag) => ({
		nodeType: 1,
		tagName: tag.toUpperCase(),
		dataset: {},
		classList: { contains: (name) => tag === 'span' && name === 'token-chip' }
	})
};
const context = vm.createContext({
	document,
	makeHostBridge: () => () => {},
	setTimeout() {},
	clearTimeout() {}
});
context.window = context;
vm.runInContext(source.slice(0, marker), context);
for (const text of ['literal {constructor}', 'literal {foo}', 'literal {__proto__}']) {
	assert.equal(
		context.serializeEditor({ childNodes: context.parseToNodes(text) }),
		text,
		'unknown brace text must round-trip literally'
	);
}
assert.equal(
	context.serializeEditor({ childNodes: context.parseToNodes('{tab}') }),
	'{Tab}',
	'known keys still normalize'
);
console.log('hotstring editor preserves literal brace groups');
