<!-- src/routes/studio/comparer/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio — Comparer
DESCRIPTION:
The comparison tab of Ergopti Studio. It frames the shared layout analysis
page served as-is from static/ergopti_plus/_shared/ui/layout_analysis/, the
same page Ergopti+ shows, so the site and the app cannot diverge. The shell
(tab bar, full-bleed frame scrolling inside itself) is ../+layout.svelte.
Everything runs in the visitor's browser. A shared comparison is this page's
address with the Comparer's parameters (?layouts=…&details=…), handed on to
the frame (#lib/js/comparerLink.js).
==============================================================================
-->

<script>
	import { asset } from '$app/paths';
	import { browser } from '$app/environment';
	import SiteFrame from '#lib/components/SiteFrame.svelte';
	import { comparerSrc as frameSrc } from '#lib/js/comparerLink.js';

	// SiteFrame sets the address on the client only, so the visited query is known there.
	const comparerSrc = frameSrc(
		asset('ergopti_plus/_shared/ui/layout_analysis/index.html'),
		{ lang: 'fr' },
		browser ? location.search : ''
	);
</script>

<svelte:head>
	<title>Comparer des dispositions — Ergopti Studio</title>
	<meta
		name="description"
		content="Ergopti Studio : comparer des dispositions de clavier sur des corpus français, anglais et code, dans le navigateur"
	/>
</svelte:head>

<h1 class="studio-title">Comparer des dispositions</h1>
<SiteFrame
	class="studio-frame layout-analysis-frame"
	title="Ergopti Studio — Comparer"
	src={comparerSrc}
/>
