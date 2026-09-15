-- ═══════════════════════════════════════════════════════════════════
--  Family Budget — міграція 002: групи, статті, плани
--
--  Що додає:
--   • основні групи (Їжа, Кредити, Оренда, …) — можна додавати свої
--   • статті всередині групи (підгрупи), у кожної свій план на місяць
--   • правку плану для окремого місяця
--   • прив'язку операцій до статті
--
--  Кредити більше не окремий модуль: це звичайна група статей.
--  Стара таблиця loans лишається недоторканою, але сторінка її не читає.
--
--  Запускати в Supabase → SQL Editor → New query → Run. Безпечно повторювати.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. Групи ──────────────────────────────────────────────────────

create table if not exists groups (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  kind         text not null check (kind in ('income','expense')),
  name         text not null,
  sort         int  not null default 100,
  archived     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists groups_household_idx on groups (household_id, kind, sort);

-- ─── 2. Статті (підгрупи) ──────────────────────────────────────────

create table if not exists categories (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  group_id     uuid not null references groups(id) on delete cascade,
  name         text not null,
  plan         numeric not null default 0 check (plan >= 0),  -- базовий план на місяць, EUR
  note         text not null default '',
  sort         int  not null default 100,
  archived     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists categories_household_idx on categories (household_id, group_id, sort);

-- ─── 3. Правка плану на конкретний місяць ──────────────────────────
-- Базовий план діє щомісяця. Рядок тут перекриває його для одного місяця.

create table if not exists plan_overrides (
  household_id uuid not null references households(id) on delete cascade,
  category_id  uuid not null references categories(id) on delete cascade,
  month        text not null check (month ~ '^\d{4}-\d{2}$'),
  plan         numeric not null check (plan >= 0),
  updated_at   timestamptz not null default now(),
  primary key (category_id, month)
);
create index if not exists plan_overrides_household_idx on plan_overrides (household_id, month);

-- ─── 4. Операція знає свою статтю ──────────────────────────────────
-- category_id — зв'язок; category / group_name — знімок назв на момент
-- запису, щоб перейменування чи видалення статті не переписало історію.

alter table transactions add column if not exists category_id uuid references categories(id) on delete set null;
alter table transactions add column if not exists group_name  text not null default '';
create index if not exists transactions_category_idx on transactions (household_id, category_id);

-- ─── 5. Права й політики для нових таблиць ─────────────────────────

alter table groups         enable row level security;
alter table categories     enable row level security;
alter table plan_overrides enable row level security;

do $$
declare t text;
begin
  foreach t in array array['groups','categories','plan_overrides'] loop
    execute format('drop policy if exists %I_read on %I', t, t);
    execute format('create policy %I_read on %I for select using (is_member(household_id))', t, t);

    execute format('drop policy if exists %I_insert on %I', t, t);
    execute format('create policy %I_insert on %I for insert with check (can_edit(household_id))', t, t);

    execute format('drop policy if exists %I_update on %I', t, t);
    execute format('create policy %I_update on %I for update using (can_edit(household_id)) with check (can_edit(household_id))', t, t);

    execute format('drop policy if exists %I_delete on %I', t, t);
    execute format('create policy %I_delete on %I for delete using (can_edit(household_id))', t, t);
  end loop;
end $$;

grant select, insert, update, delete on groups, categories, plan_overrides to authenticated;

-- ─── 6. Живі оновлення ─────────────────────────────────────────────

do $$
declare t text;
begin
  foreach t in array array['groups','categories','plan_overrides'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ─── 7. Стартовий набір груп ───────────────────────────────────────
-- Кожна група одразу отримує одну статтю з тією ж назвою, щоб можна було
-- поставити план, не вигадуючи підгруп. Підгрупи додаються за потреби.

create or replace function public.seed_groups(p_household uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  g record;
  gid uuid;
  defaults constant text[][] := array[
    ['expense','Їжа','10'],
    ['expense','Кредити','20'],
    ['expense','Оренда','30'],
    ['expense','Комунальні','40'],
    ['expense','Авто','50'],
    ['expense','Діти','60'],
    ['expense','Здоров''я','70'],
    ['expense','Одяг','80'],
    ['expense','Дозвілля','90'],
    ['income','Зарплата','10'],
    ['income','Інші надходження','20']
  ];
  i int;
begin
  if not can_edit(p_household) then
    raise exception 'not allowed';
  end if;
  if exists (select 1 from groups where household_id = p_household) then
    return;  -- уже заповнено, нічого не чіпаємо
  end if;

  for i in 1 .. array_length(defaults, 1) loop
    insert into groups (household_id, kind, name, sort)
    values (p_household, defaults[i][1], defaults[i][2], defaults[i][3]::int)
    returning id into gid;

    insert into categories (household_id, group_id, name, sort)
    values (p_household, gid, defaults[i][2], 10);
  end loop;
end;
$$;

grant execute on function public.seed_groups(uuid) to authenticated;

-- нові домогосподарства отримують набір одразу при створенні
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

  perform seed_groups(h.id);

  return h;
end;
$$;

grant execute on function public.create_household(text, text) to authenticated;
