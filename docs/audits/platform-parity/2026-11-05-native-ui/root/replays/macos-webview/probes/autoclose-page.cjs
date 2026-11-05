'use strict';
const fs = require('fs'),
	vm = require('vm'),
	path = require('path'),
	assert = require('assert');
const [root, seedFile, outputFile] = process.argv.slice(2);
assert(root && seedFile && outputFile);
const seed = JSON.parse(fs.readFileSync(seedFile, 'utf8'));
const elements = new Map(),
	messages = [],
	timers = [];
function element(id = '') {
	const classes = new Set();
	return {
		id,
		value: '',
		checked: false,
		style: {},
		dataset: {},
		childNodes: [],
		textContent: '',
		classList: {
			add(...xs) {
				xs.forEach((x) => classes.add(x));
			},
			remove(...xs) {
				xs.forEach((x) => classes.delete(x));
			},
			contains(x) {
				return classes.has(x);
			},
			toggle(x, on) {
				on ? classes.add(x) : classes.delete(x);
			}
		},
		addEventListener() {},
		focus() {},
		appendChild(n) {
			this.childNodes.push(n);
			return n;
		},
		querySelectorAll() {
			return [];
		},
		contains() {
			return false;
		}
	};
}
const document = {
	readyState: 'loading',
	getElementById(id) {
		if (!elements.has(id)) elements.set(id, element(id));
		return elements.get(id);
	},
	querySelectorAll() {
		return [];
	},
	addEventListener() {},
	createTextNode(text) {
		return { nodeType: 3, textContent: text };
	},
	createElement(tag) {
		const e = element();
		e.nodeType = 1;
		e.tagName = tag.toUpperCase();
		return e;
	}
};
const c = vm.createContext({
	console,
	document,
	makeHostBridge: (name) => {
		assert.equal(name, 'hsEditor');
		return (body) => messages.push(JSON.parse(JSON.stringify(body)));
	},
	setTimeout: (fn) => {
		timers.push(fn);
		return timers.length;
	},
	clearTimeout() {},
	addEventListener() {},
	__seed: seed
});
c.window = c;
for (const rel of ['ui/dom_utils.js', 'ui/hotstring_editor/script.js']) {
	const f = path.join(root, 'static/ergopti_plus/_shared', rel);
	vm.runInContext(fs.readFileSync(f, 'utf8'), c, { filename: f });
}
vm.runInContext('window.initData(__seed);showAddEntry(0);', c);
document.getElementById('e-trig').childNodes = [document.createTextNode('draft_trigger_20261105')];
document.getElementById('e-out').childNodes = [
	document.createTextNode('UNSAVED_DRAFT_MVB002_20261105')
];
vm.runInContext(
	'saveEntry(false);__draft=D.sections[0].entries.find(e=>e.trigger==="draft_trigger_20261105");',
	c
);
assert(c.__draft && c.__draft.output === 'UNSAVED_DRAFT_MVB002_20261105');
assert.equal(messages[0].action, 'save');
assert.deepEqual(
	messages.map((x) => x.action),
	seed.open_mode === 'shortcut' && seed.auto_close ? ['save', 'close'] : ['save']
);
fs.writeFileSync(
	outputFile,
	JSON.stringify(
		{
			host_seed_mode: seed.open_mode,
			host_seed_auto_close: seed.auto_close,
			messages,
			page_draft_present_before_native_delete: true,
			save_toast_shown: document.getElementById('save-toast').classList.contains('show')
		},
		null,
		2
	) + '\n'
);
