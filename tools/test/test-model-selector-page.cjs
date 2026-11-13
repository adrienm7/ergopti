// tools/test/test-model-selector-page.cjs

/**
 * ==============================================================================
 * MODULE: Model Selector Page Regression
 * DESCRIPTION:
 * Executes the shared model selector page (_shared/ui/model_browser) in a small
 * DOM and drives it as a user would: by backend group, filter, buttons and keys.
 *
 * ROOT CAUSE ENCODED:
 * The maintainer moved the model choice from the tray to this page on
 * 2026-10-27. The page must offer only what works now: a backend the driver
 * reports unavailable is greyed with its reason and nothing in it can be
 * selected; a model that is not installed offers its download, never its
 * activation. Its columns read the catalogue fields the shared projection
 * emits (disk_gb, ram_gb, params_b), which the Windows twin must emit too.
 *
 * model-selector-collapsed-groups: the Ollama group came first and listed
 * every Ollama model, burying MLX and the API (maintainer, 2026-10-28). The
 * page opens on three collapsed headers (local backends by name, a separator,
 * then the API), each with one emoji before its brand, its model count and a
 * chevron; the header of the group holding the active model names it; the
 * header toggles by mouse, Enter or Space (aria-expanded); a filter or a
 * search opens the groups it matches in. Rows sort case-insensitively, API
 * rows by provider then model.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const SP = path.resolve(__dirname, '../../static/ergopti_plus');
const SHARED_UI = path.join(SP, '_shared/ui');

// =========================================
// ======= 1/ Minimal DOM ==================
// =========================================

/** One element of the minimal DOM: the attributes, children and events the page uses. */
class Element {
	constructor(tag, doc) {
		this.tagName = tag.toUpperCase();
		this.ownerDocument = doc;
		this.children = [];
		this.attributes = {};
		this.listeners = {};
		this.innerHTML = '';
		this.className = '';
		this.textContent = '';
		this.hidden = false;
		this.disabled = false;
		this.value = '';
		this.style = {};
		this.parentNode = null;
		const element = this;
		this.classList = {
			toggle(name, on) {
				const set = new Set(element.className.split(/\s+/).filter(Boolean));
				if (on) set.add(name);
				else set.delete(name);
				element.className = [...set].join(' ');
			},
			contains(name) {
				return element.className.split(/\s+/).includes(name);
			}
		};
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}
	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name)
			? this.attributes[name]
			: null;
	}
	appendChild(child) {
		child.parentNode = this;
		this.children.push(child);
		return child;
	}
	removeChild(child) {
		this.children = this.children.filter((c) => c !== child);
		child.parentNode = null;
	}
	addEventListener(type, fn) {
		(this.listeners[type] = this.listeners[type] || []).push(fn);
	}
	dispatch(type) {
		for (const fn of this.listeners[type] || []) fn({ target: this });
	}
	focus() {
		this.ownerDocument.activeElement = this;
		if (this.onfocus) this.onfocus();
	}
	descendants() {
		return this.children.flatMap((c) => [c, ...c.descendants()]);
	}
	querySelectorAll(selector) {
		return this.descendants().filter((el) => matches(el, selector));
	}
}

/** The selectors the page uses: tag, tr[data-key] and th[data-sort]. */
function matches(el, selector) {
	if (selector === 'tbody') return el.tagName === 'TBODY';
	if (selector === 'tr[data-key]')
		return el.tagName === 'TR' && el.getAttribute('data-key') !== null;
	if (selector === 'th[data-sort]') return false;
	if (selector === '[data-nav]') return el.getAttribute('data-nav') !== null;
	return false;
}

function makeDocument() {
	const doc = { readyState: 'complete', activeElement: null };
	const byId = {};
	for (const id of [
		'search',
		'backend-filter',
		'backend-filter-label',
		'count',
		'current',
		'models',
		'head-row',
		'empty',
		'hint',
		'btn-disable',
		'btn-use'
	]) {
		byId[id] = new Element(id === 'models' ? 'table' : 'div', doc);
	}
	doc.getElementById = (id) => byId[id] || null;
	doc.createElement = (tag) => new Element(tag, doc);
	doc.querySelectorAll = (selector) => byId.models.querySelectorAll(selector);
	doc.addEventListener = () => {};
	return { doc, byId };
}

function loadPage(strings) {
	const { doc, byId } = makeDocument();
	const messages = [];
	const window = {
		_i18n_strings: strings,
		webkit: {
			messageHandlers: {
				model_browser_bridge: { postMessage: (m) => messages.push(JSON.parse(JSON.stringify(m))) }
			}
		}
	};
	const context = vm.createContext({ console, window, document: doc });
	vm.runInContext(fs.readFileSync(path.join(SHARED_UI, 'host_bridge.js'), 'utf8'), context);
	vm.runInContext(
		fs.readFileSync(path.join(SHARED_UI, 'model_browser/script.js'), 'utf8'),
		context
	);
	assert.deepEqual(messages.splice(0), ['ready']);
	return { context, byId, messages, doc };
}

// =========================================
// ======= 2/ Fixtures =====================
// =========================================

const en = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/core/i18n/data/locales/en.json'), 'utf8')
);
const brands = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/ai/data/backends.json'), 'utf8')
).backends;

function backend(id, available, reason_key) {
	const b = {
		id,
		brand: brands[id].brand,
		emoji: brands[id].emoji,
		kind: brands[id].kind,
		available
	};
	if (reason_key) b.reason_key = reason_key;
	return b;
}

