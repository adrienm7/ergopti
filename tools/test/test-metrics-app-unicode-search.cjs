'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const search = { value: 'ÉDITEUR' };
const list = { innerHTML: '' };
const context = vm.createContext({
	ThemeTokens: { color: () => '#000' },
	document: {
		addEventListener() {},
		getElementById: (id) => ({ app_search: search, app_list: list })[id]
	},
	window: {},
	app_state: { available_apps: ['E\u0301diteur'], selected_apps: new Set() },
	escape_html: (value) => value,
	_t: (key) => key
});
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/metrics_typing/modal.js'),
		'utf8'
	),
	context
);
vm.runInContext('render_app_list()', context);
assert.ok(
	list.innerHTML.includes('E\u0301diteur'),
	'a composed search must match a decomposed application name'
);
search.value = 'e\u0301diteur';
context.app_state.available_apps = ['Éditeur'];
vm.runInContext('render_app_list()', context);
assert.ok(
	list.innerHTML.includes('Éditeur'),
	'a decomposed search must match a composed application name'
);
search.value = 'editeur';
vm.runInContext('render_app_list()', context);
assert.ok(!list.innerHTML.includes('Éditeur'), 'normalization must not remove accents');
console.log('Unicode-equivalent app names remain searchable');
