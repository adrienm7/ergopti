// tools/test/test-action-picker-parameter-editor.cjs

/**
 * ==============================================================================
 * MODULE: Action Picker Parameter Editor (behavioural)
 * DESCRIPTION:
 * Runs the shared picker page (_shared/ui/action_picker/script.js) against a
 * minimal DOM and checks its editor for the send_text, send_key and
 * send_shortcut parameters: a text field, a key capture and a shortcut capture,
 * each validated with the rules the drivers apply, before the page confirms
 * the action together with its value. It also checks the llm_prompt editor (a
 * choice of prompt profile and prediction count) and the button that reopens
 * the current action's parameter.
 *
 * ROOT CAUSE ENCODED:
 * The picker only chose an action; every parameter was asked afterwards in a
 * native text prompt, so a key or a shortcut had to be spelled by hand ("ctrl+a",
 * "page_down") instead of pressed, and a typo was refused only after the picker
 * had closed. Changing the value of a bound action meant finding it again in the
 * whole catalogue, with nothing pointing at the current one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SCRIPT = path.join(SP, '_shared', 'ui', 'action_picker', 'script.js');
const HTML = path.join(SP, '_shared', 'ui', 'action_picker', 'index.html');
const CORPUS = path.join(
	SP,
	'_shared',
	'tests',
	'corpus',
	'action_parameters',
	'send_input_vectors.json'
);
const LLM_PROMPT_CORPUS = path.join(
	SP,
	'_shared',
	'tests',
	'corpus',
	'action_parameters',
	'llm_prompt_vectors.json'
);
const VISION_CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'llm', 'vision_vectors.json');
const VOCABULARY = path.join(SP, '_shared', 'modules', 'actions', 'send_keys.json');

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
		child.parent = this;
		this.children.push(child);
		return child;
	}
	append(...children) {
		for (const child of children) this.appendChild(child);
	}
	replaceChildren() {
		this.children = [];
	}
	remove() {
		if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this);
	}
	querySelectorAll(tag) {
		return this.children.flatMap((child) =>
			(child.tagName === tag ? [child] : []).concat(child.querySelectorAll(tag))
		);
	}
	addEventListener(type, fn) {
		(this.listeners[type] = this.listeners[type] || []).push(fn);
	}
	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}
	scrollIntoView() {}
	focus() {}
	select() {
		this.selectionStart = 0;
		this.selectionEnd = this.value.length;
	}
	/** Simulates typing: the value, with the caret after it. */
	type(value) {
		this.value = value;
		this.selectionStart = value.length;
		this.selectionEnd = value.length;
	}
	dispatch(type, event) {
		for (const fn of this.listeners[type] || []) fn(event || { preventDefault() {} });
	}
}

const errors = [];
const check = (cond, message) => {
	if (!cond) errors.push(message);
};

// Every element the page reaches by id must exist in index.html, or the editor
// works here and throws in a real webview.
const html = fs.readFileSync(HTML, 'utf8');
const IDS = [
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
	'param-language',
	'param-language-label',
	'param-language-select',
	'param-program',
	'param-program-executable',
	'param-program-executable-label',
	'param-program-arguments',
	'param-program-arguments-label',
	'param-program-add',
	'param-program-provider',
	'param-program-provider-label',
	'param-program-provider-select',
	'param-program-provider-hint',
	'param-program-provider-status',
	'param-program-automation',
	'param-program-automation-title',
	'param-program-automation-reason',
	'param-program-automation-list'
];
for (const id of IDS) check(html.includes(`id="${id}"`), `index.html must declare #${id}`);

