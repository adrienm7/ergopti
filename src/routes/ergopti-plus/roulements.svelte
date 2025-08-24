<script>
	import Nom from '$lib/components/Nom.svelte';
	import NomPlus from '$lib/components/NomPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<h2>Ajout d’excellents roulements</h2>

<div class="encadre">
	<p class="margin0">
		<b>Note :</b> Dans de très rares cas, ces raccourcis vous empêcheront d’écrire ce que vous
		voulez réellement écrire. En effet, avec <NomPlus />, les combinaisons de touches extrêmement
		rares comme
		<kbd>HC</kbd>
		sont transformées en d’autres bien plus utiles comme <kbd-sortie>WH</kbd-sortie>. Cela signifie
		que dans les cas où vous voulez vraiment écrire
		<kbd>HC</kbd>, il faudra remettre à zéro le remplacement de texte.
	</p>
	<br />
	<p class="margin0">
		➜ La remise à zéro du remplacement de texte peut notamment se réaliser en utilisant les flèches
		de navigation, la touche <kbd>Échap</kbd>, en cliquant quelque part, etc. Ces manipulations ne
		devraient arriver que très rarement, mais tout dépend de votre utilisation. Par exemple,
		l’enchaînement <kbd>XG</kbd>
		est très peu commun, mais les Data Scientists l’utiliseront régulièrement pour écrire
		<em>XGBoost</em>. Si c’est le cas, il est possible de désactiver certains des ajouts de <NomPlus
		/>, de les modifier, ou d’ajouter des raccourcis pour les contourner (par exemple avec une
		macro/remplacement de texte qui écrit <em>XGBoost</em>). À noter que le raccourci transformant
		XG en quelque chose d’autre n’est pas implémenté justement pour cette raison ; ce n’était qu’un
		exemple illustratif.
	</p>
</div>

<petit-espace></petit-espace>

<p>Des roulements pour plus de confort ont été ajoutés :</p>

<h3>Roulements avec des lettres</h3>
<ul class="margin-top-2">
	<li><kbd>hc</kbd> ➜ <kbd-sortie>wh</kbd-sortie> ;</li>
	<p>
		Le roulement <kbd>CH</kbd> était déjà l’un des grands atouts de la disposition <Nom />, car
		cette combinaison est très fréquente et se produit en roulement, ce qui la rend extrêmement
		confortable. L’ajout du roulement donnant <kbd-sortie>WH</kbd-sortie> permet d’avoir une frappe en
		anglais encore plus fluide.
	</p>
	<li><kbd>p'</kbd> ➜ <kbd-sortie>ct</kbd-sortie> ;</li>
	<p>
		Ce roulement donnant <kbd-sortie>ct</kbd-sortie> permet d’éviter le pire <SFB></SFB> de la disposition
		pour le transformer en roulement très confortable.
	</p>
	<li>
		<kbd>sx</kbd> ➜ <kbd-sortie>sk</kbd-sortie> et <kbd>cx</kbd> ➜ <kbd-sortie>ck</kbd-sortie> ;
	</li>
	<p>
		La lettre <kbd>K</kbd> est rarement utilisée. Lorsqu’elle l’est, c’est souvent pour réaliser les
		combinaisons <kbd-sortie>SK</kbd-sortie> et <kbd-sortie>CK</kbd-sortie>. Ainsi, ces roulements
		permettent d’éviter d’aller appuyer sur la vraie touche <kbd>K</kbd> pour une frappe beaucoup plus
		confortable.
	</p>
	<li>
		<kbd>à★</kbd> ➜ <kbd-sortie>bu</kbd-sortie> et <kbd>àu</kbd> ➜ <kbd-sortie>ub</kbd-sortie>.
	</li>
	<p>
		Ces roulements très confortables suppriment le plus gros <SFB></SFB> présent sur la main gauche.
	</p>
</ul>

<h3>Roulements avec des symboles</h3>

<BlocClavier nom="symboles_plus" />
<mini-espace></mini-espace>

<ul class="margin-top-2">
	<li>
		<kbd>#!</kbd> ➜ <kbd-sortie>:=</kbd-sortie> et <kbd>!#</kbd> ➜ <kbd-sortie>!=</kbd-sortie> ;
	</li>
	<li>
		<kbd>{'(#'}</kbd> ➜ <kbd-sortie>{'("'}</kbd-sortie> et <kbd>{'[#'}</kbd> ➜
		<kbd-sortie>{'["'}</kbd-sortie> ;
	</li>
	<p>
		Une fois qu’on a l’habitude de ce roulement, on ne peut plus s’en passer. Le <kbd>#</kbd>
		devient un <kbd-sortie>"</kbd-sortie>, ce qui permet d’avoir des roulements très logiques et
		ultra-confortables.
	</p>
	<li>
		<kbd>{'[)'}</kbd> ➜ <kbd-sortie>{'=""'}</kbd-sortie> ;
	</li>
	<p>
		Cette suite de symboles est extrêmement utilisée en programmation, où elle permet généralement
		d’assigner un texte à une variable. L’avoir en roulement vers l’intérieur, sur la homerow en
		plus, est un véritable luxe.
	</p>
	<li>
		<kbd>\"</kbd> ➜ <kbd-sortie>/*</kbd-sortie> et <kbd>"\</kbd> ➜ <kbd-sortie>*/</kbd-sortie> ;
	</li>
	<p>
		Ce roulement permet de réaliser un commentaire en programmation, et ce extrêmement
		confortablement.
	</p>
	<li>
		<kbd>$=</kbd> ➜ <kbd-sortie>{'=>'}</kbd-sortie> et <kbd>=$</kbd> ➜
		<kbd-sortie>{'<='}</kbd-sortie> ;
	</li>
	<li>
		<kbd>+?</kbd> ➜ <kbd-sortie>{'->'}</kbd-sortie> et <kbd>?+</kbd> ➜
		<kbd-sortie>{'<-'}</kbd-sortie> ;
	</li>
</ul>
