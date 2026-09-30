// _shared/ui/onboarding/script.js

// =======================================
// =======================================
// ======= 1/ Constants and state ========
// =======================================
// =======================================

// Supported locales, replaced by the host's list (initData.locales) before the
// first render so the wizard and every tray language menu share one order.
var LOCALES = [
	{ code: 'en', flag: '🇬🇧', name: 'English' },
	{ code: 'fr', flag: '🇫🇷', name: 'Français' }
];

// Locale shown until the host names the current one.
var DEFAULT_LOCALE_CODE = 'en';

// The catalogue format this page renders; generated with the same number by
// tools/codegen/codegen-onboarding-catalogue.cjs.
var CATALOGUE_SCHEMA_VERSION = 1;

// Steps that precede the configuration pages.
var STEP_LANGUAGE = 'language';
var STEP_CONFIG = 'config';

// Placeholder a label key fills with the value label ("Right Opt + Return → %s").
var VALUE_PLACEHOLDER = '%s';

// Separator between a slot's label and its action when the key has no placeholder.
var VALUE_SEPARATOR = ' → ';

// Radio value of the custom trigger-character row.
var CUSTOM_MAGIC_VALUE = '__custom__';

// Locale strings injected by the host (initData / applyStrings).
var _strings = {};

// Wizard state.
var _selectedLocale = DEFAULT_LOCALE_CODE;
var _platform = '';
var _pages = [];
var _steps = [STEP_LANGUAGE, STEP_CONFIG];
var _stepIndex = 0;
var _configDir = '';
var _loadedDir = '';
var _current = {};
var _pageState = {};

// Metrics store path named by the consent text, resolved by the host for the
// folder chosen on the config step. Replies carrying an older request number
// belong to a folder the user has since changed and are dropped.
var _metricsPath = '';
var _metricsRequest = 0;

// Request number of the latest loadExistingConfig; older replies are dropped.
var _configRequest = 0;

// makeHostBridge probes WebView2 (Windows) first and returns synchronously.
var _post = makeHostBridge('hsOnboarding');

// ======================================
// ======================================
// ======= 2/ Labels ====================
// ======================================
// ======================================

/**
 * Returns the translated string for key, or the key itself when missing.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}

/**
 * Resolves one catalogue label segment in the selected locale.
 * @param {{key?: string, text?: string, text_ref?: string}} segment
 * @returns {string}
 */
function _segment(segment) {
	if (typeof segment.key === 'string') return _t(segment.key);
	if (typeof segment.text === 'string') return segment.text;
	var translations = _catalogue().texts[segment.text_ref];
	return translations && translations[_selectedLocale]
		? translations[_selectedLocale]
		: segment.text_ref;
}

/**
 * Joins a catalogue label.
 * @param {Array<object>} segments
 * @returns {string}
 */
function _label(segments) {
	return segments.map(_segment).join('');
}

/**
 * The label of a checklist item, with the imported action when it is a slot.
 * @param {object} item
 * @returns {string}
 */
function _itemLabel(item) {
	var base = _label(item.label);
	if (!item.value_label) return base;
	var value = _segment(item.value_label);
	// split/join, not replace: a label containing "$&" must stay literal.
	if (base.indexOf(VALUE_PLACEHOLDER) !== -1) return base.split(VALUE_PLACEHOLDER).join(value);
	return base + VALUE_SEPARATOR + value;
}

/**
 * Fills the {n} placeholders of a translated template literally.
 * @param {string} template
 * @param {Array<string|number>} values
 * @returns {string}
 */
function _format(template, values) {
	var out = template;
	values.forEach(function (value, index) {
		out = out.split('{' + (index + 1) + '}').join(String(value));
	});
	return out;
}

// ======================================
// ======================================
// ======= 3/ Catalogue model ===========
// ======================================
// ======================================

/**
 * The generated catalogue, refusing a missing or foreign-format one.
 * @returns {object}
 */
function _catalogue() {
	var catalogue = window.ONBOARDING_CATALOGUE;
	if (!catalogue || catalogue.schema_version !== CATALOGUE_SCHEMA_VERSION) {
		throw new Error('onboarding catalogue is missing or has an unsupported format');
	}
	return catalogue;
}

