<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2>Placement logique des symboles</h2>
	<p>
		Afin de <strong>faciliter la mémorisation</strong> ainsi que de
		<strong>réduire la charge cognitive</strong>, les touches de la disposition sont, le plus
		possible, <strong>placées logiquement</strong>. C’est notamment le cas grâce à une séparation
		des lettres par main : les voyelles sont toutes présentes à gauche et les consonnes à droite
		(sauf le <kbd>W</kbd>, le <kbd>B</kbd> et le <kbd>K</kbd>). En outre, le placement logique des
		caractères est particulièrement présent sur la couche
		<kbd>AltGr</kbd> :
	</p>
	<ul>
		<li>
			<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-output>\</kbd-output> car le
			<strong>\</strong> est au-dessus du A (Le <kbd-output>\</kbd-output>
			était auparavant sur le <kbd>È</kbd> et le <kbd-output>`</kbd-output> sur le <kbd>À</kbd>, car
			plus logique. Cependant, cela a finalement été déplacé pour placer plus près ce symbole qui
			est très utilisé en programmation, notamment en LaTeX.) ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-output>ç</kbd-output>
			car la cédille est sous le <strong>C</strong> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>U</kbd> ➜
			<kbd-output>µ</kbd-output>
			car cette touche morte permettant d’écrire les lettres grecques (α, β, γ, δ…), dont µ (MU) ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>E</kbd> ➜
			<kbd-output>ᵉ</kbd-output>
			car c’est la touche morte <strong>E</strong>xposant ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-output>/</kbd-output>
			car le <strong>/</strong> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-output>`</kbd-output>
			car le <strong>`</strong> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>Ê</kbd> ➜ <kbd-output>^</kbd-output>
			car le <strong>^</strong> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-output>#</kbd-output>
			car c’est la première lettre de <strong>H</strong>ashtag ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-output>=</kbd-output> car éga<strong>L</strong> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-output>&</kbd-output> car le nom de ce symbole est a<strong
				>M</strong
			>persand ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-output>+</kbd-output>
			car c’est la première lettre de <strong>P</strong>lus ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>R</kbd> ➜
			<kbd-output>ℝ</kbd-output> car c’est la touche morte pour écrire les ensembles mathématiques
			(ℕ, ℤ, ℚ, ℝ, ℂ), dont l'un des plus connus est <strong>R</strong> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜
			<kbd-output class="deadkey">◌̈</kbd-output> car c’est la touche morte
			<strong>T</strong>réma ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-output>|</kbd-output> car c’est la barre
			<strong>V</strong>erticale ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>X</kbd> ➜ <kbd-output>*</kbd-output>
			car <strong>x</strong> ressemble au fois.
		</li>
	</ul>

	<tiny-space></tiny-space>

	<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
	<ul>
		<li>
			<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-output>{'<'}</kbd-output> et <kbd>AltGr</kbd> +
			<kbd>I</kbd>
			➜ <kbd-output>{'>'}</kbd-output> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-output>≤</kbd-output> et
			<kbd>Shift</kbd>
			+ <kbd>AltGr</kbd> +
			<kbd>I</kbd>
			➜ <kbd-output>≥</kbd-output> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>E</kbd> ➜ <kbd-output>{'{'}</kbd-output> et <kbd>AltGr</kbd> +
			<kbd>U</kbd>
			➜ <kbd-output>{'}'}</kbd-output> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>S</kbd> ➜ <kbd-output>(</kbd-output> et <kbd>AltGr</kbd> +
			<kbd>N</kbd>
			➜ <kbd-output>)</kbd-output> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-output>[</kbd-output> et <kbd>AltGr</kbd> +
			<kbd>R</kbd>
			➜ <kbd-output>]</kbd-output> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-output>«</kbd-output> et <kbd>AltGr</kbd> +
			<kbd>F</kbd>
			➜ <kbd-output>»</kbd-output> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-output>“</kbd-output> et
			<kbd>Shift</kbd>
			+ <kbd>AltGr</kbd> +
			<kbd>F</kbd>
			➜ <kbd-output>”</kbd-output>.
		</li>
	</ul>
	<tiny-space></tiny-space>
	<p class="encadre">
		À noter que les touches sont aussi placées le plus possible par distance selon leur fréquence
		d’utilisation. Ainsi, les paires de touches très utilisées <kbd>()</kbd>,
		<kbd>{'{}'}</kbd>, <kbd>{'<>'}</kbd> et <kbd>[]</kbd> sont toutes sur la rangée du milieu.
	</p>
</section>
