// _shared/ui/layout_composer/composer_page.js

/**
 * ==============================================================================
 * MODULE: Layout Composer Page
 * DESCRIPTION:
 * The composer view of the layout manager window (_shared/ui/layout_manager).
 * It lets the user take each of the four layers from any layout, say what the
 * keys give under a held Ctrl, Alt or Win, tune any key of any layer, and hand
 * the host the declaration and the complete .keylayout it compiles to. Every
 * rule about the composition lives in composer_model.js; this file only
 * renders and routes clicks.
 *
 * HOST PROTOCOL (the layout manager's bridge, same on the three drivers):
 *   page -> host  {action: "composer_open"}      send the sources and the
 *                                                stored declaration
 *                 {action: "composer_save", declaration, keylayout, use}
 *                                                validate, store and, with
 *                                                `use`, switch to it
 *                 {action: "composer_remove"}    delete the composition
 *   host -> page  composerData({platform, sources, declaration, active,
 *                               shortcuts})
 *                 composerResult({action, ok, code, detail})
 *   sources = [{id, name, convention, text}]: every registry layout the host
 *   can read; declaration = the stored composition.json text or null;
 *   shortcuts = "full" when the OS types a layer of its own under Ctrl, Alt
 *   and Win, "single" when one shortcuts layer serves the three (Linux XKB).
 *
 * FEATURES & RATIONALE:
 * 1. Nothing is written by the page: the host parses the .keylayout with its
 *    own reader before it stores or activates it.
 * 2. A layout the host sent but the model cannot read is listed with the
 *    reason, never silently dropped from the dropdowns.
 * 3. The grid shows the composed result of the level being edited, so a
 *    change in a dropdown or an override is visible at once.
 * ==============================================================================
 */

// ============================
// ======= 1/ State ===========
// ============================

var COMPOSER_FORM_STORAGE_KEY = 'layout_composer.form';

// Pixels of one key unit on the drawn board.
var COMPOSER_KEY_UNIT = 46;
// Where a registry layout's unreadable reason is shown at most.
var COMPOSER_MAX_REASON_LENGTH = 120;

// The levels the grid can show, in tab order.
var COMPOSER_LEVELS = ['base', 'shift', 'altgr', 'shift_altgr', 'caps', 'meta', 'ctrl', 'alt'];

var composerState = {
	opened: false,
	platform: '',
	shortcutsMode: 'full',
	active: false,
	sources: {},
	order: [],
	unreadable: [],
	declaration: null,
	built: null,
	problems: [],
	level: 'base',
	selected: '',
	dirty: false,
	stored: false,
	loadProblem: null,
	busy: false,
	result: null
};

/** The Windows/Mac/Linux name of a shortcut modifier's locale key. */
function composerLevelKey(level) {
	return 'layout_composer.level_' + level;
}

/**
 * A boolean the host sent: the Lua hosts send true, the AutoHotkey host's JSON
 * writer sends its booleans as 1 (see the layout manager's host).
 */
function composerTrue(value) {
	return value === true || value === 1;
}

function composerEl(id) {
	return document.getElementById(id);
}

function composerStored(name, allowed, fallback) {
	try {
		var value = window.localStorage.getItem(name);
		return allowed.indexOf(value) >= 0 ? value : fallback;
	} catch (error) {
		return fallback;
	}
}

function composerStore(name, value) {
	try {
		window.localStorage.setItem(name, value);
	} catch (error) {
		// Blocked storage only costs the remembered choice.
	}
}

// ============================
// ======= 2/ Sources =========
// ============================

/**
 * Reads what the host sent into model sources, the built-in references first.
 * @param {object[]} listed - The host's [{id, name, convention, text}].
 */
function composerReadSources(listed) {
	composerState.sources = {};
	composerState.order = [];
	composerState.unreadable = [];
	Object.keys(LAYOUT_COMPOSER_REFERENCE).forEach(function (id) {
		composerState.sources[id] = LayoutComposer.referenceSource(id, LAYOUT_COMPOSER_REFERENCE[id]);
		composerState.order.push(id);
	});
	(Array.isArray(listed) ? listed : []).forEach(function (entry) {
		if (!entry || typeof entry.id !== 'string' || composerState.sources[entry.id]) return;
		try {
			var source = LayoutComposer.parseSource(
				entry.id,
				String(entry.text),
				entry.convention,
				LAYOUT_COMPOSER_DATA
			);
			source.name = typeof entry.name === 'string' && entry.name !== '' ? entry.name : entry.id;
			composerState.sources[entry.id] = source;
			composerState.order.push(entry.id);
		} catch (error) {
			composerState.unreadable.push({
				id: entry.id,
				reason: String(error.message).slice(0, COMPOSER_MAX_REASON_LENGTH)
			});
		}
	});
}

