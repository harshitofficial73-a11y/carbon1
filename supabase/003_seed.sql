-- ============================================================
-- 003_seed.sql — reference data matching the prototype
-- Run after 001 and 002. Safe to re-run (idempotent inserts).
-- ============================================================

insert into companies (code, name, cin, sector, registered_address, reporting_fy, base_year, consolidation, email_domain)
values ('ARL-CO-001','A Refractories Ltd.','L26933MH1972PLC016581','Refractories & industrial minerals',
        'Prism House, Mumbai 400013, Maharashtra, India','FY 2025-26','FY 2019-20','operational_control','arefractories.com')
on conflict (code) do nothing;

with c as (select id from companies where code = 'ARL-CO-001')
insert into clusters (company_id, code, name, region)
select c.id, v.code, v.name, v.region from c,
(values ('N1','Cluster N1 · Rajasthan / Punjab','North'),
        ('N2','Cluster N2 · Central Plains','North'),
        ('S1','Cluster S1 · Southern Deccan','South'),
        ('E1','Cluster E1 · Eastern Coastal','East')) as v(code,name,region)
on conflict do nothing;

with c as (select id from companies where code = 'ARL-CO-001')
insert into units (company_id, cluster_id, code, name)
select c.id, cl.id, v.code, v.name
from c
join (values ('beawar','Beawar','N1'),('chittorgarh','Chittorgarh','N1'),('bhatinda','Bhatinda','N1'),
             ('satna','Satna','N2'),('wanakbori','Wanakbori','N2'),
             ('tadipatri','Tadipatri','S1'),('ariyalur','Ariyalur','S1'),('kalaburagi','Kalaburagi','S1'),
             ('rajgangpur','Rajgangpur','E1'),('durgapur','Durgapur','E1')) as v(code,name,cluster) on true
join clusters cl on cl.company_id = c.id and cl.code = v.cluster
on conflict do nothing;

-- capability matrix defaults (mirrors the Admin Console permission grid)
with c as (select id from companies where code = 'ARL-CO-001')
insert into role_permissions (company_id, role, capability, allowed)
select c.id, v.role::app_role, v.cap, true from c,
(values ('operator','enter'),('supplier','enter'),
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

with c as (select id from companies where code = 'ARL-CO-001')
insert into module_locks (company_id, module, locked)
select c.id, m, true from c, unnest(array['decarb','certifications','esg']) m
on conflict do nothing;

with c as (select id from companies where code = 'ARL-CO-001')
insert into data_controls (company_id, key, value)
select c.id, k, v::jsonb from c,
(values ('edit_window_days','5'),
        ('retro_edit_requires_signoff','true'),
        ('evidence_mandatory','true'),
        ('autolock_on_assurance','true'),
        ('supplier_resubmission_after_approval','false'),
        ('mfa_required','true')) as t(k,v)
on conflict do nothing;

-- FY 2025-26 monthly periods: Apr–Jul locked, Aug open, rest future
with c as (select id from companies where code = 'ARL-CO-001'),
     m as (select generate_series(date '2025-04-01', date '2026-03-01', interval '1 month')::date as month)
insert into reporting_periods (company_id, fy, month, state)
select c.id, 'FY 2025-26', m.month,
       case when m.month < date '2025-08-01' then 'locked'
            when m.month = date '2025-08-01' then 'open'
            else 'future' end::period_state
from c, m
on conflict do nothing;

with c as (select id from companies where code = 'ARL-CO-001')
insert into factor_versions (company_id, version, source, status)
select c.id, v.version, v.source, v.status::factor_status from c,
(values ('v4.0','CEA 2023 · IPCC AR5','archived'),
        ('v4.1','CEA CO2 Baseline Database 2024 · IPCC AR6','archived'),
        ('v4.2','CEA CO2 Baseline Database 2025 · IPCC AR6','published'),
        ('v4.3-draft','CEA 2026 provisional · DEFRA 2026','draft')) as v(version,source,status)
on conflict do nothing;

with v as (select id from factor_versions where version = 'v4.2')
insert into emission_factors (version_id, activity_key, scope, uom, value, source_ref)
select v.id, f.key, f.scope, f.uom, f.val, f.src from v,
(values ('coal_kiln',1,'t',2.402,'IPCC AR6 · sub-bituminous'),
        ('petcoke_calciner',1,'t',3.240,'IPCC AR6'),
        ('diesel_mobile',1,'kL',2.660,'IPCC AR6'),
        ('furnace_oil',1,'kL',3.150,'IPCC AR6'),
        ('clinker_process',1,'t clinker',0.529,'CSI protocol'),
        ('grid_electricity',2,'MWh',0.708,'CEA 2026 provisional'),
        ('purchased_steam',2,'GJ',0.051,'DEFRA 2026'),
        ('freight_rail',3,'kt-km',0.413,'GLEC v3')) as f(key,scope,uom,val,src)
on conflict do nothing;

with c as (select id from companies where code = 'ARL-CO-001')
insert into suppliers (company_id, name, category, country, is_top80)
select c.id, s.name, s.cat, s.country, s.top80 from c,
(values ('NTPC Talcher','Purchased electricity','India',true),
        ('Hindalco Renukoot','Bauxite / alumina','India',true),
        ('Orient Cement','Cement & binders','India',false),
        ('Gulf Magnesia FZE','Magnesia (imported)','UAE',true),
        ('Sri Balaji Logistics','Upstream transport','India',false),
        ('Tata Steel Jamshedpur','Steel scrap / alloys','India',true)) as s(name,cat,country,top80)
on conflict do nothing;
