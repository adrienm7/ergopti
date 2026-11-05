'use strict';
const fs = require('node:fs'),
	path = require('node:path'),
	vm = require('node:vm'),
	assert = require('node:assert/strict');
const root = path.resolve(process.argv[2] || process.env.SOURCE_ROOT || '.');
const source = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/_shared/ui/hotstrings_config_window/script.js'),
	'utf8'
);
let posts = [];
const ctx = vm.createContext({
	makeHostBridge: () => (p) => posts.push(p),
	document: {
		addEventListener() {},
		getElementById() {
			return null;
		}
	},
	window: {}
});
vm.runInContext(source, ctx);
function control() {
	return {
		value: '',
		listeners: {},
		addEventListener(k, f) {
			this.listeners[k] = f;
		}
	};
}
function run(ms, section) {
	posts = [];
	const input = control(),
		reset = control(),
		field = { querySelector: (q) => (q === 'input' ? input : reset), classList: { toggle() {} } };
	const cat = {
		name: 'punctuation',
		group: 'common',
		delay_ms: ms,
		delay_default_ms: 750,
		delay_overridden: true
	};
	ctx.field = field;
	ctx.cat = cat;
	ctx.sec = section
		? { name: 'test', delay_ms: ms, delay_default_ms: 750, delay_overridden: true }
		: null;
	vm.runInContext('state={global_default_delay_ms:750};bindDelay(field,cat,sec)', ctx);
	input.listeners.change();
	return { requested: ms, section, displayed: input.value, posted: posts[0] };
}
const results = [run(0, false), run(0, true), run(25, false), run(750, false)];
assert.equal(results[0].displayed, 750);
assert.equal(results[0].posted.ms, 750);
assert.equal(results[1].displayed, 750);
assert.equal(results[1].posted.ms, 750);
assert.equal(results[2].displayed, 25);
assert.equal(results[2].posted.ms, 25);
assert.equal(results[3].displayed, 750);
console.log(
	JSON.stringify(
		{
			sourceRoot: root,
			provenance:
				'full actual shared JS in VM, real bindDelay and change callback; fake DOM/bridge ports only',
			results
		},
		null,
		2
	)
);
