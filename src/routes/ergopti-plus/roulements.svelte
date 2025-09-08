<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<h2>Ajout d’excellents roulements</h2>

<div class="encadre">
	<p class="margin0">
		<b>Note :</b> Dans de très rares cas, ces raccourcis vous empêcheront d’écrire ce que vous
		voulez réellement écrire. En effet, avec <ErgoptiPlus />, les combinaisons de touches
		extrêmement rares comme
		<kbd>HC</kbd>
		sont transformées en d’autres bien plus utiles comme <kbd-output>WH</kbd-output>. Cela signifie
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
		<em>XGBoost</em>. Si c’est le cas, il est possible de désactiver certains des ajouts de <ErgoptiPlus
		/>, de les modifier, ou d’ajouter des raccourcis pour les contourner (par exemple avec une
		macro/remplacement de texte qui écrit <em>XGBoost</em>). À noter que le raccourci transformant
		XG en quelque chose d’autre n’est pas implémenté justement pour cette raison ; ce n’était qu’un
		exemple illustratif.
	</p>
</div>

<small-space></small-space>

<p>Des roulements pour plus de confort ont été ajoutés :</p>

<h3>Roulements avec des lettres</h3>
<ul class="margin-top-2">
	<li><kbd>hc</kbd> ➜ <kbd-output>wh</kbd-output> ;</li>
	<p>
		Le roulement <kbd>CH</kbd> était déjà l’un des grands atouts de la disposition <Ergopti />, car
		cette combinaison est très fréquente et se produit en roulement, ce qui la rend extrêmement
		confortable. L’ajout du roulement donnant <kbd-output>WH</kbd-output> permet d’avoir une frappe en
		anglais encore plus fluide.
	</p>
	<li><kbd>p'</kbd> ➜ <kbd-output>ct</kbd-output> ;</li>
	<p>
		Ce roulement donnant <kbd-output>ct</kbd-output> permet d’éviter le pire <SFB></SFB> de la disposition
		pour le transformer en roulement très confortable.
	</p>
	<li>
		<kbd>sx</kbd> ➜ <kbd-output>sk</kbd-output> et <kbd>cx</kbd> ➜ <kbd-output>ck</kbd-output> ;
	</li>
	<p>
		La lettre <kbd>K</kbd> est rarement utilisée. Lorsqu’elle l’est, c’est souvent pour réaliser les
		combinaisons <kbd-output>SK</kbd-output> et <kbd-output>CK</kbd-output>. Ainsi, ces roulements
		permettent d’éviter d’aller appuyer sur la vraie touche <kbd>K</kbd> pour une frappe beaucoup plus
		confortable.
	</p>
	<li>
		<kbd>à★</kbd> ➜ <kbd-output>bu</kbd-output> et <kbd>àu</kbd> ➜ <kbd-output>ub</kbd-output>.
	</li>
	<p>
		Ces roulements très confortables suppriment le plus gros <SFB></SFB> présent sur la main gauche.
	</p>
</ul>

<h3>Roulements avec des symboles</h3>

<KeyboardBasis name="symboles_plus" />
<tiny-space></tiny-space>

<ul class="margin-top-2">
	<li>
		<kbd>#!</kbd> ➜ <kbd-output>:=</kbd-output> et <kbd>!#</kbd> ➜ <kbd-output>!=</kbd-output> ;
	</li>
	<li>
		<kbd>{'(#'}</kbd> ➜ <kbd-output>{'("'}</kbd-output> et <kbd>{'[#'}</kbd> ➜
		<kbd-output>{'["'}</kbd-output> ;
	</li>
	<p>
		Une fois qu’on a l’habitude de ce roulement, on ne peut plus s’en passer. Le <kbd>#</kbd>
		devient un <kbd-output>"</kbd-output>, ce qui permet d’avoir des roulements très logiques et
		ultra-confortables.
	</p>
	<li>
		<kbd>{'[)'}</kbd> ➜ <kbd-output>{'=""'}</kbd-output> ;
	</li>
	<p>
		Cette suite de symboles est extrêmement utilisée en programmation, où elle permet généralement
		d’assigner un texte à une variable. L’avoir en roulement vers l’intérieur, sur la homerow en
		plus, est un véritable luxe.
	</p>
	<li>
		<kbd>\"</kbd> ➜ <kbd-output>/*</kbd-output> et <kbd>"\</kbd> ➜ <kbd-output>*/</kbd-output> ;
	</li>
	<p>
		Ce roulement permet de réaliser un commentaire en programmation, et ce extrêmement
		confortablement.
	</p>
	<li>
		<kbd>$=</kbd> ➜ <kbd-output>{'=>'}</kbd-output> et <kbd>=$</kbd> ➜
		<kbd-output>{'<='}</kbd-output> ;
	</li>
	<li>
		<kbd>+?</kbd> ➜ <kbd-output>{'->'}</kbd-output> et <kbd>?+</kbd> ➜
		<kbd-output>{'<-'}</kbd-output> ;
	</li>
</ul>
