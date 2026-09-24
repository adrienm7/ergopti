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
 * Other kinds (a URL, a wrap pair) confirm without one and keep the host's own
 * prompt.
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
	if (paramStrings) {
		el('param-back').textContent = paramStrings.back || '';
		el('param-save').textContent = paramStrings.save || '';
	}
	if (editing) closeParamEditor();

	entries = [];
	if (data.allowNative) {
		entries.push({ kind: 'action', id: '__native__', label: data.nativeLabel || '', special: true });
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
	focusSearch();
}

function focusSearch() {
	const s = el('search');
	if (!s) return;
	s.focus();
	setTimeout(function () { s.focus(); }, 60);
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
		if (visible[k].id === currentId) { start = k; break; }
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
		row.addEventListener('click', function () { toggleFold(i); });
	} else {
		row.classList.add('static');
	}
	return row;
}

function buildActionRow(e, depth) {
	const row = document.createElement('div');
	row.className =
		'row' + (e.special ? ' special' : '') + (e.id === currentId ? ' current' : '') + (e.disabled ? ' disabled' : '');
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
	row.addEventListener('click', function () { doConfirm(e.id); });
	row.addEventListener('mousemove', function () { setActive(idx); });
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
		a.addEventListener('click', function () { tocGoto(i); });
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
const EDITABLE_KINDS = new Set(['text', 'key', 'shortcut']);

// Host-supplied: the decoded _shared/modules/actions/send_keys.json, the
// host's platform ("hs" makes Command the primary modifier), and the localized
// strings of the editor ({ save, back, captureKey, captureShortcut, prompts:
// {kind: text}, errors: {kind: text} }). All three are required to edit.
let sendVocabulary = null;
let hostPlatform = '';
let paramStrings = null;

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
		const entry = findVocabularyEntry(sendVocabulary.modifiers, asciiLower(token.replace(TRIM, '')));
		if (!entry || held.has(entry.id)) return null;
		held.add(entry.id);
	}
	const key = parseSendKey(keyToken, true);
	if (key === null) return null;
	const mods = sendVocabulary.modifiers.filter((entry) => held.has(entry.id)).map((entry) => entry.id);
	return mods.concat([key]).join('+');
}

// Canonical form of a value, or null when invalid.
function parseParameter(kind, value) {
	if (typeof value !== 'string') return null;
	if (kind === 'text') return parseSendText(value);
	if (kind === 'key') return parseSendKey(value, false);
	if (kind === 'shortcut') return parseSendShortcut(value);
	return null;
}

// KeyboardEvent.key values of the keys send_keys.json names.
const NAMED_KEYS = {
	Enter: 'enter', Tab: 'tab', Escape: 'escape', Backspace: 'backspace', Delete: 'delete',
	Insert: 'insert', ' ': 'space', ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left',
	ArrowRight: 'right', Home: 'home', End: 'end', PageUp: 'page_up', PageDown: 'page_down'
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
	return entry && EDITABLE_KINDS.has(entry.parameter) && sendVocabulary !== null && paramStrings !== null;
}

function openParamEditor(entry) {
	editing = entry;
	el('param-title').textContent = entry.label;
	el('param-prompt').textContent = (paramStrings.prompts || {})[entry.parameter] || '';
	el('param-hint').textContent = entry.parameter === 'key' ? paramStrings.captureKey
		: entry.parameter === 'shortcut' ? paramStrings.captureShortcut : '';
	el('param-input').value = entry.parameterValue || '';
	el('param-error').hidden = true;
	el('param').hidden = false;
	el('list').hidden = true;
	el('search-bar').hidden = true;
	el('param-input').focus();
	// Selected, the current value is replaced by the first key typed or captured.
	el('param-input').select();
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
	const value = el('param-input').value;
	if (parseParameter(editing.parameter, value) === null) {
		el('param-error').textContent = (paramStrings.errors || {})[editing.parameter] || '';
		el('param-error').hidden = false;
		return;
	}
	post({ action: 'confirm', id: editing.id, parameter: value });
}

// The keys that move or erase inside a field that holds text.
const FIELD_EDITING_KEYS = new Set(['Backspace', 'Delete', 'ArrowLeft', 'ArrowRight', 'Home', 'End']);

function isAltGr(e) {
	return typeof e.getModifierState === 'function' && e.getModifierState('AltGraph') === true;
}

// Whether the next character typed replaces the whole value.
function fieldIsReplaced(input) {
	return input.value === '' || (input.selectionStart === 0 && input.selectionEnd === input.value.length);
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
	if (editing.parameter === 'key') onKeyCaptureKeydown(e, input);
	else if (editing.parameter === 'shortcut') onShortcutCaptureKeydown(e, input);
	else onPlainEditorKeydown(e, input);
	return true;
}

// ============================================================
// 8/ Events
// ============================================================

document.addEventListener('DOMContentLoaded', function () {
	el('search').addEventListener('input', function () { render(); });
	el('param-back').addEventListener('click', function () { closeParamEditor(); });
	el('param-save').addEventListener('click', function () { saveParameter(); });

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
			if (!el('toc').hidden) { el('toc').hidden = true; return; }
			doCancel();
		}
	});

	post({ action: 'ready' });
});
