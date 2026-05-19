// ui/onboarding/script.js

// =======================================
// =======================================
// ======= 1/ Locale definitions =========
// =======================================
// =======================================

// Ordered list of supported locales — kept in sync with lib/i18n.lua LOCALES table.
var LOCALES = [
	{ code: "ar", flag: "🇸🇦", name: "العربية"    },
	{ code: "cs", flag: "🇨🇿", name: "Čeština"    },
	{ code: "de", flag: "🇩🇪", name: "Deutsch"    },
	{ code: "en", flag: "🇬🇧", name: "English"    },
	{ code: "es", flag: "🇪🇸", name: "Español"    },
	{ code: "fr", flag: "🇫🇷", name: "Français"   },
	{ code: "it", flag: "🇮🇹", name: "Italiano"   },
	{ code: "ja", flag: "🇯🇵", name: "日本語"      },
	{ code: "ko", flag: "🇰🇷", name: "한국어"      },
	{ code: "nl", flag: "🇳🇱", name: "Nederlands"  },
	{ code: "pl", flag: "🇵🇱", name: "Polski"     },
	{ code: "pt", flag: "🇧🇷", name: "Português"  },
	{ code: "ru", flag: "🇷🇺", name: "Русский"    },
	{ code: "tr", flag: "🇹🇷", name: "Türkçe"     },
	{ code: "uk", flag: "🇺🇦", name: "Українська"  },
	{ code: "zh", flag: "🇨🇳", name: "中文"        },
];

// Default locale shown when no locale has been set yet
var DEFAULT_LOCALE_CODE = "en";

// Default magic key character — an asterisk is reachable on every keyboard
// without a dead key and is the documented "safe" fallback; the user can
// change it to ù, ; or any single character on step 3.
var DEFAULT_MAGIC_KEY = "*";


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

var _currentStep = 1;
var _selectedLocale = DEFAULT_LOCALE_CODE;
var _answers = {
	locale:       DEFAULT_LOCALE_CODE,
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
	for (var i = 1; i <= 5; i++) {
		var el = document.getElementById("step-" + i);
		if (el) el.classList.toggle("hidden", i !== n);

		var dot = document.getElementById("dot-" + i);
		if (dot) {
			dot.classList.remove("active", "done");
			if (i < n) dot.classList.add("done");
			else if (i === n) dot.classList.add("active");
		}
	}
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
 * Refreshes step 2 labels from the current _strings table.
 */
function renderStep2() {
	document.getElementById("s2-title").textContent = _t("onboarding.layout.title");
	document.getElementById("s2-desc").textContent  = _t("onboarding.layout.desc");
	document.getElementById("s2-yes-label").textContent = _t("onboarding.layout.yes");
	document.getElementById("s2-no-label").textContent  = _t("onboarding.layout.no");
	document.getElementById("s2-back").textContent = _t("onboarding.back");
	document.getElementById("s2-next").textContent = _t("onboarding.next");

	// Restore saved answer
	var radios = document.querySelectorAll("input[name='layout']");
	radios.forEach(function (r) { r.checked = (r.value === (_answers.use_ergopti ? "yes" : "no")); });
}

/**
 * Refreshes step 3 labels. The same hint is shown above the input (so the
 * defaults are visible before the user even thinks about typing) and below
 * (so the freedom-to-choose reminder closes the section).
 */
function renderStep3() {
	document.getElementById("s3-title").textContent     = _t("onboarding.magic_key.title");
	document.getElementById("s3-desc").textContent      = _t("onboarding.magic_key.desc");
	document.getElementById("s3-hint-top").textContent  = _t("onboarding.magic_key.hint");
	document.getElementById("s3-hint").textContent      = _t("onboarding.magic_key.choose_freely");
	document.getElementById("s3-back").textContent      = _t("onboarding.back");
	document.getElementById("s3-next").textContent      = _t("onboarding.next");

	var inp = document.getElementById("s3-input");
	inp.value = _answers.magic_key || DEFAULT_MAGIC_KEY;
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
	else if (_currentStep === 2) renderStep2();
	else if (_currentStep === 3) renderStep3();
	else if (_currentStep === 4) renderStep4();
	else if (_currentStep === 5) renderStep5();
};

/**
 * Called by Lua to provide the initial locale strings and pre-selected locale.
 * @param {Object} data - { locale: string, strings: Object }
 */
window.initData = function (data) {
	if (data && data.locale) _selectedLocale = data.locale;
	if (data && data.answers) _answers = Object.assign(_answers, data.answers);
	window.applyStrings(data && data.strings ? data.strings : {});
	renderStep1();
	showStep(1);
};


// ======================================
// ======================================
// ======= 7/ Event wiring ==============
// ======================================
// ======================================

// Step 1 → 2
document.getElementById("s1-next").addEventListener("click", function () {
	_answers.locale = _selectedLocale;
	// Ask Lua to commit the locale selection in memory
	_post({ action: "localeSelected", locale: _selectedLocale });
	renderStep2();
	showStep(2);
});

// Step 2 ← →
document.getElementById("s2-back").addEventListener("click", function () {
	renderStep1();
	showStep(1);
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
	var val = (document.getElementById("s3-input").value || "").trim();
	_answers.magic_key = val !== "" ? val : DEFAULT_MAGIC_KEY;
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
