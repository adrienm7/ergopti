<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	const keyboard = new Keyboard('roulements');

	let texte;
	let roulements_voyelles = [
		'ai',
		'aie',
		'au',
		'eu',
		'ée',
		'ie',
		'ieu',
		'io',
		'oi',
		'ou',
		'ow',
		'wo',
		'you'
	];
	let roulements_consonnes = [
		'ch',
		'd’',
		'ld',
		'gr',
		'nc',
		'nd',
		'ng',
		'ns',
		'nt',
		'ntr',
		'pl',
		'cr',
		'rs',
		'sh',
		'th',
		'tr'
	];
</script>

<section>
	<h2>Optimisation des roulements</h2>
	<p>
		L’optimisation de l’alternance des mains engendre que lors de l’utilisation d’une main pour
		frapper une touche, il y a de fortes probabilités que le frappe suivante se produise avec
		l’autre main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il convient
		de s’assurer que le plus possible de frappes intra-mains se fassent à l’aide de roulements,
		aussi appelés <em>rolls</em> en anglais.
	</p>
	<p>
		Ma définition personnelle d’un "roulement" est un déplacement sur deux doigts consécutifs et
		jamais à plus d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un roulement
		a probablement une définition plus large que la mienne, mais alors dans ce cas le côté "qui
		roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais pas de l’index
		à l’annulaire par exemple.
	</p>
	<p>
		En conclusion, un roulement est pour moi le <kbd>PO</kbd> de l’AZERTY ou le <kbd>ST</kbd> du
		BÉPO (idéalement, car mouvement horizontal). Sinon, c’est éventuellement le <kbd>PL</kbd> de
		l’AZERTY ou le <kbd>LS</kbd> du BÉPO. Toutefois, ce n’est pas le <kbd>ST</kbd> de l’AZERTY ni le
		<kbd>GL</kbd> du BÉPO.
	</p>
	<p>
		La disposition <Ergopti /> a été construite avec pour contrainte principale de permettre de réaliser
		les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des roulements, de préférence
		sur des doigts consécutifs dans un mouvement horizontal.
	</p>

	<h3>Bons bigrammes voyelle-voyelle</h3>
	<ul>
		<li><kbd>AI</kbd> ;</li>
		<li><kbd>IE</kbd> et <kbd>EI</kbd> ;</li>
		<li><kbd>EU</kbd> ;</li>
		<li><kbd>IO</kbd> et <kbd>OI</kbd> ;</li>
		<li><kbd>OU</kbd> ;</li>
		<li><kbd>ÉE</kbd>.</li>
	</ul>

	<p>Avec même quelques trigrammes très confortables :</p>
	<ul>
		<li><kbd>AIE</kbd> notamment pour écrire <strong>AIE</strong>NT ;</li>
		(avec en plus<kbd>NT</kbd> qui est lui aussi un roulement, que demander de plus ?)
		<li><kbd>IEU</kbd> ;</li>
		<li><kbd>YOU</kbd>.</li>
	</ul>

	<h3>Bons bigrammes consonne-consonne</h3>
	<ul>
		<li><kbd>NS</kbd> et <kbd>SN</kbd> ;</li>
		<li><kbd>NT</kbd> ;</li>
		<li><kbd>TR</kbd> et <kbd>RT</kbd> ;</li>
		<li><kbd>RS</kbd> ;</li>
		<li>
			<kbd>CH</kbd> ce bigramme est extraordinaire, une fois habitué il est difficile de s’en passer ;
		</li>
		<li><kbd>PL</kbd> ;</li>
		<li>
			<kbd>LD</kbd> surtout fréquent en anglais (O<strong>LD</strong>, COU<strong>LD</strong>, SHOU<strong
				>LD</strong
			>, WOU<strong>LD</strong>, etc.) ;
		</li>
		<li><kbd>D’</kbd> ;</li>
		<li><kbd>NC</kbd> ;</li>
		<li>
			<kbd>ND</kbd> notamment pour tous les A<strong>ND</strong> en anglais ;
		</li>
		<li><kbd>NG</kbd> pour tous les -I<strong>NG</strong> en anglais ;</li>
		<li><kbd>TH</kbd> bigramme le plus fréquent (et de loin) en anglais ;</li>
		<li><kbd>CR</kbd> ;</li>
		<li><kbd>GR</kbd>.</li>
	</ul>
	<h3>Autres bons bigrammes</h3>
	<ul>
		<li>
			<kbd>OW</kbd> très utilisé en anglais (ALL<strong>OW</strong>, D<strong>OW</strong>N, FOLL<strong
				>OW</strong
			>, H<strong>OW</strong>, KN<strong>OW</strong>, N<strong>OW</strong>,
			<strong>OW</strong>N, SH<strong>OW</strong>, etc.) ;
		</li>
		<li>
			<kbd>WO</kbd> très utilisé en anglais (T<strong>WO</strong>,
			<strong>WO</strong>MAN, <strong>WO</strong>RD,
			<strong>WO</strong>RK, <strong>WO</strong>RLD,
			<strong>WO</strong>RTH, <strong>WO</strong>ULD, etc.) ;
		</li>
		<li><kbd>+=</kbd> utilisé en programmation pour incrémenter.</li>
	</ul>

	<h3>Visualisation des roulements</h3>
	<p>Vous pouvez visualiser les roulements présentés précédemment ci-dessous :</p>
	<KeyboardBasis id="roulements" />
	<div style="height: 20px" />
	<keyboard-control-rolls
		style="width: 100%; margin: 0 auto; display: inline-block; text-align: center"
	>
		<select bind:value={texte} on:change={() => keyboard.typeText(texte, 250, false)}>
			<option selected disabled hidden>Sélectionner le roulement</option>
			<option disabled>• Roulements voyelles •</option>
			{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
			<option disabled>• Roulements consonnes •</option>
			{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
		</select>
	</keyboard-control-rolls>
</section>
