export function instancePage(items, page = 0, pageSize = 8) {
  const source = Array.isArray(items) ? items : [];
  const size = Math.max(1, Math.floor(Number(pageSize) || 8));
  const pageCount = Math.max(1, Math.ceil(source.length / size));
  const index = Math.min(Math.max(0, Math.floor(Number(page) || 0)), pageCount - 1);
  const start = index * size;
  return {
    items: source.slice(start, start + size),
    page: index,
    pageCount,
    first: source.length ? start + 1 : 0,
    last: Math.min(source.length, start + size),
    total: source.length
  };
}
