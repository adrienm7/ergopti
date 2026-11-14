// _shared/ui/layout_editor_window/script.js

// ===========================================================================
// MODULE: Layout Editor Window Page
// DESCRIPTION:
// The unified layout editor (_shared/ui/layout_editor) alone in its own
// window, opened by the menu's « Create or edit a layout… » and by the layout
// manager's « Layout editor » button on the three drivers. The editor saves,
// installs, emulates and applies through the same host actions the layout
// manager page used when it carried the editor:
//   source_open, source_save, source_pick, composer_open, composer_save,
//   composer_emulate, nav_save
// Each host checks them again before acting
// (_shared/layouts/engine/manager_bridge.lua, windows/ui/layout_manager).
// The downloads the site offers (Linux XKB, Windows KLC and DLL images, macOS
// bundle) are built here, offline, with the export data the app ships
// (layout_editor/_generated/export_assets.js); source_export hands their bytes
// to the host, which writes them to the user's Downloads folder.
// ===========================================================================

// ========================================
// ========================================
// ======= 1/ State =======================
// ========================================
// ========================================

// The only actions a host accepts from this page.
const LAYOUT_EDITOR_WINDOW_ACTIONS = Object.freeze([
	'ready',
	'close',
	'composer_open',
	'composer_save',
	'composer_emulate',
	'source_open',
	'source_save',
	'source_pick',
	'source_export',
	'nav_save'
]);

// Locale strings, pushed by the host with initData.
let _strings = {};
// Last state pushed by the host (the editor reads its platform).
let _state = null;

const _post = makeHostBridge('layout_editor_window_bridge');

/** Applies translations to every element carrying data-i18n. */
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
// ======= 2/ Host Bridge =================
// ========================================
// ========================================

/**
 * Posts one allowlisted action to the host.
 * @param {string} action
 * @param {Object} [extra] - More fields of the message.
 */
function send(action, extra) {
	if (!LAYOUT_EDITOR_WINDOW_ACTIONS.includes(action))
		throw new Error('layout editor window: unknown action ' + action);
	const payload = { action };
	if (extra !== undefined) Object.assign(payload, extra);
	setTimeout(function () {
		_post(payload);
	}, 0);
}

// Whether the host applies the source's navigation layer (nav_save), from initData.
let _hostAppliesNav = false;
// Whether the host opens files in a native panel (macOS), from initData.
let _hostPicks = false;
// Whether the host emulates a source without installing it (composer_emulate), from initData.
let _hostEmulates = false;
// Whether the host writes the editor's downloads to the Downloads folder (source_export), from initData.
let _hostExports = false;

/**
 * Called by the host once the page is ready: strings, capabilities and state.
 * The host then sends the last saved source with sourceData.
 * @param {{strings: Object, state: Object}} data
 */
window.initData = function (data) {
	if (!data || typeof data !== 'object') return;
	if (data.strings && typeof data.strings === 'object') {
		_strings = data.strings;
		applyDomStrings();
	}
	_hostPicks = data.source_pick === true;
	_hostAppliesNav = data.nav_apply === true;
	_hostEmulates = data.emulate === true;
	_hostExports = data.source_export === true;
	window.updateState(data.state);
};

/**
 * Called by the host after an install or an emulation changed the layouts.
 * @param {Object} state
 */
window.updateState = function (state) {
	_state = state && typeof state === 'object' ? state : _state;
};

// ========================================
// ========================================
// ======= 3/ Layout editor ===============
// ========================================
// ========================================

let _editor = null;
let _pendingSave = null;
let _pendingInstall = null;
let _pendingSources = null;
let _pendingPick = null;
let _pendingNav = null;
let _pendingExport = null;
let _exportAssets = null;

/** Saves one editor file through the host; settles on sourceResult. */
function hostSave(filename, text) {
	return new Promise(function (resolve, reject) {
		if (_pendingSave) {
			reject({ code: 'save_busy', path: filename });
			return;
		}
		_pendingSave = { resolve: resolve, reject: reject };
		send('source_save', { filename: filename, text: text });
	});
}

