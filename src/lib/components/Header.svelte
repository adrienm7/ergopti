<script>
	import Ergopti from '../components/Ergopti.svelte';
	import ErgoptiPlus from '../components/ErgoptiPlus.svelte';

	import { page } from '$app/stores';

	import { getKeyboardData } from '$lib/keyboard/getKeyboardData.js';
	import { version, layoutData, versionsList, discordLink } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	function handleVersionChange() {
		getKeyboardData(versionValue)
			.then((data) => {
				layoutData.set(data);
				version.set(versionValue); // Utiliser `set` pour mettre à jour la version dans le store
				// console.log('Données chargées :', data);
			})
			.catch((error) => {
				console.error('Erreur lors du chargement des données :', error);
			});
	}
	handleVersionChange();

	function fermerMenu() {
		document.getElementById('menu-btn').checked = false;
		document.getElementById('clavier-ref').style.zIndex =
			'-999'; /* Si le clavier était ouvert, on le ferme */
		document.body.style.overflowY = 'visible';
	}

	function toggleOverflowMenu() {
		const menuBtn = document.getElementById('menu-btn');
		const siteWidth = document.documentElement.clientWidth;
		const toc = document.querySelector('#page-toc');
		const tocPc = document.querySelector('#page-toc-pc');
		const tocMobile = document.querySelector('#page-toc-mobile');

		// Si le menu est ouvert et que la largeur de l'écran est inférieure ou égale à 1400px
		if (menuBtn.checked && siteWidth <= 1400) {
			document.body.style.overflowY = 'hidden';
		} else {
			document.body.style.overflowY = 'visible';
		}

		// Changement de l'emplacement du menu de la page selon qu’on soit sur pc ou mobile
		if (siteWidth <= 1400) {
			tocMobile.appendChild(toc);
		} else {
			tocPc.appendChild(toc);
		}
	}

	// Exécuter la fonction après la mise à jour et au redimensionnement
	$effect(() => {
		toggleOverflowMenu();
		window.addEventListener('resize', toggleOverflowMenu);
	});
</script>

