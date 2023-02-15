<script>
	import { page } from '$app/stores';
	import Nom from '../composants/Nom.svelte';

	function fermerMenu() {
		document.getElementById('menu-btn').checked = false;
		document.getElementById('clavier').style.zIndex =
			'-999'; /* Si le clavier était ouvert, on le ferme */
	}
</script>

<header>
	<div class="logo">
		<a href="/"
			><p class="italic">
				Disposition clavier <span class="hyper"
					>HyperTexte{$page.url.pathname === '/hypertexte-plus' ? '+' : ''}</span
				>
			</p></a
		>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<nav id="menu">
		<ul>
			<li aria-current={$page.url.pathname === '/' ? 'page' : undefined} on:click={fermerMenu}>
				<a href="/"><p>⌨ HyperTexte</p></a>
			</li>
			<li
				aria-current={$page.url.pathname === '/hypertexte-plus' ? 'page' : undefined}
				on:click={fermerMenu}
			>
				<a href="/hypertexte-plus"><p>★ HyperTexte<span class="glow">+</span></p></a>
			</li>
			<li
				aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
				on:click={fermerMenu}
			>
				<a href="/benchmarks"><p>⚑ Benchmarks</p></a>
			</li>
			<li
				aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
				on:click={fermerMenu}
			>
				<a href="/telechargements"><p>❖ Téléchargements</p></a>
			</li>
			<li
				aria-current={$page.url.pathname === '/contact' ? 'page' : undefined}
				on:click={fermerMenu}
			>
				<a href="/contact"><p>➜ Contact</p></a>
			</li>
		</ul>
	</nav>
</header>

<style>
	:root {
		--couleur-header: rgba(0, 0, 0, 0.8);
		--couleur-header-mobile: rgba(0, 0, 0, 0.3);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--espacement-items-menu: 5px;
		--couleur-ombre: rgba(255, 255, 255, 0.3);
		--marge-fenetre: var(--marge-bords-menu);
		--hauteur-header: 70px; /* Fallback si clamp n'est pas supporté */
		--couleur-icone-hamburger: white;
		--marge-bords-menu: 20px;
		--longueur-traits-hamburger: 18px;
	}

	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		position: fixed;
		top: 0;
		left: 0;
		z-index: 99;
		height: var(--hauteur-header);
		width: 100vw;
		margin: 0;
		padding: 0;
		background-color: var(--couleur-header);
		backdrop-filter: blur(30px);
		box-shadow: 0px 0px 5px 1px var(--couleur-ombre);
	}
	header a {
		color: var(--couleur-liens-header);
		text-decoration: none;
	}

	header #menu li a p {
		font-size: 20px;
	}

	header #menu li a p::first-letter {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	header #menu li[aria-current='page'] a p::first-letter {
		background-image: linear-gradient(to right, var(--gradient-purple));
	}

	header #menu li[aria-current='page'] a p {
		/* background-color: #f4f4f4;
			color: black !important;
			border-radius: 3px; */
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-purple));
	}
	/* header #menu li[aria-current='page'] a::after {
		content: '';
		display: block;
		position: relative;
		bottom: -5px;
		width: 100%;
		height: 3px;
		border-radius: 5px;
		background-image: linear-gradient(to right, var(--gradient-blue));
	} */

	header #menu li:not([aria-current='page']) a:hover p {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	/* header #menu li:not([aria-current='page']) a:hover::after {
		content: '';
		display: block;
		position: relative;
		bottom: -5px;
		width: 100%;
		height: 3px;
		border-radius: 5px;
		background-image: linear-gradient(to right, var(--gradient-purple));
	} */

	header .logo {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		margin-left: var(--marge-bords-menu);
	}
	header .logo p {
		display: inline;
		font-family: 'Times New Roman', Times, serif;
	}

	header .menu-btn {
		display: none;
	}

	@media (max-width: 1200px) {
		header #menu {
			position: fixed;
			top: var(--hauteur-header);
			left: 0;
			width: 100%;
			margin: 0;
			padding: 0;
			background-color: var(--couleur-header-mobile);
			backdrop-filter: blur(30px);
			border-top: 1px solid rgba(255, 255, 255, 0.2);
			overflow: scroll; /* Pour désactiver le scroll derrière le menu (1/3) */
			overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu (2/3) */
			transition: height 0.25s ease-out; /* Effet de déroulement du menu vers le bas si passage de height 0 à 100 */
		}

		header #menu ul {
			margin: 0;
			padding: 0;
			list-style: none;
			overflow: hidden;
		}

		header #menu ul li a {
			display: block;
			padding: var(--hauteur-element-menu-mobile) 0;
			padding-left: var(--marge-fenetre);
			text-decoration: none;
			font-size: 1.5rem;
			border-bottom: 1px solid rgba(255, 255, 255, 0.2);
		}
		header #menu ul li,
		header #menu ul li a p {
			margin: 0;
			padding: 0;
		}

		/* menu icon */

		header .menu-icon {
			display: inline-block;
			padding: var(--marge-bords-menu);
			cursor: pointer;
			user-select: none;
		}

		header .menu-icon .navicon {
			display: block;
			position: relative;
			width: var(--longueur-traits-hamburger);
			height: 2px;
			transition: background 0.2s ease-out;
			background: var(--couleur-icone-hamburger);
		}

		header .menu-icon .navicon:before,
		header .menu-icon .navicon:after {
			background: var(--couleur-icone-hamburger);
			content: '';
			display: block;
			height: 100%;
			position: absolute;
			transition: all 0.2s ease-out;
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
		}
		header .menu-btn:checked ~ #menu ul {
			min-height: calc(
				100vh - var(--hauteur-header)
			); /* Pour désactiver le scroll derrière le menu (3/3) */
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

	@media (min-width: 1200px) {
		header #menu {
			display: block;
		}
		header #menu ul {
			display: flex !important;
			flex-direction: row;
			background-color: transparent;
			z-index: 1;
			border: none;
			margin: 0;
			padding: 0;
			padding-right: 40px;
		}

		header #menu ul li {
			display: flex;
			justify-content: center;
			align-items: center;
			height: var(--hauteur-header);
			margin: 0;
			padding: 0;
			padding-left: calc(2 * var(--espacement-items-menu) + 5px);
			background-color: transparent;
			border-bottom: 0;
			font-size: 1rem;
		}

		header #menu li:not(:last-child)::after {
			content: '';
			background-color: transparent;
			height: 100%;
			width: 5px;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			box-shadow: 2px 0 1px 0px var(--couleur-ombre);
		}

		header #menu li a {
			padding: calc(2 * var(--espacement-items-menu));
		}
		header #menu li a p {
			text-align: center; /* Dans le cas où le texte passe sur deux lignes car trop long */
		}
		header #menu li:last-child a {
			padding-right: 0;
		}
	}
</style>
