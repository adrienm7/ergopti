// _shared/ui/model_browser/script.js

/**
 * ==============================================================================
 * MODULE: Model Selector Page Script
 * DESCRIPTION:
 * The place where the user picks the active AI model: one table, grouped by
 * backend (Ollama and MLX on this machine, then the remote API), with the
 * size on disk, the RAM required, whether the model is installed and which one
 * is current. Shared verbatim by the macOS (hs.webview), Windows (WebView2)
 * and Linux (WebKitGTK) drivers: each injects one payload via injectModels()
 * and receives the user's actions through postBridgeMessage().
 *
 * FEATURES & RATIONALE:
 * 1. One projection: the rows come from the shared model catalogue and the
 *    driver's install scan (_shared/lua/llm/model_catalogue.lua on macOS and
 *    Linux, its pinned AHK twin on Windows); the page never reads files.
 * 2. Only what works now is selectable: a backend the driver reports
 *    unavailable greys its rows with the reason, and a model that is not
 *    installed offers its download, never its activation.
 * 3. The page decides nothing: every action crosses the bridge to the code
 *    path the tray used (validation, persistence, warmup).
 * 4. Keyboard first: rows are focusable, arrows move, Enter uses the focused
 *    model, Delete removes an installed one, and every action is a button.
 * ==============================================================================
 */

var _models = []; // Rows of the current payload.
var _backends = []; // [{ id, brand, emoji, kind, available, reason_key }] in display order.
var _backend = ''; // Active backend id.
var _active = ''; // Active model name (display name) on the active backend.
var _selected = null; // Key of the highlighted row.
var _sortKey = 'name';
var _sortDir = 1;
var _filter = ''; // Backend id the table is narrowed to; '' shows every backend.
var _capabilities = {}; // { disable: bool }.

// Which column reads which row field. The numeric fields are the catalogue's
// own (models.json hardware_requirements.<backend>.download_gb / ram_gb and
// parameters.total), projected by the shared catalogue module.
var COLUMNS = [
	{ id: 'current', header: 'model_browser.col_current', sort: 'current', cls: 'col-current' },
	{ id: 'name', header: 'model_browser.col_name', sort: 'name', cls: 'col-name' },
	{
		id: 'disk',
		header: 'model_browser.col_disk',
		sort: 'disk_gb',
		cls: 'col-num',
		field: 'disk_gb'
	},
	{ id: 'ram', header: 'model_browser.col_ram', sort: 'ram_gb', cls: 'col-num', field: 'ram_gb' },
	{
		id: 'params',
		header: 'model_browser.col_params',
		sort: 'params_b',
		cls: 'col-num',
		field: 'params_b'
	},
	{ id: 'status', header: 'model_browser.col_status', sort: 'installed', cls: 'col-status' },
	{ id: 'actions', header: 'model_browser.col_actions', sort: null, cls: 'col-actions' }
];
var NUMERIC_SORT = { disk_gb: true, ram_gb: true, params_b: true };

// =========================================
// =========================================
// ======= 1/ Native Bridge Interface ======
// =========================================
// =========================================

var postBridgeMessage = makeHostBridge('model_browser_bridge');
var _session = null;
var _catalogueOwner = {};

/** Posts an action with the optional native operation identity. */
function postModelAction(action) {
	if (_session !== null) action.session = _session;
	postBridgeMessage(action);
}

/**
 * Called by the native backend to populate the table.
 * @param {object} payload - { backend, active, models, backends?, capabilities?, session? }.
 */
function injectModels(payload) {
	if (!payload || !Array.isArray(payload.models)) return;
	var session = null;
	if (Object.prototype.hasOwnProperty.call(payload, 'session')) {
		if (!Number.isSafeInteger(payload.session) || payload.session <= 0) {
			throw new TypeError('Model browser session must be a positive safe integer');
		}
		session = payload.session;
	}
	_session = session;
	_catalogueOwner = {};
	_models = payload.models;
	_backend = payload.backend || '';
	_active = payload.active || '';
	_backends = Array.isArray(payload.backends) ? payload.backends : [];
	_capabilities =
		payload.capabilities && typeof payload.capabilities === 'object' ? payload.capabilities : {};
	if (_filter && !backendById(_filter)) _filter = '';
	_selected = null;
	buildFilter();
	updateFooter();
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

/** The translated string, or the empty string while the locale is loading. */
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || '';
}