function loadPage(platform, current) {
	const byId = {};
	for (const id of IDS) byId[id] = new FakeElement('div', id);
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
	vm.runInContext(
		fs.readFileSync(path.join(SP, '_shared', 'ui', 'program_parameter.js'), 'utf8'),
		context
	);
	vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context, {
		filename: SCRIPT
	});
	for (const fn of docListeners.DOMContentLoaded || []) fn();
	posted.length = 0;
	context.__vocabulary = JSON.parse(fs.readFileSync(VOCABULARY, 'utf8'));
	context.__platform = platform;
	context.__current = current || 'none';
	vm.runInContext(
		`init({
			title: 'T', current: __current, noneLabel: 'Nothing', platform: __platform,
			sendVocabulary: __vocabulary,
			editCurrentLabel: 'Edit current',
			promptChoices: [{ value: 'basic', label: 'Basic' }, { value: 'rewrite', label: 'Rewrite' },
				{ value: 'custom_1_2', label: 'Mine' }],
			defaultCount: 3,
			visionChoices: [{ value: 'local', label: 'Local', defaultModel: 'qwen2.5vl:3b' },
				{ value: 'cerebras', label: 'Cerebras', defaultModel: '' }],
			languageChoices: [{ value: 'ui', label: 'Menu (Français)' }, { value: 'en', label: 'English' },
				{ value: 'ja', label: '日本語' }],
			parameterStrings: {
				save: 'Save', back: 'Back', captureKey: 'Press a key', captureShortcut: 'Press a shortcut',
				promptLabel: 'Prompt', countLabel: 'Count', countDefault: 'Menu ({1})',
				visionProviderLabel: 'Provider', visionModelLabel: 'Model', visionModelDefault: 'Default: {1}',
				visionModelRequired: 'Required', languageLabel: 'Translate into',
				programExecutableLabel: 'Executable', programArgumentsLabel: 'Arguments',
				programAddLabel: 'Add argument', programRemoveLabel: 'Remove argument',
				prompts: { text: 'Text?', key: 'Key?', shortcut: 'Shortcut?' },
				errors: { text: 'Bad text', key: 'Bad key', shortcut: 'Bad shortcut', llm_prompt: 'Bad prompt',
					llm_vision: 'Bad vision', llm_language: 'Bad language' }
			},
			items: [
				{ type: 'action', id: 'send_text', label: 'Type a text', parameter: 'text', parameterValue: 'salut' },
				{ type: 'action', id: 'send_key', label: 'Press a key', parameter: 'key' },
				{ type: 'action', id: 'send_shortcut', label: 'Press a shortcut', parameter: 'shortcut' },
				{ type: 'action', id: 'open_url', label: 'Open a link', parameter: 'url', parameterValue: 'https://x.y' },
				{ type: 'action', id: 'llm_prompt_prediction', label: 'Prompt', parameter: 'llm_prompt',
					parameterValue: 'rewrite|2' },
				{ type: 'action', id: 'llm_screen_region', label: 'Screen', parameter: 'llm_vision',
					parameterValue: 'cerebras|llama-4-scout' },
				{ type: 'action', id: 'llm_translate_selection', label: 'Translate', parameter: 'llm_language',
					parameterValue: 'ja' },
				{ type: 'action', id: 'run_program', label: 'Run program', parameter: 'program' },
				{ type: 'action', id: 'enter', label: 'Enter' }
			]
		})`,
		context
	);
	const keydown = (event) => {
		const e = Object.assign(
			{
				preventDefault() {
					e.prevented = true;
				},
				prevented: false
			},
			event
		);
		for (const fn of docListeners.keydown || []) fn(e);
		return e;
	};
	return { byId, posted, context, keydown };
}

// 1. The page's rules are the drivers' rules: the shared corpus replayed.
{
	const page = loadPage('ahk');
	const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
	let replayed = 0;
	for (const vector of corpus.vectors) {
		page.context.__value = vector.value.repeat(vector.repeat || 1);
		page.context.__kind = vector.kind;
		const parsed = vm.runInContext('parseParameter(__kind, __value)', page.context);
		if (vector.valid === false) {
			check(parsed === null, `${vector.id}: the page accepts it as ${JSON.stringify(parsed)}`);
		} else {
			const canonical = vector.canonical.repeat(vector.canonical_repeat || 1);
			check(
				parsed === canonical,
				`${vector.id}: the page reads ${JSON.stringify(parsed)}, not ${canonical}`
			);
		}
		replayed += 1;
	}
	check(replayed >= 40, `only ${replayed} vector(s) replayed`);

	// A Lua host's JSON encoder writes an empty alias list as {}: the page must
	// still find the entry by its id.
	const luaEncoded = JSON.parse(JSON.stringify(page.context.__vocabulary));
	for (const entry of luaEncoded.modifiers.concat(luaEncoded.keys)) {
		if (entry.aliases.length === 0) entry.aliases = {};
	}
	page.context.__luaVocabulary = luaEncoded;
	const parsed = vm.runInContext(
		"sendVocabulary = __luaVocabulary; parseParameter('shortcut', 'primary+a')",
		page.context
	);
	check(
		parsed === 'primary+a',
		`an empty alias list encoded as {} breaks the lookup: ${JSON.stringify(parsed)}`
	);
}

