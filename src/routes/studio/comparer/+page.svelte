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

	/** Height before the framed page reports its own (its usual empty height). */
	const INITIAL_HEIGHT_PX = 800;
	/** Bounds a reported height must fall in; anything else is ignored. */
	const MIN_HEIGHT_PX = 300;
	const MAX_HEIGHT_PX = 20000;
	/** Message type the layout analysis page posts when framed. */
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';

	const comparerSrc = asset('ergopti_plus/_shared/ui/layout_analysis/index.html') + '?lang=fr';

	let frame = $state();
	let height = $state(INITIAL_HEIGHT_PX);

	/**
	 * Fit the frame to the content height the framed page reports, so the
	 * comparison scrolls with the page instead of inside the frame.
	 * @param {MessageEvent} event
	 */
	function onMessage(event) {
		if (!frame || event.source !== frame.contentWindow) return;
		if (event.origin !== location.origin) return;
		const data = event.data;
		if (!data || data.type !== HEIGHT_MESSAGE) return;
		if (!Number.isFinite(data.height)) return;
		if (data.height < MIN_HEIGHT_PX || data.height > MAX_HEIGHT_PX) return;
		height = Math.ceil(data.height);
	}
</script>

<svelte:window onmessage={onMessage} />

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
		bind:this={frame}
		style="height:{height}px"
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
