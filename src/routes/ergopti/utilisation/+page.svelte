<!-- src/routes/ergopti/utilisation/+page.svelte -->

<!--
==============================================================================
MODULE: Try the Disposition Ergopti
DESCRIPTION:
Typing with the layout in the browser and browsing its text replacements,
split from the former Utilisation page; installation is its own sub-page.
==============================================================================
-->

<script>
	import { resolve } from '$app/paths';
	import IntroductionUtilisation from './introduction_utilisation.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';
</script>

<svelte:head>
	<title>Essayer la Disposition Ergopti</title>
	<meta
		name="description"
		content="Taper avec la Disposition Ergopti dans le navigateur et parcourir ses remplacements de texte"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<IntroductionUtilisation />
		</bloc-introduction>
	</svelte:fragment>

	<p>
		Pour installer la disposition sur votre ordinateur, rendez-vous sur la page
		<a href={resolve('/ergopti/installation')} class="link">Installation</a>.
	</p>
</PageWrapper>
