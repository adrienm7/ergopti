// ui/paths_editor/script.js

// ========================================
// ========================================
// ======= 1/ State =======================
// ========================================
// ========================================

// Full payload received from Lua on init
let _data = null;

// Current working value for the config directory
let _currentDir = "";


// =====================================
// =====================================
// ======= 2/ DOM Helpers ==============
// =====================================
// =====================================

/**
 * Returns the directory input element.
 * @returns {HTMLInputElement}
 */
function dirInput() {
	return document.getElementById("input-config-dir");
}

/**
 * Returns the status tag element.
 * @returns {HTMLElement}
 */
function dirTag() {
	return document.getElementById("tag-config-dir");
}

/**
 * Updates the tag (default/modified) based on current value vs default.
 */
function refreshTag() {
	if (!_data) return;
	const inp = dirInput();
	const tag = dirTag();
	if (!inp || !tag) return;
	const isDefault = _currentDir === _data.defaultConfigDir;
	inp.classList.toggle("is-default", isDefault);
	tag.textContent = isDefault ? "par défaut" : "modifié";
	tag.className   = isDefault ? "tag-default" : "tag-modified";
}


// =============================================
// =============================================
// ======= 3/ Lua Bridge =======================
// =============================================
// =============================================

/**
 * Called by Lua once the webview is ready, with initial data.
 * @param {Object} data - {configDir, defaultConfigDir}
 */
window.initData = function (data) {
	_data = data;
	_currentDir = data.configDir || data.defaultConfigDir || "";
	const inp = dirInput();
	if (inp) inp.value = _currentDir;
	refreshTag();
};

/**
 * Called by Lua after the user picks a folder via the native folder picker.
 * @param {string} path - The picked absolute directory path (with trailing slash).
 */
window.applyBrowseResult = function (path) {
	if (!path) return;
	_currentDir = path;
	const inp = dirInput();
	if (inp) inp.value = path;
	refreshTag();
};


// ==========================================
// ==========================================
// ======= 4/ Input Listener ================
// ==========================================
// ==========================================

dirInput().addEventListener("input", function () {
	_currentDir = dirInput().value;
	refreshTag();
});


// ==========================================
// ==========================================
// ======= 5/ Button Actions ================
// ==========================================
// ==========================================

document.getElementById("btn-browse").addEventListener("click", function () {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsPaths.postMessage({ action: "browse" });
		} catch (e) {
			console.error("browse postMessage failed:", e);
		}
	}, 0);
});

document.getElementById("btn-save").addEventListener("click", function () {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsPaths.postMessage({ action: "save", configDir: _currentDir });
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
	_currentDir = _data.defaultConfigDir || "";
	const inp = dirInput();
	if (inp) inp.value = _currentDir;
	refreshTag();
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