<header>
	<div class="header-logo">
		<a href="/"><img src="img/logo/logo.svg" class="logo" /></a>
		<div style="margin:0; margin-left: 0.5em; padding:0; text-align: left; width:max-content">
			<strong style="margin:0;">
				<a class="no-gradient text-white" href="/"
					>Disposition <span class="morespace">clavier </span></a
				>
				<span style="display:inline-block;"
					><a href="/"><Ergopti></Ergopti></a>
					<span class="myselect">
						<select
							id="selection-version"
							bind:value={versionValue}
							onchange={handleVersionChange}
							data-version={versionValue}
						>
							{#each versionsList.reverse() as value}<option {value}>{value}</option>{/each}
						</select>
					</span></span
				>
				<a
					href="/informations/#changelog"
					style="position:relative; left:-0.1em; top:-0.65em; font-size:0.8em"
					><i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i></a
				>
			</strong>
			<p style="margin:0; padding-top: 0; padding-left: 0; font-size: 0.8em">
				<strong class="hyper" style="font-size:1.1em">Ergonomie optimisée</strong>
				<span class="morespace2" style="color:white;"> pour le français, l’anglais et le code</span>
			</p>
		</div>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" onclick={toggleOverflowMenu} />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<nav id="menu">
		<div id="menu-pages">
			<p aria-current={$page.url.pathname === '/' ? 'page' : undefined} onclick={fermerMenu}>
				<a href="/"
					><i class="icon-keyboard-duotone"
						><span class="path1"></span><span class="path2"></span></i
					>
					<span class="titre">Ergopti</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/ergopti-plus' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/ergopti-plus"
					><i class="icon-circle-star"><span class="path1"></span><span class="path2"></span></i>
					<span class="titre">Ergopti<span class="glow">+</span></span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/benchmarks"
					><span class="couleur"
						><i class="icon-chart-mixed"><span class="path1"></span><span class="path2"></span></i
						></span
					>
					<span class="titre">Benchmarks</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/telechargements"
					><i class="icon-download"><span class="path1"></span><span class="path2"></span></i>
					<span class="titre">Téléchargements</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/informations' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/informations"
					><i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i>
					<span class="titre">Informations</span></a
				>
			</p>
		</div>
		<div id="menu-contenu">
			<p style="text-align:center; font-weight:bold; padding-top: 30px; padding-bottom: 15px;">
				Contenu de la page
			</p>
			<hr />
			<br />
			<div id="page-toc-mobile" onclick={fermerMenu}></div>
			<div style="height:70px"></div>
			<div style="text-align:center;">
				<a href="https://github.com/adrienm7/ergopti" style="font-size:1em!important"
					>Repo GitHub <i class="icon-github"></i></a
				>
				—
				<a href={discordLink} style="position:relative; bottom:-0.1em; font-size:1em!important"
					>Serveur Discord <i class="icon-discord"></i></a
				>
			</div>
			<div style="height:70px"></div>
		</div>
	</nav>
</header>
<div style="height: var(--hauteur-header);"></div>

<style>
	:root {
		--couleur-header: rgba(0, 0, 0, 0.9);
		--couleur-header-mobile: rgba(0, 16, 36, 0.975);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--espacement-items-menu: clamp(5px, 0.45vw, 14px);
		--couleur-ombre: rgba(200, 233, 255, 0.4);
		--marge-fenetre: var(--marge-bords-menu);
		--hauteur-header: clamp(70px, 5.5vw, 120px);
		--couleur-icone-hamburger: white;
		--marge-bords-menu: clamp(15px, 2vw, 50px);
		--longueur-traits-hamburger: 18px;
	}

	.morespace,
	.morespace2 {
		display: none;
	}
	@media (min-width: 400px) {
		.morespace {
			display: inline;
		}
	}
	@media (min-width: 600px) {
		.morespace2 {
			display: inline;
		}
	}

	#selection-version {
		/* -webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit; */
		/* -webkit-appearance: none;
		-moz-appearance: none; */
		background-clip: text;
		border: 1px solid rgb(14, 83, 117);
		border-radius: 5px;
		color: white;
		margin: 0;
		margin-bottom: -4px;
		padding: 0;
		padding: 4px;
		padding-bottom: 2px;
		padding-top: 1px;
		width: 2.6em;
	}

	.myselect {
		/* padding-right: 0.2em; */
		color: white;
		display: inline-block;
		/* background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit; */
		font-weight: normal !important;
		margin: 0;
		padding: 0;
		position: relative;
	}

	/* .myselect::after {
		content: '';
		position: absolute;
		right: 0px;
		top: 0.3em;
		width: 0;
		height: 0;
		border-left: 0.45em solid transparent;
		border-right: 0.45em solid transparent;
		border-top: 0.7em solid rgb(255, 255, 255);
		pointer-events: none;
	} */

	#selection-version option {
		background-color: black;
		color: white;
		font-style: normal;
		font-weight: normal;
	}

	header {
		align-items: center;
		backdrop-filter: blur(30px);
		background-color: var(--couleur-header);
		box-shadow: 0px 0px 6px 3px var(--couleur-ombre);
		display: flex;
		height: var(--hauteur-header);
		justify-content: space-between;
		left: 0;
		margin: 0;
		padding: 0;
		position: fixed;
		top: 0;
		width: 100vw;
		z-index: 100;
	}
	header a {
		color: var(--couleur-liens-header);
		font-size: 1.1rem;
		text-decoration: none;
	}

	header #menu #menu-pages p {
		display: inline-block;
	}

	header #menu #menu-pages p[aria-current='page'] .titre,
	header #menu #menu-pages p:not([aria-current='page']) .titre:hover {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(to right, var(--gradient-blue));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	header .header-logo {
		align-items: center;
		display: inline-flex;
		height: 100%;
		justify-content: center;
		margin-left: clamp(3px, 1vw, 10px);
		/* margin-left: var(--marge-bords-menu); */
	}
	header .menu-btn {
		display: none;
	}

	.logo {
		height: calc(0.85 * var(--hauteur-header));
		margin-top: 3px;
		/*  
		margin-right: 10px;
		padding: 3px;
		background-color: #010017;
		border: 1px solid white;
		border-radius: 10px;
		*/
	}

	/* Menu mobile */
	@media (max-width: 1400px) {
		header #menu {
			backdrop-filter: blur(30px);
			background-color: var(--couleur-header-mobile);
			border-top: 1px solid rgba(255, 255, 255, 0.2);
			left: 0;
			margin: 0;
			overflow: hidden;
			padding: 0;
			position: fixed;
			top: var(--hauteur-header);
			transition: height 0.15s ease-out; /* Effet de déroulement du menu vers le bas si passage de height 0 à 100 */
			width: 100%;
			z-index: 98;
		}

		header #menu p a {
			border-bottom: 1px solid rgba(255, 255, 255, 0.2);
			display: block;
			line-height: 1em;
			padding: var(--hauteur-element-menu-mobile) 0;
			padding-left: var(--marge-fenetre);
			text-decoration: none;
		}
		header #menu p,
		header #menu p a p {
			font-size: 1.1rem;
			line-height: 1em !important;
			margin: 0;
			padding: 0;
			width: 100%;
		}

		/* menu icon */

		header .menu-icon {
			cursor: pointer;
			display: inline-block;
			padding: var(--marge-bords-menu);
			user-select: none;
		}

		header .menu-icon .navicon {
			background: var(--couleur-icone-hamburger);
			display: block;
			height: 2px;
			position: relative;
			transition: background 0.1s ease-out;
			width: var(--longueur-traits-hamburger);
		}

		header .menu-icon .navicon:before,
		header .menu-icon .navicon:after {
			background: var(--couleur-icone-hamburger);
			content: '';
			display: block;
			height: 100%;
			position: absolute;
			transition: all 0.1s ease-out;
			width: 100%;
		}

		header .menu-icon .navicon:before {
			top: 5px; /* Écartement des barres du hamburger */
		}

		header .menu-icon .navicon:after {
			top: -5px; /* Écartement des barres du hamburger */
		}

		/* menu btn */

		header #menu,
		header .menu-btn:not(:checked) ~ #menu {
			height: 0;
		}

		header .menu-btn:checked ~ #menu {
			height: calc(100vh - var(--hauteur-header));
			overflow: scroll;
		}

		header .menu-btn:checked ~ .menu-icon .navicon {
			background: transparent;
		}

		header .menu-btn:checked ~ .menu-icon .navicon:before {
			transform: rotate(-45deg);
		}

		header .menu-btn:checked ~ .menu-icon .navicon:after {
			transform: rotate(45deg);
		}

		header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:before,
		header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:after {
			top: 0;
		}
	}

	/* Menu ordinateur */
	@media (min-width: 1400px) {
		header #menu #menu-pages {
			background-color: transparent;
			border: none;
			display: flex !important;
			flex-direction: row;
			margin: 0;
			padding: 0;
			padding-right: var(--marge-bords-menu);
			z-index: 1;
		}

		header #menu #menu-pages p {
			align-items: center;
			background-color: transparent;
			border-bottom: 0;
			display: flex;
			font-size: 1rem;
			height: var(--hauteur-header);
			justify-content: center;
			margin: 0;
			padding: 0;
			padding-left: calc(2 * var(--espacement-items-menu) + 5px);
		}

		header #menu #menu-pages p:not(:last-child)::after {
			background-color: transparent;
			box-shadow: 2px 0 2px 0px var(--couleur-ombre);
			content: '';
			height: 100%;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			width: 5px;
		}

		header #menu #menu-pages p a {
			padding: calc(2 * var(--espacement-items-menu));
		}
		header #menu #menu-pages p a p {
			text-align: center; /* Dans le cas où le texte passe sur deux lignes car trop long */
		}
		header #menu #menu-pages p:last-child a {
			padding-right: 0;
		}

		header #menu #menu-pages p[aria-current='page'] a::after {
			background-image: linear-gradient(to right, var(--gradient-blue));
			border-radius: 5px;
			bottom: -5px;
			content: '';
			display: block;
			height: 3px;
			position: relative;
			width: 100%;
		}

		/* header #menu #menu-pages p:not([aria-current='page']) .titre:hover::after {
		content: '';
		display: block;
		position: relative;
		bottom: -5px;
		width: 100%;
		height: 3px;
		border-radius: 5px;
		background-image: linear-gradient(to right, var(--gradient-purple));
	} */
	}
</style>
