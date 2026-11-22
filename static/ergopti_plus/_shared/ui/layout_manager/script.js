// _shared/ui/layout_manager/script.js

// ===========================================================================
// MODULE: Layout Manager Page
// DESCRIPTION:
// Lists the layouts of the keyboard-layout registry with their author,
// licence and version, whether each one is installed, can be updated or is
// available, and offers the matching install / update / uninstall / use
// buttons. The three drivers host this page and send it the same state:
//   { platform, shortcut_menu_path, index, source, error, installed, provided,
//     builtin, active, busy, result }
// Windows adds `native`, the keyboard layouts Studio registered as DLLs,
// each removed through its own uninstaller ({ action: 'uninstall', dll }).
// The page decides the rows from that state (one source for every driver)
// and only ever posts the allowlisted actions below; each host checks them
// again before acting.
// Keyboard and screen reader: the root names the interface language every
// host seeds (window._i18n_locale), a redraw keeps the focus on the row the
// user acted on, and Escape posts close, on the three hosts.
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
	'close',
	'open_editor'
]);

// Failure codes the hosts report, each with its own explanation. Any other
// code falls back to the generic one, with the host's detail as a tooltip.
const FAILURE_KEYS = Object.freeze({
	busy: 'layout_manager.failure_busy',
	provided_by_bundle: 'layout_manager.failure_provided_by_bundle',
	foreign_file: 'layout_manager.failure_foreign_file',
	download_failed: 'layout_manager.failure_download',
	python_missing: 'layouts.linux_needs_python',
	// Linux: a compositor that selects its layout only in its own file (Sway, niri...).
	session_unsupported: 'layout_manager.failure_session_unsupported'
});

// The DLL name of a Windows keyboard layout (KbdRegister_Constant("dll_name")).
const NATIVE_DLL_NAME = /^[a-z][a-z0-9]{0,7}$/;

// Catalogue error codes (_shared/layouts/engine/composer/catalogue.lua and its AHK twin).
const CATALOGUE_ERROR_KEYS = Object.freeze({
	offline: 'layout_manager.error_offline',
	http: 'layout_manager.error_http'
});

// Locale strings, pushed by the host with initData.
let _strings = {};
// Last state pushed by the host.
let _state = null;

const _post = makeHostBridge('layout_manager_bridge');

// The page speaks the interface language: a screen reader picks its voice from
// the root lang (WCAG 3.1.1), which index.html declares as fr. Every host seeds
// window._i18n_locale before this script runs (LTP-01, LTP-02).
if (typeof window._i18n_locale === 'string' && window._i18n_locale !== '')
	window.setPageLocale(window._i18n_locale);
else console.error('layout manager: no window._i18n_locale seeded; the page language stays fr');

// The elements of the last redraw that can take the focus back:
// { row, action, el }, action '' for a row's heading.
let _focusables = [];

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
 * @param {string} shortcutMenuPath - The extension file holding the host's shortcut menu.
 * @returns {Object}
 */
function makeRow(entry, installed, provided, builtin, active, shortcutMenuPath) {
	const source = entry || installed;
	const files =
		source.extension && Array.isArray(source.extension.files) ? source.extension.files : [];
	const hotstrings = files.filter(
		(file) => typeof file.path === 'string' && /^hotstrings\/.+\.toml$/.test(file.path)
	).length;
	const shortcuts = files.some((file) => file.path === shortcutMenuPath) ? 1 : 0;
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
	// The host names the shortcut menu file it loads; the page never derives it from the platform.
	if (typeof state.shortcut_menu_path !== 'string' || state.shortcut_menu_path === '')
		throw new Error('layout manager host must name its shortcut_menu_path');
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
				// The AutoHotkey host's JSON writer sends a boolean as 1.
				builtin[entry.id] === true || builtin[entry.id] === 1,
				active,
				state.shortcut_menu_path
			)
		);
	}
	for (const id of Object.keys(installed).sort()) {
		if (!listed.has(id) && installed[id] && typeof installed[id].id === 'string') {
			rows.push(makeRow(null, installed[id], false, false, active, state.shortcut_menu_path));
		}
	}
	const native = Array.isArray(state.native) ? state.native : [];
	for (const layout of native) {
		if (layout && typeof layout.dll === 'string' && NATIVE_DLL_NAME.test(layout.dll))
			rows.push(nativeRow(layout));
	}
	return rows;
}

