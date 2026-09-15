-- ═══════════════════════════════════════════════════════════════════
--  Family Budget — schema and access rules
--  Run once in Supabase → SQL Editor → New query → Run.
--  Safe to re-run: every statement is guarded.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. Tables ─────────────────────────────────────────────────────

create table if not exists households (
  id         uuid primary key default gen_random_uuid(),
  name       text not null default 'Family',
  join_code  text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists household_members (
  household_id uuid not null references households(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  display_name text not null default '',
  can_edit     boolean not null default true,
  joined_at    timestamptz not null default now(),
  primary key (household_id, user_id)
);

create table if not exists settings (
  household_id  uuid primary key references households(id) on delete cascade,
  rate_uah_eur  numeric not null default 48.5  check (rate_uah_eur > 0),
  cushion_months int    not null default 6     check (cushion_months between 1 and 24),
  avg_window     int    not null default 6     check (avg_window between 1 and 24),
  cushion_saved  numeric not null default 0    check (cushion_saved >= 0),
  updated_at     timestamptz not null default now()
);

create table if not exists transactions (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  date         date not null,
  kind         text not null check (kind in ('income','expense')),
  amount       numeric not null check (amount > 0),
  currency     text not null check (currency in ('EUR','UAH')),
  rate         numeric not null default 1 check (rate > 0),
  eur          numeric not null check (eur >= 0),
  category     text not null default '',
  note         text not null default '',
  author       text not null default '',
  created_by   uuid references auth.users(id) on delete set null,
  demo         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists transactions_household_date_idx
  on transactions (household_id, date desc);

create table if not exists loans (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name         text not null default '',
  amount       numeric not null check (amount > 0),
  currency     text not null check (currency in ('EUR','UAH')),
  annual_rate  numeric not null default 0 check (annual_rate >= 0),
  term_months  int not null check (term_months between 1 and 600),
  start_date   date not null,
  extras       jsonb not null default '[]'::jsonb,
  demo         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists loans_household_idx on loans (household_id);

create table if not exists goals (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name         text not null default '',
  target       numeric not null default 0 check (target >= 0),
  saved        numeric not null default 0 check (saved >= 0),
  monthly      numeric not null default 0 check (monthly >= 0),
  demo         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists goals_household_idx on goals (household_id);

-- Guarded add for databases created before the demo flag existed.
alter table transactions add column if not exists demo boolean not null default false;
alter table loans        add column if not exists demo boolean not null default false;
alter table goals        add column if not exists demo boolean not null default false;

-- ─── 2. Membership helpers ─────────────────────────────────────────
-- security definer so the policies below can ask "is this user a member?"
-- without the members table having to read itself (which would recurse).

create or replace function public.is_member(h uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from household_members m
    where m.household_id = h and m.user_id = auth.uid()
  );
$$;

create or replace function public.can_edit(h uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from household_members m
    where m.household_id = h and m.user_id = auth.uid() and m.can_edit
  );
$$;

-- ─── 3. Creating and joining a household ───────────────────────────

-- Creates a household, makes the caller its first editor, seeds settings,
-- and returns the row. The join code is what the second person enters.
create or replace function public.create_household(p_name text, p_display_name text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  h households;
  code text;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;

  loop
    code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from households where join_code = code);
  end loop;

  insert into households (name, join_code)
  values (coalesce(nullif(trim(p_name), ''), 'Family'), code)
  returning * into h;

  insert into household_members (household_id, user_id, display_name, can_edit)
  values (h.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Me'), true);

  insert into settings (household_id) values (h.id);

  return h;
end;
$$;

-- The second person joins with the code. Editor rights by default —
-- pass p_can_edit := false to add a read-only member.
create or replace function public.join_household(
  p_code text,
  p_display_name text,
  p_can_edit boolean default true
)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  h households;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;

  select * into h from households
  where join_code = upper(trim(p_code));

  if h.id is null then
    raise exception 'no household with that code';
  end if;

  insert into household_members (household_id, user_id, display_name, can_edit)
  values (h.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Me'), p_can_edit)
  on conflict (household_id, user_id) do update
    set display_name = excluded.display_name;

  return h;
end;
$$;

-- Rotate the code once the second person is in, so an old code that
-- travelled through a messenger cannot be used again.
create or replace function public.rotate_join_code(p_household uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare code text;
begin
  if not can_edit(p_household) then
    raise exception 'not allowed';
  end if;
  loop
    code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from households where join_code = code);
  end loop;
  update households set join_code = code where id = p_household;
  return code;
end;
$$;

-- ─── 4. Row level security ─────────────────────────────────────────
-- Nothing is readable or writable unless a policy allows it, and every
-- policy asks the same question: are you a member of this household?

alter table households        enable row level security;
alter table household_members enable row level security;
alter table settings          enable row level security;
alter table transactions      enable row level security;
alter table loans             enable row level security;
alter table goals             enable row level security;

drop policy if exists households_read on households;
create policy households_read on households
  for select using (is_member(id));

drop policy if exists households_update on households;
create policy households_update on households
  for update using (can_edit(id)) with check (can_edit(id));

drop policy if exists members_read on household_members;
create policy members_read on household_members
  for select using (user_id = auth.uid() or is_member(household_id));

drop policy if exists members_update_self on household_members;
create policy members_update_self on household_members
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists members_leave on household_members;
create policy members_leave on household_members
  for delete using (user_id = auth.uid());

-- settings / transactions / loans / goals: members read, editors write
do $$
declare t text;
begin
  foreach t in array array['settings','transactions','loans','goals'] loop
    execute format('drop policy if exists %I_read on %I', t, t);
    execute format(
      'create policy %I_read on %I for select using (is_member(household_id))', t, t);

    execute format('drop policy if exists %I_insert on %I', t, t);
    execute format(
      'create policy %I_insert on %I for insert with check (can_edit(household_id))', t, t);

    execute format('drop policy if exists %I_update on %I', t, t);
    execute format(
      'create policy %I_update on %I for update using (can_edit(household_id)) with check (can_edit(household_id))', t, t);

    execute format('drop policy if exists %I_delete on %I', t, t);
    execute format(
      'create policy %I_delete on %I for delete using (can_edit(household_id))', t, t);
  end loop;
end $$;

-- ─── 4b. Grants ────────────────────────────────────────────────────
-- RLS decides WHICH rows; grants decide whether the signed-in browser
-- role may touch the table at all. Both are needed.

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  households, household_members, settings, transactions, loans, goals
  to authenticated;
grant execute on function
  public.create_household(text, text),
  public.join_household(text, text, boolean),
  public.rotate_join_code(uuid),
  public.is_member(uuid),
  public.can_edit(uuid)
  to authenticated;

-- ─── 5. Live updates ───────────────────────────────────────────────
-- What one person enters appears on the other's screen without a reload.

do $$
declare t text;
begin
  foreach t in array array['transactions','loans','goals','settings'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ─── 6. Keep settings.updated_at honest ────────────────────────────

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

drop trigger if exists settings_touch on settings;
create trigger settings_touch before update on settings
  for each row execute function public.touch_updated_at();
