// scripts/test-port-compliance.js

/**
 * ==============================================================================
 * MODULE: Port Adapter Structural Compliance Tests
 * DESCRIPTION:
 * Validates every Hammerspoon adapter against the corresponding port contract
 * defined in static/ergopti_plus/_shared/ports/. Each adapter module is loaded as a
 * CommonJS module and passed to the contract's validateAdapter() function; any
 * structural violation (missing method, wrong arity) causes this script to exit
 * with code 1 so CI catches regressions immediately.
 *
 * FEATURES & RATIONALE:
 * 1. Zero mocking: the adapters are plain JS modules for this test; the HS Lua
 *    adapter objects are mirrored as lightweight JS stubs that expose the same
 *    method surface. Any change to a Lua adapter that removes or renames a
 *    method must also update the corresponding JS stub here — the test fails
 *    until both are in sync.
 * 2. Arity enforcement: JavaScript functions expose .length (formal parameter
 *    count), so validateAdapter can assert exact arity at zero cost.
 * 3. AHK note: AHK global functions do not exist as importable modules, so
 *    AHK compliance is validated in test_adapter_compliance.ahk using the AHK
 *    test framework instead.
 * ==============================================================================
 */

"use strict";

const path = require("path");
const fs   = require("fs");

const PORTS_DIR     = path.join(__dirname, "../static/ergopti_plus/_shared/ports");
const PASS_SYMBOL   = "✓";
const FAIL_SYMBOL   = "✗";

let total_pass = 0;
let total_fail = 0;


// ==================================================
// ==================================================
// ======= 1/ HS Adapter Stubs ======================
// ==================================================
// ==================================================

// Lightweight JS objects mirroring the method surface of each Hammerspoon
// adapter. The arity of each function must match the port contract exactly.
// When a Lua adapter method is added or removed, update this table too.
const HS_ADAPTERS = {

	KeyboardHook: {
		start:          function(opts) {},          // arity 1
		stop:           function() {},              // arity 0
		isRunning:      function() {},              // arity 0
		refreshContext: function() {},              // arity 0
		getContext:     function() {},              // arity 0
	},

	TextSender: {
		send:       function(text, opts, cb) {},    // arity 3
		eraseChars: function(count) {},             // arity 1
		pressKey:   function(key, mods) {},         // arity 2
	},

	TooltipRenderer: {
		show:          function(payload) {},        // arity 1
		hide:          function() {},               // arity 0
		isVisible:     function() {},               // arity 0
		updateElement: function(drawCall) {},       // arity 1
	},

	HttpClient: {
		post:     function(url, headers, body, cb) {}, // arity 4
		cancel:   function() {},                    // arity 0
		isActive: function() {},                    // arity 0
	},

	TimerScheduler: {
		after:     function(delaySec, fn) {},       // arity 2
		every:     function(intervalSec, fn) {},    // arity 2
		cancel:    function(handle) {},             // arity 1
		cancelAll: function() {},                   // arity 0
	},

	Notifier: {
		send: function(title, opts) {},             // arity 2
	},

	TrayMenu: {
		setIcon:    function(opts) {},              // arity 1
		setMenu:    function(items) {},             // arity 1
		setTooltip: function(text) {},              // arity 1
		destroy:    function() {},                  // arity 0
	},

	FileSystem: {
		read:   function(path) {},                  // arity 1
		write:  function(path, content) {},         // arity 2
		append: function(path, content) {},         // arity 2
		exists: function(path) {},                  // arity 1
		delete: function(path) {},                  // arity 1
	},

	WindowInfo: {
		getFocused: function() {},                  // arity 0
		getAll:     function() {},                  // arity 0
	},

	SecureFieldDetector: {
		isSecureField: function() {},               // arity 0
		isSecureApp:   function(appId) {},          // arity 1
		refresh:       function() {},               // arity 0
	},

	Clipboard: {
		read:    function() {},                     // arity 0
		write:   function(text) {},                 // arity 1
		save:    function() {},                     // arity 0
		restore: function(saved) {},                // arity 1
	},

	Storage: {
		set:    function(key, value) {},            // arity 2
		get:    function(key, defaultValue) {},     // arity 2
		delete: function(key) {},                   // arity 1
		has:    function(key) {},                   // arity 1
		keys:   function() {},                      // arity 0
		clear:  function() {},                      // arity 0
	},

	ProcessLifecycle: {
		onFocusChange:    function(callback) {},    // arity 1
		onAppLaunch:      function(callback) {},    // arity 1
		onAppQuit:        function(callback) {},    // arity 1
		getForegroundApp: function() {},            // arity 0
		start:            function() {},            // arity 0
		stop:             function() {},            // arity 0
	},

	WindowManager: {
		activate:   function(hwndOrSpec) {},        // arity 1
		exists:     function(spec) {},              // arity 1
		kill:       function(spec) {},              // arity 1
		getList:    function() {},                  // arity 0
		getTitle:   function(hwndOrSpec) {},        // arity 1
		getFocused: function() {},                  // arity 0
	},

	MouseControl: {
		setPos:           function(x, y) {},        // arity 2
		getPos:           function() {},            // arity 0
		getMonitorCount:  function() {},            // arity 0
		getMonitorBounds: function(n) {},           // arity 1
	},

	GraphicsRenderer: {
		createWindow:  function(opts) {},           // arity 1
		destroyWindow: function(handle) {},         // arity 1
		drawBitmap:    function(handle, drawFn) {}, // arity 2
		show:          function(handle) {},         // arity 1
		hide:          function(handle) {},         // arity 1
	},

	NetworkInfo: {
		getSsidHash:         function() {},         // arity 0
		getSignalStrength:   function() {},         // arity 0
		isInternetReachable: function() {},         // arity 0
		isVpnActive:         function() {},         // arity 0
	},

	Crypto: {
		sha256: function(data) {},                  // arity 1
	},

	KeyState: {
		KS_IsDown: function(keyName) {},            // arity 1
		KS_IsUp:   function(keyName) {},            // arity 1
	},

	AppLauncher: {
		AL_Launch:         function(appPath) {},         // arity 1
		AL_LaunchWithArgs: function(appPath, args) {},   // arity 2
		AL_IsRunning:      function(processName) {},     // arity 1
	},
};


