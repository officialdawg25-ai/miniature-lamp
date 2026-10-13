-- News provenance: publisher, content fingerprint, first/last seen, change versions, cross-URL duplicates and item kind.
-- The original row (title, body, published_at, created_at = first seen) is never overwritten: if a feed later serves the same URL
-- with different text, the new text is stored as a version in market.news_item_versions, so what was knowable at any time is preserved.
alter table market.news_events add column if not exists publisher text;
alter table market.news_events add column if not exists content_fingerprint text;
alter table market.news_events add column if not exists title_fingerprint text;
alter table market.news_events add column if not exists last_seen_at timestamptz;
alter table market.news_events add column if not exists seen_count integer not null default 1;
alter table market.news_events add column if not exists duplicate_of uuid references market.news_events(id);
alter table market.news_events add column if not exists item_kind text;
alter table market.news_events add column if not exists reliability text;
comment on column market.news_events.item_kind is 'Deterministic title rule (see market.news_item_kind); a heuristic label, not an interpretation.';
comment on column market.news_events.duplicate_of is 'Earliest item at another URL with the same normalized title and text within 7 days; duplicates are not independent evidence. Same title alone is not enough (recurring titles such as speech headers).';

create table if not exists market.news_item_versions (
  id uuid primary key default gen_random_uuid(),
  news_id uuid not null references market.news_events(id),
  content_fingerprint text not null,
  title text not null,
  body text,
  seen_at timestamptz not null default now(),
  unique (news_id, content_fingerprint)
);
alter table market.news_item_versions enable row level security;
revoke all on market.news_item_versions from public, anon, authenticated;
grant select, insert on market.news_item_versions to service_role;

create or replace function market.news_norm(t text) returns text language sql immutable set search_path to '' as
$$ select btrim(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', ' ', 'g')) $$;

-- Rule-based item kind for official central-bank feeds. Order matters; the first match wins.
create or replace function market.news_item_kind(p_title text) returns text language sql immutable set search_path to '' as $$
  select case
    when t ~ '(interest rate announcement|monetary policy decision|policy rate|bank rate|cash rate|official cash rate|monetary policy statement|rate decision)' then 'policy_decision'
    when t ~ '(minutes|summary of deliberations|account of the monetary policy|accounts)' then 'minutes_or_account'
    when t ~ '(speech|remarks|testimony|lecture|keynote|address by|interview)' then 'speech_or_testimony'
    when t ~ '(monetary policy report|financial stability|outlook report|economic bulletin|projections|inflation report)' then 'report_or_projection'
    when t ~ '(christmas|boxing day|new year|holiday|remembrance day|good friday|easter|thanksgiving|bank holiday)' then 'scheduled_closure'
    when t ~ '(conference|workshop|seminar|symposium|call for papers)' then 'event_announcement'
    when t ~ '(survey|release|statistics|data|publication)' then 'data_or_publication'
    else 'other' end
  from (select market.news_norm(p_title) t) x
$$;

create or replace function public.news_upsert_rows(p_rows jsonb, p_source text)
returns integer language plpgsql security definer set search_path to '' as $function$
declare src uuid; n integer;
begin
  select id into src from core.data_sources where name = p_source and active;
  if src is null then raise exception 'news source not registered'; end if;
  create temp table if not exists _news_in on commit drop as
    select x.url, x.title, x.summary, x.published_at, x.source, coalesce(x.language, 'en') language, x.sentiment_score, x.sentiment_label, x.topics, x.tickers,
           encode(sha256(convert_to(market.news_norm(x.title) || '|' || market.news_norm(x.summary), 'UTF8')), 'hex') fp,
           encode(sha256(convert_to(market.news_norm(x.title), 'UTF8')), 'hex') tfp
    from jsonb_to_recordset(p_rows) as x(url text, title text, summary text, published_at timestamptz, source text, language text, sentiment_score numeric, sentiment_label text, topics jsonb, tickers jsonb)
    where x.url is not null and x.published_at <= now() + interval '1 hour'; -- scheduled events (holidays, conferences) are not news that was published
  -- Already known URL: record the sighting; if the text changed, keep the new text as a version (original row untouched).
  update market.news_events e set last_seen_at = now(), seen_count = e.seen_count + 1 from pg_temp._news_in i where e.url = i.url;
  insert into market.news_item_versions(news_id, content_fingerprint, title, body)
    select e.id, i.fp, i.title, i.summary from pg_temp._news_in i join market.news_events e on e.url = i.url
    where e.content_fingerprint is not null and e.content_fingerprint <> i.fp
    on conflict (news_id, content_fingerprint) do nothing;
  with ins as (
    insert into market.news_events(source_id, published_at, title, body, url, language, sentiment_score, relevance_score, entities, raw_payload,
                                   publisher, content_fingerprint, title_fingerprint, last_seen_at, item_kind, reliability, duplicate_of)
    select src, i.published_at, i.title, i.summary, i.url, i.language, i.sentiment_score, null, coalesce(i.tickers, '[]'::jsonb),
           jsonb_build_object('source', i.source, 'sentiment_label', i.sentiment_label, 'topics', coalesce(i.topics, '[]'::jsonb), 'vendor', p_source),
           i.source, i.fp, i.tfp, now(), market.news_item_kind(i.title),
           case when p_source = 'Central bank press feeds' then 'official_primary' else 'secondary' end,
           (select d.id from market.news_events d where d.content_fingerprint = i.fp and d.duplicate_of is null
              and d.published_at between i.published_at - interval '7 days' and i.published_at + interval '7 days' order by d.published_at limit 1)
    from pg_temp._news_in i
    on conflict (url) where url is not null do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $function$;
revoke all on function public.news_upsert_rows(jsonb, text) from public, anon, authenticated;
grant execute on function public.news_upsert_rows(jsonb, text) to service_role;

-- Fill the new columns for rows stored before this migration (derived from their own stored text; nothing re-fetched).
update market.news_events set publisher = coalesce(publisher, raw_payload ->> 'source'),
  content_fingerprint = coalesce(content_fingerprint, encode(sha256(convert_to(market.news_norm(title) || '|' || market.news_norm(body), 'UTF8')), 'hex')),
  title_fingerprint = coalesce(title_fingerprint, encode(sha256(convert_to(market.news_norm(title), 'UTF8')), 'hex')),
  last_seen_at = coalesce(last_seen_at, created_at), item_kind = coalesce(item_kind, market.news_item_kind(title)),
  reliability = coalesce(reliability, case when (raw_payload ->> 'vendor') = 'Central bank press feeds' then 'official_primary' else 'secondary' end)
where content_fingerprint is null;
