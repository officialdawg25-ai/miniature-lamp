-- Model-generated news interpretation, stored apart from source data and always labelled as interpretation.
-- One row per (news item, prompt version). The model never writes here directly: the news-intelligence function validates the
-- structured output, checks every quoted excerpt against the stored source text, and only then inserts. Nothing reads these rows
-- into risk checks, decisions or orders.
create table if not exists intelligence.news_analyses (
  id uuid primary key default gen_random_uuid(),
  news_id uuid not null references market.news_events(id),
  prompt_version text not null,
  model text not null,
  input_basis text not null check (input_basis in ('title_only', 'title_and_feed_summary', 'full_text')),
  input_fingerprint text not null,
  status text not null check (status in ('completed', 'declined', 'invalid_output', 'failed')),
  importance text,
  evidence_sufficiency text,
  output jsonb not null default '{}'::jsonb,
  verification jsonb not null default '{}'::jsonb,
  usage jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (news_id, prompt_version)
);
alter table intelligence.news_analyses enable row level security;
revoke all on intelligence.news_analyses from public, anon, authenticated;
grant select, insert on intelligence.news_analyses to service_role;
comment on table intelligence.news_analyses is 'Labelled model interpretation of official news items (facts only with verified verbatim excerpts). Interpretation, not evidence of a price effect; never consumed by trading decisions.';

-- Committee records are minutes; recompute the rule-based label for stored rows (derived label only, source text untouched).
create or replace function market.news_item_kind(p_title text) returns text language sql immutable set search_path to '' as $$
  select case
    when t ~ '(interest rate announcement|monetary policy decision|policy rate|bank rate|cash rate|official cash rate|monetary policy statement|rate decision)' then 'policy_decision'
    when t ~ '(minutes|summary of deliberations|account of the monetary policy|accounts|committee record|policy committee record)' then 'minutes_or_account'
    when t ~ '(speech|remarks|testimony|lecture|keynote|address by|interview)' then 'speech_or_testimony'
    when t ~ '(monetary policy report|financial stability|outlook report|economic bulletin|projections|inflation report)' then 'report_or_projection'
    when t ~ '(christmas|boxing day|new year|holiday|remembrance day|good friday|easter|thanksgiving|bank holiday)' then 'scheduled_closure'
    when t ~ '(conference|workshop|seminar|symposium|call for papers)' then 'event_announcement'
    when t ~ '(survey|release|statistics|data|publication)' then 'data_or_publication'
    else 'other' end
  from (select market.news_norm(p_title) t) x
$$;
update market.news_events set item_kind = market.news_item_kind(title) where item_kind is distinct from market.news_item_kind(title);
