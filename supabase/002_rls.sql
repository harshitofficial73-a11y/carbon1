-- ============================================================
-- 002_rls.sql — row level security
-- Model: everything is scoped to a company.
--   platform : full control of accounts, structure and controls, no data writes
--   gsh      : all units of its company, approves and reports
--   operator : only units granted in profile_units, only its own drafts
--   supplier : only its own supplier submissions
--   auditor  : read-only, only companies it has an active engagement with
-- ============================================================

-- ---------- helpers ----------
create or replace function auth_profile() returns profiles
language sql stable security definer set search_path = public as $$
  select * from profiles where id = auth.uid()
$$;

create or replace function auth_company() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from profiles where id = auth.uid()
$$;

create or replace function auth_role() returns app_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function is_platform() returns boolean
language sql stable as $$ select auth_role() = 'platform' $$;

create or replace function can_read_company(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    c = auth_company()
    or exists (
      select 1 from auditor_engagements e
       where e.profile_id = auth.uid()
         and e.company_id = c
         and current_date >= e.valid_from
         and (e.valid_to is null or current_date <= e.valid_to)
    )
$$;

create or replace function unit_in_scope(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when auth_role() in ('gsh','platform') then exists (select 1 from units where id = u and company_id = auth_company())
    when auth_role() = 'auditor' then exists (select 1 from units x where x.id = u and can_read_company(x.company_id))
    else exists (select 1 from profile_units pu where pu.profile_id = auth.uid() and pu.unit_id = u)
  end
$$;

create or replace function has_capability(cap text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select allowed from role_permissions
      where company_id = auth_company() and role = auth_role() and capability = cap), false)
$$;

-- ---------- enable ----------
alter table companies            enable row level security;
alter table clusters             enable row level security;
alter table units                enable row level security;
alter table profiles             enable row level security;
alter table profile_units        enable row level security;
alter table auditor_engagements  enable row level security;
alter table invites              enable row level security;
alter table role_permissions     enable row level security;
alter table module_locks         enable row level security;
alter table data_controls        enable row level security;
alter table reporting_periods    enable row level security;
alter table factor_versions      enable row level security;
alter table emission_factors     enable row level security;
alter table suppliers            enable row level security;
alter table submissions          enable row level security;
alter table activity_data        enable row level security;
alter table evidence             enable row level security;
alter table approval_chains      enable row level security;
alter table approval_steps       enable row level security;
alter table approvals            enable row level security;
alter table data_requests        enable row level security;
alter table request_comments     enable row level security;
alter table audit_log            enable row level security;

-- ---------- company / structure ----------
create policy company_read on companies for select using (can_read_company(id));
create policy company_write on companies for all
  using (is_platform() and id = auth_company()) with check (is_platform() and id = auth_company());

create policy cluster_read on clusters for select using (can_read_company(company_id));
create policy cluster_write on clusters for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy unit_read on units for select using (can_read_company(company_id));
create policy unit_write on units for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

-- ---------- identity ----------
create policy profile_self on profiles for select using (id = auth.uid());
create policy profile_read on profiles for select
  using (can_read_company(company_id) and auth_role() in ('gsh','auditor','platform'));
create policy profile_write on profiles for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy scope_read on profile_units for select
  using (profile_id = auth.uid()
         or exists (select 1 from profiles p where p.id = profile_id and can_read_company(p.company_id)
                    and auth_role() in ('gsh','auditor','platform')));
create policy scope_write on profile_units for all
  using (is_platform()) with check (is_platform());

create policy engagement_read on auditor_engagements for select
  using (profile_id = auth.uid() or (is_platform() and company_id = auth_company()));
create policy engagement_write on auditor_engagements for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy invite_rw on invites for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

-- ---------- platform controls ----------
create policy perms_read on role_permissions for select using (can_read_company(company_id));
create policy perms_write on role_permissions for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy locks_read on module_locks for select using (can_read_company(company_id));
create policy locks_write on module_locks for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy controls_read on data_controls for select using (can_read_company(company_id));
create policy controls_write on data_controls for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy period_read on reporting_periods for select using (can_read_company(company_id));
create policy period_write on reporting_periods for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

-- ---------- factors ----------
create policy fv_read on factor_versions for select using (can_read_company(company_id));
create policy fv_author on factor_versions for all
  using (company_id = auth_company() and has_capability('factors'))
  with check (company_id = auth_company() and has_capability('factors'));
create policy fv_publish on factor_versions for update
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());

create policy ef_read on emission_factors for select
  using (exists (select 1 from factor_versions v where v.id = version_id and can_read_company(v.company_id)));
