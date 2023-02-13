<script>
	import Header from '../composants/Header.svelte';
	import Footer from '../composants/Footer.svelte';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/espacements.css';
	import '$lib/css/typography.css';
	import '$lib/css/buttons.css';
	import '$lib/css/miscellaneous.css';

	import ClavierTest from '../composants/Clavier_Test.svelte';

	let zIndex = -999;

	function toggleZIndex() {
		zIndex = zIndex === -999 ? 100 : -999;
		// document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<button id="afficher-clavier-reference" on:click={toggleZIndex}>⌨</button>

<div id="clavier" class="bg-blue" style="z-index: {zIndex};">
	<div>
		<ClavierTest
			emplacement={'clavier-reference'}
			type={'iso'}
			couche={'Visuel'}
			couleur={'oui'}
			plus={false}
			controles={true}
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
	#clavier {
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

	#clavier div {
		--marge: 10vh;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-direction: column;
		height: calc(100vh + 1px);
		height: calc(100vh - var(--hauteur-header) + 1px);
		padding: var(--marge) 0;
	}
	#afficher-clavier-reference {
		position: fixed;
		z-index: 101;
		bottom: 20px;
		right: 20px;
		padding: 12px;
		cursor: pointer;
		border: 1px solid rgba(0, 0, 0, 0.9);
		border-radius: 6px;
		font-size: 1.3rem;
		box-shadow: rgba(0, 0, 0, 0.24) 0px 3px 8px;
	}

	/* Permet de toujours placer le footer en bas de la page */

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
		color: white;
	}

	main {
		flex-grow: 1;
		margin-top: var(--hauteur-header); /* Pour que le contenu soit en-dessous du header */
	}
</style>
