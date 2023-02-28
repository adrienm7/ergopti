<script>
	import Header from '$lib/composants/Header.svelte';
	import Footer from '$lib/composants/Footer.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import { typography } from '$lib/js/typography.js';
	import { matomo } from '$lib/js/code-matomo.js';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/espacements.css';
	import '$lib/css/typography.css';
	import '$lib/css/titres.css';
	import '$lib/css/hypertexte_plus.css';
	import '$lib/css/buttons.css';
	import '$lib/css/accordion.css';
	import '$lib/css/miscellaneous.css';

	import { onMount } from 'svelte';

	onMount(async () => {
		typography();
		// matomo();
		var _paq = window._paq || [];
		/* tracker methods like "setCustomDimension" should be called before "trackPageView" */
		_paq.push(['trackPageView']);
		_paq.push(['enableLinkTracking']);
		(function () {
			var u = 'https://stats.beseven.fr/';
			_paq.push(['setTrackerUrl', u + 'm.php']);
			_paq.push(['setSiteId', '6']);
			var d = document,
				g = d.createElement('script'),
				s = d.getElementsByTagName('script')[0];
			g.type = 'text/javascript';
			g.async = true;
			g.defer = true;
			g.src = u + 'm.js';
			s.parentNode.insertBefore(g, s);
		})();
	});

	let zIndex = -999;
	let affiche = 'none';

	function toggleZIndex() {
		zIndex = zIndex === -999 ? 99 : -999;
		affiche = affiche === 'none' ? 'block' : 'none';
		// document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<button id="afficher-clavier-reference" on:click={toggleZIndex}>⌨</button>

<div id="clavier-ref" class="bg-blue" style="z-index: {zIndex}; display:{affiche}">
	<div>
		<EnsembleClavier
			emplacement={'clavier-reference'}
			type={'iso'}
			couche={'Visuel'}
			couleur={'oui'}
			plus={'non'}
			controles={'oui'}
		/>
	</div>
</div>

<div id="page" class="bg-blue">
	<Header />

	<main>
		<slot />
	</main>

	<Footer />
</div>

<style>
	#afficher-clavier-reference {
		position: fixed;
		z-index: 101;
		bottom: 1rem;
		right: 1rem;
		padding: 12px;
		cursor: pointer;
		border: 1px solid rgba(0, 0, 0, 0.5);
		border-radius: 5px;
		font-size: 1.5rem;
		box-shadow: rgba(0, 0, 0, 0.24) 0px 3px 8px;
	}

	#clavier-ref {
		--couleur: 60;
		position: fixed;
		bottom: 0;
		left: 50%;
		transform: translate(-50%, 0);
		width: 100vw;
		height: 100vh;
		height: calc(100vh - var(--hauteur-header));
		overflow: scroll;
		transition: all 0.2s ease-in-out;
		overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu */
	}

	#clavier-ref div {
		/* Permet d’avoir une div qui ne scrolle pas ce qui est dessous */
		--marge: 10vh;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-direction: column;
		height: calc(100vh + 1px);
		height: calc(100vh - var(--hauteur-header) + 1px);
		padding: var(--marge) 0;
	}

	/* Le code ci-dessous permet de toujours placer le footer en bas de la page */

	/* « Je vous conseille fortement d’utiliser un conteneur global, comme ici avec #page, pour réaliser ce genre de mise en page.
 * En effet, définir un contexte flex directement sur <body> comme on peut le voir sur d’autres d’articles peut causer des problèmes avec les plugins
 * qui créent des éléments en bas de page avant </body> (popup, autocomplete, etc.).
 * Ces éléments risquent de ne pas s’afficher correctement, à cause du contexte flex hérité. Just saying. »
 */
	#page {
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		min-height: 100vh;
		color: white; /* Couleur par défaut du texte */
	}
	main {
		flex-grow: 1;
		margin-top: var(--hauteur-header); /* Pour que le contenu soit en-dessous du header */
	}
</style>