/** Substitutes {name} placeholders of a translated template. */
function _fmt(key, values) {
	return _t(key).replace(/\{(\w+)\}/g, function (all, name) {
		return Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : all;
	});
}

var _orig_i18n_apply = window.i18n_apply;
window.i18n_apply = function (strings) {
	if (typeof _orig_i18n_apply === 'function') _orig_i18n_apply(strings);
	buildFilter();
	render();
};

// =====================================
// =====================================
// ======= 3/ Row Model ================
// =====================================
// =====================================

function backendById(id) {
	for (var i = 0; i < _backends.length; i++) if (_backends[i].id === id) return _backends[i];
	return null;
}

/** A row's identity: its backend and its name, since one model exists per backend. */
function rowKey(m) {
	return (m.backend || '') + '\u0000' + (m.name || '');
}

/** Whether the row's backend can run a model right now. Legacy rows carry no backend. */
function backendReady(m) {
	if (!m.backend) return true;
	var b = backendById(m.backend);
	return !b || b.available !== false;
}

function isRemote(m) {
	var b = m.backend ? backendById(m.backend) : null;
	return !!b && b.kind === 'remote';
}

function isCurrent(m) {
	return m.name === _active && (!m.backend || !_backend || m.backend === _backend);
}

/** Whether the row itself can act now: a working backend, no refusal of its own, no download running. */
function rowReady(m) {
	return backendReady(m) && m.available !== false && m.pending !== 'download';
}

/** Only an installed model of a working backend (or a configured API entry) can be made active. */
function isSelectable(m) {
	return rowReady(m) && (m.installed === true || isRemote(m));
}

/** A missing model of a working local backend offers its download instead. */
function isDownloadable(m) {
	return rowReady(m) && !isRemote(m) && m.installed !== true && m.downloadable !== false;
}

function isDeletable(m) {
	return rowReady(m) && !isRemote(m) && m.installed === true && m.deletable !== false;
}

function findRow(key) {
	for (var i = 0; i < _models.length; i++) {
		if (rowKey(_models[i]) === key) return _models[i];
	}
	// Legacy callers name the row only; they mean the active backend's model.
	for (var j = 0; j < _models.length; j++) {
		if (_models[j].name === key) return _models[j];
	}
	return null;
}

/**
 * Whether an identifier typed to add a model is well formed for its backend:
 * an Ollama name ("qwen3:4b", "hf.co/owner/repo:Q4_K_M") or an MLX Hugging Face
 * repository id ("mlx-community/Qwen3-4B-4bit"). The native side checks again
 * with _shared/lua/llm/model_identifier.lua or its AHK twin; all three pass
 * _shared/tests/corpus/llm/model_identifiers.json.
 */
function validModelIdentifier(backend, id) {
	if (typeof id !== 'string' || id === '' || id.length > 200) return false;
	var lower = /^[a-z0-9][a-z0-9._-]*$/;
	var any = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
	if (backend === 'ollama') {
		var fields = id.split(':');
		if (fields.length > 2) return false;
		if (fields.length === 2 && !any.test(fields[1])) return false;
		var segments = fields[0].split('/');
		if (segments.length > 3) return false;
		for (var i = 0; i < segments.length; i++) {
			if (!(i === 0 ? lower : any).test(segments[i])) return false;
		}
		return true;
	}
	if (backend === 'mlx') {
		var parts = id.split('/');
		return parts.length === 2 && any.test(parts[0]) && any.test(parts[1]);
	}
	return false;
}

// =====================================
// =====================================
// ======= 4/ Formatting Helpers =======
// =====================================
// =====================================

