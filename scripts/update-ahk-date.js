import { readFileSync, writeFileSync, existsSync } from 'fs';

const AHK_FILE = 'static/drivers/autohotkey/ErgoptiPlus.ahk';

if (!existsSync(AHK_FILE)) process.exit(0);

const content = readFileSync(AHK_FILE, 'utf8');
const lines = content.split('\n');
const firstLine = lines[0];
const hasDateLine = firstLine.match(/^; (Created|Last modified) on /);

const now = new Date();
const pad = (n) => String(n).padStart(2, '0');
const offsetMin = -now.getTimezoneOffset();
const sign = offsetMin >= 0 ? '+' : '-';
const offsetH = Math.floor(Math.abs(offsetMin) / 60);
const datePart = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const timePart = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
const newLine = `; Last modified on ${datePart} at ${timePart} (UTC${sign}${offsetH})`;

// Replace the existing date line, or prepend a new one
const rest = hasDateLine ? lines.slice(1).join('\n') : content;
const updated = newLine + '\n' + rest;
writeFileSync(AHK_FILE, updated, 'utf8');
console.log(`✅ Updated AHK date: ${newLine}`);