const payload = {
	backend: 'ollama',
	active: 'Qwen-Installed',
	capabilities: { disable: true },
	backends: [
		{
			...backend('ollama', true),
			add_model: true,
			install: { state: 'installed' }
		},
		{
			...backend('mlx', false, 'model_browser.reason_mlx_intel'),
			install: { state: 'unsupported', reason_key: 'model_browser.reason_mlx_intel' }
		},
		{
			...backend('api', true),
			providers: [
				{ id: 'openai', label: 'OpenAI' },
				{ id: 'groq', label: 'Groq' }
			]
		}
	],
	models: [
		{
			backend: 'ollama',
			name: 'Qwen-Installed',
			installed: true,
			disk_gb: 2.5,
			ram_gb: 3.1,
			params_b: 4
		},
		{
			backend: 'ollama',
			name: 'Llama-Missing',
			installed: false,
			disk_gb: 4.9,
			ram_gb: 6,
			params_b: 8
		},
		{ backend: 'ollama', name: 'my-tag', installed: true, custom: true },
		{
			backend: 'mlx',
			name: 'Mlx-Installed',
			installed: true,
			disk_gb: 1,
			ram_gb: 2,
			params_b: 1.7
		},
		{ backend: 'api', name: 'OpenAI/gpt-4o-mini', installed: true }
	]
};

/** The model rows the page drew, by name. */
function drawnRows(byId) {
	const rows = {};
	for (const tr of byId.models.querySelectorAll('tr[data-key]')) {
		rows[tr.getAttribute('data-key').split('\u0000')[1]] = tr;
	}
	return rows;
}

function button(act) {
	return { closest: () => ({ getAttribute: (name) => (name === 'data-act' ? act : null) }) };
}

/** The group bodies the page drew, the separator included, in order. */
function bodies(p) {
	return p.byId.models.querySelectorAll('tbody');
}

function groupHead(p, id) {
	const body = bodies(p).find((tb) => tb.getAttribute('data-group') === id);
	assert.ok(body, `group ${id} is drawn`);
	return body.children[0];
}

/** A group's toggle: the first child of its header cell, the tools the second. */
function toggleOf(p, id) {
	return groupHead(p, id).children[0].children[0];
}

function rowNames(p) {
	return Object.keys(drawnRows(p.byId));
}

const keyEvent = (key) => ({ key, preventDefault() {} });

// =========================================
// ======= 3/ Collapsed Groups =============
// =========================================

const page = loadPage(en);
page.context.injectModels(payload);

// Order: the local backends by name (MLX, Ollama), a separator, then the API.
assert.deepEqual(
	bodies(page).map((tb) => tb.getAttribute('data-group') || tb.className),
	['mlx', 'ollama', 'group-separator', 'api'],
	'local groups alphabetically, then a separator, then the API'
);
// Three header rows and no model row until the user opens a group.
assert.deepEqual(rowNames(page), [], 'every group opens collapsed');
for (const id of ['mlx', 'ollama', 'api']) {
	const toggle = toggleOf(page, id);
	assert.equal(toggle.getAttribute('role'), 'button');
	assert.equal(toggle.getAttribute('tabindex'), '0', `${id} header is focusable`);
	assert.equal(toggle.getAttribute('aria-expanded'), 'false', `${id} starts collapsed`);
	assert.ok(toggle.innerHTML.includes('class="chevron"'), `${id} header has a chevron`);
	// model-selector-single-emoji: the emoji once, before the brand.
	const title = toggle.innerHTML.match(/<span class="group-title">([^<]*)<\/span>/)[1];
	assert.ok(title.startsWith(`${brands[id].emoji} ${brands[id].brand}`), `${id} title: ${title}`);
	assert.equal(title.split(brands[id].emoji).length - 1, 1, `${id} title has one emoji`);
}
const countText = (n, total) =>
	en['model_browser.count_label'].replace('{n}', n).replace('{total}', total);
assert.ok(
	toggleOf(page, 'ollama').innerHTML.includes(countText(3, 3)),
	'the header counts its models'
);
assert.ok(toggleOf(page, 'api').innerHTML.includes(countText(1, 1)));
// The collapsed group of the active model names it on its header.
const activeHint = en['model_browser.current_label'].replace('{model}', 'Qwen-Installed');
assert.ok(
	toggleOf(page, 'ollama').innerHTML.includes(activeHint),
	'the active model shows collapsed'
);
assert.ok(!toggleOf(page, 'mlx').innerHTML.includes('group-active'));
assert.ok(!toggleOf(page, 'api').innerHTML.includes('group-active'));
// A brand that carries its emoji would read "🦙 Ollama 🦙": the page refuses it.
assert.throws(
	() =>
		page.context.injectModels({
			...payload,
			backends: [{ ...payload.backends[0], brand: `${brands.ollama.brand} ${brands.ollama.emoji}` }]
		}),
	/must not carry its emoji/
);
page.context.injectModels(payload);
// The backend filter lists the same order, the API after its own separator.
const filterHtml = page.byId['backend-filter'].innerHTML;
const filterOrder = [...filterHtml.matchAll(/<option value="([^"]*)"/g)].map((m) => m[1]);
assert.deepEqual(filterOrder, ['', 'mlx', 'ollama', 'api']);
assert.ok(
	filterHtml.indexOf(`<optgroup label="${en['model_browser.kind_remote']}">`) <
		filterHtml.indexOf('value="api"') &&
		filterHtml.indexOf('value="ollama"') <
			filterHtml.indexOf(`<optgroup label="${en['model_browser.kind_remote']}">`),
	'a separator stands before the API option'
);
for (const [, label] of filterHtml.matchAll(/<option value="[^"]+"[^>]*>([^<]*)</g)) {
	const id = Object.keys(brands).find((k) => label.endsWith(brands[k].brand));
	assert.equal(label, `${brands[id].emoji} ${brands[id].brand}`, 'one emoji, before the brand');
}

