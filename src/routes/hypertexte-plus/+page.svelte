<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import ControlesClavier from '$lib/clavier/ControlesClavier.svelte';

	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements from './roulements.svelte';
	import Reduction_SFBs from './reduction_sfbs.svelte';
</script>

<svelte:head>
	<title>HyperTexte +</title>
	<meta name="description" content="Découvrez HyperTexte +" />
</svelte:head>

<header>
	<img src="img/logo/logo_hypertexte.png" class="logo" />
	<h1 class="hypertexte-title" data-aos="zoom-in" data-aos-mirror="true">
		Disposition clavier<br /><span style="line-height: 0.75!important;"
			><span class="hyper">Hyper</span><span class="texte">Texte</span><span class="glow">+</span
			></span
		>
	</h1>
	<div class="container">
		<div class="block">
			<BlocClavier nom="presentation_plus" />
		</div>
	</div>
	<mini-espace />
	<ControlesClavier nom="presentation_plus" />
</header>

<petit-espace />

<div class="contenu">
	<hr />
	<div class="encart-introduction">
		<p>
			<NomPlus /> est une version améliorée de la disposition <Nom />. Elle se rapproche de très
			près de la <span class="important">disposition clavier idéale</span>. Effectivement, elle :
		</p>
		<ul class="margin0" style="text-align:left!important">
			<li>éradique la quasi-totalité des <SFB />s ;</li>
			<li>rajoute de merveilleux roulements ;</li>
			<li>réduit les distances parcourues par les doigts, en particulier l’auriculaire droit ;</li>
			<li>divise par 2 le nombre de touches frappées pour écrire certains mots ;</li>
			<li>
				ajoute divers raccourcis tels qu’une touche <kbd-sortie>Alt + Tab</kbd-sortie> et
				<kbd-sortie>Capsword</kbd-sortie>.
				<!-- ou encore <kbd-sortie>Dot-Space-Shift</kbd-sortie>. -->
			</li>
		</ul>
	</div>
	<hr />

	<petit-espace />
	<div class="encadre">
		Toutefois, l’utilisation de cette version nécessite des <span class="important"
			>outils de programmation de clavier spécifiques.
		</span>
		<span>
			Sur Windows, le programme <span class="texte"><span class="important">AutoHotkey</span></span>
			est utilisé afin de réaliser ces changements. Il est également possible de programmer le firmware
			de son clavier (avec QMK ou ZMK) pour ce faire.
		</span>
	</div>

	<petit-espace />
	<section>
		<p class="lettrine">
			⚠ Attention, ces nombreux avantages viennent à un prix. D’abord, il y a un effort
			d’apprentissage supplémentaire à effectuer. C’est d’autant plus difficile que ces raccourcis
			ne sont pas marqués sur le clavier, il faut donc les apprendre par cœur car regarder ses
			touches ne fournira aucune information. Le bon côté est que vous n’êtes pas obligé de tous les
			utiliser d’un coup, ce ne sont que des possibilités supplémentaires. Ainsi, le passage de <Nom
			/> vers <NomPlus /> se fait en douceur.
		</p>
		<p>
			☒ Ensuite, et c’est le plus grand inconvénient, dans de très rares cas ces raccourcis vous
			empêcheront d’écrire ce que vous voulez réellement écrire. En effet, avec <NomPlus />, les
			combinaisons de touches extrêmement rares comme <kbd>HC</kbd> sont transformées en d’autres
			bien plus utiles comme <kbd-sortie>WH</kbd-sortie>. Cela signifie que dans les cas où vous
			voulez vraiment écrire
			<kbd>HC</kbd>, il faudra remettre à zéro le remplacement de texte.
		</p>
		<p>
			➜ La remise à zéro du remplacement de texte peut notamment se réaliser en utilisant les
			flèches de navigation, la touche Échap, en cliquant quelque part, etc. Ces manipulations ne
			devraient arriver que très rarement, mais tout dépend de votre utilisation. Par exemple,
			l’enchaînement <kbd>XG</kbd>
			est très peu commun, mais les data scientists l’utiliseront régulièrement pour écrire
			<em>XGBoost</em>. Si c’est le cas, il est possible de désactiver certains des ajouts de <NomPlus
			/>, de les modifier, ou d’ajouter des raccourcis pour les contourner (par exemple avec une
			macro/remplacement de texte qui écrit <em>XGBoost</em>). À noter que le raccourci transformant
			XG en quelque chose d’autre n’est pas implémenté justement pour cette raison ; ce n’était
			qu’un exemple illustratif.
		</p>
	</section>
	<p class="important">Voici maintenant toutes les améliorations de <NomPlus /> :</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">➀ Confort</h2>
	<Confort />

	<h2 data-aos="zoom-out" data-aos-mirror="true">➁ Ajout d’excellents roulements</h2>
	<Roulements />

	<h2 data-aos="zoom-out" data-aos-mirror="true">➂ Diminution des SFBs</h2>
	<Reduction_SFBs />

	<h2 data-aos="zoom-out" data-aos-mirror="true">➃ Abréviations</h2>
	<Abreviations />

	<h2 data-aos="zoom-out" data-aos-mirror="true">➄ Raccourcis</h2>
	<Raccourcis />
</div>

<style>
	.logo {
		display: block;
		margin: 0 auto;
		margin-top: 30px;
		margin-bottom: -30px;
		width: 80px;
		border: 1px solid rgba(255, 255, 255, 0.7);
		border-radius: 100px;
		box-shadow: rgba(255, 255, 255, 0.24) 0px 3px 8px;
	}
	.container {
		perspective: 1000px;
	}

	.block {
		position: relative;
		margin: 0 auto;
		width: fit-content;
		transform: rotateX(25deg) translateZ(5px);
		transform-style: preserve-3d;
	}

	.block::before {
		border-radius: var(--arrondi-clavier);
		content: '';
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate3d(
			-50%,
			-50%,
			-20px
		); /* mettre la même valeur en négatif que la valeur de l'épaisseur */
		width: calc(100% + 4px);
		height: 100%;
		background-color: black; /* ou la couleur de fond de votre choix */
	}
</style>
