// ui/onboarding/script.js

// =======================================
// =======================================
// ======= 1/ Locale definitions =========
// =======================================
// =======================================

// List of supported locales — injected by Lua via initData() before the
// first render. Lua is the single source of truth (lib/i18n.LOCALES table,
// sorted by lib/i18n.get_sorted_locales()), so the wizard, the macOS
// menubar language submenu and the AHK tray menu agree on both the set
// of supported locales and their display order — non-Latin script names
// (Cyrillic, Hebrew, Arabic, Devanagari, CJK, Hangul) trail after the
// Latin ones instead of intermixing alphabetically. A small inline
// fallback below keeps step 1 usable if the injection ever fails.
var LOCALES = [
	{ code: "en", flag: "🇬🇧", name: "English"  },
	{ code: "fr", flag: "🇫🇷", name: "Français" },
];

// Default locale shown when no locale has been set yet
var DEFAULT_LOCALE_CODE = "en";

// Default magic key character. ★ (U+2605 BLACK STAR) is the documented
// Ergopti default — a dedicated key in the Ergopti+ layout, and the value
// the rest of the app already labels as "the magic key" (category headers,
// reset menu, dialogs). Pre-selected on step 3; the other rows offer the
// fallback picks for non-Ergopti layouts (*, ù, ;) plus a custom input.
var DEFAULT_MAGIC_KEY = "★";


// ======================================
// ======================================
// ======= 2/ i18n helpers ==============
// ======================================
// ======================================

// Locale strings — injected by Lua via initStrings() before the first step renders
var _strings = {};

/**
 * Returns the translated string for key, or key itself as fallback.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}


// ======================================
// ======================================
// ======= 3/ Wizard state ==============
// ======================================
// ======================================

// _currentStep is a string so we can distinguish the inserted "config"
// step from the numeric ones (1..5). The step-bar dot id mirrors this:
// numeric steps light up dot-1..dot-5, the config step lights up
// dot-config.
var _currentStep = 1;
var _selectedLocale = DEFAULT_LOCALE_CODE;
var _answers = {
	locale:       DEFAULT_LOCALE_CODE,
	config_dir:   "",       // empty = keep OS default; Lua injects the
	                        // current value via initData when the wizard
	                        // re-runs over an already-configured install.
	use_ergopti:  true,
	magic_key:    DEFAULT_MAGIC_KEY,
	use_metrics:  false,
	use_gestures: false,
};


// ======================================
// ======================================
// ======= 4/ Step navigation ===========
// ======================================
// ======================================

/**
 * Shows the given step (1-5), hiding all others and updating the step dots.
 * @param {number} n
 */
function showStep(n) {
	// Hide every step (numeric + the inserted config step) first.
	for (var i = 1; i <= 5; i++) {
		var el = document.getElementById("step-" + i);
		if (el) el.classList.add("hidden");
	}
	var cfgEl = document.getElementById("step-config");
	if (cfgEl) cfgEl.classList.add("hidden");

	// Show the requested step.
	if (n === "config") {
		if (cfgEl) cfgEl.classList.remove("hidden");
	} else {
		var target = document.getElementById("step-" + n);
		if (target) target.classList.remove("hidden");
	}

	// Update the step-bar. Sequence order: 1 → config → 2 → 3 → 4 → 5.
	var ORDER = [1, "config", 2, 3, 4, 5];
	var DOT_IDS = { 1: "dot-1", "config": "dot-config", 2: "dot-2", 3: "dot-3", 4: "dot-4", 5: "dot-5" };
	var pos = ORDER.indexOf(n);
	ORDER.forEach(function (id, idx) {
		var dot = document.getElementById(DOT_IDS[id]);
		if (!dot) return;
		dot.classList.remove("active", "done");
		if (idx < pos) dot.classList.add("done");
		else if (idx === pos) dot.classList.add("active");
	});
	_currentStep = n;
}


// ======================================
// ======================================
// ======= 5/ Step renderers ============
// ======================================
// ======================================

/**
 * Builds the language list for step 1 and pre-selects the current locale.
 * Also refreshes the welcome title and heading so they read in the previewed
 * locale rather than the old "Welcome / Bienvenue / Willkommen" mash-up.
 */
