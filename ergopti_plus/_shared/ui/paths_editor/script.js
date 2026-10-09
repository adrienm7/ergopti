// _shared/ui/paths_editor/script.js

// ========================================
// ========================================
// ======= 1/ State =======================
// ========================================
// ========================================

// Full payload received from Lua on init
let _data = null;

// Locale strings — populated by initData; used by _t() and applyDomStrings()
let _strings = {};

/**
 * Returns the translated string for key, or key itself as fallback.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}

/**
 * Applies translations from _strings to every DOM element carrying data-i18n.
 * Handles the <title> element via document.title as a special case.
 */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		var key = el.getAttribute('data-i18n');
		if (_strings[key] === undefined) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
}

// The two edited folders, keyed by the target name the hosts answer to:
// "config" (ConfigDirPath) and "logs" (LogsDirPath). Each entry names its DOM
// ids and the payload fields holding its current and default value.
const FIELDS = {
	config: {
		input: 'input-config-dir',
		tag: 'tag-config-dir',
		defaultText: 'default-config-dir',
		browse: 'btn-browse',
		current: 'configDir',
		fallback: 'defaultConfigDir',
		value: ''
	},
	logs: {
		input: 'input-logs-dir',
		tag: 'tag-logs-dir',
		defaultText: 'default-logs-dir',
		browse: 'btn-browse-logs',
		current: 'logsDir',
		fallback: 'defaultLogsDir',
		value: ''
	}
};

// =====================================
// =====================================
// ======= 2/ DOM Helpers ==============
// =====================================
// =====================================

/**
 * Updates one field's tag (default/modified) from its value vs its default.
 * @param {string} name Field key in FIELDS.
 */
function refreshTag(name) {
	if (!_data) return;
	const field = FIELDS[name];
	const inp = document.getElementById(field.input);
	const tag = document.getElementById(field.tag);
	if (!inp || !tag) return;
	const isDefault = field.value === _data[field.fallback];
	inp.classList.toggle('is-default', isDefault);
	tag.textContent = isDefault ? _t('paths_editor.tag_default') : _t('paths_editor.tag_modified');
	tag.className = isDefault ? 'tag-default' : 'tag-modified';
}

/**
 * Sets one field's value in the state and the input, then refreshes its tag.
 * @param {string} name Field key in FIELDS.
 * @param {string} value New folder.
 */
function setField(name, value) {
	const field = FIELDS[name];
	field.value = value;
	const inp = document.getElementById(field.input);
	if (inp) inp.value = value;
	refreshTag(name);
}

// =============================================
// =============================================
// ======= 3/ Host Bridge ======================
// =============================================
// =============================================

const _post = makeHostBridge('hsPaths');

/**
 * Called by the host once the webview is ready, with initial data.
 * @param {Object} data - {configDir, defaultConfigDir, logsDir, defaultLogsDir, strings}
 */
window.initData = function (data) {
	_data = data;
	if (data.strings) {
		_strings = data.strings;
		applyDomStrings();
	}
	Object.keys(FIELDS).forEach(function (name) {
		const field = FIELDS[name];
		const shown = document.getElementById(field.defaultText);
		if (shown) shown.textContent = data[field.fallback] || '';
		setField(name, data[field.current] || data[field.fallback] || '');
	});
};

/**
 * Called by the host after the user picks a folder via the native folder picker.
 * @param {string} path - The picked absolute directory path (with trailing slash).
 * @param {string} [target] - "logs" for the logs folder; the configuration folder otherwise.
 */
window.applyBrowseResult = function (path, target) {
	if (!path) return;
	setField(target === 'logs' ? 'logs' : 'config', path);
};

// ==========================================
// ==========================================
// ======= 4/ Input Listeners ===============
// ==========================================
// ==========================================

Object.keys(FIELDS).forEach(function (name) {
	const field = FIELDS[name];
	document.getElementById(field.input).addEventListener('input', function (event) {
		field.value = event.target.value;
		refreshTag(name);
	});
	document.getElementById(field.browse).addEventListener('click', function () {
		setTimeout(function () {
			_post({ action: 'browse', target: name });
		}, 0);
	});
});

// ==========================================
// ==========================================
// ======= 5/ Button Actions ================
// ==========================================
// ==========================================

document.getElementById('btn-save').addEventListener('click', function () {
	setTimeout(function () {
		_post({ action: 'save', configDir: FIELDS.config.value, logsDir: FIELDS.logs.value });
	}, 0);
});

document.getElementById('btn-cancel').addEventListener('click', function () {
	setTimeout(function () {
		_post({ action: 'cancel' });
	}, 0);
});

document.getElementById('btn-reset').addEventListener('click', function () {
	if (!_data) return;
	Object.keys(FIELDS).forEach(function (name) {
		setField(name, _data[FIELDS[name].fallback] || '');
	});
});

// ========================================
// ========================================
// ======= 6/ Ready Signal =================
// ========================================
// ========================================

// Signal Lua that the page is ready. Lua also injects initData on
// didFinishNavigation as a fallback — this postMessage is a best-effort hint.
(function () {
	setTimeout(function () {
		_post({ action: 'ready' });
	}, 0);
})();
