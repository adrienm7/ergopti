<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '$lib/keyboard/controls/KeyboardControls.svelte';
</script>

<section>
	<div>
		<h1 data-aos="zoom-in" class="ergopti-title">
			Disposition clavier<br /><span style="line-height: 0.75!important;"
				><ErgoptiPlus></ErgoptiPlus></span
			>
		</h1>
		<KeyboardBasis id="presentation_plus" />
		<tiny-space></tiny-space>
		<KeyboardControls id="presentation_plus" />
	</div>

	<small-space></small-space>

	<hr />
	<p class="main text-center">
		<ErgoptiPlus /> est une variante améliorée de la disposition <Ergopti /> qui tire parti des meilleures
		fonctionnalités des claviers programmables et outils d’automatisation. Elle se rapproche de très
		près <span class="nowrap">de la <strong>disposition clavier idéale</strong> :</span>
	</p>
	<div class="cards">
		<div class="card">
			<i class="icon-circle-1"><span class="path1"></span><span class="path2"></span></i>
			Ajout de
			<span class="text-bold">nouveaux roulements</span> extrêmement confortables.
		</div>
		<div class="card">
			<i class="icon-circle-2"><span class="path1"></span><span class="path2"></span></i>
			<strong>Éradication de la quasi-totalité des <span class="nowrap"><SFB />s</span></strong> pour
			une frappe ultra-fluide et sans inconfort.
		</div>
		<div class="card">
			<i class="icon-circle-3"><span class="path1"></span><span class="path2"></span></i>
			<span class="text-bold">Réduction des distances parcourues par les doigts</span>, en
			particulier l’auriculaire droit.
		</div>
		<div class="card">
			<i class="icon-circle-4"><span class="path1"></span><span class="path2"></span></i> Ajout de
			<strong>nombreux raccourcis</strong>
			tels qu’un layer de navigation, des tap-holds et des touches
			<kbd-output>Alt + Tab</kbd-output>,
			<kbd-output>OneShotShift</kbd-output> et <kbd-output>CapsWord</kbd-output>.
		</div>
		<div class="card">
			<i class="icon-circle-5"><span class="path1"></span><span class="path2"></span></i>
			Fonctionnalités d’<span class="text-bold">autocorrection et de snippets</span>. Cela permet
			également d’écrire des
			<span class="text-bold">symboles complexes et des emojis</span>.
		</div>
		<div class="card">
			<i class="icon-circle-6"><span class="path1"></span><span class="path2"></span></i> Chaque
			fonctionnalité est optionnelle, désactivable et
			<strong>peut être intégrée au fil du temps</strong>. Nul besoin de chercher à tout apprendre
			ou utiliser dès le départ.
		</div>
	</div>
	<tiny-space></tiny-space>
	<hr />

	<small-space></small-space>

	<div class="main">
		<div class="encadre">
			Cependant, l’utilisation d’<ErgoptiPlus></ErgoptiPlus> nécessite des
			<strong>outils de programmation de clavier :</strong>
			<ul>
				<li>
					Sur Windows, le programme <a
						class="link"
						href="https://www.autohotkey.com/"
						target="_blank">AutoHotkey</a
					>
					est utilisé afin de réaliser ces changements. Il donne une immense liberté et est l’implémentation
					la plus complète d’<ErgoptiPlus></ErgoptiPlus>.
				</li>
				<li>
					Sur macOS,
					<a href="https://karabiner-elements.pqrs.org/" target="_blank" class="link"
						>Karabiner Elements</a
					>
					et <a href="https://www.alfredapp.com/" target="_blank" class="link">Alfred</a> permettent
					de se rapprocher de très près de toutes les fonctionnalités d’<ErgoptiPlus></ErgoptiPlus>.
				</li>
				<li>
					Sur Linux, les meilleurs outils sont actuellement <a
						class="link"
						href="https://github.com/jtroo/kanata/"
						target="_blank">Kanata</a
					>
					et
					<a href="https://espanso.org/" target="_blank" class="link">Espanso</a>. Ce sont des
					programmes open source et fonctionnant sur tous les OS, mais qui ne sont actuellement pas
					aussi bons que leurs alternatives sur macOS, et encore moins qu’AutoHotkey sur Windows.
				</li>
				<li>
					Il est aussi possible de programmer le firmware de son clavier (avec <a
						class="link"
						href="https://qmk.fm/"
						target="_blank">QMK</a
					>
					ou <a href="https://zmk.dev/" target="_blank" class="link">ZMK</a>) pour bénéficier de ce
					genre de fonctionnalités quelle que soit la plateforme (Windows, Mac, Linux, etc.).
					Cependant, cela nécessite beaucoup de travail et là encore toutes les possibilités
					d’AutoHotkey ne seront pas disponibles.
				</li>
			</ul>
		</div>
		<tiny-space></tiny-space>
		<p>Voici maintenant les nombreuses fonctionnalités d’<ErgoptiPlus /> :</p>
	</div>
</section>