// Mouse: a click opens the group, hides the active hint, keeps the focus.
toggleOf(page, 'ollama').onclick();
assert.equal(toggleOf(page, 'ollama').getAttribute('aria-expanded'), 'true');
assert.ok(groupHead(page, 'ollama').className.includes('expanded'));
assert.deepEqual(
	rowNames(page),
	['Llama-Missing', 'my-tag', 'Qwen-Installed'],
	'rows sort by name, case-insensitive'
);
assert.ok(!toggleOf(page, 'ollama').innerHTML.includes('group-active'));
assert.equal(page.doc.activeElement, toggleOf(page, 'ollama'), 'the toggle keeps the focus');
// Keyboard: Enter opens, Space closes, another key does nothing.
toggleOf(page, 'mlx').onkeydown(keyEvent('Enter'));
assert.equal(toggleOf(page, 'mlx').getAttribute('aria-expanded'), 'true');
assert.ok(rowNames(page).includes('Mlx-Installed'));
toggleOf(page, 'mlx').onkeydown(keyEvent(' '));
assert.equal(toggleOf(page, 'mlx').getAttribute('aria-expanded'), 'false');
toggleOf(page, 'mlx').onkeydown(keyEvent('a'));
assert.equal(toggleOf(page, 'mlx').getAttribute('aria-expanded'), 'false');
// model-selector-whole-header: the whole header toggles, its lower lines
// included (a click there used to do nothing); a real control keeps its click.
// The selector is the page's own, read against a browser's closest().
const controlClick = { closest: (selector) => (selector.includes('button') ? {} : null) };
const headCell = (id) => groupHead(page, id).children[0];
assert.equal(typeof headCell('api').onclick, 'function');
headCell('api').onclick({ target: controlClick });
assert.equal(
	toggleOf(page, 'api').getAttribute('aria-expanded'),
	'false',
	'a control keeps its click'
);
headCell('api').onclick({ target: headCell('api').children[1] });
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'true', 'the tools line toggles');
headCell('api').onclick({ target: headCell('api').children[2] });
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'false', 'the add line toggles');
headCell('api').onclick({ target: headCell('api') });
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'true', 'its padding toggles');
// The toggle stops its click: reaching the cell too would toggle it twice.
let stopped = 0;
toggleOf(page, 'api').onclick({ stopPropagation: () => (stopped += 1) });
assert.equal(stopped, 1, 'a click on the toggle does not reach the cell');
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'false');
// The open groups survive a new payload while the page lives.
page.context.injectModels(payload);
assert.equal(toggleOf(page, 'ollama').getAttribute('aria-expanded'), 'true');
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'false');
toggleOf(page, 'ollama').onclick();
assert.deepEqual(rowNames(page), []);

// A search opens the collapsed groups it matches in, and only while it narrows.
page.byId.search.value = 'GPT';
page.byId.search.dispatch('input');
assert.equal(
	toggleOf(page, 'api').getAttribute('aria-expanded'),
	'true',
	'a match opens its group'
);
assert.deepEqual(rowNames(page), ['OpenAI/gpt-4o-mini']);
toggleOf(page, 'api').onclick();
assert.deepEqual(rowNames(page), [], 'the user can close it again');
page.byId.search.value = '';
page.byId.search.dispatch('input');
assert.deepEqual(rowNames(page), [], 'clearing the search restores the collapsed groups');
// The backend filter opens its group the same way.
page.byId['backend-filter'].value = 'mlx';
page.byId['backend-filter'].dispatch('change');
assert.equal(toggleOf(page, 'mlx').getAttribute('aria-expanded'), 'true');
assert.deepEqual(rowNames(page), ['Mlx-Installed']);
page.byId['backend-filter'].value = '';
page.byId['backend-filter'].dispatch('change');
assert.deepEqual(rowNames(page), []);

// API rows sort by provider, then model, case-insensitive.
page.context.injectModels({
	...payload,
	models: [
		{ backend: 'api', name: 'b/z', provider: 'b', model: 'z', installed: true },
		{ backend: 'api', name: 'A-B/x', provider: 'A-B', model: 'x', installed: true },
		{ backend: 'api', name: 'A/y', provider: 'A', model: 'y', installed: true }
	]
});
toggleOf(page, 'api').onclick();
assert.deepEqual(rowNames(page), ['A/y', 'A-B/x', 'b/z'], 'provider first, then model');
toggleOf(page, 'api').onclick();

// The cases below read every row: open the three groups.
page.context.injectModels(payload);
for (const id of ['mlx', 'ollama', 'api']) toggleOf(page, id).onclick();

// =========================================
// ======= 4/ Behaviour ====================
// =========================================

const rows = drawnRows(page.byId);

