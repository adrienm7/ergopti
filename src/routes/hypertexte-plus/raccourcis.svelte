<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<h2>Raccourcis</h2>

<h3>Tap-hold</h3>
<p>
	Le tap-hold permet d’assigner deux fonctions à une même touche : une lors d’un bref appui, et une
	lors de son maintien. C’est particulièrement adapté pour les touches modificatrices (<kbd
		>Shift</kbd
	>,
	<kbd>Control</kbd>, <kbd>Alt</kbd>, <kbd>AltGr</kbd>). Ainsi, il est possible d’utiliser la touche
	<kbd>AltGr</kbd> normalement, tout en y assignant une autre fonction lors d’un simple appui, par
	exemple
	<kbd>Tab</kbd>.
</p>
<p>
	Ces tap-holds ont été introduits afin de diminuer la distance parcourue par les doigts et
	améliorer le confort. Par exemple, la touche <kbd>Entrée</kbd> est régulièrement utilisée, mais est
	pourtant très loin. Elle nécessite de plus d’être pressée par l’auriculaire (droit), qui est le doigt
	le plus faible de notre main.
</p>
<ul>
	<li>Tap hold en <kbd>AltGr</kbd> ➜ <kbd-sortie>Tab</kbd-sortie> sur le tap ;</li>

	<li>
		Tap hold en <kbd>Alt</kbd> ➜ <kbd-sortie>Layer</kbd-sortie> en hold et
		<kbd-sortie>Enter</kbd-sortie> en tap ;
	</li>
	<p>
		La touche <kbd>Entrée</kbd> est très utilisée sur un clavier, elle l’est même plus que certaines
		consonnes. Toutefois, elle est peu accessible sur un clavier standard, nécessitant que
		l’auriculaire droit traverse 3 colonnes de lettres avant de l’atteindre. Par conséquent, placer
		cette touche sur <kbd>"Alt"</kbd> la ramène à un endroit extrêmement accessible. Cela supprime
		aussi beaucoup de <SFB />s. À noter que les raccourcis comme <kbd>Ctrl</kbd> + <kbd>Entrée</kbd>
		par exemple sont également fonctionnels avec cette nouvelle touche <kbd>Entrée</kbd>.
	</p>
	<BlocClavier nom="layer" />
	<p>
		Le <kbd>Layer</kbd> de navigation contient quant à lui les flèches directionnelles pour naviguer
		rapidement dans un texte, mais aussi toutes les combinaisons de ces flèches avec des
		modificateurs. Ainsi, il y a des raccourcis <kbd>Ctrl</kbd> + <kbd>Flèche</kbd>,
		<kbd>Ctrl</kbd>
		+
		<kbd>Shift</kbd>
		+
		<kbd>Flèche</kbd>, <kbd>Alt</kbd> + <kbd>Flèche</kbd>, <kbd>Alt</kbd> + <kbd>Shift</kbd> +
		<kbd>Flèche</kbd>, <kbd>Windows</kbd> + <kbd>Flèche</kbd>, etc. En outre, les raccourcis
		<kbd>Page Up</kbd>, <kbd>Page Down</kbd>, <kbd>Home</kbd> et <kbd>End</kbd> sont ajoutés. Ce layer
		de navigation évite donc des positions inconfortables nécessitant de presser plusieurs modificateurs
		en même temps ainsi que les touches de flèches qui sont peu accessibles.
	</p>
	<li>
		Tap hold en <kbd>"Tab"</kbd> ➜ <kbd-sortie>Alt</kbd-sortie> sur le hold et
		<kbd-sortie>Alt+Tab</kbd-sortie> sur le tap ;
	</li>
	<p>
		Ce raccourci est extrêmement pratique. Avec lui, il n’y a plus besoin de faire la combinaison <kbd
			>Alt</kbd
		>
		+ <kbd>Tab</kbd>. Seul un appui sur <kbd>Alt</kbd> suffit, ce qui transforme cette touche en sorte
		de toggle entre les fenêtres.
	</p>
	<li>
		Tap hold en <kbd>LShift</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>C</kbd-sortie> sur le
		tap ;
	</li>
	<li>
		Tap hold en <kbd>LCtrl</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> sur le
		tap ;
	</li>
	<p>
		Avoir la possibilité de <kbd-sortie>Coller</kbd-sortie> par appui de la main gauche sur une touche
		est très utile, particulièrement lorsque la souris est utilisée en même temps par la main droite.
		Cela permet de remplacer à la volée des parties de texte.
	</p>
	<li>
		Tap hold en <kbd>RControl</kbd> ➜ envoi <kbd-sortie>OneShot Shift</kbd-sortie> en tap,
		<kbd-sortie>Shift</kbd-sortie> en hold.
	</li>
	<p>
		Il est beaucoup plus judicieux de mettre <kbd>Shift</kbd> sous un pouce, afin d’éviter
		d’utiliser un auriculaire qui est le doigt le plus faible. Cela évite également beaucoup de <SFB
		></SFB>s. Dans de précédentes versions de <Nom></Nom>, <kbd>Shift</kbd> était même à la place de
		<kbd>Alt</kbd>, remplacé actuellement par le <kbd>Layer</kbd> de navigation. Cependant cela
		génère beaucoup de <SFB></SFB>s avec la barre d’espace et gâche un excellent emplacement sur la
		main gauche, permettant de démultiplier les possibilités à une main.
	</p>
