# Family Budget

A shared household finance page for two people: income and expenses in two
currencies, loan and debt payoff schedules, a safety-net target, and a forecast
of free cash. One HTML file, no build step, no server of its own.

The point of it is the shared part. One person enters a transaction on a phone,
the other sees it on a laptop a second later.

## What it does

**Transactions.** Income or expense, in EUR or UAH. A UAH entry stores the rate
that applied when it was entered, so history does not drift every time the rate
changes. All totals are in EUR.

**Loans and debts.** Annuity payments, payoff date, total interest over the
whole term. Extra payments shorten the term rather than the instalment — that is
what cuts total interest the most, and the effect is visible immediately.

**Safety net.** The target is N months of expenses *including* loan payments.
The forecast models the thing most planners miss: when a loan closes, its
payment is freed and starts working for the safety net, so the curve gets
steeper at that point.

**Ledger.** Every entry records who made it.

## How the sharing works

The page uses the `db` runtime capability of a published Claude Artifact: a
realtime document store scoped to the artifact, shared by its viewers. There is
no backend to deploy and nothing to pay for.

This has two consequences worth understanding before you change the hosting:

- Served as a plain static file (GitHub Pages, any web host), `claude.use("db")`
  resolves `null`, the page falls back to browser-local storage and shows a
  banner. It still works — but only for one person on one device.
- A page declaring `db` cannot be made public. Every reader and writer is a
  signed-in member of the owner's organisation. That is enforced, not a setting.

To run it as intended, publish `index.html` as a Claude Artifact with
`capabilities: {db: {}}`.

Access rules used in the deployed version:

```js
capabilities: { db: { rules: [ { path: "", read: "interact", write: "admin" } ] } }
```

Everyone with access can read; only people granted edit rights can write. A
view-only viewer cannot modify or delete anything.

## Data model

| Path | Contents |
|---|---|
| `settings/main` | rate, safety-net months, averaging window, amount saved, member names |
| `tx/<YYYY-MM>` | one document per month, `items: []` — transactions are aggregated per month, not one document each, because the store is capped at 5,000 documents per artifact |
| `loans/<id>` | amount, currency, annual rate, term, start date, extra payments |
| `goals/<id>` | target, saved, monthly contribution |

Month documents are written under a short cooperative lease (`acquire`), so two
people adding a transaction in the same second cannot overwrite each other.

## How the numbers are calculated

- **Averages** use the last N *complete* months. The current month is excluded —
  it is partial and would understate expenses.
- **Loan payments** come from the Loans section, not from the ledger. Do not
  enter them twice.
- **Free cash** = average income − average expenses − loan payments − goal
  contributions.
- **Safety-net forecast** runs month by month for five years.

The forecast deliberately ignores inflation, income changes and currency
movements. It answers "what if everything stays as it is now", which is a useful
question and not a prediction.

## Customising

Everything visual lives in the token block at the top of the file: the palette,
the type scale, the two fonts. The categorical chart colours (`--c1`…`--c7`) are
validated for colour-vision deficiency and for contrast against both the light
and dark surfaces — if you swap them, re-validate rather than eyeballing.

Currency: `EUR` and `UAH` are wired through `toEur()` and the settings rate.
Adding a third currency means extending that function and the two currency
selects.

## Files

- `index.html` — the entire application: markup, styles, logic, charts.

No dependencies, no build. Open it in a browser and it runs.
