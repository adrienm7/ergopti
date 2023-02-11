<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements_SFB from './roulements_sfb.svelte';
</script>

<svelte:head>
	<title>HyperTexte+</title>
	<meta name="description" content="About this app" />
</svelte:head>

<h1><Nom_Plus /></h1>

<p>
	<Nom_Plus /> est une version améliorée de la disposition <Nom />. Celle-ci nécessite cependant des
	outils de programmation de clavier spécifiques. Sur Windows, le programme
	<strong>AutoHotkey</strong> est utilisé afin de réaliser ces changements. Il est également possible
	de programmer le firmware de son clavier (avec QMK ou ZMK) pour ce faire.
</p>
<p>
	<Nom_Plus /> se rapproche de très près de la <strong>disposition clavier idéale</strong>.
	Effectivement, elle supprime la quasi-totalité des bigrammes à un doigt, rajoute de merveilleux
	roulements et réduit les distances parcourues. En outre, une touche spéciale de raccourci est
	ajoutée, permettant d’écrire rapidement les suffixes les plus courants en français et anglais.
	Ainsi, cela permet d’économiser plus de la moitié des frappes nécessaires pour les écrire en temps
	normal.
</p>
<petit-espace />
<p>
	Toutefois, ces nombreux avantages viennent à un prix. D’abord, il y a un effort d’apprentissage
	supplémentaire à effectuer. C’est d’autant plus difficile que ces raccourcis ne sont pas marqués
	sur le clavier, il faut donc les apprendre par cœur car regarder ses touches ne fournira aucune
	information. Le bon côté est que vous n’êtes pas obligé de tous les utiliser d’un coup, ce ne sont
	que des possibilités supplémentaires. Ainsi, le passage de <Nom /> vers <Nom_Plus /> se fait en douceur.
</p>
<p>
	Ensuite, et c’est le plus grand inconvénient, dans de très rares cas ces raccourcis vous
	empêcheront d’écrire ce que vous voulez réellement écrire. En effet, avec <Nom_Plus />, les
	combinaisons de touches extrêmement rares comme HC sont transformées en d’autres bien plus utiles
	comme WH. Cela signifie que dans les cas où vous voulez vraiment écrire HC, il faudra remettre à
	zéro le remplacement de texte.
</p>
<p>
	Cela peut notamment se faire en utilisant les flèches de navigation, la touche Échap, cliquant
	quelque part, etc. Ces manipulations ne devraient arriver que très rarement, mais tout dépend de
	votre utilisation. Par exemple, l’enchaînement XG est très peu commun, mais les data scientists
	l’utiliseront régulièrement pour écrire XGBoost. Si c’est le cas, vous avez la possibilité de
	désactiver certains des ajouts de <Nom_Plus />, de les modifier, ou d’ajouter des raccourcis pour
	les contourner (par exemple avec une macro qui écrit XGBoost).
</p>
<petit-espace />
<p>En résumé :</p>
<ul>
	<li>Utilisation de la touche À</li>
	<li>
		Utilisation de la touche È : pour certaines combinaisons de touches impossibles en français (ÈI,
		ÈO, etc.) ➜ J pour les voyelles, suppressions des SFB pour les autres
	</li>
</ul>

<p>Voici maintenant toutes les améliorations de <Nom_Plus /> :</p>

<petit-espace />

<Roulements_SFB />
<Abreviations />
<Confort />
<Raccourcis />