function renderStep1() {
	var list = document.getElementById("lang-list");
	list.innerHTML = "";
	LOCALES.forEach(function (loc) {
		var row = document.createElement("div");
		row.className = "lang-item" + (loc.code === _selectedLocale ? " selected" : "");
		row.dataset.code = loc.code;

		var flag = document.createElement("span");
		flag.className = "lang-flag";
		flag.textContent = loc.flag;

		var name = document.createElement("span");
		name.className = "lang-name";
		name.textContent = loc.name;

		row.appendChild(flag);
		row.appendChild(name);
		row.addEventListener("click", function () {
			_selectedLocale = loc.code;
			list.querySelectorAll(".lang-item").forEach(function (r) {
				r.classList.remove("selected");
				r.querySelector(".lang-name").style.color = "";
				r.querySelector(".lang-name").style.fontWeight = "";
			});
			row.classList.add("selected");
			// Request Lua to load the strings for the selected locale so the
			// button text and subsequent steps render in the right language
			_post({ action: "previewLocale", locale: loc.code });
		});
		list.appendChild(row);
	});

	// Scroll the selected row into view
	var selected = list.querySelector(".lang-item.selected");
	if (selected) selected.scrollIntoView({ block: "nearest" });

	document.getElementById("s1-title").textContent    = _t("onboarding.welcome.title");
	document.getElementById("s1-subtitle").textContent = _t("onboarding.welcome.heading");
	document.getElementById("s1-next").textContent     = _t("onboarding.next");
	document.title = _t("onboarding.welcome.title");
}

/**
 * Refreshes the inserted config-folder step labels and fills the input
 * with the user's current path. Lua injects ``_answers.config_dir`` via
 * initData; an empty value means "use the OS default", which we then
 * resolve via DEFAULT_CONFIG_DIR (also injected by Lua) for the
 * placeholder so the user sees what the default would be.
 */
function renderStepConfig() {
	document.getElementById("sc-title").textContent  = _t("dialog.config_folder.title");
	document.getElementById("sc-desc").textContent   = _t("dialog.config_folder.label");
	document.getElementById("sc-hint").textContent   = _t("dialog.config_folder.hint");
	document.getElementById("sc-browse").textContent = _t("common.browse");
	document.getElementById("sc-back").textContent   = _t("onboarding.back");
	document.getElementById("sc-next").textContent   = _t("onboarding.next");

	var inp = document.getElementById("sc-input");
	inp.value       = _answers.config_dir || "";
	inp.placeholder = window.DEFAULT_CONFIG_DIR || "";
}

/**
 * Refreshes step 2 labels from the current _strings table.
 */
function renderStep2() {
	document.getElementById("s2-title").textContent = _t("onboarding.layout.title");
	document.getElementById("s2-desc").textContent  = _t("onboarding.layout.desc");
	document.getElementById("s2-yes-label").textContent = _t("onboarding.layout.yes");
	document.getElementById("s2-no-label").textContent  = _t("onboarding.layout.no");
	document.getElementById("s2-back").textContent = _t("onboarding.back");
	document.getElementById("s2-next").textContent = _t("onboarding.next");

	// Layout preview image — only show when Lua injected a usable URL.
	// Keeps the wizard graceful on installs where static/img/ergopti.jpg
	// is missing (asset-less build, unusual install path…).
	var preview = document.getElementById("s2-preview");
	if (preview) {
		if (window.LAYOUT_IMAGE_URL) {
			preview.src    = window.LAYOUT_IMAGE_URL;
			preview.hidden = false;
		} else {
			preview.hidden = true;
		}
	}

	// Restore saved answer
	var radios = document.querySelectorAll("input[name='layout']");
	radios.forEach(function (r) { r.checked = (r.value === (_answers.use_ergopti ? "yes" : "no")); });
}

/**
 * Picks the radio that best matches the user's context — same contract
 * as the AHK _Onboarding_PickDefaultMagicKey helper so both drivers
 * surface identical defaults:
 *   - ★ when the user enabled the Ergopti emulation on step 2,
 *   - ù when the macOS keyboard layout name suggests French / AZERTY,
 *   - ; otherwise (QWERTY family).
 * Lua injects the detected layout name via initData.system_layout
 * (lowercase). When absent we fall back to ; for safety.
 */
