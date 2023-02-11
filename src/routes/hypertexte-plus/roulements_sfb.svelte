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
	SC est supprimé par le racccourci <kbd>,C</kbd> et tous les autres <SFB />s se font par roulements
	:
</p>
<ul class="margin-top-2">
	<li>HC ➜ <kbd>WH</kbd></li>
	<li>P’ ➜ <kbd>PT</kbd></li>
	<li>’P ➜ <kbd>XP</kbd></li>
	<li>GX ➜ <kbd>GT</kbd></li>
</ul>
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

<h3>Utilisation de la touche <kbd>È</kbd> + <kbd>Voyelle</kbd></h3>
<p>
	La touche <kbd>È</kbd> est souvent suivie et précédée d’autres lettres en français, il n’y a donc
	pas beaucoup de combinaisons disponibles. Toutefois, les combinaisons <kbd>È</kbd> +
	<kbd>Voyelle</kbd> n’existent pas et peuvent donc être utilisées :
</p>
<ul class="margin-top-2">
	<li><kbd>ÈE</kbd> ➜ <kbd>EO</kbd> et <kbd>EÈ</kbd> ➜ <kbd>OE</kbd></li>
	<li><kbd>ÈÉ</kbd> ➜ <kbd>BU</kbd> et <kbd>ÉÈ</kbd> ➜ <kbd>UB</kbd></li>
	<li><kbd>ÈÊ</kbd> ➜ <kbd>YI</kbd></li>
</ul>