/**
 * Installs the editor's source through the composer host (composer_save with
 * `source`, _shared/layouts/engine/composer/composer.lua) and switches to it; settles on
 * the composerResult that answers it.
 */
function hostInstall(payload) {
	return new Promise(function (resolve, reject) {
		if (_pendingInstall || _pendingSave) {
			reject({ code: 'save_busy', path: 'composer_save' });
			return;
		}
		_pendingInstall = { resolve: resolve, reject: reject, action: 'composer_save' };
		const message = { source: payload.source, keylayout: payload.keylayout, use: true };
		// The drivers perform the source's emulation table for what the .keylayout cannot hold.
		if (payload.emulation !== undefined) message.emulation = payload.emulation;
		// The Linux host writes the installed XKB from the source's converter target.
		if (payload.target !== undefined) message.target = payload.target;
		// The Windows host registers the layout DLL images the page wrote.
		if (payload.dlls !== undefined) {
			message.dll_name = payload.dll_name;
			message.dlls = payload.dlls;
		}
		send('composer_save', message);
	});
}

/**
 * « Emulate without installing »: stores the editor's source for the driver's
 * layout emulation alone (composer_emulate) and turns the emulation onto it;
 * settles on the composerResult that answers it.
 */
function hostEmulate(payload) {
	return new Promise(function (resolve, reject) {
		if (_pendingInstall || _pendingSave) {
			reject({ code: 'save_busy', path: 'composer_emulate' });
			return;
		}
		_pendingInstall = { resolve: resolve, reject: reject, action: 'composer_emulate' };
		const message = { source: payload.source, keylayout: payload.keylayout };
		if (payload.emulation !== undefined) message.emulation = payload.emulation;
		send('composer_emulate', message);
	});
}

/**
 * The registry layouts a layer can be filled from: the composer host's own
 * sources ({id, name, convention, text}), asked with composer_open.
 */
function hostSources() {
	return new Promise(function (resolve, reject) {
		if (_pendingSources) {
			reject({ code: 'save_busy', path: 'composer_open' });
			return;
		}
		_pendingSources = resolve;
		send('composer_open');
	});
}

/**
 * Called by the host with the composer's sources: { sources }.
 * @param {Object} data
 */
window.composerData = function (data) {
	const pending = _pendingSources;
	_pendingSources = null;
	if (pending) pending(data && Array.isArray(data.sources) ? data.sources : []);
};

/**
 * Called by the host once an install or an emulation settled:
 * { action, ok, code, detail, pending }.
 * @param {Object} result
 */
window.composerResult = function (result) {
	const pending = _pendingInstall;
	if (!pending || !result || result.action !== pending.action) return;
	_pendingInstall = null;
	// macOS may defer turning a new layout on until the next login.
	if (result.ok === true) pending.resolve({ pending: result.pending === true });
	else pending.reject({ code: result.code || 'host_save_failed', path: result.detail || '' });
};

/**
 * Applies the layers.toml the editor built from the source's navigation layer
 * through the host's navigation layer editor save (nav_save); settles on navResult.
 */
function hostApplyNav(text) {
	return new Promise(function (resolve, reject) {
		if (_pendingNav) {
			reject({ code: 'save_busy', path: 'nav_save' });
			return;
		}
		_pendingNav = { resolve: resolve, reject: reject };
		send('nav_save', { text: text });
	});
}

/**
 * Called by the host once the navigation layer is saved: { saved, applied, errors }.
 * A refused save rejects with its first error's code.
 * @param {Object} result
 */
window.navResult = function (result) {
	const pending = _pendingNav;
	_pendingNav = null;
	if (!pending) return;
	const errors = result && Array.isArray(result.errors) ? result.errors : [];
	if (result && result.saved === true) pending.resolve({ applied: result.applied === true });
	else
		pending.reject({
			code: (errors[0] && errors[0].code) || 'host_save_failed',
			path: (errors[0] && errors[0].detail) || ''
		});
};

/** The bytes as base64, the form a page message carries them in. */
function base64Of(bytes) {
	let binary = '';
	// Chunks keep each String.fromCharCode call under the engines' argument limit.
	for (let at = 0; at < bytes.length; at += 0x8000)
		binary += String.fromCharCode.apply(null, bytes.subarray(at, at + 0x8000));
	return btoa(binary);
}