/**
 * Structural equality over configuration values.
 * @param {*} left
 * @param {*} right
 * @returns {boolean}
 */
function _sameValue(left, right) {
	return JSON.stringify(left) === JSON.stringify(right);
}

/**
 * The configuration value currently in force at a path.
 * @param {{path: string, default: *}} entry
 * @returns {*}
 */
function _currentValue(entry) {
	return Object.prototype.hasOwnProperty.call(_current, entry.path)
		? _current[entry.path]
		: entry.default;
}

/**
 * Whether an importable entry (item or file switch) is already on.
 * @param {{path: string, value: *, default: *}} entry
 * @returns {boolean}
 */
function _currentlyOn(entry) {
	return _sameValue(_currentValue(entry), entry.value);
}

/**
 * Visits every checklist item of a group tree.
 * @param {Array<object>} groups
 * @param {function(object): void} visit
 */
function _eachItem(groups, visit) {
	groups.forEach(function (group) {
		(group.items || []).forEach(visit);
		_eachItem(group.groups || [], visit);
	});
}

/**
 * Visits every group that persists a switch of its own (a hotstring file).
 * @param {Array<object>} groups
 * @param {function(object): void} visit
 */
function _eachGate(groups, visit) {
	groups.forEach(function (group) {
		if (typeof group.path === 'string') visit(group);
		_eachGate(group.groups || [], visit);
	});
}

/**
 * Counts the checked and total items below a group.
 * @param {object} group
 * @param {object} state Page state.
 * @returns {{checked: number, total: number}}
 */
function _countItems(group, state) {
	var counts = { checked: 0, total: 0 };
	_eachItem([group], function (item) {
		counts.total += 1;
		if (state.checked[item.path]) counts.checked += 1;
	});
	return counts;
}

/**
 * Builds a page's answer from the configuration in force: the question starts
 * at the category switch's value (No when absent) and every item at whether it
 * is already imported.
 * @param {object} page
 * @returns {object}
 */
function _initialState(page) {
	var state = { answer: false, checked: {}, prefilled: false, magic: null, custom: '' };
	var anyOn = false;
	_eachItem(page.groups, function (item) {
		var on = _currentlyOn(item);
		state.checked[item.path] = on;
		if (on) anyOn = true;
	});
	state.answer = page.master ? _currentValue(page.master) === true : anyOn;
	// An existing selection is shown as it is; only a page with nothing imported
	// yet receives the recommendation when its question turns to Yes.
	state.prefilled = anyOn;
	if (page.magic_key && Object.prototype.hasOwnProperty.call(_current, page.magic_key.path)) {
		state.magic = _current[page.magic_key.path];
	}
	return state;
}

/** Rebuilds every page's state from the configuration in force. */
function _resetStates() {
	_pageState = {};
	_pages.forEach(function (page) {
		_pageState[page.id] = _initialState(page);
	});
}

/**
 * Sets a page's answer, applying the recommendation the first time it turns Yes.
 * @param {object} page
 * @param {boolean} answer
 */
function _setAnswer(page, answer) {
	var state = _pageState[page.id];
	state.answer = answer;
	if (answer && !state.prefilled) {
		_eachItem(page.groups, function (item) {
			state.checked[item.path] = item.recommended === true;
		});
		state.prefilled = true;
	}
}

/**
 * Whether a page asks its question: a category switch or something to import.
 * @param {object} page
 * @returns {boolean}
 */
function _asks(page) {
	return !!page.master || page.groups.length > 0;
}

/**
 * The trigger character a page proposes when the configuration names none:
 * the Ergopti key when the Ergopti layout is used, ù on French layouts, ;
 * elsewhere.
 * @param {object} choice The page's magic_key descriptor.
 * @returns {string}
 */
function _contextMagicKey(choice) {
	var layoutPage = _pageState.keyboard_layout;
	var system = (window.SYSTEM_LAYOUT || '').toLowerCase();
	if ((layoutPage && layoutPage.answer) || system.indexOf('ergopti') !== -1)
		return choice.recommended;
	if (system.indexOf('french') !== -1 || system.indexOf('azerty') !== -1) return 'ù';
	return ';';
}

