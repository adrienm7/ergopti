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
// Ergopti Studio reads the user's own typing with keystats_ngrams: the host
// answers keystatsNgrams with the counts of the local keystats store
// (_shared/metrics/engine/view/studio_ngrams.lua), read only and never sent
// anywhere; the page reads it once when the window opens (« My typing » is the
// app's default corpus) and again on « Analyse my typing ».
// The drivers' « Navigation layer » entries open this window on the source's
// navigation layer: the host calls studioNav({text, hold}) with the user's
// layers.toml and the key whose hold enters the layer, before or after the
// editor is mounted.
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
	'nav_save',
	'keystats_ngrams',
	'open_link',
	'studio_layouts',
	'studio_layout_save',
	'studio_layout_remove',
	'studio_corpus',
	'studio_profile_load',
	'studio_profile_save',
	'studio_workspace_load',
	'studio_workspace_save',
	'lua_export'
]);

// Locale strings: the catalogue macOS and Linux seed as window._i18n_strings,
// overlaid by the strings the host pushes with initData.
let _strings = {};
// The start source the editor copies when the host has no saved source (the
// registry id of Ergopti, from the host's composer sources).
const ERGOPTI_START = 'ergopti';
// Last state pushed by the host (the editor reads its platform).
let _state = null;

const _post = makeHostBridge('layout_editor_window_bridge');

/**
 * Whether a locale key has a translation.
 * @param {string} key
 * @returns {boolean}
 */
function hasString(key) {
	return Object.prototype.hasOwnProperty.call(_strings, key);
}

