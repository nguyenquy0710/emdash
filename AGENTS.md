This file provides guidance to agentic coding tools working in this repository. Focuses on patterns and gotchas an agent needs to write correct code.

For human-facing contributor info (setup, PR policy, changesets, i18n), see [CONTRIBUTING.md](CONTRIBUTING.md).

`CLAUDE.md` is a symlink to this file. `.opencode/skills` and `.claude/skills` are symlinks to `skills/`. Don't sync between them.

Skills available for loading via `skill`: `building-emdash-site`, `creating-plugins`, `emdash-cli`, `wordpress-plugin-to-emdash`, `wordpress-theme-to-emdash`.

Doc MCP server: `https://docs.emdashcms.com/mcp`.

# Rules

**Backwards compatibility matters.** Published pre-1.0. Prefer additive changes. Breaking changes need a decision, bump, and clear changeset. DB migrations are forward-only.

**TDD for bugs.** Failing test → fix → verify. A bug without a reproducing test is not fixed.

**Localize everything user-facing.** Admin UI strings, aria labels, toasts → Lingui. RTL-safe logical Tailwind classes.

**Scope discipline.** No drive-by refactors, no "while I'm here" edits. Systemic issue → open a Discussion.

**Updates must be typed.** When changing a `_emdash_fields` `.settings` column, update the union type in the codebase that matches it.

## Workflow

```bash
pnpm lint:json | jq '.diagnostics | length'   # confirm clean before starting
pnpm lint:quick   # after every edit (sub-second)
pnpm typecheck    # packages, or pnpm typecheck:demos for demos, pnpm typecheck:templates for templates
pnpm format       # regular (oxfmt for code, prettier for .astro)
```

Before PR: tests pass, lint clean, formatted, changeset added if published package changed.

Changeset = release notes for users, **not** a commit message or diff summary. Lead with present-tense verb (`Fixes`, `Adds`, `Updates`, `Removes`), describe observable effect, one sentence often enough.

When opening a PR via `gh`/API: copy `.github/PULL_REQUEST_TEMPLATE.md` into body and fill every section — the UI injects it automatically but the CLI does not, and PRs missing it are auto-closed. Check AI-generated code disclosure, name the model.

# Architecture

EmDash: Astro-native CMS on Cloudflare (D1 + R2 + Workers) or Node + SQLite.

- **Schema in DB.** `_emdash_collections` + `_emdash_fields` are source of truth. Each collection → real SQL table (`ec_posts`) with typed columns, not EAV.
- **Middleware chain:** runtime init → setup check → auth → request context (ALS). Auth middleware checks authentication only; routes check authorization.
- **Handler layer** (`packages/core/src/api/handlers/*.ts`): business logic, returns `ApiResult<T>`. Routes are thin wrappers.
- **Storage:** `Storage` interface (`upload/download/delete/exists/list/getSignedUploadUrl`). `LocalStorage` for dev, `S3Storage` for R2/AWS.

Key files:

| File | Purpose |
|---|---|
| `packages/core/src/emdash-runtime.ts` | Central runtime; orchestrates DB, plugins, storage |
| `packages/core/src/schema/registry.ts` | Manages `ec_*` table creation/modification |
| `packages/core/src/database/migrations/runner.ts` | StaticMigrationProvider; register new migrations here |
| `packages/core/src/plugins/manager.ts` | Loads and orchestrates plugins |

# Database

Kysely is the query builder. **Never** interpolate into SQL.

- **Values:** Kysely `sql` tagged template (auto-parameterized).
- **Identifiers:** `sql.ref()`.
- If you must use `sql.raw()` for dynamic identifiers, validate with `validateIdentifier()` from `database/validate.ts` (`/^[a-z][a-z0-9_]*$/`).
- `json_extract(data, '$.${field}')` — always validate `field`.

```typescript
// WRONG
const query = `SELECT * FROM ${table} WHERE name = '${name}'`;
await sql.raw(query).execute(db);

// RIGHT — parameterized value, safe identifier
await sql`SELECT * FROM ${sql.ref(table)} WHERE name = ${name}`.execute(db);

// RIGHT — validated identifier in raw SQL
validateIdentifier(field);
return sql.raw(`json_extract(data, '$.${field}')`);
```

