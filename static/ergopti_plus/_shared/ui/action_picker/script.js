// _shared/ui/action_picker/script.js

/**
 * ==============================================================================
 * MODULE: Action Picker UI Script
 * DESCRIPTION:
 * Renders a searchable, foldable, multi-level action list and reports the chosen
 * action back to the native host. The host (AHK WebView2 or macOS WKWebView)
 * pushes the catalogue via init() as an ordered `items` list of headings
 * ({type:"heading",level,text}) and actions ({type:"action",id,label}); the page
 * posts {action:'confirm',id} on a pick and {action:'cancel'} on dismiss.
 *
 * An action may carry `disabled: true` and a `hint` when the host has proven
 * that this machine cannot run it (a missing tool, the wrong session). The row
 * stays visible and greyed with its reason instead of vanishing — a row that
 * disappears reads as a bug — and it can be neither highlighted nor confirmed.
 *
 * UX: type to filter, ↑/↓ to move the highlight, Enter to confirm, Esc to cancel,
 * click a row to pick it. Headings render as h1/h2/h3… by their level, fold their
 * descendants on click, and a table-of-contents button jumps to any heading.
 *
 * An action whose `parameter` is text, key or shortcut is not confirmed at once:
 * the page opens its own editor (a text field, a key capture, a shortcut
 * capture), validates the value with the drivers' rules over the vocabulary the
 * host passes (`sendVocabulary`), and posts {action:'confirm',id,parameter}.
 * An llm_prompt action opens a choice of prompt profile and prediction count,
 * from the list the host passes (`promptChoices`, `defaultCount`), and posts
 * "<profile_id>" or "<profile_id>|<count>". An llm_vision action opens a choice
 * of vision backend (`visionChoices`: {value, label, defaultModel}) and an
 * optional model name, and posts "<backend>" or "<backend>|<model>". An
 * llm_language action opens a choice of target language (`languageChoices`:
 * {value, label}, the interface language first) and posts its value.
 * Other kinds (a URL, a wrap pair) confirm without one and keep the host's own
 * prompt.
 *
 * When the current action takes a parameter, an "edit" button reopens it
 * directly: its own editor for the kinds above, the host's prompt otherwise.
 * ==============================================================================
 */

// ============================================================
// 1/ Host-agnostic bridge
// ============================================================

var post = makeHostBridge('action_picker_bridge');

function doConfirm(id) {
	if (id === '' || id === undefined || id === null) return;
	if (!isConfirmable(id)) return;
	const entry = findActionEntry(id);
	if (canEdit(entry)) {
		openParamEditor(entry);
		return;
	}
	post({ action: 'confirm', id: id });
}

function doCancel() {
	post({ action: 'cancel' });
}

// ============================================================
// 2/ State
// ============================================================

// Ordered entries: specials first ({kind:'action',special:true}), then the
// host's items as {kind:'heading',level,text} / {kind:'action',id,label,disabled,hint}.
let entries = [];

// Heading entry-indices the user has collapsed (folded). Survives re-render.
const collapsed = new Set();

// Visible (rendered + focusable) action rows in display order: {id, el}.
let visible = [];
let activeIndex = 0;

let currentId = 'none';
let strings = { noResults: 'No matching action' };

function el(id) {
	return document.getElementById(id);
}

// ============================================================
// 3/ Init (host -> page)
// ============================================================

function init(data) {
	data = data || {};
	strings.noResults = data.noResults || 'No matching action';

	el('title').textContent = data.title || '';
	el('subtitle').textContent = data.label || '';
	el('search').placeholder = data.searchPlaceholder || '';
	el('btn-cancel').textContent = data.cancelLabel || 'Cancel';

	currentId = data.current;
	if (currentId === '' || currentId === undefined || currentId === null) {
		currentId = data.allowNative ? '__native__' : 'none';
	}

	// The parameter editor needs all three; without them every action confirms
	// at once and the host asks for the value itself.
	sendVocabulary = data.sendVocabulary || null;
	hostPlatform = data.platform || '';
	paramStrings = data.parameterStrings || null;
	programProviders = data.programProviders || null;
	programProviderStrings = data.programProviderStrings || {};
	promptChoices = Array.isArray(data.promptChoices) ? data.promptChoices : null;
	defaultCount = typeof data.defaultCount === 'number' ? data.defaultCount : null;
	visionChoices = Array.isArray(data.visionChoices) ? data.visionChoices : null;
	languageChoices = Array.isArray(data.languageChoices) ? data.languageChoices : null;
	if (paramStrings) {
		el('param-back').textContent = paramStrings.back || '';
		el('param-save').textContent = paramStrings.save || '';
		el('param-profile-label').textContent = paramStrings.promptLabel || '';
		el('param-count-label').textContent = paramStrings.countLabel || '';
		el('param-vision-provider-label').textContent = paramStrings.visionProviderLabel || '';
		el('param-vision-model-label').textContent = paramStrings.visionModelLabel || '';
		el('param-language-label').textContent = paramStrings.languageLabel || '';
		el('param-program-executable-label').textContent = paramStrings.programExecutableLabel || '';
		el('param-program-arguments-label').textContent = paramStrings.programArgumentsLabel || '';
		el('param-program-add').textContent = paramStrings.programAddLabel || '';
	}
	if (editing) closeParamEditor();

	entries = [];
	if (data.allowNative) {
		entries.push({
			kind: 'action',
			id: '__native__',
			label: data.nativeLabel || '',
			special: true
		});
	}
	entries.push({ kind: 'action', id: 'none', label: data.noneLabel || '', special: true });
	(data.items || []).forEach(function (it) {
		if (it.type === 'heading') {
			entries.push({ kind: 'heading', level: it.level || 1, text: it.text || '' });
		} else if (it.type === 'action') {
			entries.push({
				kind: 'action',
				id: it.id,
				label: it.label,
				special: false,
				disabled: it.disabled === true,
				hint: it.hint || '',
				parameter: it.parameter || '',
				parameterValue: typeof it.parameterValue === 'string' ? it.parameterValue : ''
			});
		}
	});

	collapsed.clear();
	render();
	updateEditCurrent(data.editCurrentLabel || '');
	focusSearch();
}