// 2. Picking a parameterized action opens the editor instead of confirming.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('send_text')", page.context);
	check(page.posted.length === 0, 'send_text must not confirm before its text is entered');
	check(
		page.byId.param.hidden === false && page.byId.list.hidden === true,
		'the editor replaces the list'
	);
	check(
		page.byId['param-input'].value === 'salut',
		"the editor starts from the binding's current value"
	);
	page.byId['param-input'].value = 'a\nb';
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 0 && page.byId['param-error'].hidden === false,
		'an invalid text is refused in place'
	);
	page.byId['param-input'].value = 'bonjour cela va bien?';
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 &&
			page.posted[0].action === 'confirm' &&
			page.posted[0].id === 'send_text' &&
			page.posted[0].parameter === 'bonjour cela va bien?',
		'a valid text confirms the action with it'
	);
}

// 3. The key capture turns a keystroke into its name; the shortcut capture into
//    modifiers + key, Control being "primary" off macOS and Command on it.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('send_key')", page.context);
	const e = page.keydown({ key: 'PageDown', code: 'PageDown' });
	check(
		e.prevented && page.byId['param-input'].value === 'page_down',
		'PageDown is captured as page_down'
	);
	page.keydown({ key: 'Escape', code: 'Escape' });
	check(
		page.byId['param-input'].value === 'escape' && page.posted.length === 0,
		'Escape is a key to capture here, not a cancel'
	);
	page.byId['param-back'].dispatch('click');
	check(
		page.byId.param.hidden === true && page.byId.list.hidden === false,
		'Back returns to the list'
	);

	vm.runInContext("doConfirm('send_shortcut')", page.context);
	page.keydown({ key: 'Control', code: 'ControlLeft', ctrlKey: true });
	check(page.byId['param-input'].value === '', 'a lone modifier captures nothing yet');
	page.keydown({ key: 'a', code: 'KeyA', ctrlKey: true });
	check(page.byId['param-input'].value === 'primary+a', 'Ctrl+A is primary+a on Windows and Linux');
	page.keydown({ key: 'T', code: 'KeyT', ctrlKey: true, shiftKey: true });
	check(
		page.byId['param-input'].value === 'primary+shift+t',
		'Ctrl+Shift+T captures the letter, not the capital'
	);
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 && page.posted[0].parameter === 'primary+shift+t',
		'the capture is what is saved'
	);

	const mac = loadPage('hs');
	vm.runInContext("doConfirm('send_shortcut')", mac.context);
	mac.keydown({ key: 'a', code: 'KeyA', metaKey: true });
	check(mac.byId['param-input'].value === 'primary+a', 'Cmd+A is primary+a on macOS');
	mac.keydown({ key: 'a', code: 'KeyA', ctrlKey: true });
	check(mac.byId['param-input'].value === 'ctrl+a', 'Ctrl+A stays ctrl+a on macOS');
}