function _pickDefaultMagicKey() {
	if (_answers.use_ergopti) return "★";
	var layout = (window.SYSTEM_LAYOUT || "").toLowerCase();
	// Match French / AZERTY-flavoured layouts. The Apple-shipped layout
	// names are "French" / "French - Numerical" / "French - PC" / etc.;
	// the substring check catches them all without having to enumerate.
	if (layout.indexOf("french") !== -1 || layout.indexOf("azerty") !== -1)
		return "ù";
	return ";";
}

/**
 * Refreshes step 3 labels + restores the pre-selected radio. Five rows:
 * ★ (Ergopti default, FIRST and checked), *, ù, ;, custom. The custom
 * row is the only one with a text input — disabled until selected so
 * the user can't accidentally type into an inert field.
 */
function renderStep3() {
	document.getElementById("s3-title").textContent          = _t("onboarding.magic_key.title");
	document.getElementById("s3-desc").textContent           = _t("onboarding.magic_key.desc");
	document.getElementById("s3-blackstar-label").textContent = _t("onboarding.magic_key.option_blackstar");
	document.getElementById("s3-ugrave-label").textContent    = _t("onboarding.magic_key.option_ugrave");
	document.getElementById("s3-semicolon-label").textContent = _t("onboarding.magic_key.option_semicolon");
	document.getElementById("s3-custom-label").textContent    = _t("onboarding.magic_key.option_custom");
	document.getElementById("s3-hint").textContent           = _t("onboarding.magic_key.choose_freely");
	document.getElementById("s3-back").textContent           = _t("onboarding.back");
	document.getElementById("s3-next").textContent           = _t("onboarding.next");

	// Pre-select the radio matching the persisted value. If the user
	// hasn't explicitly picked one yet (still at the wizard default ★),
	// derive a context-aware default from the layout choice / system KB
	// detection so AZERTY users land on ù, QWERTY on ; and Ergopti users
	// keep ★.
	var key = _answers.magic_key;
	if (!key || key === DEFAULT_MAGIC_KEY) {
		key = _pickDefaultMagicKey();
		_answers.magic_key = key;
	}
	// The dedicated ASCII-star radio was retired (folded into the custom
	// input slot, which defaults to "*") so any saved "*" value now lands
	// on the custom row pre-filled with that character.
	var preset = { "★": "★", "ù": "ù", ";": ";" };
	var radioValue = preset[key] || "__custom__";
	var radios = document.querySelectorAll("input[name='magickey']");
	radios.forEach(function (r) { r.checked = (r.value === radioValue); });

	var inp = document.getElementById("s3-input");
	// Custom row: show the saved value if any, otherwise fall back to the
	// historical ASCII-star ("*") that used to live on its own radio.
	inp.value    = (radioValue === "__custom__") ? (key || "*") : "*";
	inp.disabled = (radioValue !== "__custom__");

	// Wire the radios so toggling Custom enables/disables the text input.
	radios.forEach(function (r) {
		r.addEventListener("change", function () {
			var isCustom = (r.checked && r.value === "__custom__");
			inp.disabled = !isCustom;
			if (isCustom) inp.focus();
		}, { once: true });
	});
}

/**
 * Refreshes step 4 labels.
 */
function renderStep4() {
	document.getElementById("s4-title").textContent = _t("onboarding.metrics.title");
	document.getElementById("s4-desc").textContent  = _t("onboarding.metrics.desc");
	document.getElementById("s4-warning").textContent = _t("dialog.metrics.enable_warning_formatted");
	document.getElementById("s4-yes-label").textContent = _t("onboarding.yes");
	document.getElementById("s4-no-label").textContent  = _t("onboarding.no");
	document.getElementById("s4-back").textContent = _t("onboarding.back");
	document.getElementById("s4-next").textContent = _t("onboarding.next");

	var radios = document.querySelectorAll("input[name='metrics']");
	radios.forEach(function (r) { r.checked = (r.value === (_answers.use_metrics ? "yes" : "no")); });
}

