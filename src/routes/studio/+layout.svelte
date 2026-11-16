<!-- src/routes/studio/+layout.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio Section Layout
DESCRIPTION:
Ergopti Studio is an app-like workspace: under the site header, a slim tab
bar (« Éditer », « Comparer », « Optimiser », from siteNavigation.js) and the framed tool,
which takes the full width and the rest of the viewport height and scrolls
inside itself. The site page around it does not scroll. The editor's
« Compare with other layouts » opens the « Comparer » tab, which takes the
layout the editor stored for this tab; the optimizer's « Open in the editor »
opens « Éditer », which takes the layout the optimizer stored the same way.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import SubNav from '#lib/components/SubNav.svelte';
	import { STUDIO_PAGES } from '#lib/js/siteNavigation.js';

	let { children } = $props();

	// The editor's « Compare with other layouts »: the framed editor stores the
	// layout for this tab, then asks for the Comparer (the message type of
	// layout_analysis/corpus_files.js OPEN_COMPARER_MESSAGE).
	const OPEN_COMPARER_MESSAGE = 'ergopti-studio:open-comparer';
	// The optimizer's « Open in the editor »: the layout waits in this tab's
	// storage (corpus_files.js handOffToEditor, OPEN_EDITOR_MESSAGE).
	const OPEN_EDITOR_MESSAGE = 'ergopti-studio:open-editor';

	onMount(() => {
		const open = (event) => {
			if (event.origin !== location.origin) return;
			if (!event.data) return;
			if (event.data.type === OPEN_COMPARER_MESSAGE) goto(resolve('/studio/comparer'));
			else if (event.data.type === OPEN_EDITOR_MESSAGE) goto(resolve('/studio'));
		};
		window.addEventListener('message', open);
		return () => window.removeEventListener('message', open);
	});

	let items = $derived(
		STUDIO_PAGES.map((entry) => ({
			href: resolve(entry.route),
			label: entry.label,
			current: page.url.pathname.replace(/\/$/, '') === resolve(entry.route)
		}))
	);
</script>

<div class="studio-shell">
	<SubNav label="Onglets d’Ergopti Studio" {items} compact />
	<main class="studio-workspace">
		{@render children()}
	</main>
</div>

<style>
	/* Below the fixed header (and the dev banner), the shell fills the screen. */
	.studio-shell {
		display: flex;
		flex-direction: column;
		height: calc(100dvh - var(--header-height) - var(--banner-height));
		min-height: 480px;
	}

	/* The site's main rule sizes text pages; the workspace is full bleed. */
	.studio-workspace {
		display: flex;
		flex: 1;
		flex-direction: column;
		margin: 0;
		min-height: 0;
		overflow: hidden;
		padding: 0;
		width: 100%;
	}

	.studio-workspace :global(.studio-frame) {
		background: #101018;
		border: 0;
		display: block;
		flex: 1;
		min-height: 0;
		width: 100%;
	}

	.studio-workspace :global(.studio-title) {
		clip: rect(0 0 0 0);
		clip-path: inset(50%);
		height: 1px;
		margin: -1px;
		overflow: hidden;
		position: absolute;
		white-space: nowrap;
		width: 1px;
	}
</style>