/** A new composition the first time: Ergopti's layers when it is readable, else QWERTY. */
function composerDefaultDeclaration() {
	var first = composerState.sources.ergopti ? 'ergopti' : 'qwerty';
	var form = composerStored(COMPOSER_FORM_STORAGE_KEY, ['iso', 'ansi'], 'iso');
	return LayoutComposer.emptyDeclaration(_t('layout_composer.default_name'), form, first);
}

// ============================
// ======= 3/ Build ===========
// ============================

/** Compiles the declaration and keeps the problems for the page. */
function composerRebuild() {
	var built = LayoutComposer.build(
		composerState.declaration,
		composerState.sources,
		LAYOUT_COMPOSER_DATA
	);
	composerState.built = built.ok ? built.layout : null;
	composerState.problems = built.problems;
}

/** What a key shows on a level of the compiled layout: {text, dead}. */
function composerLegend(code, level) {
	var layout = composerState.built;
	if (!layout || !layout.keys[code]) return { text: '', dead: false };
	var cell = layout.keys[code][level];
	if (!cell) return { text: '', dead: false };
	if (cell.output !== undefined) return { text: cell.output, dead: false };
	var neutral = layout.actions[cell.action].none;
	if (neutral.next !== '') {
		var terminator = layout.terminators[neutral.next];
		return { text: terminator === undefined ? '' : terminator, dead: true };
	}
	return { text: neutral.output, dead: false };
}

/** A problem as the locale words it. */
function composerProblemText(problem) {
	var key = 'layout_composer.problem_' + problem.code;
	var text = _t(key);
	if (text === key) text = _fmt('layout_composer.problem_other', problem.code);
	return problem.detail ? text + ' (' + problem.detail + ')' : text;
}

// ============================
// ======= 4/ Editing =========
// ============================

function composerTouch() {
	composerState.dirty = true;
	composerState.result = null;
	composerRebuild();
	composerRender();
}

function composerSetLayer(layer, sourceId, from) {
	LayoutComposer.setLayerSource(composerState.declaration, layer, sourceId, from);
	composerTouch();
}

/** Sets the shortcuts entry of a modifier, null to follow the base layer. */
function composerSetShortcut(modifier, sourceId, from) {
	LayoutComposer.setShortcutSource(
		composerState.declaration,
		modifier,
		sourceId === '' ? null : { source: sourceId, layer: from || 'base' }
	);
	composerTouch();
}

/** The override a key has on the level being edited, or undefined. */
function composerOverrideOf(code) {
	var overrides = composerState.declaration.overrides || {};
	var table = overrides[composerState.level];
	return table && Object.prototype.hasOwnProperty.call(table, code) ? table[code] : undefined;
}

/**
 * Applies the key editor's choice to the selected key.
 * @param {string} kind - layer | text | nothing | copy.
 * @param {object} fields - text, or source/key/layer for a copy.
 */
function composerApplyKey(kind, fields) {
	var level = composerState.level;
	var code = composerState.selected;
	if (code === '') return;
	if (kind === 'layer') LayoutComposer.clearOverride(composerState.declaration, level, code);
	else if (kind === 'nothing')
		LayoutComposer.setOverride(composerState.declaration, level, code, null);
	else if (kind === 'text')
		LayoutComposer.setOverride(composerState.declaration, level, code, String(fields.text));
	else
		LayoutComposer.setOverride(composerState.declaration, level, code, {
			copy: { source: fields.source, key: fields.key, layer: fields.layer }
		});
	composerTouch();
}

// ============================
// ======= 5/ Rendering =======
// ============================

function composerClear(node) {
	while (node.firstChild) node.removeChild(node.firstChild);
}

/**
 * A select element.
 * @param {{value: string, label: string}[]} options
 * @param {string} value - The selected value.
 * @param {Function} onChange - Called with the new value.
 */