/**
 * Refreshes step 5 labels.
 */
function renderStep5() {
	document.getElementById("s5-title").textContent = _t("onboarding.gestures.title");
	document.getElementById("s5-desc").textContent  = _t("onboarding.gestures.desc");
	// Reuse the macOS-gestures-conflict warning shown by the tray "Enable
	// gestures" toggle — same orange box style as the metrics keylogger
	// warning on step 4. Tells the user that activating Ergopti gestures
	// requires disabling certain macOS native swipes/taps first.
	document.getElementById("s5-warning").textContent = _t("dialog.gestures.warning_msg");
	document.getElementById("s5-yes-label").textContent = _t("onboarding.yes");
	document.getElementById("s5-no-label").textContent  = _t("onboarding.no");
	document.getElementById("s5-back").textContent   = _t("onboarding.back");
	document.getElementById("s5-finish").textContent = _t("onboarding.finish");

	var radios = document.querySelectorAll("input[name='gestures']");
	radios.forEach(function (r) { r.checked = (r.value === (_answers.use_gestures ? "yes" : "no")); });
}


// ======================================
// ======================================
// ======= 6/ Lua bridge ================
// ======================================
// ======================================

/**
 * Posts a message to the Lua usercontent bridge.
 * @param {Object} msg
 */
function _post(msg) {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsOnboarding.postMessage(msg);
		} catch (e) {
			console.error("[onboarding] postMessage failed:", e);
		}
	}, 0);
}

/**
 * Called by Lua to inject translated strings for the selected locale.
 * After receiving strings we re-render the current step so labels update live.
 * @param {Object} strings - Flat key→value map from the locale JSON.
 */
window.applyStrings = function (strings) {
	_strings = strings || {};
	// Re-render the current step with the new strings
	if (_currentStep === 1) renderStep1();
	else if (_currentStep === "config") renderStepConfig();
	else if (_currentStep === 2) renderStep2();
	else if (_currentStep === 3) renderStep3();
	else if (_currentStep === 4) renderStep4();
	else if (_currentStep === 5) renderStep5();
	// Keep the window title in sync with the active locale on every step
	document.title = _t("onboarding.welcome.title");
};

/**
 * Called by Lua to provide the initial locale strings and pre-selected locale.
 * @param {Object} data - { locale: string, strings: Object }
 */
window.initData = function (data) {
	if (data && data.locale) _selectedLocale = data.locale;
	if (data && data.answers) _answers = Object.assign(_answers, data.answers);
	if (data && data.default_config_dir) window.DEFAULT_CONFIG_DIR = data.default_config_dir;
	// Locale list authored and sorted in lib/i18n.lua — override the
	// inline fallback so step 1 lists every supported locale in the
	// same order as the menubar language submenu.
	if (data && Array.isArray(data.locales) && data.locales.length > 0) {
		LOCALES = data.locales;
	}
	// System layout name (macOS) — used by step 3 to pre-select ù on
	// AZERTY-flavoured layouts and ; otherwise. Lua resolves it via
	// hs.keycodes.currentLayout().
	if (data && data.system_layout) window.SYSTEM_LAYOUT = data.system_layout;
	// Layout preview image URL (file:// URI to static/img/ergopti.jpg).
	// Optional — when absent step 2 renders without the visual cue.
	if (data && data.layout_image_url) window.LAYOUT_IMAGE_URL = data.layout_image_url;
	window.applyStrings(data && data.strings ? data.strings : {});
	renderStep1();
	showStep(1);
};

// Called by Lua after the native folder picker resolves. Fills the input
// + remembers the choice without leaving the config step.
window.setConfigDir = function (path) {
	if (typeof path !== "string" || path === "") return;
	var inp = document.getElementById("sc-input");
	if (inp) inp.value = path;
	_answers.config_dir = path;
};

