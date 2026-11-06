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
		classList: { contains: () => false }
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
for (const text of ['message{Enter}', 'message{Enter}{Enter}', '{Enter}']) {
	const nodes = context.parseToNodes(text);
	assert.equal(
		context.serializeEditor({ childNodes: nodes }),
		text,
		'opening and saving must preserve trailing Enter'
	);
}
const placeholder = document.createElement('br');
assert.equal(
	context.serializeEditor({ childNodes: [placeholder] }),
	'',
	'browser placeholder is not an Enter command'
);
const nodes = context.parseToNodes('message{Enter}');
nodes.push(placeholder);
assert.equal(
	context.serializeEditor({ childNodes: nodes }),
	'message{Enter}',
	'placeholder after an Enter must not consume the command'
);
console.log('hotstring editor preserves intentional trailing Enter commands');