/**
 * Applies translations to every element carrying data-i18n, and to the
 * placeholders and options the Comparer's markup names (as i18n.js does).
 */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		const key = el.getAttribute('data-i18n');
		if (!hasString(key)) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
	document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
		const key = el.getAttribute('data-i18n-placeholder');
		if (hasString(key)) el.placeholder = _strings[key];
	});
	document.querySelectorAll('select[data-i18n-option-prefix]').forEach(function (select) {
		const prefix = select.getAttribute('data-i18n-option-prefix');
		select.querySelectorAll('option').forEach(function (option) {
			const key = prefix + '.' + option.value;
			if (hasString(key)) option.textContent = _strings[key];
		});
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
// Whether the host runs the downloads' export adapter with its own Lua (lua_export), from initData.
let _hostLuaExport = false;
// Whether the host writes the editor's downloads to the Downloads folder (source_export), from initData.
let _hostExports = false;
// Whether the host keeps the editor's tabs in the user's data folder (studio_workspace_*), from initData.
let _hostWorkspace = false;

/**
 * Called by the host once the page is ready: strings, capabilities and state.
 * The host then sends the last saved source with sourceData.
 * @param {{strings: Object, state: Object}} data
 */
window.initData = function (data) {
	if (!data || typeof data !== 'object') return;
	if (data.strings && typeof data.strings === 'object') {
		_strings = Object.assign({}, window._i18n_strings || {}, data.strings);
		window._i18n_strings = _strings;
		applyDomStrings();
		// The Comparer redraws the text it builds from data on this event.
		document.dispatchEvent(new CustomEvent('i18n:applied'));
	}
	_hostPicks = data.source_pick === true;
	_hostAppliesNav = data.nav_apply === true;
	_hostEmulates = data.emulate === true;
	_hostExports = data.source_export === true;
	_hostLuaExport = data.lua_export === true;
	_hostWorkspace = data.studio_workspace === true;
	showKeystatsSource(data.keystats === true);
	// « My typing » is the app's default corpus (maintainer, 2026-11-14): the
	// window reads the local store once when it opens, as the button does; the
	// counts stay in this window, as the bar's privacy line says.
	if (data.keystats === true && !_keystatsOpened) {
		_keystatsOpened = true;
		loadKeystats(true);
	}
	settleStudioStore(data.studio_store === true);
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

/**
 * What the XKB and KLC downloads run, built once from the data this page loads.
 * The macOS and Linux windows refuse the page's fengari VM (no 'unsafe-eval'):
 * their host runs the shared export adapter with its own Lua (lua_export,
 * answered by luaExportResult), and so does Windows once its build ships the export
 * step executable; a Windows build without it keeps fengari.
 */
function hostExportAssets() {
	if (_exportAssets) return _exportAssets;
	_exportAssets = _hostLuaExport
		? {
				lua: { call: hostLuaStep },
				keysyms: LayoutExportAssetData.keysyms,
				template: LayoutExportAssetData.template,
				types: LayoutExportAssetData.types,
				generator: LayoutKlcGenerator
			}
		: LayoutLuaRunner.assets(window, LayoutExportAssetData, LayoutKlcGenerator);
	return _exportAssets;
}

/**
 * Runs one step of the export adapter in the host, as LayoutLuaRunner's call
 * does in the page: the input crosses as JSON text, the result comes back as
 * the shared json module's encoding.
 * @param {'read'|'xkb'} step
 * @param {object} input
 * @returns {Promise<object>}
 */
function hostLuaStep(step, input) {
	return studioRequest('lua_export', { step: step, input: JSON.stringify(input) }).then(
		function (result) {
			return JSON.parse(result.output);
		}
	);
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
// The navigation layer the host asked to show before the editor was mounted.
let _pendingNavShow = null;

/**
 * Called by the host to show the navigation layer: { text, hold }, where text
 * is the user's layers.toml (or the shipped one) and hold the registry code
 * of the key whose hold enters the layer, null when unknown.
 * @param {Object} nav
 */
window.studioNav = function (nav) {
	if (!nav || typeof nav !== 'object') return;
	if (_editor) _editor.showNav(nav);
	else _pendingNavShow = nav;
};

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
		workspace: _hostWorkspace ? hostWorkspace : null,
		startNav: _pendingNavShow,
		platform: _state && _state.platform,
		savedStatus: 'status.saved_in_app',
		initial: initial,
		// No saved source yet: the Studio opens on a copy of Ergopti rather than an
		// empty keyboard (maintainer, 2026-11-15); the user's own layout, once saved,
		// is what the host sends next time.
		startFrom: initial === null ? ERGOPTI_START : null,
		// « Compare with other layouts »: the Comparer ranks the edited layout
		// against the layouts ticked there, on its chosen corpus.
		compare: compareEdited,
		// The editor is the whole window: leaving it closes the window, after the
		// tabs' last edits (the host answers the messages in order).
		onClose: function () {
			_editor.flushAutosave();
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
// ======= 4/ My typing (keystats) ========
// ========================================
// ========================================

// The user's own n-gram counts once loaded ({schema, source, chars, bigrams,
// trigrams, total}); the Studio analysis reads them from here.
let _keystatsNgrams = null;
let _keystatsPending = false;
// Whether the pending read is the one the window makes when it opens.
let _keystatsAutomatic = false;
// Whether that read was made: initData may come again (a reload).
let _keystatsOpened = false;

// The message of each refusal code the hosts send (metrics/engine/view/studio_ngrams.lua
// CODES); an unknown code reads as unreadable, never as an empty success.
const KEYSTATS_REFUSALS = Object.freeze({
	keystats_absent: 'layout_editor.studio.keystats.keystats_absent',
	keystats_unreadable: 'layout_editor.studio.keystats.keystats_unreadable'
});

/**
 * Formats one translated string, replacing {1}, {2}… with the arguments.
 * @param {string} key
 * @param {...*} args
 * @returns {string}
 */
function tr(key) {
	const args = Array.prototype.slice.call(arguments, 1);
	const text = Object.prototype.hasOwnProperty.call(_strings, key) ? _strings[key] : key;
	return text.replace(/\{(\d+)\}/g, function (whole, index) {
		const value = args[Number(index) - 1];
		return value === undefined ? whole : String(value);
	});
}

/**
 * Shows the « My typing » bar when the host reads keystats.
 * @param {boolean} offered
 */
function showKeystatsSource(offered) {
	document.getElementById('studio-keystats').hidden = !offered;
}

/**
 * Writes the bar's status line.
 * @param {string} text
 * @param {boolean} [error]
 */
function setKeystatsStatus(text, error) {
	const status = document.getElementById('studio-keystats-status');
	status.textContent = text;
	status.classList.toggle('error', error === true);
}

/**
 * Asks the host for the user's n-grams, once at a time.
 * @param {boolean} [automatic] - The read the window makes when it opens.
 */
function loadKeystats(automatic) {
	if (_keystatsPending) return;
	_keystatsPending = true;
	_keystatsAutomatic = automatic === true;
	document.getElementById('studio-keystats-load').disabled = true;
	setKeystatsStatus(tr('layout_editor.studio.keystats.loading'));
	send('keystats_ngrams');
}

/**
 * Called by the host with the user's n-grams: { ok, ngrams } or { ok: false, code }.
 * A refusal keeps the previous data and says why.
 * @param {Object} result
 */
window.keystatsNgrams = function (result) {
	_keystatsPending = false;
	document.getElementById('studio-keystats-load').disabled = false;
	const ngrams = result && result.ok === true ? result.ngrams : null;
	if (!ngrams || typeof ngrams !== 'object' || typeof ngrams.chars !== 'object') {
		const code = result && typeof result.code === 'string' ? result.code : '';
		const key = Object.prototype.hasOwnProperty.call(KEYSTATS_REFUSALS, code)
			? KEYSTATS_REFUSALS[code]
			: KEYSTATS_REFUSALS.keystats_unreadable;
		// No store yet is not a failure of the read the window makes by itself:
		// the built-in corpus stays chosen, and the bar says why.
		setKeystatsStatus(tr(key), !(_keystatsAutomatic && code === 'keystats_absent'));
		return;
	}
	_keystatsNgrams = ngrams;
	setKeystatsStatus(
		tr('layout_editor.studio.keystats.loaded', Math.round(ngrams.total || 0).toLocaleString())
	);
	document.dispatchEvent(new CustomEvent('studio-ngrams', { detail: ngrams }));
};

document.getElementById('studio-keystats-load').addEventListener('click', function () {
	loadKeystats(false);
});

// The analysis panels (_shared/ui/layout_analysis) open their « i » links
// through the host, in the system browser, instead of a WebView tab. The
// panels and the Comparer read this same object (LAYOUT_ANALYSIS_HOST).
window.LAYOUT_ANALYSIS_HOST = Object.assign(window.LAYOUT_ANALYSIS_HOST || {}, {
	openLink: function (url) {
		send('open_link', { url: String(url) });
	}
});

// ========================================
// ========================================
// ======= 5/ Personal layouts ============
// ========================================
// ========================================

// The Comparer's personal layouts live in the host (the user's data folder),
// so they survive the window, a reload and a crash. Each one travels as its
// JSON text, which the host stores and returns exactly as given.
let _studioRequest = 0;
const _studioPending = new Map();

/**
 * Sends one personal-layout message and settles on the host's answer.
 * @param {string} action
 * @param {Object} [extra]
 * @returns {Promise<Object>} The host's answer.
 */
function studioRequest(action, extra) {
	return new Promise(function (resolve, reject) {
		const request = ++_studioRequest;
		_studioPending.set(request, { resolve: resolve, reject: reject });
		send(action, Object.assign({ request: request }, extra || {}));
	});
}

/**
 * Settles the request a host answer names.
 * @param {Object} result - { request, ok, code, detail, ... }.
 */
function settleStudio(result) {
	const pending = result && _studioPending.get(result.request);
	if (!pending) return;
	_studioPending.delete(result.request);
	if (result.ok === true) pending.resolve(result);
	else pending.reject({ code: result.code || 'host_save_failed', path: result.detail || '' });
}

/** Called by the host with the stored layouts: { request, ok, layouts: [json text] }. */
window.studioLayouts = settleStudio;
/** Called by the host once a layout is saved or removed: { request, ok, code, detail }. */
window.studioLayoutResult = settleStudio;
/** Called by the host once a built-in corpus's tables ran in the page: { request, ok, code, detail }. */
window.studioCorpus = settleStudio;
/** Called by the host with one export step's result: { request, ok, output | code, detail }. */
window.luaExportResult = settleStudio;
/** Called by the host with the editor's tabs: { request, ok, workspace: json text | absent }. */
window.studioWorkspace = settleStudio;
/** Called by the host once the editor's tabs are saved: { request, ok, code, detail }. */
window.studioWorkspaceResult = settleStudio;
/** Called by the host with the fingering profile: { request, ok, profile: json text | absent }. */
window.studioProfile = settleStudio;
/** Called by the host once the fingering profile is saved or reset: { request, ok, code, detail }. */
window.studioProfileResult = settleStudio;

// The Comparer lists the stored layouts as soon as it mounts, which can come
// before the host's initData says whether it keeps them: every call waits
// for that answer.
let _settleStore = null;
const _storeOffered = new Promise(function (resolve, reject) {
	_settleStore = { resolve: resolve, reject: reject };
});
// A refusal nobody awaits yet is not an unhandled rejection.
_storeOffered.catch(function () {});

/**
 * Settles whether the host keeps the Comparer's layouts (initData studio_store).
 * @param {boolean} offered
 */
function settleStudioStore(offered) {
	if (offered) _settleStore.resolve();
	else _settleStore.reject({ code: 'studio_store_unavailable', path: '' });
}

/**
 * Runs one store request once the host has offered its store.
 * @param {string} action
 * @param {Object} [extra]
 * @returns {Promise<Object>}
 */
function storeRequest(action, extra) {
	return _storeOffered.then(function () {
		return studioRequest(action, extra);
	});
}

Object.assign(window.LAYOUT_ANALYSIS_HOST, {
	store: {
		list: function () {
			return storeRequest('studio_layouts').then(function (result) {
				return (Array.isArray(result.layouts) ? result.layouts : []).map(function (text) {
					return JSON.parse(text);
				});
			});
		},
		save: function (layout) {
			return storeRequest('studio_layout_save', {
				id: layout.id,
				text: JSON.stringify(layout)
			}).then(function () {});
		},
		remove: function (id) {
			return storeRequest('studio_layout_remove', { id: id }).then(function () {});
		},
		// The Comparer's fingering profile (« Doigté »), one per user; null
		// means the defaults.
		loadProfile: function () {
			return storeRequest('studio_profile_load').then(function (result) {
				return typeof result.profile === 'string' ? JSON.parse(result.profile) : null;
			});
		},
		saveProfile: function (profile) {
			const extra = profile === null ? { reset: true } : { text: JSON.stringify(profile) };
			return storeRequest('studio_profile_save', extra).then(function () {});
		}
	},
	// The macOS and Linux hosts inline the page's scripts, so a built-in
	// corpus's tables cannot load from a relative <script src>: the host runs
	// the generated file in the page on request, only for the chosen corpus.
	loadCorpus: function (id) {
		return studioRequest('studio_corpus', { id: String(id) }).then(function () {
			const corpora = window.LAYOUT_ANALYSIS_CORPORA;
			if (!corpora || !corpora[id]) throw new Error('the host ran no tables for the corpus ' + id);
		});
	}
});

// The editor's tabs and their unsaved edits, kept in the user's data folder
// (studio_store.lua, StudioStore_Workspace*) so a reload or a crash restores
// them; LayoutEditorWorkspace owns the text.
const hostWorkspace = Object.freeze({
	load: function () {
		return studioRequest('studio_workspace_load').then(function (result) {
			return typeof result.workspace === 'string' ? result.workspace : null;
		});
	},
	save: function (text) {
		return studioRequest('studio_workspace_save', { text: text }).then(function () {});
	}
});

// ========================================
// ========================================
// ======= 6/ Tabs ========================
// ========================================
// ========================================

// The Comparer mounts the first time its tab opens, so opening the window
// costs no analysis; « My typing » loaded before then waits for the mount
// (comparer_page.js).
let _comparerMounted = false;

/**
 * Shows one of the two tabs.
 * @param {'edit'|'compare'} tab
 */
function showTab(tab) {
	const compare = tab === 'compare';
	const comparer = document.getElementById('studio-comparer');
	document.getElementById('studio-tab-edit').setAttribute('aria-selected', String(!compare));
	document.getElementById('studio-tab-compare').setAttribute('aria-selected', String(compare));
	document.getElementById('layout-editor').hidden = compare;
	comparer.hidden = !compare;
	if (!compare) return;
	if (!_comparerMounted) {
		_comparerMounted = true;
		window.LAYOUT_ANALYSIS_COMPARER.mount(comparer, { host: window.LAYOUT_ANALYSIS_HOST });
	} else {
		// Its charts lay out again once visible.
		window.dispatchEvent(new Event('resize'));
	}
	// One keyboard format for both tabs: the editor's « Format » is the Comparer's.
	if (_editor) window.LAYOUT_ANALYSIS_COMPARER.setFormat(_editor.format());
}

/**
 * Shows the edited layout in « Comparer », ticked beside the layouts already
 * chosen there; it is not stored with the personal layouts.
 * @param {Object} layout - The analysis panel's layout (library shape).
 */
function compareEdited(layout) {
	showTab('compare');
	window.LAYOUT_ANALYSIS_COMPARER.addLayouts([layout]);
}

document.getElementById('studio-tab-edit').addEventListener('click', function () {
	showTab('edit');
});
document.getElementById('studio-tab-compare').addEventListener('click', function () {
	showTab('compare');
});

// ========================================
// ========================================
// ======= 7/ Ready =======================
// ========================================
// ========================================

// The hosts also push initData when the navigation completes; this is the
// page's own hint that its handlers are in place.
send('ready');