/**
 * The trigger character currently chosen on a page, or "" for an empty custom entry.
 * @param {object} page
 * @returns {string}
 */
function _magicValue(page) {
	var state = _pageState[page.id];
	if (state.magic === CUSTOM_MAGIC_VALUE) return state.custom.trim();
	if (typeof state.magic === 'string') return state.magic;
	return _contextMagicKey(page.magic_key);
}

/**
 * The manifest paths and values the answers change. The category switch is
 * always explicit; items are written only where the answer differs from the
 * configuration in force, so a value set elsewhere is never overwritten by a
 * checklist the user left alone.
 * @returns {Array<{path: string, value: *}>}
 */
function _operations() {
	var operations = [];
	_pages.forEach(function (page) {
		var state = _pageState[page.id];
		if (page.master) operations.push({ path: page.master.path, value: state.answer });
		if (!state.answer) return;
		_eachItem(page.groups, function (item) {
			var wanted = state.checked[item.path] === true;
			if (wanted !== _currentlyOn(item)) {
				operations.push({ path: item.path, value: wanted ? item.value : item.default });
			}
		});
		_eachGate(page.groups, function (gate) {
			var wanted = _countItems(gate, state).checked > 0;
			if (wanted !== _currentlyOn(gate)) {
				operations.push({ path: gate.path, value: wanted ? gate.value : gate.default });
			}
		});
		if (page.magic_key) {
			var chosen = _magicValue(page);
			if (chosen !== _currentValue(page.magic_key)) {
				operations.push({ path: page.magic_key.path, value: chosen });
			}
		}
	});
	return operations;
}

// ======================================
// ======================================
// ======= 4/ Step navigation ===========
// ======================================
// ======================================

/**
 * The configuration page shown at a step index, or null.
 * @param {number} index
 * @returns {object|null}
 */
function _pageAt(index) {
	var id = _steps[index];
	for (var i = 0; i < _pages.length; i++) {
		if (_pages[i].id === id) return _pages[i];
	}
	return null;
}

/** Draws one dot per step, marking the done and active ones. */
function _renderStepBar() {
	var bar = document.getElementById('step-bar');
	bar.innerHTML = '';
	_steps.forEach(function (_id, index) {
		var dot = document.createElement('div');
		dot.className = 'step-dot';
		if (index < _stepIndex) dot.classList.add('done');
		else if (index === _stepIndex) dot.classList.add('active');
		bar.appendChild(dot);
	});
}

/** Shows the current step and its footer buttons. */
function _render() {
	var step = _steps[_stepIndex];
	document.getElementById('step-language').classList.toggle('hidden', step !== STEP_LANGUAGE);
	document.getElementById('step-config').classList.toggle('hidden', step !== STEP_CONFIG);
	var page = _pageAt(_stepIndex);
	document.getElementById('step-page').classList.toggle('hidden', !page);
	if (step === STEP_LANGUAGE) _renderLanguage();
	else if (step === STEP_CONFIG) _renderConfig();
	else _renderPage(page);
	_renderStepBar();
	var back = document.getElementById('btn-back');
	back.textContent = _t('onboarding.back');
	back.classList.toggle('hidden', _stepIndex === 0);
	var last = _stepIndex === _steps.length - 1;
	document.getElementById('btn-next').textContent = _t(
		last ? 'onboarding.finish' : 'onboarding.next'
	);
	document.title = _t('onboarding.welcome.title');
}

/**
 * Moves to a step.
 * @param {number} index
 */
function _go(index) {
	_stepIndex = index;
	_render();
	var scroller = document.getElementById('step-scroll');
	if (scroller) scroller.scrollTop = 0;
}

// ======================================
// ======================================
// ======= 5/ Step renderers ============
// ======================================
// ======================================

