-- ─────────────────────────────────────────────────────────────────
-- 004_operator_knowledge.sql
-- Three tables:
--   1. claude_memory          — mirrors local .md memory files
--   2. operator_profiles      — one row per operator, builds over time
--   3. operator_interactions  — every touchpoint (calculator, apply, call, email)
--
-- Auto-create profiles:
--   • trigger on operator_calculator_sessions insert
--   • trigger on marketing_leads insert (inquiry_type = 'operator' or 'mto_operator')
-- ─────────────────────────────────────────────────────────────────

-- ── 1. claude_memory ─────────────────────────────────────────────
create table if not exists claude_memory (
  id           uuid primary key default gen_random_uuid(),
  file_name    text not null unique,   -- e.g. "project_rin_outreach_strategy.md"
  memory_name  text,
  description  text,
  type         text check (type in ('user','feedback','project','reference')),
  content      text,
  synced_at    timestamptz default now(),
  created_at   timestamptz default now()
);

create index if not exists claude_memory_type_idx on claude_memory (type);

alter table claude_memory enable row level security;
create policy "service role full access memory"
  on claude_memory for all to service_role using (true);

-- ── 2. operator_profiles ─────────────────────────────────────────
create table if not exists operator_profiles (
  id                        uuid primary key default gen_random_uuid(),

  -- Identity (filled from apply form or call)
  company_name              text,
  contact_name              text,
  phone                     text,
  email                     text,
  service_area              text,

  -- Fleet intel
  truck_count_range         text,     -- from apply: '1','2-5','6-15','16+'
  truck_count_actual        integer,  -- confirmed on qual call
  mto_certified             boolean,
  mto_zones                 text[],   -- e.g. ARRAY['1A','2B']

  -- Calculator intel (latest session snapshot)
  calc_session_id           text,   -- matches operator_calculator_sessions.session_id
  calc_trucks               integer,
  calc_extra_jobs_per_day   numeric(3,1),
  calc_avg_job_value        integer,
  calc_monthly_net_expected integer,

  -- Pipeline status
  lead_status               text not null default 'calculator_visitor',
  -- calculator_visitor → applied → contacted → qual_call_booked →
  -- qual_call_done → pilot_offered → pilot_active → churned | rejected

  -- Qualification answers (filled after discovery call)
  qual_dispatch_method      text,   -- 'phone_radio','motor_club','none','other'
  qual_overflow_handling    text,
  qual_payment_cycle_days   integer,
  qual_pain_score           smallint check (qual_pain_score between 1 and 5),

  -- Working notes
  call_notes                text,
  last_contact_at           timestamptz,
  next_action               text,
  next_action_date          date,

  -- Source
  source                    text,   -- 'calculator','mto_outreach','referral','inbound'
  marketing_lead_id         uuid references marketing_leads(id),
  referrer                  text,

  created_at                timestamptz default now(),
  updated_at                timestamptz default now()
);

create index if not exists op_profiles_status_idx  on operator_profiles (lead_status);
create index if not exists op_profiles_company_idx on operator_profiles (company_name);
create index if not exists op_profiles_phone_idx   on operator_profiles (phone);

alter table operator_profiles enable row level security;
create policy "service role full access profiles"
  on operator_profiles for all to service_role using (true);
create policy "anon insert profiles"
  on operator_profiles for insert to anon with check (true);

-- ── 3. operator_interactions ─────────────────────────────────────
create table if not exists operator_interactions (
  id               uuid primary key default gen_random_uuid(),
  operator_id      uuid references operator_profiles(id) on delete cascade,

  -- What happened
  interaction_type text not null,
  -- calculator | page_view | apply | email_sent | email_reply |
  -- call_outbound | call_inbound | sms_sent | sms_reply |
  -- calendly_booked | calendly_completed | pilot_started | note

  channel          text,   -- web | email | phone | sms | calendly
  summary          text,   -- short description
  notes            text,   -- full notes / transcript excerpt
  metadata         jsonb,  -- any extra structured data

  occurred_at      timestamptz default now(),
  created_at       timestamptz default now()
);

create index if not exists op_interactions_operator_idx on operator_interactions (operator_id);
create index if not exists op_interactions_type_idx     on operator_interactions (interaction_type);
create index if not exists op_interactions_time_idx     on operator_interactions (occurred_at desc);

alter table operator_interactions enable row level security;
create policy "service role full access interactions"
  on operator_interactions for all to service_role using (true);
create policy "anon insert interactions"
  on operator_interactions for insert to anon with check (true);

-- ── Auto-update updated_at ────────────────────────────────────────
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger operator_profiles_updated_at
  before update on operator_profiles
  for each row execute function update_updated_at();

