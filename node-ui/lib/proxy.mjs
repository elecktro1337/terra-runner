import crypto from 'node:crypto';

export const DIRECT_ROUTE_ID = 'direct';
export const PROXY_PROTOCOLS = ['http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h'];
const LOOPBACK = ['localhost', '127.0.0.1', '::1'];

export function normalizeProxy(settings) {
  const proxy = settings.proxy ||= {};
  proxy.activeRouteId = String(proxy.activeRouteId || DIRECT_ROUTE_ID);
  proxy.routes = Array.isArray(proxy.routes) ? proxy.routes : [];
  proxy.routes = proxy.routes.map(route => ({ id: String(route?.id || crypto.randomUUID()), name: String(route?.name || 'Proxy'), protocol: PROXY_PROTOCOLS.includes(route?.protocol) ? route.protocol : 'http', host: String(route?.host || ''), port: Number(route?.port || 0), username: String(route?.username || ''), passwordProtected: String(route?.passwordProtected || ''), caFile: String(route?.caFile || ''), noProxy: Array.isArray(route?.noProxy) ? route.noProxy.map(String).filter(Boolean) : [] }));
  if (proxy.activeRouteId !== DIRECT_ROUTE_ID && !proxy.routes.some(route => route.id === proxy.activeRouteId)) proxy.activeRouteId = DIRECT_ROUTE_ID;
  return proxy;
}
export function activeProxyRoute(settings) { const proxy = normalizeProxy(settings); return proxy.activeRouteId === DIRECT_ROUTE_ID ? null : proxy.routes.find(route => route.id === proxy.activeRouteId) || null; }
export function validateProxyRoute(route) {
  if (!String(route.name || '').trim()) return 'Enter a route name.';
  if (!PROXY_PROTOCOLS.includes(route.protocol)) return 'Unsupported proxy protocol.';
  if (!String(route.host || '').trim() || /[\s/@]/.test(route.host)) return 'Enter a valid proxy host or IP address.';
  if (!Number.isInteger(Number(route.port)) || Number(route.port) < 1 || Number(route.port) > 65535) return 'Port must be from 1 to 65535.';
  return '';
}
export function noProxyValue(route) { return [...new Set([...LOOPBACK, ...(route?.noProxy || [])])].join(','); }
export function redactedRoute(route) { return route ? `${route.protocol}://${route.host}:${route.port}` : 'Direct'; }
