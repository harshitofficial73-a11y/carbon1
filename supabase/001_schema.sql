-- ============================================================
-- RePut carbon accounting · Supabase schema
-- 001_schema.sql — types, tables, indexes, triggers
-- Postgres 15 / Supabase. Run before 002_rls.sql.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- enums ----------
create type app_role as enum ('operator', 'gsh', 'supplier', 'auditor', 'platform');
create type user_status as enum ('pending', 'active', 'suspended');
create type approval_authority as enum ('none', 'plant', 'group');
create type period_state as enum ('future', 'open', 'locked');
create type submission_status as enum ('draft', 'submitted', 'returned', 'approved', 'verified');
create type request_status as enum ('open', 'in_progress', 'submitted', 'closed', 'reopened');
create type factor_status as enum ('draft', 'published', 'archived');
create type audit_event as enum ('submission','approval','return','edit','factor_change','period_lock','access_change','login','export');

-- ---------- tenancy ----------
create table companies (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique,                 -- ARL-CO-001
  name           text not null,
  cin            text,
  sector         text,
  registered_address text,
  reporting_fy   text not null default 'FY 2025-26',
  base_year      text,
  consolidation  text not null default 'operational_control',
  email_domain   text,
  created_at     timestamptz not null default now()
);

create table clusters (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  code        text not null,
  name        text not null,
  region      text,
  unique (company_id, code)
);

create table units (                                    -- plants / facilities
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  cluster_id  uuid references clusters on delete set null,
  code        text not null,
  name        text not null,
  state       text,
  commissioned_on date,
  unique (company_id, code)
);

-- ---------- identity ----------
-- one row per auth.users record; the app's "ID addition" step writes here
create table profiles (
  id            uuid primary key references auth.users on delete cascade,
  company_id    uuid not null references companies on delete cascade,
  full_name     text not null,
  email         text not null,
  employee_id   text,
  role          app_role not null default 'operator',
  authority     approval_authority not null default 'none',
  is_external   boolean not null default false,
  status        user_status not null default 'pending',
  supplier_id   uuid,                                   -- set for role = 'supplier'
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  unique (company_id, employee_id)
);

-- access scope: which units a profile may see (role assignment step)
create table profile_units (
  profile_id uuid not null references profiles on delete cascade,
  unit_id    uuid not null references units on delete cascade,
  granted_by uuid references profiles,
  granted_at timestamptz not null default now(),
  primary key (profile_id, unit_id)
);

-- auditors work across companies: one row per engagement
create table auditor_engagements (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references profiles on delete cascade,
  company_id   uuid not null references companies on delete cascade,
  scheme       text,                                    -- ISO 14064-3 limited / reasonable
  valid_from   date not null default current_date,
  valid_to     date,
  unique (profile_id, company_id, valid_from)
);

create table invites (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  email       text not null,
  role        app_role not null,
  unit_id     uuid references units,
  all_units   boolean not null default false,
  token       text not null unique default encode(gen_random_bytes(24),'hex'),
  invited_by  uuid references profiles,
  sent_at     timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz
);

-- ---------- platform controls ----------
create table role_permissions (
  company_id uuid not null references companies on delete cascade,
  role       app_role not null,
  capability text not null,                             -- enter, import, submit, approve, boundary, ...
  allowed    boolean not null default false,
  primary key (company_id, role, capability)
);

create table module_locks (
  company_id uuid not null references companies on delete cascade,
  module     text not null,                             -- decarb, certifications, esg
  locked     boolean not null default true,
  locked_by  uuid references profiles,
  locked_at  timestamptz not null default now(),
  primary key (company_id, module)
);

create table data_controls (
  company_id uuid not null references companies on delete cascade,
  key        text not null,                             -- edit_window_days, mfa_required, ...
  value      jsonb not null,
  primary key (company_id, key)
);

create table reporting_periods (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies on delete cascade,
  fy         text not null,
  month      date not null,                             -- first day of the month
  state      period_state not null default 'future',
  locked_by  uuid references profiles,
  locked_at  timestamptz,
  unique (company_id, month)
);

-- ---------- emission factors ----------
create table factor_versions (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies on delete cascade,
  version    text not null,
  source     text,
  status     factor_status not null default 'draft',
  authored_by uuid references profiles,
  published_by uuid references profiles,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (company_id, version)
);

create table emission_factors (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references factor_versions on delete cascade,
  activity_key text not null,                           -- coal_kiln, grid_electricity, ...
  scope       smallint not null check (scope in (1,2,3)),
  ghg_category text,
  uom         text not null,
  value       numeric(18,6) not null,
  unit        text not null default 'tCO2e/unit',
  source_ref  text,
  unique (version_id, activity_key)
);

-- ---------- suppliers ----------
create table suppliers (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  name        text not null,
  category    text,
  country     text,
  tier        smallint default 1,
  is_top80    boolean not null default false,
  created_at  timestamptz not null default now()
);

alter table profiles
  add constraint profiles_supplier_fk foreign key (supplier_id) references suppliers on delete set null;

