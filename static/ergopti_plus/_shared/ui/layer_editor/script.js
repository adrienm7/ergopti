// _shared/ui/layer_editor/script.js

/**
 * ==============================================================================
 * MODULE: Layer Editor UI Script
 * DESCRIPTION:
 * Draws the physical keyboard, numpad, mouse buttons and wheel of the
 * generated LAYER_EDITOR_DATA, lets the user pick what each one does while the
 * navigation layer is held, and hands the result to the native host as the
 * complete text of layers.toml. Every rule about the file lives in
 * layer_model.js; this file only renders and routes clicks.
 *
 * HOST PROTOCOL (bridge "layer_editor_bridge", same on the three drivers):
 *   page -> host  "ready"                        the page can take init()
 *                 {action: "save", text}         validate, write, apply
 *                 {action: "cancel"}             close without saving
 *   host -> page  init({os, path, text, errors}) the user's file, once
 *                 saveResult({saved, applied, errors})
 *
 * FEATURES & RATIONALE:
 * 1. Recommended vs custom: every key shows whether it does what Ergopti's
 *    recommended layer does on this OS, something else, or cannot be a layer
 *    key here at all (with the vocabulary's reason).
 * 2. The picker uses the shared action picker's item shape (headings and
 *    actions) over the layer vocabulary, plus the two parameterised forms: a
 *    repeat count and a keyboard shortcut.
 * 3. Nothing is written by the page: the host validates the text with its own
 *    loader for every OS and refuses anything they would not all read.
 * ==============================================================================
 */

// ============================
// ======= 1/ State ===========
// ============================

var post = makeHostBridge('layer_editor_bridge');
var DATA = LAYER_EDITOR_DATA;

var FORM_STORAGE_KEY = 'layer_editor.form';
var DEFAULT_FORM = 'iso';
// The gap between the function row and the rest, in key units.
var FUNCTION_ROW_GAP = 0.25;
var BOARD_ROWS = 6;

// Mouse buttons and wheel directions, by registry code, and their label keys.
var INPUT_LABEL_KEYS = {
	MouseLeft: 'layer_editor.input.mouse_left',
	MouseRight: 'layer_editor.input.mouse_right',
	MouseMiddle: 'layer_editor.input.mouse_middle',
	MouseBack: 'layer_editor.input.mouse_back',
	MouseForward: 'layer_editor.input.mouse_forward',
	WheelUp: 'layer_editor.input.wheel_up',
	WheelDown: 'layer_editor.input.wheel_down',
	WheelLeft: 'layer_editor.input.wheel_left',
	WheelRight: 'layer_editor.input.wheel_right'
};

var state = {
	os: null,
	path: '',
	form: DEFAULT_FORM,
	doc: { layers: {} },
	dirty: false,
	saving: false,
	closeArmed: false,
	selected: null,
	search: '',
	fileProblem: null,
	fileErrors: [],
	status: ''
};

function el(id) {
	return document.getElementById(id);
}

/**
 * Translates a key and fills its {1}, {2}… placeholders. A key the locale does
 * not know shows as itself, so a missing string is visible, not blank.
 */
function _t(key) {
	var strings = window._i18n_strings || {};
	var text = typeof strings[key] === 'string' ? strings[key] : key;
	for (var i = 1; i < arguments.length; i++)
		text = text.split('{' + i + '}').join(String(arguments[i]));
	return text;
}

function make(tag, className, text) {
	var node = document.createElement(tag);
	if (className) node.className = className;
	if (text !== undefined) node.textContent = text;
	return node;
}

function readStoredForm() {
	try {
		var stored = window.localStorage.getItem(FORM_STORAGE_KEY);
		return stored === 'iso' || stored === 'ansi' ? stored : DEFAULT_FORM;
	} catch (e) {
		return DEFAULT_FORM;
	}
}

function storeForm(form) {
	try {
		window.localStorage.setItem(FORM_STORAGE_KEY, form);
	} catch (e) {
		// The keyboard form is a per-viewer convenience: a blocked storage only
		// means the next window opens on the default form.
	}
}

// =================================
// ======= 2/ Host -> page =========
// =================================

/**
 * Receives the user's layer file. Only the first call counts: a host may push
 * twice (page "ready" and navigation completed), and a late second push must
 * not wipe edits already made.
 * @param {{os: string, path: string, text: string|null, errors: object[]}} payload
 */
