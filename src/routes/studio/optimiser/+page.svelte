<!-- src/routes/studio/optimiser/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio — Optimiser
DESCRIPTION:
The optimizer tab of Ergopti Studio. It frames the shared layout optimizer
page served as-is from static/ergopti_plus/_shared/ui/layout_optimizer/: it
searches the arrangement the Comparer's score rates best on a corpus, in Web
Workers of the visitor's browser. The shell (tab bar, full-bleed frame
scrolling inside itself) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { asset } from '$app/paths';
	import SiteFrame from '#lib/components/SiteFrame.svelte';

	const optimizerSrc = asset('ergopti_plus/_shared/ui/layout_optimizer/index.html') + '?lang=fr';
</script>

<svelte:head>
	<title>Optimiser une disposition — Ergopti Studio</title>
	<meta
		name="description"
		content="Ergopti Studio : générer la disposition de clavier la mieux notée sur un corpus, dans le navigateur"
	/>
</svelte:head>

<h1 class="studio-title">Optimiser une disposition</h1>
<SiteFrame class="studio-frame" title="Ergopti Studio — Optimiser" src={optimizerSrc} />