</ul>

<h3>Raccourcis avec AltGr</h3>
<ul>
	<li><kbd>AltGr</kbd> + <kbd>"Alt"</kbd> ➜ <kbd-sortie>Capsword</kbd-sortie> ;</li>
	<p>
		<kbd>Capsword</kbd> est une sorte de
		<span class="important">CapsLock qui se désactive automatiquement</span>
		à la fin d’un "mot". Ainsi, CapsLock se désactive lors de la pression de
		<kbd>Espace</kbd>,
		<kbd>,</kbd> ou encore <kbd>Entrée</kbd>. Cette fonctionnalité peut être très utile pour écrire
		des abréviations telles que <kbd-sortie>QMK</kbd-sortie>,
		<kbd-sortie>ASCII</kbd-sortie>,
		<kbd-sortie>FAQ</kbd-sortie>, etc. De plus, elle permet également d’écrire plus aisément les
		noms des variables et constantes en programmation comme
		<kbd-sortie>KC_SPC</kbd-sortie>,
		<kbd-sortie>SERVER_NAME</kbd-sortie>, etc.
	</p>
	<li>
		<kbd>AltGr</kbd> + <kbd>"CapsLock"</kbd> (BackSpace) ➜ <kbd-sortie>Ctrl</kbd-sortie> +
		<kbd-sortie>BackSpace</kbd-sortie> ;
	</li>
	<p>
		La combinaison <kbd>Ctrl</kbd> + <kbd>BackSpace</kbd> permet de supprimer d’un coup le mot vers
		la gauche. <kbd>AltGr</kbd> est un modificateur très accessible sur n’importe quel clavier, étant
		sous le pouce droit. Par conséquent, ce raccourci permet de très rapidement corriger des erreurs
		de frappe.
	</p>
	<p>
		De plus, ajouter cette fonctionnalité sur la touche <kbd>"CapsLock"</kbd> (qui a été remappée en
		BackSpace) est un choix plutôt logique. Ainsi, tous les raccourcis de suppression sont à cet
		emplacement, car la touche <kbd-sortie>Delete</kbd-sortie> est quant à elle disponible en
		<kbd>Shift</kbd>
		+ <kbd>"CapsLock"</kbd>.
	</p>
	<!-- <li>
				<kbd>AltGr</kbd> + <kbd>LShift</kbd> ➜ <kbd-sortie>Dot-Space-Shift</kbd-sortie> =
				<kbd-sortie>.</kbd-sortie>
				+
				<kbd-sortie>Space</kbd-sortie>
				+ <kbd-sortie>Shift</kbd-sortie>
			</li> -->
	<!-- <p>
				Le <kbd>Dot-Space-Shift</kbd> envoie un <kbd-sortie>Point</kbd-sortie>, puis un
				<kbd-sortie>Espace</kbd-sortie>, puis active la touche
				<kbd-sortie>Shift</kbd-sortie>
				pour la prochaine touche pressée, avant de se désactiver. C’est un gain de temps et de confort,
				car en un seul raccourci, trois touches sont pressées, dont la touche <kbd>Shift</kbd> qui
				est peu confortable à presser sur claviers standards (car pressée par les auriculaires). Un
				autre avantage est que <kbd>Shift</kbd> ne s’active que pour le premier caractère de la
				nouvelle phrase. Ainsi, vous n’aurez plus jamais de <kbd-non>JE</kbd-non> ou de
				<kbd-non>THe</kbd-non> par exemple.
			</p> -->
</ul>

<h3>Raccourcis sur <kbd>"CapsLock"</kbd> (transformé en <kbd>BackSpace</kbd>)</h3>
<ul>
	<li>
		<kbd>Shift</kbd> + <kbd>"CapsLock"</kbd> (BackSpace) ➜ <kbd-sortie>Delete</kbd-sortie> ;
	</li>
	<li>
		<kbd>Windows</kbd> + <kbd>"CapsLock"</kbd> (BackSpace) ➜ <kbd-sortie>CapsLock</kbd-sortie>.
	</li>
</ul>
