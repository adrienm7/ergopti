// _shared/ui/personal_info_editor/script.js

// ===========================================================================
// Personal Info Editor UI Script.
//
// Renders a host-supplied list of personal-information fields and reports the
// edited values back through the host bridge. The same script drives the
// Windows WebView2 host and the macOS WKWebView host: window.initData injects
// the fields + UI strings, and _post() relays save/cancel/ready actions
// host-agnostically (window.chrome.webview on Windows, window.webkit on macOS).
// ===========================================================================

// =================================
// =================================
// ======= 1/ State ================
// =================================
// =================================

let _strings = {};
let _initialValues = new WeakMap();
let _initialized = false;

/**
 * Returns the translated string for key, or the key itself as a fallback.
 * @param {string} key - The i18n key.
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}

/**
 * Applies translations from _strings to every element carrying data-i18n.
 * @returns {void}
 */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		const key = el.getAttribute('data-i18n');
		if (_strings[key] === undefined) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
}

// =================================
// =================================
// ======= 2/ Host Bridge ==========
// =================================
// =================================

const _post = makeHostBridge('hsPersonalInfo');

// =================================
// =================================
// ======= 3/ Rendering ============
// =================================
// =================================

/**
 * Called by the host once the webview is ready, with the field list + strings.
 * @param {Object} data - {fields: [{key, label, value, hint}], strings}
 * @returns {void}
 */
window.initData = function (data) {
	data = data || {};
	if (data.strings) {
		_strings = data.strings;
		applyDomStrings();
	}

	if (_initialized || !Array.isArray(data.fields)) return;
	const rows = document.getElementById('rows');
	rows.innerHTML = '';
	_initialValues = new WeakMap();
	(data.fields || []).forEach(function (f) {
		const row = document.createElement('div');
		row.className = 'row';

		const label = document.createElement('label');
		label.textContent = f.hint ? f.label + ' ' + f.hint : f.label;

		const original = typeof f.value === 'string' ? f.value : '';
		// Every field is a textarea so a single-line value can still become
		// multiline; an input would silently drop the typed line breaks.
		const input = document.createElement('textarea');
		input.setAttribute('rows', /[\r\n]/.test(original) ? '3' : '1');
		input.setAttribute('name', f.key);
		input.setAttribute('autocomplete', 'off');
		input.value = original;
		// A textarea normalizes CR/CRLF; retain untouched source bytes on save.
		_initialValues.set(input, { original, displayed: input.value });

		row.appendChild(label);
		row.appendChild(input);
		rows.appendChild(row);
	});

	_initialized = true;
	const first = document.querySelector('#rows input, #rows textarea');
	if (first) first.focus();
};

/**
 * Collects the current field values keyed by field name.
 * @returns {Object} A map of {key: value}.
 */
function collectValues() {
	const values = Object.create(null);
	document.querySelectorAll('#rows input, #rows textarea').forEach(function (input) {
		const initial = _initialValues.get(input);
		values[input.getAttribute('name')] =
			initial && input.value === initial.displayed ? initial.original : input.value;
	});
	return values;
}

// =================================
// =================================
// ======= 4/ Event Wiring =========
// =================================
// =================================

document.getElementById('btn-save').addEventListener('click', function () {
	_post({ action: 'save', values: collectValues() });
});

document.getElementById('btn-cancel').addEventListener('click', function () {
	_post({ action: 'cancel' });
});

document.addEventListener('keydown', function (event) {
	if (event.key === 'Escape') _post({ action: 'cancel' });
});

// Best-effort readiness hint; the host also injects initData on navigation
// completion, so both paths are idempotent.
document.addEventListener('DOMContentLoaded', function () {
	_post({ action: 'ready' });
});
