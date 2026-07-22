<!-- src/routes/ergopti-plus/Hero.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Hero
DESCRIPTION:
Above-the-fold section: OS chrome toggle, headline, live typing demo (real
expansions from the shipped TOMLs, with the tooltip preview the driver shows)
and the download call-to-action.

FEATURES & RATIONALE:
1. Live Demo First: showing an expansion firing beats any paragraph — the
   demo cycles through the real hotstring families with their real colors.
2. OS-Aware: the chrome toggle drives every mock window on the page and the
   primary download button, so a Mac visitor sees a Mac page instantly.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { fly } from 'svelte/transition';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import WindowChrome from './WindowChrome.svelte';
	import { ui, setOS } from './state.svelte.js';
	import { t } from './i18n.svelte.js';

	/** Milliseconds between two typed characters in the demo. */
	const TYPE_INTERVAL_MS = 110;
	/** How long the tooltip preview stays visible before the expansion fires. */
	const TOOLTIP_HOLD_MS = 900;
	/** How long the expanded result stays on screen before the next demo. */
	const RESULT_HOLD_MS = 1600;

	// Live typing demo — real expansions from the hotstring TOMLs. Each entry
	// carries the typed prefix, the expanded result, the family label and the
	// same hex tint the driver's tooltip uses for that family.
	const demos = [
		{ input: 'ct★', output: 'c’était', group: 'Touche magique', color: '#e53935' },
		{ input: 'qa', output: 'qua', group: 'Roulements', color: '#1e88e5' },
		{ input: 'taiwan', output: 'Taïwan', group: 'Autocorrection', color: '#43a047' },
		{ input: 'np★', output: 'Adrien Moyaux', group: 'Hotstrings perso', color: '#8e8e93' },
		{ input: ',t', output: 'pt', group: 'Réduction SFBs', color: '#1e88e5' },
		{ input: 'jusqu', output: 'jusqu’', group: 'Autocorrection', color: '#43a047' },
		{ input: 'pex★', output: 'par exemple', group: 'Touche magique', color: '#e53935' },
		{ input: 'sx', output: 'sk', group: 'Roulements', color: '#1e88e5' }
	];

	let demoIndex = $state(0);
	let typed = $state('');
	let phase = $state('typing');
	let demoStepTimer;
	// Generation counter — incremented on every runCycle / goToDemo call so a
	// pending setTimeout from the previous cycle bails out the moment it fires.
	let cycleGen = 0;

	/**
	 * Advance the typing animation one character, then hand over to the
	 * tooltip → expansion → next-demo chain.
	 * @param {{input: string, output: string}} d
	 * @param {number} i
	 * @param {number} gen
	 */
	function runDemoStep(d, i, gen) {
		if (gen !== cycleGen) return;
		if (i < d.input.length) {
			typed = d.input.slice(0, i + 1);
			demoStepTimer = setTimeout(() => runDemoStep(d, i + 1, gen), TYPE_INTERVAL_MS);
			return;
		}
		phase = 'tooltip';
		demoStepTimer = setTimeout(() => {
			if (gen !== cycleGen) return;
			phase = 'expanded';
			typed = d.output;
			demoStepTimer = setTimeout(() => {
				if (gen !== cycleGen) return;
				demoIndex = (demoIndex + 1) % demos.length;
				runCycle();
			}, RESULT_HOLD_MS);
		}, TOOLTIP_HOLD_MS);
	}

	/** Start (or restart) the current demo from an empty buffer. */
	function runCycle() {
		cycleGen++;
		const gen = cycleGen;
		typed = '';
		phase = 'typing';
		demoStepTimer = setTimeout(() => runDemoStep(demos[demoIndex], 0, gen), 50);
	}

	/**
	 * Jump to a specific demo from the pager chips.
	 * @param {number} i
	 */
	function goToDemo(i) {
		clearTimeout(demoStepTimer);
		demoIndex = i;
		runCycle();
	}

	onMount(() => {
		runCycle();
		return () => clearTimeout(demoStepTimer);
	});

	// Active index for the sliding toggle indicator (windows → macos → linux).
	let osIndex = $derived(ui.osStyle === 'windows' ? 0 : ui.osStyle === 'macos' ? 1 : 2);

	let urlWindows = $derived(ui.release?.url('ErgoptiPlus.exe') ?? '#');
	let urlMacos = $derived(ui.release?.url('ErgoptiPlus.app.zip') ?? '#');
	let urlKanata = $derived(ui.release?.url('kanata.kbd') ?? '#');

	// A single download button, driven by the OS toggle. The previous layout
	// showed a second *download* button for a different OS — so picking Linux
	// still surfaced a "Windows" button, which read as a bug. The secondary
	// action is now a neutral, always-relevant in-page jump instead.
	let primaryDownload = $derived(
		ui.osStyle === 'macos'
			? { url: urlMacos, icon: 'icon-appleinc', label: t('Télécharger pour macOS') }
			: ui.osStyle === 'linux'
				? { url: urlKanata, icon: 'icon-linux', label: t('Télécharger pour Linux (alpha)') }
				: { url: urlWindows, icon: 'icon-windows', label: t('Télécharger pour Windows') }
	);
