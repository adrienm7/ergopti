<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
</script>

<div>
	<h1 data-aos="zoom-in" class="ergopti-title">
		Disposition clavier<br /><span class="italic"
			><span>—&nbsp;</span><span style="line-height: 0.75!important;"
				><Nom></Nom><span>&nbsp;—</span></span
			>
		</span>
	</h1>
	<BlocClavier nom="presentation" />
	<mini-espace />
	<BlocControlesClavier nom="presentation" />
</div>

<div style="margin: 0 auto; text-align:center; padding-top: 5px;">
	<a href="#debut"><i class="far fa-chevron-down icon-chevron-down scrollez"></i></a>
</div>
<div id="debut">
	<petit-espace />
	<hr />
	<p class="encart-introduction">
		<Nom /> est une <strong class="important">disposition clavier ergonomique</strong> pour le
		<strong>français</strong>, l’<strong>anglais</strong> et la <strong>programmation</strong>.
		Fruit de nombreuses réflexions et expérimentations, elle se veut la plus optimale possible pour
		une frappe rapide, fluide et
		<span class="important">un&nbsp;confort&nbsp;d’exception</span>.
	</p>
	<hr />
</div>

<mini-espace />

<div class="cards">
	<div class="card">
		<i class="fa-duotone fa-circle-1"></i>
		<span class="text-bold">Diminution de la distance parcourue</span> par les doigts pour moins de fatigue.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-2"></i> <span class="important">Frappe extrêmement fluide</span>
		par élimination de la quasi-totalité des
		<span class="nowrap"><SFB />s.</span>
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-3"></i> <span class="text-bold">Alternance des mains</span> favorisée
		pour paralléliser la frappe et ainsi écrire plus vite.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-4"></i> <span class="important">Frappe ultra-confortable</span> grâce
		à une optimisation des roulements.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-5"></i> <span class="text-bold">Placement logique</span> des touches,
		permettant de s’en souvenir aisément.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-6"></i> <span class="important">Chiffres en accès direct</span>,
		raccourcis sur la main gauche, ponctuations insécables, etc.
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
</style>
