-- Scheduled FOMC statement dates from federalreserve.gov (calendar page and per-year historical pages), for event studies.
-- Scheduled meetings are announced long in advance, so a rule may use the date before the event without look-ahead.
create table if not exists macro.fomc_meetings (
  statement_date date primary key,
  label text not null,
  source_url text not null,
  retrieved_at timestamptz not null default now()
);
alter table macro.fomc_meetings enable row level security;
revoke all on macro.fomc_meetings from public, anon, authenticated;
comment on table macro.fomc_meetings is 'Scheduled FOMC meetings only: statement release day (last day of the meeting). Unscheduled meetings, conference calls, notation votes and the cancelled March 2020 meeting are excluded.';
