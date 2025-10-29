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
		'ei',
		'eu',
		'ée',
		'ie',
		'ieu',
		'io',
		'oi',
		'ou',
		'oui',
		'ow',
		'ue',
		'wo',
		'ye',
		'yo',
		'you'
	];
	let roulements_consonnes = [
		'ch',
		'cr',
		'd’',
		'ght',
		'gr',
		'ld',
		'nc',
		'nd',
		'ng',
		'ns',
		'nt',
		'ntr',
		'pl',
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
		frapper une touche, il y a une forte probabilité que le frappe suivante se produise avec
		l’autre main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il convient
		de s’assurer que le plus possible de frappes intra-mains se réalisent à l’aide de roulements,
		aussi appelés <em>rolls</em> en anglais.
	</p>
	<p>
		Un roulement consiste à frapper deux touches avec la même main, sans que cela n’entraîne de <SFB></SFB> ni de <em>ciseau</em>. Généralement, la frappe est tellement rapide que la première touche n’est pas encore relâchée que le seconde est déjà pressée. Cela donne une impression très agréable de "rouler" sur les touches.
	</p>
	<p>
        Cependant, tous les roulement ne se valent pas.
        Les meilleurs sont ceux sur deux doigts consécutifs et
		jamais à plus d’une rangée d’écart. Cela évite tout problème de coordination, car s’il faut "sauter" un doigt, par exemple pour utiliser l’index puis l’annulaire, le mouvement peut être plus lent et le risque de se tromper un peu plus élevé.
		Par exemple, un roulement est le <kbd>PO</kbd> de l’AZERTY ou le <kbd>ST</kbd> du
		BÉPO (idéalement, car mouvement horizontal). Sinon, c’est éventuellement le <kbd>SE</kbd> de
		l’AZERTY ou le <kbd>DR</kbd> du BÉPO. Toutefois, ce n’est pas le <kbd>CE</kbd> de l’AZERTY ni le
		<kbd>GL</kbd> du BÉPO.
	</p>
	<p class = "encadre">
		La disposition <Ergopti /> a été construite avec pour contrainte principale de permettre de réaliser
		les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des roulements, de préférence
		sur deux doigts consécutifs dans un mouvement horizontal.
	</p>

    <tiny-space></tiny-space>
    
    <p>Vous pouvez visualiser les roulements d’<Ergopti></Ergopti> ci-dessous :</p>
	<KeyboardBasis id="roulements" />
	<div style="height: 20px" />
	<keyboard-control-rolls
		style="width: 100%; margin: 0 auto; display: inline-block; text-align: center"
	>
		<select bind:value={texte} on:change={() => keyboard.typeText(texte, 250, false)}>
			<option selected disabled hidden>Sélectionner le roulement</option>
			<option disabled>——— Roulements voyelles ———</option>
			{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
			<option disabled>——— Roulements consonnes ———</option>
			{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
		</select>
	</keyboard-control-rolls>

	<h3>Bons bigrammes voyelle-voyelle</h3>
	<ul>
		<li><kbd>AI</kbd> ;</li>
		<li><kbd>AU</kbd> ;</li>
		<li><kbd>EU</kbd> et <kbd>UE</kbd> ;</li>
		<li><kbd>ÉE</kbd> ;</li>
		<li><kbd>IE</kbd> et <kbd>EI</kbd> ;</li>
		<li><kbd>IO</kbd> et <kbd>OI</kbd> ;</li>
		<li><kbd>OU</kbd> ;</li>
		<li><kbd>YE</kbd> ;</li>
		<li><kbd>YO</kbd>.</li>
	</ul>

	<p>Avec même quelques trigrammes très confortables :</p>
	<ul>
		<li><kbd>AIE</kbd> : notamment pour écrire <strong>AIE</strong>NT 
            (avec en plus <kbd>NT</kbd> qui est lui aussi un roulement, que demander de plus ?) ;
        </li>
		<li><kbd>IEU</kbd> ;</li>
		<li><kbd>OUI</kbd> ;</li>
		<li><kbd>YOU</kbd>.</li>
	</ul>

	<h3>Bons bigrammes consonne-consonne</h3>
	<ul>
        <li>
			<kbd>CH</kbd> : <strong>ce bigramme est extraordinaire</strong>, une fois habitué il est difficile de s’en passer ;
		</li>
		<li><kbd>CR</kbd> ;</li>
		<li><kbd>D’</kbd> ;</li>
        <li><kbd>GR</kbd> ;</li>
		<li>
			<kbd>LD</kbd> : fréquent en anglais (O<strong>LD</strong>, COU<strong>LD</strong>, SHOU<strong
				>LD</strong
			>, WOU<strong>LD</strong>, etc.) ;
		</li>
		<li><kbd>NC</kbd> ;</li>
		<li>
			<kbd>ND</kbd> : extrêmement fréquent, notamment pour tous les A<strong>ND</strong> en anglais ;
		</li>
		<li><kbd>NG</kbd> : pour tous les -I<strong>NG</strong> en anglais ;</li>
		<li><kbd>NS</kbd> et <kbd>SN</kbd> ;</li>
		<li><kbd>NT</kbd> : c’est le <strong>bigramme consonne-consonne le plus fréquent en français</strong> ;</li>
		<li><kbd>PL</kbd> ;</li>
		<li><kbd>RS</kbd> ;</li>
		<li><kbd>SH</kbd> ;</li>
		<li><kbd>TH</kbd> : c’est le <strong>bigramme le plus fréquent, et de loin, en anglais</strong> et il est ultra-confortable ;</li>
		<li><kbd>TR</kbd> et <kbd>RT</kbd> .</li>
	</ul>
    <p>Avec même quelques trigrammes très confortables :</p>
	<ul>
        <li><kbd>NTR</kbd> ;</li>
        <li><kbd>GHT</kbd> : très fréquent en anglais pour tous les -OU<strong>GHT</strong> et -I<strong>GHT</strong> ;</li>
    </ul>

	<h3>Autres bons bigrammes</h3>
	<ul>
		<li>
			<kbd>OW</kbd> : très utilisé en anglais (ALL<strong>OW</strong>, D<strong>OW</strong>N, FOLL<strong
				>OW</strong
			>, H<strong>OW</strong>, KN<strong>OW</strong>, N<strong>OW</strong>,
			<strong>OW</strong>N, SH<strong>OW</strong>, etc.) ;
		</li>
		<li>
			<kbd>WO</kbd> : très utilisé en anglais (T<strong>WO</strong>,
			<strong>WO</strong>MAN, <strong>WO</strong>RD,
			<strong>WO</strong>RK, <strong>WO</strong>RLD,
			<strong>WO</strong>RTH, <strong>WO</strong>ULD, etc.) ;
		</li>
		<li><kbd>+=</kbd> : utilisé en programmation pour incrémenter.</li>
	</ul>
</section>
