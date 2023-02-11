<script>
	import Nom from '../../composants/Nom.svelte';
	import Nom_Plus from '../../composants/Nom_Plus.svelte';
	import SFB from '../../composants/SFB.svelte';
</script>

<h2>Raccourcis</h2>
<h3>Avec AltGr</h3>
<ul class="margin-top-2">
	<li><kbd>AltGr</kbd> + <kbd>Tab</kbd> ➜ <kbd-sortie>Capsword</kbd-sortie></li>
	<p>
		Capsword est une sorte de <strong>Capslock qui se désactive automatiquement</strong> à la fin
		d’un "mot". Ainsi, Capslock se désactive lors de la pression de <kbd>Espace</kbd>,
		<kbd>,</kbd> ou encore <kbd>Entrée</kbd>. Cette fonctionnalité peut être très utile pour écrire
		des abréviations telles que <em>QMK</em>, <em>ASCII</em>, <em>FAQ</em>, etc. De plus, elle
		permet également d’écrire plus aisément les noms des variables et constantes en programmation
		comme <em>KC_SPC</em>, <em>SERVER_NAME</em>, etc.
	</p>
	<li>
		<kbd>AltGr</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Ctrl</kbd-sortie> +
		<kbd-sortie>BackSpace</kbd-sortie>
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
		<kbd>AltGr</kbd> + <kbd>LShift</kbd> ➜ <kbd-sortie>Dot</kbd-sortie> +
		<kbd-sortie>Space</kbd-sortie>
		+ <kbd-sortie>Shift</kbd-sortie>
	</li>
	<p>
		Le Dot-Space-Shift envoie un point, puis un espace, puis active la touche Shift pour la
		prochaine touche pressée, avant de se désactiver. C’est un gain de temps et de confort, car en
		un seul raccourci, trois touches sont pressée, dont la touche Shift qui est peu confortable à
		presser sur claviers standards (car pressée par les auriculaires). Un autre avantage est que
		Shift ne s’active que pour le premier caractère de la nouvelle phrase. Ainsi, vous n’aurez plus
		jamais de <em>JE</em> ou de <em>THe</em> par exemple.
	</p>
	<li><kbd>AltGr</kbd> + <kbd>Y</kbd> ➜ <kbd-sortie>Échap</kbd-sortie></li>
	<li><kbd>AltGr</kbd> + <kbd>Z</kbd> ➜ <kbd-sortie>Home</kbd-sortie></li>
	<li><kbd>AltGr</kbd> + <kbd>Q</kbd> ➜ <kbd-sortie>End</kbd-sortie></li>
</ul>
<h3>Autres raccourcis sur "Capslock" (BackSpace)</h3>
<ul class="margin-top-2">
	<li><kbd>Shift</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Delete</kbd-sortie></li>
	<li>
		<kbd>Windows</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Capslock</kbd-sortie>
	</li>
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
	<li>Tap hold en <kbd>AltGr</kbd> ➜ <kbd-sortie>Entrée</kbd-sortie> sur le tap</li>
	<p>
		La touche Entrée est l’une des plus utilisée sur un clavier, elle l’est même plus que certaines
		consonnes. Toutefois, elle est peu accessible sur un clavier standard, nécessitant que
		l’auriculaire droit traverse 3 colonnes de lettres avant de l’atteindre. Par conséquent, placer
		cette touche sur la touche AltGr la ramène à un endroit extrêmement accessible. Cela empéche
		aussi beaucoup de <SFB />s.
	</p>
	<p>
		À noter que les raccourcis en Ctrl + Entrée par exemple ne sont pas pris en charge par cette
		nouvelle touche Entrée. En effet, techniquement la touche AltGr équivaut à presser Ctrl + Alt,
		donc il n’est pas possible de dire que Ctrl + AltGr fait une certaine action, Ctrl étant déjà
		inclus dans AltGr. Pour les raccourcis Ctrl + Enter, il faudra donc se rabattre sur la vraie
		touche Entrée, qui fonctionne exactement comme avant.
	</p>

	<li>
		Tap hold en <kbd>Alt</kbd> ➜ <kbd-sortie>Alt</kbd-sortie> + <kbd-sortie>Tab</kbd-sortie> sur le tap
	</li>
	<p>
		Ce raccourci est extrêmement pratique. Plus besoin de faire la combinaison Alt+Tab, seul un
		appui sur Tab suffit, ce qui le transfore en sorte de toggle entre les fenêtres.
	</p>
	<li>
		Tap hold en <kbd>LCtrl</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> sur le
		tap
	</li>
	<p>
		Avoir la possibilité de "Coller" par appui de la main gauche sur une touche est très utile,
		particulièrement lorsque la souris est utilisée en même temps par la main droite. Cela permet de
		remplacer à la volée des parties de texte.
	</p>
	<li>Tap hold en <kbd>Espace</kbd> ➜ <kbd-sortie>Layer de navigation</kbd-sortie> en hold</li>
	<p>
		Ce layer de navigation contient les flèches directionnelles pour naviguer rapidement dans un
		texte, mais aussi toutes les combinaisons de ces flèches avec des modificateurs. Ainsi, il y a
		des raccourcis Ctrl + Flèche, Ctrl + Shift + Flèche, Alt + Flèche, Alt + Shift + Flèche, Windows
		+ Flèche, etc. En outre, les raccourcis Page Up, Page Down, Home et End sont ajoutés. Ce layer
		de navigation vous évite donc des positions inconfortables nécessitant de presser plusieurs
		modificateurs en même temps ainsi que les touches de flèches qui sont peu accessibles.
	</p>
</ul>
