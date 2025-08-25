<script>
	import Header from '$lib/components/Header.svelte';
	import Footer from '$lib/components/Footer.svelte';

	import IntroductionDisposition from './accueil/introduction_ergopti.svelte';
	import IntroductionDispositionPlus from './ergopti-plus/introduction_ergopti_plus.svelte';
	import IntroductionBenchmarks from './benchmarks/introduction_benchmarks.svelte';
	import IntroductionTelechargements from './telechargements/introduction_telechargements.svelte';
	import IntroductionInformations from './informations/introduction_informations.svelte';
	import DispositionPlus from './accueil/ergopti_plus.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControlButtons from '$lib/keyboard/KeyboardControlButtons.svelte';

	import 'modern-normalize';

	import { afterUpdate, onMount } from 'svelte';
	import { page } from '$app/stores';
	import { discord_link } from '$lib/stores_infos.js';

	import AOS from 'aos';
	import 'aos/dist/aos.css';

	import { makeIds } from '$lib/js/make-ids.js';
	import tocbot from 'tocbot';
	import '$lib/css/tocbot.css';

	import '$lib/css/global.css';
	import '$lib/css/layout.css';
	import '$lib/css/cards.css';
	import '$lib/css/espacements.css';
	import '$lib/css/titles.css';
	import '$lib/css/typographie.css';
	import '$lib/css/ergopti_name.css';
	import '$lib/css/images.css';
	import '$lib/css/buttons.css';

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
							href={discord_link}
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
			<KeyboardBasis nom="reference" />
			<mini-espace />
			<KeyboardControlButtons nom="reference" />
		</div>
	</clavier-reference>
</bloc-clavier-reference>

<!-- <div class="banner">
	<p>En construction</p>
</div> -->

<style>
	#afficher-clavier-reference {
		animation: glowing 3s infinite alternate ease-in-out;
		background-color: rgba(0, 1, 14, 0.9);
		border: 1px solid rgba(0, 0, 0, 0.5);
		border-radius: 5px;
		bottom: 1rem;
		box-shadow: 0px 0px 7px 3px #0087b4b1;
		cursor: pointer;
		font-size: 1.5rem;
		height: 3rem;
		margin: 0 auto;
		padding: 0.5rem;
		position: fixed;
		right: 1rem;
		width: 3rem;
		z-index: 99;
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
		background-image: linear-gradient(to right, var(--gradient-blue));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	clavier-reference {
		--couleur: 60;
		bottom: 0;
		height: 100vh;
		left: 0;
		overflow: scroll;
		overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu */
		padding-top: var(--hauteur-header);
		position: fixed;
		transition: all 0.2s ease-in-out;
		width: 100vw;
	}

	clavier-reference .conteneur {
		/* Permet d’avoir une div qui ne scrolle pas ce qui est dessous */
		--marge: 10vh;
		align-items: center;
		display: flex;
		flex-direction: column;
		justify-content: center;
		margin: var(--marge) 0;
		min-height: calc(100vh - var(--hauteur-header) - 2 * var(--marge) + 1px);
	}
</style>
