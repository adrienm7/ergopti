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
const mixedCase = 'Explain {CONTEXT} and {Language} exactly.';
context.editorElement = { childNodes: context.parseToNodes(mixedCase) };
context.doSave();
assert.strictEqual(
	context.message.prompt,
	mixedCase,
	'editing must preserve the case of literal prompt text'
);
const typedNode = { nodeType: 3, textContent: '{CONTEXT}' };
let inserted;
const range = {
	collapsed: true,
	startContainer: typedNode,
	startOffset: 9,
	insertNode: (node) => {
		inserted = node;
	}
};
const selection = { rangeCount: 1, getRangeAt: () => range, removeAllRanges() {}, addRange() {} };
context.window = { getSelection: () => selection };
context.document.createRange = () => ({
	setStart() {},
	setEnd() {},
	deleteContents() {},
	setStartAfter() {},
	collapse() {}
});
context.checkPlaceholder = () => {};
context.tryConvertToken({});
assert.strictEqual(inserted.dataset.token, 'CONTEXT', 'typing must preserve token case as well');
context.editorElement = { childNodes: context.parseToNodes('  Prefix {context}\n\n') };
context.doSave();
assert.strictEqual(
	context.message.prompt,
	'  Prefix {context}\n\n',
	'intentional whitespace must survive save'
);
const initStart = source.indexOf('var activePromptContext =');
const initEnd = source.indexOf('var post = makeHostBridge', initStart);
assert(initStart > 0 && initEnd > initStart);
const fields = { title: {}, 'p-name': {}, 'p-mode': {} };
context.document.getElementById = (id) => fields[id];
context.editorElement = {
	childNodes: [],
	set innerHTML(_) {
		this.childNodes = [];
	},
	appendChild(node) {
		this.childNodes.push(node);
	}
};
context.checkPlaceholder = () => {};
context.setTimeout = () => {};
vm.runInContext(source.slice(initStart, initEnd), context);
const data = {
	edit_id: 'context-a',
	epoch: 1,
	title: 'Title',
	name: 'Name',
	mode: 'single',
	prompt: 'original'
};
context.init(data);
context.editorElement.childNodes[0].textContent = 'unsaved draft';
context.init(data);
assert.strictEqual(
	context.serializeEditor(context.editorElement),
	'unsaved draft',
	'duplicate init must not erase a draft'
);
context.init({ ...data, edit_id: 'context-b', epoch: 2, prompt: 'next profile' });
assert.strictEqual(
	context.serializeEditor(context.editorElement),
	'next profile',
	'new context must still initialize'
);
console.log('prompt editor preserves literal brace text');