**Migrations** live in `packages/core/src/database/migrations/`. Naming: `NNN_descriptive_name.ts`. Static imports in `runner.ts` + added to `getMigrations()` (not auto-discovered for Workers compat). Multi-table migrations: query `_emdash_collections` and loop (see `013_scheduled_publishing.ts`).

**Index naming:** `idx_{table}_{column}` single-column, `idx_{table}_{purpose}` multi-column.

**Content tables:** `ec_{collection_slug}`. System tables: `_emdash_{name}`. Slugs: `/^[a-z][a-z0-9_]*$/`, max 63 chars, checked against `RESERVED_COLLECTION_SLUGS` / `RESERVED_FIELD_SLUGS`.

**Content localization:** row-per-locale (migration `019_i18n.ts`). Every `ec_*` table has `locale` (default `'en'`) and `translation_group` (ULID). `UNIQUE(slug, locale)`. Every query must filter by `locale`.

# API Routes

Routes: `packages/core/src/astro/routes/api/`. Convention: `export const prerender = false;`. File structure mirrors URLs.

| Need | Use |
|---|---|
| Error response | `apiError(code, message, status)` from `#api/error.js` |
| Catch block | `handleError(error, message, code)` — never expose `error.message` |
| Body validation | `parseBody(request, zodSchema)` from `#api/parse.js` |
| Unwrap handler | `unwrapResult(result)` — maps error codes via `mapErrorStatus` |
| Init check | `if (!emdash) return apiError("NOT_CONFIGURED", "EmDash is not initialized", 500);` |

**Authorization** — permission-based, not role-based. `Permissions` map in `packages/auth/src/rbac.ts` is authoritative. Use `requirePerm(user, perm)` and `requireOwnerPerm(user, ownerId, ownPerm, anyPerm)` from `#api/authorize.js`. Both return `null` on success or a `Response`.

**CSRF:** All state-changing endpoints need `X-EmDash-Request: 1` header (enforced by auth middleware).

**Pagination:** `{ items, nextCursor? }` — never bare array. `encodeCursor`/`decodeCursor`. Default limit 50, max 100.

**URL/redirect:** require leading `/`, reject `//`, HTML-escape before interpolation, prefer `Response.redirect()`.

# Admin UI

