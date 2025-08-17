<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
</script>

<div>
	<h1 data-aos="zoom-in" class="ergopti-title">
		Disposition clavier<br /><span style="line-height: 0.75!important;"><NomPlus></NomPlus></span>
	</h1>
	<BlocClavier nom="presentation_plus" />
	<mini-espace />
	<BlocControlesClavier nom="presentation_plus" />
</div>

<petit-espace />

<hr />
<p class="main">
	<NomPlus /> est une version améliorée de la disposition <Nom />. Elle se rapproche de très près de
	la <span class="important">disposition clavier idéale</span>. Effectivement, elle :
</p>
<div class="cards">
	<div class="card">
		<i class="fa-duotone fa-circle-1"></i>
		Ajoute de
		<span class="text-bold">nouveaux roulements</span>.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-2"></i>
		<span class="important"
			>Éradique la quasi-totalité des <span class="nowrap"><SFB />s</span></span
		> pour une frappe ultra-fluide et sans inconfort.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-3"></i>
		<span class="text-bold">Réduit les distances parcourues par les doigts</span>, en particulier
		l’auriculaire droit.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-4"></i> Ajoute <span class="important">divers raccourcis</span>
		tels que des touches
		<kbd-sortie>OneShotShift</kbd-sortie>, <kbd-sortie>Alt + Tab</kbd-sortie>
		et
		<kbd-sortie>Capsword</kbd-sortie>.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-5"></i>
		<span class="text-bold">Divise par 2 le nombre de touches frappées</span> pour écrire certains mots.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-6"></i> Les fonctionnalités sont optionnelles et
		<span class="important">peuvent être intégrées au fil du temps</span>.
	</div>
</div>
<mini-espace></mini-espace>
<hr />

<petit-espace />

<div class="main">
	<div class="encadre">
		Toutefois, l’utilisation de cette version nécessite des <span class="important"
			>outils de programmation de clavier spécifiques.
		</span>
		<span>
			Sur Windows, le programme <span class="important">AutoHotkey</span>
			est utilisé afin de réaliser ces changements. Il est également possible de programmer le firmware
			de son clavier (avec QMK ou ZMK) pour ce faire.
		</span>
	</div>

	<petit-espace />

	<p class="lettrine">
		⚠ Attention, ces nombreux avantages viennent à un prix. D’abord, il y a un effort
		d’apprentissage supplémentaire à effectuer. C’est d’autant plus difficile que ces raccourcis ne
		sont pas marqués sur le clavier, il faut donc les apprendre par cœur car regarder ses touches ne
		fournira aucune information. Le bon côté est que vous n’êtes pas obligé de tous les utiliser
		d’un coup, ce ne sont que des possibilités supplémentaires. Ainsi, le passage de <Nom /> vers <NomPlus
		/> se fait en douceur.
	</p>
	<p>
		☒ Ensuite, et c’est le plus grand inconvénient, dans de très rares cas ces raccourcis vous
		empêcheront d’écrire ce que vous voulez réellement écrire. En effet, avec <NomPlus />, les
		combinaisons de touches extrêmement rares comme <kbd>HC</kbd> sont transformées en d’autres bien
		plus utiles comme <kbd-sortie>WH</kbd-sortie>. Cela signifie que dans les cas où vous voulez
		vraiment écrire
		<kbd>HC</kbd>, il faudra remettre à zéro le remplacement de texte.
	</p>
	<p>
		➜ La remise à zéro du remplacement de texte peut notamment se réaliser en utilisant les flèches
		de navigation, la touche <kbd>Échap</kbd>, en cliquant quelque part, etc. Ces manipulations ne
		devraient arriver que très rarement, mais tout dépend de votre utilisation. Par exemple,
		l’enchaînement <kbd>XG</kbd>
		est très peu commun, mais les Data Scientists l’utiliseront régulièrement pour écrire
		<em>XGBoost</em>. Si c’est le cas, il est possible de désactiver certains des ajouts de <NomPlus
		/>, de les modifier, ou d’ajouter des raccourcis pour les contourner (par exemple avec une
		macro/remplacement de texte qui écrit <em>XGBoost</em>). À noter que le raccourci transformant
		XG en quelque chose d’autre n’est pas implémenté justement pour cette raison ; ce n’était qu’un
		exemple illustratif.
	</p>

	<p class="important">Voici maintenant toutes les améliorations de <NomPlus /> :</p>
</div>