/** Builds the language list and pre-selects the current locale. */
function _renderLanguage() {
	var list = document.getElementById('lang-list');
	list.innerHTML = '';
	LOCALES.forEach(function (loc) {
		var row = document.createElement('div');
		row.className = 'lang-item' + (loc.code === _selectedLocale ? ' selected' : '');
		row.dataset.code = loc.code;

		var flag = document.createElement('span');
		flag.className = 'lang-flag';
		// Windows has no flag-emoji font, so its host injects a flag_url.
		if (loc.flag_url) {
			var flagImg = document.createElement('img');
			flagImg.className = 'lang-flag-img';
			flagImg.src = loc.flag_url;
			flagImg.alt = '';
			flag.appendChild(flagImg);
		} else {
			flag.textContent = loc.flag;
		}

		var name = document.createElement('span');
		name.className = 'lang-name';
		name.textContent = loc.name;

		row.appendChild(flag);
		row.appendChild(name);
		row.addEventListener('click', function () {
			_selectedLocale = loc.code;
			_renderLanguage();
			// The host answers with applyStrings for the previewed locale.
			_post({ action: 'previewLocale', locale: loc.code });
		});
		list.appendChild(row);
	});
	var selected = list.querySelector('.lang-item.selected');
	if (selected) selected.scrollIntoView({ block: 'nearest' });
	document.getElementById('language-title').textContent = _t('onboarding.welcome.title');
	document.getElementById('language-subtitle').textContent = _t('onboarding.welcome.heading');
}

/** Refreshes the configuration-folder step from the answers. */
function _renderConfig() {
	document.getElementById('config-title').textContent = _t('dialog.config_folder.title');
	document.getElementById('config-desc').textContent = _t('dialog.config_folder.label');
	document.getElementById('config-hint').textContent = _t('dialog.config_folder.hint');
	document.getElementById('config-browse').textContent = _t('common.browse');
	var input = document.getElementById('config-input');
	input.value = _configDir;
	input.placeholder = window.DEFAULT_CONFIG_DIR || '';
}

/**
 * Shows a text block, or hides it when there is nothing to say.
 * @param {string} id Element id.
 * @param {string} text
 */
function _showText(id, text) {
	var el = document.getElementById(id);
	el.textContent = text;
	el.classList.toggle('hidden', text === '');
}

/**
 * Renders one configuration page.
 * @param {object} page
 */
function _renderPage(page) {
	var state = _pageState[page.id];
	document.getElementById('page-title').textContent = _t(page.title_key);
	document.getElementById('page-desc').textContent = _t(page.description_key);
	_showText(
		'page-consent',
		page.consent ? _t('dialog.metrics.enable_warning').split('{1}').join(_metricsPath) : ''
	);
	_showText('page-hint', page.hint_key ? _t(page.hint_key) : '');
	_showText('page-note', page.note_key ? _t(page.note_key) : '');

	var asks = _asks(page);
	document.getElementById('page-question').classList.toggle('hidden', !asks);
	document.getElementById('page-question-label').textContent = _t(page.question_key);
	document.getElementById('page-yes-label').textContent = _t('onboarding.yes');
	document.getElementById('page-no-label').textContent = _t('onboarding.no');
	document.getElementById('page-yes').checked = state.answer;
	document.getElementById('page-no').checked = !state.answer;

	_renderRegister(page, state);
	_renderMagicKey(page, state);
	_renderChecklist(page, state);
}

/**
 * Shows the Windows gesture-registration panel on the gestures page when the
 * answer is Yes.
 * @param {object} page
 * @param {object} state
 */
function _renderRegister(page, state) {
	var panel = document.getElementById('page-register');
	var shown = _platform === 'windows' && page.id === 'gestures' && state.answer;
	panel.classList.toggle('hidden', !shown);
	if (!shown) return;
	document.getElementById('register-section').textContent = _t(
		'onboarding.gestures.register_section'
	);
	document.getElementById('register-auto').textContent = _t('onboarding.gestures.register_auto');
	document.getElementById('register-auto-hint').textContent = _t(
		'onboarding.gestures.register_auto_hint'
	);
	document.getElementById('register-manual').textContent = _t(
		'onboarding.gestures.register_manual'
	);
	document.getElementById('register-manual-hint').textContent = _t(
		'onboarding.gestures.register_manual_hint'
	);
}

