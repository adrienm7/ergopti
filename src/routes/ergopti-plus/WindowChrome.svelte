<!-- src/routes/ergopti-plus/WindowChrome.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Window Chrome
DESCRIPTION:
Title bar of the mock windows, rendered in the style selected by the page's
OS toggle: macOS traffic lights, Windows caption buttons, or a GNOME-style
Linux headerbar with circular controls.

FEATURES & RATIONALE:
1. Single Source: every mock window on the page shares this component, so
   adding an OS style (Linux) is one edit instead of five.
2. Decorative Only: the buttons are not interactive and carry no hover
   state — mock chrome must never look clickable.
==============================================================================
-->

<script>
	import { ui } from './state.svelte.js';

	/** @type {{title: string, live?: boolean}} */
	let { title, live = false } = $props();
</script>

<div class="chrome">
	{#if ui.osStyle === 'macos'}
		<span class="mac-dots">
			<span class="dot dot-r"></span>
			<span class="dot dot-y"></span>
			<span class="dot dot-g"></span>
		</span>
		<span class="chrome-title">{title}</span>
		{#if live}<span class="live-badge">● live</span>{:else}<span class="chrome-spacer"></span>{/if}
	{:else if ui.osStyle === 'linux'}
		<span class="chrome-spacer chrome-spacer--linux"></span>
		<span class="chrome-title">{title}</span>
		{#if live}<span class="live-badge">● live</span>{/if}
		<span class="linux-controls">
			<span class="linux-btn">─</span>
			<span class="linux-btn">▢</span>
			<span class="linux-btn">✕</span>
		</span>
	{:else}
		<span class="chrome-title chrome-title--win">{title}</span>
		{#if live}<span class="live-badge">● live</span>{/if}
		<span class="win-buttons">
			<span class="win-btn">─</span>
			<span class="win-btn">▢</span>
			<span class="win-btn">✕</span>
		</span>
	{/if}
</div>
