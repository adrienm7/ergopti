// _shared/ui/model_browser/script.js

/**
 * ==============================================================================
 * MODULE: Model Browser UI Script
 * DESCRIPTION:
 * Renders the curated LLM model catalogue as a sortable, filterable table and
 * lets the user pick a model. Shared verbatim by the macOS Hammerspoon driver
 * (hs.webview) and the Windows AHK driver (WebView2): both inject the catalogue
 * via injectModels() and receive the chosen model through postBridgeMessage().
 *
 * FEATURES & RATIONALE:
 * 1. Bridge-agnostic: postBridgeMessage() targets WebView2 (window.chrome.webview)
 *    or WKWebView (window.webkit.messageHandlers.model_browser_bridge) automatically.
 * 2. Backend pushes data: the native side builds the normalised model list (params,
 *    RAM, speed, type, installed flag) from _shared/modules/llm/models.json + an install scan,
 *    so the page stays platform-neutral and never reads files itself.
 * 3. Pure client interaction: search, column sort, and selection are all in-page;
 *    only the final "use this model" / "open source page" actions cross the bridge.
 * ==============================================================================
 */

var _models = []; // Full catalogue (normalised rows), as injected by the backend.
var _backend = ''; // "mlx" | "ollama" — affects which RAM/install column applies.
var _active = ''; // Currently-selected model name (highlighted with a dot).
var _selected = null; // Name of the row the user has highlighted (pending "use").
var _sortKey = 'name';
var _sortDir = 1; // 1 = ascending, -1 = descending.

// =========================================
// =========================================
// ======= 1/ Native Bridge Interface ======
// =========================================
// =========================================

var postBridgeMessage = makeHostBridge('model_browser_bridge');

/**
 * Called by the native backend to populate the table.
 * @param {object} payload - { backend, active, models: [...] }.
 */
function injectModels(payload) {
	if (!payload || !Array.isArray(payload.models)) return;
	_models = payload.models;
	_backend = payload.backend || '';
	_active = payload.active || '';
	_selected = null;
	updateUseButton();
	render();
}

// Signal readiness so the native backend can flush its queued injectModels() call.
if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', function () {
		postBridgeMessage('ready');
	});
} else {
	postBridgeMessage('ready');
}

// =====================================
// =====================================
// ======= 2/ i18n Helper ==============
// =====================================
// =====================================

function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || null;
}

/** Re-applies labels (column headers etc.) whenever i18n strings arrive. */
function applyLabels() {
	var useBtn = document.getElementById('btn-use');
	if (useBtn) useBtn.textContent = _t('model_browser.use_button') || 'Utiliser';
	// Header / placeholder data-i18n attributes are handled by i18n.js; re-render
	// the rows so chips and dynamic cells pick up the freshest strings too.
	render();
}

var _orig_i18n_apply = window.i18n_apply;
window.i18n_apply = function (strings) {
	if (typeof _orig_i18n_apply === 'function') _orig_i18n_apply(strings);
	applyLabels();
};

// =====================================
// =====================================
// ======= 3/ Formatting Helpers =======
// =====================================
// =====================================

/** Formats a billions-of-parameters value, collapsing MoE active/total. */
function fmtParams(row) {
	var total = _num(row.params_b);
	var active = _num(row.active_b);
	if (row.is_moe && active > 0 && active < total) {
		return _trim(active) + '/' + _trim(total) + ' B';
	}
	return total > 0 ? _trim(total) + ' B' : '—';
}

function fmtRam(row) {
	var r = _num(row.ram_gb);
	return r > 0 ? _trim(r) + ' Go' : '—';
}

function fmtSpeed(row) {
	var s = _num(row.speed_tok_s);
	return s > 0 ? Math.round(s) + ' tok/s' : '—';
}

function _num(v) {
	var n = parseFloat(v);
	return isNaN(n) ? 0 : n;
}

/** Drops a trailing ".0" / ".00" so "8.00" → "8" but "4.22" stays. */
function _trim(n) {
	return parseFloat(n.toFixed(2)).toString();
}

