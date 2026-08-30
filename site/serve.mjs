// A static server for the built site, so `file://` quirks are not what you
// are debugging. `npm run build && npm run serve`, then open the URL it prints.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const out = join(dirname(fileURLToPath(import.meta.url)), 'dist');
const port = Number(process.env.PORT || 4173);

const TYPES = {
	'.html': 'text/html; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.svg': 'image/svg+xml',
	'.jpg': 'image/jpeg',
	'.png': 'image/png',
};

createServer(async (request, response) => {
	// Normalize before joining, or `..` walks out of the built site.
	let path = normalize(decodeURIComponent(new URL(request.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '');
	if (path.endsWith('/')) path += 'index.html';

	try {
		const body = await readFile(join(out, path));
		response.writeHead(200, { 'Content-Type': TYPES[extname(path)] || 'application/octet-stream' });
		response.end(body);
	} catch {
		response.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
		response.end(await readFile(join(out, '404.html')).catch(() => 'not found'));
	}
}).listen(port, () => console.log(`serving site/dist on http://localhost:${port}/`));
