// _shared/ui/layout_manager/script.js

// ===========================================================================
// MODULE: Layout Manager Page
// DESCRIPTION:
// Lists the layouts of the keyboard-layout registry with their author,
// licence and version, whether each one is installed, can be updated or is
// available, and offers the matching install / update / uninstall / use
// buttons. The three drivers host this page and send it the same state:
//   { platform, index, source, error, installed, provided, builtin, active,
//     busy, result }
// The page decides the rows from that state (one source for every driver)
// and only ever posts the allowlisted actions below; each host checks them
// again before acting.
// ===========================================================================

// ========================================
// ========================================
// ======= 1/ State =======================
// ========================================
// ========================================

// The only actions a host accepts from this page.
const LAYOUT_MANAGER_ACTIONS = Object.freeze([
	'ready',
	'refresh',
	'install',
	'update',
	'uninstall',
	'select',
	'open_homepage',
	'close'
]);

// Failure codes the hosts report, each with its own explanation. Any other
// code falls back to the generic one, with the host's detail as a tooltip.
const FAILURE_KEYS = Object.freeze({
	busy: 'layout_manager.failure_busy',
	provided_by_bundle: 'layout_manager.failure_provided_by_bundle',
	foreign_file: 'layout_manager.failure_foreign_file',
	download_failed: 'layout_manager.failure_download',
	python_missing: 'layouts.linux_needs_python'
});

// Catalogue error codes (_shared/lua/layouts/catalogue.lua and its AHK twin).
const CATALOGUE_ERROR_KEYS = Object.freeze({
	offline: 'layout_manager.error_offline',
	http: 'layout_manager.error_http'
});

// Locale strings, pushed by the host with initData.
let _strings = {};
// Last state pushed by the host.
let _state = null;

const _post = makeHostBridge('layout_manager_bridge');

/**
 * Returns the translated string for key, or key itself when it is missing.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return Object.prototype.hasOwnProperty.call(_strings, key) ? _strings[key] : key;
}

/**
 * Formats a translated string, replacing each %s in order.
 * @param {string} key
 * @param {...*} args
 * @returns {string}
 */
function _fmt(key, ...args) {
	let position = 0;
	return _t(key).replace(/%s/g, () => (position < args.length ? String(args[position++]) : ''));
}

/**
 * Applies translations to every element carrying data-i18n.
 */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		const key = el.getAttribute('data-i18n');
		if (!Object.prototype.hasOwnProperty.call(_strings, key)) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
}

// ========================================
// ========================================
// ======= 2/ Catalogue rows ==============
// ========================================
// ========================================

/**
 * One row of the list.
 * @param {Object|null} entry - Registry index entry (null once the registry dropped it).
 * @param {Object|undefined} installed - Installed record entry.
 * @param {boolean} provided - Another package already provides the layout.
 * @param {boolean} builtin - The driver ships the layout built in.
 * @param {string} active - Registry id of the active layout.
 * @param {string} platform - Host platform, selecting its shortcut menu format.
 * @returns {Object}
 */
function makeRow(entry, installed, provided, builtin, active, platform) {
	const source = entry || installed;
	const files =
		source.extension && Array.isArray(source.extension.files) ? source.extension.files : [];
	const hotstrings = files.filter(
		(file) => typeof file.path === 'string' && /^hotstrings\/.+\.toml$/.test(file.path)
	).length;
	const shortcutPath = platform === 'windows' ? 'shortcuts/menu.ahk' : 'shortcuts/menu.lua';
	const shortcuts = files.some((file) => file.path === shortcutPath) ? 1 : 0;
	let status;
	if (builtin) status = 'builtin';
	else if (provided) status = 'provided';
	else if (!installed) status = 'available';
	else if (
		entry &&
		(installed.sha256 !== entry.sha256 ||
			(entry.extension &&
				entry.extension.sha256 !== (installed.extension && installed.extension.sha256)))
	)
		status = 'update';
	else status = 'installed';
	const isActive = active === source.id;
	const actions = [];
	if (status === 'available') actions.push('install');
	if (status === 'update') actions.push('update');
	if ((status === 'installed' || status === 'update' || status === 'builtin') && !isActive)
		actions.push('select');
	if (status === 'installed' || status === 'update') actions.push('uninstall');
	return {
		id: source.id,
		name: typeof source.name === 'string' && source.name !== '' ? source.name : source.id,
		author: typeof source.author === 'string' ? source.author : '',
		licence: typeof source.licence === 'string' ? source.licence : '',
		homepage:
			typeof source.homepage === 'string' && /^https:\/\//.test(source.homepage)
				? source.homepage
				: '',
		version: entry && typeof entry.version === 'string' ? entry.version : '',
		installedVersion: installed && typeof installed.version === 'string' ? installed.version : '',
		status,
		active: isActive,
		removed: !entry,
		hotstrings,
		shortcuts,
		actions
	};
}

