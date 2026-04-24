-- Outreach contacts: tracks who was contacted, which template, and pipeline status
create table if not exists outreach_contacts (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  company       text not null,
  title         text,
  email         text,
  phone         text,
  persona       text not null check (persona in ('ops_manager','dispatcher','finance','other')),
  -- which letter template was sent
  template      text check (template in ('ops_manager','dispatcher','finance','follow_up','sms')),
  -- pipeline stage
  status        text not null default 'identified'
                check (status in ('identified','sent','replied','follow_up_sent','call_booked','qualified','closed_won','closed_lost','not_now')),
  -- key dates
  sent_at       timestamptz,
  replied_at    timestamptz,
  call_at       timestamptz,
  -- source of the lead
  source        text,   -- e.g. 'linkedin', 'referral', 'conference', 'manual'
  notes         text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- Indexes
create index if not exists outreach_status_idx   on outreach_contacts (status);
create index if not exists outreach_persona_idx  on outreach_contacts (persona);
create index if not exists outreach_created_idx  on outreach_contacts (created_at desc);

-- Auto-update updated_at
create or replace function set_outreach_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger outreach_updated_at
  before update on outreach_contacts
  for each row execute function set_outreach_updated_at();

-- RLS: only service role reads/writes (managed from dashboard or edge functions)
alter table outreach_contacts enable row level security;

create policy "service all outreach"
  on outreach_contacts for all
  to service_role using (true) with check (true);
