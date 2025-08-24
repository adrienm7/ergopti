<script>
	import Nom from '$lib/components/Nom.svelte';
	import NomPlus from '$lib/components/NomPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<h2>Placement logique des symboles</h2>
<p>
	Afin de <span class="important">faciliter la mémorisation</span> ainsi que de
	<span class="important">réduire la charge cognitive</span>, les touches de la disposition sont, le
	plus possible, <span style="text-decoration: underline;">placées logiquement</span>. C’est
	notamment le cas grâce à une séparation des lettres par main : les voyelles sont toutes présentes
	à gauche et les consonnes à droite (sauf le <kbd>W</kbd>, le <kbd>B</kbd> et le <kbd>K</kbd>). En
	outre, le placement logique des caractères est particulièrement présent sur la couche
	<kbd>AltGr</kbd> :
</p>
<ul>
	<li>
		<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>\</kbd-sortie> car le
		<span class="hyper text-bold">\</span> est au-dessus du A (Le <kbd-sortie>\</kbd-sortie>
		était auparavant sur le
		<kbd>È</kbd> et le <kbd-sortie>`</kbd-sortie> sur le <kbd>À</kbd>, car plus logique. Cependant,
		cela a finalement été déplacé pour placer plus près ce symbole qui est très utilisé en
		programmation, notamment en LaTeX.) ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
		car la cédille est sous le <span class="hyper text-bold">C</span> ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>U</kbd> ➜
		<kbd-sortie>µ</kbd-sortie>
		car cette touche morte permettant d’écrire les lettres grecques (α, β, γ, δ…), dont µ (MU) ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>E</kbd> ➜
		<kbd-sortie>ᵉ</kbd-sortie>
		car c’est la touche morte <span class="hyper text-bold">E</span>xposant ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
		car le <span class="hyper text-bold">/</span> est au-dessus du E ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>`</kbd-sortie>
		car le <span class="hyper text-bold">`</span> est au-dessus du E ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>Ê</kbd> ➜ <kbd-sortie>^</kbd-sortie>
		car le <span class="hyper text-bold">^</span> est au-dessus du E ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
		car c’est la première lettre de <span class="hyper text-bold">H</span>ashtag ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> car éga<span
			class="hyper text-bold">L</span
		> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> car le nom de ce symbole est a<span
			class="hyper text-bold">M</span
		>persand ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
		car c’est la première lettre de <span class="hyper text-bold">P</span>lus ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>R</kbd> ➜
		<kbd-sortie>ℝ</kbd-sortie>
		car c’est la touche morte pour écrire les ensembles mathématiques (ℕ, ℤ, ℚ, ℝ, ℂ), dont l'un des
		plus connus est <span class="hyper text-bold">R</span> ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜
		<kbd-sortie style="font-weight: normal;">◌̈</kbd-sortie>
		car c’est la touche morte <span class="hyper text-bold">T</span>réma ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> car c’est la barre
		<span class="hyper text-bold">V</span>erticale ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>X</kbd> ➜ <kbd-sortie>*</kbd-sortie>
		car <span class="hyper text-bold">x</span> ressemble au fois.
	</li>
</ul>

<mini-espace />

<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
<ul>
	<li>
		<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>{'<'}</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>I</kbd>
		➜ <kbd-sortie>{'>'}</kbd-sortie> ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>≤</kbd-sortie> et
		<kbd>Shift</kbd>
		+ <kbd>AltGr</kbd> +
		<kbd>I</kbd>
		➜ <kbd-sortie>≥</kbd-sortie> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>E</kbd> ➜ <kbd-sortie>{'{'}</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>U</kbd>
		➜ <kbd-sortie>{'}'}</kbd-sortie> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>S</kbd> ➜ <kbd-sortie>(</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>N</kbd>
		➜ <kbd-sortie>)</kbd-sortie> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>[</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>R</kbd>
		➜ <kbd-sortie>]</kbd-sortie> ;
	</li>
	<li>
		<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>«</kbd-sortie> et <kbd>AltGr</kbd> +
		<kbd>F</kbd>
		➜ <kbd-sortie>»</kbd-sortie> ;
	</li>
	<li>
		<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>“</kbd-sortie> et
		<kbd>Shift</kbd>
		+ <kbd>AltGr</kbd> +
		<kbd>F</kbd>
		➜ <kbd-sortie>”</kbd-sortie>.
	</li>
</ul>
<mini-espace />
<p class="encadre">
	À noter que les touches sont aussi placées le plus possible par distance selon leur fréquence
	d’utilisation. Ainsi, les paires de touches très utilisées telles que <kbd>()</kbd>,
	<kbd>{'{}'}</kbd>, <kbd>{'<>'}</kbd> et <kbd>[]</kbd> sont toutes sur la rangée du milieu.
</p>
