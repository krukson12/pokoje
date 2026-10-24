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
