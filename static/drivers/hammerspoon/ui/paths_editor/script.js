// ui/paths_editor/script.js

// ========================================
// ========================================
// ======= 1/ Constants & State ===========
// ========================================
// ========================================

const ICONS = {
	PersonalTomlPath:     "📄",
	PersonalInfoTomlPath: "📋",
	HotstringsDirPath:    "📁",
	ConfigJsonPath:       "⚙️",
	KarabinerConfigPath:  "⌨️",
};

// Holds the full data payload received from Lua on init
let _data = null;

// Current working values (key → path string), updated as the user edits
const _current = {};


// =====================================
// =====================================
// ======= 2/ DOM Helpers ==============
// =====================================
// =====================================

/**
 * Returns the input element for a given path key.
 * @param {string} key - The path key.
 * @returns {HTMLInputElement|null}
 */
function inputFor(key) {
	return document.getElementById("input-" + key);
}

/**
 * Returns the tag span element for a given path key.
 * @param {string} key - The path key.
 * @returns {HTMLElement|null}
 */
function tagFor(key) {
	return document.getElementById("tag-" + key);
}

/**
 * Updates the tag (default/modified) and input styling for a row.
 * @param {string} key - The path key.
 */
function refreshTag(key) {
	const inp = inputFor(key);
	const tag = tagFor(key);
	if (!inp || !tag || !_data) return;

	const isDefault = _current[key] === _data.defaults[key];
	inp.classList.toggle("is-default", isDefault);
	tag.textContent  = isDefault ? "par défaut" : "modifié";
	tag.className    = isDefault ? "tag-default" : "tag-modified";
}


// ==============================================
// ==============================================
// ======= 3/ Form Builder =====================
// ==============================================
// ==============================================

/**
 * Builds and injects all form rows from the data payload.
 * @param {Object} data - The payload from Lua (keys, labels, defaults, current).
 */
function buildForm(data) {
	const form = document.getElementById("paths-form");
	form.innerHTML = "";

	data.keys.forEach(function (key) {
		_current[key] = data.current[key] || data.defaults[key] || "";

		const row = document.createElement("div");
		row.className = "row";

		// Header: icon + label + tag
		const header = document.createElement("div");
		header.className = "row-header";

		const icon = document.createElement("span");
		icon.className   = "row-icon";
		icon.textContent = ICONS[key] || "📄";

		const lbl = document.createElement("label");
		lbl.setAttribute("for", "input-" + key);
		lbl.textContent = data.labels[key] || key;

		const tag = document.createElement("span");
		tag.id = "tag-" + key;

		header.appendChild(icon);
		header.appendChild(lbl);
		header.appendChild(tag);

		// Input row: text field + browse button
		const wrap = document.createElement("div");
		wrap.className = "path-input-wrap";

		const inp = document.createElement("input");
		inp.type  = "text";
		inp.id    = "input-" + key;
		inp.value = _current[key];
		inp.addEventListener("input", function () {
			_current[key] = inp.value;
			refreshTag(key);
		});

		const btn = document.createElement("button");
		btn.type        = "button";
		btn.className   = "btn-browse";
		btn.textContent = "Parcourir…";
		btn.addEventListener("click", function () {
			// setTimeout(0) ensures postMessage fires outside the synchronous click stack,
			// which is required for WKWebView to dispatch it reliably
			setTimeout(function () {
				try {
					window.webkit.messageHandlers.hsPaths.postMessage({ action: "browse", key: key });
				} catch (e) {
					console.error("postMessage failed:", e);
				}
			}, 0);
		});

		wrap.appendChild(inp);
		wrap.appendChild(btn);

		row.appendChild(header);
		row.appendChild(wrap);
		form.appendChild(row);

		refreshTag(key);
	});
}


// =============================================
// =============================================
// ======= 4/ Lua Bridge =======================
// =============================================
// =============================================

/**
 * Called by Lua once when the webview is ready, with the full initial data.
 * @param {Object} data - {keys, labels, defaults, current}
 */
window.initData = function (data) {
	_data = data;
	buildForm(data);
};

/**
 * Called by Lua after the user picks a path via the native file picker.
 * @param {string} key - The path key that was browsed.
 * @param {string} path - The picked absolute path.
 */
window.applyBrowseResult = function (key, path) {
	if (!path) return;
	_current[key] = path;
	const inp = inputFor(key);
	if (inp) inp.value = path;
	refreshTag(key);
};


// ==========================================
// ==========================================
// ======= 5/ Button Actions ================
// ==========================================
// ==========================================

document.getElementById("btn-save").addEventListener("click", function () {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsPaths.postMessage({ action: "save", current: _current });
		} catch (e) {
			console.error("save postMessage failed:", e);
		}
	}, 0);
});

document.getElementById("btn-cancel").addEventListener("click", function () {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsPaths.postMessage({ action: "cancel" });
		} catch (e) {
			console.error("cancel postMessage failed:", e);
		}
	}, 0);
});

document.getElementById("btn-reset").addEventListener("click", function () {
	if (!_data) return;
	_data.keys.forEach(function (key) {
		_current[key] = _data.defaults[key] || "";
		const inp = inputFor(key);
		if (inp) inp.value = _current[key];
		refreshTag(key);
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
		try {
			window.webkit.messageHandlers.hsPaths.postMessage({ action: "ready" });
		} catch (e) {
			console.error("ready postMessage failed:", e);
		}
	}, 0);
}());
