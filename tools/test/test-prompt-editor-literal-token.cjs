// tools/test/test-prompt-editor-literal-token.cjs

/** Exercises the actual editor parser and serializer without a native WebView. */
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const script = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/prompt_editor/script.js'
);
const source = fs.readFileSync(script, 'utf8');
const marker = source.indexOf('// ======= 3/ Events Wiring');
assert(marker > 0);
const document = {
	createTextNode: (text) => ({ nodeType: 3, textContent: text }),
	createElement: (tag) => ({
		nodeType: 1,
		tagName: tag.toUpperCase(),
		dataset: {},
		classList: { contains: (name) => name === 'token-chip' && tag === 'span' }
	})
};
const context = vm.createContext({ document });
vm.runInContext(source.slice(0, marker), context);
const original = 'Explain {Enter} literally, then use {context}.';
const nodes = context.parseToNodes(original);
assert.strictEqual(context.serializeEditor({ childNodes: nodes }), original);
context.editorElement = { childNodes: context.parseToNodes('First\n' + original) };
context.document.getElementById = (id) => ({ value: id === 'p-name' ? 'Profile' : 'single' });
context.activePromptContext = { edit_id: 'edit-1', epoch: 2 };
context.post = (message) => {
	context.message = message;
};
const saveStart = source.indexOf('function doSave()');
const saveEnd = source.indexOf('// Global hotkey for cancellation', saveStart);
assert(saveStart > 0 && saveEnd > saveStart);
vm.runInContext(source.slice(saveStart, saveEnd), context);
context.doSave();
assert.strictEqual(context.message.prompt, 'First\n' + original);
assert.strictEqual(context.message.edit_id, 'edit-1');
console.log('prompt editor preserves literal brace text');
