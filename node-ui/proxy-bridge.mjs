import { Server } from 'proxy-chain';

const input = await new Promise((resolve, reject) => { let text = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', chunk => text += chunk); process.stdin.once('end', () => resolve(text)); process.stdin.once('error', reject); });
const route = JSON.parse(input);
const upstream = new URL(`${route.protocol}://${route.host}:${route.port}`);
if (route.username) upstream.username = route.username;
if (route.password) upstream.password = route.password;
const server = new Server({ host: '127.0.0.1', port: 0, prepareRequestFunction: () => ({ requestAuthentication: false, upstreamProxyUrl: upstream.toString() }) });
await server.listen();
process.stdout.write(`${JSON.stringify({ port: server.port })}\n`);
const stop = async () => { try { await server.close(true); } finally { process.exit(0); } };
process.once('SIGTERM', stop); process.once('SIGINT', stop);