// 4. The captures still let a name be typed: a character types itself, the
//    editing keys edit a field that holds text, and Enter saves it; only an
//    empty (or wholly selected) field turns those keys into captures.
{
	const page = loadPage('ahk');
	const input = page.byId['param-input'];
	vm.runInContext("doConfirm('send_key')", page.context);
	check(
		!page.keydown({ key: 'f', code: 'KeyF' }).prevented,
		'a character types into the key field'
	);
	input.type('f13');
	check(
		!page.keydown({ key: 'Backspace', code: 'Backspace' }).prevented,
		'Backspace edits a typed name'
	);
	page.keydown({ key: 'Enter', code: 'Enter' });
	check(
		page.posted.length === 1 && page.posted[0].parameter === 'f13',
		'Enter saves a typed key name'
	);

	const empty = loadPage('ahk');
	vm.runInContext("doConfirm('send_key')", empty.context);
	empty.keydown({ key: 'Backspace', code: 'Backspace' });
	check(empty.byId['param-input'].value === 'backspace', 'an empty key field captures Backspace');
	check(
		!empty.keydown({ key: 'a', code: 'KeyA', ctrlKey: true }).prevented,
		'Ctrl+A selects the key field instead of being captured'
	);

	const shortcut = loadPage('ahk');
	const field = shortcut.byId['param-input'];
	vm.runInContext("doConfirm('send_shortcut')", shortcut.context);
	check(
		!shortcut.keydown({ key: 'c', code: 'KeyC' }).prevented,
		'a plain letter types into the shortcut field'
	);
	field.type('ctrl');
	check(
		!shortcut.keydown({ key: '+', code: 'Equal', shiftKey: true }).prevented,
		'Shift+= types "+" after a modifier name'
	);
	check(
		!shortcut.keydown({
			key: '€',
			code: 'KeyE',
			ctrlKey: true,
			altKey: true,
			getModifierState: (name) => name === 'AltGraph'
		}).prevented,
		'AltGr types its character'
	);
	field.type('ctrl++');
	shortcut.keydown({ key: 'Enter', code: 'Enter' });
	check(
		shortcut.posted.length === 1 && shortcut.posted[0].parameter === 'ctrl++',
		'Enter saves a typed shortcut'
	);

	const fresh = loadPage('ahk');
	vm.runInContext("doConfirm('send_shortcut')", fresh.context);
	fresh.keydown({ key: 'A', code: 'KeyA', shiftKey: true });
	check(fresh.byId['param-input'].value === 'shift+a', 'an empty shortcut field captures Shift+A');
	fresh.keydown({ key: 'Escape', code: 'Escape' });
	check(
		fresh.byId.param.hidden === true && fresh.posted.length === 0,
		'Escape returns from a shortcut to the list'
	);
}

// 5. A kind the page does not edit, and an action without one, confirm directly:
//    the host keeps its own prompt for those.
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('open_url')", page.context);
	check(
		page.posted.length === 1 &&
			page.posted[0].id === 'open_url' &&
			page.posted[0].parameter === undefined,
		'a URL is still asked by the host'
	);
	vm.runInContext("doConfirm('enter')", page.context);
	check(
		page.posted.length === 2 && page.posted[1].id === 'enter',
		'an ordinary action confirms at once'
	);
}

// 6. The llm_prompt rules are the drivers' rules: the shared corpus replayed.
{
	const page = loadPage('ahk');
	const corpus = JSON.parse(fs.readFileSync(LLM_PROMPT_CORPUS, 'utf8'));
	let replayed = 0;
	for (const vector of corpus.vectors) {
		page.context.__value = vector.value;
		const parsed = vm.runInContext('parseLlmPrompt(__value)', page.context);
		if (vector.valid === false) {
			check(parsed === null, `${vector.id}: the page accepts ${JSON.stringify(vector.value)}`);
		} else {
			const expected = vector.num_predictions === undefined ? null : vector.num_predictions;
			check(
				parsed !== null &&
					parsed.profileId === vector.profile_id &&
					parsed.numPredictions === expected &&
					parsed.translationTarget === vector.translation_target,
				`${vector.id}: the page reads ${JSON.stringify(parsed)}`
			);
		}
		replayed += 1;
	}
	check(replayed >= 15, `only ${replayed} llm_prompt vector(s) replayed`);
}

// 7. Picking llm_prompt_prediction offers the host's prompts and the counts,
//    starts from the binding's value and saves "<id>" or "<id>|<count>".
{
	const page = loadPage('ahk');
	vm.runInContext("doConfirm('llm_prompt_prediction')", page.context);
	check(page.posted.length === 0, 'the prompt action must not confirm before a prompt is chosen');
	check(
		page.byId['param-choice'].hidden === false && page.byId['param-input'].hidden === true,
		'the prompt editor shows the choices instead of the text field'
	);
	const profiles = page.byId['param-profile'].children.map((o) => o.value);
	check(
		JSON.stringify(profiles) === JSON.stringify(['basic', 'rewrite', 'custom_1_2']),
		`every host prompt is offered, in order: ${JSON.stringify(profiles)}`
	);
	const counts = page.byId['param-count'].children;
	check(
		counts.length === 11 &&
			counts[0].value === '' &&
			counts[0].textContent === 'Menu (3)' &&
			counts[10].value === '10',
		'the counts are the menu default then 1 to 10'
	);
	check(
		page.byId['param-profile'].value === 'rewrite' && page.byId['param-count'].value === '2',
		"the editor starts from the binding's current prompt and count"
	);
	page.byId['param-count'].value = '';
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 &&
			page.posted[0].id === 'llm_prompt_prediction' &&
			page.posted[0].parameter === 'rewrite',
		'the menu count saves the bare prompt id'
	);

	const second = loadPage('ahk');
	vm.runInContext("doConfirm('llm_prompt_prediction')", second.context);
	second.byId['param-profile'].value = 'custom_1_2';
	second.byId['param-count'].value = '5';
	second.keydown({ key: 'Enter', code: 'Enter' });
	check(
		second.posted.length === 1 && second.posted[0].parameter === 'custom_1_2|5',
		'Enter saves the prompt and its count'
	);

	const noChoices = loadPage('ahk');
	vm.runInContext("promptChoices = []; doConfirm('llm_prompt_prediction')", noChoices.context);
	check(
		noChoices.posted.length === 1 && noChoices.posted[0].parameter === undefined,
		'without prompts to offer, the host asks for the value itself'
	);
}

