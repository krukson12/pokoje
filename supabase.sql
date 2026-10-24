-- Pokoje: tablica stanu pokoi (dworek + hotel). Run: ~/terminy/sql.sh ~/pokoje/supabase.sql

create table if not exists pokoje_staff (
  email text primary key check (email = lower(email)),
  name text not null default '',
  role text not null check (role in ('edit', 'view'))
);
-- Owner rows can't be changed or removed from the app.
alter table pokoje_staff add column if not exists locked boolean not null default false;

create or replace function pokoje_role() returns text
language sql stable security definer set search_path = public as $$
  select role from pokoje_staff where email = lower(auth.jwt() ->> 'email')
$$;
grant execute on function pokoje_role() to authenticated;

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
  cleaned boolean not null default false,
  prepared boolean not null default false,
  keys_out boolean not null default false,
  keys_back boolean not null default false,
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text
);

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
create policy r on pokoje_staff for select to authenticated using (pokoje_role() is not null);
drop policy if exists i on pokoje_staff;
drop policy if exists u on pokoje_staff;
drop policy if exists d on pokoje_staff;
-- Editors manage others, never themselves (no locking yourself out) and never locked rows.
create policy i on pokoje_staff for insert to authenticated with check (pokoje_role() = 'edit' and not locked);
create policy u on pokoje_staff for update to authenticated
  using (pokoje_role() = 'edit' and not locked and email <> lower(auth.jwt() ->> 'email'))
  with check (not locked);
create policy d on pokoje_staff for delete to authenticated
  using (pokoje_role() = 'edit' and not locked and email <> lower(auth.jwt() ->> 'email'));

drop policy if exists r on pokoje_rooms;
drop policy if exists w on pokoje_rooms;
create policy r on pokoje_rooms for select to authenticated using (pokoje_role() is not null);
create policy w on pokoje_rooms for update to authenticated using (pokoje_role() = 'edit') with check (pokoje_role() = 'edit');

drop policy if exists r on pokoje_settings;
drop policy if exists w on pokoje_settings;
create policy r on pokoje_settings for select to authenticated using (pokoje_role() is not null);
create policy w on pokoje_settings for update to authenticated using (pokoje_role() = 'edit') with check (pokoje_role() = 'edit');

drop policy if exists r on pokoje_log;
create policy r on pokoje_log for select to authenticated using (pokoje_role() is not null);

do $$ begin
  alter publication supabase_realtime add table pokoje_rooms;
exception when duplicate_object then null;
end $$;

-- Seed: 4 rooms in the manor (one for newlyweds), hotel rooms 1-28 without 11. Rename in the app.
insert into pokoje_rooms (id, building, sort, name) values
  ('d1', 'dworek', 1, 'Dworek 1'),
  ('d2', 'dworek', 2, 'Dworek 2'),
  ('d3', 'dworek', 3, 'Dworek 3'),
  ('d4', 'dworek', 4, 'Dworek 4 (małżeński)')
on conflict do nothing;
insert into pokoje_rooms (id, building, sort, name)
  select 'h' || n, 'hotel', n, 'Hotel ' || n from generate_series(1, 28) n where n <> 11
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
  with check (pokoje_role() = 'edit' and day >= pokoje_today() and by = lower(auth.jwt() ->> 'email'));
create policy d on pokoje_blocks for delete to authenticated using (pokoje_role() = 'edit' and day >= pokoje_today());
revoke all on pokoje_blocks from anon, authenticated;
grant select, insert, delete on pokoje_blocks to authenticated;

-- Block the first p_count hotel rooms (by number) that are free on every day of the range.
-- One call at a time, so two people blocking at once never pick the same rooms.
create or replace function pokoje_block_hotel(p_from date, p_to date, p_count int, p_note text)
returns text[] language plpgsql security invoker set search_path = public as $$
declare picked text[];
begin
  if pokoje_role() is distinct from 'edit' then raise exception 'Brak uprawnień.'; end if;
  if p_from < pokoje_today() or p_to < p_from or p_to > p_from + 60 then raise exception 'Zły zakres dat.'; end if;
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

-- Live updates go through a counter on pokoje_settings: realtime DELETE events skip RLS
-- and would show outsiders which room was unblocked, UPDATE events don't.
alter table pokoje_settings add column if not exists blocks_rev bigint not null default 0;
create or replace function pokoje_blocks_bump() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update pokoje_settings set blocks_rev = blocks_rev + 1 where id = 1;
  return null;
end $$;
revoke execute on function pokoje_blocks_bump() from public, anon, authenticated;
drop trigger if exists pokoje_blocks_bump on pokoje_blocks;
create trigger pokoje_blocks_bump after insert or delete on pokoje_blocks for each statement execute function pokoje_blocks_bump();
do $$ begin
  alter publication supabase_realtime add table pokoje_settings;
exception when duplicate_object then null;
end $$;
