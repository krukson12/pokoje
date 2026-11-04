// Permission rules and bulk blocking, run against supabase.sql in a local Postgres (PGlite).
// npm install && npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
// Stand-ins for what Supabase provides.
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth; create schema storage;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text);
  create table auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid);
  create function auth.jwt() returns jsonb language sql stable as
    $$ select coalesce(nullif(current_setting('t.jwt', true), ''), '{}')::jsonb $$;
  create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
  create table storage.objects (bucket_id text, name text);
  create publication supabase_realtime;
  grant usage on schema auth, public to authenticated, anon;`);
const sql = readFileSync(new URL('../supabase.sql', import.meta.url), 'utf8');
await db.exec(sql);
await db.exec(sql); // the file must stay safe to re-run

const session = {};
for (const [email, role] of [['owner@x.pl', 'admin'], ['adm@x.pl', 'admin'], ['ed@x.pl', 'edit'], ['vw@x.pl', 'view'], ['out@x.pl', null]]) {
  if (role) await db.query('insert into pokoje_staff (email, role, locked) values ($1, $2, $3)', [email, role, email === 'owner@x.pl']);
  session[email] = (await db.query('insert into auth.sessions default values returning id')).rows[0].id;
}
await db.exec(`insert into pokoje_events (day, kind, data, source, updated_by) values ('2099-01-01', 'impreza', '{"Nazwisko":"X"}', 'excel-2099', 'import excel')`);

// Run SQL as a signed-in user; returns rows, or the error message.
async function as(email, query, params) {
  const claims = JSON.stringify({ email, session_id: session[email] ?? '00000000-0000-0000-0000-000000000000' });
  try {
    await db.exec(`set role authenticated; select set_config('t.jwt', '${claims}', false);`);
    return (await db.query(query, params)).rows;
  } catch (e) { return e.message; } finally { await db.exec('reset role'); }
}
const ahead = n => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);

test('outsiders see nothing', async () => {
  for (const t of ['pokoje_rooms', 'pokoje_staff', 'pokoje_log', 'pokoje_blocks', 'pokoje_events', 'pokoje_files'])
    assert.equal((await as('out@x.pl', `select * from ${t}`)).length, 0, t);
  assert.equal((await as('out@x.pl', 'select pokoje_role() r'))[0].r, null);
});

test('viewers read rooms and events, but not the team or history, and change nothing', async () => {
  assert.equal((await as('vw@x.pl', 'select * from pokoje_rooms')).length, 31);
  assert.equal((await as('vw@x.pl', 'select * from pokoje_events')).length, 1);
  assert.equal((await as('vw@x.pl', 'select * from pokoje_staff')).length, 0);
  assert.equal((await as('vw@x.pl', 'select * from pokoje_log')).length, 0);
  assert.equal((await as('vw@x.pl', "update pokoje_rooms set note = 'x' where id = 'h1' returning id")).length, 0);
  assert.match(String(await as('vw@x.pl', `insert into pokoje_blocks (room_id, day) values ('h1', '${ahead(3)}')`)), /row-level security/);
});

test('editors manage rooms and the team, but not admins, themselves or the history', async () => {
  assert.equal((await as('ed@x.pl', "update pokoje_rooms set occupied = true where id = 'h2' and occupied = false returning id")).length, 1);
  assert.equal((await as('ed@x.pl', "update pokoje_rooms set occupied = true where id = 'h2' and occupied = false returning id")).length, 0, 'taking a taken room');
  assert.equal((await as('ed@x.pl', 'select * from pokoje_log')).length, 0);
  assert.ok((await as('ed@x.pl', 'select * from pokoje_staff')).length >= 4);
  assert.equal((await as('ed@x.pl', "update pokoje_staff set role = 'view' where email = 'adm@x.pl' returning email")).length, 0);
  assert.equal((await as('ed@x.pl', "delete from pokoje_staff where email = 'adm@x.pl' returning email")).length, 0);
  assert.equal((await as('ed@x.pl', "update pokoje_staff set role = 'view' where email = 'ed@x.pl' returning email")).length, 0, 'self');
  assert.match(String(await as('ed@x.pl', "insert into pokoje_staff (email, role) values ('new@x.pl', 'admin')")), /row-level security/);
  assert.match(String(await as('ed@x.pl', "update pokoje_staff set role = 'admin' where email = 'vw@x.pl'")), /row-level security/);
  assert.equal((await as('ed@x.pl', "update pokoje_staff set role = 'view' where email = 'vw@x.pl' returning email")).length, 1);
});

test('admins see the history and manage admins, but not the locked owner', async () => {
  assert.ok((await as('adm@x.pl', 'select * from pokoje_log')).length > 0);
  assert.equal((await as('adm@x.pl', "update pokoje_staff set role = 'admin' where email = 'vw@x.pl' returning email")).length, 1);
  assert.equal((await as('adm@x.pl', "update pokoje_staff set role = 'view' where email = 'vw@x.pl' returning email")).length, 1);
  assert.equal((await as('adm@x.pl', "update pokoje_staff set role = 'view' where email = 'owner@x.pl' returning email")).length, 0);
});

test('an ended session (password reset) loses access at once', async () => {
  await db.query('delete from auth.sessions where id = $1', [session['ed@x.pl']]);
  assert.equal((await as('ed@x.pl', 'select * from pokoje_rooms')).length, 0);
  assert.equal((await as('ed@x.pl', "update pokoje_rooms set note = 'x' where id = 'h1' returning id")).length, 0);
  session['ed@x.pl'] = (await db.query('insert into auth.sessions default values returning id')).rows[0].id;
});

test('bulk blocking takes the first free hotel rooms, all or nothing', async () => {
  const pick = async (from, to, n) => as('ed@x.pl', 'select pokoje_block_hotel($1, $2, $3, $4) x', [from, to, n, 'wesele']);
  assert.deepEqual((await pick(ahead(5), ahead(6), 3))[0].x, ['Hotel 1', 'Hotel 2', 'Hotel 3']);
  assert.deepEqual((await pick(ahead(6), ahead(6), 2))[0].x, ['Hotel 4', 'Hotel 5'], 'skips rooms blocked that day');
  assert.deepEqual((await pick(ahead(9), ahead(9), 11))[0].x.slice(-1), ['Hotel 11'], 'numbering has no gap');
  assert.match(String(await pick(ahead(20), ahead(20), 30)), /tylko 27/);
  assert.match(String(await pick(ahead(-1), ahead(-1), 1)), /minęły/);
  assert.match(String(await as('vw@x.pl', 'select pokoje_block_hotel($1, $1, 1, null)', [ahead(3)])), /Brak uprawnień/);
});

test('block details can change, the day and author cannot', async () => {
  const where = `where room_id = 'h1' and day = '${ahead(5)}'`;
  assert.equal((await as('ed@x.pl', `update pokoje_blocks set note = 'Nowak', extra_beds = 2, details = 'x' ${where} returning 1`)).length, 1);
  assert.match(String(await as('ed@x.pl', `update pokoje_blocks set day = '${ahead(7)}' ${where}`)), /permission denied/);
  assert.match(String(await as('ed@x.pl', `update pokoje_blocks set by = 'x' ${where}`)), /permission denied/);
});

test('deleting an event is in the history, with who did it', async () => {
  assert.equal((await as('ed@x.pl', "delete from pokoje_events where source = 'excel-2099' returning id")).length, 1);
  const log = await as('adm@x.pl', "select * from pokoje_log where tbl = 'pokoje_events'");
  assert.equal(log.at(-1).by, 'ed@x.pl');
  assert.equal(log.at(-1).old.source, 'excel-2099');
});