// The current action, when it takes a parameter the user may want to change.
function editableCurrent() {
	const entry = findActionEntry(currentId);
	if (!entry || entry.special || entry.disabled || !entry.parameter) return null;
	return entry;
}

function updateEditCurrent(label) {
	const button = el('btn-edit-current');
	const entry = editableCurrent();
	button.textContent = label;
	button.hidden = entry === null || label === '';
}

// Reopens the current action's parameter: the page's editor when it has one,
// otherwise a confirm, which makes the host ask for the value again.
function editCurrent() {
	const entry = editableCurrent();
	if (!entry) return;
	if (canEdit(entry)) {
		openParamEditor(entry);
		return;
	}
	post({ action: 'confirm', id: entry.id });
}

function focusSearch() {
	const s = el('search');
	if (!s) return;
	s.focus();
	setTimeout(function () {
		s.focus();
	}, 60);
}

// ============================================================
// 4/ Heading / ancestor helpers
// ============================================================

// Indices (into `entries`) of the heading ancestors enclosing entry `i`: the
// chain of headings with strictly increasing level that contain it.
function ancestorsOf(i) {
	const stack = [];
	for (let j = 0; j < i; j++) {
		const e = entries[j];
		if (e.kind !== 'heading') continue;
		while (stack.length && entries[stack[stack.length - 1]].level >= e.level) stack.pop();
		stack.push(j);
	}
	// Drop any trailing headings that are siblings (level >= entries[i].level when i is a heading).
	if (entries[i] && entries[i].kind === 'heading') {
		while (stack.length && entries[stack[stack.length - 1]].level >= entries[i].level) stack.pop();
	}
	return stack;
}

// Whether any ancestor heading of entry `i` is currently collapsed.
function hiddenByFold(i) {
	const anc = ancestorsOf(i);
	for (const h of anc) if (collapsed.has(h)) return true;
	return false;
}

// ============================================================
// 5/ Rendering
// ============================================================

function render() {
	const list = el('list');
	list.innerHTML = '';
	visible = [];

	const q = el('search').value.trim().toLowerCase();
	const searching = q !== '';

	// When searching, mark headings that have at least one matching descendant.
	const headingHasMatch = new Set();
	if (searching) {
		const stack = [];
		for (let i = 0; i < entries.length; i++) {
			const e = entries[i];
			if (e.kind === 'heading') {
				while (stack.length && entries[stack[stack.length - 1]].level >= e.level) stack.pop();
				stack.push(i);
			} else if (matches(e, q)) {
				for (const h of stack) headingHasMatch.add(h);
			}
		}
	}

	let curLevel = 0; // depth of the last rendered heading → indent of its actions
	for (let i = 0; i < entries.length; i++) {
		const e = entries[i];
		if (e.kind === 'heading') {
			if (searching) {
				if (!headingHasMatch.has(i)) continue;
			} else if (hiddenByFold(i)) {
				continue;
			}
			curLevel = Math.min(e.level, 4);
			list.appendChild(buildHeadingRow(i, e));
		} else {
			if (searching) {
				if (!matches(e, q)) continue;
			} else if (hiddenByFold(i)) {
				continue;
			}
			const row = buildActionRow(e, e.special ? 0 : curLevel);
			list.appendChild(row);
			// A greyed row is shown but never focusable, so neither the arrows nor
			// Enter can land on an action this machine cannot run.
			if (!e.disabled) visible.push({ id: e.id, el: row });
		}
	}

	el('empty').hidden = visible.length > 0;
	if (!el('empty').hidden) el('empty').textContent = strings.noResults;
	el('count').textContent = visible.length ? String(visible.length) : '';

	let start = 0;
	for (let k = 0; k < visible.length; k++) {
		if (visible[k].id === currentId) {
			start = k;
			break;
		}
	}
	if (visible.length) setActive(start, true);
}