</script>

<section class="hero" id="ep-demo">
	<div class="hero-glow" aria-hidden="true"></div>
	<div class="ep-wrap">
		<div class="os-toggle" role="group" aria-label="Style des fenêtres">
			<span class="os-slider" style="--i: {osIndex};" aria-hidden="true"></span>
			<button
				type="button"
				class={ui.osStyle === 'windows' ? 'os-btn active' : 'os-btn'}
				onclick={() => setOS('windows')}
				title={t('Afficher les fenêtres au style Windows (AutoHotkey)')}
				aria-pressed={ui.osStyle === 'windows'}
			>
				<i class="icon-windows"></i><span>Windows</span>
			</button>
			<button
				type="button"
				class={ui.osStyle === 'macos' ? 'os-btn active' : 'os-btn'}
				onclick={() => setOS('macos')}
				title={t('Afficher les fenêtres au style macOS (Hammerspoon)')}
				aria-pressed={ui.osStyle === 'macos'}
			>
				<i class="icon-appleinc"></i><span>macOS</span>
			</button>
			<button
				type="button"
				class={ui.osStyle === 'linux' ? 'os-btn active' : 'os-btn'}
				onclick={() => setOS('linux')}
				title={t('Afficher les fenêtres au style Linux (kanata + daemon Lua, alpha)')}
				aria-pressed={ui.osStyle === 'linux'}
			>
				<i class="icon-linux"></i><span>Linux</span>
			</button>
		</div>

		<p class="eyebrow">
			{t('Frappe augmentée')} <span class="dot">•</span> Windows, macOS, Linux
			<span class="dot">•</span>
			{t('100 % local')}
		</p>
		<h1 class="hero-title">
			{t('Tapez moins.')}<br /><span class="grad">{t('Écrivez plus.')}</span>
		</h1>
		<p class="hero-sub">
			<ErgoptiPlus></ErgoptiPlus>
			{@html t(
				'transforme votre frappe en temps réel : expansions de texte, autocorrection, prédictions IA locales, tap-holds, gestes trackpad. Pensé pour le français, l’anglais et le code — <strong>gratuit et open-source</strong>.'
			)}
		</p>

		<ul class="hero-trust" aria-label={t('En bref')}>
			<li><span class="ht-ico" aria-hidden="true">⚡</span> {t('Frappe augmentée')}</li>
			<li><span class="ht-ico" aria-hidden="true">🔒</span> {t('100 % local')}</li>
			<li><span class="ht-ico" aria-hidden="true">⌨️</span> {t('Toute disposition')}</li>
		</ul>

		<div class="hero-cta">
			<a class="btn btn-primary" href={primaryDownload.url} download={!!ui.release}>
				<i class={primaryDownload.icon}></i>
				<span>{primaryDownload.label}</span>
			</a>
			<a class="btn btn-secondary" href="#ep-telecharger">
				<span>{t('Installation & comparatif ↓')}</span>
			</a>
		</div>
		<p class="hero-meta">
			{#if ui.release}<span class="hero-version">{ui.release.tag}</span> ·{/if}
			{t('Gratuit · Open-source · Aucun compte, aucune télémétrie')}
		</p>

		<!-- Live typing demo — real window chrome, real family colors -->
		<div class="demo-stage">
			<div class="demo-window ep-window os-{ui.osStyle}" aria-hidden="true">
				<WindowChrome title="~/notes/brouillon.md" />
				<div class="demo-viewport">
					{#key demoIndex}
						<div
							class="demo-body"
							in:fly={{ x: 80, duration: 320, opacity: 0.2 }}
							out:fly={{ x: -80, duration: 280, opacity: 0 }}
						>
							<span class="demo-typed">{typed}</span><span class="caret"></span>
							{#if phase === 'tooltip'}
								<span class="demo-tooltip" style="--tt: {demos[demoIndex].color};">
									<span class="tt-text">{demos[demoIndex].output}</span>
									<span class="tt-tag">{demos[demoIndex].group}</span>
								</span>
							{/if}
						</div>
					{/key}
				</div>
			</div>

			<ul class="demo-pager" aria-label="Sélectionner une démo">
				{#each demos as d, i}
					<li>
						<button
							type="button"
							class:active={i === demoIndex}
							onclick={() => goToDemo(i)}
							title="{d.input} → {d.output} ({d.group})"
							aria-label="Démo {i + 1} sur {demos.length} : {d.input} devient {d.output}"
						>
							<span class="pager-input">{d.input}</span>
							<span class="pager-arrow">→</span>
							<span class="pager-output">{d.output}</span>
						</button>
					</li>
				{/each}
			</ul>
		</div>

		<a class="scroll-hint" href="#ep-promesses" aria-label={t('Découvrir les fonctionnalités')}>
			<span class="scroll-chevron" aria-hidden="true"></span>
		</a>
	</div>
</section>

<style>
	.hero {
		overflow: visible;
		padding-block: clamp(40px, 6vw, 88px) 0;
		text-align: center;
	}

	.hero-glow {
		/* A soft multi-blob mesh that slowly breathes — replaces the single
		 * static glow for a calmer, more alive Apple-style backdrop. */
		animation: hero-mesh 18s var(--ease, ease-in-out) infinite alternate;
		background:
			radial-gradient(40% 55% at 30% 32%, rgba(49, 190, 255, 0.2), transparent 70%),
			radial-gradient(46% 56% at 72% 42%, rgba(2, 201, 219, 0.15), transparent 70%),
			radial-gradient(52% 62% at 50% 78%, rgba(126, 227, 255, 0.11), transparent 72%);
		filter: blur(8px);
		height: 700px;
		left: 50%;
		max-width: 100vw;
		pointer-events: none;
		position: absolute;
		top: -150px;
		transform: translateX(-50%);
		width: min(1020px, 100vw);
		z-index: -1;
	}

	@keyframes hero-mesh {
		from {
			opacity: 0.82;
			transform: translateX(-50%) scale(1);
		}
		to {
			opacity: 1;
			transform: translateX(-50%) scale(1.08) translateY(12px);
		}
	}

	/* ─── Above-the-fold trust pills + scroll hint ──────────── */

	.hero-trust {
		display: flex;
		flex-wrap: wrap;
		gap: 10px 22px;
		justify-content: center;
		list-style: none;
		margin: 0 0 28px;
		padding: 0;
	}

	.hero-trust li {
		align-items: center;
		color: var(--ink-soft);
		display: inline-flex;
		font-size: 0.9rem;
		font-weight: 600;
		gap: 7px;
	}

	.ht-ico {
		font-size: 1.05rem;
	}

	.scroll-hint {
		color: var(--ink-faint);
		display: block;
		height: 26px;
		margin: clamp(30px, 5vw, 56px) auto 0;
		width: 26px;
	}

	.scroll-hint:hover {
		color: var(--ink);
	}

	.scroll-chevron {
		animation: scroll-bounce 1.9s var(--ease, ease-in-out) infinite;
		border-bottom: 2px solid currentColor;
		border-right: 2px solid currentColor;
		display: block;
		height: 12px;
		margin: 0 auto;
		transform: rotate(45deg);
		width: 12px;
	}

	@keyframes scroll-bounce {
		0%,
		100% {
			opacity: 0.5;
			transform: rotate(45deg) translate(0, 0);
		}
		50% {
			opacity: 1;
			transform: rotate(45deg) translate(4px, 4px);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.hero-glow,
		.scroll-chevron {
			animation: none;
		}
	}

	/* ─── OS toggle ─────────────────────────────────────────── */

	.os-toggle {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		display: inline-flex;
		gap: 0;
		margin-bottom: 28px;
		padding: 4px;
		position: relative;
		width: min(340px, 92vw);
	}

	/* The single highlight that slides between the three options. */
	.os-slider {
		background: rgba(255, 255, 255, 0.13);
		border-radius: 999px;
		bottom: 4px;
		left: 4px;
		position: absolute;
		top: 4px;
		transform: translateX(calc(var(--i, 0) * 100%));
		transition: transform 0.32s var(--ease-out);
		width: calc((100% - 8px) / 3);
		z-index: 0;
	}

	.os-btn {
		align-items: center;
		background: transparent;
		border: 0;
		border-radius: 999px;
		color: var(--ink-soft);
		cursor: pointer;
		display: inline-flex;
		flex: 1;
		font: inherit;
		font-size: 0.85rem;
		font-weight: 600;
		gap: 7px;
		justify-content: center;
		padding: 7px 12px;
		position: relative;
		transition: color 0.25s var(--ease);
		z-index: 1;
	}

	.os-btn:hover {
		color: var(--ink);
	}

	.os-btn.active {
		color: var(--ink);
	}

	@media (prefers-reduced-motion: reduce) {
		.os-slider {
			transition: none;
		}
	}

	/* ─── Headline ──────────────────────────────────────────── */

	.eyebrow {
		color: var(--ink-faint);
		font-size: 0.85rem;
		font-weight: 600;
		letter-spacing: 0.1em;
		margin: 0 0 18px;
		text-align: center;
		text-transform: uppercase;
	}

	.eyebrow .dot {
		color: var(--accent-blue);
		margin-inline: 6px;
	}

	.hero-title {
		font-size: clamp(2rem, 5vw, 3.4rem);
		font-weight: 800;
		letter-spacing: -0.03em;
		line-height: 1.08;
		margin: 0 0 20px;
		text-align: center;
	}

	/* inline-block + bottom padding keep descenders inside the painted
	 * area — background-clip:text renders them transparent otherwise */
	.hero-title .grad {
		animation: grad-shift 7s linear infinite;
		background: linear-gradient(92deg, #31beff, #02c9db, #7ee3ff, #31beff);
		background-size: 200% auto;
		-webkit-background-clip: text;
		background-clip: text;
		display: inline-block;
		padding-bottom: 0.1em;
		-webkit-text-fill-color: transparent;
	}

	@keyframes grad-shift {
		to {
			background-position: 200% center;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.hero-title .grad {
			animation: none;
		}
	}

	.hero-sub {
		color: var(--ink-soft);
		font-size: clamp(0.95rem, 1.2vw, 1.08rem);
		line-height: 1.65;
		margin: 0 auto 26px;
		max-width: 600px;
		text-align: center;
		text-wrap: pretty;
	}

	.hero-cta {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		justify-content: center;
	}

	.hero-meta {
		color: var(--ink-faint);
		font-size: 0.82rem;
		margin: 14px 0 0;
		text-align: center;
	}

	.hero-version {
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 999px;
		color: var(--accent-blue);
		font-weight: 600;
		padding: 2px 10px;
	}

	/* ─── Demo window ───────────────────────────────────────── */

	.demo-stage {
		margin: clamp(36px, 5vw, 56px) auto 0;
		max-width: 720px;
	}

	.demo-viewport {
		display: grid;
		min-height: 150px;
		overflow: hidden;
		padding: 28px 30px;
		text-align: left;
	}

	.demo-body {
		align-self: center;
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: clamp(1.25rem, 2.6vw, 1.7rem);
		grid-area: 1 / 1;
		position: relative;
	}

	.demo-typed {
		color: var(--ink);
	}

	/* Inline in the text flow, right of the caret — like the real driver
	 * tooltip. Absolute placement below the line got clipped by the
	 * window's bottom edge. */
	.demo-tooltip {
		align-items: center;
		animation: tooltip-pop 0.22s var(--ease-out);
		background: rgba(12, 16, 28, 0.97);
		border: 1.5px solid var(--tt);
		border-radius: 8px;
		box-shadow: 0 6px 22px -6px color-mix(in srgb, var(--tt) 55%, transparent);
		display: inline-flex;
		gap: 8px;
		margin-left: 14px;
		padding: 4px 10px;
		vertical-align: middle;
		white-space: nowrap;
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
		font-size: 0.95rem;
		font-weight: 700;
	}

	.tt-tag {
		background: color-mix(in srgb, var(--tt) 18%, transparent);
		border-radius: 999px;
		color: color-mix(in srgb, var(--tt) 70%, #fff);
		font-size: 0.68rem;
		font-weight: 700;
		letter-spacing: 0.05em;
		padding: 3px 9px;
		text-transform: uppercase;
	}

	/* ─── Pager chips ───────────────────────────────────────── */

	.demo-pager {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		justify-content: center;
		list-style: none;
		margin: 22px 0 0;
		padding: 0;
	}

	.demo-pager button {
		align-items: center;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-faint);
		cursor: pointer;
		display: inline-flex;
		font: inherit;
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.78rem;
		gap: 6px;
		padding: 6px 13px;
		transition:
			background-color 0.25s var(--ease),
			border-color 0.25s var(--ease),
			color 0.25s var(--ease);
	}

	.demo-pager button:hover {
		border-color: var(--border-strong);
		color: var(--ink-soft);
	}

	.demo-pager button.active {
		background: rgba(49, 190, 255, 0.12);
		border-color: rgba(49, 190, 255, 0.45);
		color: var(--ink);
	}

	.pager-arrow {
		opacity: 0.55;
	}

	.pager-output {
		font-weight: 700;
	}

	@media (max-width: 720px) {
		.demo-pager {
			display: none;
		}
	}
</style>
