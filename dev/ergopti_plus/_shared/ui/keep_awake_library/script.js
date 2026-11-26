// _shared/ui/keep_awake_library/script.js

/**
 * ==============================================================================
 * MODULE: Anti-Sleep Library Window
 * DESCRIPTION:
 * The « Bibliothèque anti-veille… » window: lists the anti-sleep presets and
 * edits one at a time (name, switches, the allowed apps of this OS, its image
 * and text targets), creates, duplicates, deletes, makes active, exports and
 * imports presets, and adds a button by drawing it on screen (« Ajouter un
 * bouton… ») or from an image file.
 *
 * FEATURES & RATIONALE:
 * 1. The host owns the document: every change is one store edit posted to the
 *    host, and the page redraws from the document the host sends back, so the
 *    window never shows a state the drivers would not run.
 * 2. Keyboard first: every control is a native button, checkbox or field at
 *    least 44 px tall; the status line is a polite live region.
 * 3. Host protocol (bridge hsKeepAwake): the page posts ready, edit, add_image,
 *    export, import and close; the host calls initData, onDoc, onImage,
 *    onExported and onImported.
 * ==============================================================================
 */

const _post = makeHostBridge('hsKeepAwake');

// ========================================
// ========================================
// ======= 1/ State and strings ===========
// ========================================
// ========================================

let _strings = {};
let _os = 'linux';
let _defaults = { threshold: 0.92, threshold_min: 0.5, threshold_max: 1, text_max_distance: 1 };
let _doc = { active: '', presets: [] };
let _thumbnails = {};
let _selected = '';

/**
 * Returns the translated string for key, or key itself as fallback.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}

/**
 * Replaces {1}, {2}… in one pass.
 * @param {string} text
 * @param {Array<string>} values
 * @returns {string}
 */
function _fill(text, values) {
	return text.replace(/\{(\d+)\}/g, (all, n) =>
		values[n - 1] === undefined ? all : String(values[n - 1])
	);
}

/** Applies the static strings of the page. */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		const key = el.getAttribute('data-i18n');
		if (_strings[key] === undefined) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
	document.querySelectorAll('[data-i18n-aria-label]').forEach(function (el) {
		el.setAttribute('aria-label', _t(el.getAttribute('data-i18n-aria-label')));
	});
}

/**
 * Shows a status line, read by screen readers.
 * @param {string} text
 * @param {boolean} isError
 */
function showStatus(text, isError) {
	const status = document.getElementById('status');
	status.textContent = text;
	status.classList.toggle('error', isError === true);
}

/**
 * The display name of a preset.
 * @param {object} preset
 * @returns {string}
 */
function presetName(preset) {
	return preset.name || _t(preset.name_key);
}

/** @returns {object|null} The selected preset. */
function current() {
	return _doc.presets.find((p) => p.id === _selected) || null;
}

/**
 * A fresh preset id, unique in the document.
 * @returns {string}
 */
function newId() {
	const used = new Set(_doc.presets.map((p) => p.id));
	let id;
	do {
		id = 'preset_' + Math.random().toString(36).slice(2, 8);
	} while (used.has(id));
	return id;
}

/**
 * Posts one store edit; the host answers with onDoc.
 * @param {string} op
 * @param {Array} args
 */
function edit(op, args) {
	_post({ action: 'edit', op: op, args: args });
}

// ========================================
// ========================================
// ======= 2/ Rendering ===================
// ========================================
// ========================================

/** Redraws the preset list. */
function renderList() {
	const list = document.getElementById('preset-list');
	list.textContent = '';
	_doc.presets.forEach(function (preset) {
		const item = document.createElement('li');
		const button = document.createElement('button');
		button.type = 'button';
		button.className = 'preset';
		button.textContent =
			presetName(preset) +
			(preset.id === _doc.active ? ' — ' + _t('keepawake.library.active') : '');
		button.setAttribute('aria-pressed', preset.id === _selected ? 'true' : 'false');
		button.addEventListener('click', function () {
			_selected = preset.id;
			render();
		});
		item.appendChild(button);
		list.appendChild(item);
	});
}

/**
 * A labelled checkbox that posts one edit when it changes.
 * @param {string} labelKey
 * @param {boolean} checked
 * @param {Function} onChange Receives the new value.
 * @returns {HTMLElement}
 */
function checkbox(labelKey, checked, onChange) {
	const label = document.createElement('label');
	label.className = 'check';
	const input = document.createElement('input');
	input.type = 'checkbox';
	input.checked = checked === true;
	input.addEventListener('change', () => onChange(input.checked));
	label.appendChild(input);
	label.appendChild(document.createTextNode(' ' + _t(labelKey)));
	return label;
}