function composerSelect(options, value, onChange) {
	var select = element('select', '');
	options.forEach(function (option) {
		var node = element('option', '', option.label);
		node.value = option.value;
		select.appendChild(node);
	});
	select.value = value;
	select.addEventListener('change', function () {
		onChange(select.value);
	});
	return select;
}

function composerSourceOptions(includeNone) {
	var options = includeNone ? [{ value: '', label: _t('layout_composer.follow_base') }] : [];
	composerState.order.forEach(function (id) {
		options.push({ value: id, label: composerState.sources[id].name });
	});
	return options;
}

function composerLayerOptions(sameLabel) {
	var options = sameLabel ? [{ value: '', label: _t('layout_composer.same_layer') }] : [];
	LayoutComposer.SOURCE_LAYERS.forEach(function (layer) {
		options.push({ value: layer, label: _t(composerLevelKey(layer)) });
	});
	return options;
}

function composerRenderLayers() {
	var host = composerEl('composer-layers');
	composerClear(host);
	LayoutComposer.LAYER_IDS.forEach(function (layer) {
		var spec = composerState.declaration.layers[layer] || { source: composerState.order[0] };
		var row = element('div', 'composer-row');
		row.appendChild(element('label', 'composer-label', _t(composerLevelKey(layer))));
		row.appendChild(
			composerSelect(composerSourceOptions(false), spec.source, function (value) {
				composerSetLayer(layer, value, spec.layer);
			})
		);
		row.appendChild(
			composerSelect(
				composerLayerOptions(true),
				spec.layer && spec.layer !== layer ? spec.layer : '',
				function (value) {
					composerSetLayer(layer, spec.source, value === '' ? undefined : value);
				}
			)
		);
		host.appendChild(row);
	});
}

function composerRenderShortcuts() {
	var host = composerEl('composer-shortcuts');
	composerClear(host);
	composerEl('composer-shortcuts-note').hidden = composerState.shortcutsMode === 'full';
	var shortcuts = composerState.declaration.shortcuts || {};
	['default'].concat(LayoutComposer.SHORTCUT_MODIFIERS).forEach(function (modifier) {
		var spec = shortcuts[modifier];
		var row = element('div', 'composer-row');
		row.appendChild(
			element(
				'label',
				'composer-label',
				_t(modifier === 'default' ? 'layout_composer.shortcut_default' : composerLevelKey(modifier))
			)
		);
		var sourceSelect = composerSelect(
			composerSourceOptions(true),
			spec ? spec.source : '',
			function (value) {
				composerSetShortcut(modifier, value, spec && spec.layer);
			}
		);
		// With one shortcuts layer for every modifier only the default entry applies.
		var locked = modifier !== 'default' && composerState.shortcutsMode === 'single';
		sourceSelect.disabled = locked;
		row.appendChild(sourceSelect);
		var layerSelect = composerSelect(
			composerLayerOptions(false),
			spec && spec.layer ? spec.layer : 'base',
			function (value) {
				composerSetShortcut(modifier, spec.source, value);
			}
		);
		layerSelect.disabled = locked || !spec;
		row.appendChild(layerSelect);
		host.appendChild(row);
	});
}

function composerRenderTabs() {
	var host = composerEl('composer-tabs');
	composerClear(host);
	COMPOSER_LEVELS.forEach(function (level) {
		var tab = element(
			'button',
			'composer-tab' + (level === composerState.level ? ' is-active' : ''),
			_t(composerLevelKey(level))
		);
		tab.type = 'button';
		tab.dataset.level = level;
		tab.addEventListener('click', function () {
			composerState.level = level;
			composerRender();
		});
		host.appendChild(tab);
	});
}

function composerRenderBoard() {
	var board = composerEl('composer-board');
	composerClear(board);
	var form = composerState.declaration.keycode_convention;
	var maxRow = 0;
	var maxCol = 0;
	LAYOUT_COMPOSER_DATA.keys.forEach(function (key) {
		var geometry = key.geometry[form];
		if (!geometry) return;
		maxRow = Math.max(maxRow, geometry.row);
		maxCol = Math.max(maxCol, geometry.col + geometry.width);
		var legend = composerLegend(key.code, composerState.level);
		var overridden = composerOverrideOf(key.code) !== undefined;
		var cap = element(
			'button',
			'composer-key' +
				(key.code === composerState.selected ? ' is-selected' : '') +
				(overridden ? ' is-overridden' : '') +
				(legend.dead ? ' is-dead' : '')
		);
		cap.type = 'button';
		cap.dataset.code = key.code;
		cap.title = key.code;
		cap.style.left = geometry.col * COMPOSER_KEY_UNIT + 'px';
		cap.style.top = (geometry.row - 1) * COMPOSER_KEY_UNIT + 'px';
		cap.style.width = geometry.width * COMPOSER_KEY_UNIT - 4 + 'px';
		cap.textContent = legend.text;
		cap.addEventListener('click', function () {
			composerState.selected = key.code;
			composerRender();
		});
		board.appendChild(cap);
	});
	board.style.width = maxCol * COMPOSER_KEY_UNIT + 'px';
	board.style.height = maxRow * COMPOSER_KEY_UNIT + 'px';
}

