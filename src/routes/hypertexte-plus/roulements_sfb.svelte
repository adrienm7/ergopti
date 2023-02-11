<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
	import SFB from '../../composants/SFB.svelte';
</script>

<h2>Roulements et diminution des <SFB />s</h2>
<p>L’un des avantages majeurs de <Nom_Plus /> est qu’il réduit presque à 0 les <SFB />s.</p>
<p>
	Les <SFB />s les plus fréquents de la disposition sont, par ordre de fréquence : SC, PT, OE, EO,
	GT, BU et UB. Évidemment, ils seront tous supprimés.
</p>
<h3>Ajout d’excellents roulements et suppression des <SFB />s majeurs</h3>

<p>
	<kbd-sortie>SC</kbd-sortie> est remplacé par le racccourci <kbd>,C</kbd> et tous les autres <SFB
	/>s les plus fréquents se font par roulements :
</p>
<ul class="margin-top-2">
	<li><kbd>P’</kbd> ➜ <kbd-sortie>PT</kbd-sortie></li>
	<li><kbd>GX</kbd> ➜ <kbd-sortie>GT</kbd-sortie></li>
</ul>

<mini-espace />

<p>En outre, des roulements pour plus de confort sont ajoutés :</p>
<ul class="margin-top-2">
	<li><kbd>HC</kbd> ➜ <kbd-sortie>WH</kbd-sortie></li>
	<li><kbd>’P</kbd> ➜ <kbd-sortie>XP</kbd-sortie></li>
</ul>

<mini-espace />

<p>
	Encore une fois, ces roulements améliorent beaucoup l’expérience de frappe dans la majorité du
	temps. Cependant, parfois vous voudrez écrire GX (par exemple pour écrire Yu-Gi-Oh GX) et vous ne
	pourrez pas car GX se transformera en GT. À vous de voir si vous voulez supprimer certains
	raccourcis, les modifier ou créer d’autres raccourcis pour écrire GX d’une autre manière.
</p>

<h3>Utilisation de la touche <kbd>À</kbd> + <kbd>Consonne</kbd></h3>
<p>
	La touche <kbd>À</kbd> est l’une des plus importantes dans <Nom_Plus />. C’est grâce à elle que
	tous les autres <SFB />s, en dehors de ceux supprimés grâce à des roulements, sont supprimés.
</p>
<ul class="margin-top-2">
	<li><kbd>ÀB</kbd> ➜ <kbd-sortie>BÉ</kbd-sortie></li>
	<li><kbd>ÀC</kbd> ➜ <kbd-sortie>CD</kbd-sortie></li>
	<li><kbd>ÀD</kbd> ➜ <kbd-sortie>DS</kbd-sortie></li>
	<li><kbd>ÀF</kbd> ➜ <kbd-sortie>SF</kbd-sortie></li>
	<li><kbd>ÀG</kbd> ➜ <kbd-sortie>GL</kbd-sortie></li>
	<li><kbd>ÀH</kbd> ➜ <kbd-sortie>NH</kbd-sortie></li>
	<li><kbd>ÀL</kbd> ➜ <kbd-sortie>CL</kbd-sortie></li>
	<li><kbd>ÀM</kbd> ➜ <kbd-sortie>SM</kbd-sortie></li>
	<li><kbd>ÀN</kbd> ➜ <kbd-sortie>NL</kbd-sortie></li>
	<li><kbd>ÀP</kbd> ➜ <kbd-sortie>PH</kbd-sortie></li>
	<li><kbd>ÀQ</kbd> ➜ <kbd-sortie>RQ</kbd-sortie></li>
	<li><kbd>ÀR</kbd> ➜ <kbd-sortie>CF.</kbd-sortie></li>
	<li><kbd>ÀS</kbd> ➜ <kbd-sortie>CS</kbd-sortie></li>
	<li><kbd>ÀT</kbd> ➜ <kbd-sortie>TP</kbd-sortie></li>
	<li><kbd>ÀV</kbd> ➜ <kbd-sortie>ADV</kbd-sortie></li>
	<li><kbd>ÀX</kbd> ➜ <kbd-sortie>ADM</kbd-sortie></li>
</ul>
<p>
	Comme vous pouvez le constater, la touche <kbd>À</kbd> est vraiment pour supprimer les derniers
	petits <SFB />s restants. Sans utiliser cette touche, vous aurez déjà éliminé la majorité d’entre
	eux.
</p>

<h3>Utilisation de la touche <kbd>È</kbd> + <kbd>Voyelle</kbd></h3>
<p>
	La touche <kbd>È</kbd> est souvent suivie et précédée d’autres lettres en français, il n’y a donc
	pas beaucoup de combinaisons disponibles. Toutefois, les combinaisons <kbd>È</kbd> +
	<kbd>Voyelle</kbd> n’existent pas et peuvent donc être utilisées :
</p>
<ul class="margin-top-2">
	<li>
		<kbd>ÈE</kbd> ➜ <kbd-sortie>EO</kbd-sortie> et <kbd>EÈ</kbd> ➜ <kbd-sortie>OE</kbd-sortie>
	</li>
	<li>
		<kbd>ÈÉ</kbd> ➜ <kbd-sortie>BU</kbd-sortie> et <kbd>ÉÈ</kbd> ➜ <kbd-sortie>UB</kbd-sortie>
	</li>
	<li><kbd>ÈÊ</kbd> ➜ <kbd-sortie>YI</kbd-sortie></li>
</ul>
