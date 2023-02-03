<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
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
<p>Voici maintenant toutes les améliorations de <Nom_Plus /> :</p>
<petit-espace />
<h2>Ajout d’excellents roulements et suppression des SFB majeurs</h2>
(WH, PT, GT, XP, BU et UB, SCH, SCR)
<ul>
	<li>SC</li>
	<li>WH</li>
	<li>TH</li>
	<li>PT</li>
	<li>XP</li>
	<li>BU et UB</li>
	<li>EO et OE</li>
	<li>YI</li>
</ul>
<h2>[QU] automatiques avant les voyelles</h2>
<h2>Utilisation de la touche À : en tant que J</h2>
<h2>Utilisation de la touche À : pour éviter des SFBs</h2>
<h2>
	Utilisation de la touche È : pour certaines combinaisons de touches impossibles en français (ÈI,
	ÈO, etc.) ➜ J pour les voyelles, suppressions des SFB pour les autres
</h2>
<h2>ê fait office de ^</h2>
<h2>Remplacement automatique des ’ pour l’anglais : t’s, n't</h2>
<h2>Ajout des suffixes les plus communs en , pour encore plus optimiser</h2>
<h2>Autres</h2>
<ul>
	<li>Shift + "Capslock" (BackSpace) = Delete</li>
	<li>AltGr + "Capslock" (BackSpace) = Ctrl + BackSpace</li>
	<li>Windows + "Capslock" (BackSpace) = Capslock</li>
</ul>
<ul>
	<li>AltGr + LShift = Dot shift space</li>
	<li>AltGr + Tab = Capsword</li>
</ul>
<ul>
	<li>Tap hold en AltGr = Entrée sur le tap</li>
	<li>Tap hold en Alt = Alt+Tab sur le tap</li>
	<li>Tap hold en Space = layer de navigation en hold</li>
</ul>