function composerRenderKeyEditor() {
	var host = composerEl('composer-key-editor');
	composerClear(host);
	var code = composerState.selected;
	host.hidden = code === '';
	if (code === '') return;
	var current = composerOverrideOf(code);
	var kind = 'layer';
	if (current === null) kind = 'nothing';
	else if (typeof current === 'string') kind = 'text';
	else if (current !== undefined) kind = 'copy';
	host.appendChild(
		element('div', 'composer-key-title', code + ' - ' + _t(composerLevelKey(composerState.level)))
	);
	var kinds = [
		{ value: 'layer', label: _t('layout_composer.key_from_layer') },
		{ value: 'text', label: _t('layout_composer.key_text') },
		{ value: 'nothing', label: _t('layout_composer.key_nothing') },
		{ value: 'copy', label: _t('layout_composer.key_copy') }
	];
	var fields = {
		text: typeof current === 'string' ? current : '',
		source: current && current.copy ? current.copy.source : composerState.order[0],
		key: current && current.copy ? current.copy.key : code,
		layer: current && current.copy ? current.copy.layer : 'base'
	};
	var kindSelect = composerSelect(kinds, kind, function (value) {
		kind = value;
		details();
	});
	host.appendChild(kindSelect);
	var detail = element('div', 'composer-key-detail');
	host.appendChild(detail);
	function details() {
		composerClear(detail);
		if (kind === 'text') {
			var input = element('input', '');
			input.type = 'text';
			input.id = 'composer-key-text';
			input.value = fields.text;
			input.addEventListener('input', function () {
				fields.text = input.value;
			});
			detail.appendChild(input);
		} else if (kind === 'copy') {
			detail.appendChild(
				composerSelect(composerSourceOptions(false), fields.source, function (value) {
					fields.source = value;
				})
			);
			detail.appendChild(
				composerSelect(
					LAYOUT_COMPOSER_DATA.keys.map(function (key) {
						return { value: key.code, label: key.code };
					}),
					fields.key,
					function (value) {
						fields.key = value;
					}
				)
			);
			detail.appendChild(
				composerSelect(composerLayerOptions(false), fields.layer, function (value) {
					fields.layer = value;
				})
			);
		}
	}
	details();
	var apply = element('button', '', _t('layout_composer.btn_apply'));
	apply.type = 'button';
	apply.id = 'composer-key-apply';
	apply.addEventListener('click', function () {
		composerApplyKey(kind, fields);
	});
	host.appendChild(apply);
}

function composerRenderStatus() {
	var problems = composerEl('composer-problems');
	composerClear(problems);
	if (composerState.loadProblem !== null)
		problems.appendChild(
			element('li', '', composerProblemText({ code: 'declaration_invalid', detail: '' }))
		);
	composerState.problems.forEach(function (problem) {
		problems.appendChild(element('li', '', composerProblemText(problem)));
	});
	composerState.unreadable.forEach(function (entry) {
		problems.appendChild(
			element('li', '', _fmt('layout_composer.unreadable_layout', entry.id, entry.reason))
		);
	});
	problems.hidden = problems.children.length === 0;

	var result = composerEl('composer-result');
	var state = composerState.result;
	result.hidden = !state;
	if (state) {
		if (state.ok) {
			result.textContent = _t(
				state.action === 'composer_remove'
					? 'layout_composer.result_removed'
					: state.used
						? 'layout_composer.result_saved_used'
						: 'layout_composer.result_saved'
			);
		} else {
			var failure = 'layout_composer.failure_' + state.code;
			if (_t(failure) === failure) failure = 'layout_composer.failure_other';
			result.textContent = _fmt('layout_composer.result_failed', _t(failure));
		}
		result.title = typeof state.detail === 'string' ? state.detail : '';
		result.classList.toggle('is-error', !state.ok);
	}
	var valid = composerState.built !== null;
	var busy = composerState.busy;
	composerEl('composer-save').disabled = !valid || busy;
	composerEl('composer-save-use').disabled = !valid || busy;
	composerEl('composer-remove').disabled = busy || (!composerState.active && !composerState.stored);
	composerEl('composer-active').hidden = !composerState.active;
}