// Columns: one header per declared column, translated, in the declared order.
const headers = [...page.byId['head-row'].innerHTML.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(
	(m) => m[1]
);
assert.deepEqual(
	headers,
	[...page.context.COLUMNS].map((c) => en[c.header]),
	'every column header is translated'
);
assert.ok(
	headers.includes(en['model_browser.col_disk']) && headers.includes(en['model_browser.col_ram'])
);

// Groups: one header per backend, emoji first, the unavailable one with its reason.
const groups = ['ollama', 'mlx', 'api'].map((id) => toggleOf(page, id).innerHTML);
assert.equal(
	bodies(page).filter((tb) => tb.getAttribute('data-group')).length,
	3,
	'one group per backend with rows'
);
assert.ok(groups[0].includes(`${brands.ollama.emoji} ${brands.ollama.brand}`));

// Unavailable backend: greyed, no use button, the select path refuses it.
assert.ok(rows['Mlx-Installed'].className.includes('unavailable'));
assert.ok(!rows['Mlx-Installed'].innerHTML.includes('data-act="use"'));
page.context.selectRow('mlx\u0000Mlx-Installed');
page.context.useSelected();
rows['Mlx-Installed'].onkeydown({
	key: 'Enter',
	target: rows['Mlx-Installed'],
	preventDefault() {}
});
assert.deepEqual(page.messages.splice(0), [], 'nothing of an unavailable backend can be selected');
assert.equal(page.byId['btn-use'].disabled, true);

// A missing model of a working backend: download, never activation.
const missing = rows['Llama-Missing'];
assert.ok(missing.innerHTML.includes('data-act="download"'));
assert.ok(!missing.innerHTML.includes('data-act="use"'));
missing.onkeydown({ key: 'Enter', target: missing, preventDefault() {} });
assert.deepEqual(
	page.messages.splice(0),
	[],
	'Enter cannot activate a model that is not installed'
);
missing.onclick({ target: button('download'), stopPropagation() {} });
assert.deepEqual(page.messages.splice(0), [
	{ action: 'download_model', name: 'Llama-Missing', backend: 'ollama' }
]);

// The current model carries the mark and no use button.
assert.ok(rows['Qwen-Installed'].className.includes('active'));
assert.ok(!rows['Qwen-Installed'].innerHTML.includes('data-act="use"'));
assert.ok(rows['Qwen-Installed'].innerHTML.includes('data-act="delete"'));

// The API row is selectable and names its backend.
const api = rows['OpenAI/gpt-4o-mini'];
api.onclick({ target: button('use'), stopPropagation() {} });
assert.deepEqual(page.messages.splice(0), [
	{ action: 'select_model', name: 'OpenAI/gpt-4o-mini', backend: 'api' }
]);

// Keyboard: Enter uses, Delete removes, arrows move focus across groups.
const custom = rows['my-tag'];
custom.onkeydown({ key: 'Enter', target: custom, preventDefault() {} });
custom.onkeydown({ key: 'Delete', target: custom, preventDefault() {} });
assert.deepEqual(page.messages.splice(0), [
	{ action: 'select_model', name: 'my-tag', backend: 'ollama' },
	{ action: 'remove_custom_model', name: 'my-tag', backend: 'ollama' }
]);
rows['Qwen-Installed'].onkeydown({
	key: 'Delete',
	target: rows['Qwen-Installed'],
	preventDefault() {}
});
assert.deepEqual(page.messages.splice(0), [
	{ action: 'delete_model', name: 'Qwen-Installed', backend: 'ollama' }
]);
// Rows sort by name inside their group, so Qwen-Installed closes the Ollama
// group, which the API group follows.
rows['Qwen-Installed'].onkeydown({
	key: 'ArrowDown',
	target: rows['Qwen-Installed'],
	preventDefault() {}
});
assert.equal(
	page.doc.activeElement,
	rows['OpenAI/gpt-4o-mini'],
	'ArrowDown crosses into the next group'
);
assert.equal(String(custom.tabIndex), '0', 'every row is focusable');

// Filter: one backend at a time.
page.byId['backend-filter'].value = 'api';
page.byId['backend-filter'].dispatch('change');
assert.deepEqual(Object.keys(drawnRows(page.byId)), ['OpenAI/gpt-4o-mini']);
page.byId['backend-filter'].value = '';
page.byId['backend-filter'].dispatch('change');
assert.equal(Object.keys(drawnRows(page.byId)).length, 5);

// Header current line: emoji first, as the tray button.
assert.equal(
	page.byId.current.textContent,
	en['model_browser.current_label'].replace('{model}', `${brands.ollama.emoji} Qwen-Installed`)
);

// Footer: "no model" exists only with its capability.
assert.equal(page.byId['btn-disable'].hidden, false);
page.byId['btn-disable'].dispatch('click');
assert.deepEqual(page.messages.splice(0), [{ action: 'disable_model' }]);
page.context.injectModels({ ...payload, capabilities: {} });
assert.equal(page.byId['btn-disable'].hidden, true);
page.byId['btn-disable'].dispatch('click');
assert.deepEqual(page.messages.splice(0), [], 'a hidden capability cannot be invoked');

// Group tools: a driver action, the add-a-model field and the provider list.
// model-selector-two-lines: install, port and status on one line, adding on the other.
const toolsOf = (id) => groupHead(page, id).children[0].children[1];
const addOf = (id) => groupHead(page, id).children[0].children[2];
const ollamaTools = toolsOf('ollama').children;
assert.equal(toolsOf('ollama').className, 'group-tools');
assert.equal(addOf('ollama').className, 'group-add');
assert.equal(toolsOf('mlx').children[1].className, 'reason', 'the status stands on the tools line');
assert.equal(toolsOf('mlx').children[1].textContent, en['model_browser.reason_mlx_intel']);
const installText = (id) => en['model_browser.install_runtime'].replace('%s', brands[id].brand);
// model-selector-install-button: an installed runtime greys its install button
// with the reason, and a click on it reaches nothing.
// model-selector-greyed-install: the maintainer's Mac had both runtimes, so both
// buttons were disabled; they still read "Install ..." with the hover of an
// enabled button, and the click looked dead. The caption states the fact and
// the sheet greys every disabled action.
assert.equal(ollamaTools[0].textContent, en['model_browser.install_installed']);
const browserCss = fs.readFileSync(path.join(SHARED_UI, 'model_browser/style.css'), 'utf8');
const disabledRule = browserCss.match(/\.act:disabled,\s*\.act:disabled:hover\s*{([^}]*)}/);
assert.ok(disabledRule, 'a greyed action has its own look, and no hover');
assert.ok(/cursor:\s*default/.test(disabledRule[1]), 'a greyed action has no pointer');
assert.ok(/color:\s*var\(--text-dim\)/.test(disabledRule[1]), 'a greyed action is dimmed');
assert.equal(ollamaTools[0].disabled, true, 'an installed runtime cannot be installed again');
assert.equal(ollamaTools[0].title, en['model_browser.install_installed']);
ollamaTools[0].onclick();
assert.deepEqual(page.messages.splice(0), [], 'a greyed install button posts nothing');
// A machine that cannot run the backend greys it with that reason.
const mlxInstall = toolsOf('mlx').children[0];
assert.equal(mlxInstall.textContent, installText('mlx'));
assert.equal(mlxInstall.disabled, true);
assert.equal(mlxInstall.title, en['model_browser.reason_mlx_intel']);
const [input, addButton, addError] = addOf('ollama').children;
input.value = 'Qwen3 4b';
addButton.onclick();
assert.deepEqual(
	page.messages.splice(0),
	[],
	'an invalid identifier never reaches the native side'
);
assert.equal(addError.textContent, en['model_browser.invalid_identifier_ollama']);
assert.equal(input.getAttribute('aria-invalid'), 'true');
input.value = ' qwen3:4b ';
input.onkeydown({ key: 'Enter', preventDefault() {} });
assert.deepEqual(page.messages.splice(0), [
	{ action: 'add_model', backend: 'ollama', name: 'qwen3:4b' }
]);
assert.deepEqual(
	toolsOf('mlx').children.map((el) => el.className),
	['act install', 'reason'],
	'an unavailable backend offers only its greyed install, no add field'
);
assert.equal(addOf('mlx').children.length, 0);
const [select, providerButton] = addOf('api').children;
select.value = 'groq';
providerButton.onclick();
assert.deepEqual(page.messages.splice(0), [
	{ action: 'add_provider', backend: 'api', provider: 'groq' }
]);

