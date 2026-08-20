// _shared/core/ports/HotkeyRegistrar.spec.js

/**
 * ==============================================================================
 * PORT: HotkeyRegistrar
 * DESCRIPTION:
 * Contract for registering a system-wide keyboard chord against a callback. None
 * of the twenty ports that preceded this one had a "bind a chord to a callback"
 * operation, which is precisely why every driver invented its own: the macOS
 * driver called hs.hotkey.bind from three different modules, and the Windows
 * driver called Hotkey() straight out of the keymap layer. Both are OS calls
 * living outside adapters/, which is the one thing the port layer exists to stop.
 *
 * The chord itself is NOT part of this contract's vocabulary beyond being a
 * canonical string: what a chord IS belongs to the shared notation core
 * (_shared/lua/chord/init.lua and its AutoHotkey twin windows/infra/chord.ahk).
 * This port only says what a driver must be able to DO with one.
 *
 * FEATURES & RATIONALE:
 * 1. Opaque handles: bind() returns a handle the caller stores and passes back.
 *    Its type is deliberately unspecified — hs.hotkey returns an object with
 *    methods, AutoHotkey has no object at all and needs the chord string kept.
 *    Specifying the type would force one driver to fake the other's shape, which
 *    is the mistake Clipboard.save() made before it was corrected.
 * 2. unbind() is idempotent: unbinding twice, or unbinding a handle from a
 *    previous session, must report false rather than throw. Teardown paths run
 *    defensively and a raise there takes the whole reload with it.
 * 3. setEnabled() rather than enable()/disable(): the caller almost always has
 *    the desired state as a boolean already (a menu checkbox, a config field),
 *    and a two-method form invites `if on then enable() else disable() end` at
 *    every call site.
 * 4. Binding failure is a RETURN, not a throw. A chord the OS refuses (already
 *    claimed by another application, unknown key name) is an ordinary outcome the
 *    caller must be able to report to the user; it is not an exception.
 * ==============================================================================
 */

'use strict';

// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The HotkeyRegistrar port contract.
 * @type {object}
 */
const portContract = {
	name: 'HotkeyRegistrar',
	version: '1.0.0',

	/**
	 * bind(chord, callback) — Register a system-wide chord.
	 *   @param {string} chord      Canonical chord string, e.g. "Ctrl+Shift+S".
	 *          Accepted spellings are whatever the shared chord core parses; the
	 *          adapter MUST canonicalise before touching the OS so that two
	 *          spellings of one chord cannot produce two live bindings.
	 *   @param {Function} callback Invoked with no arguments on each press.
	 *   @returns {*|null} An opaque handle, or null when the OS refused the bind.
	 *   @error_behavior "return_null" — a refused chord is an outcome, not a throw.
	 *
	 * unbind(handle) — Release a binding.
	 *   @param {*} handle A handle previously returned by bind().
	 *   @returns {boolean} true if a live binding was released, false otherwise.
	 *   @error_behavior "return_false" — idempotent; unknown handles are not errors.
	 *
	 * setEnabled(handle, enabled) — Suspend or resume a binding without releasing it.
	 *   @param {*} handle A handle previously returned by bind().
	 *   @param {boolean} enabled Desired state.
	 *   @returns {boolean} true if the handle now holds the requested state.
	 *   @error_behavior "return_false" — unknown handles are not errors.
	 */
	methods: {
		bind: { arity: 2, required: true },
		unbind: { arity: 1, required: true },
		setEnabled: { arity: 2, required: true }
	}
};

// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a HotkeyRegistrar adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== 'object') {
		return ['adapter must be a non-null object'];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== 'function') {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}

// ==================================================
// ==================================================
// ======= 3/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for HotkeyRegistrar compliance.
 * Harnesses stub the OS binding API and assert what was registered.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: 'bind_returns_handle',
			description: 'bind() with a valid chord returns a non-null handle.',
			input: { chord: 'Ctrl+Shift+S' },
			assert: { handle_not_null: true }
		},
		{
			id: 'bind_canonicalises_chord',
			description:
				'Two spellings of one chord produce one canonical registration, so the OS never sees the caller\'s spelling.',
			input: { chord: 'shift+ctrl+s' },
			assert: { registered_chord: 'Ctrl+Shift+S' }
		},
		{
			id: 'bind_invalid_chord_returns_null',
			description: 'A chord the notation core rejects returns null without reaching the OS.',
			input: { chord: 'Ctrl+Shift' },
			assert: { handle_null: true, os_untouched: true }
		},
		{
			id: 'bind_os_refusal_returns_null',
			description: 'When the OS refuses the bind, bind() returns null rather than throwing.',
			stub: { os_refuses: true },
			input: { chord: 'Ctrl+Alt+Q' },
			assert: { handle_null: true, no_exception: true }
		},
		{
			id: 'callback_invoked_on_press',
			description: 'The registered callback runs when the chord fires.',
			input: { chord: 'Ctrl+T', press: true },
			assert: { callback_invoked: true }
		},
		{
			id: 'unbind_releases',
			description: 'unbind() on a live handle reports true and releases the OS binding.',
			input: { chord: 'Ctrl+T' },
			assert: { unbind_result: true, os_released: true }
		},
		{
			id: 'unbind_is_idempotent',
			description: 'A second unbind() of the same handle reports false and does not throw.',
			input: { chord: 'Ctrl+T', unbind_twice: true },
			assert: { second_unbind_result: false, no_exception: true }
		},
		{
			id: 'unbind_unknown_handle',
			description: 'unbind() of a handle this registrar never issued reports false, not an error.',
			input: { unknown_handle: true },
			assert: { unbind_result: false, no_exception: true }
		},
		{
			id: 'set_enabled_false_suspends',
			description: 'setEnabled(handle, false) stops the callback firing without releasing the handle.',
			input: { chord: 'Ctrl+T', enabled: false, press: true },
			assert: { callback_invoked: false, handle_still_known: true }
		},
		{
			id: 'set_enabled_true_resumes',
			description: 'setEnabled(handle, true) after a suspend restores delivery.',
			input: { chord: 'Ctrl+T', enabled: false, then_enabled: true, press: true },
			assert: { callback_invoked: true }
		},
		{
			id: 'set_enabled_unknown_handle',
			description: 'setEnabled() on an unknown handle reports false rather than throwing.',
			input: { unknown_handle: true, enabled: true },
			assert: { set_enabled_result: false, no_exception: true }
		}
	];
}

module.exports = { portContract, validateAdapter, contractTestVectors };
