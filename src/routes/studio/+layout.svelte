<!-- src/routes/studio/+layout.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio Section Layout
DESCRIPTION:
Wraps the Ergopti Studio pages with their tab bar: « Éditer » (the layout
editor) and « Comparer » (layout comparison). The tabs come from
siteNavigation.js.
==============================================================================
-->

<script>
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import SubNav from '#lib/components/SubNav.svelte';
	import { STUDIO_PAGES } from '#lib/js/siteNavigation.js';

	let { children } = $props();

	let items = $derived(
		STUDIO_PAGES.map((entry) => ({
			href: resolve(entry.route),
			label: entry.label,
			current: page.url.pathname.replace(/\/$/, '') === resolve(entry.route)
		}))
	);
</script>

<SubNav label="Onglets d’Ergopti Studio" {items} />
{@render children()}