// An API row without its key: greyed, not selectable, but its key can be set.
page.context.injectModels({
	...payload,
	models: [
		{
			backend: 'api',
			name: 'oMLX',
			installed: true,
			available: false,
			hint_key: 'model_browser.hint_api_no_key',
			actions: [{ id: 'set_key', text: 'Key…' }]
		},
		{ backend: 'ollama', name: 'Pulling', installed: false, pending: 'download' }
	]
});
const keyless = drawnRows(page.byId).oMLX;
assert.ok(keyless.className.includes('unavailable'));
assert.ok(keyless.innerHTML.includes(en['model_browser.hint_api_no_key']));
assert.ok(!keyless.innerHTML.includes('data-act="use"'));
keyless.onkeydown({ key: 'Enter', target: keyless, preventDefault() {} });
assert.deepEqual(page.messages.splice(0), [], 'a keyless provider cannot be selected');
keyless.onclick({
	target: {
		closest: () => ({
			getAttribute: (n) => (n === 'data-act' ? 'row' : n === 'data-index' ? '0' : null)
		})
	},
	stopPropagation() {}
});
assert.deepEqual(page.messages.splice(0), [
	{ action: 'row_action', id: 'set_key', name: 'oMLX', backend: 'api' }
]);
const pulling = drawnRows(page.byId).Pulling;
assert.ok(pulling.innerHTML.includes(en['model_browser.status_downloading']));
assert.ok(!pulling.innerHTML.includes('data-act='), 'a running download offers no other action');

page.context.injectModels({
	...payload,
	models: [
		{
			backend: 'ollama',
			name: 'Unknown',
			installed: false,
			available: false,
			inventory_unknown: true,
			hint_key: 'model_browser.inventory_unavailable'
		}
	]
});
const unknownInventory = drawnRows(page.byId).Unknown;
assert.ok(unknownInventory.innerHTML.includes(en['model_browser.inventory_unavailable']));
assert.ok(!unknownInventory.innerHTML.includes('data-act="download"'));
assert.ok(!unknownInventory.innerHTML.includes(en['model_browser.status_available']));
page.context.injectModels({
	...payload,
	models: [{ backend: 'ollama', name: 'Unknown', installed: false, available: true }]
});
assert.ok(drawnRows(page.byId).Unknown.innerHTML.includes('data-act="download"'));
page.context.injectModels({
	...payload,
	models: [{ backend: 'ollama', name: 'Pulling', installed: false, pending: 'download' }]
});

// model-selector-progress: a driver's download percentage reaches the row; a
// payload row may carry it too; an unknown row or a foreign backend is ignored.
page.context.injectProgress({ backend: 'ollama', name: 'Pulling', percent: 42.8 });
const percentText = en['model_browser.status_downloading_percent'].replace('{n}', '42');
assert.ok(
	drawnRows(page.byId).Pulling.innerHTML.includes(percentText),
	'the whole percentage is shown'
);
page.context.injectProgress({ backend: 'mlx', name: 'Pulling', percent: 90 });
assert.ok(
	drawnRows(page.byId).Pulling.innerHTML.includes(percentText),
	'another backend changes nothing'
);
page.context.injectProgress({ backend: 'ollama', name: 'Ghost', percent: 10 });
assert.ok(!('Ghost' in drawnRows(page.byId)), 'an unknown row is not invented');
page.context.injectProgress({ backend: 'ollama', name: 'Pulling', percent: 150 });
const bounded = drawnRows(page.byId).Pulling;
assert.ok(
	bounded.innerHTML.includes(en['model_browser.status_downloading_percent'].replace('{n}', '100')),
	'a percentage is bounded'
);
assert.ok(!bounded.innerHTML.includes('data-act='), 'a downloading row offers no other action');

