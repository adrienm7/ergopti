<script>
	import '$lib/css/orb.css';

	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';

	import AlternanceMains from './accueil/alternance_mains.svelte';
	import DistanceDoigtsTouches from './accueil/distance_doigts_touches.svelte';
	import MinimisationSfbs from './accueil/minimisation_sfbs.svelte';
	import PlacementLogiqueTouches from './accueil/placement_logique_touches.svelte';
	import ChiffresAccesDirect from './accueil/chiffres_acces_direct.svelte';
	import UtilisationUneMain from './accueil/utilisation_une_main.svelte';
	import OptimisationRoulements from './accueil/optimisation_roulements.svelte';
</script>

<svelte:head>
	<title>Disposition HyperTexte</title>
	<meta
		name="description"
		content="La disposition HyperTexte est optimisée pour le français et l’anglais"
	/>
</svelte:head>

<header>
	<h1 class="hypertexte-title" data-aos="zoom-in" data-aos-mirror="true">
		Disposition clavier<br /><span class="hyper">—&nbsp;Hyper</span><span class="texte"
			>Texte&nbsp;—</span
		>
	</h1>
	<BlocClavier nom="presentation" />
	<mini-espace />
	<BlocControlesClavier nom="presentation" />
</header>

<div style="margin: 0 auto; text-align:center; padding-top: 10px;">
	<a href="#debut"><i class="far fa-chevron-down icon-chevron-down scrollez"></i></a>
</div>
<petit-espace />

<div id="debut">
	<hr />
	<mini-espace />
	<p class="encart-introduction">
		<Nom /> est une disposition clavier
		<strong
			>destinée à taper majoritairement du français, de l’anglais et du code informatique</strong
		>. Fruit de nombreuses réflexions et expérimentations, elle se veut la plus optimale possible
		<span class="important">pour&nbsp;un&nbsp;confort&nbsp;d’exception</span>.
	</p>
	<div class="cards">
		<div class="card">
			➀ <span class="text-bold">Diminution de la distance parcourue</span> pour moins de fatigue et plus
			de confort
		</div>
		<div class="card">
			➁ <span class="important">Frappe extrêmement fluide</span> par élimination de la
			quasi-totalité des <SFB />s
		</div>
		<div class="card">
			➂ <span class="text-bold">Alternance des mains</span> favorisée pour paralléliser la frappe et
			ainsi écrire plus vite
		</div>
		<div class="card">
			➃ <span class="important">Frappe ultra-confortable</span> grâce à une optimisation des roulements
		</div>
		<div class="card">
			➄ <span class="text-bold">Placement logique</span> des touches, permettant de s’en souvenir aisément
		</div>
		<div class="card">
			➅ <span class="important">Et bien d’autres</span> améliorations, voire révolutions...
		</div>
	</div>
	<mini-espace />
	<div style="text-align:center;">
		<a href="/telechargements">
			<button class="bouton-telechargement">➜ Essayer en ligne / Installation</button>
		</a>
	</div>
	<petit-espace />
	<hr />

	<DistanceDoigtsTouches />
	<MinimisationSfbs />
	<AlternanceMains />
	<OptimisationRoulements />
	<PlacementLogiqueTouches />
	<ChiffresAccesDirect />
	<UtilisationUneMain />
</div>
<div style="border-bottom: 1px solid rgba(255, 255, 255, 0.5);"></div>
<div style="background:black; padding: 50px 0; margin-bottom:-10vh;">
	<h2 data-aos="zoom-out" data-aos-mirror="true">
		<span class="glow">★</span>
	</h2>
	<div id="orb">
		<div class="wrap">
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
			<div class="c" />
		</div>
		<h2
			class="text-orange-gradient text-center"
			style="margin: 0 auto; padding-top: 20vh; padding-bottom:10vh; border:none; box-shadow: none; font-weight:bolder;"
		>
			Pour aller encore <b>+</b> loin
		</h2>
		<div class="texte-orb">
			<hr />
			<p class="encart-introduction">
				<NomPlus /> permet d’avoir une disposition encore meilleure. Les <SFB />s sont éradiqués,
				les roulements sont améliorés et les doigts ont encore moins de distance à parcourir.<br
				/>Découvrez cette amélioration de la disposition en consultant sa page associée :
			</p>
			<a href="/hypertexte-plus" style="text-decoration: none;"
				><button
					style="display:block; margin: 0 auto; margin-bottom: 25px; background: rgba(0, 0, 0, 0.2); padding: 10px; padding-top: 6px; border-radius: 3px; border: 1px solid white;"
					><NomPlus /></button
				></a
			>
			<hr />
		</div>
	</div>
</div>

<style>
	.scrollez {
		text-align: center;
		font-size: 4rem;
		font-size: clamp(20px, 4rem, 100px);
		color: white;
		-webkit-animation: bounce7 2s infinite;
		animation: bounce7 2s infinite;
	}

	@keyframes bounce7 {
		0% {
			-webkit-transform: translate(0, -20px);
			opacity: 0;
		}
		50% {
			opacity: 1;
		}
		100% {
			-webkit-transform: translate(0, 20px);
			opacity: 0;
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.scrollez {
			animation: none;
		}
	}

	.cards {
		max-width: 1000px;
		margin: 0 auto;
		display: grid;
		gap: 1rem;
		/* grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); */
	}

	.card {
		display: block;
		align-items: center;
		background-color: rgba(38, 0, 110, 0.6);
		padding: 1rem;
		border-radius: 7px;
	}

	.cards .card:nth-child(even) {
		background-color: rgba(0, 0, 0, 0.8);
		color: white;
	}
	.cards .card:nth-child(odd) {
		background-color: rgba(255, 255, 255, 0.9);
		color: black;
	}

	/* Screen larger than 500px? 2 column */
	@media (min-width: 500px) and (max-width: 900px) {
		.cards {
			grid-template-columns: repeat(2, 1fr);
		}

		.cards .card:nth-child(1),
		.cards .card:nth-child(4),
		.cards .card:nth-child(5) {
			background-color: rgba(0, 0, 0, 0.8);
			color: white;
		}
		.cards .card:nth-child(2),
		.cards .card:nth-child(3),
		.cards .card:nth-child(6) {
			background-color: rgba(255, 255, 255, 0.9);
			color: black;
		}
	}

	/* Screen larger than 900px? 3 columns */
	@media (min-width: 900px) {
		.cards {
			grid-template-columns: repeat(3, 1fr);
		}
	}
</style>