function _num(v) {
	var n = parseFloat(v);
	return isNaN(n) ? 0 : n;
}

/** Drops a trailing ".0" / ".00" so "8.00" → "8" but "4.22" stays. */
function _trim(n) {
	return parseFloat(n.toFixed(2)).toString();
}

function fmtGb(value) {
	var n = _num(value);
	return n > 0 ? _fmt('model_browser.unit_gb', { n: _trim(n) }) : '—';
}

/** Formats a billions-of-parameters value, collapsing MoE active/total. */
function fmtParams(row) {
	var total = _num(row.params_b);
	var active = _num(row.active_b);
	if (row.is_moe && active > 0 && active < total) {
		return _fmt('model_browser.unit_params_moe', { active: _trim(active), total: _trim(total) });
	}
	return total > 0 ? _fmt('model_browser.unit_params', { n: _trim(total) }) : '—';
}

function _escHtml(s) {
	return String(s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function backendHeading(b) {
	var kind = _t(b.kind === 'remote' ? 'model_browser.kind_remote' : 'model_browser.kind_local');
	return (b.emoji ? b.emoji + ' ' : '') + (b.brand || b.id) + (kind ? ' — ' + kind : '');
}

// =====================================
// =====================================
// ======= 5/ Rendering ================
// =====================================
// =====================================

function buildHead() {
	var head = document.getElementById('head-row');
	if (!head) return;
	head.innerHTML = COLUMNS.map(function (c) {
		var sorted =
			c.sort && c.sort === _sortKey ? (_sortDir === 1 ? 'ascending' : 'descending') : 'none';
		return (
			'<th scope="col" class="' +
			c.cls +
			'"' +
			(c.sort ? ' data-sort="' + c.sort + '" tabindex="0" aria-sort="' + sorted + '"' : '') +
			'>' +
			_escHtml(_t(c.header)) +
			'</th>'
		);
	}).join('');
	if (typeof head.querySelectorAll !== 'function') return;
	head.querySelectorAll('th[data-sort]').forEach(function (th) {
		th.onclick = function () {
			setSort(th.getAttribute('data-sort'));
		};
		th.onkeydown = function (ev) {
			if (ev.key === 'Enter' || ev.key === ' ') {
				ev.preventDefault();
				setSort(th.getAttribute('data-sort'));
			}
		};
	});
}

function buildFilter() {
	var select = document.getElementById('backend-filter');
	if (!select) return;
	var html = '<option value="">' + _escHtml(_t('model_browser.filter_all')) + '</option>';
	_backends.forEach(function (b) {
		html +=
			'<option value="' +
			_escHtml(b.id) +
			'"' +
			(b.id === _filter ? ' selected' : '') +
			'>' +
			_escHtml((b.emoji ? b.emoji + ' ' : '') + (b.brand || b.id)) +
			'</option>';
	});
	select.innerHTML = html;
	select.value = _filter;
	if ('hidden' in select) select.hidden = _backends.length < 2;
	var label = document.getElementById('backend-filter-label');
	if (label && 'hidden' in label) label.hidden = _backends.length < 2;
}

function matches(m, query) {
	if (_filter && m.backend && m.backend !== _filter) return false;
	if (!query) return true;
	return (
		(m.name || '').toLowerCase().indexOf(query) !== -1 ||
		(m.family || '').toLowerCase().indexOf(query) !== -1 ||
		(m.provider || '').toLowerCase().indexOf(query) !== -1
	);
}

function compareRows(a, b) {
	var va, vb;
	if (_sortKey === 'current') {
		va = isCurrent(a) ? 1 : 0;
		vb = isCurrent(b) ? 1 : 0;
		return (vb - va) * _sortDir;
	}
	if (_sortKey === 'installed') return ((b.installed ? 1 : 0) - (a.installed ? 1 : 0)) * _sortDir;
	if (NUMERIC_SORT[_sortKey]) return (_num(a[_sortKey]) - _num(b[_sortKey])) * _sortDir;
	va = String(a[_sortKey] == null ? '' : a[_sortKey]).toLowerCase();
	vb = String(b[_sortKey] == null ? '' : b[_sortKey]).toLowerCase();
	if (va < vb) return -1 * _sortDir;
	if (va > vb) return 1 * _sortDir;
	return 0;
}

/** The groups the table draws: one per backend in payload order, then legacy rows. */
function groupRows(rows, query) {
	var groups = [];
	var byId = {};
	_backends.forEach(function (b) {
		byId[b.id] = { backend: b, rows: [] };
		groups.push(byId[b.id]);
	});
	var loose = { backend: null, rows: [] };
	rows.forEach(function (m) {
		var g = m.backend && byId[m.backend];
		(g || loose).rows.push(m);
	});
	if (loose.rows.length) groups.push(loose);
	return groups.filter(function (g) {
		if (g.rows.length > 0) return true;
		// An empty backend still shows its tools (add a model, add a provider)
		// unless a search or another backend's filter narrows the table.
		return !!g.backend && !query && (!_filter || _filter === g.backend.id) && hasTools(g.backend);
	});
}

function hasTools(b) {
	return (
		(Array.isArray(b.actions) && b.actions.length > 0) ||
		!!b.add_model ||
		(Array.isArray(b.providers) && b.providers.length > 0)
	);
}

/** Applies the filters and the active sort, then rebuilds every group. */
function render() {
	var table = document.getElementById('models');
	var empty = document.getElementById('empty');
	if (!table) return;
	buildHead();
	var search = document.getElementById('search');
	var query = ((search && search.value) || '').trim().toLowerCase();
	var rows = _models.filter(function (m) {
		return matches(m, query);
	});
	rows.sort(compareRows);

	if (typeof table.querySelectorAll === 'function') {
		table.querySelectorAll('tbody').forEach(function (tb) {
			table.removeChild(tb);
		});
	}
	groupRows(rows, query).forEach(function (g) {
		var tbody = document.createElement('tbody');
		if (g.backend) tbody.appendChild(buildGroupHead(g.backend));
		g.rows.forEach(function (m) {
			tbody.appendChild(buildRow(m));
		});
		table.appendChild(tbody);
	});

	if (empty) empty.style.display = rows.length === 0 ? 'block' : 'none';
	updateCount(rows.length, _models.length);
	updateCurrent();
}

/**
 * One backend's header: its emoji and name, why it cannot run now, and its
 * tools — the driver's own actions (install, port, token…), the field that
 * adds a model by identifier, and the provider list that adds an API.
 */
function buildGroupHead(b) {
	var catalogueOwner = _catalogueOwner;
	var head = document.createElement('tr');
	head.className = 'group' + (b.available === false ? ' unavailable' : '');
	var th = document.createElement('th');
	th.setAttribute('scope', 'rowgroup');
	th.setAttribute('colspan', String(COLUMNS.length));
	var reason = b.available === false && b.reason_key ? _t(b.reason_key) : '';
	th.innerHTML =
		'<span class="group-title">' +
		_escHtml(backendHeading(b)) +
		'</span>' +
		(reason ? ' <span class="reason">' + _escHtml(reason) + '</span>' : '');
	var tools = document.createElement('div');
	tools.className = 'group-tools';

	(Array.isArray(b.actions) ? b.actions : []).forEach(function (a) {
		var btn = document.createElement('button');
		btn.type = 'button';
		btn.className = 'act';
		btn.textContent = a.text || '';
		btn.disabled = a.disabled === true;
		btn.onclick = function () {
			if (_catalogueOwner !== catalogueOwner || a.disabled === true) return;
			postModelAction({ action: 'group_action', backend: b.id, id: a.id });
		};
		tools.appendChild(btn);
	});

	if (b.add_model && b.available !== false) {
		var input = document.createElement('input');
		input.type = 'text';
		input.className = 'add-input';
		input.setAttribute('spellcheck', 'false');
		input.setAttribute('autocomplete', 'off');
		var hint = _t('model_browser.add_model_placeholder_' + b.id);
		input.setAttribute('placeholder', hint);
		input.setAttribute('aria-label', hint);
		var addBtn = document.createElement('button');
		addBtn.type = 'button';
		addBtn.className = 'act';
		addBtn.textContent = _t('model_browser.add_model_button');
		var error = document.createElement('span');
		error.className = 'add-error';
		error.setAttribute('role', 'alert');
		var submit = function () {
			if (_catalogueOwner !== catalogueOwner) return;
			var name = String(input.value || '').trim();
			if (!validModelIdentifier(b.id, name)) {
				error.textContent = _t('model_browser.invalid_identifier_' + b.id);
				input.setAttribute('aria-invalid', 'true');
				return;
			}
			error.textContent = '';
			input.setAttribute('aria-invalid', 'false');
			postModelAction({ action: 'add_model', backend: b.id, name: name });
		};
		addBtn.onclick = submit;
		input.onkeydown = function (ev) {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				submit();
			}
		};
		tools.appendChild(input);
		tools.appendChild(addBtn);
		tools.appendChild(error);
	}

	if (Array.isArray(b.providers) && b.providers.length > 0) {
		var select = document.createElement('select');
		select.className = 'provider-select';
		select.setAttribute('aria-label', _t('model_browser.add_provider_label'));
		select.innerHTML = b.providers
			.map(function (p) {
				return '<option value="' + _escHtml(p.id) + '">' + _escHtml(p.label || p.id) + '</option>';
			})
			.join('');
		select.value = b.providers[0].id;
		var providerBtn = document.createElement('button');
		providerBtn.type = 'button';
		providerBtn.className = 'act';
		providerBtn.textContent = _t('model_browser.add_provider_button');
		providerBtn.onclick = function () {
			if (_catalogueOwner !== catalogueOwner) return;
			var id = select.value || b.providers[0].id;
			postModelAction({ action: 'add_provider', backend: b.id, provider: id });
		};
		tools.appendChild(select);
		tools.appendChild(providerBtn);
	}

	th.appendChild(tools);
	head.appendChild(th);
	return head;
}

/** The cells of one row, in COLUMNS order. */
function rowCells(m) {
	var current = isCurrent(m);
	var cells = {
		current:
			'<span class="mark' +
			(current ? ' on' : '') +
			'" aria-label="' +
			_escHtml(current ? _t('model_browser.status_current') : '') +
			'">' +
			(current ? '✓' : '') +
			'</span>',
		name:
			'<span class="name-cell">' +
			_escHtml(m.name || '') +
			'</span>' +
			(m.family || m.provider
				? '<span class="sub">' + _escHtml(m.family || m.provider) + '</span>'
				: '') +
			(m.custom
				? ' <span class="chip">' + _escHtml(_t('model_browser.chip_custom')) + '</span>'
				: '') +
			(m.is_default
				? ' <span class="chip default">' + _escHtml(_t('model_browser.chip_default')) + '</span>'
				: '') +
			(m.type === 'completion'
				? ' <span class="chip completion">' +
					_escHtml(_t('model_browser.type_completion')) +
					'</span>'
				: '') +
			(m.hint_key ? '<span class="sub hint">' + _escHtml(_t(m.hint_key)) + '</span>' : ''),
		disk: _escHtml(fmtGb(m.disk_gb)),
		ram: _escHtml(fmtGb(m.ram_gb)),
		params: _escHtml(fmtParams(m)),
		status:
			m.pending === 'download'
				? '<span class="status pending">' +
					_escHtml(_t('model_browser.status_downloading')) +
					'</span>'
				: isRemote(m)
					? '<span class="status remote">' + _escHtml(_t('model_browser.status_remote')) + '</span>'
					: '<span class="dot' +
						(m.installed ? ' on' : '') +
						'" aria-hidden="true"></span> ' +
						_escHtml(
							_t(m.installed ? 'model_browser.status_installed' : 'model_browser.status_available')
						),
		actions: rowActions(m, current)
	};
	return COLUMNS.map(function (c) {
		var cls =
			c.cls === 'col-num'
				? 'num'
				: c.id === 'current' || c.id === 'status'
					? 'center'
					: c.id === 'actions'
						? 'col-actions'
						: '';
		return '<td class="' + cls + '">' + cells[c.id] + '</td>';
	}).join('');
}

function rowActions(m, current) {
	var html = '';
	if (isSelectable(m) && !current) {
		html +=
			'<button type="button" class="act" data-act="use">' +
			_escHtml(_t('model_browser.use_button')) +
			'</button>';
	}
	if (isDownloadable(m)) {
		html +=
			'<button type="button" class="act" data-act="download">' +
			_escHtml(_t('model_browser.download_button')) +
			'</button>';
	}
	if (m.custom && !isRemote(m)) {
		html +=
			'<button type="button" class="act danger" data-act="remove">' +
			_escHtml(_t('model_browser.remove_button')) +
			'</button>';
	} else if (isDeletable(m)) {
		html +=
			'<button type="button" class="act danger" data-act="delete">' +
			_escHtml(_t('model_browser.delete_button')) +
			'</button>';
	}
	(Array.isArray(m.actions) ? m.actions : []).forEach(function (a, index) {
		if (!backendReady(m) || m.pending === 'download') return;
		html +=
			'<button type="button" class="act" data-act="row" data-index="' +
			index +
			'">' +
			_escHtml(a.text || '') +
			'</button>';
	});
	if (m.url) {
		html +=
			'<button type="button" class="act link" data-act="source" data-url="' +
			_escHtml(m.url) +
			'" title="' +
			_escHtml(_t('model_browser.source_button')) +
			'" aria-label="' +
			_escHtml(_t('model_browser.source_button')) +
			'">↗</button>';
	}
	return html;
}

/** Builds a single <tr> for a model row. */
function buildRow(m) {
	var catalogueOwner = _catalogueOwner;
	var key = rowKey(m);
	var tr = document.createElement('tr');
	var classes = [];
	if (isCurrent(m)) classes.push('active');
	if (!backendReady(m) || m.available === false) classes.push('unavailable');
	else if (!isSelectable(m)) classes.push('missing');
	if (key === _selected) classes.push('selected');
	tr.className = classes.join(' ');
	tr.tabIndex = 0;
	if (typeof tr.setAttribute === 'function') {
		tr.setAttribute('data-key', key);
		tr.setAttribute('aria-disabled', isSelectable(m) ? 'false' : 'true');
		tr.setAttribute('aria-selected', key === _selected ? 'true' : 'false');
	}
	tr.innerHTML = rowCells(m);

	tr.onclick = function (ev) {
		if (_catalogueOwner !== catalogueOwner) return;
		var button =
			ev && ev.target && ev.target.closest ? ev.target.closest('button[data-act]') : null;
		if (button) {
			if (ev.stopPropagation) ev.stopPropagation();
			runAction(
				m,
				button.getAttribute('data-act'),
				button.getAttribute('data-url'),
				button.getAttribute('data-index')
			);
			return;
		}
		selectRow(key);
	};
	tr.ondblclick = function () {
		if (_catalogueOwner !== catalogueOwner) return;
		selectRow(key);
		useSelected();
	};
	tr.onkeydown = function (ev) {
		if (_catalogueOwner !== catalogueOwner) return;
		if (ev.target !== tr) return;
		if (ev.key === 'Enter') {
			ev.preventDefault();
			selectRow(key);
			useSelected();
		} else if (ev.key === ' ') {
			ev.preventDefault();
			selectRow(key);
		} else if (ev.key === 'Delete' || ev.key === 'Backspace') {
			ev.preventDefault();
			if (m.custom) runAction(m, 'remove');
			else if (isDeletable(m)) runAction(m, 'delete');
		} else if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
			ev.preventDefault();
			moveFocus(tr, ev.key === 'ArrowDown' ? 1 : -1);
		}
	};
	tr.onfocus = function () {
		if (_catalogueOwner === catalogueOwner) selectRow(key);
	};
	return tr;
}