function _escHtml(s) {
	return String(s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

// =====================================
// =====================================
// ======= 4/ Rendering ================
// =====================================
// =====================================

/** Applies the live search filter and the active sort, then rebuilds the rows. */
function render() {
	var tbody = document.getElementById('rows');
	var empty = document.getElementById('empty');
	if (!tbody) return;

	var query = (document.getElementById('search').value || '').trim().toLowerCase();
	var rows = _models.filter(function (m) {
		if (!query) return true;
		return (
			(m.name || '').toLowerCase().indexOf(query) !== -1 ||
			(m.family || '').toLowerCase().indexOf(query) !== -1 ||
			(m.provider || '').toLowerCase().indexOf(query) !== -1
		);
	});

	rows.sort(function (a, b) {
		var va = a[_sortKey];
		var vb = b[_sortKey];
		// Numeric columns sort numerically; everything else case-insensitively.
		if (_sortKey === 'params_b' || _sortKey === 'ram_gb' || _sortKey === 'speed_tok_s') {
			return (_num(va) - _num(vb)) * _sortDir;
		}
		if (_sortKey === 'installed') {
			return ((va ? 1 : 0) - (vb ? 1 : 0)) * _sortDir;
		}
		va = (va == null ? '' : String(va)).toLowerCase();
		vb = (vb == null ? '' : String(vb)).toLowerCase();
		if (va < vb) return -1 * _sortDir;
		if (va > vb) return 1 * _sortDir;
		return 0;
	});

	tbody.innerHTML = '';
	rows.forEach(function (m) {
		tbody.appendChild(buildRow(m));
	});

	if (empty) empty.style.display = rows.length === 0 ? 'block' : 'none';
	updateCount(rows.length, _models.length);
	updateSortIndicators();
}

/** Builds a single <tr> for a model row. */
function buildRow(m) {
	var tr = document.createElement('tr');
	if (m.name === _active) tr.className = 'active';

	var installedTitle = m.installed
		? _t('model_browser.status_installed') || 'Installé'
		: _t('model_browser.status_available') || 'Disponible';

	var typeKey = m.type === 'completion' ? 'model_browser.type_completion' : 'model_browser.type_chat';
	var typeLabel = _t(typeKey) || (m.type === 'completion' ? 'Complétion' : 'Chat');
	var typeClass = m.type === 'completion' ? 'chip completion' : 'chip';

	tr.innerHTML =
		'<td class="center"><span class="dot ' +
		(m.installed ? 'on' : '') +
		'" title="' +
		_escHtml(installedTitle) +
		'"></span></td>' +
		'<td class="name-cell">' +
		_escHtml(m.name || '') +
		'</td>' +
		'<td>' +
		_escHtml(m.family || '') +
		'</td>' +
		'<td class="num">' +
		_escHtml(fmtParams(m)) +
		'</td>' +
		'<td class="num">' +
		_escHtml(fmtRam(m)) +
		'</td>' +
		'<td class="num">' +
		_escHtml(fmtSpeed(m)) +
		'</td>' +
		'<td><span class="' +
		typeClass +
		'">' +
		_escHtml(typeLabel) +
		'</span></td>' +
		'<td class="center">' +
		(m.url ? '<a class="src-link" data-url="' + _escHtml(m.url) + '" title="HuggingFace ↗">↗</a>' : '') +
		'</td>';

	tr.onclick = function (ev) {
		// The source link opens the model page instead of selecting the row.
		var a = ev.target.closest ? ev.target.closest('a.src-link') : null;
		if (a) {
			ev.stopPropagation();
			postBridgeMessage({ action: 'open_url', url: a.getAttribute('data-url') });
			return;
		}
		selectRow(m.name);
	};
	tr.ondblclick = function () {
		selectRow(m.name);
		useSelected();
	};
	return tr;
}

function selectRow(name) {
	_selected = name;
	document.querySelectorAll('#rows tr').forEach(function (tr) {
		var cell = tr.querySelector('.name-cell');
		tr.classList.toggle('selected', cell && cell.textContent === name);
	});
	updateUseButton();
}

function updateUseButton() {
	var btn = document.getElementById('btn-use');
	if (btn) btn.disabled = !_selected;
}

function updateCount(shown, total) {
	var el = document.getElementById('count');
	if (!el) return;
	var tmpl = _t('model_browser.count_label') || '{n} / {total}';
	el.textContent = tmpl.replace('{n}', shown).replace('{total}', total);
}

function updateSortIndicators() {
	document.querySelectorAll('thead th').forEach(function (th) {
		th.classList.remove('sorted-asc', 'sorted-desc');
		if (th.getAttribute('data-sort') === _sortKey) {
			th.classList.add(_sortDir === 1 ? 'sorted-asc' : 'sorted-desc');
		}
	});
}

// =====================================
// =====================================
// ======= 5/ Actions ==================
// =====================================
// =====================================

/** Sends the highlighted model back to the native backend to activate it. */
function useSelected() {
	if (!_selected) return;
	postBridgeMessage({ action: 'select_model', name: _selected });
}

function setSort(key) {
	if (!key) return;
	if (_sortKey === key) {
		_sortDir = -_sortDir;
	} else {
		_sortKey = key;
		_sortDir = 1;
	}
	render();
}

// =====================================
// =====================================
// ======= 6/ Initialisation ===========
// =====================================
// =====================================

(function init() {
	var search = document.getElementById('search');
	if (search) search.addEventListener('input', render);

	document.querySelectorAll('thead th[data-sort]').forEach(function (th) {
		th.addEventListener('click', function () {
			setSort(th.getAttribute('data-sort'));
		});
	});

	var useBtn = document.getElementById('btn-use');
	if (useBtn) useBtn.addEventListener('click', useSelected);

	// Enter activates the highlighted row; Escape is handled by the native window.
	document.addEventListener('keydown', function (ev) {
		if (ev.key === 'Enter' && _selected) {
			ev.preventDefault();
			useSelected();
		}
	});

	applyLabels();
	if (window._i18n_strings) render();
})();