/**
 * Renders the trigger-character choice of a page that declares one.
 * @param {object} page
 * @param {object} state
 */
function _renderMagicKey(page, state) {
	var box = document.getElementById('page-magic');
	var choice = page.magic_key;
	box.classList.toggle('hidden', !choice || !state.answer);
	if (!choice || !state.answer) return;
	document.getElementById('page-magic-label').textContent = _t(choice.label_key);
	document.getElementById('page-magic-hint').textContent = _t(choice.hint_key);
	var container = document.getElementById('page-magic-options');
	container.innerHTML = '';
	var chosen = _magicValue(page);
	var isPreset =
		state.magic !== CUSTOM_MAGIC_VALUE &&
		choice.options.some(function (option) {
			return option.value === chosen;
		});
	choice.options.forEach(function (option) {
		container.appendChild(
			_magicRow(page, option.value, _t(option.label_key), isPreset && chosen === option.value)
		);
	});
	var custom = _magicRow(page, CUSTOM_MAGIC_VALUE, _t(choice.custom_label_key), !isPreset);
	var input = document.createElement('input');
	input.type = 'text';
	input.className = 'magic-input';
	input.maxLength = choice.max_characters;
	input.value = isPreset
		? state.custom
		: state.magic === CUSTOM_MAGIC_VALUE
			? state.custom
			: chosen;
	input.disabled = isPreset;
	input.addEventListener('input', function () {
		state.magic = CUSTOM_MAGIC_VALUE;
		state.custom = input.value;
		input.classList.remove('invalid');
	});
	custom.appendChild(input);
	container.appendChild(custom);
}

/**
 * One radio row of the trigger-character choice.
 * @param {object} page
 * @param {string} value
 * @param {string} text
 * @param {boolean} checked
 * @returns {object} The row element.
 */
function _magicRow(page, value, text, checked) {
	var state = _pageState[page.id];
	var row = document.createElement('label');
	row.className = 'radio-card';
	var radio = document.createElement('input');
	radio.type = 'radio';
	radio.name = 'magic';
	radio.value = value;
	radio.checked = checked;
	radio.addEventListener('change', function () {
		if (!radio.checked) return;
		if (value === CUSTOM_MAGIC_VALUE && state.magic !== CUSTOM_MAGIC_VALUE) {
			state.custom = state.custom || _magicValue(page);
		}
		state.magic = value;
		_renderMagicKey(page, state);
	});
	var label = document.createElement('span');
	label.className = 'radio-label';
	label.textContent = text;
	row.appendChild(radio);
	row.appendChild(label);
	return row;
}

/**
 * Renders the collapsible checklist: disabled and unchecked while the answer is
 * No, the retained selection when it is Yes.
 * @param {object} page
 * @param {object} state
 */
function _renderChecklist(page, state) {
	var details = document.getElementById('page-checklist');
	details.classList.toggle('hidden', page.groups.length === 0);
	if (page.groups.length === 0) return;
	var counts = { checked: 0, total: 0 };
	page.groups.forEach(function (group) {
		var groupCounts = _countItems(group, state);
		counts.checked += groupCounts.checked;
		counts.total += groupCounts.total;
	});
	document.getElementById('page-checklist-summary').textContent = _format(
		_t('onboarding.checklist.summary'),
		[state.answer ? counts.checked : 0, counts.total]
	);
	_showText('page-checklist-inactive', state.answer ? '' : _t('onboarding.checklist.inactive'));
	var body = document.getElementById('page-checklist-body');
	body.innerHTML = '';
	page.groups.forEach(function (group) {
		body.appendChild(_groupNode(page, group, state, 0));
	});
}

/**
 * A group of the checklist: a header whose checkbox selects every item below
 * it, then its items and sub-groups.
 * @param {object} page
 * @param {object} group
 * @param {object} state
 * @param {number} depth
 * @returns {object} The group element.
 */
