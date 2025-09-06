<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<h2>Optimisation pour l’utilisation à&nbsp;une&nbsp;main</h2>

<p>
	Lors de l’utilisation d’un ordinateur, la plupart du temps la souris est tenue de la main droite
	et la main gauche repose près de la partie gauche du clavier. Quand vient le moment de taper sur
	une touche ou de réaliser une combinaison de touches pour faire un raccourci, il est bien souvent
	nécessaire de bouger la main droite. Celle-ci doit se déplacer de la souris à la partie droite du
	clavier, taper dessus, puis retourner à la souris pour continuer la navigation.
</p>
<p>
	Par conséquent, il est également important de s’assurer que, grâce à sa disposition clavier,
	beaucoup d’actions courantes puissent se réaliser avec la seule main gauche <span
		class="important">afin de ne pas avoir à lâcher la souris</span
	>. À noter que sur ce point AZERTY est très bon car <kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd>
	et de nombreuses autres lettres fréquemment utilisées pour faire des raccourcis en combinaison avec
	<kbd>Ctrl</kbd> sont du côté gauche.
</p>
<p>
	Avec <Ergopti />, le <kbd>=</kbd> a ainsi été dupliqué à gauche pour être mis en accès direct.
	Cela permet de faire facilement des raccourcis, notamment sur Excel, tels que <kbd>=</kbd> et
	<kbd>Alt</kbd>
	+
	<kbd>=</kbd>. En effet, normalement le <kbd>=</kbd> se situe en <kbd>AltGr</kbd> +
	<kbd>L</kbd>.
</p>

<h3>
	Conservation des raccourcis <kbd>Ctrl</kbd> + <kbd>X</kbd>, <kbd>C</kbd>, <kbd>V</kbd> et
	<kbd>Z</kbd>
</h3>

<KeyboardBasis name="controle" />
<tiny-space></tiny-space>
<p>
	Les raccourcis <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>X</kbd-sortie>,
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>C</kbd-sortie>,
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>V</kbd-sortie> et <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>Z</kbd-sortie>
	sont également conservés à gauche. Cela permet de les réaliser sans avoir à bouger la main droite.
	Ils sont respectivement en <kbd>Ctrl</kbd> + <kbd>Ê</kbd>, <kbd>Ctrl</kbd> +
	<kbd>É</kbd>,
	<kbd>Ctrl</kbd>
	+ <kbd>À</kbd> et <kbd>Ctrl</kbd> + <kbd>È</kbd>.
</p>

<h3>Touches de raccourci sur la version Ergodox</h3>
<KeyboardBasis name="raccourcis_ergodox" />
<tiny-space></tiny-space>
<p>
	La version d’<Ergopti /> adaptée aux claviers de type Ergodox est complètement optimisée pour l’utilisation
	à une main, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
	<kbd>Alt+Tab</kbd> ont été directement incluses à gauche du clavier. À noter que ces touches ne sont
	pas définies dans le pilote et que ce sont uniquement des idées d’implémentation. Les claviers de type
	Ergodox peuvent en effet être programmés pour ajouter et déplacer des touches.
</p>

<h3>Touches de raccourci sur la version ISO</h3>
<p>
	La version ISO (pour claviers standards) ne peut quant à elle malheureusement pas bénéficier des
	touches de raccourci de la version Ergodox, car les touches à sa gauche sont déjà occupées par les
	touches
	<kbd>Shift</kbd>, <kbd>"CapsLock"</kbd> et <kbd>Tab</kbd> contrairement à l’Ergodox où l’on peut placer
	ces 3 touches sous les pouces.
</p>
<p>
	<ErgoptiPlus /> donne toutefois le moyen de contourner les limites de la version ISO grâce à un
	<span class="important">mécanisme de tap-hold</span>. L’idée du tap-hold est qu’il est possible
	d’assigner deux actions à une même touche : une au tap (appui bref) et une au hold (maintenir
	pressé). Grâce au tap-hold, il devient possible d’avoir le comportement suivant : taper une touche
	envoie un raccourci, mais la presser la fait se comporter normalement. Cela permet d’intégrer des
	touches
	<kbd-sortie>Copier</kbd-sortie>, <kbd-sortie>Coller</kbd-sortie> et
	<kbd-sortie>Alt+Tab</kbd-sortie>
	respectivement sur
	<kbd>LShift</kbd>, <kbd>LCtrl</kbd> et <kbd>Alt</kbd>. En outre, un layer de navigation ainsi que
	les touches
	<kbd>Backspace</kbd>
	et <kbd>Entrée</kbd> sont également disponibles à gauche du clavier avec <ErgoptiPlus
	></ErgoptiPlus>.
</p>
