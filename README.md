# Family Budget

Shared household finances for two people: income and expenses in two currencies,
loan and debt payoff schedules, a safety-net target, and a forecast of free cash.

Two generations of the same product live here.

| | `app/` | root `index.html`, `index.uk.html` |
|---|---|---|
| Backend | Supabase (Postgres + auth) | Claude Artifact database |
| Who can use it | anyone you invite, with their own login | members of one Claude organisation |
| Hosting | any static host | claude.ai |
| Cost | free tier | included in a Claude plan |

**`app/` is the current version.** The root files are the earlier artifact build,
kept for reference.

Setup instructions (in Ukrainian): **[SETUP.md](SETUP.md)**

## What it does

**Transactions.** Income or expense, EUR or UAH. A UAH entry stores the rate that
applied when it was entered, so history does not drift when the rate changes.
Totals are in EUR.

**Loans and debts.** Annuity payments, payoff date, total interest over the term.
Extra payments shorten the term rather than the instalment — that is what cuts
total interest most, and the effect shows immediately.

**Safety net.** Target is N months of expenses *including* loan payments. The
forecast models what most planners miss: when a loan closes its payment is freed
and starts working for the safety net, so the curve gets steeper there.

**Two people, live.** What one enters appears on the other's screen without a
reload, over Postgres realtime.

## Security model

Every table has row level security on. Each policy asks one question: is the
signed-in user a member of this household? Nothing is readable or writable
otherwise — a stranger's query returns an empty set rather than an error, and a
write is rejected outright.

Members are either editors or view-only. A view-only member can read everything
and change nothing.

`supabase/test-access.sh` proves it rather than asserting it. Against a real
Postgres it creates two households and a stranger, then checks that the stranger
sees zero rows in every table, cannot insert into someone else's household,
and cannot change or delete their rows; that a view-only member can read but not
write; and that a rotated invite code stops working. Run it after any change to
the policies.

The `anon` key in `config.js` is public by design — it only names the project.
Access is decided by the policies, not by keeping the key secret. The
`service_role` key must never appear in this repository or in any page.

## Files

```
app/
  index.html            the whole application: markup, styles, logic, charts
  config.example.js     copy to config.js and fill in your project's keys
supabase/
  schema.sql            tables, policies, invite codes, realtime — run once
  test-access.sh        proves the policies actually isolate households
SETUP.md                step-by-step setup
```

## How the numbers are calculated

- **Averages** use the last N *complete* months; the current month is excluded
  because it is partial and would understate expenses.
- **Loan payments** come from the Loans section, not from the ledger. Entering
  them twice double-counts them.
- **Free cash** = average income − average expenses − loan payments − goal
  contributions.
- **The forecast ignores** inflation, income changes and currency movements. It
  answers "what if everything stays as it is now", which is a useful question
  and not a prediction.

## Still to do

- One page with a UK/EN switch instead of separate language files.
- CSV import from a bank statement — the single biggest reason budget tools get
  abandoned is the typing.
- Per-category monthly limits with a warning when a month is running over.
