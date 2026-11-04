-- Pokoje: tablica stanu pokoi (dworek + hotel). Run: REF=wkzaebbfhytuauioqjqw ~/terminy/sql.sh ~/pokoje/supabase.sql (sql.sh defaults to the Duely project now)

create table if not exists pokoje_staff (
  email text primary key check (email = lower(email)),
  name text not null default '',
  role text not null check (role in ('edit', 'view'))
);
-- Owner rows can't be changed or removed from the app.
alter table pokoje_staff add column if not exists locked boolean not null default false;

-- The session check makes a password reset (which ends sessions) cut access at once;
-- without it the person's old token kept working until it expired (up to an hour).
create or replace function pokoje_role() returns text
language sql stable security definer set search_path = public as $$
  select role from pokoje_staff
  where email = lower(auth.jwt() ->> 'email')
    and exists (select 1 from auth.sessions where id::text = auth.jwt() ->> 'session_id')
$$;
grant execute on function pokoje_role() to authenticated;

-- Roles: admin (owner, also sees the history), edit, view.
alter table pokoje_staff drop constraint if exists pokoje_staff_role_check;
alter table pokoje_staff add constraint pokoje_staff_role_check check (role in ('admin', 'edit', 'view'));
create or replace function pokoje_can_edit() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(pokoje_role() in ('admin', 'edit'), false)
$$;
revoke execute on function pokoje_can_edit() from public, anon;
grant execute on function pokoje_can_edit() to authenticated;