/**
 * A labelled number field that posts one edit when it changes.
 * @param {string} labelKey
 * @param {number} value
 * @param {object} bounds { min, max, step }
 * @param {Function} onChange Receives the new value.
 * @returns {HTMLElement}
 */
function numberField(labelKey, value, bounds, onChange) {
	const label = document.createElement('label');
	label.className = 'number';
	const input = document.createElement('input');
	input.type = 'number';
	input.min = String(bounds.min);
	input.max = String(bounds.max);
	input.step = String(bounds.step);
	input.value = String(value);
	input.addEventListener('change', function () {
		const parsed = Number(input.value);
		if (Number.isFinite(parsed)) onChange(parsed);
	});
	label.appendChild(document.createTextNode(_t(labelKey) + ' '));
	label.appendChild(input);
	return label;
}

/**
 * The remove button of one target.
 * @param {string} targetId
 * @returns {HTMLElement}
 */
function removeButton(targetId) {
	const button = document.createElement('button');
	button.type = 'button';
	button.textContent = _t('keepawake.library.remove');
	button.addEventListener('click', () => edit('remove_target', [_selected, targetId]));
	return button;
}

/**
 * Redraws the image targets of a preset.
 * @param {object} preset
 */
function renderImages(preset) {
	const list = document.getElementById('images');
	list.textContent = '';
	document.getElementById('images-empty').hidden = preset.images.length > 0;
	preset.images.forEach(function (image) {
		const item = document.createElement('li');
		item.className = 'target';
		const thumb = document.createElement('img');
		thumb.alt = _fill(_t('keepawake.library.image_alt'), [image.id]);
		if (_thumbnails[image.file]) thumb.src = 'data:image/png;base64,' + _thumbnails[image.file];
		item.appendChild(thumb);
		const put = (field, value) => {
			const next = Object.assign({}, image);
			next[field] = value;
			edit('put_target', [_selected, 'images', next]);
		};
		item.appendChild(
			checkbox('keepawake.library.enabled', image.enabled, (v) => put('enabled', v))
		);
		item.appendChild(
			numberField(
				'keepawake.library.threshold',
				image.threshold || _defaults.threshold,
				{ min: _defaults.threshold_min, max: _defaults.threshold_max, step: 0.01 },
				(v) => put('threshold', v)
			)
		);
		item.appendChild(removeButton(image.id));
		list.appendChild(item);
	});
}

/**
 * Redraws the text targets of a preset.
 * @param {object} preset
 */
function renderTexts(preset) {
	const list = document.getElementById('texts');
	list.textContent = '';
	document.getElementById('texts-empty').hidden = preset.texts.length > 0;
	preset.texts.forEach(function (text) {
		const item = document.createElement('li');
		item.className = 'target';
		const caption = document.createElement('p');
		caption.className = 'variants';
		caption.textContent = text.variants.join(' · ');
		item.appendChild(caption);
		const put = (field, value) => {
			const next = Object.assign({}, text);
			next[field] = value;
			edit('put_target', [_selected, 'texts', next]);
		};
		item.appendChild(checkbox('keepawake.library.enabled', text.enabled, (v) => put('enabled', v)));
		item.appendChild(
			numberField(
				'keepawake.library.max_distance',
				text.max_distance,
				{ min: 0, max: 3, step: 1 },
				(v) => put('max_distance', Math.round(v))
			)
		);
		item.appendChild(removeButton(text.id));
		list.appendChild(item);
	});
}

/** Redraws the editor of the selected preset. */
function renderEditor() {
	const preset = current();
	const editor = document.getElementById('editor');
	editor.hidden = preset === null;
	if (preset === null) return;
	document.getElementById('editor-heading').textContent = presetName(preset);
	document.getElementById('input-name').value = presetName(preset);
	document.getElementById('btn-activate').disabled = preset.id === _doc.active;
	document.getElementById('switch-keep-awake').checked = preset.keep_awake === true;
	document.getElementById('switch-auto-click').checked = preset.auto_click === true;
	document.getElementById('input-apps').value = (preset.allowed_apps[_os] || []).join('\n');
	renderImages(preset);
	renderTexts(preset);
}

/** Redraws the whole window. */
function render() {
	if (!current() && _doc.presets.length > 0) _selected = _doc.active || _doc.presets[0].id;
	renderList();
	renderEditor();
	document.getElementById('btn-delete').disabled = _doc.presets.length <= 1;
}

