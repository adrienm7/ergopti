import { readFileSync, writeFileSync, existsSync } from 'fs';

const AHK_FILE = 'static/drivers/autohotkey/ErgoptiPlus.ahk';

if (!existsSync(AHK_FILE)) process.exit(0);

const content = readFileSync(AHK_FILE, 'utf8');
const firstLine = content.split('\n')[0];

if (!firstLine.match(/^; (Created|Last modified) on /)) process.exit(0);

const now = new Date();
const pad = (n) => String(n).padStart(2, '0');
const offsetMin = -now.getTimezoneOffset();
const sign = offsetMin >= 0 ? '+' : '-';
const offsetH = Math.floor(Math.abs(offsetMin) / 60);
const datePart = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const timePart = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
const newLine = `; Last modified on ${datePart} at ${timePart} (UTC${sign}${offsetH})`;

const updated = newLine + '\n' + content.split('\n').slice(1).join('\n');
writeFileSync(AHK_FILE, updated, 'utf8');
console.log(`✅ Updated AHK date: ${newLine}`);