function matches(actionEntry, q) {
	return (actionEntry.label || '').toLowerCase().indexOf(q) !== -1;
}

// The action entry an id names, or null.
function findActionEntry(id) {
	for (let i = 0; i < entries.length; i++) {
		if (entries[i].kind === 'action' && entries[i].id === id) return entries[i];
	}
	return null;
}

// Whether an id may be confirmed: known to the list and not greyed out.
function isConfirmable(id) {
	for (let i = 0; i < entries.length; i++) {
		const e = entries[i];
		if (e.kind === 'action' && e.id === id) return !e.disabled;
	}
	return false;
}

function buildHeadingRow(i, e) {
	const row = document.createElement('div');
	const lvl = Math.min(e.level, 4);
	row.className = 'heading lvl' + lvl + (collapsed.has(i) ? ' collapsed' : '');
	row.style.paddingLeft = 8 + (lvl - 1) * 16 + 'px';

	const caret = document.createElement('span');
	caret.className = 'caret';
	caret.textContent = '▾';
	const txt = document.createElement('span');
	txt.className = 'heading-text';
	txt.textContent = e.text;
	row.appendChild(caret);
	row.appendChild(txt);

	// Folding is a fold of the live tree, so it is disabled while searching
	// (search already expands only the relevant matches).
	const searching = el('search').value.trim() !== '';
	if (!searching) {
		row.addEventListener('click', function () {
			toggleFold(i);
		});
	} else {
		row.classList.add('static');
	}
	return row;
}

function buildActionRow(e, depth) {
	const row = document.createElement('div');
	row.className =
		'row' +
		(e.special ? ' special' : '') +
		(e.id === currentId ? ' current' : '') +
		(e.disabled ? ' disabled' : '');
	row.dataset.id = e.id;
	row.style.paddingLeft = 12 + (depth || 0) * 16 + 'px';

	const tick = document.createElement('span');
	tick.className = 'row-tick';
	tick.textContent = '✓';
	const label = document.createElement('span');
	label.className = 'row-label';
	label.textContent = e.label;
	row.appendChild(tick);
	row.appendChild(label);
	if (e.hint) {
		const hint = document.createElement('span');
		hint.className = 'row-hint';
		hint.textContent = e.hint;
		row.appendChild(hint);
		row.title = e.hint;
	}
	if (e.disabled) {
		row.setAttribute('aria-disabled', 'true');
		return row;
	}

	const idx = visible.length;
	row.addEventListener('click', function () {
		doConfirm(e.id);
	});
	row.addEventListener('mousemove', function () {
		setActive(idx);
	});
	return row;
}

function setActive(idx, instant) {
	if (idx < 0 || idx >= visible.length) return;
	if (visible[activeIndex] && visible[activeIndex].el) {
		visible[activeIndex].el.classList.remove('active');
	}
	activeIndex = idx;
	const row = visible[activeIndex].el;
	row.classList.add('active');
	row.scrollIntoView({ block: 'nearest' });
}

function toggleFold(i) {
	if (collapsed.has(i)) collapsed.delete(i);
	else collapsed.add(i);
	render();
}

// ============================================================
// 6/ Table of contents
// ============================================================

function toggleToc() {
	const toc = el('toc');
	if (toc.hidden) {
		buildToc();
		toc.hidden = false;
	} else {
		toc.hidden = true;
	}
}

function buildToc() {
	const inner = el('toc-inner');
	inner.innerHTML = '';
	for (let i = 0; i < entries.length; i++) {
		const e = entries[i];
		if (e.kind !== 'heading') continue;
		const lvl = Math.min(e.level, 4);
		const a = document.createElement('div');
		a.className = 'toc-item lvl' + lvl;
		a.style.paddingLeft = 10 + (lvl - 1) * 16 + 'px';
		a.textContent = e.text;
		a.addEventListener('click', function () {
			tocGoto(i);
		});
		inner.appendChild(a);
	}
}

function tocGoto(i) {
	// Expand every ancestor so the heading is visible, then scroll to it.
	for (const h of ancestorsOf(i)) collapsed.delete(h);
	el('search').value = '';
	el('toc').hidden = true;
	render();
	// Find the heading row by re-walking; headings carry no id, so match by order.
	const rows = el('list').children;
	let seen = -1;
	for (let r = 0; r < rows.length; r++) {
		if (rows[r].classList.contains('heading')) {
			seen++;
			if (headingDomToEntry(seen) === i) {
				rows[r].scrollIntoView({ block: 'start' });
				break;
			}
		}
	}
}

