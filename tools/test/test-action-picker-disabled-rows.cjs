// tools/test/test-action-picker-disabled-rows.cjs

/**
 * ==============================================================================
 * MODULE: Action Picker Disabled Rows (behavioural)
 * DESCRIPTION:
 * Runs the shared picker page (_shared/ui/action_picker/script.js) against a
 * minimal DOM and checks what a host-greyed row does.
 *
 * ROOT CAUSE ENCODED:
 * The picker had no way to say "this machine cannot run this action": a row was
 * either listed as if it worked or hidden, and a hidden row reads as a bug. A
 * host now marks an action `disabled` with a `hint` when it has proven a
 * requirement absent (Linux: a missing tool, a Wayland session for an
 * X11-only action). Such a row must stay visible with its reason, and must be
 * impossible to pick — by click, by arrow keys or by Enter — because a greyed
 * row that still confirms is the silent no-op binding this exists to prevent.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'ui',
	'action_picker',
	'script.js'
);

/** A DOM element with just what the page script touches. */
class FakeElement {
	constructor(tag, id) {
		this.tagName = tag;
		this.id = id || '';
		this.children = [];
		this.listeners = {};
		this.attributes = {};
		this.dataset = {};
		this.style = {};
		this.hidden = false;
		this.textContent = '';
		this.value = '';
		this.placeholder = '';
		this.title = '';
		this._classes = new Set();
		const self = this;
		this.classList = {
			add: (c) => self._classes.add(c),
			remove: (c) => self._classes.delete(c),
			contains: (c) => self._classes.has(c)
		};
	}
	set className(v) {
		this._classes = new Set(String(v).split(/\s+/).filter(Boolean));
	}
	get className() {
		return [...this._classes].join(' ');
	}
	set innerHTML(v) {
		if (v === '') this.children = [];
	}
	appendChild(child) {
		this.children.push(child);
		return child;
	}
	addEventListener(type, fn) {
		(this.listeners[type] = this.listeners[type] || []).push(fn);
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}
	scrollIntoView() {}
	focus() {}
	dispatch(type) {
		for (const fn of this.listeners[type] || []) fn({ preventDefault() {} });
	}
	text() {
		return this.textContent + this.children.map((c) => c.text()).join('');
	}
}

const byId = {};
for (const id of [
	'title',
	'subtitle',
	'search',
	'search-bar',
	'btn-cancel',
	'list',
	'empty',
	'count',
	'toc',
	'toc-inner',
	'param',
	'param-title',
	'param-prompt',
	'param-hint',
	'param-input',
	'param-error',
	'param-back',
	'param-save',
	'param-choice',
	'param-profile',
	'param-profile-label',
	'param-count',
	'param-count-label',
	'btn-edit-current',
	'param-vision',
	'param-vision-provider',
	'param-vision-provider-label',
	'param-vision-model',
	'param-vision-model-label',
	'param-program',
	'param-program-executable-label',
	'param-program-executable',
	'param-program-arguments-label',
	'param-program-arguments',
	'param-program-add',
	'param-program-provider',
	'param-program-provider-label',
	'param-program-provider-select',
	'param-program-provider-hint',
	'param-program-provider-status'
]) {
	byId[id] = new FakeElement('div', id);
}
const docListeners = {};
const posted = [];
const context = {
	document: {
		getElementById: (id) => byId[id] || null,
		createElement: (tag) => new FakeElement(tag),
		addEventListener: (type, fn) => {
			(docListeners[type] = docListeners[type] || []).push(fn);
		}
	},
	setTimeout: () => 0,
	makeHostBridge: () => (msg) => posted.push(msg),
	console
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context, { filename: SCRIPT });
for (const fn of docListeners.DOMContentLoaded || []) fn();
posted.length = 0;

vm.runInContext(
	`init({
		title: 'T', current: 'none', noneLabel: 'Nothing',
		items: [
			{ type: 'heading', level: 1, text: 'Mouse' },
			{ type: 'action', id: 'left_click_toggle', label: 'Hold left click', disabled: true, hint: 'X11 session only' },
			{ type: 'action', id: 'enter', label: 'Enter' }
		]
	})`,
	context
);

const errors = [];
const check = (cond, message) => {
	if (!cond) errors.push(message);
};

const rows = byId.list.children.filter((r) => r.classList.contains('row'));
const greyed = rows.find((r) => r.dataset.id === 'left_click_toggle');
const live = rows.find((r) => r.dataset.id === 'enter');
check(rows.length === 3, `expected the none row plus two actions, rendered ${rows.length}`);
check(greyed !== undefined, 'a disabled action must stay visible — a vanished row reads as a bug');
check(
	greyed && greyed.classList.contains('disabled'),
	'the disabled row must carry the disabled class'
);
check(
	greyed && greyed.text().includes('X11 session only'),
	'the disabled row must show its reason'
);
check(live && !live.classList.contains('disabled'), 'an ordinary row stays enabled');

// Click, arrows and Enter must never confirm the greyed row.
if (greyed) greyed.dispatch('click');
check(posted.length === 0, 'clicking a disabled row must not confirm it');
vm.runInContext("doConfirm('left_click_toggle')", context);
check(posted.length === 0, 'a disabled id must be refused even when confirmed directly');
const visibleIds = vm.runInContext('visible.map(function (v) { return v.id; })', context);
check(
	JSON.stringify(visibleIds) === JSON.stringify(['none', 'enter']),
	`arrow keys walk only the pickable rows, got ${JSON.stringify(visibleIds)}`
);
if (live) live.dispatch('click');
check(
	posted.length === 1 && posted[0].action === 'confirm' && posted[0].id === 'enter',
	'an enabled row still confirms'
);

// Native-unavailable programs retain the same visible/inert DATA contract.
posted.length = 0;
vm.runInContext(
	`init({ title: 'T', current: 'none', noneLabel: 'Nothing', items: [
 {type:'action', id:'run_program', label:'Run a program [configurable]', parameter:'program', disabled:true, hint:'Unavailable: Native runner'}
] })`,
	context
);
const program = byId.list.children.find((row) => row.dataset.id === 'run_program');
check(
	program && program.classList.contains('disabled'),
	'unavailable program remains visibly disabled'
);
check(
	program && program.text().includes('Unavailable: Native runner'),
	'unavailable program carries its closed native reason'
);
if (program) program.dispatch('click');
vm.runInContext("doConfirm('run_program')", context);
check(posted.length === 0, 'neither click nor direct confirm may acquire an unavailable program');

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action picker disabled rows:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] a greyed picker row shows its reason and can never be picked.\x1b[0m');
