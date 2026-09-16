-- ═══════════════════════════════════════════════════════════════════
--  Family Budget — міграція 005: помісячні плани і завдання
--
--  1. План тепер живе окремо для КОЖНОГО місяця. Раніше сума стояла на
--     статті й повторювалась усюди — виправляєш жовтень, злітає вересень.
--     Таблиця plan_overrides (створена міграцією 002) стає основним
--     сховищем планів: один рядок = одна стаття в одному місяці.
--     Наявні суми переносяться у свій місяць, щоб нічого не загубилось.
--
--  2. Нова таблиця tasks — завдання на місяць: дата, час, текст, «виконано».
--
--  Запускати в Supabase → SQL Editor → New query → Run. Безпечно повторювати.
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. Переносимо наявні плани в їхній місяць ─────────────────────
-- Стаття з позначкою місяця (pay_month) іде у той місяць.
-- Стаття без позначки — у поточний місяць; далі копіюється кнопкою.

insert into plan_overrides (household_id, category_id, month, plan)
select c.household_id,
       c.id,
       coalesce(nullif(c.pay_month, ''), to_char(now(), 'YYYY-MM')),
       c.plan
from categories c
where c.plan > 0
  and not exists (
    select 1 from plan_overrides o
    where o.category_id = c.id
      and o.month = coalesce(nullif(c.pay_month, ''), to_char(now(), 'YYYY-MM'))
  );

-- ─── 2. Завдання на місяць ─────────────────────────────────────────

create table if not exists tasks (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  due_date     date not null,
  due_time     text not null default '',      -- 'HH:MM' або порожньо на весь день
  title        text not null,
  note         text not null default '',
  done         boolean not null default false,
  done_at      timestamptz,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists tasks_household_idx on tasks (household_id, due_date);

alter table tasks enable row level security;

do $$
begin
  drop policy if exists tasks_read on tasks;
  create policy tasks_read on tasks for select using (is_member(household_id));

  drop policy if exists tasks_insert on tasks;
  create policy tasks_insert on tasks for insert with check (can_edit(household_id));

  drop policy if exists tasks_update on tasks;
  create policy tasks_update on tasks for update using (can_edit(household_id))
    with check (can_edit(household_id));

  drop policy if exists tasks_delete on tasks;
  create policy tasks_delete on tasks for delete using (can_edit(household_id));
end $$;

grant select, insert, update, delete on tasks to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tasks'
  ) then
    alter publication supabase_realtime add table public.tasks;
  end if;
end $$;

comment on table tasks is 'Завдання родини: дата, час, текст, позначка «виконано».';