// model-selector-install-flow: on a fresh machine only the API rows can be
// selected; Install runs the driver's install, shows its progress in the
// header, and the payload that reports the runtime installed unlocks the rows.
const fresh = {
	...payload,
	backends: [
		{
			...backend('ollama', false, 'model_browser.reason_ollama_missing'),
			install: { state: 'available' }
		},
		payload.backends[1],
		payload.backends[2]
	]
};
page.context.injectModels(fresh);
const freshRows = drawnRows(page.byId);
for (const name of ['Qwen-Installed', 'Llama-Missing', 'my-tag', 'Mlx-Installed']) {
	assert.ok(freshRows[name].className.includes('unavailable'), `${name} waits for its runtime`);
	assert.ok(
		!/data-act="(use|download|delete)"/.test(freshRows[name].innerHTML),
		`${name} cannot be used, downloaded or deleted yet`
	);
}
assert.ok(freshRows['OpenAI/gpt-4o-mini'].innerHTML.includes('data-act="use"'));
let freshInstall = toolsOf('ollama').children[0];
assert.equal(freshInstall.disabled, false, 'a missing runtime offers its install');
assert.equal(freshInstall.title || '', '');
freshInstall.onclick();
assert.deepEqual(page.messages.splice(0), [
	{ action: 'group_action', backend: 'ollama', id: 'install' }
]);
freshInstall = toolsOf('ollama').children[0];
assert.equal(
	freshInstall.textContent,
	en['model_browser.install_running'].replace('{name}', brands.ollama.brand)
);
assert.equal(freshInstall.disabled, true, 'a running install cannot be started twice');
freshInstall.onclick();
assert.deepEqual(page.messages.splice(0), []);
page.context.injectInstallProgress({ backend: 'ollama', percent: 42.6 });
assert.equal(
	toolsOf('ollama').children[0].textContent,
	en['model_browser.install_running_percent']
		.replace('{name}', brands.ollama.brand)
		.replace('{n}', '42')
);
page.context.injectInstallProgress({ backend: 'api', percent: 10 });
assert.ok(
	!toolsOf('api').children.some((el) => el.className.includes('install')),
	'the API has no install'
);
page.context.injectModels(payload);
assert.ok(drawnRows(page.byId)['Qwen-Installed'].innerHTML.includes('data-act="delete"'));
assert.equal(
	toolsOf('ollama').children[0].disabled,
	true,
	'the installed runtime unlocks its rows'
);
assert.throws(
	() =>
		page.context.injectModels({
			...payload,
			backends: [{ ...payload.backends[0], install: { state: 'maybe' } }]
		}),
	/Unknown install state/
);
// model-selector-checking-install: an unresolved runtime probe is no missing
// runtime: the button is greyed and says so, and a click posts nothing.
const withInstall = (install, extra = {}) => ({
	...payload,
	backends: [
		{ ...payload.backends[0], install, ...extra },
		payload.backends[1],
		payload.backends[2]
	]
});
page.context.injectModels(withInstall({ state: 'checking' }));
const checking = toolsOf('ollama').children[0];
assert.equal(
	checking.textContent,
	en['model_browser.install_checking'].replace('{name}', brands.ollama.brand)
);
assert.equal(checking.disabled, true);
checking.onclick();
assert.deepEqual(page.messages.splice(0), []);
// model-selector-install-refusal: a click the driver could not honour comes back
// in words next to a button that offers the install again.
page.context.injectModels(
	withInstall({ state: 'available', failed_key: 'model_browser.install_not_started' })
);
const refusedTools = toolsOf('ollama').children;
assert.equal(refusedTools[0].disabled, false, 'an install that did not start is offered again');
assert.equal(refusedTools[1].className, 'install-note');
assert.equal(refusedTools[1].getAttribute('role'), 'alert');
assert.equal(
	refusedTools[1].textContent,
	en['model_browser.install_not_started'].replace('{name}', brands.ollama.brand)
);
// An install greyed for a reason the header does not show states it in words.
page.context.injectModels(
	withInstall({ state: 'unsupported', reason_key: 'model_browser.install_paused' })
);
const pausedTools = toolsOf('ollama').children;
assert.equal(pausedTools[0].disabled, true);
assert.equal(
	pausedTools[1].textContent,
	en['model_browser.install_paused'].replace('{name}', brands.ollama.brand)
);
assert.ok(
	toolsOf('mlx').children.every((el) => el.className !== 'install-note'),
	'a reason the header already states is not repeated'
);
page.context.injectModels(payload);

