// static/ergopti_plus/_shared/modules/tooltip/lifecycle.js

/**
 * ==============================================================================
 * MODULE: Tooltip Surface Lifecycle
 * DESCRIPTION:
 * Canonical show / hide / rebuild sequence for the Ergopti+ tooltip overlay.
 * Prevents transient visual defects (border-only ghosts, empty tinted rects,
 * content without border) by defining when each surface may become visible.
 *
 * DRIVER MAPPING:
 *   Hammerspoon — single hs.canvas; all elements are updated while hidden,
 *                 then canvas:show() once (already compliant).
 *   AutoHotkey    — two HWNDs (content Gui + layered border). MUST follow the
 *                 phases below; never Show() content before border is painted.
 *
 * PHASES (strict order):
 *
 *   1. TEARDOWN  — hide border, hide content, destroy both, sweep tracked HWNDs.
 *                  Used when dismissing the tooltip entirely.
 *
 *   2. SUSPEND   — hide border, hide content, keep HWNDs alive.
 *                  Used before an in-place rebuild (LLM streaming refresh,
 *                  dequeue destack) so the user never sees a lone border ring.
 *
 *   3. PREPARE   — build / measure / paint while surfaces are hidden:
 *                    a. content Gui.Show("Hide …") at final (x, y)
 *                    b. SetWindowRgn (rounded corners)
 *                    c. UpdateLayeredWindow on border (no ShowWindow yet)
 *
 *   4. REVEAL    — ShowWindow content + border in the same composition pass.
 *
 * INVARIANTS:
 *   - Never call REVEAL until PREPARE completed without error.
 *   - On PREPARE failure → TEARDOWN immediately (no ghost surfaces).
 *   - Border is always hidden before content during TEARDOWN / SUSPEND.
 *   - Dequeue destack rebuilds use SUSPEND → PREPARE → REVEAL (not TEARDOWN).
 * ==============================================================================
 */

'use strict';

/** @typedef {"teardown"|"suspend"|"prepare"|"reveal"} LifecyclePhase */

const PHASES = ['teardown', 'suspend', 'prepare', 'reveal'];

/**
 * Returns the ordered phase list drivers must implement.
 * @returns {LifecyclePhase[]}
 */
function lifecyclePhases() {
	return [...PHASES];
}

/**
 * Cross-driver lifecycle contract notes for documentation / codegen.
 * @returns {object[]}
 */
function lifecycleContract() {
	return [
		{
			id: 'teardown_border_first',
			description: 'TEARDOWN and SUSPEND always hide the border before the content surface.'
		},
		{
			id: 'prepare_while_hidden',
			description:
				'PREPARE keeps both surfaces hidden until border bitmap and content controls are ready.'
		},
		{
			id: 'reveal_atomic',
			description: 'REVEAL shows content and border together — never content alone on screen.'
		},
		{
			id: 'prepare_failure_teardown',
			description: 'Any PREPARE exception triggers TEARDOWN so no partial overlay lingers.'
		},
		{
			id: 'dequeue_suspend_not_teardown',
			description:
				'Stacked row expiry rebuilds use SUSPEND+PREPARE+REVEAL to avoid border-only flashes.'
		}
	];
}

module.exports = {
	PHASES,
	lifecyclePhases,
	lifecycleContract
};
