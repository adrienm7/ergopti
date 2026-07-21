<!-- src/routes/ergopti-plus/LiveSession.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Live Session Demo
DESCRIPTION:
Animated "real sentence" block: a full paragraph is typed with several
expansions firing along the way, each previewed by the driver-style tooltip
inline at the caret. Rendered as a sub-block of the Hotstrings section.

FEATURES & RATIONALE:
1. Context Beats Isolation: isolated "sx → sk" rows undersell the flow;
   watching a sentence assemble itself is the actual product experience.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import WindowChrome from './WindowChrome.svelte';
	import { ui } from './state.svelte.js';

	/** Base per-character delay for literal text (jittered for realism). */
	const LITERAL_CHAR_MS = 28;
	/** Per-character delay while typing a hotstring prefix. */
	const HOTSTRING_CHAR_MS = 50;
	/** Tooltip preview duration before the expansion replaces the prefix. */
	const TOOLTIP_HOLD_MS = 600;
	/** Pause after an expansion fires. */
	const POST_EXPANSION_MS = 250;
	/** Pause before the session restarts from scratch. */
	const RESTART_DELAY_MS = 4000;

	// Pre-recorded session: literal tokens are typed verbatim; hotstring
	// tokens type a prefix, show the tooltip, then swap in the expansion.
	// Colors mirror the driver's real family tints.
	const session = [
		{ type: 'lit', text: 'Bonjour, ' },
		{ type: 'hot', pre: 'jusqu', post: 'jusqu’', color: '#43a047', group: 'Auto' },
		{ type: 'lit', text: 'à hier ' },
		{ type: 'hot', pre: 'pex★', post: 'par exemple', color: '#e53935', group: 'Magique' },
		{ type: 'lit', text: ', je signais encore mes mails « ' },
		{ type: 'hot', pre: 'np★', post: 'Adrien Moyaux', color: '#8e8e93', group: 'Perso' },
		{ type: 'lit', text: ' » à la main. ' },
		{ type: 'hot', pre: 'ct★', post: 'c’était', color: '#e53935', group: 'Magique' },
		{ type: 'lit', text: ' fastidieux et ' },
		{ type: 'hot', pre: ',t', post: 'pt', color: '#1e88e5', group: 'SFB' },
		{ type: 'lit', text: 'imal pour les doigts.' }
	];

	let sessionText = $state('');
	let sessionTooltip = $state(null);
	let sessionTimer;

	/** Run the full session animation, then loop. */
	function runSession() {
		sessionText = '';
		sessionTooltip = null;
		let tIdx = 0;
		let cIdx = 0;
		let pendingTooltip = false;

		function step() {
			if (tIdx >= session.length) {
				sessionTimer = setTimeout(runSession, RESTART_DELAY_MS);
				return;
			}
			const tok = session[tIdx];
			if (tok.type === 'lit') {
				if (cIdx < tok.text.length) {
					sessionText += tok.text[cIdx];
					cIdx++;
					sessionTimer = setTimeout(step, LITERAL_CHAR_MS + Math.random() * 30);
				} else {
					tIdx++;
					cIdx = 0;
					sessionTimer = setTimeout(step, 60);
				}
			} else {
				if (cIdx < tok.pre.length) {
					sessionText += tok.pre[cIdx];
					cIdx++;
					sessionTimer = setTimeout(step, HOTSTRING_CHAR_MS);
					return;
				}
				if (!pendingTooltip) {
					pendingTooltip = true;
					sessionTooltip = { text: tok.post, color: tok.color, group: tok.group };
					sessionTimer = setTimeout(step, TOOLTIP_HOLD_MS);
					return;
				}
				// Swap the typed prefix for the expansion in-place.
				sessionText = sessionText.slice(0, sessionText.length - tok.pre.length) + tok.post;
				sessionTooltip = null;
				pendingTooltip = false;
				tIdx++;
				cIdx = 0;
				sessionTimer = setTimeout(step, POST_EXPANSION_MS);
			}
		}
		step();
	}

	onMount(() => {
		runSession();
		return () => clearTimeout(sessionTimer);
	});
</script>

<div class="session-block">
	<div class="session-window ep-window os-{ui.osStyle}">
		<WindowChrome title="message.txt" />
		<div class="session-body">
			<p class="session-line">
				{sessionText}<span class="caret"></span>{#if sessionTooltip}<span
						class="session-tooltip"
						style="--tt: {sessionTooltip.color};"
					>
						<span class="tt-text">{sessionTooltip.text}</span>
						<span class="tt-tag">{sessionTooltip.group}</span>
					</span>{/if}
			</p>
		</div>
	</div>
	<p class="session-caption">
		Expansion en temps réel — une vraie phrase, plusieurs familles d’expansions, sans jamais rompre
		le flux de frappe.
	</p>
</div>

<style>
	.session-block {
		margin: 0 auto clamp(32px, 5vw, 52px);
		max-width: 880px;
	}

	.session-body {
		min-height: 150px;
		padding: 24px 26px 28px;
		position: relative;
	}

	.session-line {
		color: var(--ink);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: clamp(0.95rem, 1.6vw, 1.15rem);
		line-height: 1.75;
		margin: 0;
		text-align: left;
	}

	.session-caption {
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin: 12px 0 0;
		text-align: center;
	}

	/* Inline in the text flow, right of the caret — mirrors the driver's
	 * real tooltip position and can never be clipped by the window edge */
	.session-tooltip {
		align-items: center;
		animation: tooltip-pop 0.22s var(--ease-out);
		background: rgba(12, 16, 28, 0.97);
		border: 1.5px solid var(--tt);
		border-radius: 7px;
		box-shadow: 0 6px 22px -6px color-mix(in srgb, var(--tt) 55%, transparent);
		display: inline-flex;
		gap: 8px;
		margin-left: 10px;
		max-width: 100%;
		padding: 2px 9px;
		vertical-align: middle;
	}

	@keyframes tooltip-pop {
		from {
			opacity: 0;
			transform: translateX(-6px) scale(0.96);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.tt-text {
		color: var(--tt);
		font-size: 0.85rem;
		font-weight: 700;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.tt-tag {
		background: color-mix(in srgb, var(--tt) 18%, transparent);
		border-radius: 999px;
		color: color-mix(in srgb, var(--tt) 70%, #fff);
		flex-shrink: 0;
		font-size: 0.65rem;
		font-weight: 700;
		letter-spacing: 0.05em;
		padding: 3px 8px;
		text-transform: uppercase;
	}
</style>