React SPA at `packages/admin/`, mounted at `/_emdash/admin/*`. Uses [Kumo](https://github.com/cloudflare/kumo) design system — never roll your own components.

```bash
npx @cloudflare/kumo doc Button  # docs for any component
npx @cloudflare/kumo ls          # list all components
```

- `RouterLinkButton` wraps TanStack Router `<Link>` with Kumo styles. Never `<Link><Button>...</Button></Link>`.
- Use semantic Kumo tokens (`bg-kumo-brand`), never raw Tailwind colors or `dark:` prefixes.
- `ConfirmDialog`, `DialogError`, `getMutationError()` for dialogs.
- Admin API client: use `throwResponseError()` from `lib/api/client.ts` — never `throw new Error("Failed to X")`.

**Lingui** for all user-facing strings. Catalogs: `packages/admin/src/locales/{locale}/messages.po`. English source. Don't include `messages.po` changes in feature PRs — `pnpm locale:extract` runs on merge to main. Use `EMDASH_PSEUDO_LOCALE=1` in dev to spot leaks.

```typescript
// In components
import { useLingui, Trans } from "@lingui/react/macro";
const { t } = useLingui();           // inside component only
return <button aria-label={t`Delete post`}>{t`Delete`}</button>;

// Module scope — use msg, resolve with t() in component
import { msg } from "@lingui/core/macro";
const label = msg`Paragraph`;

// Pluralization
import { plural } from "@lingui/core/macro";
const label = plural(count, { one: "# item", other: "# items" });
```

**RTL-safe Tailwind:** use `ms-*` / `me-*`, `ps-*` / `pe-*`, `start-*` / `end-*`, `text-start` / `text-end`, `border-s` / `border-e`, `rounded-s-*` / `rounded-e-*`. Flip directional icons with `rtl:-scale-x-100`. Test in Arabic before declaring done.

# Performance

- **`requestCached`** (`src/request-cache.ts`): dedupes identical calls within a render. Wrap helpers with stable args.
- **Module-scope singletons** on `globalThis` with `Symbol.for` key (Vite duplicates modules across SSR chunks).
- **`after(fn)`** for deferred bookkeeping. Uses workerd `waitUntil` when available, fire-and-forgets on Node.
- **One query beats two.** `LEFT JOIN` for parent+children. Batch `WHERE id IN (...)` chunked at `SQL_BATCH_SIZE`.
- **Query-count snapshots:** `pnpm query-counts` records per-route counts. CI auto-updates on PRs — review the diff.

# Conventions

- **Internal imports** use `.js` extensions (ESM). Type-only: `import type` (`verbatimModuleSyntax` on).
- Virtual modules: `// @ts-ignore - virtual module`.
- Barrel files: separate `export type { ... }` from value exports.
- Use `import.meta.env.DEV` / `import.meta.env.PROD`, never `process.env.NODE_ENV`.
- Secrets: `import.meta.env.EMDASH_X || import.meta.env.X || ""`.
- Cloudflare `env` from `"cloudflare:workers"` virtual module. Don't manually type `Env` — run `pnpm wrangler types` to generate `worker-configuration.d.ts`. Local secrets in `.env` (not `.dev.vars`).

# Testing

- **Framework:** vitest. Tests in `packages/core/tests/` (unit, integration) and `e2e/tests/` (Playwright E2E).
- **No DB mocks.** SQLite (`better-sqlite3`) by default. PostgreSQL via `EMDASH_TEST_PG` env var with per-test schema isolation.
- **Test utilities:** `tests/utils/test-db.ts` — `setupTestDatabase()`, `setupTestDatabaseWithCollections()`, `teardownTestDatabase()`, `describeEachDialect()` for dialect-parametric suites.
- **Browser tests:** `pnpm test:browser` (via Playwright component tests in `packages/admin`).
- **Dev bypass** for auth-less browser testing: `GET /_emdash/api/setup/dev-bypass?redirect=/_emdash/admin` or `GET /_emdash/api/auth/dev-bypass?redirect=/_emdash/admin` (dev only).

# Toolchain

- **pnpm** v11 — package manager
- **tsdown** — TypeScript builds (ESM + DTS)
- **vitest** — testing
- **oxfmt** — code formatting (tabs). Prettier for `.astro` files only.
- **oxlint** — linting (strict, type-aware). `pnpm lint:quick` / `pnpm lint:json`.
- **TypeScript:** target ES2024, module `preserve`, strict, `noUncheckedIndexedAccess`, `noImplicitOverride`, `verbatimModuleSyntax`.

Repo scripts:

| Command | What |
|---|---|
| `pnpm test` | All package unit/integration tests |
| `pnpm test:unit` | Core + auth + blocks + related packages |
| `pnpm test:browser` | Admin browser tests |
| `pnpm test:e2e` | Playwright E2E (workers: 1, serial) |
| `pnpm typecheck` | All packages |
| `pnpm typecheck:demos` | Demo sites |
| `pnpm typecheck:templates` | Template sites |
| `pnpm build` | All packages |
| `pnpm format` | oxfmt + prettier |
| `pnpm lint:quick` | oxlint (json output, fast) |
| `pnpm locale:extract` | Lingui catalog extraction |
| `pnpm query-counts` | Per-route query count snapshots |

Common imports: `Button`, `LinkButton`, `Dialog`, `Input`, `InputArea`, `Select`, `Checkbox`, `Switch`, `Loader`, `Badge`, `Toast`/`Toasty`, `Popover`, `Dropdown`, `Tooltip`, `Label`, `CommandPalette`.

### Buttons and links

| Need                                      | Component                        |
| ----------------------------------------- | -------------------------------- |
| In-place action                           | `Button`                         |
| External link styled as a button          | `LinkButton href="..." external` |
| Internal router-aware link as a button    | `RouterLinkButton to="..."`      |
| Non-button element needing button classes | `buttonVariants(...)`            |

`RouterLinkButton` wraps TanStack Router's `<Link>` with Kumo button classes. Never write `<Link><Button>...</Button></Link>` (invalid `<a><button>` HTML). Never hand-roll button styling on an `<a>`.

### Styling rules

- Use semantic tokens (`bg-kumo-brand`, `text-kumo-subtle`). Never raw Tailwind colors.
- Never use `dark:` prefixes. Kumo's tokens use CSS `light-dark()`.
- Never duplicate component styles. If you're writing `bg-kumo-brand text-white rounded-md px-3 py-2` on a `<button>`, use Kumo's `Button` instead.

### Dialogs and errors

- `ConfirmDialog` (in `components/`) for confirm/cancel modals. Pass `mutation.error` directly -- don't manage error state manually.
- `DialogError` + `getMutationError()` for inline errors in form dialogs.
- Admin API client functions use `throwResponseError()` from `lib/api/client.ts` to surface server messages -- never `throw new Error("Failed to X")` and lose the body.

## Admin UI: Localization (Lingui)

Every user-facing string goes through Lingui. No hard-coded English in JSX, attributes, or strings that end up in the DOM.

- Catalogs: `packages/admin/src/locales/{locale}/messages.po`. English is source.
- Enabled locales: `packages/admin/src/locales/locales.ts`.
- **Don't include `messages.po` changes in non-translation PRs.** A workflow runs `pnpm locale:extract` on merge to `main`. Including extracted catalog updates in feature PRs creates merge churn -- revert before opening.
- Set `EMDASH_PSEUDO_LOCALE=1` in dev to render pseudo-localized text and spot untranslated leaks.

```typescript
import { useLingui } from "@lingui/react/macro";
import { Trans } from "@lingui/react/macro";

function DeleteButton() {
	const { t } = useLingui();
	return <button aria-label={t`Delete post`}>{t`Delete`}</button>;
}

// JSX with nested components
<Trans>Published by <strong>{authorName}</strong> on {formattedDate}</Trans>

// Pluralization
import { plural } from "@lingui/core/macro";
const label = plural(count, { one: "# item", other: "# items" });

// Module-scope constants: msg`` descriptors, resolved with t() in the component
import { msg } from "@lingui/core/macro";
import type { MessageDescriptor } from "@lingui/core";

const transforms: { id: string; label: MessageDescriptor }[] = [
	{ id: "paragraph", label: msg`Paragraph` },
];
// ...inside component: t(transforms[0].label)
```

Common mistakes:

- Bare string literals in JSX, unwrapped aria/title/placeholder/alt attributes.
- Concatenating translated pieces (`` t`Hello ` + name``) -- breaks word order. Use `` t`Hello ${name}` `` or `<Trans>`.
- Calling `t` at module scope -- locale isn't bound. Use `msg` + `t(descriptor)` inside a component.

Server-side error messages are English-only for now. Keep error codes stable (`SCREAMING_SNAKE_CASE`); the admin maps codes to localized messages client-side.

## Admin UI: RTL-safe Tailwind

The admin supports RTL locales. Use logical Tailwind classes, never physical:

| Use                           | Not                           |
| ----------------------------- | ----------------------------- |
| `ms-*` / `me-*`               | `ml-*` / `mr-*`               |
| `ps-*` / `pe-*`               | `pl-*` / `pr-*`               |
| `start-*` / `end-*`           | `left-*` / `right-*`          |
| `text-start` / `text-end`     | `text-left` / `text-right`    |
| `border-s` / `border-e`       | `border-l` / `border-r`       |
| `rounded-s-*` / `rounded-e-*` | `rounded-l-*` / `rounded-r-*` |
| `float-start` / `float-end`   | `float-left` / `float-right`  |

For directional icons (chevrons, arrows), flip them with `rtl:-scale-x-100` or use a bidi-aware icon.

`LocaleDirectionProvider` syncs `document.documentElement.dir`/`lang` automatically.

**Test new admin UI in Arabic** before declaring done. Broken directionality is the most common i18n regression.

# Conventions

## Imports

- **Internal imports** use `.js` extensions (ESM): `import { X } from "../foo.js"`.
- **Type-only imports** use `import type` (`verbatimModuleSyntax` is on).
- **Package imports** have no extension: `import { sql } from "kysely"`.
- **Virtual modules** need a `// @ts-ignore`: `// @ts-ignore - virtual module` above `import virtualConfig from "virtual:emdash/config"`.
- **Barrel files** separate `export type { ... }` from value exports.

## Environment

- Use `import.meta.env.DEV` / `import.meta.env.PROD` (Vite/Astro standard). Never `process.env.NODE_ENV`.
- Dev-only endpoints must check `import.meta.env.DEV` and return 403 otherwise -- it's a compile-time constant, unspoofable at runtime.
- Secrets pattern: `import.meta.env.EMDASH_X || import.meta.env.X || ""`.

## Cloudflare Env

Import `env` directly from `"cloudflare:workers"` -- a virtual module that resolves to the right bindings for the current environment (Worker or local dev).

Don't manually type the `Env` object. In a Worker context, run `pnpm wrangler types` to generate `worker-configuration.d.ts` (includes wrangler.jsonc bindings and `.env` secrets). Reference it in `tsconfig.json`'s `include`.

Local-dev secrets go in `.env` (read by Wrangler and the Cloudflare Vite plugin since Aug 2025), not `.dev.vars`. Note Wrangler loads either `.dev.vars` or `.env` but never both -- if a `.dev.vars` file exists it wins and `.env` is ignored entirely. Production secrets are set with `wrangler secret put`.

In libraries used in a Worker but not themselves Workers, install `@cloudflare/workers-types` and reference it in `tsconfig.compilerOptions.types`.

# Testing

- **Framework:** vitest. Tests in `packages/core/tests/`.
- **No mocks for the DB.** SQLite (`better-sqlite3`) by default. PostgreSQL parity tests via a real `pg` connection with per-test schema isolation (set `PG_CONNECTION_STRING` to opt in).
- **Utilities:** `tests/utils/test-db.ts` exposes `setupTestDatabase()`, `setupTestDatabaseWithCollections()`, `teardownTestDatabase()` for SQLite and `setupTestPostgresDatabase()` etc. for Postgres. Dialect-agnostic: `setupForDialect`, `setupForDialectWithCollections`, `teardownForDialect`, plus `describeEachDialect(name, fn)`. Use the dialect wrapper for query-builder code -- regressions tend to be dialect-specific.
- **Structure:** `tests/unit/`, `tests/integration/`, `tests/e2e/` (Playwright). Test files mirror source structure. Each test gets a fresh DB.

# Toolchain

- **pnpm** -- package manager
- **tsdown** -- TypeScript builds (ESM + DTS)
- **vitest** -- testing
- **oxfmt** -- formatting (tabs, configured in `.prettierrc`). All source files use tabs.

TypeScript: target ES2023, module `preserve`, strict mode with `noUncheckedIndexedAccess`, `noImplicitOverride`, `verbatimModuleSyntax`.

# Dev Bypass for Browser Testing

Passkey auth can't be automated in browser tests. Two dev-only endpoints (`import.meta.env.DEV` only, 403 in prod):

- `GET /_emdash/api/setup/dev-bypass?redirect=/_emdash/admin` -- runs migrations, creates a dev admin user (`dev@emdash.local`), establishes a session, redirects.
- `GET /_emdash/api/auth/dev-bypass?redirect=/_emdash/admin` -- assumes setup is complete, just creates a session.

In agent-browser:

```typescript
await page.goto("http://localhost:4321/_emdash/api/setup/dev-bypass?redirect=/_emdash/admin");
```