/**
 * One keyboard layout Studio registered as a Windows DLL: it can only be
 * removed, through its own uninstaller.
 * @param {Object} layout - { dll, name, author, klid } from the host.
 * @returns {Object}
 */
function nativeRow(layout) {
	return {
		id: 'native:' + layout.dll,
		dll: layout.dll,
		name: typeof layout.name === 'string' && layout.name !== '' ? layout.name : layout.dll,
		author: typeof layout.author === 'string' ? layout.author : '',
		licence: '',
		homepage: '',
		version: '',
		installedVersion: '',
		status: 'native',
		active: false,
		removed: false,
		hotstrings: 0,
		shortcuts: 0,
		actions: ['uninstall']
	};
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
	// A removed DLL row is gone from the list: the host names it in the result.
	const name = row ? row.name : typeof result.name === 'string' ? result.name : result.id;
	const detail = typeof result.detail === 'string' ? result.detail : '';
	if (!result.ok) {
		const key = FAILURE_KEYS[result.code] || 'layout_manager.failure_other';
		return { text: _fmt('layout_manager.result_failed', name, _t(key)), isError: true, detail };
	}
	if (result.warning === 'macos_consent') {
		return {
			text: _fmt('layout_manager.result_installed_consent', name),
			isError: false,
			detail
		};
	}
	if (result.warning === 'pending_logout') {
		return {
			text: _fmt('layout_manager.result_installed_pending_logout', name),
			isError: false,
			detail
		};
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
	// Each card is a self-contained article: its name is the heading a screen
	// reader jumps by, its header carries the badges and its footer the actions.
	const card = element('article', 'layout-card');
	item.appendChild(card);

	const header = element('header', 'layout-header');
	const heading = element('h2', 'layout-name', row.name);
	// Out of the Tab order: the focus comes back here when the button the user
	// pressed is disabled or gone after the redraw.
	heading.setAttribute('tabindex', '-1');
	_focusables.push({ row: row.id, action: '', el: heading });
	header.appendChild(heading);
	const badges = element('ul', 'layout-badges');
	badges.appendChild(
		element('li', 'badge badge-' + row.status, _t('layout_manager.status_' + row.status))
	);
	if (row.active)
		badges.appendChild(element('li', 'badge badge-active', _t('layout_manager.status_active')));
	header.appendChild(badges);
	card.appendChild(header);

	const meta = element('ul', 'layout-meta');
	if (row.author)
		meta.appendChild(element('li', '', _fmt('layout_manager.meta_author', row.author)));
	if (row.licence)
		meta.appendChild(element('li', '', _fmt('layout_manager.meta_licence', row.licence)));
	if (row.version)
		meta.appendChild(element('li', '', _fmt('layout_manager.meta_version', row.version)));
	if (row.dll) meta.appendChild(element('li', '', _fmt('layout_manager.meta_dll', row.dll)));
	if (row.installedVersion && row.installedVersion !== row.version) {
		meta.appendChild(
			element('li', '', _fmt('layout_manager.meta_installed_version', row.installedVersion))
		);
	}
	card.appendChild(meta);
	if (row.hotstrings || row.shortcuts) {
		card.appendChild(
			element(
				'p',
				'layout-content',
				_fmt('layout_manager.extension_content', row.hotstrings, row.shortcuts)
			)
		);
		card.appendChild(
			element('p', 'layout-content layout-content-note', _t('layout_manager.extension_opt_in'))
		);
	}

	const buttons = element('footer', 'layout-actions');
	if (busy && busy.id === row.id && busy.action !== 'select') {
		const key =
			busy.action === 'uninstall' ? 'layout_manager.busy_uninstall' : 'layout_manager.busy_install';
		buttons.appendChild(element('p', 'busy', _t(key)));
	}
	if (row.homepage) buttons.appendChild(actionButton('open_homepage', row.id, false, 'link'));
	for (const action of row.actions) {
		buttons.appendChild(
			actionButton(
				action,
				row.id,
				Boolean(busy),
				action === 'uninstall' ? 'danger' : '',
				row.dll ? { dll: row.dll } : undefined
			)
		);
	}
	card.appendChild(buttons);
	return item;
}

/**
 * Builds one action button.
 * @param {string} action
 * @param {string} id
 * @param {boolean} disabled
 * @param {string} variant - Extra class.
 * @param {Object} [target] - { dll } for a Windows DLL row, which has no registry id.
 * @returns {HTMLElement}
 */
function actionButton(action, id, disabled, variant, target) {
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
	_focusables.push({ row: id, action, el: button });
	button.addEventListener('click', function () {
		if (target) send(action, undefined, target);
		else send(action, id);
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
	const focused = focusedTarget();
	_focusables = [];
	while (list.firstChild) list.removeChild(list.firstChild);
	for (const row of rows) list.appendChild(renderRow(row, busy));
	document.getElementById('empty').hidden = rows.length > 0;
	if (focused) restoreFocus(focused);
}

/**
 * The row and action of the list element that holds the focus, before a
 * redraw replaces it.
 * @returns {{row: string, action: string}|null}
 */
function focusedTarget() {
	const active = document.activeElement;
	const target = _focusables.find((candidate) => candidate.el === active);
	return target ? { row: target.row, action: target.action } : null;
}

/**
 * Gives the focus back after a redraw: to the same button when it can take
 * it, else to its row's heading, else to the result line, which names a row
 * that left the list. The redraw replaced every element, so without this the
 * focus fell to the document and a keyboard or screen reader user started
 * again from the top after each install (LTP-06).
 * @param {{row: string, action: string}} focused
 */
function restoreFocus(focused) {
	const same = _focusables.find(
		(candidate) =>
			candidate.row === focused.row && candidate.action === focused.action && !candidate.el.disabled
	);
	const heading = _focusables.find(
		(candidate) => candidate.row === focused.row && candidate.action === ''
	);
	const result = document.getElementById('result');
	const target = same
		? same.el
		: heading
			? heading.el
			: result.hidden
				? document.getElementById('btn-refresh')
				: result;
	target.focus();
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
 * @param {Object} [extra] - More fields of the message.
 */
function send(action, id, extra) {
	if (!LAYOUT_MANAGER_ACTIONS.includes(action))
		throw new Error('layout manager: unknown action ' + action);
	const payload = { action };
	if (id !== undefined) payload.id = id;
	if (extra !== undefined) Object.assign(payload, extra);
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
	// Only a host that stores the editor's files offers it (all three drivers),
	// in its own window (_shared/ui/layout_editor_window).
	document.getElementById('btn-editor').hidden = data.source_editor !== true;
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

// The layout editor opens in its own window (_shared/ui/layout_editor_window).
document.getElementById('btn-editor').addEventListener('click', function () {
	send('open_editor');
});

document.getElementById('btn-close').addEventListener('click', function () {
	send('close');
});

// Escape closes the window, as « Close » does and as Escape closes the Updates
// window (UPD-03): the WebView holds the keyboard focus, so no host window
// sees the key (LTP-07). The window keeps no unsaved work, and an operation
// in flight goes on without it.
document.addEventListener('keydown', function (event) {
	if (event.key !== 'Escape' || event.defaultPrevented) return;
	event.preventDefault();
	send('close');
});

// The hosts also push initData when the navigation completes; this is the
// page's own hint that its handlers are in place.
send('ready');