// Maps the Nth rendered heading (DOM order) back to its entry index. Rebuilt
// each call from the current fold state so it always matches what is on screen.
function headingDomToEntry(nth) {
	let seen = -1;
	for (let i = 0; i < entries.length; i++) {
		if (entries[i].kind !== 'heading') continue;
		if (hiddenByFold(i)) continue;
		seen++;
		if (seen === nth) return i;
	}
	return -1;
}

// ============================================================
// 7/ Parameter editor (send_text, send_key, send_shortcut)
// ============================================================

// The parameter kinds this page edits itself. Every other kind is left to the
// host's own prompt, which receives a confirm without a `parameter`.
const EDITABLE_KINDS = new Set([
	'text',
	'key',
	'shortcut',
	'llm_prompt',
	'llm_vision',
	'llm_language',
	'program'
]);
const SEND_INPUT_KINDS = new Set(['text', 'key', 'shortcut']);

// Host-supplied: the decoded _shared/modules/actions/send_keys.json, the
// host's platform ("hs" makes Command the primary modifier), and the localized
// strings of the editor ({ save, back, captureKey, captureShortcut, prompts:
// {kind: text}, errors: {kind: text} }). All three are required to edit.
let sendVocabulary = null;
let hostPlatform = '';
let paramStrings = null;
let programProviders = null;
let programProviderStrings = {};

// Host-supplied for llm_prompt: the prompt profiles a binding may run
// ([{value: id, label}], built-in then custom) and the AI menu's prediction
// count, offered as the default.
let promptChoices = null;
let defaultCount = null;

// Host-supplied for llm_vision: the vision backends a binding may use
// ([{value: id, label, defaultModel}], defaultModel "" when it needs one).
let visionChoices = null;

// Host-supplied for llm_language: the target languages a binding may name
// ([{value, label}]: "ui" for the interface language, then every locale).
let languageChoices = null;

// The entry being edited, or null while the list is shown.
let editing = null;

const TRIM = /^[ \t\r\n\v\f]+|[ \t\r\n\v\f]+$/g;
const asciiLower = (text) => text.replace(/[A-Z]/g, (c) => c.toLowerCase());
const isControl = (code) => code <= 0x1f || (code >= 0x7f && code <= 0x9f);

function findVocabularyEntry(entries, wanted) {
	for (const entry of entries) {
		// A Lua host may encode an empty alias list as {}, which is no array.
		const aliases = Array.isArray(entry.aliases) ? entry.aliases : [];
		if (entry.id === wanted || aliases.indexOf(wanted) !== -1) return entry;
	}
	return null;
}

// The rules pinned by _shared/tests/corpus/action_parameters/send_input_vectors.json,
// which tools/test/test-action-picker-parameter-editor.cjs replays against this
// page: the drivers validate again, this only spares the user a round trip.
function parseSendText(value) {
	const points = Array.from(value);
	if (points.length === 0 || points.length > sendVocabulary.text_max_code_points) return null;
	for (const point of points) if (isControl(point.codePointAt(0))) return null;
	return value;
}

function parseSendKey(value, lowerLetter) {
	const wanted = value.replace(TRIM, '');
	if (wanted === '') return null;
	const entry = findVocabularyEntry(sendVocabulary.keys, asciiLower(wanted));
	if (entry) return entry.id;
	const points = Array.from(wanted);
	if (points.length !== 1 || isControl(points[0].codePointAt(0))) return null;
	return lowerLetter ? asciiLower(wanted) : wanted;
}

function parseSendShortcut(value) {
	const wanted = value.replace(TRIM, '');
	if (wanted === '') return null;
	let keyToken;
	let modTokens;
	if (wanted.length >= 2 && wanted.endsWith('++')) {
		keyToken = '+';
		modTokens = wanted.slice(0, -2).split('+');
	} else {
		modTokens = wanted.split('+');
		keyToken = modTokens.pop();
	}
	if (modTokens.length === 0) return null;
	const held = new Set();
	for (const token of modTokens) {
		const entry = findVocabularyEntry(
			sendVocabulary.modifiers,
			asciiLower(token.replace(TRIM, ''))
		);
		if (!entry || held.has(entry.id)) return null;
		held.add(entry.id);
	}
	const key = parseSendKey(keyToken, true);
	if (key === null) return null;
	const mods = sendVocabulary.modifiers
		.filter((entry) => held.has(entry.id))
		.map((entry) => entry.id);
	return mods.concat([key]).join('+');
}

// The rules pinned by _shared/tests/corpus/action_parameters/llm_prompt_vectors.json:
// "<profile_id>" or "<profile_id>|<count>", the count from 1 to 10.
const LLM_PROMPT_MAX_ID_LENGTH = 128;
const LLM_PROMPT_MIN_PREDICTIONS = 1;
const LLM_PROMPT_MAX_PREDICTIONS = 10;

