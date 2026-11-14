<!-- src/routes/accueil/projet_ergopti.svelte -->

<!--
==============================================================================
MODULE: Ergopti Project Overview
DESCRIPTION:
Short section at the top of the home page presenting Ergopti as the whole
project (optimising keyboard typing) and linking to its three products: the
Disposition Ergopti layout featured below, the Ergopti+ software and the
Ergopti Studio layout editor.
==============================================================================
-->

<script>
	import { resolve } from '$app/paths';

	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
</script>

<section id="projet-ergopti" aria-labelledby="projet-ergopti-titre">
	<h2 id="projet-ergopti-titre" class="projet-ergopti-title">
		Le projet <Ergopti />
	</h2>
	<p class="encart-introduction">
		<strong><Ergopti /></strong> est un projet pour <strong>optimiser la frappe au clavier</strong>,
		en trois produits complémentaires&nbsp;:
	</p>
	<div class="cards projet-ergopti-cards">
		<a class="card" href="#debut" data-product="disposition">
			<i class="icon-keyboard-duotone"><span class="path1"></span><span class="path2"></span></i>
			<strong>Disposition <Ergopti /></strong>&nbsp;: la disposition clavier ergonomique pour le
			français, l’anglais et le code, présentée sur cette page.
		</a>
		<a class="card" href={resolve('/ergopti-plus')} data-product="ergopti-plus">
			<i class="icon-circle-star"><span class="path1"></span><span class="path2"></span></i>
			<strong><ErgoptiPlus /></strong>&nbsp;: le logiciel qui accélère la frappe avec hotstrings,
			tap-holds et IA.
		</a>
		<a class="card" href={resolve('/studio')} data-product="studio">
			<i class="icon-keyboard-duotone"><span class="path1"></span><span class="path2"></span></i>
			<strong><Ergopti /> Studio</strong>&nbsp;: l’éditeur pour créer, modifier et exporter sa
			propre disposition.
		</a>
	</div>
	<tiny-space></tiny-space>
</section>

<style>
	/* The global h2 opens a page section with a third of a screen above it;
	   this overview must stay short so the layout below remains the feature. */
	.projet-ergopti-title {
		margin-bottom: 0.5rem;
		margin-top: 1.5rem;
	}

	#projet-ergopti .encart-introduction {
		margin-top: 0;
	}

	.projet-ergopti-cards .card {
		text-decoration: none;
		transition: transform 0.15s ease-out;
	}

	.projet-ergopti-cards .card:hover,
	.projet-ergopti-cards .card:focus-visible {
		transform: translateY(-2px);
	}

	@media (prefers-reduced-motion: reduce) {
		.projet-ergopti-cards .card {
			transition: none;
		}
	}
</style>
