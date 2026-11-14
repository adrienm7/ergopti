<!-- src/routes/studio/comparer/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti Studio — Comparer
DESCRIPTION:
The comparison tab of Ergopti Studio. It frames the shared layout analysis
page served as-is from static/ergopti_plus/_shared/ui/layout_analysis/, the
same page Ergopti+ shows, so the site and the app cannot diverge. Everything
runs in the visitor's browser.
==============================================================================
-->

<script>
	import { asset } from '$app/paths';
	import PageWrapper from '#lib/components/PageWrapper.svelte';

	/** Height of the framed page; it scrolls inside the frame beyond that. */
	const COMPARER_HEIGHT_PX = 1400;

	const comparerSrc = asset('ergopti_plus/_shared/ui/layout_analysis/index.html') + '?lang=fr';
</script>

<svelte:head>
	<title>Comparer des dispositions — Ergopti Studio</title>
	<meta
		name="description"
		content="Ergopti Studio : comparer des dispositions de clavier sur des corpus français, anglais et code, dans le navigateur"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<h1>Comparer des dispositions</h1>
			<p>
				Choisissez un corpus et des dispositions, ou importez les vôtres, pour comparer leurs
				statistiques de frappe. L’analyse tourne entièrement dans votre navigateur : aucun fichier
				n’est envoyé.
			</p>
		</bloc-introduction>
	</svelte:fragment>

	<iframe
		class="layout-analysis-frame"
		title="Comparer des dispositions — Ergopti Studio"
		src={comparerSrc}
		style="height:{COMPARER_HEIGHT_PX}px"
	></iframe>
</PageWrapper>

<style>
	.layout-analysis-frame {
		border: 0;
		border-radius: 8px;
		display: block;
		width: 100%;
	}
</style>