// {profileId, numPredictions (null = the menu's count)}, or null when invalid.
function parseLlmPrompt(value) {
	const parts = value.split('|');
	if (parts.length > 2) return null;
	const profileId = parts[0];
	if (profileId === '' || profileId.length > LLM_PROMPT_MAX_ID_LENGTH) return null;
	if (!/^[A-Za-z0-9_-]+$/.test(profileId)) return null;
	if (parts.length === 1) return { profileId: profileId, numPredictions: null };
	if (!/^[0-9]+$/.test(parts[1])) return null;
	const count = Number(parts[1]);
	if (count < LLM_PROMPT_MIN_PREDICTIONS || count > LLM_PROMPT_MAX_PREDICTIONS) return null;
	return { profileId: profileId, numPredictions: count };
}

// The rules pinned by _shared/tests/corpus/llm/vision_vectors.json:
// "<backend>" or "<backend>|<model>", the model 1 to 200 characters with no
// control character, no | and no spacing at either end.
const LLM_VISION_MAX_MODEL_LENGTH = 200;

// {backend, model (null = the backend's default)}, or null when invalid.
function parseLlmVision(value) {
	const parts = value.split('|');
	if (parts.length > 2) return null;
	if (!/^[a-z][a-z0-9_]*$/.test(parts[0])) return null;
	if (parts.length === 1) return { backend: parts[0], model: null };
	const model = parts[1];
	if (model === '' || Array.from(model).length > LLM_VISION_MAX_MODEL_LENGTH) return null;
	if (/[\u0000-\u001f\u007f]/.test(model) || /^\s|\s$/.test(model)) return null;
	return { backend: parts[0], model: model };
}

// Canonical form of a value, or null when invalid.
function parseParameter(kind, value) {
	if (typeof value !== 'string') return null;
	if (kind === 'program')
		return ProgramParameter.parse(value, hostPlatform) === null ? null : value;
	if (kind === 'text') return parseSendText(value);
	if (kind === 'key') return parseSendKey(value, false);
	if (kind === 'shortcut') return parseSendShortcut(value);
	if (kind === 'llm_prompt') return parseLlmPrompt(value) === null ? null : value;
	if (kind === 'llm_vision') return parseLlmVision(value) === null ? null : value;
	if (kind === 'llm_language')
		return languageChoices !== null && findLanguageChoice(value) !== null ? value : null;
	return null;
}

// KeyboardEvent.key values of the keys send_keys.json names.
const NAMED_KEYS = {
	Enter: 'enter',
	Tab: 'tab',
	Escape: 'escape',
	Backspace: 'backspace',
	Delete: 'delete',
	Insert: 'insert',
	' ': 'space',
	ArrowUp: 'up',
	ArrowDown: 'down',
	ArrowLeft: 'left',
	ArrowRight: 'right',
	Home: 'home',
	End: 'end',
	PageUp: 'page_up',
	PageDown: 'page_down'
};
const MODIFIER_KEYS = new Set(['Shift', 'Control', 'Alt', 'Meta', 'AltGraph', 'OS', 'CapsLock']);

// The vocabulary name of a named or function key, or null.
function namedKey(e) {
	if (NAMED_KEYS[e.key]) return NAMED_KEYS[e.key];
	if (/^F([1-9]|1[0-9]|20)$/.test(e.key)) return e.key.toLowerCase();
	return null;
}

// The key of a captured shortcut: a named key, else the character. Letters and
// digits come from the physical code, so Shift+A captures "a" (and the shift)
// rather than "A".
function shortcutKeyToken(e) {
	const named = namedKey(e);
	if (named) return named;
	if (/^Key[A-Z]$/.test(e.code || '')) return e.code.slice(3).toLowerCase();
	if (/^Digit[0-9]$/.test(e.code || '')) return e.code.slice(5);
	if (typeof e.key === 'string' && Array.from(e.key).length === 1) return e.key;
	return null;
}

// The shortcut a keydown captures, in canonical order, or null for a lone
// modifier or a key with no modifier held.
function captureShortcut(e) {
	if (MODIFIER_KEYS.has(e.key)) return null;
	const mods = [];
	const commandIsPrimary = hostPlatform === 'hs';
	if (commandIsPrimary ? e.metaKey : e.ctrlKey) mods.push('primary');
	if (commandIsPrimary && e.ctrlKey) mods.push('ctrl');
	if (e.altKey) mods.push('alt');
	if (e.shiftKey) mods.push('shift');
	if (!commandIsPrimary && e.metaKey) mods.push('super');
	if (mods.length === 0) return null;
	const key = shortcutKeyToken(e);
	return key === null ? null : mods.concat([key]).join('+');
}

