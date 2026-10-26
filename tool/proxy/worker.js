// Прокси Basic Caster для подкастов, недоступных напрямую.
// Cloudflare → Workers & Pages → Create → Worker, вставить этот код,
// заменить KEY на свой длинный случайный ключ и нажать Deploy.
// В приложении: Настройки → Подписки → «Прокси для недоступных подкастов»:
// адрес Worker (https://….workers.dev/) и тот же ключ.
const KEY = 'замените-на-свой-длинный-ключ';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.searchParams.get('key') !== KEY) return new Response('forbidden', { status: 403 });

    const target = url.searchParams.get('url');
    if (!target || !/^https?:\/\//i.test(target)) return new Response('bad url', { status: 400 });

    // Перемотка аудио (range) и проверка «не изменилась ли лента» (etag).
    const headers = new Headers();
    for (const h of ['range', 'if-none-match', 'if-modified-since', 'accept']) {
      const v = request.headers.get(h);
      if (v) headers.set(h, v);
    }
    headers.set('user-agent', request.headers.get('user-agent') || 'BasicCaster');

    const r = await fetch(target, { method: request.method === 'HEAD' ? 'HEAD' : 'GET', headers, redirect: 'follow' });

    const out = new Headers();
    for (const h of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
      const v = r.headers.get(h);
      if (v) out.set(h, v);
    }
    return new Response(r.body, { status: r.status, headers: out });
  },
};
