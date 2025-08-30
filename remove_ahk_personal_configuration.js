import fs from 'fs';
import path from 'path';

const dirPath = 'static/pilotes/plus';
const files = fs.readdirSync(dirPath).filter((f) => f.endsWith('.ahk'));

files.forEach((file) => {
	const filePath = path.join(dirPath, file);
	let content = fs.readFileSync(filePath, 'utf8');

	// 1. Match the "2/ PERSONAL SHORTCUT" block delimiters
	const start2Match = content.match(
		/(?:^; ={5,}\s*\n){2,}; ={3,} 2\/ PERSONAL SHORTCUTS ={3,}\s*\n(?:^; ={5,}\s*\n){2,}/m
	);
	if (!start2Match) return;
	const start2Index = start2Match.index;
	const start2Block = start2Match[0];
	const after2Slice = content.slice(start2Index + start2Block.length);

	// 2. Capture everything up to and including #InputLevel and any empty lines after it
	const after2Match = after2Slice.match(/^([\s\S]*?\n#InputLevel[^\n]*\n(?:\s*\n)*)/m);
	const extra2 = after2Match ? after2Match[0] : '';

	// 3. Match the "3/ LAYOUT MODIFICATION" block delimiters
	const start3Match = content.match(
		/(?:^; ={5,}\s*\n){2,}; ={3,} 3\/ LAYOUT MODIFICATION ={3,}\s*\n(?:^; ={5,}\s*\n){2,}/m
	);
	if (!start3Match) return;
	const start3Index = start3Match.index;
	const endBlock = start3Match[0];

	// 4. Everything before 2/ and after 3/ remains unchanged
	const before = content.slice(0, start2Index);
	const after = content.slice(start3Index + endBlock.length);

	// 5. Combine everything: before + 2/ block + preserved comments/#InputLevel + 3/ block + after
	const newContent = before + start2Block + extra2 + endBlock + after;

	fs.writeFileSync(filePath, newContent, 'utf8');
	console.log(`✅ ${file} cleaned`);
});
