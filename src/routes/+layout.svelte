<script>
	import Header from '../composants/Header.svelte';
	import Footer from '../composants/Footer.svelte';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/espacements.css';
	import '$lib/css/typography.css';
	import '$lib/css/buttons.css';
	import '$lib/css/miscellaneous.css';

	import Clavier from '../composants/Clavier.svelte';
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';
	import { onMount } from 'svelte';
	import Controles_Clavier from '../composants/Controles_Clavier.svelte';

	let typeClavier = 'iso';
	let couche = 'Visuel';
	let couleur = 'oui';
	let plus = false;

	onMount(() => {
		majClavier({
			emplacement: 'clavier-reference',
			data: hypertexte,
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur,
				plus: plus
			}
		});
	});

	let zIndex = -999;

	function toggleZIndex() {
		zIndex = zIndex === -999 ? 100 : -999;
		document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<button id="afficher-clavier-reference" on:click={toggleZIndex}>⌨</button>

<div id="clavier" style="z-index: {zIndex};">
	<div>
		<bloc-clavier id="clavier-reference">
			<Clavier />
		</bloc-clavier>
		<petit-espace />
		<Controles_Clavier emplacement={'clavier-reference'} />
	</div>
</div>

<div id="page">
	<Header />

	<main>
		<slot />
	</main>

	<Footer />
</div>

<style>
	#clavier {
		position: fixed;
		bottom: 0;
		left: 50%;
		transform: translate(-50%, 0);
		width: 100vw;
		height: calc(100vh - var(--hauteur-header));
		overflow: scroll;
		transition: all 0.2s ease-in-out;
		overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu */
		--couleur: 80;
		background: linear-gradient(
			90deg,
			rgba(0, 0, var(--couleur), 1) 0%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 10%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 20%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 30%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 40%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 50%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 60%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 70%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 80%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 90%,
			rgba(0, 0, var(--couleur), 1) 100%
		);
	}

	#clavier div {
		--marge: 10vh;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-direction: column;
		min-height: calc(100vh - var(--hauteur-header) + 1px - 2 * var(--marge));
		padding: var(--marge) 0;
	}
	#afficher-clavier-reference {
		position: fixed;
		z-index: 999;
		bottom: 20px;
		right: 20px;
		padding: 10px;
	}
	/* Permet de toujours placer le footer en bas de la page */

	/* « Je vous conseille fortement d’utiliser un conteneur global, comme ici avec #page, pour réaliser ce genre de mise en page.
 * En effet, définir un contexte flex directement sur <body> comme on peut le voir sur d’autres d’articles peut causer des problèmes avec les plugins
 * qui créent des éléments en bas de page avant </body> (popup, autocomplete, etc.).
 * Ces éléments risquent de ne pas s’afficher correctement, à cause du contexte flex hérité. Just saying. »
 */

	#page {
		--couleur: 80;
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		min-height: 100vh;
		background: linear-gradient(
			90deg,
			rgba(0, 0, var(--couleur), 1) 0%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 10%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 20%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 30%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 40%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 50%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 60%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 70%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 80%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 90%,
			rgba(0, 0, var(--couleur), 1) 100%
		);
		color: white;
	}

	@media (max-width: 800px) {
		#page {
			--couleur: 150;
			background: linear-gradient(
				90deg,
				rgba(0, 0, calc(var(--couleur) / 3), 1) 0%,
				rgba(0, 0, calc(var(--couleur) / 4), 1) 50%,
				rgba(0, 0, calc(var(--couleur) / 3), 1) 100%
			);
		}
	}

	main {
		flex-grow: 1;
		margin-top: var(--hauteur-header); /* Pour que le contenu soit en-dessous du header */
	}
</style>
