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

<h2>Utilisation de la touche <kbd>À</kbd> : pour éviter des SFBs</h2>
<h2>
	Utilisation de la touche È : pour certaines combinaisons de touches impossibles en français (ÈI,
	ÈO, etc.) ➜ J pour les voyelles, suppressions des SFB pour les autres
</h2>

<h2>Ajout des suffixes les plus communs en <kbd>,</kbd> pour encore plus optimiser</h2>
<p>
	Il y a toujours un espace après la virgule (sauf si l’on écrit des nombres). Par conséquent, toute
	combinaison de type <kbd>,s</kbd> ou <kbd>,c</kbd> n’est jamais tapée. Cela donne une opportunité
	extraordinaire de raccourcis pour augmenter sa vitesse et son confort de frappe. Par exemple, au
	lieu de taper 5 lettres pour écrire le suffixe <kbd>EMENT</kbd>, très souvent utilisé en français,
	deux frappes suffisent : <kbd>,S</kbd>. Ces raccourcis vont diviser par deux le nombre de touches
	nécessaires pour écrire les suffixes les plus communs, entrainant une petite augmentation de
	vitesse.
</p>
<p>
	Le confort est aussi visé, par exemple pour la combinaison <em>GHT</em> qui est un peu
	inconfortable à faire en <Nom />, car il faut frapper de l’annulaire droit, du majeur droit, puis
	encore de l’annulaire droit. Ce n’est pas un beau roulement, alors qu’au contraire <kbd>,I</kbd>
	écrira <em>IGHT</em> et <kbd>,O</kbd> écrira <em>OUGH</em>.
</p>
<h2>Raccourcis</h2>
<h3>Avec AltGr</h3>
<ul class="margin-top-2">
	<li><kbd>AltGr</kbd> + <kbd>Tab</kbd> ➜ <kbd>Capsword</kbd></li>
	<p>
		Capsword est une sorte de <strong>Capslock qui se désactive automatiquement</strong> à la fin
		d’un "mot". Ainsi, Capslock se désactive lors de la pression de <kbd>Espace</kbd>,
		<kbd>,</kbd>
		ou encore
		<kbd>Entrée</kbd>. Cette fonctionnalité peut être très utile pour écrire des abréviations telles
		que <em>QMK</em>, <em>ASCII</em>, <em>FAQ</em>, etc. De plus, elle permet également d’écrire
		plus aisément les noms des variables et constantes en programmation comme <em>KC_SPC</em>,
		<em>SERVER_NAME</em>, etc.
	</p>
	<li>
		<kbd>AltGr</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd>Ctrl</kbd> + <kbd>BackSpace</kbd>
	</li>
	<p>
		Ctrl + BackSpace permet de supprimer en une fois le mot vers la gauche. AltGr est un
		modificateur très accessible sur n’importe quel clavier, étant sous le pouce droit. Par
		conséquent, ce raccourci permet de très rapidement corriger des erreurs de frappe.
	</p>
	<p>
		De plus, ajouter cette fonctionnalité sur la touche "Capslock" (qui a été remappée en BackSpace)
		est un choix plutôt logique. Ainsi, tous les raccourcis de suppression sont à cet emplacement,
		car la touche Suppr. est quant à elle disponible en Shift + "Capslock".
	</p>
	<li>
		<kbd>AltGr</kbd> + <kbd>LShift</kbd> ➜ <kbd>Dot</kbd> + <kbd>Space</kbd> + <kbd>Shift</kbd>
	</li>
	<p>
		Le dot-space-shift envoie un point, puis un espace, puis active la touche Shift pour la
		prochaine touche pressée, avant de se désactiver. C’est un gain de temps et de confort, car en
		un seul raccourci, trois touches sont pressée, dont la touche Shift qui est peu confortable à
		presser sur claviers standards (car pressée par les auriculaires). Un autre avantage est que
		Shift ne s’active que pour le premier caractère de la nouvelle phrase. Ainsi, vous n’aurez plus
		jamais de <em>JE</em> ou de <em>THe</em> par exemple.
	</p>
</ul>
<h3>Autres raccourcis sur "Capslock" (BackSpace)</h3>
<ul class="margin-top-2">
	<li><kbd>Shift</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd>Delete</kbd></li>
	<li><kbd>Windows</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd>Capslock</kbd></li>
</ul>
<h3>Tap-hold</h3>
<p>
	Le tap-hold permet d’assigner deux fonctions à une même touche : une lors d’un bref appui, et une
	lors de son maintien. C’est particulièrement adapté pour les touches modificatrices (Shift,
	Control, Alt, AltGr). Ainsi, il est possible d’utiliser la touche AltGr normalementt, tout en y
	assignant une autre touche lors d’un simple appui, par exemple Entrée.
</p>
<p>
	Ces tap-holds ont été introduits afin de diminuer la distance parcourue par les doigts et
	améliorer le confort. Par exemple, la touche Entrée est régulièrement utilisée mais est pourtant
	très loin. Elle nécessite de plus d’être pressée par l’auriculaire (droit), qui est le doigt le
	plus faible de notre main.
