// Login + password accounts for staff without Google. Only editors may call it, and only
// for <login>@pokoje.local accounts, so nobody can touch other users of this shared project.
// Takes { action: 'create' | 'password' | 'delete', login, password?, name?, role? }.
const DOMAIN = '@pokoje.local';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = (path: string, method = 'GET', body?: unknown) =>
  fetch(URL_ + path, {
    method,
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return reply({ error: 'Tylko POST.' }, 405);

  // Caller's role, checked with their own token (JWT already verified by the gateway).
  const r = await fetch(`${URL_}/rest/v1/rpc/pokoje_role`, {
    method: 'POST',
    headers: { apikey: Deno.env.get('SUPABASE_ANON_KEY')!, Authorization: req.headers.get('Authorization') ?? '', 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!r.ok || (await r.json()) !== 'edit') return reply({ error: 'Tylko osoba z edycją może zarządzać kontami.' }, 403);

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return reply({ error: 'Zły format zapytania.' }, 400); }
  const login = String(b.login ?? '').trim().toLowerCase().replace(DOMAIN, '');
  if (!/^[a-z0-9._-]{2,30}$/.test(login)) return reply({ error: 'Login: 2 do 30 znaków, małe litery bez polskich znaków, cyfry, kropka lub myślnik.' }, 400);
  const email = login + DOMAIN;
  const password = String(b.password ?? '');
  const badPassword = password.length < 8 || password.length > 72;

  if (b.action === 'create') {
    if (badPassword) return reply({ error: 'Hasło musi mieć od 8 do 72 znaków.' }, 400);
    if (b.role !== 'edit' && b.role !== 'view') return reply({ error: 'Zła rola.' }, 400);
    const u = await admin('/auth/v1/admin/users', 'POST', { email, password, email_confirm: true });
    if (!u.ok) {
      const e = await u.json().catch(() => ({}));
      return reply({ error: u.status === 422 ? 'Taki login już istnieje.' : 'Nie założono konta: ' + (e.msg || e.message || u.status) }, 400);
    }
    const s = await admin('/rest/v1/pokoje_staff', 'POST', { email, name: String(b.name ?? '').trim(), role: b.role });
    if (!s.ok) return reply({ error: 'Konto założone, ale nie dodano go do zespołu.' }, 500);
    return reply({ ok: true });
  }

  // Same rule as the RLS policies: nobody changes themselves or a locked (owner) row.
  const caller = JSON.parse(atob((req.headers.get('Authorization') ?? '').split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).email;
  const row = await (await admin(`/rest/v1/pokoje_staff?select=locked&email=eq.${encodeURIComponent(email)}`)).json();
  if (email === String(caller).toLowerCase() || row[0]?.locked) return reply({ error: 'Tego konta nie można zmienić.' }, 403);

  const idRes = await admin('/rest/v1/rpc/pokoje_user_id', 'POST', { p_email: email });
  const id = idRes.ok ? await idRes.json() : null;

  if (b.action === 'password') {
    if (badPassword) return reply({ error: 'Hasło musi mieć od 8 do 72 znaków.' }, 400);
    if (!id) return reply({ error: 'Nie ma takiego konta.' }, 404);
    const u = await admin(`/auth/v1/admin/users/${id}`, 'PUT', { password });
    if (!u.ok) return reply({ error: 'Nie zmieniono hasła.' }, 500);
    // A reset usually means a lost phone or a leaked password: end every open session.
    await admin('/rest/v1/rpc/pokoje_end_sessions', 'POST', { p_user: id });
    return reply({ ok: true });
  }

  if (b.action === 'delete') {
    // Staff row first: access is gone even if deleting the auth user fails.
    const s = await admin(`/rest/v1/pokoje_staff?email=eq.${encodeURIComponent(email)}`, 'DELETE');
    if (!s.ok) return reply({ error: 'Nie usunięto z zespołu.' }, 500);
    if (id) await admin(`/auth/v1/admin/users/${id}`, 'DELETE');
    return reply({ ok: true });
  }

  return reply({ error: 'Nieznana akcja.' }, 400);
});
