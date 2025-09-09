<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<h2>Placement logique des symboles</h2>
	<p>
		Afin de <span class="important">faciliter la mémorisation</span> ainsi que de
		<span class="important">réduire la charge cognitive</span>, les touches de la disposition sont,
		le plus possible, <span style="text-decoration: underline;">placées logiquement</span>. C’est
		notamment le cas grâce à une séparation des lettres par main : les voyelles sont toutes
		présentes à gauche et les consonnes à droite (sauf le <kbd>W</kbd>, le <kbd>B</kbd> et le
		<kbd>K</kbd>). En outre, le placement logique des caractères est particulièrement présent sur la
		couche
		<kbd>AltGr</kbd> :
	</p>
	<ul>
		<li>
			<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-output>\</kbd-output> car le
			<span class="hyper text-bold">\</span> est au-dessus du A (Le <kbd-output>\</kbd-output>
			était auparavant sur le
			<kbd>È</kbd> et le <kbd-output>`</kbd-output> sur le <kbd>À</kbd>, car plus logique.
			Cependant, cela a finalement été déplacé pour placer plus près ce symbole qui est très utilisé
			en programmation, notamment en LaTeX.) ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-output>ç</kbd-output>
			car la cédille est sous le <span class="hyper text-bold">C</span> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>U</kbd> ➜
			<kbd-output>µ</kbd-output>
			car cette touche morte permettant d’écrire les lettres grecques (α, β, γ, δ…), dont µ (MU) ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>E</kbd> ➜
			<kbd-output>ᵉ</kbd-output>
			car c’est la touche morte <span class="hyper text-bold">E</span>xposant ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-output>/</kbd-output>
			car le <span class="hyper text-bold">/</span> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-output>`</kbd-output>
			car le <span class="hyper text-bold">`</span> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>Ê</kbd> ➜ <kbd-output>^</kbd-output>
			car le <span class="hyper text-bold">^</span> est au-dessus du E ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-output>#</kbd-output>
			car c’est la première lettre de <span class="hyper text-bold">H</span>ashtag ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-output>=</kbd-output> car éga<span
				class="hyper text-bold">L</span
			> ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-output>&</kbd-output> car le nom de ce symbole est a<span
				class="hyper text-bold">M</span
			>persand ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-output>+</kbd-output>
			car c’est la première lettre de <span class="hyper text-bold">P</span>lus ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>R</kbd> ➜
			<kbd-output>ℝ</kbd-output>
			car c’est la touche morte pour écrire les ensembles mathématiques (ℕ, ℤ, ℚ, ℝ, ℂ), dont l'un des
			plus connus est <span class="hyper text-bold">R</span> ;
		</li>
		<li>
			<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜
			<kbd-output style="font-weight: normal;">◌̈</kbd-output>
			car c’est la touche morte <span class="hyper text-bold">T</span>réma ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-output>|</kbd-output> car c’est la barre
			<span class="hyper text-bold">V</span>erticale ;
		</li>
		<li>
			<kbd>AltGr</kbd> + <kbd>X</kbd> ➜ <kbd-output>*</kbd-output>
			car <span class="hyper text-bold">x</span> ressemble au fois.
		</li>
	</ul>

	<tiny-space></tiny-space>

	<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
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
		d’utilisation. Ainsi, les paires de touches très utilisées telles que <kbd>()</kbd>,
		<kbd>{'{}'}</kbd>, <kbd>{'<>'}</kbd> et <kbd>[]</kbd> sont toutes sur la rangée du milieu.
	</p>
</section>
