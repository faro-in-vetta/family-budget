-- ═══════════════════════════════════════════════════════════════════
--  Family Budget — міграція 003: місяць надходження / платежу
--
--  У статті з'являється позначка місяця. Порожньо — сума планується
--  щомісяця. Заповнено — сума планується лише в тому місяці.
--  Саме це дозволяє показати на графіку, що гроші від одного джерела
--  приходять у вересні, а від інших — у жовтні.
--
--  Запускати в Supabase → SQL Editor → New query → Run. Безпечно повторювати.
-- ═══════════════════════════════════════════════════════════════════

alter table categories
  add column if not exists pay_month text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'categories_pay_month_format'
  ) then
    alter table categories
      add constraint categories_pay_month_format
      check (pay_month is null or pay_month ~ '^\d{4}-\d{2}$');
  end if;
end $$;

comment on column categories.pay_month is
  'YYYY-MM — місяць, коли планується ця сума. NULL = щомісяця.';

-- Нові групи більше не отримують автоматичну статтю з тією ж назвою:
-- статті створює людина сама, під свої джерела чи платежі.
-- Стартовий набір (seed_groups) лишається як є — там стаття зручна.
