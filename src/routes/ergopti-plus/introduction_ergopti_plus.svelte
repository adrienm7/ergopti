<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
</script>

<div>
	<h1 data-aos="zoom-in" class="ergopti-title">
		Disposition clavier<br /><span style="line-height: 0.75!important;"><NomPlus></NomPlus></span>
	</h1>
	<BlocClavier nom="presentation_plus" />
	<mini-espace />
	<BlocControlesClavier nom="presentation_plus" />
</div>

<petit-espace />

<hr />
<p class="main text-center">
	<NomPlus /> est une variante améliorée de la disposition <Nom /> qui tire parti des meilleures fonctionnalités
	des claviers programmables et outils d’automatisation. Elle se rapproche de très près de la
	<span class="important">disposition clavier idéale</span>. En effet, elle :
</p>
<div class="cards">
	<div class="card">
		<i class="fa-duotone fa-circle-1"></i>
		Ajoute de
		<span class="text-bold">nouveaux roulements</span> extrêmement confortables.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-2"></i>
		<span class="important"
			>Éradique la quasi-totalité des <span class="nowrap"><SFB />s</span></span
		> pour une frappe ultra-fluide et sans inconfort.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-3"></i>
		<span class="text-bold">Réduit les distances parcourues par les doigts</span>, en particulier
		l’auriculaire droit.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-4"></i> Ajoute de
		<span class="important">nombreux raccourcis</span>
		tels qu’un layer de navigation, des tap-holds et des touches <kbd-sortie>Alt + Tab</kbd-sortie>,
		<kbd-sortie>OneShotShift</kbd-sortie> et <kbd-sortie>CapsWord</kbd-sortie>.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-5"></i>
		Fonctionnalités d’<span class="text-bold">autocorrection et de snippets</span>. Permet également
		d’écrire des
		<span class="text-bold">symboles complexes et des emojis</span>.
	</div>
	<div class="card">
		<i class="fa-duotone fa-circle-6"></i> Chaque fonctionnalité est optionnelle, désactivable et
		<span class="important">peut être intégrée au fil du temps</span>. Nul besoin de chercher à tout
		utiliser dès le départ.
	</div>
</div>
<mini-espace></mini-espace>
<hr />

<petit-espace />

<div class="main">
	<div class="encadre">
		Cependant, l’utilisation d’<NomPlus></NomPlus> nécessite des
		<span class="important">outils de programmation de clavier :</span>
		<ul>
			<li>
				Sur Windows, le programme <a href="https://www.autohotkey.com/">AutoHotkey</a>
				est utilisé afin de réaliser ces changements. Il donne une immense liberté et est l’implémentation
				actuelle d’<NomPlus></NomPlus>.
			</li>
			<li>
				Sur macOS,
				<a href="https://karabiner-elements.pqrs.org/">Karabiner Elements</a> permet d’également
				réaliser une partie de ces fonctionnalités, à savoir les remappages de touches, tap-holds et
				layer de navigation. Cependant, il ne gère pas les hotstrings (remplacements de texte), ce
				qui ne permet pas d’utiliser la moitié des possibilités d’<NomPlus></NomPlus> sur macOS.
			</li>
			<li>
				Enfin, il est aussi possible de programmer le firmware de son clavier (avec <a
					href="https://qmk.fm/">QMK</a
				>
				ou <a href="https://zmk.dev/">ZMK</a>) pour bénéficier de ce genre de fonctionnalités
				quelque soit la plateforme. Cependant, cela nécessite beaucoup plus de travail et là encore
				toutes les possibilités d’AutoHotkey ne seront pas disponibles.
			</li>
		</ul>
	</div>
	<mini-espace></mini-espace>
	<p class="important">Voici maintenant toutes les fonctionnalités d’<NomPlus /> :</p>
</div>