function canEdit(entry) {
	if (!entry || !EDITABLE_KINDS.has(entry.parameter) || paramStrings === null) return false;
	if (entry.parameter === 'program') return typeof ProgramParameter === 'object';
	if (entry.parameter === 'llm_prompt')
		return promptChoices !== null && promptChoices.length > 0 && defaultCount !== null;
	if (entry.parameter === 'llm_vision') return visionChoices !== null && visionChoices.length > 0;
	if (entry.parameter === 'llm_language')
		return languageChoices !== null && languageChoices.length > 0;
	return SEND_INPUT_KINDS.has(entry.parameter) && sendVocabulary !== null;
}

function appendOption(select, value, label) {
	const option = document.createElement('option');
	option.value = value;
	option.textContent = label;
	select.appendChild(option);
}

// Fills the prompt and count choices, selecting the binding's current value;
// a value naming a deleted prompt starts from the first prompt instead.
function fillPromptChoices(value) {
	const current = parseLlmPrompt(value || '');
	const profile = el('param-profile');
	const count = el('param-count');
	profile.innerHTML = '';
	count.innerHTML = '';
	let selected = promptChoices[0].value;
	for (const choice of promptChoices) {
		appendOption(profile, choice.value, choice.label);
		if (current && choice.value === current.profileId) selected = choice.value;
	}
	profile.value = selected;
	const defaultLabel = (paramStrings.countDefault || '{1}').replace('{1}', String(defaultCount));
	appendOption(count, '', defaultLabel);
	for (let n = LLM_PROMPT_MIN_PREDICTIONS; n <= LLM_PROMPT_MAX_PREDICTIONS; n++)
		appendOption(count, String(n), String(n));
	count.value = current && current.numPredictions !== null ? String(current.numPredictions) : '';
}

// The vision choice an id names, or null.
function findVisionChoice(value) {
	for (const choice of visionChoices) if (choice.value === value) return choice;
	return null;
}

// Shows the selected backend's default model, or that it needs one.
function updateVisionModelHint() {
	const choice = findVisionChoice(el('param-vision-provider').value);
	el('param-vision-model').placeholder =
		choice && choice.defaultModel
			? (paramStrings.visionModelDefault || '{1}').replace('{1}', choice.defaultModel)
			: paramStrings.visionModelRequired || '';
}

// Fills the backend choices and the model field from the binding's value.
function fillVisionChoices(value) {
	const current = parseLlmVision(value || '');
	const provider = el('param-vision-provider');
	provider.innerHTML = '';
	let selected = visionChoices[0].value;
	for (const choice of visionChoices) {
		appendOption(provider, choice.value, choice.label);
		if (current && choice.value === current.backend) selected = choice.value;
	}
	provider.value = selected;
	el('param-vision-model').value = current && current.model !== null ? current.model : '';
	updateVisionModelHint();
}

// The value the vision choices describe, or null when a needed model is missing.
function visionChoiceValue() {
	const backend = el('param-vision-provider').value;
	const model = el('param-vision-model').value.replace(TRIM, '');
	if (model !== '') return backend + '|' + model;
	const choice = findVisionChoice(backend);
	return choice && choice.defaultModel ? backend : null;
}

// The language choice a value names, or null.
function findLanguageChoice(value) {
	for (const choice of languageChoices) if (choice.value === value) return choice;
	return null;
}

// Fills the target languages, selecting the binding's value; a value naming
// no offered language starts from the first choice (the interface language).
function fillLanguageChoices(value) {
	const select = el('param-language-select');
	select.innerHTML = '';
	for (const choice of languageChoices) appendOption(select, choice.value, choice.label);
	select.value = findLanguageChoice(value || '') !== null ? value : languageChoices[0].value;
}

// The value the prompt choices describe.
function promptChoiceValue() {
	const count = el('param-count').value;
	return count === '' ? el('param-profile').value : el('param-profile').value + '|' + count;
}

