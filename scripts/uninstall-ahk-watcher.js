import { execFileSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const PM2 = path.join(PROJECT_DIR, 'node_modules', '.bin', 'pm2');
const APP_NAME = 'ergopti-ahk-watcher';

try {
	execFileSync(PM2, ['delete', APP_NAME], { stdio: 'inherit' });
	execFileSync(PM2, ['save'], { stdio: 'inherit' });
	console.log(`✅ Watcher "${APP_NAME}" stopped and removed.`);
} catch {
	console.log(`ℹ️  No watcher "${APP_NAME}" was running.`);
}
