-- Marketing leads from the RIN website apply form
create table if not exists marketing_leads (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid,
  company_name   text not null,
  contact_name   text not null,
  phone          text not null,
  truck_count    text,
  inquiry_type   text,
  message        text,
  referrer       text,
  page           text,
  status         text default 'new',   -- new | contacted | qualified | rejected
  notes          text,
  created_at     timestamptz default now()
);

-- UI activity events from the marketing site
create table if not exists ui_events (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid,
  event_type   text not null,   -- page_view | section_view | section_leave | cta_click | scroll_depth | form_start | form_submit | form_success | form_error | page_exit
  event_data   jsonb default '{}',
  page         text,
  referrer     text,
  user_agent   text,
  created_at   timestamptz default now()
);

-- Indexes for analytics queries
create index if not exists ui_events_session_idx   on ui_events (session_id);
create index if not exists ui_events_type_idx      on ui_events (event_type);
create index if not exists ui_events_created_idx   on ui_events (created_at desc);
create index if not exists leads_status_idx        on marketing_leads (status);
create index if not exists leads_created_idx       on marketing_leads (created_at desc);

-- RLS: allow anonymous inserts from the website, no reads
alter table marketing_leads enable row level security;
alter table ui_events       enable row level security;

create policy "anon insert leads"  on marketing_leads for insert to anon with check (true);
create policy "anon insert events" on ui_events       for insert to anon with check (true);

-- Service role can read everything (for edge functions + dashboard)
create policy "service read leads"  on marketing_leads for select to service_role using (true);
create policy "service read events" on ui_events       for select to service_role using (true);
create policy "service update leads" on marketing_leads for update to service_role using (true);