function init(payload) {
	if (state.os !== null) return;
	payload = payload || {};
	if (DATA.platforms.indexOf(payload.os) < 0) {
		showBanner(['Unknown OS "' + String(payload.os) + '"'], true);
		setEditable(false);
		return;
	}
	state.os = payload.os;
	state.path = typeof payload.path === 'string' ? payload.path : DATA.user_file;
	var read = LayerModel.readLayerFile(payload.text === undefined ? null : payload.text, DATA);
	state.doc = read.doc;
	state.fileProblem = read.problem;
	state.fileErrors = errorList(payload.errors);
	setEditable(true);
	render();
}

/**
 * Receives the outcome of a save.
 * @param {{saved: boolean, applied: boolean, errors: object[]}} result
 */
function saveResult(result) {
	result = result || {};
	state.saving = false;
	if (result.saved !== true) {
		var reasons = errorList(result.errors).map(describeError);
		state.status = _t('layer_editor.save_refused', reasons.join(' · ') || '?');
	} else {
		state.dirty = false;
		state.closeArmed = false;
		state.fileProblem = null;
		state.fileErrors = [];
		state.status = result.applied === false ? _t('layer_editor.apply_failed') : _t('common.saved');
	}
	render();
}

/**
 * A host's error list. The Lua hosts' JSON encoder writes an empty list as {},
 * which is no error.
 */
function errorList(errors) {
	return Array.isArray(errors) ? errors : [];
}

function describeError(e) {
	var where = [e.layer, e.section, e.key].filter(function (p) {
		return p !== undefined && p !== null && p !== '';
	});
	return (where.length ? where.join('.') + ' — ' : '') + (e.detail || e.code || '');
}

// ================================
// ======= 3/ Edits ===============
// ================================

function markDirty() {
	state.dirty = true;
	state.closeArmed = false;
	state.status = _t('layer_editor.unsaved');
}

/** Binds the selected input to a value, or gives it its normal behaviour back (null). */
function pick(value) {
	if (!state.selected || state.os === null) return;
	if (value === null)
		LayerModel.makeNative(state.doc, DATA.layer, state.os, state.selected, DATA.platforms);
	else {
		if (!LayerModel.bindingAvailability(value, state.os, DATA).ok) return;
		LayerModel.setBinding(state.doc, DATA.layer, state.os, state.selected, value);
	}
	markDirty();
	render();
}

function restoreRecommended() {
	LayerModel.restoreRecommended(state.doc, DATA.layer, DATA.recommended);
	markDirty();
	render();
}

function clearAll() {
	LayerModel.clearLayer(state.doc, DATA.layer);
	markDirty();
	render();
}

function save() {
	if (state.os === null || state.saving) return;
	state.saving = true;
	post({ action: 'save', text: LayerModel.serialize(state.doc, DATA) });
	render();
}

function closeEditor() {
	if (state.dirty && !state.closeArmed) {
		state.closeArmed = true;
		state.status = _t('layer_editor.unsaved_close');
		render();
		return;
	}
	post({ action: 'cancel' });
}

function select(code) {
	state.selected = code;
	state.search = '';
	render();
}

// ================================
// ======= 4/ Rendering ===========
// ================================

function setEditable(enabled) {
	['btn-restore', 'btn-clear', 'btn-save'].forEach(function (id) {
		el(id).disabled = !enabled;
	});
}

function showBanner(lines, isError) {
	var banner = el('banner');
	banner.innerHTML = '';
	banner.hidden = lines.length === 0;
	banner.className = isError ? 'error' : '';
	lines.forEach(function (line) {
		banner.appendChild(make('div', 'banner-line', line));
	});
}

function renderBanner() {
	var lines = [];
	var entryErrors = state.fileErrors.filter(function (e) {
		return e.key || e.section || e.layer;
	});
	// A problem with the file as a whole: the page's own reading of it, else the
	// host's (an unreadable file reaches the page as no text at all).
	var fileLevel = state.fileErrors.filter(function (e) {
		return entryErrors.indexOf(e) < 0;
	});
	var problem = state.fileProblem || fileLevel.map(describeError).join('; ');
	if (problem) lines.push(_t('layer_editor.file_problem', state.path, problem));
	if (entryErrors.length) {
		lines.push(_t('layer_editor.file_errors', state.path));
		entryErrors.forEach(function (e) {
			lines.push('• ' + describeError(e));
		});
	}
	showBanner(lines, lines.length > 0);
}

/**
 * The state of one input on the current OS.
 * @returns {{value: any, recommended: any, className: string, reason: string|null}}
 */