-- ---------- activity data ----------
create table submissions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies on delete cascade,
  unit_id      uuid references units on delete cascade,
  supplier_id  uuid references suppliers on delete cascade,   -- supplier submissions
  period_id    uuid not null references reporting_periods on delete restrict,
  status       submission_status not null default 'draft',
  prepared_by  uuid references profiles,
  submitted_at timestamptz,
  total_tco2e  numeric(18,3) not null default 0,
  created_at   timestamptz not null default now(),
  check (unit_id is not null or supplier_id is not null)
);

create table activity_data (
  id            uuid primary key default gen_random_uuid(),
  submission_id uuid not null references submissions on delete cascade,
  activity_key  text not null,
  description   text,
  scope         smallint not null check (scope in (1,2,3)),
  ghg_category  text,
  quantity      numeric(18,4) not null,
  uom           text not null,
  factor_id     uuid references emission_factors,
  tco2e         numeric(18,4) not null default 0,
  source        text,                                   -- manual, erp, magic_scan, api
  created_by    uuid references profiles,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table evidence (
  id            uuid primary key default gen_random_uuid(),
  activity_id   uuid references activity_data on delete cascade,
  submission_id uuid references submissions on delete cascade,
  storage_path  text not null,                          -- supabase storage object path
  file_name     text not null,
  mime_type     text,
  bytes         bigint,
  uploaded_by   uuid references profiles,
  uploaded_at   timestamptz not null default now()
);

-- ---------- approvals ----------
create table approval_chains (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies on delete cascade,
  name       text not null,
  applies_to text not null default 'unit'               -- unit | supplier | assurance
);

create table approval_steps (
  id         uuid primary key default gen_random_uuid(),
  chain_id   uuid not null references approval_chains on delete cascade,
  step_no    smallint not null,
  approver_id uuid references profiles,
  approver_role app_role,
  trigger_above_tco2e numeric(18,3),
  unique (chain_id, step_no)
);

create table approvals (
  id            uuid primary key default gen_random_uuid(),
  submission_id uuid not null references submissions on delete cascade,
  step_no       smallint not null,
  actor_id      uuid references profiles,
  decision      text not null check (decision in ('approved','returned','forwarded','verified')),
  comment       text,
  decided_at    timestamptz not null default now()
);

-- ---------- data requests (Pending Requests screen) ----------
create table data_requests (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies on delete cascade,
  unit_id      uuid references units,
  supplier_id  uuid references suppliers,
  period_id    uuid references reporting_periods,
  scope        smallint check (scope in (1,2,3)),
  subject      text not null,
  status       request_status not null default 'open',
  raised_by    uuid references profiles,
  assigned_to  uuid references profiles,
  due_on       date,
  created_at   timestamptz not null default now(),
  closed_at    timestamptz
);

create table request_comments (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references data_requests on delete cascade,
  author_id  uuid references profiles,
  body       text not null,
  created_at timestamptz not null default now()
);

-- ---------- audit trail ----------
create table audit_log (
  id          bigserial primary key,
  company_id  uuid not null references companies on delete cascade,
  event       audit_event not null,
  unit_id     uuid references units,
  object_type text,
  object_id   uuid,
  actor_id    uuid references profiles,
  actor_role  app_role,
  detail      text,
  before      jsonb,
  after       jsonb,
  record_hash text,
  occurred_at timestamptz not null default now()
);

-- ---------- indexes ----------
create index on profiles (company_id, role);
create index on profile_units (unit_id);
create index on submissions (company_id, period_id, status);
create index on activity_data (submission_id);
create index on audit_log (company_id, occurred_at desc);
create index on data_requests (company_id, status);
create index on evidence (submission_id);

-- ---------- triggers ----------
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger activity_data_touch before update on activity_data
  for each row execute function touch_updated_at();

-- recalculate tCO2e whenever quantity or factor changes
create or replace function calc_tco2e() returns trigger language plpgsql as $$
declare f numeric;
begin
  if new.factor_id is null then
    new.tco2e = 0;
  else
    select value into f from emission_factors where id = new.factor_id;
    new.tco2e = round(new.quantity * coalesce(f, 0), 4);
  end if;
  return new;
end $$;

create trigger activity_data_calc before insert or update of quantity, factor_id on activity_data
  for each row execute function calc_tco2e();

-- block writes into a locked period
create or replace function enforce_period_lock() returns trigger language plpgsql as $$
declare st period_state; sid uuid;
begin
  sid := case when tg_op = 'DELETE' then old.submission_id else new.submission_id end;
  select p.state into st
    from submissions s join reporting_periods p on p.id = s.period_id
   where s.id = sid;
  if st = 'locked' then
    raise exception 'Reporting period is locked by the platform admin';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger activity_data_period_lock before insert or update or delete on activity_data
  for each row execute function enforce_period_lock();

-- append-only audit log
create or replace function audit_log_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit_log is append-only'; end $$;

create trigger audit_log_no_update before update or delete on audit_log
  for each row execute function audit_log_immutable();
