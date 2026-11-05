import path from 'node:path';
import { pathToFileURL } from 'node:url';
const repository = process.argv[2];
if (!repository) throw new Error('Pass the repository root');
const { default: dictionary } = await import(
	pathToFileURL(path.resolve(repository, 'src/routes/ergopti-plus/locales/en.js')).href
);
const keys = [
	'Options de menu propres à certains systèmes',
	'Option',
	'Touches tap-hold par système',
	'Inventaire des actions configurables',
	'Action',
	'Trois systèmes, un projet.',
	'Les entrées ci-dessous proviennent du manifeste partagé. Une entrée absente peut avoir un équivalent sous un autre nom ; sa présence ne garantit pas son fonctionnement en conditions réelles.',
	'Inventaire des réglages et fonctionnalités',
	'Fonctionnalité ou réglage',
	'✓ déclaré pour ce système',
	'— entrée non déclarée pour ce système',
	'Comportements examinés dans le code',
	'Ce catalogue complémentaire couvre les comportements examinés. Il ne constitue pas un inventaire exhaustif ni une garantie de fonctionnement dans chaque application.'
];
const observed = Object.fromEntries(keys.map((key) => [key, dictionary[key] ?? null]));
if (Object.values(observed).some((value) => typeof value !== 'string' || !value.trim()))
	throw new Error('Missing exported inventory mapping');
console.log(JSON.stringify({ observed, control: dictionary['Pour qui ?'] ?? null }));