/**
 * Decides every row from the host state: the index entries published for
 * this platform, then the installed layouts the registry no longer lists.
 * @param {Object|null} state
 * @returns {Object[]}
 */
function layoutRows(state) {
	if (!state || typeof state !== 'object') return [];
	const entries = state.index && Array.isArray(state.index.layouts) ? state.index.layouts : [];
	const installed = state.installed && typeof state.installed === 'object' ? state.installed : {};
	const provided = state.provided && typeof state.provided === 'object' ? state.provided : {};
	const builtin = state.builtin && typeof state.builtin === 'object' ? state.builtin : {};
	const active = typeof state.active === 'string' ? state.active : '';
	const rows = [];
	const listed = new Set();
	for (const entry of entries) {
		if (!entry || typeof entry.id !== 'string') continue;
		const platforms = Array.isArray(entry.platforms) ? entry.platforms : [];
		if (typeof state.platform === 'string' && !platforms.includes(state.platform)) continue;
		listed.add(entry.id);
		rows.push(
			makeRow(
				entry,
				installed[entry.id],
				Boolean(provided[entry.id]),
				builtin[entry.id] === true,
				active,
				state.platform
			)
		);
	}
	for (const id of Object.keys(installed).sort()) {
		if (!listed.has(id) && installed[id] && typeof installed[id].id === 'string') {
			rows.push(makeRow(null, installed[id], false, false, active, state.platform));
		}
	}
	return rows;
}

/**
 * The catalogue line: where the list comes from and why the network one is
 * missing, if it is.
 * @param {Object|null} state
 * @returns {{text: string, isError: boolean}}
 */
function catalogueStatus(state) {
	const source = state && typeof state.source === 'string' ? state.source : 'none';
	let text = _t('layout_manager.source_' + source);
	const error = state && state.error && typeof state.error === 'object' ? state.error : null;
	if (error) {
		const key = CATALOGUE_ERROR_KEYS[error.code];
		const detail = typeof error.detail === 'string' ? error.detail : '';
		text += ' ' + (key ? _fmt(key, detail) : _fmt('layout_manager.error_generic', error.code));
	}
	if (state && typeof state.record_error === 'string' && state.record_error !== '') {
		text += ' ' + _t('layout_manager.error_record');
	}
	return { text, isError: Boolean(error) || Boolean(state && state.record_error) };
}

/**
 * The line reporting the last operation.
 * @param {Object|null} result - { id, action, ok, code, detail, warning }.
 * @param {Object[]} rows
 * @returns {{text: string, isError: boolean, detail: string}|null}
 */
function resultMessage(result, rows) {
	if (!result || typeof result !== 'object' || typeof result.id !== 'string') return null;
	const row = rows.find((candidate) => candidate.id === result.id);
	const name = row ? row.name : result.id;
	const detail = typeof result.detail === 'string' ? result.detail : '';
	if (!result.ok) {
		const key = FAILURE_KEYS[result.code] || 'layout_manager.failure_other';
		return { text: _fmt('layout_manager.result_failed', name, _t(key)), isError: true, detail };
	}
	if (result.warning === 'not_enabled') {
		return {
			text: _fmt('layout_manager.result_installed_not_enabled', name),
			isError: false,
			detail
		};
	}
	const keys = {
		install: 'layout_manager.result_installed',
		update: 'layout_manager.result_installed',
		uninstall: 'layout_manager.result_uninstalled',
		select: 'layout_manager.result_selected'
	};
	return {
		text: _fmt(keys[result.action] || 'layout_manager.result_installed', name),
		isError: false,
		detail
	};
}

// ========================================
// ========================================
// ======= 3/ Rendering ===================
// ========================================
// ========================================

/**
 * Creates an element with an optional class and text.
 * @param {string} tag
 * @param {string} className
 * @param {string} text
 * @returns {HTMLElement}
 */
function element(tag, className, text) {
	const el = document.createElement(tag);
	if (className) el.className = className;
	if (text !== undefined) el.textContent = text;
	return el;
}

/**
 * Builds the list item of one row.
 * @param {Object} row
 * @param {Object|null} busy - { id, action } of the operation in flight.
 * @returns {HTMLElement}
 */
