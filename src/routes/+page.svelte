<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import Presentation from './accueil/presentation.svelte';
	import Genese from './accueil/genese.svelte';
	import Autocritiques from './accueil/autocritiques.svelte';
</script>

<div class="presentation">
	<h1 class="titre">
		Disposition clavier<br /><span class="hyper">—&nbsp;Hyper</span><span class="texte"
			>Texte&nbsp;—</span
		>
	</h1>

	<EnsembleClavier
		emplacement={'clavier-presentation'}
		type={'iso'}
		couche={'Visuel'}
		couleur={'non'}
		plus={'non'}
		controles={'oui'}
	/>
</div>
<petit-espace />

<div class="contenu">
	<div class="important">
		<p>
			<Nom /> est une disposition clavier destinée à taper majoritairement du français et de l’anglais.
			Fruit de longues réflexions, elle se veut la plus
			<span class="text-glow">optimale</span>
			possible. Cette page vous présente la disposition ainsi que ses nombreux avantages.
		</p>
	</div>

	<Presentation />
	<Genese />
	<Autocritiques />

	<h2><span class="glow">★</span> Pour aller plus loin</h2>
	<div class="important">
		<p>
			<Nom_Plus /> permet d’avoir une disposition encore meilleure. Les <SFB />s sont éradiqués, les
			roulements sont améliorés et les doigts ont encore moins de distance à parcourir.
		</p>
		<p>
			Cependant, ces excellents résultats sont le fruit d’une fraude. En effet, ils nécessitent
			d’avoir un logiciel comme AutoHotkey qui permet de se faire des raccourcis personnalisés. Il
			faudra aussi accepter d’apprendre des enchaînements de touches supplémentaires.
		</p>
		<mini-espace />
		<a href="/hypertexte-plus" style="text-decoration: none"
			><button style="display:block; margin: 0 auto;"><Nom_Plus /></button></a
		>
	</div>
</div>

<style>
	.titre {
		z-index: 2;
		line-height: 1;
		margin: 7vh 0;
		font-size: 2.5rem;
	}
</style>