// 8. "Edit the current action" appears only when the current action takes a
//    parameter, and reopens it: the page's editor, or the host's prompt.
{
	const none = loadPage('ahk');
	check(none.byId['btn-edit-current'].hidden === true, 'no edit button when no action is bound');
	const plain = loadPage('ahk', 'enter');
	check(
		plain.byId['btn-edit-current'].hidden === true,
		'no edit button for an action without a parameter'
	);

	const prompt = loadPage('ahk', 'llm_prompt_prediction');
	const button = prompt.byId['btn-edit-current'];
	check(
		button.hidden === false && button.textContent === 'Edit current',
		'the edit button shows for a prompt action'
	);
	button.dispatch('click');
	check(
		prompt.byId.param.hidden === false &&
			prompt.byId['param-profile'].value === 'rewrite' &&
			prompt.posted.length === 0,
		'the edit button opens the prompt editor on the current value'
	);

	const text = loadPage('ahk', 'send_text');
	text.byId['btn-edit-current'].dispatch('click');
	check(
		text.byId['param-input'].value === 'salut',
		'the edit button opens the text editor on the current text'
	);

	const url = loadPage('ahk', 'open_url');
	url.byId['btn-edit-current'].dispatch('click');
	check(
		url.posted.length === 1 &&
			url.posted[0].id === 'open_url' &&
			url.posted[0].parameter === undefined,
		'the edit button hands a URL back to the host prompt'
	);
}

// 9. The llm_vision rules are the drivers' rules, and its editor offers the
//    host's backends with their default model, or requires one.
{
	const page = loadPage('ahk');
	const corpus = JSON.parse(fs.readFileSync(VISION_CORPUS, 'utf8'));
	for (const vector of corpus.parse_vectors) {
		page.context.__value = vector.value;
		const parsed = vm.runInContext('parseLlmVision(__value)', page.context);
		if (vector.valid === false) {
			check(
				parsed === null,
				`vision ${vector.id}: the page accepts ${JSON.stringify(vector.value)}`
			);
		} else {
			const model = vector.model === undefined ? null : vector.model;
			check(
				parsed !== null && parsed.backend === vector.backend && parsed.model === model,
				`vision ${vector.id}: the page reads ${JSON.stringify(parsed)}`
			);
		}
	}

	vm.runInContext("doConfirm('llm_screen_region')", page.context);
	check(
		page.byId['param-vision'].hidden === false &&
			page.byId['param-input'].hidden === true &&
			page.byId['param-choice'].hidden === true,
		'the vision editor replaces the text field'
	);
	check(
		page.byId['param-vision-provider'].value === 'cerebras' &&
			page.byId['param-vision-model'].value === 'llama-4-scout',
		'the editor starts from the binding'
	);
	check(
		page.byId['param-vision-model'].placeholder === 'Required',
		'a backend without a default asks for a model'
	);
	page.byId['param-vision-model'].value = '';
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 0 && page.byId['param-error'].hidden === false,
		'a backend without a default is refused without a model'
	);
	page.byId['param-vision-provider'].value = 'local';
	page.byId['param-vision-provider'].dispatch('change');
	check(
		page.byId['param-vision-model'].placeholder === 'Default: qwen2.5vl:3b',
		'the default model is shown'
	);
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 &&
			page.posted[0].id === 'llm_screen_region' &&
			page.posted[0].parameter === 'local',
		'an empty model keeps the backend default'
	);

	const second = loadPage('ahk');
	vm.runInContext("doConfirm('llm_screen_region')", second.context);
	second.byId['param-vision-model'].value = '  llama-4-scout  ';
	second.keydown({ key: 'Enter', code: 'Enter' });
	check(
		second.posted.length === 1 && second.posted[0].parameter === 'cerebras|llama-4-scout',
		'Enter saves the backend and the trimmed model'
	);
}