// model-selector-provider-sections: a long local list folds by catalogue provider,
// alphabetically, as the tray's provider sub-menus did. The user's own models stay
// directly under the backend, and the API stays flat.
{
	const sectioned = loadPage(en);
	const row = (name, provider, extra = {}) => ({
		backend: 'ollama',
		name,
		provider,
		installed: true,
		...extra
	});
	const sectionPayload = {
		...payload,
		active: 'Qwen-Small',
		models: [
			row('Qwen-Small', 'Alibaba'),
			row('Qwen-Large', 'Alibaba', { family: 'Qwen' }),
			row('Gemma-Tiny', 'Google'),
			row('Mistral-Mini', 'mistral'),
			row('Bloom', 'BigScience'),
			{ backend: 'ollama', name: 'my-tag', installed: true, custom: true },
			{ backend: 'api', name: 'OpenAI/gpt-4o-mini', provider: 'OpenAI', installed: true }
		]
	};
	sectioned.context.injectModels(sectionPayload);
	const open = () => rowNames(sectioned);
	const sectionsOf = () =>
		bodies(sectioned)
			.find((tb) => tb.getAttribute('data-group') === 'ollama')
			.children.filter((tr) => tr.className.includes('section'));
	const sectionToggle = (provider) =>
		sectionsOf()
			.map((tr) => tr.children[0].children[0])
			.find((el) => el.getAttribute('data-section') === `ollama\u0000${provider}`);
	assert.equal(sectionsOf().length, 0, 'a collapsed backend draws no section');
	toggleOf(sectioned, 'ollama').onclick();
	assert.deepEqual(
		sectionsOf().map(
			(tr) => tr.children[0].children[0].getAttribute('data-section').split('\u0000')[1]
		),
		['Alibaba', 'BigScience', 'Google', 'mistral'],
		'sections sort alphabetically, whatever their case'
	);
	assert.deepEqual(
		open(),
		['my-tag', 'Qwen-Large', 'Qwen-Small'],
		'the own models stay out of the sections; only the current model section opens'
	);
	assert.equal(sectionToggle('Alibaba').getAttribute('aria-expanded'), 'true');
	assert.equal(sectionToggle('Google').getAttribute('aria-expanded'), 'false');
	assert.ok(sectionToggle('Alibaba').innerHTML.includes(countText(2, 2)), 'it counts its models');
	assert.ok(!sectionToggle('Alibaba').innerHTML.includes('group-active'));

	// Mouse and keyboard, on the toggle and on the whole header.
	sectionToggle('Google').onclick();
	assert.ok(open().includes('Gemma-Tiny'), 'a click opens a section');
	assert.equal(sectioned.doc.activeElement, sectionToggle('Google'), 'its toggle keeps the focus');
	sectionToggle('Google').onkeydown(keyEvent('Enter'));
	assert.ok(!open().includes('Gemma-Tiny'), 'Enter closes it');
	sectionToggle('Google').onkeydown(keyEvent(' '));
	assert.ok(open().includes('Gemma-Tiny'), 'Space opens it');
	sectionsOf()[2].children[0].onclick({ target: sectionsOf()[2].children[0] });
	assert.ok(!open().includes('Gemma-Tiny'), 'the whole section header toggles');

	// The current model's section can be closed, and names the model then.
	sectionToggle('Alibaba').onclick();
	assert.ok(!open().includes('Qwen-Small'), 'the user can close the current model section');
	assert.ok(sectionToggle('Alibaba').innerHTML.includes('group-active'));
	// The state survives a new payload while the page lives.
	sectioned.context.injectModels(sectionPayload);
	assert.deepEqual(open(), ['my-tag'], 'a closed section stays closed across a payload');
	sectionToggle('Alibaba').onclick();

	// Arrows walk rows and section headers, so a collapsed section is reachable.
	drawnRows(sectioned.byId)['Qwen-Small'].focus();
	const qwenSmall = drawnRows(sectioned.byId)['Qwen-Small'];
	qwenSmall.onkeydown({ key: 'ArrowDown', target: qwenSmall, preventDefault() {} });
	assert.equal(sectioned.doc.activeElement, sectionToggle('BigScience'));
	sectionToggle('BigScience').onkeydown(keyEvent('ArrowDown'));
	assert.equal(sectioned.doc.activeElement, sectionToggle('Google'));
	sectionToggle('Google').onkeydown(keyEvent('ArrowUp'));
	assert.equal(sectioned.doc.activeElement, sectionToggle('BigScience'));

	// A selected row keeps working, and its section stays open across a payload.
	sectionToggle('BigScience').onclick();
	sectioned.context.selectRow('ollama\u0000Bloom');
	assert.equal(sectioned.byId['btn-use'].disabled, false, 'the selection reaches the footer');
	sectioned.context.useSelected();
	assert.deepEqual(sectioned.messages.splice(0), [
		{ action: 'select_model', name: 'Bloom', backend: 'ollama' }
	]);

	// A search reaches into closed sections and opens only those it matches in.
	sectionToggle('BigScience').onclick();
	sectioned.byId.search.value = 'gemma';
	sectioned.byId.search.dispatch('input');
	assert.deepEqual(open(), ['Gemma-Tiny'], 'a search opens the section it matches in');
	assert.equal(sectionsOf().length, 1, 'and draws no other section');
	sectionToggle('Google').onclick();
	assert.deepEqual(open(), [], 'the user can close it again');
	sectioned.byId.search.value = '';
	sectioned.byId.search.dispatch('input');
	assert.ok(!open().includes('Gemma-Tiny'), 'clearing the search restores the closed section');
	// The backend filter alone opens no section: it does not name a model.
	sectioned.byId['backend-filter'].value = 'ollama';
	sectioned.byId['backend-filter'].dispatch('change');
	assert.ok(!open().includes('Gemma-Tiny'));
	sectioned.byId['backend-filter'].value = '';
	sectioned.byId['backend-filter'].dispatch('change');

	// The API group stays flat: its rows carry a provider too.
	toggleOf(sectioned, 'api').onclick();
	assert.ok(open().includes('OpenAI/gpt-4o-mini'));
	assert.equal(
		bodies(sectioned)
			.find((tb) => tb.getAttribute('data-group') === 'api')
			.children.filter((tr) => tr.className.includes('section')).length,
		0
	);
}

