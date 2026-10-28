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

const en = JSON.parse(fs.readFileSync(path.join(SP, '_shared/data/locales/en.json'), 'utf8'));
const brands = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/llm/backends.json'), 'utf8')
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
// The header's empty space toggles; a click inside its tools does not.
const apiCell = groupHead(page, 'api').children[0];
apiCell.onclick({ target: apiCell.children[1] });
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'false');
apiCell.onclick({ target: apiCell });
assert.equal(toggleOf(page, 'api').getAttribute('aria-expanded'), 'true');
toggleOf(page, 'api').onclick();
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
assert.ok(
	groups[1].includes(en['model_browser.reason_mlx_intel']),
	'the unavailable backend says why'
);

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
const toolsOf = (id) => groupHead(page, id).children[0].children[1];
const ollamaTools = toolsOf('ollama').children;
const installText = (id) => en['model_browser.install_runtime'].replace('%s', brands[id].brand);
// model-selector-install-button: an installed runtime greys its install button
// with the reason, and a click on it reaches nothing.
assert.equal(ollamaTools[0].textContent, installText('ollama'));
assert.equal(ollamaTools[0].disabled, true, 'an installed runtime cannot be installed again');
assert.equal(ollamaTools[0].title, en['model_browser.install_installed']);
ollamaTools[0].onclick();
assert.deepEqual(page.messages.splice(0), [], 'a greyed install button posts nothing');
// A machine that cannot run the backend greys it with that reason.
const mlxInstall = toolsOf('mlx').children[0];
assert.equal(mlxInstall.textContent, installText('mlx'));
assert.equal(mlxInstall.disabled, true);
assert.equal(mlxInstall.title, en['model_browser.reason_mlx_intel']);
const [, input, addButton, addError] = ollamaTools;
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
	['act install'],
	'an unavailable backend offers only its greyed install, no add field'
);
const [select, providerButton] = toolsOf('api').children;
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
page.context.injectModels(payload);

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
	cwd: path.join(SP, '_shared/lua'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;' .. package.path
local M = require('llm.model_identifier')
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
const catalogue = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/llm/models.json'), 'utf8')
);
const first = catalogue[0].families[0].models[0];
const luaProbe = spawnSync('lua', ['-'], {
	cwd: path.join(SP, '_shared/lua'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;' .. package.path
local C = require('llm.model_catalogue')
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
