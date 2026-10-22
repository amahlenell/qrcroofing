-- QRC Brain: Phase 1 core schema. Single-tenant. RLS enforced on every table.
create extension if not exists vector;
create extension if not exists pgcrypto;

-- ===== Enums =====
create type app_role as enum ('admin','manager','marketing','office','roofer');
create type access_level as enum ('all_staff','managers','admin');
create type task_status as enum ('todo','in_progress','blocked','done');
create type job_status as enum ('quoted','scheduled','in_progress','completed','on_hold','cancelled');
create type approval_status as enum ('pending','approved','rejected');
create type media_type as enum ('photo','drone_video','video','document','graphic');

-- ===== Helpers =====
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create table staff (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  role app_role not null default 'roofer',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Security definer so policies can read role without recursive RLS.
create or replace function current_role_name() returns app_role
language sql stable security definer set search_path = public as $$
  select role from staff where id = auth.uid() and active
$$;

create or replace function has_role(roles app_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_role_name() = any(roles), false)
$$;

create or replace function can_read_level(lvl access_level) returns boolean
language sql stable security definer set search_path = public as $$
  select case lvl
    when 'all_staff' then current_role_name() is not null
    when 'managers'  then has_role(array['admin','manager']::app_role[])
    when 'admin'     then has_role(array['admin']::app_role[])
  end
$$;

-- ===== Jobs (internal source of truth; CRM contact lives in GHL) =====
create table jobs (
  id uuid primary key default gen_random_uuid(),
  job_ref text not null unique,
  title text not null,
  site_address text,
  service text,
  status job_status not null default 'scheduled',
  ghl_contact_id text,            -- reference only, never a copy of CRM data
  supervisor_id uuid references staff(id),
  start_date date,
  end_date date,
  notes text,
  created_by uuid references staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on jobs(status);
create index on jobs(supervisor_id);

create table job_assignments (
  job_id uuid references jobs(id) on delete cascade,
  staff_id uuid references staff(id) on delete cascade,
  primary key (job_id, staff_id)
);

-- ===== Marketing goals and tasks =====
create table marketing_goals (
  id uuid primary key default gen_random_uuid(),
  channel text not null,                  -- website_blog, youtube, facebook, instagram, ...
  metric text not null default 'items_published',
  target_count integer,                   -- NULL = managed channel, no target invented
  period text not null default 'weekly',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (channel, period)
);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  status task_status not null default 'todo',
  assignee_id uuid references staff(id),
  due_date date,
  job_id uuid references jobs(id) on delete set null,
  goal_id uuid references marketing_goals(id) on delete set null,
  created_by uuid references staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on tasks(assignee_id, status);
create index on tasks(job_id);

-- ===== Media library =====
create table media_assets (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null unique,      -- Supabase Storage object path
  title text,
  media_type media_type not null,
  service text,
  job_id uuid references jobs(id) on delete set null,
  captured_on date,
  photographer text,
  location text,
  copyright_holder text,
  customer_consent boolean,               -- NULL = unknown, treated as not cleared
  consent_notes text,
  approval approval_status not null default 'pending',
  usage_restrictions text,
  uploaded_by uuid references staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on media_assets(job_id);
create index on media_assets(media_type, service);
create index on media_assets(captured_on);

-- ===== Knowledge library =====
create table knowledge_documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  source_type text not null default 'document',  -- document | training_video | procedure
  storage_path text,
  access access_level not null default 'all_staff',
  approved boolean not null default false,       -- only approved docs are retrievable by AI
  approved_by uuid references staff(id),
  approved_at timestamptz,
  version text,
  uploaded_by uuid references staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table knowledge_chunks (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references knowledge_documents(id) on delete cascade,
  chunk_index integer not null,
  content text not null,
  page_number integer,
  start_seconds integer,                  -- video transcript timestamp
  embedding vector(1024),
  unique (document_id, chunk_index)
);
create index on knowledge_chunks(document_id);
create index on knowledge_chunks using hnsw (embedding vector_cosine_ops);

-- ===== AI conversations =====
create table conversations (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id) on delete cascade,
  title text,
  created_at timestamptz not null default now()
);
create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null,
  citations jsonb not null default '[]',  -- [{document_id, chunk_id, page, start_seconds}]
  created_at timestamptz not null default now()
);
create index on messages(conversation_id, created_at);

-- ===== External record links (GHL etc.) =====
create table external_links (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid not null,
  system text not null,                   -- 'ghl'
  external_id text not null,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (system, external_id, entity_type)
);

-- ===== Audit log (append-only) =====
create table audit_events (
  id bigint generated always as identity primary key,
  actor_id uuid references staff(id),
  action text not null,
  entity_type text,
  entity_id text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on audit_events(entity_type, entity_id);
create index on audit_events(created_at desc);

-- ===== updated_at triggers =====
do $$ declare t text; begin
  foreach t in array array['staff','jobs','marketing_goals','tasks','media_assets','knowledge_documents']
  loop execute format('create trigger trg_%1$s_updated before update on %1$s for each row execute function set_updated_at()', t);
  end loop;
end $$;

-- ===== Row Level Security =====
alter table staff enable row level security;
alter table jobs enable row level security;
alter table job_assignments enable row level security;
alter table marketing_goals enable row level security;
alter table tasks enable row level security;
alter table media_assets enable row level security;
alter table knowledge_documents enable row level security;
alter table knowledge_chunks enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table external_links enable row level security;
alter table audit_events enable row level security;

-- staff: everyone active sees directory; users cannot change their own role
create policy staff_read on staff for select using (current_role_name() is not null);
create policy staff_admin_write on staff for all
  using (has_role(array['admin']::app_role[])) with check (has_role(array['admin']::app_role[]));

-- jobs: managers/office see all; roofers only jobs they are assigned to or supervise
create policy jobs_read on jobs for select using (
  has_role(array['admin','manager','office','marketing']::app_role[])
  or supervisor_id = auth.uid()
  or exists (select 1 from job_assignments a where a.job_id = jobs.id and a.staff_id = auth.uid())
);
create policy jobs_write on jobs for all
  using (has_role(array['admin','manager','office']::app_role[]))
  with check (has_role(array['admin','manager','office']::app_role[]));

create policy ja_read on job_assignments for select using (
  staff_id = auth.uid() or has_role(array['admin','manager','office']::app_role[]));
create policy ja_write on job_assignments for all
  using (has_role(array['admin','manager','office']::app_role[]))
  with check (has_role(array['admin','manager','office']::app_role[]));

-- marketing goals: all staff read; admin/manager/marketing write
create policy goals_read on marketing_goals for select using (current_role_name() is not null);
create policy goals_write on marketing_goals for all
  using (has_role(array['admin','manager','marketing']::app_role[]))
  with check (has_role(array['admin','manager','marketing']::app_role[]));

-- tasks: assignee/creator see own; managers and marketing see all
create policy tasks_read on tasks for select using (
  assignee_id = auth.uid() or created_by = auth.uid()
  or has_role(array['admin','manager','marketing','office']::app_role[]));
create policy tasks_insert on tasks for insert with check (
  current_role_name() is not null and created_by = auth.uid());
create policy tasks_update on tasks for update using (
  assignee_id = auth.uid() or created_by = auth.uid()
  or has_role(array['admin','manager','marketing']::app_role[]));
create policy tasks_delete on tasks for delete using (
  has_role(array['admin','manager']::app_role[]) or created_by = auth.uid());

-- media: staff see approved assets; uploaders see their own; marketing/managers see all and approve
create policy media_read on media_assets for select using (
  uploaded_by = auth.uid()
  or has_role(array['admin','manager','marketing']::app_role[])
  or (approval = 'approved' and current_role_name() is not null));
create policy media_insert on media_assets for insert with check (
  current_role_name() is not null and uploaded_by = auth.uid());
create policy media_update on media_assets for update using (
  uploaded_by = auth.uid() or has_role(array['admin','manager','marketing']::app_role[]));
create policy media_delete on media_assets for delete using (
  has_role(array['admin','manager']::app_role[]));

-- knowledge: retrieval requires approval AND access level (or admin/manager authoring)
create policy kd_read on knowledge_documents for select using (
  (approved and can_read_level(access)) or has_role(array['admin','manager']::app_role[]));
create policy kd_write on knowledge_documents for all
  using (has_role(array['admin','manager']::app_role[]))
  with check (has_role(array['admin','manager']::app_role[]));
create policy kc_read on knowledge_chunks for select using (
  exists (select 1 from knowledge_documents d where d.id = document_id
          and d.approved and can_read_level(d.access)));
create policy kc_write on knowledge_chunks for all
  using (has_role(array['admin','manager']::app_role[]))
  with check (has_role(array['admin','manager']::app_role[]));

-- conversations: strictly private to owner
create policy conv_own on conversations for all
  using (staff_id = auth.uid()) with check (staff_id = auth.uid());
create policy msg_own on messages for all
  using (exists (select 1 from conversations c where c.id = conversation_id and c.staff_id = auth.uid()))
  with check (exists (select 1 from conversations c where c.id = conversation_id and c.staff_id = auth.uid()));

-- external links: managers read; writes only via service role (server adapters)
create policy el_read on external_links for select using (
  has_role(array['admin','manager','office','marketing']::app_role[]));

-- audit: admins read; inserts only by service role or via logged-in actor; no update/delete policies
create policy audit_read on audit_events for select using (has_role(array['admin']::app_role[]));
create policy audit_insert on audit_events for insert with check (actor_id = auth.uid());

-- Auto-create a staff row (least privilege) when an auth user is created
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into staff (id, full_name, email, role, active)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), new.email, 'roofer', false);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- Seed the initial weekly goals. Other channels are managed but have NO invented target.
insert into marketing_goals (channel, target_count) values
  ('website_blog', 3), ('youtube', 1), ('facebook', 1),
  ('instagram', null), ('tiktok', null), ('linkedin', null), ('google_business_profile', null);

-- Vector search that respects RLS (security invoker): callers only see chunks they may read
create or replace function match_knowledge(query_embedding vector(1024), match_count int default 8)
returns table (chunk_id uuid, document_id uuid, content text, page_number int, start_seconds int, similarity float)
language sql stable security invoker as $$
  select c.id, c.document_id, c.content, c.page_number, c.start_seconds,
         1 - (c.embedding <=> query_embedding)
  from knowledge_chunks c
  order by c.embedding <=> query_embedding
  limit match_count
$$;