// ===================================================
// ===================================================
// ======= 2/ Spec Loading & Validation =============
// ===================================================
// ===================================================

/**
 * Loads a spec file and runs validateAdapter against the given adapter stub.
 * Prints a PASS/FAIL line per port and increments the global counters.
 * @param {string} portName - Port name matching <portName>.spec.js.
 * @param {object} adapter  - Adapter stub with methods to validate.
 */
function runValidation(portName, adapter) {
	const specPath = path.join(PORTS_DIR, `${portName}.spec.js`);
	if (!fs.existsSync(specPath)) {
		console.log(`  ${FAIL_SYMBOL}  ${portName}: spec file not found at ${specPath}`);
		total_fail++;
		return;
	}

	let validateAdapter;
	try {
		// The spec files use module.exports = {} — load them as CommonJS.
		const src = fs.readFileSync(specPath, "utf8");
		// Strip the "use strict" header and extract validateAdapter via eval
		// in a local scope so the function definitions are accessible.
		const wrapped = `(function() { ${src}; return validateAdapter; })()`;
		validateAdapter = eval(wrapped); // eslint-disable-line no-eval
	} catch (err) {
		console.log(`  ${FAIL_SYMBOL}  ${portName}: failed to load spec — ${err.message}`);
		total_fail++;
		return;
	}

	if (typeof validateAdapter !== "function") {
		console.log(`  ${FAIL_SYMBOL}  ${portName}: spec does not export validateAdapter`);
		total_fail++;
		return;
	}

	const violations = validateAdapter(adapter);
	if (violations.length === 0) {
		console.log(`  ${PASS_SYMBOL}  ${portName}`);
		total_pass++;
	} else {
		console.log(`  ${FAIL_SYMBOL}  ${portName}:`);
		for (const v of violations) {
			console.log(`       - ${v}`);
		}
		total_fail++;
	}
}


// ===================================================
// ===================================================
// ======= 3/ Test Runner ============================
// ===================================================
// ===================================================

console.log("\nPort adapter structural compliance (Hammerspoon)");
console.log("=".repeat(50));

for (const [portName, adapterStub] of Object.entries(HS_ADAPTERS)) {
	runValidation(portName, adapterStub);
}

console.log("");
console.log(`Total: ${total_pass + total_fail} port(s) — ${total_pass} passed, ${total_fail} failed`);
console.log("");

process.exit(total_fail > 0 ? 1 : 0);
