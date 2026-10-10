<!-- src/routes/ergopti-plus/DriverFrame.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Embedded Driver Window
DESCRIPTION:
One real driver webview embedded where the page talks about it: the same
HTML/JS/CSS bundle the drivers open natively, served as-is from static/ and
framed in the OS chrome selected by the page toggle. The page plays the
native host's role — same-origin iframes let it call the exact injection
entry points the drivers use (injectModels, initData).

FEATURES & RATIONALE:
1. Dispatched, Not Gathered: each window lives inside the section that
   explains it (editor with the hotstrings, catalog with the AI…), instead
   of a separate gallery the visitor has to connect back mentally.
2. Host Emulation: injection goes through the drivers' own contracts, so
   the demo can never diverge from the real UI.
==============================================================================
-->

<script>
	import { base } from '$app/paths';
	import { driverWindowSrc, hostDriverWindow } from '$lib/js/driverWindowHost.js';
	import WindowChrome from './WindowChrome.svelte';
	import { reveal } from './reveal.js';
	import { ui } from './state.svelte.js';

	/** Default max height of the embedded window area. */
	const DEFAULT_DISPLAY_HEIGHT = 600;

	/**
	 * @type {{
	 *   id: string,
	 *   width: number,
	 *   height: number,
	 *   displayHeight?: number,
	 *   oninfochange?: ((fields: Record<string, string>) => void) | null
	 * }}
	 */
	let { id, width, height, displayHeight = DEFAULT_DISPLAY_HEIGHT, oninfochange = null } = $props();

	let frameHeight = $derived(Math.min(displayHeight, height));

	// Flips true on the iframe's load event so the skeleton shimmer can hide.
	let loaded = $state(false);

	let frameSrc = $derived(driverWindowSrc(id, base));

	/**
	 * Play the native host: once the iframe loads, inject the data through
	 * the same entry point the driver uses for this window.
	 * @param {Event} ev
	 */
	function onFrameLoad(ev) {
		const win = ev.currentTarget?.contentWindow;
		loaded = true;
		if (!win) return;
		hostDriverWindow(win, id, { base, locale: 'fr', onInfoChange: oninfochange }).catch((e) =>
			console.error('Injection dans la fenêtre du driver impossible :', e)
		);
	}
</script>

<!-- The shell hugs the window's native width so the iframe fills it edge to
     edge — no leftover gutter, narrow windows stay naturally centered -->
<div class="frame-shell ep-window os-{ui.osStyle}" style="max-width: {width}px;" use:reveal>
	<WindowChrome title="/ergopti_plus/_shared/ui/{id}/ · {width}×{height}" live={true} />
	<div class="frame-wrap" style="height: {frameHeight}px;">
		{#if !loaded}
			<div class="frame-skeleton" aria-hidden="true"></div>
		{/if}
		<iframe src={frameSrc} title={id} loading="lazy" onload={onFrameLoad}></iframe>
	</div>
</div>

<style>
	.frame-shell {
		margin: 0 auto;
		width: 100%;
	}

	.frame-wrap {
		background: #101018;
		overflow: hidden;
		position: relative;
	}

	.frame-wrap iframe {
		border: 0;
		display: block;
		height: 100%;
		position: relative;
		width: 100%;
		z-index: 1;
	}

	/* Shimmer placeholder shown until the embedded window finishes loading —
	 * a calmer first paint than a bare dark rectangle. */
	.frame-skeleton {
		animation: frame-shimmer 1.4s ease-in-out infinite;
		background:
			linear-gradient(
				100deg,
				transparent 20%,
				rgba(255, 255, 255, 0.06) 40%,
				rgba(255, 255, 255, 0.06) 60%,
				transparent 80%
			),
			#101018;
		background-size: 220% 100%;
		inset: 0;
		position: absolute;
		z-index: 2;
	}

	@keyframes frame-shimmer {
		from {
			background-position: 120% 0;
		}
		to {
			background-position: -120% 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.frame-skeleton {
			animation: none;
		}
	}

	@media (max-width: 720px) {
		.frame-wrap {
			max-height: 460px;
		}
	}
</style>
