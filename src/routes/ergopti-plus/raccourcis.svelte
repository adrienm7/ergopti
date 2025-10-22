<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<section>
	<h2>Raccourcis</h2>

	<h3>Tap-holds</h3>
	<p>
		Le tap-hold permet d’assigner deux fonctions à une même touche : une lors d’un bref appui, et
		une lors de son maintien. C’est particulièrement adapté pour les touches modificatrices (<kbd
			>Shift</kbd
		>,
		<kbd>Control</kbd>, <kbd>Alt</kbd>, <kbd>AltGr</kbd>). Ainsi, il est possible d’utiliser la
		touche
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
		<li>Tap hold en <kbd>AltGr</kbd> ➜ <kbd-output>Tab</kbd-output> sur le tap ;</li>
		<li>
			Tap hold en <kbd>Alt</kbd> ➜ <kbd-output>Shift</kbd-output> en hold et
			<kbd-output>OneShotShift</kbd-output> en tap ;
		</li>
		<p>
			Il est beaucoup plus judicieux de mettre <kbd>Shift</kbd> sous un pouce, afin d’éviter
			d’utiliser un auriculaire qui est le doigt le plus faible. Cela évite également beaucoup de <SFB
			></SFB>s.
		</p>
		<li>
			Tap hold en <kbd>"CapsLock"</kbd> ➜ <kbd-output>Ctrl</kbd-output> sur le hold et
			<kbd-output>Enter</kbd-output> sur le tap ;
		</li>
		<p>
			La touche <kbd>Entrée</kbd> est très utilisée sur un clavier, elle l’est même plus que
			certaines consonnes. Toutefois, elle est peu accessible sur un clavier standard, nécessitant
			que l’auriculaire droit traverse 3 colonnes de lettres avant de l’atteindre. Par conséquent,
			placer cette touche sur <kbd>"Alt"</kbd> la ramène à un endroit extrêmement accessible. Cela
			supprime aussi beaucoup de <SFB />s. À noter que les raccourcis comme <kbd>Ctrl</kbd> +
			<kbd>Entrée</kbd>
			par exemple sont également fonctionnels avec cette nouvelle touche <kbd>Entrée</kbd>.
		</p>
		<li>
			Tap hold en <kbd>"Tab"</kbd> ➜ <kbd-output>Alt</kbd-output> sur le hold et
			<kbd-output>Alt+Tab</kbd-output> sur le tap ;
		</li>
		<p>
			Ce raccourci est extrêmement pratique. Avec lui, il n’y a plus besoin de faire la combinaison <kbd
				>Alt</kbd
			>
			+ <kbd>Tab</kbd>. Seul un appui sur <kbd>Alt</kbd> suffit, ce qui transforme cette touche en sorte
			de toggle entre les fenêtres.
		</p>

		<small-space></small-space>

		<KeyboardBasis id="layer" />
		<p>
			Le <kbd>Layer</kbd> de navigation contient quant à lui les flèches directionnelles pour
			naviguer rapidement dans un texte, mais aussi toutes les combinaisons de ces flèches avec des
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

		<small-space></small-space>

		<li>
			Tap hold en <kbd>LShift</kbd> ➜ <kbd-output>Ctrl</kbd-output> + <kbd-output>C</kbd-output> sur
			le tap ;
		</li>
		<li>
			Tap hold en <kbd>LCtrl</kbd> ➜ <kbd-output>Ctrl</kbd-output> + <kbd-output>V</kbd-output> sur le
			tap ;
		</li>
		<p>
			Avoir la possibilité de <kbd-output>Coller</kbd-output> par appui de la main gauche sur une touche
			est très utile, particulièrement lorsque la souris est utilisée en même temps par la main droite.
			Cela permet de remplacer à la volée des parties de texte.
		</p>
	</ul>

	<h3>Raccourcis avec AltGr</h3>
	<ul>
		<li>
			<kbd>AltGr</kbd> + <kbd>"LAlt"</kbd> ➜ <kbd-output>Ctrl</kbd-output> +
			<kbd-output>BackSpace</kbd-output> ;
		</li>
		<p>
			La combinaison <kbd>Ctrl</kbd> + <kbd>BackSpace</kbd> permet de supprimer d’un coup le mot
			vers la gauche. <kbd>AltGr</kbd> est un modificateur très accessible, étant sous le pouce droit.
			Par conséquent, ce raccourci permet de très rapidement corriger des erreurs de frappe.
		</p>
		<li>
			<kbd>AltGr</kbd> + <kbd>"CapsLock"</kbd> ➜ <kbd-output>Ctrl</kbd-output> +
			<kbd-output>Delete</kbd-output>.
		</li>
		<p>Le principe est le même, sauf qu’ici on supprime le mot à droite.</p>
		<!-- <li>
				<kbd>AltGr</kbd> + <kbd>LShift</kbd> ➜ <kbd-output>Dot-Space-Shift</kbd-output> =
				<kbd-output>.</kbd-output>
				+
				<kbd-output>Space</kbd-output>
				+ <kbd-output>Shift</kbd-output>
			</li> -->
		<!-- <p>
				Le <kbd>Dot-Space-Shift</kbd> envoie un <kbd-output>Point</kbd-output>, puis un
				<kbd-output>Espace</kbd-output>, puis active la touche
				<kbd-output>Shift</kbd-output>
				pour la prochaine touche pressée, avant de se désactiver. C’est un gain de temps et de confort,
				car en un seul raccourci, trois touches sont pressées, dont la touche <kbd>Shift</kbd> qui
				est peu confortable à presser sur claviers standards (car pressée par les auriculaires). Un
				autre avantage est que <kbd>Shift</kbd> ne s’active que pour le premier caractère de la
				nouvelle phrase. Ainsi, vous n’aurez plus jamais de <kbd-non>JE</kbd-non> ou de
				<kbd-non>THe</kbd-non> par exemple.
			</p> -->
	</ul>

	<h3>Raccourcis avec <kbd>"CapsLock"</kbd> (transformé en <kbd>Enter</kbd>)</h3>
	<ul>
		<li><kbd>"LAlt"</kbd> + <kbd>"CapsLock"</kbd> ➜ <kbd-output>CapsWord</kbd-output> ;</li>
		<p>
			<kbd>CapsWord</kbd> est une sorte de
			<strong>CapsLock qui se désactive automatiquement</strong>
			à la fin d’un "mot". Ainsi, CapsLock se désactive lors de la pression de
			<kbd>Espace</kbd>, <kbd>,</kbd> ou encore <kbd>Entrée</kbd>. Cette fonctionnalité peut être
			très utile pour écrire des abréviations telles que <kbd-output>QMK</kbd-output>,
			<kbd-output>ASCII</kbd-output>, <kbd-output>FAQ</kbd-output>, etc. De plus, elle permet
			d’écrire plus aisément les noms des variables et constantes en programmation comme
			<kbd-output>KC_SPC</kbd-output>, <kbd-output>SERVER_NAME</kbd-output>, etc.
		</p>
		<li>
			<kbd>Windows</kbd> + <kbd>"CapsLock"</kbd> ➜ <kbd-output>CapsLock</kbd-output>, pour ne pas
			perdre la fonctionnalité.
		</li>
	</ul>
</section>
