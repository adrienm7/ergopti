<!-- src/routes/ergopti-plus/LiveWpm.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Live MPM Widget Demo
DESCRIPTION:
A faithful, animated reproduction of the driver's native floating MPM widget
(kept native on the drivers for performance — this is a web-only demo). A
synthetic typing stream drives a real rolling-window MPM computation, so the
number and the moving bar chart spike exactly when a hotstring or an AI
suggestion injects several characters at once — the whole point of the metric.

FEATURES & RATIONALE:
1. Faithful style: the pill geometry and the source colours mirror
   _shared/modules/wpm_widget/constants.toml (manual blue, AI purple,
   hotstring = the family colour), so the demo reads as the real widget.
2. Real computation, not a fake needle: MPM is (chars / 5) over a sliding
   window, so bursts from expansions produce genuine, proportional jumps.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';

	// ── Widget canon, mirrored from _shared/modules/wpm_widget/constants.toml ──
	/** Blue background for manual keystrokes. */
	const COLOR_MANUAL = '#0055cc';
	/** Purple background for AI-generated keystrokes. */
	const COLOR_AI = '#7a30b0';

	// ── Simulation tuning ──────────────────────────────────────────────────
	/** Director tick — also the per-character cadence for manual typing (ms). */
	const TICK_MS = 130;
	/** Rolling window over which MPM is averaged (ms). */
	const WINDOW_MS = 4000;
	/** How long a hotstring/AI accent colour + tag stays lit after a burst (ms). */
	const FLASH_MS = 950;
	/** Pause after an instant expansion before typing resumes (ticks). */
	const BURST_PAUSE_TICKS = 4;
	/** MPM easing factor per tick toward the rolling-window target. */
	const EASE = 0.28;

	// A repeating script: manual runs typed char-by-char, burst chunks (a
	// hotstring expansion or an AI acceptance) appear at once and spike the MPM.
	const SEGMENTS = [
		{ kind: 'manual', text: 'Bonjour Madame, je vous écris pour ' },
		{ kind: 'burst', source: 'hotstring', color: '#e53935', tag: '★ Touche magique', text: 'par exemple ' },
		{ kind: 'manual', text: 'convenir d’un ' },
		{ kind: 'burst', source: 'hotstring', color: '#1e88e5', tag: '★ Roulement', text: 'rendez-vous ' },
		{ kind: 'manual', text: 'la semaine ' },
		{ kind: 'burst', source: 'ai', color: COLOR_AI, tag: '✨ IA — suite acceptée', text: 'prochaine, si vos disponibilités le permettent.' }
	];

	let typed = $state('');
	let mpm = $state(0);
	let pillColor = $state(COLOR_MANUAL);
	let flashTag = $state('');
	/** @type {number[]} Recent MPM samples driving the moving bar strip. */
	let bars = $state(Array(28).fill(0));

	onMount(() => {
		// Rolling window of character-insertion events: {t, n}.
		/** @type {{t: number, n: number}[]} */
		let events = [];
		let segIndex = 0;
		let charIndex = 0;
		let pauseTicks = 0;
		let flashUntil = 0;

		const step = () => {
			const now = performance.now();

			if (pauseTicks > 0) {
				pauseTicks--;
			} else {
				const seg = SEGMENTS[segIndex];
				if (seg.kind === 'manual') {
					typed += seg.text[charIndex];
					events.push({ t: now, n: 1 });
					charIndex++;
					if (charIndex >= seg.text.length) {
						segIndex = (segIndex + 1) % SEGMENTS.length;
						charIndex = 0;
						if (segIndex === 0) typed = ''; // loop: clear the field
					}
				} else {
					// Burst: the whole expansion lands at once → a real MPM jump.
					typed += seg.text;
					events.push({ t: now, n: seg.text.length });
					pillColor = seg.color;
					flashTag = seg.tag;
					flashUntil = now + FLASH_MS;
					pauseTicks = BURST_PAUSE_TICKS;
					segIndex = (segIndex + 1) % SEGMENTS.length;
					charIndex = 0;
					if (segIndex === 0) {
						// A burst can be the last segment; clear on the next tick's loop.
						setTimeout(() => (typed = ''), FLASH_MS);
					}
				}
			}

			// Expire the flash accent back to manual blue.
			if (flashUntil && now > flashUntil) {
				pillColor = COLOR_MANUAL;
				flashTag = '';
				flashUntil = 0;
			}

			// Rolling-window MPM: characters / 5 over the window, per minute.
			events = events.filter((e) => now - e.t <= WINDOW_MS);
			const chars = events.reduce((s, e) => s + e.n, 0);
			const target = Math.round((chars / 5) * (60000 / WINDOW_MS));
			mpm = Math.round(mpm + (target - mpm) * EASE);

			bars = [...bars.slice(1), mpm];
		};

		const timer = setInterval(step, TICK_MS);
		return () => clearInterval(timer);
	});

	// Bar heights are normalised to the tallest recent sample so the strip
	// always uses its full height as the values drift.
	let barMax = $derived(Math.max(60, ...bars));