-- For the pokoje-staff edge function (service role only).
create or replace function pokoje_user_id(p_email text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from auth.users where email = lower(p_email)
$$;
revoke execute on function pokoje_user_id(text) from public, anon, authenticated;
grant execute on function pokoje_user_id(text) to service_role;

create table if not exists pokoje_rooms (
  id text primary key,
  building text not null check (building in ('dworek', 'hotel')),
  sort int not null,
  name text not null,
  occupied boolean not null default false,
  guest text not null default '',
  extra_beds int not null default 0 check (extra_beds between 0 and 3),
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text
);

-- Left over from the removed cleaning/keys checklist.
alter table pokoje_rooms drop column if exists cleaned, drop column if exists prepared,
  drop column if exists keys_out, drop column if exists keys_back;

create table if not exists pokoje_settings (
  id int primary key default 1 check (id = 1),
  extra_beds_total int check (extra_beds_total >= 0)
);

create table if not exists pokoje_log (
  id bigserial primary key,
  room_id text not null,
  at timestamptz not null default now(),
  by text,
  old jsonb not null,
  new jsonb not null
);
-- tbl = which table changed; room_id is set for rooms and blocks.
alter table pokoje_log add column if not exists tbl text not null default 'pokoje_rooms';
alter table pokoje_log alter column room_id drop not null;
create index if not exists pokoje_log_room on pokoje_log (room_id, at desc);
create index if not exists pokoje_log_at on pokoje_log (at desc);

-- Who changed what: stamp the row and keep the old/new row in the log.
create or replace function pokoje_rooms_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := lower(auth.jwt() ->> 'email');
  if (to_jsonb(new) - 'updated_at' - 'updated_by') <> (to_jsonb(old) - 'updated_at' - 'updated_by') then
    insert into pokoje_log (room_id, by, old, new) values (new.id, new.updated_by, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end $$;
drop trigger if exists pokoje_rooms_stamp on pokoje_rooms;
create trigger pokoje_rooms_stamp before update on pokoje_rooms for each row execute function pokoje_rooms_stamp();

alter table pokoje_staff enable row level security;
alter table pokoje_rooms enable row level security;
alter table pokoje_settings enable row level security;
alter table pokoje_log enable row level security;

drop policy if exists r on pokoje_staff;
drop policy if exists w on pokoje_staff;
create policy r on pokoje_staff for select to authenticated using (pokoje_can_edit());
drop policy if exists i on pokoje_staff;
drop policy if exists u on pokoje_staff;
drop policy if exists d on pokoje_staff;
-- Editors manage others, never themselves (no locking yourself out) and never locked rows.
-- Only admins create, change or remove admins.
create policy i on pokoje_staff for insert to authenticated
  with check (pokoje_can_edit() and not locked and (role <> 'admin' or pokoje_role() = 'admin'));
create policy u on pokoje_staff for update to authenticated
  using (pokoje_can_edit() and not locked and email <> lower(auth.jwt() ->> 'email') and (role <> 'admin' or pokoje_role() = 'admin'))
  with check (not locked and (role <> 'admin' or pokoje_role() = 'admin'));
create policy d on pokoje_staff for delete to authenticated
  using (pokoje_can_edit() and not locked and email <> lower(auth.jwt() ->> 'email') and (role <> 'admin' or pokoje_role() = 'admin'));

drop policy if exists r on pokoje_rooms;
drop policy if exists w on pokoje_rooms;
create policy r on pokoje_rooms for select to authenticated using (pokoje_role() is not null);
create policy w on pokoje_rooms for update to authenticated using (pokoje_can_edit()) with check (pokoje_can_edit());

drop policy if exists r on pokoje_settings;
drop policy if exists w on pokoje_settings;
create policy r on pokoje_settings for select to authenticated using (pokoje_role() is not null);
create policy w on pokoje_settings for update to authenticated using (pokoje_can_edit()) with check (pokoje_can_edit());

drop policy if exists r on pokoje_log;
create policy r on pokoje_log for select to authenticated using (pokoje_role() = 'admin');

do $$ begin
  alter publication supabase_realtime add table pokoje_rooms;
exception when duplicate_object then null;
end $$;

-- Seed: manor rooms 27-30 (30 for newlyweds), hotel rooms 1-27 (ids h1-h28 skip h11; h12 is named Hotel 11). Rename in the app.
insert into pokoje_rooms (id, building, sort, name) values
  ('d1', 'dworek', 1, 'Dworek 27'),
  ('d2', 'dworek', 2, 'Dworek 28'),
  ('d3', 'dworek', 3, 'Dworek 29'),
  ('d4', 'dworek', 4, 'Dworek 30 (małżeński)')
on conflict do nothing;
insert into pokoje_rooms (id, building, sort, name)
  select 'h' || n, 'hotel', n, 'Hotel ' || (case when n > 11 then n - 1 else n end) from generate_series(1, 28) n where n <> 11
on conflict do nothing;
insert into pokoje_settings (id) values (1) on conflict do nothing;
-- Owner (once, by hand): insert into pokoje_staff (email, name, role, locked) values ('you@example.com', 'Imię', 'edit', true);

-- Least privilege: RLS already filters rows, but Supabase's default grants are far wider
-- (anon gets everything, TRUNCATE ignores RLS). Keep only what the app uses.
revoke all on pokoje_staff, pokoje_rooms, pokoje_settings, pokoje_log from anon, authenticated;
grant select on pokoje_staff, pokoje_rooms, pokoje_settings, pokoje_log to authenticated;
grant insert, update, delete on pokoje_staff to authenticated;
grant update on pokoje_rooms, pokoje_settings to authenticated;
revoke all on sequence pokoje_log_id_seq from anon, authenticated;
revoke execute on function pokoje_role() from public, anon;
revoke execute on function pokoje_rooms_stamp() from public, anon, authenticated;

-- Used by pokoje-staff after a password reset: logs that person out on every device.
create or replace function pokoje_end_sessions(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from auth.sessions where user_id = p_user
$$;
revoke execute on function pokoje_end_sessions(uuid) from public, anon, authenticated;
grant execute on function pokoje_end_sessions(uuid) to service_role;

-- ── Calendar: rooms blocked for future days ──
create table if not exists pokoje_blocks (
  room_id text not null references pokoje_rooms (id),
  day date not null,
  note text not null default '',
  by text default lower(auth.jwt() ->> 'email'),
  at timestamptz not null default now(),
  primary key (room_id, day)
);
create index if not exists pokoje_blocks_day on pokoje_blocks (day);
alter table pokoje_blocks enable row level security;

-- Today in the venue's timezone; past days stay as they were.
create or replace function pokoje_today() returns date language sql stable as $$
  select (now() at time zone 'Europe/Warsaw')::date
$$;

drop policy if exists r on pokoje_blocks;
drop policy if exists i on pokoje_blocks;
drop policy if exists d on pokoje_blocks;
create policy r on pokoje_blocks for select to authenticated using (pokoje_role() is not null);
create policy i on pokoje_blocks for insert to authenticated
  with check (pokoje_can_edit() and day >= pokoje_today() and by = lower(auth.jwt() ->> 'email'));
create policy d on pokoje_blocks for delete to authenticated using (pokoje_can_edit() and day >= pokoje_today());
revoke all on pokoje_blocks from anon, authenticated;
grant select, insert, delete on pokoje_blocks to authenticated;

-- Block the first p_count hotel rooms (by number) that are free on every day of the range.
-- One call at a time, so two people blocking at once never pick the same rooms.
create or replace function pokoje_block_hotel(p_from date, p_to date, p_count int, p_note text)
returns text[] language plpgsql security invoker set search_path = public as $$
declare picked text[];
begin
  if not pokoje_can_edit() then raise exception 'Brak uprawnień.'; end if;
  if p_from < pokoje_today() then raise exception 'Nie można blokować dni, które minęły.'; end if;
  if p_to < p_from then raise exception 'Data „do” jest wcześniejsza niż „od”.'; end if;
  if p_to > p_from + 60 then raise exception 'Naraz można zablokować najwyżej 61 dni.'; end if;
  if p_count is null or p_count < 1 then raise exception 'Podaj liczbę pokoi.'; end if;
  perform pg_advisory_xact_lock(hashtext('pokoje_blocks'));
  select array_agg(id order by sort) into picked from (
    select r.id, r.sort from pokoje_rooms r
    where r.building = 'hotel'
      and not exists (select 1 from pokoje_blocks b where b.room_id = r.id and b.day between p_from and p_to)
      and not (r.occupied and p_from = pokoje_today())
    order by r.sort limit p_count) f;
  if coalesce(array_length(picked, 1), 0) < p_count then
    raise exception 'W tym terminie wolnych pokoi w hotelu jest tylko %.', coalesce(array_length(picked, 1), 0);
  end if;
  insert into pokoje_blocks (room_id, day, note)
    select id, d::date, coalesce(trim(p_note), '') from unnest(picked) id, generate_series(p_from, p_to, interval '1 day') d;
  return (select array_agg(name order by sort) from pokoje_rooms where id = any(picked));
end $$;
revoke execute on function pokoje_block_hotel(date, date, int, text) from public, anon;
grant execute on function pokoje_block_hotel(date, date, int, text) to authenticated;


-- ── Events calendar (imported from the Excel "harmonogram", then edited in the app) ──
-- data keeps the spreadsheet's own column names as keys (see EVENT_COLS in index.html).
create table if not exists pokoje_events (
  id bigserial primary key,
  day date not null,
  kind text not null check (kind in ('impreza', 'komunia')),
  data jsonb not null default '{}' check (jsonb_typeof(data) = 'object'),
  sort int not null default 0,
  source text,
  updated_by text default lower(auth.jwt() ->> 'email'),
  updated_at timestamptz not null default now()
);
create index if not exists pokoje_events_day on pokoje_events (day);
alter table pokoje_events enable row level security;

create or replace function pokoje_events_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := lower(auth.jwt() ->> 'email');
  return new;
end $$;
revoke execute on function pokoje_events_stamp() from public, anon, authenticated;
drop trigger if exists pokoje_events_stamp on pokoje_events;
create trigger pokoje_events_stamp before update on pokoje_events for each row execute function pokoje_events_stamp();

drop policy if exists r on pokoje_events;
drop policy if exists w on pokoje_events;
create policy r on pokoje_events for select to authenticated using (pokoje_role() is not null);
create policy w on pokoje_events for all to authenticated using (pokoje_can_edit()) with check (pokoje_can_edit());
revoke all on pokoje_events from anon, authenticated;
grant select, insert, update, delete on pokoje_events to authenticated;
revoke all on sequence pokoje_events_id_seq from anon;
grant usage on sequence pokoje_events_id_seq to authenticated;


-- ── Event attachments (oferta, kosztorys, zdjęcia): PDF, DOCX, JPG, HEIC in a private bucket ──
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pokoje-files', 'pokoje-files', false, 20971520,
  array['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'image/jpeg', 'image/heic'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists pokoje_files_r on storage.objects;
drop policy if exists pokoje_files_i on storage.objects;
drop policy if exists pokoje_files_d on storage.objects;
create policy pokoje_files_r on storage.objects for select to authenticated
  using (bucket_id = 'pokoje-files' and public.pokoje_role() is not null);
create policy pokoje_files_i on storage.objects for insert to authenticated
  with check (bucket_id = 'pokoje-files' and public.pokoje_can_edit());
create policy pokoje_files_d on storage.objects for delete to authenticated
  using (bucket_id = 'pokoje-files' and public.pokoje_can_edit());

-- Storage keys can't hold Polish letters reliably, so the original file name lives here.
create table if not exists pokoje_files (
  id bigserial primary key,
  event_id bigint not null references pokoje_events (id) on delete cascade,
  name text not null,
  path text not null unique,
  size int,
  by text default lower(auth.jwt() ->> 'email'),
  at timestamptz not null default now()
);
create index if not exists pokoje_files_event on pokoje_files (event_id);
alter table pokoje_files enable row level security;
drop policy if exists r on pokoje_files;
drop policy if exists i on pokoje_files;
drop policy if exists d on pokoje_files;
create policy r on pokoje_files for select to authenticated using (pokoje_role() is not null);
create policy i on pokoje_files for insert to authenticated with check (pokoje_can_edit() and by = lower(auth.jwt() ->> 'email'));
create policy d on pokoje_files for delete to authenticated using (pokoje_can_edit());
revoke all on pokoje_files from anon, authenticated;
grant select, insert, delete on pokoje_files to authenticated;
revoke all on sequence pokoje_files_id_seq from anon;
grant usage on sequence pokoje_files_id_seq to authenticated;

-- Block details like the room sheet on "Dziś": guest (note), extra beds, notes.
alter table pokoje_blocks add column if not exists extra_beds int not null default 0 check (extra_beds between 0 and 3);
alter table pokoje_blocks add column if not exists details text not null default '';
drop policy if exists u on pokoje_blocks;
create policy u on pokoje_blocks for update to authenticated
  using (pokoje_can_edit() and day >= pokoje_today()) with check (pokoje_can_edit() and day >= pokoje_today());
grant update (note, extra_beds, details) on pokoje_blocks to authenticated;

-- ── Live refresh ──
-- Blocks, events and files aren't broadcast themselves: realtime DELETE events skip RLS and
-- would show outsiders what was removed. A counter on pokoje_settings (UPDATE events do
-- respect RLS) tells the app to reload.
alter table pokoje_settings add column if not exists rev bigint not null default 0;
create or replace function pokoje_bump() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update pokoje_settings set rev = rev + 1 where id = 1;
  return null;
end $$;
revoke execute on function pokoje_bump() from public, anon, authenticated;
drop trigger if exists pokoje_blocks_bump on pokoje_blocks;
drop trigger if exists pokoje_events_bump on pokoje_events;
drop trigger if exists pokoje_files_bump on pokoje_files;
drop trigger if exists pokoje_bump on pokoje_blocks;
drop trigger if exists pokoje_bump on pokoje_events;
drop trigger if exists pokoje_bump on pokoje_files;
create trigger pokoje_bump after insert or update or delete on pokoje_blocks for each statement execute function pokoje_bump();
create trigger pokoje_bump after insert or update or delete on pokoje_events for each statement execute function pokoje_bump();
create trigger pokoje_bump after insert or delete on pokoje_files for each statement execute function pokoje_bump();
drop function if exists pokoje_blocks_bump();
drop function if exists pokoje_events_bump();
alter table pokoje_settings drop column if exists blocks_rev, drop column if exists events_rev;
do $$ begin
  alter publication supabase_realtime add table pokoje_settings;
exception when duplicate_object then null;
end $$;

-- ── History for everything else (rooms log themselves in pokoje_rooms_stamp) ──
create or replace function pokoje_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
begin
  if o is not distinct from n then return null; end if;
  insert into pokoje_log (tbl, room_id, by, old, new)
  values (tg_table_name, coalesce(n, o) ->> 'room_id', lower(auth.jwt() ->> 'email'), coalesce(o, '{}'), coalesce(n, '{}'));
  return null;
end $$;
revoke execute on function pokoje_log_change() from public, anon, authenticated;
drop trigger if exists pokoje_log_change on pokoje_blocks;
drop trigger if exists pokoje_log_change on pokoje_events;
drop trigger if exists pokoje_log_change on pokoje_files;
drop trigger if exists pokoje_log_change on pokoje_staff;
create trigger pokoje_log_change after insert or update or delete on pokoje_blocks for each row execute function pokoje_log_change();
create trigger pokoje_log_change after insert or update or delete on pokoje_events for each row execute function pokoje_log_change();
create trigger pokoje_log_change after insert or delete on pokoje_files for each row execute function pokoje_log_change();
create trigger pokoje_log_change after insert or update or delete on pokoje_staff for each row execute function pokoje_log_change();
