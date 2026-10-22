# QRC Brain — build brief for Claude Code

Internal platform for Quality Roof Co (NZ). Single-tenant. Not SaaS.
Stack: Next.js App Router, React, TypeScript, Tailwind, Supabase (Postgres, Auth, Storage, pgvector), OpenAI (Responses API for chat, text-embedding-3-small at 1536 dims for embeddings), Vercel, GitHub.
GoHighLevel (GHL) is the CRM source of truth. Credentials are NOT available yet, so GHL must run in a disconnected state.

## Decisions already made
- Auth: Supabase email + password. Invite-only. New users are created inactive with role `roofer`; an admin activates them and assigns a role (admin, manager, marketing, office, roofer).
- Access control is enforced by Postgres RLS. UI hiding is cosmetic only. Every server action and route handler calls `requireRole()`.
- Schema starts from `supabase/migrations/0001_core_schema.sql`. Add new migrations; never edit applied ones.
- AI retrieval runs with the signed-in user's JWT (never the service role) via `match_knowledge`, so RLS limits what can be cited.
- GHL stores IDs only (`external_links`, `jobs.ghl_contact_id`). Never copy CRM contacts or consent into Supabase.

## Brand tokens (Tailwind)
navy #152331, blue #2F4056, light green #ACD58B, green #7AB46E, off-white #F4EFEB, white #FFFFFF. Premium, clean, mobile-first.

## Non-negotiable rules
1. Do not fabricate customers, jobs, metrics, documents or technical roofing instructions. Empty states beat fake data.
2. AI answers must cite approved documents (title, page or video timestamp) and label content as "Verified from source" or "Suggestion". If nothing relevant is retrieved, say so and escalate to a supervisor for hazardous or uncertain situations.
3. Public publishing and external messages require explicit human approval.
4. Secrets stay server-side. Commit `.env.example` only.
5. Every write to jobs, tasks, media, knowledge or staff records an `audit_events` row.
6. Background work must be idempotent, retry with backoff, and surface clear integration errors.
7. GHL adapter: one interface, `DisconnectedGhlClient` returns a typed "not_connected" error; UI shows a "GHL not connected" state.

## Phase 1 order (do one step per session; commit after each; run tests)
1. Scaffold project, Tailwind brand tokens, Supabase clients (server, browser, middleware), `.env.example`.
2. Auth: login, middleware, pending-approval screen, admin staff page (activate, set role). pgTAP tests for RLS.
3. Dashboard shell: sidebar and mobile bottom nav, filtered by role.
4. Marketing goals (weekly progress from seeded goals) and task board.
5. Media library: private storage bucket with RLS, upload with consent/copyright/approval metadata, filters by service, job, date, type.
6. Knowledge Library (upload, approve, chunk, embed) and cited AI chat at `/brain`.
7. Job register with assignments, GHL link placeholder, audit log.

## Definition of done per step
Typechecks, lints, has tests (RLS tests for anything permission-sensitive), works on mobile width, and README updated.

## Env vars (.env.example)
NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (server only), OPENAI_API_KEY (server only), GHL_API_KEY and GHL_LOCATION_ID (leave blank until available).

## First prompt to give Claude Code
"Read CLAUDE.md and supabase/migrations/0001_core_schema.sql. Complete Phase 1 step 1 and step 2 only. Explain any trade-offs, then stop for review."