/** Moves keyboard focus to the next or previous model row, across groups. */
function moveFocus(fromRow, step) {
	var rows = Array.prototype.slice.call(document.querySelectorAll('tr[data-key]'));
	var index = rows.indexOf(fromRow);
	var next = rows[index + step];
	if (next && typeof next.focus === 'function') next.focus();
}

function selectRow(key) {
	var row = findRow(key);
	_selected = row ? rowKey(row) : null;
	document.querySelectorAll('tr[data-key]').forEach(function (tr) {
		var on = tr.getAttribute('data-key') === _selected;
		tr.classList.toggle('selected', on);
		tr.setAttribute('aria-selected', on ? 'true' : 'false');
	});
	updateFooter();
}

function updateFooter() {
	var row = _selected ? findRow(_selected) : null;
	var useBtn = document.getElementById('btn-use');
	if (useBtn) useBtn.disabled = !row || !isSelectable(row) || isCurrent(row);
	var disableBtn = document.getElementById('btn-disable');
	if (disableBtn && 'hidden' in disableBtn) disableBtn.hidden = _capabilities.disable !== true;
}

function updateCount(shown, total) {
	var el = document.getElementById('count');
	if (el) el.textContent = _fmt('model_browser.count_label', { n: shown, total: total });
}

/** States the active choice above the table, emoji first, as the tray button does. */
function updateCurrent() {
	var el = document.getElementById('current');
	if (!el) return;
	var b = backendById(_backend);
	var name = _active || _t('model_browser.current_none');
	el.textContent = _fmt('model_browser.current_label', {
		model: (b && b.emoji ? b.emoji + ' ' : '') + name
	});
}

