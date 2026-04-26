-- operator_calculator_sessions
-- Stores every slider interaction from the for-operators.html calculator.
-- session_id is a UUID generated in localStorage — same visitor across multiple adjustments
-- gets multiple rows, giving a full picture of how they navigated the numbers.
-- marketing_leads rows are linked via calculator_session_id.

create table if not exists operator_calculator_sessions (
  id                    uuid primary key default gen_random_uuid(),
  session_id            text not null,
  trucks                integer not null,
  extra_jobs_per_day    numeric(3,1) not null,
  avg_job_value         integer not null,
  working_days          integer not null,
  calculated_monthly_net integer not null,
  calculated_annual_net  integer not null,
  referrer              text,
  created_at            timestamptz default now()
);

create index on operator_calculator_sessions (session_id);
create index on operator_calculator_sessions (created_at desc);

-- Link calculator sessions to apply submissions
alter table marketing_leads
  add column if not exists calculator_session_id  text,
  add column if not exists calc_trucks            integer,
  add column if not exists calc_extra_jobs_per_day numeric(3,1),
  add column if not exists calc_avg_job_value     integer,
  add column if not exists calc_working_days      integer,
  add column if not exists calc_monthly_net       integer;

create index if not exists marketing_leads_calc_session_idx
  on marketing_leads (calculator_session_id);

-- RLS: allow anon inserts from the marketing site
alter table operator_calculator_sessions enable row level security;

create policy "anon insert calculator sessions"
  on operator_calculator_sessions for insert
  to anon with check (true);

create policy "service role full access calculator"
  on operator_calculator_sessions for all
  to service_role using (true);