// 10. Free language entry belongs to the host's existing InputBox, on all drivers.
// The page must not synthesize a locale or overwrite the stored binding value.
for (const platform of ['ahk', 'hs', 'linux']) {
	const page = loadPage(platform);
	vm.runInContext("doConfirm('llm_translate_selection')", page.context);
	check(page.posted.length === 1, 'language choice is handed off once');
	const handoff = page.posted[0];
	check(
		handoff && handoff.action === 'confirm' && handoff.id === 'llm_translate_selection',
		'exact language action is handed to its native parameter owner'
	);
	check(
		handoff && !Object.hasOwn(handoff, 'parameter'),
		'the page cannot invent a target-language receipt'
	);
	check(
		vm.runInContext('editing === null', page.context),
		'the closed locale catalogue never opens'
	);
	page.context.__value = 'translate|2|Esperanto';
	const receipt = vm.runInContext('parseLlmPrompt(__value)', page.context);
	check(
		receipt &&
			receipt.profileId === 'translate' &&
			receipt.numPredictions === 2 &&
			receipt.translationTarget === 'Esperanto',
		'the typed per-binding target stays literal'
	);
	page.context.__value = 'rewrite|2|Esperanto';
	check(
		vm.runInContext('parseLlmPrompt(__value)', page.context) === null,
		'a target cannot silently change an unrelated prompt'
	);
}

// 11. The editor stores an executable and literal ordered arguments, including
// empty strings and line breaks, without interpreting shell syntax.
for (const platform of ['ahk', 'hs', 'linux']) {
	const page = loadPage(platform);
	vm.runInContext("doConfirm('run_program')", page.context);
	check(
		page.posted.length === 0 && page.byId['param-program'].hidden === false,
		'program selection opens its real executable/argv editor'
	);
	check(page.byId['param-input'].hidden === true, 'raw scalar JSON is not the program input');
	check(
		page.byId['param-program-executable-label'].textContent === 'Executable',
		'host executable label is forwarded'
	);
	page.byId['param-program-executable'].value =
		platform === 'ahk' ? 'C:\\Program Files\\été.exe' : '/private/été 日本 program';
	const literal = ['', 'two words', ' padded ', '日本語', '%TOKEN%;$(literal)', 'line\nnext'];
	for (const argument of literal) {
		page.byId['param-program-add'].dispatch('click');
		const inputs = page.byId['param-program-arguments'].querySelectorAll('textarea');
		inputs[inputs.length - 1].value = argument;
	}
	const enter = page.keydown({ key: 'Enter', code: 'Enter' });
	check(
		page.posted.length === 0 && enter.prevented === false,
		'Enter remains literal program argument input'
	);
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 && page.posted[0].id === 'run_program',
		'program save delivers the actual action choice'
	);
	const decoded = page.posted[0] && JSON.parse(page.posted[0].parameter);
	check(
		decoded &&
			decoded.version === 1 &&
			decoded.executable === page.byId['param-program-executable'].value,
		'program executable remains an opaque absolute path'
	);
	check(
		decoded && JSON.stringify(decoded.arguments) === JSON.stringify(literal),
		'all literal argv values/order remain exact'
	);
}

// 12. Independent shared vectors reject duplicate, null, bool/version and
// malformed argument shapes across each actual picker platform.
{
	const corpus = JSON.parse(
		fs.readFileSync(
			path.join(SP, '_shared', 'tests', 'corpus', 'action_parameters', 'program_vectors.json'),
			'utf8'
		)
	);
	let count = 0;
	for (const vector of corpus.cases)
		for (const platform of vector.platforms) {
			const page = loadPage(platform);
			page.context.__raw = vector.value;
			const parsed = vm.runInContext('ProgramParameter.parse(__raw, hostPlatform)', page.context);
			check(
				JSON.stringify(parsed) === JSON.stringify(vector.expected),
				`${vector.id}/${platform}: program codec disagrees with independent vector`
			);
			count += 1;
		}
	check(count >= 63, 'all independent program vectors execute');
}

