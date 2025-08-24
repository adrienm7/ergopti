<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
</script>

<div>
	<h1 data-aos="zoom-in" class="ergopti-title">
		Disposition clavier<br /><span style="line-height: 0.75!important;"
			><ErgoptiPlus></ErgoptiPlus></span
		>
	</h1>
	<BlocClavier nom="presentation_plus" />
	<mini-espace />
	<BlocControlesClavier nom="presentation_plus" />
</div>

<petit-espace />

<hr />
<p class="main text-center">
	<ErgoptiPlus /> est une variante améliorée de la disposition <Ergopti /> qui tire parti des meilleures
	fonctionnalités des claviers programmables et outils d’automatisation. Elle se rapproche de très près
	de la
	<span class="important">disposition clavier idéale</span>. En effet, elle :
</p>
<div class="cards">
	<div class="card">
		<i class="icon-circle-1"><span class="path1"></span><span class="path2"></span></i>
		Ajoute de
		<span class="text-bold">nouveaux roulements</span> extrêmement confortables.
	</div>
	<div class="card">
		<i class="icon-circle-2"><span class="path1"></span><span class="path2"></span></i>
		<span class="important"
			>Éradique la quasi-totalité des <span class="nowrap"><SFB />s</span></span
		> pour une frappe ultra-fluide et sans inconfort.
	</div>
	<div class="card">
		<i class="icon-circle-3"><span class="path1"></span><span class="path2"></span></i>
		<span class="text-bold">Réduit les distances parcourues par les doigts</span>, en particulier
		l’auriculaire droit.
	</div>
	<div class="card">
		<i class="icon-circle-4"><span class="path1"></span><span class="path2"></span></i> Ajoute de
		<span class="important">nombreux raccourcis</span>
		tels qu’un layer de navigation, des tap-holds et des touches <kbd-sortie>Alt + Tab</kbd-sortie>,
		<kbd-sortie>OneShotShift</kbd-sortie> et <kbd-sortie>CapsWord</kbd-sortie>.
	</div>
	<div class="card">
		<i class="icon-circle-5"><span class="path1"></span><span class="path2"></span></i>
		Fonctionnalités d’<span class="text-bold">autocorrection et de snippets</span>. Permet également
		d’écrire des
		<span class="text-bold">symboles complexes et des emojis</span>.
	</div>
	<div class="card">
		<i class="icon-circle-6"><span class="path1"></span><span class="path2"></span></i> Chaque
		fonctionnalité est optionnelle, désactivable et
		<span class="important">peut être intégrée au fil du temps</span>. Nul besoin de chercher à tout
		utiliser dès le départ.
	</div>
</div>
<mini-espace></mini-espace>
<hr />

<petit-espace />

<div class="main">
	<div class="encadre">
		Cependant, l’utilisation d’<ErgoptiPlus></ErgoptiPlus> nécessite des
		<span class="important">outils de programmation de clavier :</span>
		<ul>
			<li>
				Sur Windows, le programme <a class="link" href="https://www.autohotkey.com/">AutoHotkey</a>
				est utilisé afin de réaliser ces changements. Il donne une immense liberté et est l’implémentation
				actuelle d’<ErgoptiPlus></ErgoptiPlus>.
			</li>
			<li>
				Sur macOS,
				<a class="link" href="https://karabiner-elements.pqrs.org/">Karabiner Elements</a>
				permettrait de réaliser une partie des fonctionnalités d’<ErgoptiPlus></ErgoptiPlus>. Celles
				pouvant être implémentées sont les remappages de touches, les tap-holds et la création d’un
				layer de navigation. Cependant, ce logiciel ne gère pas les hotstrings (remplacements de
				texte), ce qui ne permet pas d’utiliser la moitié des possibilités d’<ErgoptiPlus
				></ErgoptiPlus> sur macOS : création de nouveaux roulements, touche <kbd>,</kbd> de
				correction de <SFB></SFB>s, touche
				<kbd>★</kbd> de répétition et d’expansion de texte, etc. Peut-être un programme complémentaire
				pourrait se charger de cette partie, mais il n’y a pas de solution aussi simple et puissante
				qu’AutoHotkey sur macOS.
			</li>
			<li>
				Il est aussi possible de programmer le firmware de son clavier (avec <a
					class="link"
					href="https://qmk.fm/">QMK</a
				>
				ou <a class="link" href="https://zmk.dev/">ZMK</a>) pour bénéficier de ce genre de
				fonctionnalités quelle que soit la plateforme (Windows, Mac, Linux, etc.). Cependant, cela
				nécessite beaucoup de travail et là encore toutes les possibilités d’AutoHotkey ne seront
				pas disponibles.
			</li>
		</ul>
	</div>
	<mini-espace></mini-espace>
	<p>Voici maintenant les nombreuses fonctionnalités d’<ErgoptiPlus /> :</p>
</div>
