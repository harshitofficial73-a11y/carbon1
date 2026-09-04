-- ============================================================
-- 005_provisioning.sql — platform admin provisioning helpers
-- The client can never read auth.users, so creating a profile for
-- an invited account needs a security-definer lookup by email.
-- Every function here is callable only by the platform admin of
-- the caller's own company.
-- ============================================================

create or replace function require_platform() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from profiles where id = auth.uid() and role = 'platform';
  if c is null then raise exception 'Platform admin role required'; end if;
  return c;
end $$;

-- add a cluster + its units in one call: acCluster('N1','Cluster N1 · …', array['beawar:Beawar', …])
create or replace function upsert_structure(p_cluster_code text, p_cluster_name text, p_units text[])
returns int language plpgsql security definer set search_path = public as $$
declare c uuid; cl uuid; u text; n int := 0;
begin
  c := require_platform();
  insert into clusters (company_id, code, name) values (c, p_cluster_code, p_cluster_name)
    on conflict (company_id, code) do update set name = excluded.name
    returning id into cl;
  if cl is null then select id into cl from clusters where company_id = c and code = p_cluster_code; end if;
  foreach u in array coalesce(p_units, '{}') loop
    insert into units (company_id, cluster_id, code, name)
    values (c, cl, split_part(u, ':', 1), split_part(u, ':', 2))
    on conflict (company_id, code) do update set name = excluded.name, cluster_id = excluded.cluster_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- create the profile for an existing auth account and scope it to units
create or replace function provision_profile(
  p_email       text,
  p_role        app_role,
  p_full_name   text default null,
  p_employee_id text default null,
  p_authority   approval_authority default 'none',
  p_is_external boolean default false,
  p_unit_codes  text[] default null      -- null = all units of the company
) returns profiles
language plpgsql security definer set search_path = public as $$
declare c uuid; uid uuid; pr profiles;
begin
  c := require_platform();
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then
    raise exception 'No auth account for %. Create the user first (dashboard or sign-up).', p_email;
  end if;

  insert into profiles (id, company_id, full_name, email, employee_id, role, authority, is_external, status)
  values (uid, c, coalesce(p_full_name, split_part(p_email,'@',1)), p_email, p_employee_id,
          p_role, p_authority, p_is_external, 'active')
  on conflict (id) do update set company_id = excluded.company_id, full_name = excluded.full_name,
        employee_id = excluded.employee_id, role = excluded.role, authority = excluded.authority,
        is_external = excluded.is_external, status = 'active'
  returning * into pr;

  delete from profile_units where profile_id = uid;
  insert into profile_units (profile_id, unit_id, granted_by)
  select uid, u.id, auth.uid() from units u
   where u.company_id = c
     and (p_unit_codes is null or u.code = any(p_unit_codes));

  insert into audit_log (company_id, event, actor_id, actor_role, object_type, object_id, detail)
  values (c, 'access_change', auth.uid(), 'platform', 'profile', uid,
          'Profile provisioned · ' || p_email || ' · role ' || p_role);

  return pr;
end $$;

-- auditors read across companies
create or replace function grant_engagement(p_email text, p_scheme text default 'ISO 14064-3 limited')
returns auditor_engagements language plpgsql security definer set search_path = public as $$
declare c uuid; uid uuid; e auditor_engagements;
begin
  c := require_platform();
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then raise exception 'No auth account for %', p_email; end if;
  insert into auditor_engagements (profile_id, company_id, scheme)
  values (uid, c, p_scheme)
  on conflict do nothing
  returning * into e;
  if e is null then select * into e from auditor_engagements where profile_id = uid and company_id = c limit 1; end if;
  return e;
end $$;

revoke all on function require_platform() from public;
grant execute on function upsert_structure(text,text,text[]) to authenticated;
grant execute on function provision_profile(text,app_role,text,text,approval_authority,boolean,text[]) to authenticated;
grant execute on function grant_engagement(text,text) to authenticated;