function inputState(code, current, recommended) {
	var entry = current[code];
	var rec = recommended[code];
	var value = entry ? entry.value : undefined;
	var recValue = rec ? rec.value : undefined;
	var source = LayerModel.inputAvailability(code, state.os, DATA);
	if (!source.ok)
		return {
			value: value,
			recommended: recValue,
			className: 'unavailable',
			reason: source.reason_key ? _t(source.reason_key) : null
		};
	if (value !== undefined && !LayerModel.bindingAvailability(value, state.os, DATA).ok) {
		var why = LayerModel.bindingAvailability(value, state.os, DATA).reason_key;
		return {
			value: value,
			recommended: recValue,
			className: 'invalid',
			reason: why ? _t(why) : null
		};
	}
	if (value !== undefined && value === recValue)
		return { value: value, recommended: recValue, className: 'recommended', reason: null };
	if (value !== undefined || recValue !== undefined)
		return { value: value, recommended: recValue, className: 'custom', reason: null };
	return { value: value, recommended: recValue, className: '', reason: null };
}

function inputLabel(code) {
	return INPUT_LABEL_KEYS[code] ? _t(INPUT_LABEL_KEYS[code]) : LayerModel.keyLegend(code, state.os);
}

function bindingShort(value) {
	return value === undefined ? '' : LayerModel.describeBinding(value, state.os, DATA, _t);
}

/** One clickable input, placed by the caller. */
function buildInput(code, info, text, extraClass) {
	var node = make(
		'div',
		['key', info.className, extraClass || '', state.selected === code ? 'selected' : '']
			.join(' ')
			.replace(/\s+/g, ' ')
			.trim()
	);
	node.dataset.code = code;
	node.title = info.reason || '';
	// The slot fills the key's place on the board; the cap inside it is drawn a
	// little smaller, which leaves the gap between two keys.
	var cap = make('div', 'cap');
	cap.appendChild(make('span', 'legend', text));
	cap.appendChild(make('span', 'binding', bindingShort(info.value)));
	node.appendChild(cap);
	node.addEventListener('click', function () {
		select(code);
	});
	return node;
}

function place(node, geo, row, col, width, height) {
	var totalCols = boardColumns();
	var totalRows = BOARD_ROWS + FUNCTION_ROW_GAP;
	var top = row + (row > 0 ? FUNCTION_ROW_GAP : 0);
	node.style.left = (col / totalCols) * 100 + '%';
	node.style.width = (width / totalCols) * 100 + '%';
	node.style.top = (top / totalRows) * 100 + '%';
	node.style.height = (height / totalRows) * 100 + '%';
}

function boardColumns() {
	var max = 0;
	DATA.keys.forEach(function (k) {
		var g = k.geometry && k.geometry[state.form];
		if (g)
			max = Math.max(
				max,
				g.col + g.width,
				g.bottom_col !== undefined ? g.bottom_col + g.bottom_width : 0
			);
	});
	return max;
}

function renderBoard(current, recommended) {
	var board = el('board');
	board.innerHTML = '';
	// A zero-height box whose padding carries the board's proportions: the keys'
	// percentages resolve against that padding box, in every engine the three
	// hosts embed (older WebKitGTK builds lack aspect-ratio).
	board.style.paddingTop = ((BOARD_ROWS + FUNCTION_ROW_GAP) / boardColumns()) * 100 + '%';
	DATA.keys.forEach(function (k) {
		var geo = k.geometry && k.geometry[state.form];
		if (!geo) return;
		var info = inputState(k.code, current, recommended);
		var node = buildInput(k.code, info, inputLabel(k.code));
		if (geo.bottom_col !== undefined) {
			// The ISO Enter: a wide upper row and a narrower lower row, drawn as
			// two blocks that select the same key.
			place(node, geo, geo.row, geo.col, geo.width, 1);
			board.appendChild(node);
			var lower = buildInput(k.code, info, '', 'enter-lower');
			place(lower, geo, geo.row + 1, geo.bottom_col, geo.bottom_width, 1);
			board.appendChild(lower);
			return;
		}
		place(node, geo, geo.row, geo.col, geo.width, geo.height || 1);
		board.appendChild(node);
	});
}

function renderMouse(current, recommended) {
	var pane = el('mouse');
	pane.innerHTML = '';
	DATA.keys.forEach(function (k) {
		if (k.kind !== 'mouse_button' && k.kind !== 'wheel') return;
		pane.appendChild(
			buildInput(k.code, inputState(k.code, current, recommended), inputLabel(k.code), 'pointer')
		);
	});
}