function openParamEditor(entry) {
	editing = entry;
	const choosing = entry.parameter === 'llm_prompt';
	const vision = entry.parameter === 'llm_vision';
	const language = entry.parameter === 'llm_language';
	const program = entry.parameter === 'program';
	el('param-title').textContent = entry.label;
	el('param-prompt').textContent =
		choosing || vision || language ? '' : (paramStrings.prompts || {})[entry.parameter] || '';
	el('param-hint').textContent =
		entry.parameter === 'key'
			? paramStrings.captureKey
			: entry.parameter === 'shortcut'
				? paramStrings.captureShortcut
				: '';
	el('param-error').hidden = true;
	el('param-input').hidden = choosing || vision || language || program;
	el('param-choice').hidden = !choosing;
	el('param-vision').hidden = !vision;
	el('param-language').hidden = !language;
	el('param-program').hidden = !program;
	el('param').hidden = false;
	el('list').hidden = true;
	el('search-bar').hidden = true;
	if (program) {
		const current = ProgramParameter.parse(entry.parameterValue || '', hostPlatform);
		el('param-program-executable').value = current === null ? '' : current.executable;
		el('param-program-arguments').replaceChildren();
		for (const argument of current === null ? [] : current.arguments)
			appendProgramArgument(argument);
		fillProgramProviders();
		el('param-program-executable').focus();
		return;
	}
	if (choosing) {
		fillPromptChoices(entry.parameterValue);
		el('param-profile').focus();
		return;
	}
	if (vision) {
		fillVisionChoices(entry.parameterValue);
		el('param-vision-provider').focus();
		return;
	}
	if (language) {
		fillLanguageChoices(entry.parameterValue);
		el('param-language-select').focus();
		return;
	}
	el('param-input').value = entry.parameterValue || '';
	el('param-input').focus();
	// Selected, the current value is replaced by the first key typed or captured.
	el('param-input').select();
}

// Discovery keys stay opaque: only the owning native session can resolve them.
function fillProgramProviders() {
	const container = el('param-program-provider');
	container.hidden = programProviders === null;
	el('param-program-executable').hidden = false;
	el('param-program-executable-label').hidden = false;
	if (programProviders === null) return;
	const select = el('param-program-provider-select');
	select.replaceChildren();
	const manual = document.createElement('option');
	manual.value = '';
	manual.textContent = programProviderStrings.manual || '';
	select.appendChild(manual);
	for (const choice of Array.isArray(programProviders.choices) ? programProviders.choices : []) {
		if (typeof choice.key !== 'string' || typeof choice.label !== 'string') continue;
		const option = document.createElement('option');
		option.value = choice.key;
		option.textContent = choice.label;
		select.appendChild(option);
	}
	select.value = '';
	el('param-program-provider-label').textContent = programProviderStrings.label || '';
	el('param-program-provider-hint').textContent = programProviderStrings.hint || '';
	el('param-program-provider-status').textContent = programProviders.unavailable
		? programProviderStrings.unavailable || ''
		: programProviders.truncated
			? programProviderStrings.truncated || ''
			: select.children.length === 1
				? programProviderStrings.empty || ''
				: '';
	updateProgramProvider();
}

function updateProgramProvider() {
	const selected = programProviders !== null && el('param-program-provider-select').value !== '';
	el('param-program-executable').hidden = selected;
	el('param-program-executable-label').hidden = selected;
	el('param-error').hidden = true;
}

// Called only by the still-owned native page after a refused identity check.
function programProviderRefused() {
	if (!editing || editing.parameter !== 'program') return;
	el('param-error').textContent = programProviderStrings.changed || '';
	el('param-error').hidden = false;
}

function appendProgramArgument(value) {
	const row = document.createElement('div');
	row.className = 'program-argument';
	const input = document.createElement('textarea');
	input.value = value;
	input.spellcheck = false;
	input.setAttribute('aria-label', paramStrings.programArgumentsLabel || '');
	const remove = document.createElement('button');
	remove.type = 'button';
	remove.textContent = paramStrings.programRemoveLabel || '';
	remove.addEventListener('click', () => row.remove());
	row.append(input, remove);
	el('param-program-arguments').appendChild(row);
	return input;
}

function closeParamEditor() {
	editing = null;
	el('param').hidden = true;
	el('list').hidden = false;
	el('search-bar').hidden = false;
	focusSearch();
}

function saveParameter() {
	if (!editing) return;
	if (
		editing.parameter === 'program' &&
		programProviders !== null &&
		el('param-program-provider-select').value !== ''
	) {
		post({
			action: 'confirm',
			id: editing.id,
			providerKey: el('param-program-provider-select').value,
			programArguments: Array.from(
				el('param-program-arguments').querySelectorAll('textarea'),
				(input) => input.value
			)
		});
		return;
	}
	const value =
		editing.parameter === 'program'
			? ProgramParameter.encode(
					el('param-program-executable').value,
					Array.from(
						el('param-program-arguments').querySelectorAll('textarea'),
						(input) => input.value
					),
					hostPlatform
				)
			: editing.parameter === 'llm_prompt'
				? promptChoiceValue()
				: editing.parameter === 'llm_vision'
					? visionChoiceValue()
					: editing.parameter === 'llm_language'
						? el('param-language-select').value
						: el('param-input').value;
	if (value === null || parseParameter(editing.parameter, value) === null) {
		el('param-error').textContent = (paramStrings.errors || {})[editing.parameter] || '';
		el('param-error').hidden = false;
		return;
	}
	post({ action: 'confirm', id: editing.id, parameter: value });
}