// ========================================
// ========================================
// ======= 3/ Host callbacks ==============
// ========================================
// ========================================

/**
 * The refusal text of a reason, or the generic one.
 * @param {string} reason
 * @returns {string}
 */
function refusal(reason) {
	return _fill(_t('keepawake.library.refused'), [reason || '']);
}

window.initData = function (data) {
	_strings = data.strings || {};
	_os = data.os || _os;
	_defaults = Object.assign(_defaults, data.defaults || {});
	_doc = data.doc;
	_thumbnails = data.thumbnails || {};
	applyDomStrings();
	render();
};

window.onDoc = function (data) {
	_doc = data.doc;
	_thumbnails = data.thumbnails || _thumbnails;
	render();
	if (data.ok === false) showStatus(refusal(data.reason), true);
	else if (data.ok === true) showStatus(_t('keepawake.library.saved'), false);
};

window.onImage = function (data) {
	if (data.ok) showStatus(_t('keepawake.library.image_added'), false);
	else if (data.reason !== 'cancelled') showStatus(_t('keepawake.library.image_failed'), true);
};

window.onExported = function (data) {
	showStatus(data.ok ? _t('keepawake.library.exported') : refusal(data.reason), !data.ok);
};

window.onImported = function (data) {
	if (data.ok) {
		_selected = data.id;
		showStatus(_t('keepawake.library.imported'), false);
	} else {
		showStatus(_t('keepawake.library.import_failed'), true);
	}
};

// ========================================
// ========================================
// ======= 4/ Controls ====================
// ========================================
// ========================================

/** Wires every static control. */
function wire() {
	const on = (id, fn) => document.getElementById(id).addEventListener('click', fn);
	on('btn-new', function () {
		const id = newId();
		const apps = { macos: [], windows: [], linux: [] };
		edit('add', [
			{
				id: id,
				name: _t('keepawake.library.new_name'),
				keep_awake: true,
				auto_click: false,
				allowed_apps: apps,
				images: [],
				texts: []
			}
		]);
		_selected = id;
	});
	on('btn-duplicate', function () {
		const preset = current();
		if (!preset) return;
		const id = newId();
		edit('duplicate', [
			preset.id,
			id,
			_fill(_t('keepawake.library.copy_name'), [presetName(preset)])
		]);
		_selected = id;
	});
	on('btn-delete', function () {
		const preset = current();
		if (!preset) return;
		if (!window.confirm(_fill(_t('keepawake.library.confirm_delete'), [presetName(preset)])))
			return;
		edit('remove', [preset.id]);
		_selected = '';
	});
	on('btn-import', () => _post({ action: 'import' }));
	on('btn-export', () => current() && _post({ action: 'export', preset: _selected }));
	on('btn-rename', function () {
		const name = document.getElementById('input-name').value.trim();
		if (name !== '') edit('rename', [_selected, name]);
	});
	on('btn-activate', () => edit('set_active', [_selected]));
	on('btn-add-button', () => _post({ action: 'add_image', preset: _selected, source: 'capture' }));
	on('btn-import-image', () => _post({ action: 'add_image', preset: _selected, source: 'import' }));
	on('btn-add-text', function () {
		const preset = current();
		const variants = document
			.getElementById('input-variants')
			.value.split('|')
			.map((v) => v.trim())
			.filter((v) => v !== '');
		if (!preset || variants.length === 0) return;
		const used = new Set(preset.texts.map((t) => t.id).concat(preset.images.map((i) => i.id)));
		let id = 'text_1';
		for (let n = 2; used.has(id); n += 1) id = 'text_' + n;
		edit('put_target', [
			_selected,
			'texts',
			{ id: id, variants: variants, max_distance: _defaults.text_max_distance, enabled: true }
		]);
		document.getElementById('input-variants').value = '';
	});
	on('btn-close', () => _post({ action: 'close' }));
	document
		.getElementById('switch-keep-awake')
		.addEventListener('change', (e) =>
			edit('set_switch', [_selected, 'keep_awake', e.target.checked])
		);
	document
		.getElementById('switch-auto-click')
		.addEventListener('change', (e) =>
			edit('set_switch', [_selected, 'auto_click', e.target.checked])
		);
	document.getElementById('input-apps').addEventListener('change', function (e) {
		const apps = e.target.value
			.split('\n')
			.map((v) => v.trim())
			.filter((v) => v !== '');
		edit('set_apps', [_selected, _os, apps]);
	});
	document.addEventListener('keydown', function (e) {
		if (e.key === 'Escape') _post({ action: 'close' });
	});
}

wire();
_post({ action: 'ready' });