// Called by Lua after parsing an existing config.toml at the chosen folder.
// Merges the saved answers into _answers and re-renders whichever step is
// currently on screen so the pre-fill becomes visible without a manual nav.
window.applyExistingAnswers = function (saved) {
	if (!saved || typeof saved !== "object") return;
	_answers = Object.assign(_answers, saved);
	// Re-render the active step so freshly-hydrated values show up. Subsequent
	// steps read _answers directly when first rendered (via renderStepN), so
	// only the current one needs an explicit refresh.
	if (_currentStep === 2)      renderStep2();
	else if (_currentStep === 3) renderStep3();
	else if (_currentStep === 4) renderStep4();
	else if (_currentStep === 5) renderStep5();
};


// ======================================
// ======================================
// ======= 7/ Event wiring ==============
// ======================================
// ======================================

// Step 1 → config
document.getElementById("s1-next").addEventListener("click", function () {
	_answers.locale = _selectedLocale;
	// Ask Lua to commit the locale selection in memory
	_post({ action: "localeSelected", locale: _selectedLocale });
	renderStepConfig();
	showStep("config");
});

// Config step ← →
document.getElementById("sc-back").addEventListener("click", function () {
	renderStep1();
	showStep(1);
});
document.getElementById("sc-next").addEventListener("click", function () {
	var val = (document.getElementById("sc-input").value || "").trim();
	_answers.config_dir = val;
	// Ask Lua to load any existing config.toml at the chosen folder so steps
	// 2-5 open pre-selected with the user's previous answers. The reply
	// arrives asynchronously via window.applyExistingAnswers(), which
	// re-renders the active step in place — so showing step 2 first is fine.
	_post({ action: "loadExistingConfig", config_dir: val });
	renderStep2();
	showStep(2);
});
// Browse → asks Lua to open the macOS native folder picker. Lua replies
// via window.setConfigDir(path) which fills the input back in.
document.getElementById("sc-browse").addEventListener("click", function () {
	_post({ action: "pickConfigDir", current: (document.getElementById("sc-input").value || "") });
});

// Step 2 ← →
document.getElementById("s2-back").addEventListener("click", function () {
	// Going back from layout returns to the inserted config step, not the
	// language step — keeps the wizard's forward sequence reversible.
	renderStepConfig();
	showStep("config");
});
document.getElementById("s2-next").addEventListener("click", function () {
	var checked = document.querySelector("input[name='layout']:checked");
	_answers.use_ergopti = checked ? checked.value === "yes" : true;
	renderStep3();
	showStep(3);
});

// Step 3 ← →
document.getElementById("s3-back").addEventListener("click", function () {
	renderStep2();
	showStep(2);
});
document.getElementById("s3-next").addEventListener("click", function () {
	// Read the value from the selected radio — the custom row carries
	// its own text input that wins when checked. Empty input on custom
	// row falls back to the Ergopti default so we never persist "".
	var checked = document.querySelector("input[name='magickey']:checked");
	var val;
	if (!checked) {
		val = _pickDefaultMagicKey();
	} else if (checked.value === "__custom__") {
		val = (document.getElementById("s3-input").value || "").trim();
		if (val === "") val = DEFAULT_MAGIC_KEY;
	} else {
		val = checked.value;
	}
	_answers.magic_key = val;
	renderStep4();
	showStep(4);
});

// Step 4 ← →
document.getElementById("s4-back").addEventListener("click", function () {
	renderStep3();
	showStep(3);
});
document.getElementById("s4-next").addEventListener("click", function () {
	var checked = document.querySelector("input[name='metrics']:checked");
	_answers.use_metrics = checked ? checked.value === "yes" : false;
	renderStep5();
	showStep(5);
});

// Step 5 ← finish
document.getElementById("s5-back").addEventListener("click", function () {
	renderStep4();
	showStep(4);
});
document.getElementById("s5-finish").addEventListener("click", function () {
	var checked = document.querySelector("input[name='gestures']:checked");
	_answers.use_gestures = checked ? checked.value === "yes" : false;
	_post({ action: "finish", answers: _answers });
});

// Signal Lua that the page is ready to receive initData
(function () {
	setTimeout(function () {
		try {
			window.webkit.messageHandlers.hsOnboarding.postMessage({ action: "ready" });
		} catch (e) {
			console.error("[onboarding] ready postMessage failed:", e);
		}
	}, 0);
}());
