<!-- src/routes/ergopti/+page.svelte -->

<!--
==============================================================================
MODULE: Disposition Ergopti Overview
DESCRIPTION:
Short entry page of the layout: what it is, the layout itself, and the
sub-pages that hold the details (siteNavigation.js lists them).
==============================================================================
-->

<script>
	import { resolve } from '$app/paths';

	import Ergopti from '#lib/components/Ergopti.svelte';
	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '#lib/keyboard/controls/KeyboardControls.svelte';
	import { LAYOUT_PAGES } from '#lib/js/siteNavigation.js';
</script>

<svelte:head>
	<title>Disposition Ergopti</title>
	<meta
		name="description"
		content="La Disposition Ergopti, une disposition clavier ergonomique et optimisée pour le français, l’anglais et le code"
	/>
</svelte:head>

<main class="overview" aria-labelledby="overview-title">
	<h1 id="overview-title" class="ergopti-title">Disposition <Ergopti /></h1>
	<p class="encart-introduction">
		Une <strong>disposition clavier ergonomique et optimisée</strong> pour le
		<b>français</b>, l’<b>anglais</b> et la <b>programmation</b> : moins de distance parcourue par les
		doigts, une frappe fluide et un confort d’exception.
	</p>
	<KeyboardBasis id="presentation" />
	<!-- A click on a key switches the drawn layer; the layer select of the
	     controls does it from the keyboard (WCAG 2.1.1). -->
	<tiny-space></tiny-space>
	<KeyboardControls id="presentation" />
	<ul class="overview-pages">
		{#each LAYOUT_PAGES.slice(1) as entry (entry.route)}
			<li>
				<a href={resolve(entry.route)}>
					<strong>{entry.label}</strong>
					<p>{entry.summary}</p>
				</a>
			</li>
		{/each}
	</ul>
</main>

<style>
	/* The site's main rule sizes text pages; the overview sets its own measure. */
	.overview {
		margin: 0 auto;
		max-width: 1100px;
		padding: 0 16px 3rem;
		width: auto;
	}

	.overview .ergopti-title {
		margin: 1.5rem 0 0.5rem;
	}

	/* Cards at least 15rem wide: the rem follows the text size, so larger text
	   gives fewer columns instead of names cut or drawn over their neighbours. */
	.overview-pages {
		display: grid;
		gap: 0.75rem;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, 15rem), 1fr));
		list-style: none;
		margin: 2rem 0 0;
		padding: 0;
	}

	.overview-pages li {
		margin: 0;
	}

	/* The summary is a paragraph of the card: none of the prose column's
	   spacing, measure or line height applies inside the link. */
	.overview-pages p {
		line-height: inherit;
		margin: 0;
		max-width: none;
		text-align: inherit;
	}

	.overview-pages a {
		background: rgba(0, 0, 0, 0.45);
		border: 1px solid rgba(255, 255, 255, 0.12);
		border-radius: 10px;
		color: white;
		display: flex;
		flex-direction: column;
		gap: 0.35rem;
		height: 100%;
		padding: 1rem;
		text-align: left;
		text-decoration: none;
	}

	.overview-pages a:hover,
	.overview-pages a:focus-visible {
		border-color: rgba(255, 255, 255, 0.45);
	}
</style>
