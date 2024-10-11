<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
</script>

<div>
	<h1 class="hypertexte-title" data-aos="zoom-in" data-aos-mirror="true">
		Disposition clavier<br /><span class="hyper">—&nbsp;Hyper</span><span class="htexte"
			>Texte&nbsp;—</span
		>
	</h1>
	<BlocClavier nom="presentation" />
	<mini-espace />
	<BlocControlesClavier nom="presentation" />
</div>

<div style="margin: 0 auto; text-align:center; padding-top: 10px;">
	<a href="#debut"><i class="far fa-chevron-down icon-chevron-down scrollez"></i></a>
</div>
<petit-espace />

<div id="debut">
	<hr />
	<p class="encart-introduction">
		<Nom /> est une disposition clavier
		<strong
			>destinée à taper majoritairement du français, de l’anglais et du code informatique</strong
		>. Fruit de nombreuses réflexions et expérimentations, elle se veut la plus optimale possible
		<span class="important">pour&nbsp;un&nbsp;confort&nbsp;d’exception</span>.
	</p>
</div>
<hr />
<mini-espace />
<div class="cards main">
	<div class="card">
		➀ <span class="text-bold">Diminution de la distance parcourue</span> pour moins de fatigue et plus
		de confort
	</div>
	<div class="card">
		➁ <span class="important">Frappe extrêmement fluide</span> par élimination de la quasi-totalité
		des <SFB />s
	</div>
	<div class="card">
		➂ <span class="text-bold">Alternance des mains</span> favorisée pour paralléliser la frappe et ainsi
		écrire plus vite
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
<grand-espace />

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