</script>

<div class="live">
	<div class="live-editor ep-window os-macos">
		<div class="le-chrome">
			<span class="dot"></span><span class="dot"></span><span class="dot"></span>
			<span class="le-title">~/courriel/brouillon.txt</span>
		</div>
		<div class="le-body">
			<span class="le-text">{typed}</span><span class="le-caret"></span>
			{#if flashTag}
				<span class="le-tag" style="--tag: {pillColor};">{flashTag}</span>
			{/if}
		</div>
	</div>

	<div class="live-widget" aria-label="Widget MPM en direct">
		<!-- The pill: big number over a darkened unit strip, exactly like the
		     native widget. Background colour tracks the active typing source. -->
		<div class="pill" style="--pill: {pillColor};">
			<div class="pill-num">{mpm}</div>
			<div class="pill-unit">MPM</div>
		</div>
		<div class="bars" aria-hidden="true">
			{#each bars as v}
				<span class="bar" style="height: {Math.max(4, (v / barMax) * 100)}%;"></span>
			{/each}
		</div>
		<p class="live-hint">Les pics correspondent aux hotstrings et aux acceptations d’IA.</p>
	</div>
</div>

<style>
	.live {
		align-items: stretch;
		display: grid;
		gap: 18px;
		grid-template-columns: 1fr auto;
		margin: 0 auto;
		max-width: 720px;
	}

	/* ─── Text field ────────────────────────────────────────── */

	.live-editor {
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	.le-chrome {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border-bottom: 1px solid var(--border);
		display: flex;
		gap: 6px;
		padding: 9px 12px;
	}

	.le-chrome .dot {
		background: rgba(255, 255, 255, 0.25);
		border-radius: 50%;
		height: 10px;
		width: 10px;
	}

	.le-title {
		color: var(--ink-faint);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.72rem;
		margin-left: 8px;
	}

	.le-body {
		flex: 1;
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 1.02rem;
		line-height: 1.7;
		min-height: 132px;
		padding: 18px 20px;
		position: relative;
	}

	.le-text {
		color: var(--ink);
	}

	.le-caret {
		animation: blink 1.1s steps(1) infinite;
		background: var(--accent-cyan, #02c9db);
		display: inline-block;
		height: 1.05em;
		margin-left: 1px;
		vertical-align: -0.18em;
		width: 2px;
	}

	@keyframes blink {
		50% {
			opacity: 0;
		}
	}

	.le-tag {
		animation: tagpop 0.2s var(--ease-out, ease-out);
		background: color-mix(in srgb, var(--tag) 22%, #0c1018);
		border: 1px solid var(--tag);
		border-radius: 7px;
		color: #fff;
		font-size: 0.7rem;
		font-weight: 700;
		margin-left: 10px;
		padding: 2px 8px;
		white-space: nowrap;
	}

	@keyframes tagpop {
		from {
			opacity: 0;
			transform: translateY(4px);
		}
	}

	/* ─── Live pill widget (mirrors the native driver widget) ── */

	.live-widget {
		align-items: center;
		display: flex;
		flex-direction: column;
		gap: 12px;
		justify-content: center;
		width: 118px;
	}

	.pill {
		background: var(--pill);
		border-radius: 14px;
		box-shadow: 0 10px 30px -8px color-mix(in srgb, var(--pill) 60%, transparent);
		overflow: hidden;
		text-align: center;
		transition:
			background-color 0.35s var(--ease, ease),
			box-shadow 0.35s var(--ease, ease);
		width: 96px;
	}

	.pill-num {
		color: #fff;
		font-size: 2.2rem;
		font-variant-numeric: tabular-nums;
		font-weight: 800;
		line-height: 1;
		padding: 14px 0 10px;
	}

	.pill-unit {
		/* The darkened lower strip, per unit_strip_darken_factor = 0.40 */
		background: rgba(0, 0, 0, 0.4);
		color: rgba(255, 255, 255, 0.85);
		font-size: 0.62rem;
		font-weight: 700;
		letter-spacing: 0.14em;
		padding: 4px 0;
	}

	.bars {
		align-items: flex-end;
		display: flex;
		gap: 2px;
		height: 46px;
		width: 100%;
	}

	.bar {
		background: linear-gradient(180deg, var(--accent-cyan, #02c9db), rgba(2, 201, 219, 0.35));
		border-radius: 1px;
		flex: 1;
		min-height: 4px;
		transition: height 0.13s linear;
	}

	.live-hint {
		color: var(--ink-faint);
		font-size: 0.72rem;
		line-height: 1.4;
		margin: 0;
		text-align: center;
	}

	@media (max-width: 620px) {
		.live {
			grid-template-columns: 1fr;
		}

		.live-widget {
			flex-direction: row;
			width: 100%;
		}

		.bars {
			flex: 1;
		}
	}
</style>