// 13. Discovered scripts lower only in the native owner; the page cannot forge
// executable paths and a refusal keeps literal arguments available for retry.
for (const platform of ['hs', 'linux', 'ahk']) {
	const page = loadPage(platform);
	vm.runInContext(
		`programProviders = {
		choices: [{key:'1:1', label:'été 日本.py'}], truncated:false
	}; programProviderStrings = { label:'Script', manual:'Manual', hint:'Owned folder',
		unavailable:'Unavailable', changed:'Changed', empty:'Empty', truncated:'Truncated' };
	doConfirm('run_program')`,
		page.context
	);
	check(page.byId['param-program-provider'].hidden === false, 'provider selector is visible');
	check(
		page.byId['param-program-provider-select'].children[1].textContent === 'été 日本.py',
		'script labels remain opaque Unicode text'
	);
	page.byId['param-program-provider-select'].value = '1:1';
	page.byId['param-program-provider-select'].dispatch('change');
	check(page.byId['param-program-executable'].hidden === true, 'preset owns its executable');
	page.context.__argument = 'a "quoted" 日本\nline';
	vm.runInContext("appendProgramArgument(''); appendProgramArgument(__argument)", page.context);
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 &&
			page.posted[0].providerKey === '1:1' &&
			!Object.hasOwn(page.posted[0], 'parameter'),
		'only opaque key reaches native resolver'
	);
	check(
		JSON.stringify(page.posted[0].programArguments) ===
			JSON.stringify(['', 'a "quoted" 日本\nline']),
		'preset arguments preserve empty, quote, Unicode and newline values'
	);
	vm.runInContext('programProviderRefused()', page.context);
	check(
		page.byId['param-error'].hidden === false && page.byId['param-error'].textContent === 'Changed',
		'identity refusal remains visible in the same open editor'
	);
	check(
		page.byId['param-program-arguments'].querySelectorAll('textarea').length === 2,
		'refusal does not erase editable arguments'
	);
	page.byId['param-program-provider-select'].value = '';
	page.byId['param-program-provider-select'].dispatch('change');
	check(
		page.byId['param-program-executable'].hidden === false,
		'manual executable remains available'
	);
	vm.runInContext(
		'closeParamEditor(); programProviders={unavailable:true}; doConfirm("run_program")',
		page.context
	);
	check(
		page.byId['param-program-provider-status'].textContent === 'Unavailable',
		'unsupported discovery has its translated reason'
	);
	vm.runInContext(
		'closeParamEditor(); programProviders={choices:[],truncated:false}; doConfirm("run_program")',
		page.context
	);
	check(
		page.byId['param-program-provider-status'].textContent === 'Empty',
		'missing folder is neutral'
	);
	vm.runInContext(
		'closeParamEditor(); programProviders={choices:[],truncated:true}; doConfirm("run_program")',
		page.context
	);
	check(
		page.byId['param-program-provider-status'].textContent === 'Truncated',
		'bounded inventory is honest'
	);
	vm.runInContext(
		'closeParamEditor(); programProviders=null; doConfirm("run_program")',
		page.context
	);
	check(
		page.byId['param-program-provider'].hidden === true &&
			page.byId['param-program-executable'].hidden === false,
		'legacy/manual editor never stays hidden'
	);
}