create policy ef_write on emission_factors for all
  using (exists (select 1 from factor_versions v where v.id = version_id and v.company_id = auth_company())
         and has_capability('factors'))
  with check (exists (select 1 from factor_versions v where v.id = version_id and v.company_id = auth_company())
         and has_capability('factors'));

-- ---------- suppliers ----------
create policy supplier_read on suppliers for select
  using (can_read_company(company_id)
         and (auth_role() <> 'supplier' or id = (select supplier_id from profiles where id = auth.uid())));
create policy supplier_write on suppliers for all
  using (company_id = auth_company() and auth_role() in ('gsh','platform'))
  with check (company_id = auth_company() and auth_role() in ('gsh','platform'));

-- ---------- submissions & activity data ----------
create policy sub_read on submissions for select using (
  can_read_company(company_id) and (
    auth_role() in ('gsh','auditor','platform')
    or (auth_role() = 'supplier' and supplier_id = (select supplier_id from profiles where id = auth.uid()))
    or (auth_role() = 'operator' and unit_in_scope(unit_id))
  ));
create policy sub_insert on submissions for insert with check (
  company_id = auth_company() and has_capability('submit') and (
    (auth_role() = 'operator' and unit_in_scope(unit_id))
    or (auth_role() = 'supplier' and supplier_id = (select supplier_id from profiles where id = auth.uid()))
  ));
create policy sub_update_preparer on submissions for update using (
    prepared_by = auth.uid() and status in ('draft','returned')
  ) with check (prepared_by = auth.uid());
create policy sub_update_reviewer on submissions for update using (
    company_id = auth_company() and has_capability('approve')
  ) with check (company_id = auth_company());

create policy act_read on activity_data for select
  using (exists (select 1 from submissions s where s.id = submission_id
                 and (can_read_company(s.company_id))
                 and (auth_role() in ('gsh','auditor','platform')
                      or (auth_role() = 'supplier' and s.supplier_id = (select supplier_id from profiles where id = auth.uid()))
                      or (auth_role() = 'operator' and unit_in_scope(s.unit_id)))));
create policy act_write on activity_data for all
  using (exists (select 1 from submissions s where s.id = submission_id
                 and s.prepared_by = auth.uid() and s.status in ('draft','returned'))
         and has_capability('enter'))
  with check (exists (select 1 from submissions s where s.id = submission_id
                 and s.prepared_by = auth.uid() and s.status in ('draft','returned'))
         and has_capability('enter'));

create policy evidence_read on evidence for select
  using (exists (select 1 from submissions s where s.id = evidence.submission_id and can_read_company(s.company_id))
         or exists (select 1 from activity_data a
                    join submissions s on s.id = a.submission_id
                    where a.id = evidence.activity_id and can_read_company(s.company_id)));
create policy evidence_write on evidence for insert
  with check (uploaded_by = auth.uid() and has_capability('enter'));

-- ---------- approvals ----------
create policy chain_read on approval_chains for select using (can_read_company(company_id));
create policy chain_write on approval_chains for all
  using (is_platform() and company_id = auth_company()) with check (is_platform() and company_id = auth_company());
create policy step_read on approval_steps for select
  using (exists (select 1 from approval_chains c where c.id = chain_id and can_read_company(c.company_id)));
create policy step_write on approval_steps for all
  using (is_platform()) with check (is_platform());

create policy approval_read on approvals for select
  using (exists (select 1 from submissions s where s.id = submission_id and can_read_company(s.company_id)));
create policy approval_insert on approvals for insert
  with check (actor_id = auth.uid()
              and (has_capability('approve') or (auth_role() = 'auditor' and has_capability('opinion'))));

-- ---------- data requests ----------
create policy req_read on data_requests for select
  using (can_read_company(company_id)
         and (auth_role() in ('gsh','auditor','platform')
              or assigned_to = auth.uid() or raised_by = auth.uid()
              or (unit_id is not null and unit_in_scope(unit_id))));
create policy req_write on data_requests for all
  using (company_id = auth_company() and auth_role() in ('gsh','platform'))
  with check (company_id = auth_company() and auth_role() in ('gsh','platform'));
create policy req_respond on data_requests for update
  using (assigned_to = auth.uid()) with check (assigned_to = auth.uid());

create policy comment_read on request_comments for select
  using (exists (select 1 from data_requests r where r.id = request_id and can_read_company(r.company_id)));
create policy comment_write on request_comments for insert with check (author_id = auth.uid());

-- ---------- audit log ----------
create policy audit_read on audit_log for select
  using (can_read_company(company_id) and (auth_role() in ('gsh','auditor','platform') or actor_id = auth.uid()));
create policy audit_insert on audit_log for insert
  with check (company_id = auth_company() and actor_id = auth.uid());