-- ── Trigger: calculator session → create/update profile ──────────
create or replace function upsert_profile_from_calculator()
returns trigger language plpgsql security definer as $$
declare v_id uuid;
begin
  -- If a profile already exists with same session, update calc snapshot
  select id into v_id
    from operator_profiles
   where calc_session_id = new.session_id
   limit 1;

  if v_id is not null then
    update operator_profiles set
      calc_trucks               = new.trucks,
      calc_extra_jobs_per_day   = new.extra_jobs_per_day,
      calc_avg_job_value        = new.avg_job_value,
      calc_monthly_net_expected = new.calculated_monthly_net,
      updated_at                = now()
    where id = v_id;
  else
    insert into operator_profiles (
      calc_session_id, calc_trucks, calc_extra_jobs_per_day,
      calc_avg_job_value, calc_monthly_net_expected,
      lead_status, source, referrer
    ) values (
      new.session_id, new.trucks, new.extra_jobs_per_day,
      new.avg_job_value, new.calculated_monthly_net,
      'calculator_visitor', 'calculator', new.referrer
    )
    returning id into v_id;
  end if;

  -- Log the interaction
  insert into operator_interactions (operator_id, interaction_type, channel, summary, metadata)
  values (
    v_id, 'calculator', 'web',
    format('%s trucks × %s jobs/day @ $%s = $%s/mo',
           new.trucks, new.extra_jobs_per_day, new.avg_job_value, new.calculated_monthly_net),
    jsonb_build_object(
      'trucks', new.trucks,
      'extra_jobs_per_day', new.extra_jobs_per_day,
      'avg_job_value', new.avg_job_value,
      'monthly_net', new.calculated_monthly_net,
      'annual_net', new.calculated_annual_net
    )
  );

  return new;
end;
$$;

create trigger on_calculator_session_insert
  after insert on operator_calculator_sessions
  for each row execute function upsert_profile_from_calculator();

-- ── Trigger: marketing_leads apply → upgrade profile ─────────────
create or replace function upsert_profile_from_lead()
returns trigger language plpgsql security definer as $$
declare v_id uuid;
begin
  -- Only handle operator + MTO operator applications
  if new.inquiry_type not in ('operator','mto_operator') then
    return new;
  end if;

  -- Try to match existing profile by calc_session_id first, then phone
  select id into v_id
    from operator_profiles
   where calc_session_id = new.calculator_session_id
      or (phone = new.phone and new.phone is not null)
   limit 1;

  if v_id is not null then
    update operator_profiles set
      company_name      = coalesce(company_name, new.company_name),
      contact_name      = coalesce(contact_name, new.contact_name),
      phone             = coalesce(phone, new.phone),
      truck_count_range = coalesce(truck_count_range, new.truck_count),
      lead_status       = case when lead_status = 'calculator_visitor'
                               then 'applied' else lead_status end,
      marketing_lead_id = new.id,
      calc_trucks               = coalesce(calc_trucks, new.calc_trucks),
      calc_extra_jobs_per_day   = coalesce(calc_extra_jobs_per_day, new.calc_extra_jobs_per_day),
      calc_avg_job_value        = coalesce(calc_avg_job_value, new.calc_avg_job_value),
      calc_monthly_net_expected = coalesce(calc_monthly_net_expected, new.calc_monthly_net),
      updated_at        = now()
    where id = v_id;
  else
    insert into operator_profiles (
      company_name, contact_name, phone,
      truck_count_range, lead_status, source,
      marketing_lead_id, referrer,
      calc_session_id, calc_trucks, calc_extra_jobs_per_day,
      calc_avg_job_value, calc_monthly_net_expected
    ) values (
      new.company_name, new.contact_name, new.phone,
      new.truck_count, 'applied',
      case when new.inquiry_type = 'mto_operator' then 'mto_outreach' else 'calculator' end,
      new.id, new.referrer,
      new.calculator_session_id, new.calc_trucks, new.calc_extra_jobs_per_day,
      new.calc_avg_job_value, new.calc_monthly_net
    )
    returning id into v_id;
  end if;

  -- Log the apply interaction
  insert into operator_interactions (operator_id, interaction_type, channel, summary, metadata)
  values (
    v_id, 'apply', 'web',
    format('Applied: %s (%s)', new.company_name, new.truck_count),
    jsonb_build_object(
      'company', new.company_name,
      'contact', new.contact_name,
      'phone', new.phone,
      'trucks', new.truck_count,
      'calc_monthly_net', new.calc_monthly_net
    )
  );

  return new;
end;
$$;

create trigger on_marketing_lead_insert
  after insert on marketing_leads
  for each row execute function upsert_profile_from_lead();

