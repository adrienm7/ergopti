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
When the shell is narrow for its text (a phone, or 200 % text), the tabs and
« Apparence » fold into a menu button named after the current tab, so the bar
stays one row and the workspace keeps the screen (WCAG 1.4.4, 1.4.10).
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { afterNavigate, goto } from '$app/navigation';
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
	// The editor's « Optimize this layout »: the layout waits in this tab's
	// storage (corpus_files.js OPEN_OPTIMIZER_MESSAGE).
	const OPEN_OPTIMIZER_MESSAGE = 'ergopti-studio:open-optimizer';

	onMount(() => {
		const open = (event) => {
			if (event.origin !== location.origin) return;
			if (!event.data) return;
			if (event.data.type === OPEN_COMPARER_MESSAGE) goto(resolve('/studio/comparer'));
			else if (event.data.type === OPEN_EDITOR_MESSAGE) goto(resolve('/studio'));
			else if (event.data.type === OPEN_OPTIMIZER_MESSAGE) goto(resolve('/studio/optimiser'));
		};
		window.addEventListener('message', open);
		return () => window.removeEventListener('message', open);
	});

	// The folded menu (a narrow shell, see the style) closes once a tab opens.
	let menuOpen = $state(false);
	let menuButton = $state();
	afterNavigate(() => {
		menuOpen = false;
	});

	/** Escape folds the open menu and gives the focus back to its button. */
	function closeOnEscape(event) {
		if (event.key !== 'Escape' || !menuOpen) return;
		menuOpen = false;
		menuButton.focus();
	}

	let items = $derived(
		STUDIO_PAGES.map((entry) => ({
			href: resolve(entry.route),
			label: entry.label,
			icon: entry.icon,
			current: page.url.pathname.replace(/\/$/, '') === resolve(entry.route)
		}))
	);
	let currentLabel = $derived(items.find((item) => item.current)?.label);
</script>

<div class="studio-shell">
	<div class="studio-bar">
		<!-- « Ergopti Studio » and its mark on the left of its tabs (maintainer, 2026-11-18). -->
		<span class="studio-brand">
			<img src={asset('img/logo/studio.svg')} alt="" width="24" height="24" />
			<span class="studio-brand-name">Ergopti Studio</span>
		</span>
		<button
			type="button"
			class="studio-menu-button"
			aria-expanded={menuOpen}
			aria-controls="studio-menu"
			bind:this={menuButton}
			onclick={() => (menuOpen = !menuOpen)}
		>
			<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"
				><path d="M4 6h16M4 12h16M4 18h16" /></svg
			><span class="visually-hidden">Onglets et apparence d’Ergopti Studio, onglet actuel :</span>
			{currentLabel}
		</button>
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			id="studio-menu"
			class="studio-menu bg-blue"
			class:open={menuOpen}
			onkeydown={closeOnEscape}
		>
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
	</div>
	<main class="studio-workspace" bind:this={workspace}>
		{@render children()}
	</main>
</div>

<style>
	/* Below the fixed header (and the dev banner), the shell fills the screen. */
	.studio-shell {
		container: studio-shell / inline-size;
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

	/* On a wide shell the tabs and « Apparence » are the bar's own items. */
	.studio-menu {
		display: contents;
	}

	.studio-menu-button {
		display: none;
	}

	/*
	 * A shell under 24 em of its own text, a phone or 200 % text (in em, so
	 * the site's text size counts): the tabs, the brand and « Apparence »
	 * wrapped into up to 500 px of bar at 320 px with 200 % text, leaving the
	 * workspace 0 px. The bar is then one row, the brand's mark and a menu
	 * button named after the current tab, and the open menu lays over the
	 * workspace instead of resizing it.
	 */
	@container studio-shell (max-width: 24em) {
		.studio-bar {
			flex-wrap: nowrap;
			justify-content: space-between;
			position: relative;
		}

		.studio-brand {
			flex: none;
		}

		/* Still read: the site header already shows « Ergopti » to the eye. */
		.studio-brand-name {
			clip: rect(0 0 0 0);
			clip-path: inset(50%);
			height: 1px;
			margin: -1px;
			overflow: hidden;
			position: absolute;
			white-space: nowrap;
			width: 1px;
		}

		.studio-menu-button {
			align-items: center;
			background: none;
			border: 1px solid rgba(255, 255, 255, 0.35);
			border-radius: 6px;
			color: var(--couleur-liens-header);
			display: flex;
			font: inherit;
			font-weight: bold;
			gap: 0.4em;
			margin: 0.3rem 16px 0.3rem 0;
			min-width: 0;
			padding: 0.3rem 0.6rem;
		}

		.studio-menu-button svg {
			fill: none;
			flex: none;
			height: 1.1em;
			stroke: currentColor;
			stroke-linecap: round;
			stroke-width: 2;
			width: 1.1em;
		}

		.studio-menu {
			display: none;
		}

		/* The page's own backdrop (.bg-blue) under the header's translucent
		   band, so the workspace does not show through the open menu. */
		.studio-menu.open {
			border-bottom: 1px solid rgba(255, 255, 255, 0.15);
			display: flex;
			flex-direction: column;
			left: 0;
			position: absolute;
			right: 0;
			top: 100%;
			z-index: 2;
		}

		/* Each row spans the menu (the tabs' own centring margin would not). */
		.studio-bar .studio-menu.open > :global(*) {
			background-color: var(--header-color);
			margin: 0;
			width: 100%;
		}

		.studio-menu.open :global(.subnav.compact ul) {
			align-items: center;
			flex-direction: column;
		}
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