// 14. Native readonly automation inventory remains separate from script assignment.
{
	const page = loadPage('hs');
	vm.runInContext(
		`programProviders={choices:[{key:'8:1',label:'Owned script.py'}]};
		programProviderStrings={manual:'Manual',unavailableBinding:'Translated native unavailable'};
		doConfirm('run_program'); appendProgramArgument('literal before native query')`,
		page.context
	);
	page.byId['param-program-executable'].value = '/private/literal tool';
	vm.runInContext(
		`updateAutomationProviders({title:'Apple Shortcuts',choices:[
		{key:'automation:9:1',label:'日本 e\\u0301\\n<script>private name</script>',available:false}],truncated:false})`,
		page.context
	);
	check(page.byId['param-program-automation'].hidden === false, 'actual native inventory appears');
	check(
		page.byId['param-program-automation-title'].textContent === 'Apple Shortcuts',
		'separate provider identity'
	);
	check(
		page.byId['param-program-automation-reason'].textContent === 'Translated native unavailable',
		'existing translated unavailable reason'
	);
	check(
		page.byId['param-program-automation-list'].children[0].textContent ===
			'日本 e\u0301\n<script>private name</script>',
		'native names remain literal Unicode text'
	);
	check(
		page.byId['param-program-provider-select'].children.length === 2,
		'readonly workflows never enter script select'
	);
	check(
		page.byId['param-program-executable'].value === '/private/literal tool',
		'asynchronous native update preserves manual executable'
	);
	check(
		page.byId['param-program-arguments'].querySelectorAll('textarea')[0].value ===
			'literal before native query',
		'asynchronous native update preserves literal arguments'
	);
	check(page.posted.length === 0, 'inventory update cannot confirm an automation');
	page.byId['param-save'].dispatch('click');
	check(
		page.posted.length === 1 &&
			JSON.parse(page.posted[0].parameter).executable === '/private/literal tool',
		'manual literal assignment remains available'
	);
}

// Parser controls qualify receipt admission only; native Hammerspoon runs in CI.
{
	const controls = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		[
			'-m',
			'unittest',
			'discover',
			'-s',
			'tools/diagnostics/native_hs_program_providers',
			'-p',
			'test_receipt.py'
		],
		{
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	check(
		!controls.error && controls.signal === null && controls.status === 0,
		'provider receipt parser controls complete'
	);
	check(
		/Ran 40 tests in /.test(controls.stderr) && /\nOK\s*$/.test(controls.stderr),
		'all twenty original receipt controls, nine bootstrap diagnostics and eleven metadata authentication controls execute without skip'
	);
}

// These independent parser/API controls do not qualify native Shortcuts invocation.
{
	const controls = spawnSync(
		process.execPath,
		['tools/diagnostics/apple_shortcuts_probe/test_probe.cjs'],
		{
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000
		}
	);
	check(
		!controls.error && controls.signal === null && controls.status === 0,
		'Shortcuts structured API controls complete'
	);
	check(
		/Controlled JXA cases: 13 passed, 0 failed; native execution untested/.test(controls.stdout),
		'all thirteen independent Shortcuts API controls execute'
	);
	const parser = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		[
			'-m',
			'unittest',
			'discover',
			'-s',
			'tools/diagnostics/apple_shortcuts_probe',
			'-p',
			'test_probe.py'
		],
		{
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	check(
		!parser.error && parser.signal === null && parser.status === 0,
		'Shortcuts parser and owned registration controls complete'
	);
	check(
		/Ran 35 tests in /.test(parser.stderr) && /\nOK\s*$/.test(parser.stderr),
		'all eighteen original, twelve same-principal, three failure-refinement and two budget controls execute without skip'
	);
	const parserSource = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/apple_shortcuts_probe/test_probe.py'),
		'utf8'
	);
	const originalControls =
		parserSource.split('class PermissionPreflightControls(')[0].trimEnd() + '\n';
	check(
		require('node:crypto').createHash('sha256').update(originalControls).digest('hex') ===
			'df1903edc2398f0a5385f2bdc9c8217850ce4a0b9d346977070013c589e81074',
		'all eighteen original Shortcuts control bodies remain byte-exact'
	);
}

// Portable signed-query protocol/provenance references run on every host.
// Actual nonreaping pipe controls and native Swift/SB execution are Darwin CI-owned.
{
	const reference = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		['-m', 'unittest', 'test_signed_query_probe.ProtocolControls'],
		{
			cwd: path.join(ROOT, 'tools', 'diagnostics', 'program_actions'),
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	check(
		!reference.error && reference.signal === null && reference.status === 0,
		'signed-query protocol/provenance controls complete'
	);
	check(
		/Ran 9 tests in /.test(reference.stderr) && /\nOK\s*$/.test(reference.stderr),
		'all nine independent signed-query references execute without skip'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] action picker parameter editor:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] the picker edits a text, a key, a shortcut and a prompt choice, validates them as the drivers do, and reopens the current action.\x1b[0m'
);
