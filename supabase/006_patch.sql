-- ============================================================
-- 006_patch.sql — fixes found during end-to-end testing
-- ============================================================

-- 1. units were readable by every member of the company, so an operator
--    scoped to one plant could still list all of them. Structure reads now
--    follow the same scope rule as data reads.
drop policy if exists unit_read on units;
create policy unit_read on units for select using (
  case
    when auth_role() in ('gsh','platform','auditor') then can_read_company(company_id)
    else exists (select 1 from profile_units pu where pu.profile_id = auth.uid() and pu.unit_id = units.id)
  end
);

-- 2. same for clusters: only clusters that contain a visible unit
drop policy if exists cluster_read on clusters;
create policy cluster_read on clusters for select using (
  case
    when auth_role() in ('gsh','platform','auditor') then can_read_company(company_id)
    else exists (select 1 from units u join profile_units pu on pu.unit_id = u.id
                  where u.cluster_id = clusters.id and pu.profile_id = auth.uid())
  end
);
