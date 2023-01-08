<script>
	import { page } from '$app/stores';
	import Nom from '../composants/Nom.svelte';

	function fermerMenu() {
		document.getElementById('menu-btn').checked = false;
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
	<ul class="menu">
		<li aria-current={$page.url.pathname === '/' ? 'page' : undefined} on:click={fermerMenu}>
			<a href="/">⌨ HyperTexte</a>
		</li>
		<li
			aria-current={$page.url.pathname === '/hypertexte-plus' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/hypertexte-plus">★ HyperTexte<span class="glow">+</span></a>
		</li>
		<li
			aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/benchmarks">❖ Benchmarks</a>
		</li>
		<li
			aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/telechargements">➜ Téléchargements</a>
		</li>
		<li aria-current={$page.url.pathname === '/contact' ? 'page' : undefined} on:click={fermerMenu}>
			<a href="/contact">✉ Contact</a>
		</li>
	</ul>
</header>

<style>
	:root {
		--couleur-header: rgba(0, 0, 0, 0.8);
		--couleur-header-mobile: rgba(0, 0, 0, 0.6);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--espacement-items-menu: 5px;
		--couleur-ombre: rgba(255, 255, 255, 0.3);
		--marge-fenetre: 5vw;
		--hauteur-header: 70px; /* Fallback si clamp n'est pas supporté */
		--couleur-icone-hamburger: white;
	}

	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		background-color: var(--couleur-header);
		backdrop-filter: blur(30px);
		box-shadow: 0px 0px 5px 1px var(--couleur-ombre);
		position: fixed;
		width: 100%;
		height: var(--hauteur-header);
		z-index: 3;
	}
	header a {
		color: var(--couleur-liens-header);
		text-decoration: none;
	}
	header ul {
		position: fixed;
		width: 100%;
		height: 100%;
		top: var(--hauteur-header);
		z-index: -1;
		display: block;
		margin: 0;
		padding: 0;
		list-style: none;
		background-color: var(--couleur-header-mobile);
		backdrop-filter: blur(30px);
		border-top: 1px solid rgba(255, 255, 255, 0.2);
	}

	header .menu li {
		display: block;
		padding: var(--hauteur-element-menu-mobile) 0;
		padding-left: var(--marge-fenetre);
		text-decoration: none;
		font-size: 1.5rem;
		border-bottom: 1px solid rgba(255, 255, 255, 0.2);
		/* font-family: 'Times New Roman', Times, serif; */
		/* font-style: italic; */
		/* text-shadow: rgba(255, 255, 255, 0.3) 0 0 20px; */
	}

	/* On met li et li a car ne fonctionne pas sur mobile et bureau sinon */
	header .menu li::first-letter,
	header .menu li a::first-letter {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	header .menu li[aria-current='page']::first-letter,
	header .menu li[aria-current='page'] a::first-letter {
		background-image: linear-gradient(to right, var(--gradient-purple));
	}

	header .menu li[aria-current='page'] a {
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
	/* header .menu li[aria-current='page'] a::after {
		content: '';
		display: block;
		position: relative;
		bottom: -5px;
		width: 100%;
		height: 3px;
		border-radius: 5px;
		background-image: linear-gradient(to right, var(--gradient-blue));
	} */

	header .menu li:not([aria-current='page']) a:hover {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	/* header .menu li:not([aria-current='page']) a:hover::after {
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
		padding: 0.5rem;
	}
	header .logo p {
		display: inline;
		font-family: 'Times New Roman', Times, serif;
	}

	/* menu */

	header .menu {
		clear: both;
		max-height: 0;
		transition: height 0.2s ease-out;
	}

	/* menu icon */

	header .menu-icon {
		padding: 5vw;
		display: inline-block;
		cursor: pointer;
		user-select: none;
	}

	header .menu-icon .navicon {
		background: var(--couleur-icone-hamburger);
		display: block;
		height: 2px;
		position: relative;
		transition: background 0.2s ease-out;
		width: 18px;
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

	header .menu-btn {
		display: none;
	}

	header .menu-btn:not(:checked) ~ .menu {
		display: none;
	}

	header .menu-btn:checked ~ .menu {
		max-height: 100vh;
		height: 100vh;
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

	/* 48em = 768px, donc pour les grands écrans */

	@media (min-width: 1024px) {
		header .menu {
			display: flex !important;
			background-color: transparent;
			margin-right: 15px;
			height: unset !important;
		}

		header ul {
			position: static;
			width: unset;
			height: unset;
			z-index: 1;
			border: none;
			margin: 0;
			padding: 0;
		}

		header .menu li {
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

		header .menu li:not(:last-child)::after {
			content: '';
			background-color: transparent;
			height: 100%;
			width: 5px;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			box-shadow: 2px 0 1px 0px var(--couleur-ombre);
		}

		header .menu li a {
			padding: var(--espacement-items-menu);
			margin: var(--espacement-items-menu);
		}

		header .menu {
			clear: none;
			float: right;
			max-height: none;
		}
		header .menu-icon {
			display: none;
		}
	}

</style>