</p>
<ul class="margin-top-2">
	<li>Tap hold en <kbd>AltGr</kbd> ➜ <kbd>Entrée</kbd> sur le tap</li>
	<p>
		La touche Entrée est l’une des plus utilisée sur un clavier, elle l’est même plus que certaines
		consonnes. Toutefois, elle est peu accessible sur un clavier standard, nécessitant que
		l’auriculaire droit traverse 3 colonnes de lettres avant de l’atteindre. Par conséquent, placer
		cette touche sur la touche AltGr la ramène à un endroit extrêmement accessible. Cela empéche
		aussi beaucoup de SFBs.
	</p>
	<p>
		À noter que les raccourcis en Ctrl + Entrée par exemple ne sont pas pris en charge par cette
		nouvelle touche Entrée. En effet, techniquement la touche AltGr équivaut à presser Ctrl + Alt,
		donc il n’est pas possible de dire que Ctrl + AltGr fait une certaine action, Ctrl étant déjà
		inclus dans AltGr. Pour les raccourcis Ctrl + Enter, il faudra donc se rabattre sur la vraie
		touche Entrée, qui fonctionne exactement comme avant.
	</p>

	<li>Tap hold en <kbd>Alt</kbd> ➜ <kbd>Alt</kbd> + <kbd>Tab</kbd> sur le tap</li>
	<p>
		Ce raccourci est extrêmement pratique. Plus besoin de faire la combinaison Alt+Tab, seul un
		appui sur Tab suffit, ce qui le transfore en sorte de toggle entre les fenêtres.
	</p>
	<li>Tap hold en <kbd>LCtrl</kbd> ➜ <kbd>Ctrl</kbd> + <kbd>V</kbd> sur le tap</li>
	<p>
		Avoir la possibilité de "Coller" par appui de la main gauche sur une touche est très utile,
		particulièrement lorsque la souris est utilisée en même temps par la main droite. Cela permet de
		remplacer à la volée des parties de texte.
	</p>
	<li>Tap hold en <kbd>Espace</kbd> ➜ Layer de navigation en hold</li>
	<p>
		Ce layer de navigation contient les flèches directionnelles pour naviguer rapidement dans un
		texte, mais aussi toutes les combinaisons de ces flèches avec des modificateurs. Ainsi, il y a
		des raccourcis Ctrl + Flèche, Ctrl + Shift + Flèche, Alt + Flèche, Alt + Shift + Flèche, Windows
		+ Flèche, etc. En outre, les raccourcis Page Up, Page Down, Home et End sont ajoutés. Ce layer
		de navigation vous évite donc des positions inconfortables nécessitant de presser plusieurs
		modificateurs en même temps ainsi que les touches de flèches qui sont peu accessibles.
	</p>
</ul>

<h2>Ajouts de confort</h2>
<h3>[QU] automatiques avant les voyelles</h3>
<p>La touche q est à 99% suivie de u si une voyelle vient ensuite.</p>
<h3>[où]</h3>
<p>
	La touche <kbd>Ù</kbd> n’est utilisée que pour écrire <em>où</em>. Ainsi, autant tranformer cette
	touche en raccourci pour écrire <kbd>où</kbd> pour économiser une frappe certaine sur la touche
	<kbd>O</kbd> et améliorer l’alternance des mains.
</p>
<h3>Utilisation de la touche <kbd>À</kbd> : en tant que J</h3>
<p>
	La touche <kbd>J</kbd> est très loin et pourtant relativement souvent utilisée en français,
	notammentt pour écrire <em>je</em>
</p>
<h3><kbd>Ê</kbd> fait office de <kbd>^</kbd></h3>
<p>
	La touche morte ^ est très loin sur un clavier standard. La majorité des fois elle est utilisée
	pour écrire ê, qui est une touche présente sur l’annulaire gauche. Toutefois, dans de rares cas il
	est nécessaire de taper â, î, ô ou encore û. C’est pour cela que <kbd>ÊA</kbd> donne Â par exemple.
</p>
<p>
	À noter que pour écrire Î, plutôt que de faire un SFB en tapant <kbd>ÊI</kbd>, vous pouvez aussi
	faire <kbd>ÊE</kbd>.
</p>
<h3>Remplacement automatique des <kbd>’</kbd> par <kbd>'</kbd> pour l’anglais</h3>
<p>
	En anglais, l’apostrophe typographique n’est pas utilisée. Afin d’écrire "correctement" en anglais
	sans perte de vitesse ni besoin de réflexion pour savoir quelle apostrophe taper, des
	remplacements de texte ont été introduits. Ainsi, t’s et n’t sont automatiquement remplacés par
	les bonnes apostrophes : t's et n't.
</p>
<p>
	Un autre raccourci a été ajouté pour avoir la possibilité d’écrire n't par un roulement. Ainsi,
	nt’ se transforme en n't pour pouvoir faire majeur, annulaire, auriculaire plutôt que majeur,
	auriculaire, annulaire.
</p>
