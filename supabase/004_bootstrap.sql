-- ============================================================
-- 004_bootstrap.sql — first-run bootstrap
-- Problem 002 creates: every policy is scoped to the caller's
-- company, so the FIRST company and the FIRST platform admin can
-- never be inserted by a normal signed-in user. This RPC is the
-- only security-definer escape hatch: a signed-in user with no
-- profile may create one organisation and become its platform admin.
-- ============================================================

create or replace function bootstrap_company(
  p_code   text,
  p_name   text,
  p_cin    text default null,
  p_sector text default null,
  p_address text default null,
  p_fy     text default 'FY 2025-26',
  p_base_year text default null,
  p_consolidation text default 'operational_control',
  p_email_domain text default null,
  p_admin_name text default null
) returns companies
language plpgsql security definer set search_path = public as $$
declare co companies;
begin
  if auth.uid() is null then
    raise exception 'Sign in before creating an organisation';
  end if;
  if exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'This account already belongs to an organisation';
  end if;

  insert into companies (code, name, cin, sector, registered_address, reporting_fy, base_year, consolidation, email_domain)
  values (p_code, p_name, p_cin, p_sector, p_address, p_fy, p_base_year, p_consolidation, p_email_domain)
  returning * into co;

  insert into profiles (id, company_id, full_name, email, employee_id, role, status, is_external)
  values (auth.uid(), co.id,
          coalesce(p_admin_name, split_part(auth.email(), '@', 1)),
          auth.email(), 'ARL-0001', 'platform', 'active', false);

  -- default capability matrix
  insert into role_permissions (company_id, role, capability, allowed)
  select co.id, v.role::app_role, v.cap, true from (values
    ('operator','enter'),('supplier','enter'),
    ('operator','import'),('gsh','import'),('supplier','import'),
    ('operator','submit'),('supplier','submit'),
    ('gsh','editsub'),('gsh','approve'),
    ('gsh','boundary'),('platform','boundary'),
    ('gsh','factors'),('gsh','forward'),('auditor','opinion'),
    ('gsh','report'),('auditor','report'),('gsh','esg'),
    ('gsh','evidence'),('auditor','evidence'),
    ('operator','trail'),('gsh','trail'),('auditor','trail'),('platform','trail'),
    ('platform','users'),('platform','perms'),('platform','scope'),('platform','locks'),('platform','publish')
  ) as v(role,cap)
  on conflict do nothing;

  insert into module_locks (company_id, module, locked)
  select co.id, m, true from unnest(array['decarb','certifications','esg']) m
  on conflict do nothing;

  insert into data_controls (company_id, key, value)
  select co.id, k, v::jsonb from (values
    ('edit_window_days','5'),('retro_edit_requires_signoff','true'),
    ('evidence_mandatory','true'),('autolock_on_assurance','true'),
    ('supplier_resubmission_after_approval','false'),('mfa_required','true')
  ) as t(k,v)
  on conflict do nothing;

  -- twelve monthly periods for the stated FY, current month open
  insert into reporting_periods (company_id, fy, month, state)
  select co.id, p_fy, m::date,
         case when m::date < date_trunc('month', current_date) then 'locked'
              when m::date = date_trunc('month', current_date) then 'open'
              else 'future' end::period_state
  from generate_series(date_trunc('year', current_date) + interval '3 months',
                       date_trunc('year', current_date) + interval '14 months',
                       interval '1 month') m
  on conflict do nothing;

  insert into audit_log (company_id, event, object_type, object_id, actor_id, actor_role, detail)
  values (co.id, 'access_change', 'company', co.id, auth.uid(), 'platform',
          'Organisation created · platform admin provisioned');

  return co;
end $$;

revoke all on function bootstrap_company(text,text,text,text,text,text,text,text,text,text) from public;
grant execute on function bootstrap_company(text,text,text,text,text,text,text,text,text,text) to authenticated;

-- convenience: the signed-in user's own profile + company, one round trip
create or replace function me()
returns table (profile_id uuid, full_name text, email text, role app_role,
               company_id uuid, company_code text, company_name text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.email, p.role, c.id, c.code, c.name
    from profiles p join companies c on c.id = p.company_id
   where p.id = auth.uid()
$$;

grant execute on function me() to authenticated;
