<script>
	import Header from '$lib/components/Header.svelte';
	import Footer from '$lib/components/Footer.svelte';

	import IntroductionDisposition from './accueil/introduction_ergopti.svelte';
	import IntroductionDispositionPlus from './ergopti-plus/introduction_ergopti_plus.svelte';
	import IntroductionBenchmarks from './benchmarks/introduction_benchmarks.svelte';
	import IntroductionTelechargements from './telechargements/introduction_telechargements.svelte';
	import IntroductionInformations from './informations/introduction_informations.svelte';
	import DispositionPlus from './accueil/ergopti_plus.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';

	import 'modern-normalize';

	import { afterUpdate, onMount } from 'svelte';
	import { page } from '$app/stores';
	import AOS from 'aos';
	import 'aos/dist/aos.css';
	import { makeIds } from '$lib/js/make-ids.js';
	import tocbot from 'tocbot';

	import '$lib/css/global.css';
	import '$lib/css/layout.css';
	import '$lib/css/cards.css';
	import '$lib/css/espacements.css';
	import '$lib/css/titles.css';
	import '$lib/css/typographie.css';
	import '$lib/css/nom.css';
	import '$lib/css/images.css';
	import '$lib/css/buttons.css';
	import '$lib/css/tocbot.css';

	import '$lib/icons/icomoon/style.css';

	onMount(() => {
		tocbot.init({
			// Where to render the table of contents.
			tocSelector: '#page-toc',
			// Where to grab the headings to build the table of contents.
			contentSelector: 'main',
			// Which headings to grab inside of the contentSelector element.
			headingSelector: 'h2, h3, h4, h5, h6',
			// For headings inside relative or absolute positioned containers within content.
			hasInnerContainers: true,
			// Prend en compte la hauteur du header pour le scroll
			headingsOffset: 120,
			scrollSmoothOffset: -120,
			scrollSmoothDuration: 300,
			orderedList: false
		});
	});

	afterUpdate(() => {
		makeIds(document.getElementById('main-content'));
		document.querySelectorAll('h2').forEach(function (h2) {
			h2.setAttribute('data-aos', 'zoom-out');
		});
		document.querySelectorAll('h3').forEach(function (h3) {
			h3.setAttribute('data-aos', 'fade-right');
		});

		AOS.init({ mirror: true, offset: 0, anchorPlacement: 'top-bottom' });
		typography(document.getElementsByTagName('main')[0]);
		tocbot.refresh();
	});

	let zIndex = -999;
	let affiche = 'none';
	function toggleZIndex() {
		zIndex = zIndex === -999 ? 80 : -999;
		affiche = affiche === 'none' ? 'block' : 'none';
		// document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<bloc-page id="page" class="bg-blue">
	<div style="flex-grow:1">
		<Header />
		<bloc-introduction>
			{#if $page.url.pathname === '/'}
				<IntroductionDisposition></IntroductionDisposition>
			{/if}
			{#if $page.url.pathname === '/ergopti-plus'}
				<IntroductionDispositionPlus></IntroductionDispositionPlus>
			{/if}
			{#if $page.url.pathname === '/benchmarks'}
				<IntroductionBenchmarks></IntroductionBenchmarks>
			{/if}
			{#if $page.url.pathname === '/telechargements'}
				<IntroductionTelechargements></IntroductionTelechargements>
			{/if}
			{#if $page.url.pathname === '/informations'}
				<IntroductionInformations></IntroductionInformations>
			{/if}
		</bloc-introduction>
		<bloc-main>
			<aside id="sidebar">
				<div>
					<p style="text-align:center; color:white; margin:0; padding:0; font-weight: bold">
						Contenu de la page
					</p>
					<div id="page-toc-pc">
						<div id="page-toc"></div>
					</div>
					<p style="text-align:center; margin: 0; margin-top: 1em; margin-bottom: 0.5em;">
						<a
							href="https://github.com/adrienm7/ergopti"
							style="font-size:0.9em!important; color:white"
							>Repo GitHub <i class="icon-github"></i></a
						>
						—
						<a
							href="https://discord.gg/ptxRzBqcQP"
							style="position:relative; bottom:-0.1em; font-size:0.9em!important; color:white"
							>Serveur Discord <i class="icon-discord"></i></a
						>
					</p>
				</div>
			</aside>
			<div id="main-content">
				<main>
					<slot />
				</main>
			</div>
		</bloc-main>
		<bloc-fin>
			{#if $page.url.pathname === '/'}
				<DispositionPlus></DispositionPlus>
			{/if}
		</bloc-fin>
	</div>
	<Footer />
</bloc-page>

<bloc-clavier-reference>
	<button id="afficher-clavier-reference" on:click={toggleZIndex}>
		<i class="icon-keyboard-duotone" style="display:{affiche === 'none' ? 'block' : 'none'}"
			><span class="path1"></span><span class="path2"></span></i
		>
		<i class="icon-square-xmark" style="display:{affiche}"
			><span class="path1"></span><span class="path2"></span></i
		>
	</button>

	<clavier-reference id="clavier-ref" class="bg-blue" style="z-index: {zIndex}; display:{affiche}">
		<div class="conteneur">
			<BlocClavier nom="reference" />
			<mini-espace />
			<BlocControlesClavier nom="reference" />
		</div>
	</clavier-reference>
</bloc-clavier-reference>

<!-- <div class="banner">
	<p>En construction</p>
</div> -->

<style>
	#afficher-clavier-reference {
		position: fixed;
		right: 1rem;
		bottom: 1rem;
		z-index: 99;
		animation: glowing 3s infinite alternate ease-in-out;
		cursor: pointer;
		margin: 0 auto;
		box-shadow: 0px 0px 7px 3px #0087b4b1;
		border: 1px solid rgba(0, 0, 0, 0.5);
		border-radius: 5px;
		background-color: rgba(0, 1, 14, 0.9);
		padding: 0.5rem;
		width: 3rem;
		height: 3rem;
		font-size: 1.5rem;
	}

	@keyframes glowing {
		0% {
			box-shadow: 0px 0px 1px 1px #0087b4b1;
		}
		70% {
			box-shadow: 0px 0px 1px 1px #0087b4b1;
		}
		100% {
			box-shadow: 0px 0px 20px 7px #0087b4b1;
		}
	}

	#afficher-clavier-reference i {
		color: #3088ed;
	}
	#afficher-clavier-reference i::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
		color: transparent;
	}

	clavier-reference {
		--couleur: 60;
		position: fixed;
		bottom: 0;
		left: 0;
		transition: all 0.2s ease-in-out;
		padding-top: var(--hauteur-header);
		width: 100vw;
		height: 100vh;
		overflow: scroll;
		overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu */
	}

	clavier-reference .conteneur {
		/* Permet d’avoir une div qui ne scrolle pas ce qui est dessous */
		--marge: 10vh;
		display: flex;
		flex-direction: column;
		justify-content: center;
		align-items: center;
		margin: var(--marge) 0;
		min-height: calc(100vh - var(--hauteur-header) - 2 * var(--marge) + 1px);
	}
</style>
