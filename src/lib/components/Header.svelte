<script>
	import Ergopti from '../components/Ergopti.svelte';
	import ErgoptiPlus from '../components/ErgoptiPlus.svelte';

	import { page } from '$app/stores';

	import { getKeyboardData } from '$lib/keyboard/data/getKeyboardData.js';
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

	function closeMenu() {
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

		// Si le menu est ouvert et que la largeur de l'écran est inférieure ou égale à 1280px
		if (menuBtn.checked && siteWidth <= 1280) {
			document.body.style.overflowY = 'hidden';
		} else {
			document.body.style.overflowY = 'visible';
		}

		// Changement de l'emplacement du menu de la page selon qu’on soit sur pc ou mobile
		if (siteWidth <= 1280) {
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
	<div id="ergopti-header">
		<a href="/" aria-label="Accéder à la page d’accueil">
			<img src="img/logo/logo.svg" class="logo" alt="Logo Ergopti" />
		</a>
		<div id="ergopti-title">
			<strong>
				<a class="no-gradient text-white" href="/">
					Disposition <span class="morespace">clavier </span>
				</a>
				<a href="/" aria-label="Accéder à la page d’accueil">
					<Ergopti></Ergopti>
				</a>
				<select
					id="version-selection"
					bind:value={versionValue}
					onchange={handleVersionChange}
					data-version={versionValue}
				>
					{#each versionsList as value}<option {value}>{value}</option>{/each}
				</select>
				<a
					href="/informations/#changelog"
					aria-label="Accéder à la page d’accueil"
					style="position:relative; left:-0.1em; top:-0.65em; font-size:0.8em"
				>
					<i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i>
				</a>
			</strong>
			<p id="ergopti-subtitle">
				<strong class="hyper" style="font-size:1.1em">Ergonomie optimisée</strong>
				<span class="morespace2"> pour le français, l’anglais et le code</span>
			</p>
		</div>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" onclick={toggleOverflowMenu} />
	<label class="menu-icon" for="menu-btn"><span class="navicon"></span></label>
	<nav id="menu">
		<div id="menu-pages">
			<a
				href="/"
				onclick={closeMenu}
				aria-label="Accéder à la page Ergopti"
				aria-current={$page.url.pathname === '/' ? 'page' : undefined}
			>
				<i class="icon-keyboard-duotone"><span class="path1"></span><span class="path2"></span></i>
				<span class="title">Ergopti</span>
			</a>
			<a
				href="/ergopti-plus"
				onclick={closeMenu}
				aria-label="Accéder à la page Ergopti+"
				aria-current={$page.url.pathname === '/ergopti-plus' ? 'page' : undefined}
			>
				<i class="icon-circle-star">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title" style="position:relative; top:-2px; right:1px"
					>Ergopti<span class="glow">+</span></span
				></a
			>
			<a
				href="/benchmarks"
				onclick={closeMenu}
				aria-label="Accéder à la page Benchmarks"
				aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
			>
				<i class="icon-chart-mixed" style="position:relative; right:2px; top:-2px"
					><span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title">Benchmarks</span></a
			>
			<a
				href="/telechargements"
				onclick={closeMenu}
				aria-label="Accéder à la page Téléchargements"
				aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
			>
				<i class="icon-download"><span class="path1"></span><span class="path2"></span></i>
				<span class="title">Téléchargements</span></a
			>
			<a
				href="/informations"
				onclick={closeMenu}
				aria-current={$page.url.pathname === '/informations' ? 'page' : undefined}
				aria-label="Accéder à la page Informations"
			>
				<i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i>
				<span class="title">Informations</span></a
			>
		</div>
		<div id="menu-page-content">
			<p id="menu-page-content-title">Contenu de la page</p>
			<hr />
			<br />
			<div
				id="page-toc-mobile"
				onclick={closeMenu}
				aria-label="Ouvrir le lien et fermer le menu"
			></div>
			<div style="height:70px"></div>
			<div class="links">
				<a href="https://github.com/adrienm7/ergopti" style="font-size:1em!important">
					Repo GitHub <i class="icon-github"></i>
				</a>
				<span> — </span>
				<a href={discordLink} style="position:relative; bottom:-0.1em; font-size:1em!important">
					Serveur Discord
					<i class="icon-discord"></i>
				</a>
			</div>
			<div style="height:70px"></div>
		</div>
	</nav>
</header>
<div style="height: var(--header-height);"></div>

<style>
	:root {
		--header-color: rgba(0, 0, 0, 0.9);
		--header-color-mobile: rgba(0, 16, 36, 0.975);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--espacement-items-menu: clamp(5px, 1vw, 50px);
		--couleur-ombre: rgba(200, 233, 255, 0.4);
		--marge-fenetre: var(--marge-bords-menu);
		--header-height: clamp(70px, 5.5vw, 120px);
		--couleur-icone-hamburger: white;
		--marge-bords-menu: clamp(15px, 2vw, 50px);
		--longueur-traits-hamburger: 18px;
	}

	header {
		align-items: center;
		backdrop-filter: blur(30px);
		background-color: var(--header-color);
		box-shadow: 0px 0px 6px 3px var(--couleur-ombre);
		display: flex;
		height: var(--header-height);
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

	.links {
		text-align: center;
	}
	.links a {
		display: inline !important;
	}

	/*
=============================
======= Ergopti title =======
=============================
*/

	#ergopti-header {
		align-items: center;
		display: flex;
		margin-left: calc(0.125 * var(--header-height));
	}

	#ergopti-header .logo {
		height: calc(0.85 * var(--header-height));
		margin-top: calc(0.05 * var(--header-height));
	}

	#ergopti-header #ergopti-title {
		margin-left: calc(0.125 * var(--header-height));
	}

	#ergopti-header #ergopti-subtitle {
		font-size: 0.85em;
		margin: 0;
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

	#version-selection {
		border: 1px solid rgb(0, 129, 194);
		border-radius: 5px;
		color: white;
		margin: 0;
		margin-bottom: -4px;
		padding: 4px;
		padding-bottom: 2px;
		padding-top: 1px;
	}

	#version-selection option {
		background-color: black;
		color: white;
		font-style: normal;
		font-weight: normal;
	}

	/*
==========================
======= Menu style =======
==========================
*/

	header .menu-btn {
		display: none;
	}

	#menu-pages a:not([aria-current='page']) .title:hover {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(var(--gradient-blue));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	#menu-pages a[aria-current='page'] .title {
		line-height: 1.3; /* Opthewrwise, the gradient is cut */
	}

	#menu-pages a[aria-current='page'] .title,
	#menu-pages a[aria-current='page'] i .path1::before,
	#menu-pages a[aria-current='page'] i .path2::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(var(--gradient-purple));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	#menu-pages a[aria-current='page'] i .path1::before {
		background-image: linear-gradient(var(--gradient-purple-dark));
	}

	/* Menu mobile */
	@media (max-width: 1280px) {
		#menu {
			backdrop-filter: blur(30px);
			background-color: var(--header-color-mobile);
			border-top: 1px solid rgba(255, 255, 255, 0.2);
			left: 0;
			margin: 0;
			overflow: hidden;
			padding: 0;
			position: fixed;
			top: var(--header-height);
			transition: height 0.15s ease-out; /* Effet de déroulement du menu vers le bas si passage de height 0 à 100 */
			width: 100%;
			z-index: 98;
		}

		#menu-pages a {
			border-bottom: 1px solid rgba(255, 255, 255, 0.2);
			display: block;
			line-height: 1em;
			padding: var(--hauteur-element-menu-mobile) 0;
			padding-left: var(--marge-fenetre);
			text-decoration: none;
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
			height: calc(100vh - var(--header-height));
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

	/* Menu on large screens */
	@media (min-width: 1280px) {
		#menu-pages {
			display: flex;
			padding-right: var(--marge-bords-menu);
		}

		#menu-pages a {
			align-items: center;
			display: flex;
			height: var(--header-height);
			padding-left: calc(2 * var(--espacement-items-menu) + 5px);
		}
		#menu-pages a .title {
			font-size: 1rem;
			text-align: center; /* Dans le cas où le texte passe sur deux lignes car trop long */
		}

		#menu-pages a i {
			margin-right: 5px;
		}

		#menu-pages a:not(:last-child)::after {
			background-color: transparent;
			box-shadow: 2px 0 2px 0px var(--couleur-ombre);
			content: '';
			height: 100%;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			width: 5px;
		}

		/* Underline selected page */
		/* #menu-pages a[aria-current='page'] a::after {
			background-image: linear-gradient(var(--gradient-purple));
			border-radius: 5px;
			bottom: -5px;
			content: '';
			display: block;
			height: 3px;
			position: relative;
			width: 100%;
		} */

		/* #menu-pages a:not([aria-current='page']) .title:hover::after {
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

	#menu-page-content-title {
		font-weight: bold;
		padding-bottom: 5px;
		padding-top: 30px;
		text-align: center;
	}
</style>