/** Redraws the composer view from its state. */
function composerRender() {
	if (!composerState.opened || !composerState.declaration) return;
	composerEl('composer-name').value = composerState.declaration.name;
	composerEl('composer-form').value = composerState.declaration.keycode_convention;
	composerRenderLayers();
	composerRenderShortcuts();
	composerRenderTabs();
	composerRenderBoard();
	composerRenderKeyEditor();
	composerRenderStatus();
}

// ============================
// ======= 6/ Host bridge =====
// ============================

/**
 * Called by the host with the sources and the stored composition.
 * @param {{platform: string, sources: object[], declaration: (string|null),
 *   active: boolean, shortcuts: boolean}} data
 */
window.composerData = function (data) {
	if (!data || typeof data !== 'object') return;
	composerState.platform = typeof data.platform === 'string' ? data.platform : '';
	composerState.shortcutsMode = data.shortcuts === 'single' ? 'single' : 'full';
	composerState.active = composerTrue(data.active);
	composerState.stored = typeof data.declaration === 'string';
	composerReadSources(data.sources);
	var stored = LayoutComposer.readDeclaration(
		typeof data.declaration === 'string' ? data.declaration : null
	);
	var declaration = stored.declaration;
	composerState.loadProblem = stored.problem;
	composerState.declaration = declaration !== null ? declaration : composerDefaultDeclaration();
	composerState.opened = true;
	composerState.dirty = false;
	composerState.busy = false;
	composerState.selected = '';
	composerShowView(true);
	composerRebuild();
	composerRender();
};

/** Called by the host with the outcome of a save or a removal. */
window.composerResult = function (result) {
	if (!result || typeof result !== 'object') return;
	composerState.busy = false;
	composerState.result = {
		action: String(result.action),
		ok: composerTrue(result.ok),
		code: result.code,
		detail: result.detail,
		used: composerTrue(result.used)
	};
	if (composerTrue(result.ok)) {
		composerState.dirty = false;
		if (result.action === 'composer_save') {
			composerState.stored = true;
			composerState.active = composerTrue(result.used);
		} else if (result.action === 'composer_remove') {
			composerState.stored = false;
			composerState.active = false;
		}
	}
	composerRenderStatus();
};

/** Shows the composer in place of the layout list, or the reverse. */
function composerShowView(show) {
	composerEl('composer').hidden = !show;
	composerEl('layout-view').hidden = show;
}

function composerSave(use) {
	if (composerState.built === null) return;
	composerState.busy = true;
	composerState.result = null;
	send('composer_save', undefined, {
		declaration: LayoutComposer.writeDeclaration(composerState.declaration),
		keylayout: LayoutComposer.serialize(composerState.built, LAYOUT_COMPOSER_DATA),
		use: use
	});
	composerRenderStatus();
}

// ============================
// ======= 7/ Events ==========
// ============================

composerEl('btn-compose').addEventListener('click', function () {
	send('composer_open');
});

composerEl('composer-back').addEventListener('click', function () {
	composerShowView(false);
});

composerEl('composer-name').addEventListener('input', function () {
	if (!composerState.declaration) return;
	composerState.declaration.name = composerEl('composer-name').value;
	composerState.dirty = true;
	composerState.result = null;
	composerRebuild();
	composerRenderStatus();
});

composerEl('composer-form').addEventListener('change', function () {
	var form = composerEl('composer-form').value === 'ansi' ? 'ansi' : 'iso';
	composerStore(COMPOSER_FORM_STORAGE_KEY, form);
	composerState.declaration.keycode_convention = form;
	composerTouch();
});

composerEl('composer-save').addEventListener('click', function () {
	composerSave(false);
});

composerEl('composer-save-use').addEventListener('click', function () {
	composerSave(true);
});

composerEl('composer-remove').addEventListener('click', function () {
	composerState.busy = true;
	send('composer_remove');
	composerRenderStatus();
});