function pickerRow(label, value, current, available, reason) {
	var row = make('div', 'row' + (current ? ' current' : '') + (available ? '' : ' disabled'));
	row.appendChild(make('span', 'row-tick', '✓'));
	row.appendChild(make('span', 'row-label', label));
	if (!available) {
		row.title = reason || '';
		return row;
	}
	row.addEventListener('click', function () {
		pick(value);
	});
	return row;
}

function renderPicker(panel, info) {
	var search = make('input', 'search');
	search.type = 'text';
	search.id = 'search';
	search.placeholder = _t('dialog.action_picker.search');
	search.value = state.search;
	search.addEventListener('input', function () {
		state.search = search.value;
		renderPickerList(list, info);
	});
	panel.appendChild(search);
	var list = make('div', 'list');
	list.id = 'picker-list';
	panel.appendChild(list);
	renderPickerList(list, info);
}

function renderPickerList(list, info) {
	list.innerHTML = '';
	var query = state.search.trim().toLowerCase();
	var matches = function (label) {
		return query === '' || label.toLowerCase().indexOf(query) >= 0;
	};
	var items = LayerModel.pickerItems(DATA, state.os, _t);
	var shown = 0;
	var pendingHeading = null;
	var nativeLabel = _t('layer_editor.value.native');
	items.forEach(function (item) {
		if (item.type === 'heading') {
			pendingHeading = item;
			// The "key" group carries the native behaviour, which is no action.
			if (item.id === DATA.groups[0].id && matches(nativeLabel)) {
				list.appendChild(make('div', 'heading', item.text));
				pendingHeading = null;
				list.appendChild(pickerRow(nativeLabel, null, info.value === undefined, true, null));
				shown += 1;
			}
			return;
		}
		if (!matches(item.label)) return;
		if (pendingHeading) {
			list.appendChild(make('div', 'heading', pendingHeading.text));
			pendingHeading = null;
		}
		list.appendChild(
			pickerRow(item.label, item.id, info.value === item.id, item.available, item.reason)
		);
		shown += 1;
	});
	if (shown === 0) list.appendChild(make('div', 'empty', _t('dialog.action_picker.no_results')));
}

function renderRepeat(panel, info) {
	var box = make('div', 'param');
	box.appendChild(make('h3', '', _t('layer_editor.repeat.heading')));
	var available = DATA.repeat_count.platforms.indexOf(state.os) >= 0;
	var input = make('input', 'count');
	input.type = 'number';
	input.id = 'repeat-count';
	input.min = String(DATA.repeat_count.min);
	input.max = String(DATA.repeat_count.max);
	var parsed = info.value !== undefined ? LayerModel.parseBinding(info.value, DATA) : null;
	input.value = String(
		parsed && parsed.type === 'repeat_count' ? parsed.count : DATA.repeat_count.min
	);
	var apply = make('button', '', _t('layer_editor.repeat.apply'));
	apply.type = 'button';
	apply.id = 'repeat-apply';
	if (!available) {
		input.disabled = true;
		apply.disabled = true;
		box.title = _t(DATA.repeat_count.reason_key);
		box.classList.add('disabled');
	}
	apply.addEventListener('click', function () {
		var n = Number(input.value);
		if (!(n >= DATA.repeat_count.min && n <= DATA.repeat_count.max && Math.floor(n) === n)) return;
		pick('repeat_count:' + n);
	});
	box.appendChild(input);
	box.appendChild(apply);
	panel.appendChild(box);
}