// The page and the shared Lua rule accept and refuse the same identifiers.
const corpus = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/tests/corpus/llm/model_identifiers.json'), 'utf8')
);
const luaCases = [];
for (const backendId of ['ollama', 'mlx']) {
	for (const [kind, expected] of [
		['valid', true],
		['invalid', false]
	]) {
		for (const id of corpus[backendId][kind]) {
			assert.equal(
				page.context.validModelIdentifier(backendId, id),
				expected,
				`page ${backendId} ${JSON.stringify(id)}`
			);
			luaCases.push(`{ ${JSON.stringify(backendId)}, ${JSON.stringify(id)}, ${expected} }`);
		}
	}
}
const luaCorpus = spawnSync('lua', ['-'], {
	cwd: path.join(SP, '_shared'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;' .. package.path
local M = require('ai.engine.local_servers.model_identifier')
for _, c in ipairs({ ${luaCases.join(', ')} }) do
	if M.valid(c[1], c[2]) ~= c[3] then error(('lua %s %q'):format(c[1], c[2])) end
end
`
});
assert.ifError(luaCorpus.error);
assert.equal(luaCorpus.status, 0, luaCorpus.stderr);

// =========================================
// ======= 5/ Catalogue Columns ============
// =========================================

// The shared projection emits every field a column reads, from the real catalogue.
const fields = [...page.context.COLUMNS].filter((c) => c.field).map((c) => c.field);
const catalogue = JSON.parse(fs.readFileSync(path.join(SP, '_shared/ai/data/models.json'), 'utf8'));
const first = catalogue[0].families[0].models[0];
const luaProbe = spawnSync('lua', ['-'], {
	cwd: path.join(SP, '_shared'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;' .. package.path
local C = require('ai.engine.local_servers.model_catalogue')
local catalogue = { { label = 'P', families = { { label = 'F', models = { {
	name = ${JSON.stringify(first.name)},
	parameters = { total = ${JSON.stringify(first.parameters.total)} },
	hardware_requirements = { ollama = { download_gb = ${first.hardware_requirements.ollama.download_gb}, ram_gb = ${first.hardware_requirements.ollama.ram_gb} } },
	urls = { ollama = ${JSON.stringify(first.urls.ollama)} },
} } } } } }
local p = C.build_selector(catalogue, { active_backend = 'ollama', backends = {
	{ id = 'ollama', kind = 'local', available = true, is_installed = function() return true end },
} })
local row = p.models[1]
for _, field in ipairs({ ${fields.map((f) => JSON.stringify(f)).join(', ')} }) do
	io.write(field, '=', tostring(row[field]), '\\n')
end
io.write('backend=', tostring(row.backend), '\\n')
`
});
assert.ifError(luaProbe.error);
assert.equal(luaProbe.status, 0, luaProbe.stderr);
const projected = Object.fromEntries(
	luaProbe.stdout
		.trim()
		.split('\n')
		.map((line) => line.split('='))
);
assert.equal(
	Number(projected.disk_gb),
	first.hardware_requirements.ollama.download_gb,
	'disk = download_gb'
);
assert.equal(Number(projected.ram_gb), first.hardware_requirements.ollama.ram_gb, 'ram = ram_gb');
assert.ok(Number(projected.params_b) > 0, 'params from parameters.total');
assert.equal(projected.backend, 'ollama', 'each row names its backend');

// The Windows twin emits the same fields into the page.
const ahk = fs.readFileSync(path.join(SP, 'windows/ui/model_browser/init.ahk'), 'utf8');
for (const field of [...fields, 'backend', 'installed']) {
	assert.ok(ahk.includes(`${field}:`) || ahk.includes(`"${field}"`), `Windows projects ${field}`);
}

// model-selector-single-emoji: every driver sends the bare brand, the page
// writes the emoji before it.
assert.ok(ahk.includes(',brand:" . JsonStringLiteral(Brands[Id]["brand"])'), 'Windows: bare brand');

// model-selector-install-button: every driver states the install of its local
// backends, and routes the page's install click to its owned-runtime install.
assert.ok(ahk.includes('",install:" . InstallJson'), 'Windows projects the install state');
assert.ok(ahk.includes('Tools["ollama`ninstall"] := (*) => _LLM_MBW_InstallOllama()'));
const macPage = fs.readFileSync(
	path.join(SP, 'macos/ui/menu/menu_llm/model_selector_page.lua'),
	'utf8'
);
assert.ok(!macPage.includes('BackendLabels.brand('), 'macOS: no "<brand> <emoji>" in the payload');
assert.ok(macPage.includes('brand = BackendLabels.name(backend)'), 'macOS: bare brand');
assert.ok(
	macPage.includes('backend.install = install[backend.id]'),
	'macOS projects the install state'
);
assert.ok(macPage.includes('if id == "install" then return install_runtime(ctx, backend'));
const linuxBridge = fs.readFileSync(path.join(SP, 'linux/ui/model_browser/bridge.lua'), 'utf8');
assert.ok(linuxBridge.includes('brand = BackendBrands.brand(id)'), 'Linux: bare brand');
assert.ok(
	linuxBridge.includes('b.install = ollama_install(frame, blocked, ollama_ok)'),
	'Linux projects it'
);
assert.ok(linuxBridge.includes('_bound.install_ollama(frame.llm'));

// model-selector-api-listing: every driver replays the shared listing corpus.
for (const replay of [
	'macos/tests/unit/modules/llm/vectors/test_api_model_listing_vectors.lua',
	'linux/tests/meta/corpus/test_corpus_api_model_listing.lua',
	'windows/tests/unit/modules/llm/menu/test_llm_menu_backend_model_labels.ahk'
]) {
	assert.ok(
		fs.readFileSync(path.join(SP, replay), 'utf8').includes('api_model_listing_vectors.json'),
		`${replay} replays the API listing corpus`
	);
}

console.log(
	'[OK] model selector page: collapsed groups, order, greying, download-only rows, keyboard, filter and catalogue columns.'
);
