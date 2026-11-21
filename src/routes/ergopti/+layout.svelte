<!-- src/routes/ergopti/+layout.svelte -->

<!--
==============================================================================
MODULE: Disposition Ergopti Section Layout
DESCRIPTION:
Wraps every Disposition Ergopti page with the local navigation between its
sub-pages. The page map is siteNavigation.js.
==============================================================================
-->

<script>
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import SubNav from '#lib/components/SubNav.svelte';
	import { LAYOUT_PAGES, resolveWithQuery } from '#lib/js/siteNavigation.js';

	let { children } = $props();

	let items = $derived(
		LAYOUT_PAGES.map((entry) => ({
			href: resolveWithQuery(entry.query ? entry.route + '?' + entry.query : entry.route, resolve),
			label: entry.label,
			current: page.url.pathname.replace(/\/$/, '') === resolve(entry.route)
		}))
	);
</script>

<SubNav label="Pages de la Disposition Ergopti" {items} />
{@render children()}