/**
 * Hands one download to the host (source_export), which writes it to the
 * Downloads folder without replacing a file there; settles on exportResult
 * with the file's path.
 */
function hostSaveBinary(filename, bytes) {
	return new Promise(function (resolve, reject) {
		if (_pendingExport) {
			reject({ code: 'save_busy', path: filename });
			return;
		}
		_pendingExport = { resolve: resolve, reject: reject };
		send('source_export', { filename: filename, data: base64Of(bytes) });
	});
}

/**
 * Called by the host once a download is written: { ok, code, detail, path }.
 * @param {Object} result
 */
window.exportResult = function (result) {
	const pending = _pendingExport;
	_pendingExport = null;
	if (!pending) return;
	if (result && result.ok === true) pending.resolve(result.path);
	else
		pending.reject({
			code: (result && result.code) || 'host_save_failed',
			path: (result && result.detail) || ''
		});
};

/** What the XKB and KLC downloads run, built once from the data this page loads. */
function hostExportAssets() {
	_exportAssets =
		_exportAssets || LayoutLuaRunner.assets(window, LayoutExportAssetData, LayoutKlcGenerator);
	return _exportAssets;
}

/** Opens a file in the host's native panel; settles on sourcePicked. */
function hostPick() {
	return new Promise(function (resolve, reject) {
		if (_pendingPick) {
			reject({ code: 'save_busy', path: 'source_pick' });
			return;
		}
		_pendingPick = { resolve: resolve, reject: reject };
		send('source_pick');
	});
}

/**
 * Called by the host with the picked file: { filename, text }, {} when the
 * user cancelled, or { code, detail } when the host refused the file.
 * @param {Object} data
 */
window.sourcePicked = function (data) {
	const pending = _pendingPick;
	_pendingPick = null;
	if (!pending) return;
	if (data && typeof data.code === 'string')
		pending.reject({ code: data.code, path: data.detail || '' });
	else pending.resolve(data && typeof data.text === 'string' ? data : null);
};

/**
 * Called by the host with the last saved source: { text, filename, folder }.
 * The first one mounts the editor; a later one (the menu asked again) opens it.
 * @param {Object} data
 */
window.sourceData = function (data) {
	const initial = data && typeof data.text === 'string' ? data.text : null;
	// A host that does not seed window._i18n_strings (Windows) sends the editor's strings here.
	if (data && data.strings && typeof data.strings === 'object')
		window._i18n_strings = Object.assign({}, window._i18n_strings || {}, data.strings);
	if (_editor) {
		if (initial !== null) _editor.open(data.filename, initial);
		return;
	}
	_editor = LayoutEditorPage.mount(document.getElementById('layout-editor'), {
		saveFile: hostSave,
		install: hostInstall,
		emulate: _hostEmulates ? hostEmulate : null,
		loadSources: hostSources,
		pickFile: _hostPicks ? hostPick : null,
		applyNav: _hostAppliesNav ? hostApplyNav : null,
		saveBinary: _hostExports ? hostSaveBinary : null,
		exportAssets: _hostExports ? hostExportAssets : null,
		platform: _state && _state.platform,
		savedStatus: 'status.saved_in_app',
		initial: initial,
		// The editor is the whole window: leaving it closes the window.
		onClose: function () {
			send('close');
		}
	});
};

/**
 * Called by the host once a file is stored: { ok, code, detail, filename }.
 * @param {Object} result
 */
window.sourceResult = function (result) {
	const pending = _pendingSave;
	_pendingSave = null;
	if (!pending) return;
	if (result && result.ok === true) pending.resolve();
	else
		pending.reject({
			code: (result && result.code) || 'host_save_failed',
			path: (result && result.detail) || ''
		});
};

// ========================================
// ========================================
// ======= 4/ Ready =======================
// ========================================
// ========================================

// The hosts also push initData when the navigation completes; this is the
// page's own hint that its handlers are in place.
send('ready');