function renderRow(row, busy) {
	const item = element('li', 'layout layout-' + row.status);
	item.dataset.id = row.id;

	const header = element('div', 'layout-header');
	header.appendChild(element('span', 'layout-name', row.name));
	const badges = element('span', 'layout-badges');
	badges.appendChild(
		element('span', 'badge badge-' + row.status, _t('layout_manager.status_' + row.status))
	);
	if (row.active)
		badges.appendChild(element('span', 'badge badge-active', _t('layout_manager.status_active')));
	header.appendChild(badges);
	item.appendChild(header);

	const meta = element('div', 'layout-meta');
	if (row.author)
		meta.appendChild(element('span', '', _fmt('layout_manager.meta_author', row.author)));
	if (row.licence)
		meta.appendChild(element('span', '', _fmt('layout_manager.meta_licence', row.licence)));
	if (row.version)
		meta.appendChild(element('span', '', _fmt('layout_manager.meta_version', row.version)));
	if (row.installedVersion && row.installedVersion !== row.version) {
		meta.appendChild(
			element('span', '', _fmt('layout_manager.meta_installed_version', row.installedVersion))
		);
	}
	item.appendChild(meta);
	if (row.hotstrings || row.shortcuts) {
		const content = element('div', 'layout-content');
		content.appendChild(
			element('div', '', _fmt('layout_manager.extension_content', row.hotstrings, row.shortcuts))
		);
		content.appendChild(
			element('div', 'layout-content-note', _t('layout_manager.extension_opt_in'))
		);
		item.appendChild(content);
	}

	const buttons = element('div', 'layout-actions');
	if (busy && busy.id === row.id) {
		const key =
			busy.action === 'uninstall' ? 'layout_manager.busy_uninstall' : 'layout_manager.busy_install';
		buttons.appendChild(element('span', 'busy', _t(key)));
	}
	if (row.homepage) buttons.appendChild(actionButton('open_homepage', row.id, false, 'link'));
	for (const action of row.actions) {
		buttons.appendChild(
			actionButton(action, row.id, Boolean(busy), action === 'uninstall' ? 'danger' : '')
		);
	}
	item.appendChild(buttons);
	return item;
}

/**
 * Builds one action button.
 * @param {string} action
 * @param {string} id
 * @param {boolean} disabled
 * @param {string} variant - Extra class.
 * @returns {HTMLElement}
 */
function actionButton(action, id, disabled, variant) {
	const labels = {
		install: 'layout_manager.btn_install',
		update: 'layout_manager.btn_update',
		uninstall: 'layout_manager.btn_uninstall',
		select: 'layout_manager.btn_select',
		open_homepage: 'layout_manager.btn_homepage'
	};
	const button = element('button', variant, _t(labels[action]));
	button.type = 'button';
	button.disabled = disabled;
	button.dataset.action = action;
	button.addEventListener('click', function () {
		send(action, id);
	});
	return button;
}

/**
 * Redraws the whole page from the last state.
 */
function render() {
	const rows = layoutRows(_state);
	const busy = _state && _state.busy && typeof _state.busy.id === 'string' ? _state.busy : null;

	const status = catalogueStatus(_state);
	const statusEl = document.getElementById('catalogue-status');
	statusEl.textContent = status.text;
	statusEl.classList.toggle('is-error', status.isError);

	const refresh = document.getElementById('btn-refresh');
	refresh.disabled = Boolean(busy);

	const resultEl = document.getElementById('result');
	const result = resultMessage(_state && _state.result, rows);
	resultEl.hidden = !result;
	if (result) {
		resultEl.textContent = result.text;
		resultEl.title = result.detail;
		resultEl.classList.toggle('is-error', result.isError);
	}

	const list = document.getElementById('layout-list');
	while (list.firstChild) list.removeChild(list.firstChild);
	for (const row of rows) list.appendChild(renderRow(row, busy));
	document.getElementById('empty').hidden = rows.length > 0;
}

// ========================================
// ========================================
// ======= 4/ Host Bridge =================
// ========================================
// ========================================

/**
 * Posts one allowlisted action to the host.
 * @param {string} action
 * @param {string} [id] - Registry id the action applies to.
 */
function send(action, id) {
	if (!LAYOUT_MANAGER_ACTIONS.includes(action))
		throw new Error('layout manager: unknown action ' + action);
	const payload = { action };
	if (id !== undefined) payload.id = id;
	setTimeout(function () {
		_post(payload);
	}, 0);
}

/**
 * Called by the host once the page is ready: strings and the first state.
 * @param {{strings: Object, state: Object}} data
 */
window.initData = function (data) {
	if (!data || typeof data !== 'object') return;
	if (data.strings && typeof data.strings === 'object') {
		_strings = data.strings;
		applyDomStrings();
	}
	window.updateState(data.state);
};

/**
 * Called by the host after every refresh or operation.
 * @param {Object} state
 */
window.updateState = function (state) {
	_state = state && typeof state === 'object' ? state : null;
	render();
};

// ========================================
// ========================================
// ======= 5/ Events & Ready ==============
// ========================================
// ========================================

document.getElementById('btn-refresh').addEventListener('click', function () {
	send('refresh');
});

document.getElementById('btn-close').addEventListener('click', function () {
	send('close');
});

// The hosts also push initData when the navigation completes; this is the
// page's own hint that its handlers are in place.
send('ready');
