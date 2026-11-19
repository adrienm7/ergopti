<!-- src/routes/+page.svelte -->

<!--
==============================================================================
MODULE: Home Page
DESCRIPTION:
Ergopti is the project; the home page only presents its three products, each
with its icon, one or two sentences and a link. The layout content that used
to live here is on /ergopti/presentation, and an anchor of the former home
page is forwarded there.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { asset, resolve } from '$app/paths';

	import Ergopti from '#lib/components/Ergopti.svelte';
	import { PRODUCTS, LEGACY_HOME_ANCHOR_TARGET } from '#lib/js/siteNavigation.js';

	onMount(() => {
		if (location.hash)
			goto(resolve(LEGACY_HOME_ANCHOR_TARGET) + location.hash, { replaceState: true });
	});
</script>

<svelte:head>
	<title>Ergopti — optimisation de l’ergonomie clavier</title>
	<meta
		name="description"
		content="Ergopti, le projet d’optimisation de l’ergonomie clavier : la Disposition Ergopti, le logiciel Ergopti+ et l’éditeur Ergopti Studio."
	/>
</svelte:head>

<main id="accueil" aria-labelledby="accueil-titre">
	<h1 id="accueil-titre" class="accueil-title"><Ergopti /></h1>
	<p class="accueil-tagline">Optimisation de l’ergonomie clavier</p>
	<p class="accueil-naming">
		<strong>Ergopti</strong> est le projet ; il comprend la <strong>Disposition Ergopti</strong>
		(la disposition clavier), <strong>Ergopti+</strong> (le logiciel) et
		<strong>Ergopti Studio</strong> (l’éditeur de disposition).
	</p>
	<ul class="products">
		{#each PRODUCTS as product (product.id)}
			<li>
				<a class="product" href={resolve(product.route)} data-product={product.id}>
					<img src={asset(product.icon)} alt="" width="64" height="64" />
					<span class="product-name">{product.name}</span>
					<span class="product-summary">{product.summary}</span>
					<span class="product-link">Découvrir →</span>
				</a>
			</li>
		{/each}
	</ul>
</main>

<style>
	/* The site's main rule sizes text pages; the home page sets its own measure. */
	#accueil {
		margin: 0 auto;
		max-width: 1100px;
		padding: 2rem 16px 4rem;
		width: auto;
	}

	.accueil-title {
		font-size: clamp(2.5rem, 7vw, 4.5rem);
		margin: 0;
		text-align: center;
	}

	.accueil-tagline {
		font-size: 1.25rem;
		margin: 0.25rem 0 1.5rem;
		text-align: center;
	}

	.accueil-naming {
		margin: 0 auto 2rem;
		/* At most 80 characters per line (WCAG 1.4.8). */
		max-width: min(760px, 58ch);
		text-align: center;
	}

	/* As many columns as fit cards at least 16rem wide: the rem follows the
	   text size, so at 200 % text the cards stack instead of overflowing the
	   page, which clipped their names (site-reading.cjs). */
	.products {
		display: grid;
		gap: 1rem;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, 16rem), 1fr));
		list-style: none;
		margin: 0;
		padding: 0;
	}

	.products li {
		margin: 0;
	}

	.product {
		align-items: center;
		background: rgba(0, 0, 0, 0.45);
		border: 1px solid rgba(255, 255, 255, 0.12);
		border-radius: 12px;
		color: white;
		display: flex;
		flex-direction: column;
		gap: 0.6rem;
		height: 100%;
		padding: 1.5rem 1.25rem;
		text-align: center;
		text-decoration: none;
		transition:
			border-color 0.15s ease-out,
			transform 0.15s ease-out;
	}

	.product:hover,
	.product:focus-visible {
		border-color: rgba(255, 255, 255, 0.45);
		transform: translateY(-2px);
	}

	.product img {
		height: 64px;
		width: 64px;
	}

	.product-name {
		font-size: 1.35rem;
		font-weight: bold;
	}

	.product-summary {
		flex-grow: 1;
		line-height: 1.4;
	}

	.product-link {
		color: #5ccbff;
		font-weight: bold;
	}

	@media (prefers-reduced-motion: reduce) {
		.product {
			transition: none;
		}
	}
</style>
