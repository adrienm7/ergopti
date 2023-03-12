<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements_SFB from './roulements_sfb.svelte';
</script>

<svelte:head>
	<title>HyperTexte +</title>
	<meta name="description" content="Découvrez HyperTexte +" />
</svelte:head>

<header>
	<h1 class="hypertexte-title" data-aos="zoom-in" data-aos-mirror="true">
		Disposition clavier<br /><span style="line-height: 0.75!important;"
			><span class="hyper">Hyper</span><span class="texte">Texte</span><span class="glow">+</span
			></span
		>
	</h1>
	<EnsembleClavier
		emplacement={'clavier-presentation'}
		type={'iso'}
		couche={'Visuel'}
		couleur={'oui'}
		plus={'oui'}
		controles={'oui'}
	/>
</header>

<petit-espace />

<div class="contenu">
	<hr />
	<div class="encart-introduction">
		<p>
			<Nom_Plus /> est une version améliorée de la disposition <Nom />.<br />Elle se rapproche de
			très près de la <span class="hyper"><strong>disposition clavier idéale</strong></span>.
		</p>
		<p>Effectivement, elle :</p>
		<ul class="margin0">
			<li>éradique la quasi-totalité des <SFB />s ;</li>
			<li>rajoute de merveilleux roulements ;</li>
			<li>réduit les distances parcourues par les doigts, en particulier l’auriculaire droit ;</li>
			<li>divise par 2 le nombre de touches frappées pour écrire certains mots ;</li>
			<li>
				ajoute divers raccourcis tels qu’une touche <kbd-sortie>Alt</kbd-sortie> +
				<kbd-sortie>Tab</kbd-sortie>,
				<kbd-sortie>Capsword</kbd-sortie>
				ou encore <kbd-sortie>Dot-Space-Shift</kbd-sortie>.
			</li>
		</ul>
	</div>
	<hr />

	<mini-espace />
	<p>
		Toutefois, l’utilisation de cette version nécessite des <span class="texte text-bold"
			>outils de programmation de clavier spécifiques.
		</span>
		<span>
			Sur Windows, le programme <span class="texte"><strong>AutoHotkey</strong></span> est utilisé afin
			de réaliser ces changements. Il est également possible de programmer le firmware de son clavier
			(avec QMK ou ZMK) pour ce faire.
		</span>
	</p>

	<petit-espace />
	<p class="lettrine">
		⚠ Attention, ces nombreux avantages viennent à un prix. D’abord, il y a un effort
		d’apprentissage supplémentaire à effectuer. C’est d’autant plus difficile que ces raccourcis ne
		sont pas marqués sur le clavier, il faut donc les apprendre par cœur car regarder ses touches ne
		fournira aucune information. Le bon côté est que vous n’êtes pas obligé de tous les utiliser
		d’un coup, ce ne sont que des possibilités supplémentaires. Ainsi, le passage de <Nom /> vers <Nom_Plus
		/> se fait en douceur.
	</p>
	<p>
		☒ Ensuite, et c’est le plus grand inconvénient, dans de très rares cas ces raccourcis vous
		empêcheront d’écrire ce que vous voulez réellement écrire. En effet, avec <Nom_Plus />, les
		combinaisons de touches extrêmement rares comme <kbd>HC</kbd> sont transformées en d’autres bien
		plus utiles comme <kbd-sortie>WH</kbd-sortie>. Cela signifie que dans les cas où vous voulez
		vraiment écrire
		<kbd>HC</kbd>, il faudra remettre à zéro le remplacement de texte.
	</p>
	<p>
		➜ La remise à zéro du remplacement de texte peut notamment se réaliser en utilisant les flèches
		de navigation, la touche Échap, en cliquant quelque part, etc. Ces manipulations ne devraient
		arriver que très rarement, mais tout dépend de votre utilisation. Par exemple, l’enchaînement <kbd
			>XG</kbd
		>
		est très peu commun, mais les data scientists l’utiliseront régulièrement pour écrire
		<em>XGBoost</em>. Si c’est le cas, vous avez la possibilité de désactiver certains des ajouts de <Nom_Plus
		/>, de les modifier, ou d’ajouter des raccourcis pour les contourner (par exemple avec une
		macro/remplacement de texte qui écrit <em>XGBoost</em>). À noter que le raccourci transformant
		XG en quelque chose d’autre n’est pas implémenté justement pour cette raison ; ce n’était qu’un
		exemple illustratif.
	</p>

	<p class="text-bold">Voici maintenant toutes les améliorations de <Nom_Plus /> :</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Roulements et diminution des SFBs</h2>
	<Roulements_SFB />

	<h2 data-aos="zoom-out" data-aos-mirror="true">Abréviations</h2>
	<Abreviations />

	<h2 data-aos="zoom-out" data-aos-mirror="true">Confort</h2>
	<Confort />

	<h2 data-aos="zoom-out" data-aos-mirror="true">Raccourcis</h2>
	<Raccourcis />
</div>
