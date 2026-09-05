-- ============================================================
-- 007_defra_schema.sql — provenance columns for imported factor sets
-- Run this, then the factor rows load through the app / REST.
-- Source of the data: UK Government GHG Conversion Factors for
-- Company Reporting 2024, full set (advanced users) v1.1 — DESNZ/DEFRA.
-- ============================================================

alter table emission_factors add column if not exists category        text;
alter table emission_factors add column if not exists activity        text;
alter table emission_factors add column if not exists sub_activity    text;
alter table emission_factors add column if not exists qualifier       text;
alter table emission_factors add column if not exists internal_key    text;
alter table emission_factors add column if not exists value_co2       numeric(20,10);
alter table emission_factors add column if not exists value_ch4       numeric(20,10);
alter table emission_factors add column if not exists value_n2o       numeric(20,10);
alter table emission_factors add column if not exists reference       text;
alter table emission_factors add column if not exists publisher       text;
alter table emission_factors add column if not exists dataset_year    int;
alter table emission_factors add column if not exists dataset_version text;

alter table emission_factors alter column value type numeric(20,10);
alter table emission_factors alter column activity_key type text;

create index if not exists emission_factors_internal_key_idx on emission_factors (internal_key);
create index if not exists emission_factors_category_idx on emission_factors (category, activity);

-- activity_data should record which factor set produced each line
alter table activity_data add column if not exists factor_reference text;