// The keys that move or erase inside a field that holds text.
const FIELD_EDITING_KEYS = new Set([
	'Backspace',
	'Delete',
	'ArrowLeft',
	'ArrowRight',
	'Home',
	'End'
]);

function isAltGr(e) {
	return typeof e.getModifierState === 'function' && e.getModifierState('AltGraph') === true;
}

// Whether the next character typed replaces the whole value.
function fieldIsReplaced(input) {
	return (
		input.value === '' || (input.selectionStart === 0 && input.selectionEnd === input.value.length)
	);
}

function setCaptured(e, value) {
	e.preventDefault();
	const input = el('param-input');
	input.value = value;
	input.select();
	el('param-error').hidden = true;
}

// A key capture that still lets the user type a name (F13 to F20 exist on few
// keyboards). A character types itself, and is a valid key as it is. A named
// key is captured, except that while the field holds text the editing keys
// edit it and Enter saves it: an empty field captures every one of them.
function onKeyCaptureKeydown(e, input) {
	if ((e.ctrlKey && !isAltGr(e)) || e.metaKey) return;
	const named = namedKey(e);
	if (!named) return;
	if (input.value !== '' && FIELD_EDITING_KEYS.has(e.key)) return;
	if (input.value !== '' && e.key === 'Enter') {
		e.preventDefault();
		saveParameter();
		return;
	}
	setCaptured(e, named);
}

// A shortcut capture that still lets the user type one: a chord with Control,
// Alt or Command is always captured; Shift alone is captured with a named key,
// or with a character when it would replace the value, and otherwise types
// that character ("+", a capital). AltGr types.
function onShortcutCaptureKeydown(e, input) {
	if (MODIFIER_KEYS.has(e.key)) return;
	const named = namedKey(e) !== null;
	const chord = (e.ctrlKey || e.altKey || e.metaKey) && !isAltGr(e);
	if (chord || (e.shiftKey && (named || fieldIsReplaced(input)))) {
		const captured = captureShortcut(e);
		if (captured !== null) setCaptured(e, captured);
		return;
	}
	onPlainEditorKeydown(e, input);
}

// Enter saves a value and Escape returns to the list.
function onPlainEditorKeydown(e, input) {
	if (e.key === 'Enter' && input.value !== '') {
		e.preventDefault();
		saveParameter();
	} else if (e.key === 'Escape') {
		e.preventDefault();
		closeParamEditor();
	}
}

// Every key belongs to the editor while it is open. Returns whether it is.
function onParamKeydown(e) {
	if (!editing) return false;
	const input = el('param-input');
	if (editing.parameter === 'program') {
		if (e.key === 'Escape') {
			e.preventDefault();
			closeParamEditor();
		}
	} else if (editing.parameter === 'key') onKeyCaptureKeydown(e, input);
	else if (editing.parameter === 'shortcut') onShortcutCaptureKeydown(e, input);
	else if (
		editing.parameter === 'llm_prompt' ||
		editing.parameter === 'llm_vision' ||
		editing.parameter === 'llm_language'
	)
		onChoiceEditorKeydown(e);
	else onPlainEditorKeydown(e, input);
	return true;
}

// The choices always hold a valid value, so Enter saves it; the arrows keep
// moving inside the focused list.
function onChoiceEditorKeydown(e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		saveParameter();
	} else if (e.key === 'Escape') {
		e.preventDefault();
		closeParamEditor();
	}
}

// ============================================================
// 8/ Events
// ============================================================

document.addEventListener('DOMContentLoaded', function () {
	el('search').addEventListener('input', function () {
		render();
	});
	el('param-back').addEventListener('click', function () {
		closeParamEditor();
	});
	el('param-program-add').addEventListener('click', function () {
		appendProgramArgument('').focus();
	});
	el('param-program-provider-select').addEventListener('change', updateProgramProvider);
	el('param-save').addEventListener('click', function () {
		saveParameter();
	});
	el('btn-edit-current').addEventListener('click', function () {
		editCurrent();
	});
	el('param-vision-provider').addEventListener('change', function () {
		updateVisionModelHint();
	});

	document.addEventListener('keydown', function (e) {
		// While a value is being edited every key belongs to the editor: Escape
		// and Enter can be keys to capture there, never a cancel or a pick.
		if (onParamKeydown(e)) return;
		if (e.key === 'ArrowDown') {
			e.preventDefault();
			if (visible.length) setActive((activeIndex + 1) % visible.length);
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			if (visible.length) setActive((activeIndex - 1 + visible.length) % visible.length);
		} else if (e.key === 'Enter') {
			e.preventDefault();
			if (visible.length && visible[activeIndex]) doConfirm(visible[activeIndex].id);
		} else if (e.key === 'Escape') {
			e.preventDefault();
			if (!el('toc').hidden) {
				el('toc').hidden = true;
				return;
			}
			doCancel();
		}
	});

	post({ action: 'ready' });
});