// =====================================
// =====================================
// ======= 6/ Actions ==================
// =====================================
// =====================================

/** Posts one row action; the native side validates it against its own catalogue. */
function postRowAction(action, m) {
	var message = { action: action, name: m.name };
	if (m.backend) message.backend = m.backend;
	postModelAction(message);
}

function runAction(m, act, url, index) {
	if (act === 'row') {
		var a = Array.isArray(m.actions) ? m.actions[Number(index)] : null;
		if (!a || !backendReady(m) || m.pending === 'download') return;
		var message = { action: 'row_action', id: a.id, name: m.name };
		if (m.backend) message.backend = m.backend;
		postModelAction(message);
		return;
	}
	if (act === 'use') {
		if (isSelectable(m)) postRowAction('select_model', m);
	} else if (act === 'download') {
		if (isDownloadable(m)) postRowAction('download_model', m);
	} else if (act === 'delete') {
		if (isDeletable(m)) postRowAction('delete_model', m);
	} else if (act === 'remove') {
		if (m.custom) postRowAction('remove_custom_model', m);
	} else if (act === 'source') {
		postModelAction({ action: 'open_url', url: url || m.url });
	}
}

/** Sends the highlighted model back to the native backend to activate it. */
function useSelected() {
	var row = _selected ? findRow(_selected) : null;
	if (!row || !isSelectable(row)) return;
	postRowAction('select_model', row);
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
// ======= 7/ Initialisation ===========
// =====================================
// =====================================

(function init() {
	var search = document.getElementById('search');
	if (search) search.addEventListener('input', render);

	var filter = document.getElementById('backend-filter');
	if (filter)
		filter.addEventListener('change', function () {
			_filter = filter.value || '';
			render();
		});

	var useBtn = document.getElementById('btn-use');
	if (useBtn) useBtn.addEventListener('click', useSelected);
	var disableBtn = document.getElementById('btn-disable');
	if (disableBtn)
		disableBtn.addEventListener('click', function () {
			if (_capabilities.disable === true) postModelAction({ action: 'disable_model' });
		});

	updateFooter();
	if (window._i18n_strings) render();
})();