function _groupNode(page, group, state, depth) {
	var node = document.createElement('div');
	node.className = 'checklist-group depth-' + depth;
	if (group.label) {
		var counts = _countItems(group, state);
		var header = _checkRow(
			_label(group.label),
			state.answer && counts.checked === counts.total && counts.total > 0,
			state.answer && counts.checked > 0 && counts.checked < counts.total,
			!state.answer,
			function (checked) {
				_eachItem([group], function (item) {
					state.checked[item.path] = checked;
				});
				_renderChecklist(page, state);
			}
		);
		header.classList.add('checklist-group-header');
		node.appendChild(header);
	}
	(group.items || []).forEach(function (item) {
		node.appendChild(
			_checkRow(
				_itemLabel(item),
				state.answer && state.checked[item.path] === true,
				false,
				!state.answer,
				function (checked) {
					state.checked[item.path] = checked;
					_renderChecklist(page, state);
				}
			)
		);
	});
	(group.groups || []).forEach(function (child) {
		node.appendChild(_groupNode(page, child, state, depth + 1));
	});
	return node;
}

/**
 * One checkbox row.
 * @param {string} text
 * @param {boolean} checked
 * @param {boolean} mixed
 * @param {boolean} disabled
 * @param {function(boolean): void} onChange
 * @returns {object} The row element.
 */
function _checkRow(text, checked, mixed, disabled, onChange) {
	var row = document.createElement('label');
	row.className = 'check-row';
	var box = document.createElement('input');
	box.type = 'checkbox';
	box.checked = checked;
	box.indeterminate = mixed;
	box.disabled = disabled;
	box.addEventListener('change', function () {
		onChange(box.checked);
	});
	var label = document.createElement('span');
	label.className = 'check-label';
	label.textContent = text;
	row.appendChild(box);
	row.appendChild(label);
	return row;
}

// ======================================
// ======================================
// ======= 6/ Host bridge ===============
// ======================================
// ======================================

/**
 * Called by the host with the strings of a locale, either as a flat map (the
 * initData path) or as a {locale, strings} envelope. A stale envelope from a
 * rapid language switch is discarded.
 * @param {Object} payload
 */
window.applyStrings = function (payload) {
	var strings;
	if (payload && typeof payload.strings === 'object' && typeof payload.locale === 'string') {
		if (payload.locale !== _selectedLocale) return;
		strings = payload.strings;
	} else {
		strings = payload || {};
	}
	_strings = strings;
	if (_platform !== '') _render();
	document.title = _t('onboarding.welcome.title');
};

/**
 * Called by the host once the page is ready.
 * @param {{locale: string, strings: Object, locales: Array, platform: string,
 *   default_config_dir: string, config_dir: string, current: Object,
 *   metrics_path: string, system_layout?: string}} data
 */
window.initData = function (data) {
	var catalogue = _catalogue();
	var platform = catalogue.platforms[data.platform];
	if (!platform) throw new Error('onboarding host names an unknown platform: ' + data.platform);
	_platform = data.platform;
	_pages = platform.pages;
	_steps = [STEP_LANGUAGE, STEP_CONFIG].concat(
		_pages.map(function (page) {
			return page.id;
		})
	);
	if (typeof data.locale === 'string') _selectedLocale = data.locale;
	if (Array.isArray(data.locales) && data.locales.length > 0) LOCALES = data.locales;
	window.DEFAULT_CONFIG_DIR = data.default_config_dir || '';
	window.SYSTEM_LAYOUT = data.system_layout || '';
	_configDir = typeof data.config_dir === 'string' ? data.config_dir : '';
	_loadedDir = _configDir;
	_current = data.current && typeof data.current === 'object' ? data.current : {};
	_metricsPath = typeof data.metrics_path === 'string' ? data.metrics_path : '';
	_resetStates();
	_strings = data.strings || {};
	_go(0);
};

/**
 * Called by the host after the native folder picker resolves.
 * @param {string} path
 */
window.setConfigDir = function (path) {
	if (typeof path !== 'string' || path === '') return;
	_configDir = path;
	var input = document.getElementById('config-input');
	if (input) input.value = path;
};

