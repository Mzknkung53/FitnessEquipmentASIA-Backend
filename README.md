# Fitness Equipment Asia — Backend

Database (Supabase / PostgreSQL) for the Fitness Equipment Asia website: schema,
security rules and the database functions the site calls.

Scope for now: **product catalog + quotation requests + repair requests**. There is no
online ordering or payment; staff send quotations and handle payment outside the site.
All prices are stored **excluding VAT**; quotations add VAT (`vat_rate`, default 7%).

The frontend's server side (Next.js Server Actions) currently plays the backend role:
it holds the keys and calls the functions below. A separate API server can take that
over later without changing the database.

Design document (Thai, with ER diagram and access matrix): [`docs/database-design.md`](docs/database-design.md)

## Layout

| Path | What |
| --- | --- |
| `supabase/migrations/` | Schema, in order: foundation → catalog → inventory → sales → RLS → API (views + functions) → storage |
| `supabase/seed.sql` | Demo data from the frontend's sample products and stock (local, or once in a fresh project before launch) |
| `tests/database.test.sql` | ~80 checks: RLS per role, form functions, VAT, staff sign-in rules, stock state machine. Runs in a transaction and rolls back |
| `tests/supabase-stubs.sql` | Stand-ins for Supabase's `auth`/`storage` schemas and roles, for plain Postgres only |
| `scripts/verify-local.sh` | Throwaway Postgres → stubs → migrations → seed → tests, no Docker needed |

## Run locally

With the [Supabase CLI](https://supabase.com/docs/guides/local-development) and Docker:

```bash
supabase init        # once; creates supabase/config.toml, keeps the migrations
```

```bash
supabase start
```

```bash
supabase db reset    # applies migrations + seed.sql
```

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/database.test.sql
```

Without Docker (needs Postgres 15+ binaries):

```bash
scripts/verify-local.sh
```

## Deploy to a Supabase project

```bash
supabase link --project-ref <project-ref>
```

```bash
supabase db push     # migrations only; seed.sql is never pushed
```

For a first look with demo data, run `supabase/seed.sql` once in the dashboard's SQL Editor.
Without the CLI you can also paste each file of `supabase/migrations/` into the SQL Editor, in name order.

### Staff accounts (Google sign-in)

Staff sign in with Google. An account gets staff rights only when its email is **confirmed**
and listed in `private.staff_allowlist`; the allowlist creates the `staff_profiles` row once,
at that person's next sign-in. After that the row is managed directly:

```sql
insert into private.staff_allowlist (email, role, display_name) values ('name@example.com', 'sales', 'Name');
update public.staff_profiles set is_active = false where user_id = '<uuid>';   -- disable
update public.staff_profiles set role = 'warehouse' where user_id = '<uuid>';  -- change role
```

Only Google is used, so turn off the Email provider in Authentication → Sign In / Providers.

The secret key bypasses RLS: keep it server-side (the frontend reads it only in server code).

## How the server talks to the database

- **Public forms** (quote, repair): server code validates, then calls `submit_quote_request`,
  `submit_service_request`, `register_attachment` with the secret key. These functions are not
  callable with the publishable key.
- **Staff actions** (later, once staff login exists): the server forwards the staff user's JWT, so RLS applies and `auth.uid()` is
  recorded, e.g. `stock_apply_action('U-000201', 'receive')`.
- **Catalog**: read `products_public` (safe with the publishable key, so the frontend may also read it directly).

Validation errors use SQLSTATE `22023` with a short code (`missing:city`, `unknown_sku:…`) → HTTP 400;
`forbidden` (`42501`) → HTTP 403.

Generate TypeScript types for the API server once a database is running:

```bash
supabase gen types typescript --local > src/database.types.ts
```