function renderKeystroke(panel, info) {
	var box = make('div', 'param');
	box.appendChild(make('h3', '', _t('layer_editor.keystroke.heading')));
	var parsed = info.value !== undefined ? LayerModel.parseBinding(info.value, DATA) : null;
	var chord =
		parsed && parsed.type === 'keystroke' && parsed.chords.length === 1 ? parsed.chords[0] : null;
	var boxes = {};
	var mods = make('div', 'mods');
	var primary = make('label', 'mod primary');
	var primaryBox = make('input');
	primaryBox.type = 'checkbox';
	primaryBox.id = 'mod-primary';
	primaryBox.checked = !!chord && chord.mods.indexOf('primary') >= 0;
	primary.appendChild(primaryBox);
	primary.appendChild(make('span', '', _t('layer_editor.keystroke.primary')));
	DATA.modifier_order.forEach(function (mod) {
		if (DATA.modifiers[mod].platforms.indexOf(state.os) < 0) return;
		var label = make('label', 'mod');
		var cb = make('input');
		cb.type = 'checkbox';
		cb.id = 'mod-' + mod;
		cb.checked = !!chord && chord.mods.indexOf(mod) >= 0;
		boxes[mod] = cb;
		label.appendChild(cb);
		label.appendChild(make('span', '', LayerModel.modifierName(mod, state.os)));
		mods.appendChild(label);
	});
	box.appendChild(mods);
	box.appendChild(primary);
	var keySelect = make('select', 'target');
	keySelect.id = 'keystroke-key';
	DATA.keys.forEach(function (k) {
		if (k.kind !== 'key') return;
		var option = make('option', '', LayerModel.keyLegend(k.code, state.os) + '  (' + k.code + ')');
		option.value = k.code;
		keySelect.appendChild(option);
	});
	keySelect.value = chord ? chord.key : 'KeyA';
	box.appendChild(keySelect);
	var apply = make('button', '', _t('layer_editor.keystroke.apply'));
	apply.type = 'button';
	apply.id = 'keystroke-apply';
	apply.addEventListener('click', function () {
		var chosen = [];
		if (primaryBox.checked) chosen.push('primary');
		DATA.modifier_order.forEach(function (mod) {
			if (boxes[mod] && boxes[mod].checked) chosen.push(mod);
		});
		chosen.push(keySelect.value);
		pick('keystroke:' + chosen.join('+'));
	});
	box.appendChild(apply);
	panel.appendChild(box);
}

function renderPanel(current, recommended) {
	var panel = el('panel');
	panel.innerHTML = '';
	if (!state.selected) {
		panel.appendChild(make('p', 'prompt', _t('layer_editor.pick_prompt')));
		return;
	}
	var info = inputState(state.selected, current, recommended);
	panel.appendChild(
		make('h2', 'panel-title', inputLabel(state.selected) + '  ·  ' + state.selected)
	);
	if (info.className === 'unavailable') {
		panel.appendChild(make('p', 'reason', info.reason || _t('layer_editor.legend.unavailable')));
		return;
	}
	var now = make(
		'p',
		'current-value',
		_t('layer_editor.current', bindingShort(info.value) || _t('layer_editor.value.native'))
	);
	now.id = 'current-value';
	panel.appendChild(now);
	if (info.className === 'invalid' && info.reason)
		panel.appendChild(make('p', 'reason', info.reason));
	var recLine = make('div', 'recommended-line');
	recLine.appendChild(
		make(
			'span',
			'',
			_t(
				'layer_editor.recommended',
				bindingShort(info.recommended) || _t('layer_editor.value.native')
			)
		)
	);
	var useRec = make('button', '', _t('layer_editor.use_recommended'));
	useRec.type = 'button';
	useRec.id = 'use-recommended';
	useRec.disabled = info.value === info.recommended;
	useRec.addEventListener('click', function () {
		pick(info.recommended === undefined ? null : info.recommended);
	});
	recLine.appendChild(useRec);
	panel.appendChild(recLine);
	renderPicker(panel, info);
	renderRepeat(panel, info);
	renderKeystroke(panel, info);
}

function render() {
	if (state.os === null) return;
	var current = LayerModel.effective(state.doc, DATA.layer, state.os);
	var recommendedDoc = { layers: {} };
	recommendedDoc.layers[DATA.layer] = DATA.recommended;
	var recommended = LayerModel.effective(recommendedDoc, DATA.layer, state.os);
	el('form').value = state.form;
	renderBanner();
	renderBoard(current, recommended);
	renderMouse(current, recommended);
	renderPanel(current, recommended);
	el('status').textContent = state.status;
	el('btn-save').disabled = state.saving;
}

// ================================
// ======= 5/ Events ==============
// ================================

document.addEventListener('DOMContentLoaded', function () {
	state.form = readStoredForm();
	setEditable(false);
	el('form').addEventListener('change', function () {
		state.form = el('form').value === 'ansi' ? 'ansi' : 'iso';
		storeForm(state.form);
		render();
	});
	el('btn-restore').addEventListener('click', restoreRecommended);
	el('btn-clear').addEventListener('click', clearAll);
	el('btn-save').addEventListener('click', save);
	el('btn-close').addEventListener('click', closeEditor);
	document.addEventListener('keydown', function (e) {
		if (e.key === 'Escape') {
			e.preventDefault();
			closeEditor();
		}
	});
	// Labels come from the locale file i18n.js loads; draw again once it has.
	document.addEventListener('i18n:applied', render);
	post('ready');
});
