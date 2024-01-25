<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section>
	<h3 data-aos="fade-right" data-aos-mirror="true">Raccourcis avec AltGr</h3>
	<div class="content">
		<ul>
			<li><kbd>AltGr</kbd> + <kbd>Tab</kbd> ➜ <kbd-sortie>Capsword</kbd-sortie></li>
			<p>
				<kbd>Capsword</kbd> est une sorte de
				<span class="important">Capslock qui se désactive automatiquement</span>
				à la fin d’un "mot". Ainsi, Capslock se désactive lors de la pression de
				<kbd>Espace</kbd>,
				<kbd>,</kbd> ou encore <kbd>Entrée</kbd>. Cette fonctionnalité peut être très utile pour
				écrire des abréviations telles que <kbd-sortie>QMK</kbd-sortie>,
				<kbd-sortie>ASCII</kbd-sortie>,
				<kbd-sortie>FAQ</kbd-sortie>, etc. De plus, elle permet également d’écrire plus aisément les
				noms des variables et constantes en programmation comme
				<kbd-sortie>KC_SPC</kbd-sortie>,
				<kbd-sortie>SERVER_NAME</kbd-sortie>, etc.
			</p>
			<li>
				<kbd>AltGr</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Ctrl</kbd-sortie> +
				<kbd-sortie>BackSpace</kbd-sortie>
			</li>
			<p>
				La combinaison <kbd>Ctrl</kbd> + <kbd>BackSpace</kbd> permet de supprimer d’un coup le mot
				vers la gauche. <kbd>AltGr</kbd> est un modificateur très accessible sur n’importe quel clavier,
				étant sous le pouce droit. Par conséquent, ce raccourci permet de très rapidement corriger des
				erreurs de frappe.
			</p>
			<p>
				De plus, ajouter cette fonctionnalité sur la touche <kbd>"Capslock"</kbd> (qui a été
				remappée en BackSpace) est un choix plutôt logique. Ainsi, tous les raccourcis de
				suppression sont à cet emplacement, car la touche <kbd-sortie>Suppr.</kbd-sortie> est quant
				à elle disponible en
				<kbd>Shift</kbd>
				+ <kbd>"Capslock"</kbd>.
			</p>
			<li>
				<kbd>AltGr</kbd> + <kbd>LShift</kbd> ➜ <kbd-sortie>Dot-Space-Shift</kbd-sortie> =
				<kbd-sortie>.</kbd-sortie>
				+
				<kbd-sortie>Space</kbd-sortie>
				+ <kbd-sortie>Shift</kbd-sortie>
			</li>
			<p>
				Le <kbd>Dot-Space-Shift</kbd> envoie un <kbd-sortie>Point</kbd-sortie>, puis un
				<kbd-sortie>Espace</kbd-sortie>, puis active la touche
				<kbd-sortie>Shift</kbd-sortie>
				pour la prochaine touche pressée, avant de se désactiver. C’est un gain de temps et de confort,
				car en un seul raccourci, trois touches sont pressées, dont la touche <kbd>Shift</kbd> qui
				est peu confortable à presser sur claviers standards (car pressée par les auriculaires). Un
				autre avantage est que <kbd>Shift</kbd> ne s’active que pour le premier caractère de la
				nouvelle phrase. Ainsi, vous n’aurez plus jamais de <kbd-non>JE</kbd-non> ou de
				<kbd-non>THe</kbd-non> par exemple.
			</p>
			<li><kbd>AltGr</kbd> + <kbd>J</kbd> ➜ <kbd-sortie>Échap</kbd-sortie></li>
			<li><kbd>AltGr</kbd> + <kbd>Z</kbd> ➜ <kbd-sortie>Home</kbd-sortie></li>
			<li><kbd>AltGr</kbd> + <kbd>Q</kbd> ➜ <kbd-sortie>End</kbd-sortie></li>
		</ul>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">Autres raccourcis sur "Capslock" (BackSpace)</h3>
	<div class="content">
		<ul>
			<li>
				<kbd>Shift</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Delete</kbd-sortie>
			</li>
			<li>
				<kbd>Windows</kbd> + <kbd>"Capslock"</kbd> (BackSpace) ➜ <kbd-sortie>Capslock</kbd-sortie>
			</li>
		</ul>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">Raccourcis en <kbd>Ctrl</kbd></h3>
	<div class="content">
		<p>
			Sur la main gauche, <kbd>Ctrl</kbd> + <kbd>É</kbd> donne <kbd-sortie>Ctrl +</kbd-sortie> et
			<kbd>Ctrl</kbd>
			+ <kbd>È</kbd> donne <kbd-sortie>Ctrl -</kbd-sortie>. Ces raccourcis permettent de zoomer et
			dézoomer.
		</p>
	</div>

	<h3 data-aos="fade-right" data-aos-mirror="true">Tap-hold</h3>
	<div class="content">
		<p>
			Le tap-hold permet d’assigner deux fonctions à une même touche : une lors d’un bref appui, et
			une lors de son maintien. C’est particulièrement adapté pour les touches modificatrices (<kbd
				>Shift</kbd
			>,
			<kbd>Control</kbd>, <kbd>Alt</kbd>, <kbd>AltGr</kbd>). Ainsi, il est possible d’utiliser la
			touche
			<kbd>AltGr</kbd> normalement, tout en y assignant une autre fonction lors d’un simple appui,
			par exemple
			<kbd-sortie>Entrée</kbd-sortie>.
		</p>
		<p>
			Ces tap-holds ont été introduits afin de diminuer la distance parcourue par les doigts et
			améliorer le confort. Par exemple, la touche <kbd>Entrée</kbd> est régulièrement utilisée, mais
			est pourtant très loin. Elle nécessite de plus d’être pressée par l’auriculaire (droit), qui est
			le doigt le plus faible de notre main.
		</p>
		<ul>
			<li>Tap hold en <kbd>AltGr</kbd> ➜ <kbd-sortie>Entrée</kbd-sortie> sur le tap</li>
			<p>
				La touche <kbd>Entrée</kbd> est l’une des plus utilisée sur un clavier, elle l’est même plus
				que certaines consonnes. Toutefois, elle est peu accessible sur un clavier standard,
				nécessitant que l’auriculaire droit traverse 3 colonnes de lettres avant de l’atteindre. Par
				conséquent, placer cette touche sur la touche <kbd>AltGr</kbd> la ramène à un endroit
				extrêmement accessible. Cela supprime aussi beaucoup de <SFB />s.
			</p>
			<p>
				À noter que les raccourcis comme <kbd>Ctrl</kbd> + <kbd>Entrée</kbd> par exemple ne sont pas
				pris en charge par cette nouvelle touche <kbd>Entrée</kbd>. En effet, techniquement la
				touche
				<kbd>AltGr</kbd>
				équivaut à presser
				<kbd>Ctrl</kbd> + <kbd>Alt</kbd>, donc il n’est pas possible de dire que <kbd>Ctrl</kbd> +
				<kbd>AltGr</kbd>
				fait une certaine action, <kbd>Ctrl</kbd> étant déjà inclus dans <kbd>AltGr</kbd>. Pour les
				raccourcis <kbd>Ctrl</kbd> + <kbd>Enter</kbd>, il faudra donc se rabattre sur la vraie
				touche
				<kbd>Entrée</kbd>, qui fonctionne exactement comme avant.
			</p>

			<li>
				Tap hold en <kbd>Alt</kbd> ➜ <kbd-sortie>Alt</kbd-sortie> + <kbd-sortie>Tab</kbd-sortie> sur
				le tap
			</li>
			<p>
				Ce raccourci est extrêmement pratique. Avec lui, il n’y a plus besoin de faire la
				combinaison <kbd>Alt</kbd>
				+ <kbd>Tab</kbd>. Seul un appui sur <kbd>Alt</kbd> suffit, ce qui transforme cette touche en
				sorte de toggle entre les fenêtres.
			</p>
			<li>
				Tap hold en <kbd>LCtrl</kbd> ➜ <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> sur
				le tap
			</li>
			<p>
				Avoir la possibilité de <kbd-sortie>"Coller"</kbd-sortie> par appui de la main gauche sur une
				touche est très utile, particulièrement lorsque la souris est utilisée en même temps par la main
				droite. Cela permet de remplacer à la volée des parties de texte.
			</p>
			<li>
				Tap hold en <kbd>Espace</kbd> ➜ <kbd-sortie>Layer de navigation</kbd-sortie> en hold
			</li>
			<p>
				Ce layer de navigation contient les flèches directionnelles pour naviguer rapidement dans un
				texte, mais aussi toutes les combinaisons de ces flèches avec des modificateurs. Ainsi, il y
				a des raccourcis <kbd>Ctrl</kbd> + <kbd>Flèche</kbd>, <kbd>Ctrl</kbd> +
				<kbd>Shift</kbd>
				+
				<kbd>Flèche</kbd>, <kbd>Alt</kbd> + <kbd>Flèche</kbd>, <kbd>Alt</kbd> + <kbd>Shift</kbd> +
				<kbd>Flèche</kbd>, <kbd>Windows</kbd> + <kbd>Flèche</kbd>, etc. En outre, les raccourcis
				<kbd>Page Up</kbd>, <kbd>Page Down</kbd>, <kbd>Home</kbd> et <kbd>End</kbd> sont ajoutés. Ce
				layer de navigation vous évite donc des positions inconfortables nécessitant de presser plusieurs
				modificateurs en même temps ainsi que les touches de flèches qui sont peu accessibles.
			</p>
		</ul>
	</div>
</section>
