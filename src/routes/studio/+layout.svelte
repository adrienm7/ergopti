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
« Apparence » chooses the framed tools' light or dark theme (or the
system's), kept in this browser and sent to each frame (frameTheme.js).
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { asset, resolve } from '$app/paths';
	import SubNav from '#lib/components/SubNav.svelte';
	import { STUDIO_PAGES } from '#lib/js/siteNavigation.js';
	import {
		THEME_CHOICES,
		THEME_STORAGE_KEY,
		readThemeChoice,
		sendTheme
	} from '#lib/js/frameTheme.js';

	let { children } = $props();

	// The framed tools' theme: the system's appearance until the visitor
	// chooses, then the choice, kept in this browser (frameTheme.js).
	const THEME_LABELS = { system: 'Thème du système', light: 'Clair', dark: 'Sombre' };
	let theme = $state(THEME_CHOICES[0]);
	let workspace = $state();

	/** Tells every framed tool the theme. */
	function sendToFrames() {
		for (const frame of workspace?.querySelectorAll('iframe') ?? []) sendTheme(frame, theme);
	}

	function chooseTheme() {
		try {
			localStorage.setItem(THEME_STORAGE_KEY, theme);
		} catch {
			// A private window or blocked storage: the choice holds for this page only.
		}
		sendToFrames();
	}

	onMount(() => {
		try {
			theme = readThemeChoice(localStorage.getItem(THEME_STORAGE_KEY));
		} catch {
			theme = THEME_CHOICES[0];
		}
		// Each framed tool, when it loads (or loads another tab), hears the theme.
		const loaded = (event) => {
			if (event.target instanceof HTMLIFrameElement) sendTheme(event.target, theme);
		};
		workspace.addEventListener('load', loaded, true);
		sendToFrames();
		return () => workspace.removeEventListener('load', loaded, true);
	});

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
			icon: entry.icon,
			current: page.url.pathname.replace(/\/$/, '') === resolve(entry.route)
		}))
	);
</script>

<div class="studio-shell">
	<div class="studio-bar">
		<!-- « Ergopti Studio » and its mark on the left of its tabs (maintainer, 2026-11-18). -->
		<span class="studio-brand">
			<img src={asset('img/logo/studio.svg')} alt="" width="24" height="24" />
			Ergopti Studio
		</span>
		<SubNav label="Onglets d’Ergopti Studio" {items} compact />
		<label class="studio-theme">
			<span>Apparence</span>
			<select bind:value={theme} onchange={chooseTheme}>
				{#each THEME_CHOICES as choice (choice)}
					<option value={choice}>{THEME_LABELS[choice]}</option>
				{/each}
			</select>
		</label>
	</div>
	<main class="studio-workspace" bind:this={workspace}>
		{@render children()}
	</main>
</div>

<style>
	/* Below the fixed header (and the dev banner), the shell fills the screen. */
	.studio-shell {
		display: flex;
		flex-direction: column;
		height: calc(100dvh - var(--header-offset) - var(--banner-height));
		min-height: 480px;
	}

	/* The tabs and the appearance choice share the header's dark band; on a
	   phone the choice wraps under the tabs. */
	.studio-bar {
		align-items: center;
		background-color: var(--header-color);
		display: flex;
		flex-wrap: wrap;
		gap: 0 12px;
		justify-content: center;
	}

	.studio-bar :global(.subnav.compact) {
		flex: 1 1 auto;
		min-width: 0;
		width: auto;
	}

	/* The name may break between its two words at 200 % text on a phone. */
	.studio-brand {
		align-items: center;
		box-sizing: border-box;
		color: rgba(255, 255, 255, 0.95);
		display: flex;
		font-weight: bold;
		gap: 8px;
		max-width: 100%;
		min-width: 0;
		padding: 0.4rem 16px;
		text-align: center;
	}

	/* At 200 % text the longest choice (« Thème du système ») outgrows a phone:
	   the select then goes under its label and narrows to the bar. */
	.studio-theme {
		align-items: center;
		box-sizing: border-box;
		color: rgba(255, 255, 255, 0.9);
		display: flex;
		flex-wrap: wrap;
		font-size: 0.9rem;
		gap: 6px;
		justify-content: center;
		max-width: 100%;
		min-width: 0;
		padding: 0.4rem 16px;
	}

	.studio-theme select {
		font: inherit;
		max-width: 100%;
		min-width: 0;
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
