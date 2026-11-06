// tools/test/test-metrics-app-fallback-icon-unicode.cjs

/** Renders the actual app selector with native-icon fallback names. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const list = { innerHTML: '' };
const search = { value: '' };
const context = vm.createContext({
	ThemeTokens: { color: () => '#000' },
	document: {
		addEventListener() {},
		getElementById: (id) => ({ app_search: search, app_list: list })[id]
	},
	window: {},
	app_state: {
		available_apps: ['😀 Writer', 'e\u0301diteur', '🇫🇷 Notes'],
		selected_apps: new Set()
	},
	escape_html: (text) =>
		text.replace(
			/[&<>"']/g,
			(ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]
		),
	_t: (key) => key
});
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/metrics_typing/modal.js'),
		'utf8'
	),
	context
);
context.render_app_list();
assert.ok(
	list.innerHTML.includes('>😀</div>'),
	'emoji fallback must not split the UTF-16 surrogate pair'
);
assert.ok(
	list.innerHTML.includes('>É</div>'),
	'a decomposed accented initial must remain accented'
);
assert.ok(list.innerHTML.includes('>🇫🇷</div>'), 'a flag must remain one complete grapheme');
const fallbackList = { innerHTML: '' };
const legacy = vm.createContext({
	ThemeTokens: { color: () => '#000' },
	Intl: {},
	document: {
		addEventListener() {},
		getElementById: (id) => ({ app_search: search, app_list: fallbackList })[id]
	},
	window: {},
	app_state: { available_apps: ['😀 Writer', 'e\u0301diteur'], selected_apps: new Set() },
	escape_html: context.escape_html,
	_t: (key) => key
});
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/metrics_typing/modal.js'),
		'utf8'
	),
	legacy
);
legacy.render_app_list();
assert.ok(
	fallbackList.innerHTML.includes('>😀</div>'),
	'older WebKit must preserve full code points'
);
assert.ok(
	fallbackList.innerHTML.includes('>É</div>'),
	'older WebKit must preserve composed accents'
);
console.log('application fallback badges preserve Unicode initials');