/**
 * Called by the host in reply to resolveMetricsPath.
 * @param {{request: number, path: string}} payload
 */
window.setMetricsPath = function (payload) {
	if (!payload || typeof payload.path !== 'string') return;
	if (payload.request !== _metricsRequest) return;
	_metricsPath = payload.path;
	if (_pageAt(_stepIndex)) _render();
};

/**
 * Called by the host with the configuration found in the folder chosen on the
 * config step: every page restarts from those values.
 * @param {{request: number, values: Object}} payload
 */
window.applyCurrentValues = function (payload) {
	if (!payload || typeof payload.values !== 'object' || payload.values === null) return;
	if (payload.request !== _configRequest) return;
	_current = payload.values;
	_resetStates();
	if (_pageAt(_stepIndex)) _render();
};

/**
 * Called by the host when the Windows touchpad registration finishes.
 * @param {boolean} ok
 */
window.setGestureRegisterStatus = function (ok) {
	var el = document.getElementById('register-status');
	el.textContent = _t(
		ok ? 'onboarding.gestures.register_success' : 'onboarding.gestures.register_failed'
	);
	el.classList.remove('hidden');
	el.classList.toggle('register-ok', !!ok);
	el.classList.toggle('register-err', !ok);
};

// ======================================
// ======================================
// ======= 7/ Event wiring ==============
// ======================================
// ======================================

/** Leaves the config step: the folder's configuration and metrics store. */
function _leaveConfig() {
	_configDir = (document.getElementById('config-input').value || '').trim();
	if (_configDir !== _loadedDir) {
		_loadedDir = _configDir;
		_configRequest += 1;
		_post({ action: 'loadExistingConfig', config_dir: _configDir, request: _configRequest });
	}
	_metricsRequest += 1;
	_post({ action: 'resolveMetricsPath', config_dir: _configDir, request: _metricsRequest });
}

/**
 * Refuses to leave a page whose custom trigger character is empty.
 * @param {object|null} page
 * @returns {boolean} Whether the page can be left.
 */
function _pageComplete(page) {
	if (!page || !page.magic_key || !_pageState[page.id].answer) return true;
	if (_magicValue(page) !== '') return true;
	var input = document.getElementById('page-magic-options').querySelector('.magic-input');
	if (input) {
		input.classList.add('invalid');
		input.focus();
	}
	return false;
}

document.getElementById('btn-next').addEventListener('click', function () {
	var step = _steps[_stepIndex];
	if (step === STEP_LANGUAGE) {
		_post({ action: 'localeSelected', locale: _selectedLocale });
	} else if (step === STEP_CONFIG) {
		_leaveConfig();
	} else if (!_pageComplete(_pageAt(_stepIndex))) {
		return;
	}
	if (_stepIndex < _steps.length - 1) {
		_go(_stepIndex + 1);
		return;
	}
	_post({
		action: 'finish',
		answers: { locale: _selectedLocale, config_dir: _configDir, operations: _operations() }
	});
});

document.getElementById('btn-back').addEventListener('click', function () {
	if (_steps[_stepIndex] === STEP_CONFIG) {
		_configDir = (document.getElementById('config-input').value || '').trim();
	}
	if (_stepIndex > 0) _go(_stepIndex - 1);
});

document.getElementById('config-browse').addEventListener('click', function () {
	_post({ action: 'pickConfigDir', current: document.getElementById('config-input').value || '' });
});

['page-yes', 'page-no'].forEach(function (id) {
	document.getElementById(id).addEventListener('change', function () {
		var page = _pageAt(_stepIndex);
		if (!page) return;
		_setAnswer(page, document.getElementById('page-yes').checked);
		_renderPage(page);
	});
});

document.getElementById('register-auto').addEventListener('click', function () {
	_post({ action: 'registerGesturesAuto' });
});
document.getElementById('register-manual').addEventListener('click', function () {
	_post({ action: 'registerGesturesManual' });
});

// Signal the host once the DOM the initData render targets exists.
if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', function () {
		_post({ action: 'ready' });
	});
} else {
	_post({ action: 'ready' });
}
