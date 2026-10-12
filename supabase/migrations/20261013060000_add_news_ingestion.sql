-- Macro and market news with vendor sentiment, stored in the existing market.news_events table. Articles are keyed by URL and never overwritten.
-- Point in time: published_at is the vendor's publication time and created_at is when the platform first saw the article; a test must use the later of the two.
create unique index if not exists news_events_url_key on market.news_events (url) where url is not null;
create index if not exists news_events_published_at_idx on market.news_events (published_at desc);
create index if not exists news_events_source_id_idx on market.news_events (source_id);

insert into core.data_sources(name, provider_type, base_url, active, metadata)
select 'GDELT', 'news', 'https://api.gdeltproject.org', true, '{"use": "english headlines on central banks, rates, inflation, currencies and gold", "has_sentiment": false, "key": "none"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'GDELT');
insert into core.data_sources(name, provider_type, base_url, active, metadata)
select 'Central bank press feeds', 'official_public', null, true, '{"use": "official press and policy feeds of the eight central banks", "has_sentiment": false, "key": "none"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Central bank press feeds');
-- Alpha Vantage NEWS_SENTIMENT is a premium endpoint (refused on the saved key), so it is not used.

create or replace function public.news_upsert_rows(p_rows jsonb, p_source text)
returns integer language plpgsql security definer set search_path to '' as $function$
declare src uuid; n integer;
begin
  select id into src from core.data_sources where name = p_source and active;
  if src is null then raise exception 'news source not registered'; end if;
  with ins as (
    insert into market.news_events(source_id, published_at, title, body, url, language, sentiment_score, relevance_score, entities, raw_payload)
    select src, x.published_at, x.title, x.summary, x.url, coalesce(x.language, 'en'), x.sentiment_score, null,
           coalesce(x.tickers, '[]'::jsonb), jsonb_build_object('source', x.source, 'sentiment_label', x.sentiment_label, 'topics', coalesce(x.topics, '[]'::jsonb), 'vendor', p_source)
    from jsonb_to_recordset(p_rows) as x(url text, title text, summary text, published_at timestamptz, source text, language text, sentiment_score numeric, sentiment_label text, topics jsonb, tickers jsonb)
    where x.published_at <= now() + interval '1 hour' -- scheduled events (holidays, conferences) are not news that was published
    on conflict (url) where url is not null do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $function$;
revoke all on function public.news_upsert_rows(jsonb, text) from public, anon, authenticated;
grant execute on function public.news_upsert_rows(jsonb, text) to service_role;

create or replace function public.get_news(p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(),
    'total', (select count(*) from market.news_events where published_at <= now()),
    'last_published', (select max(published_at) from market.news_events where published_at <= now()),
    'last_ingested', (select max(created_at) from market.news_events),
    'overall_24h', (select jsonb_build_object('articles', count(*), 'avg_sentiment', round(avg(sentiment_score), 4)) from market.news_events where published_at >= now() - interval '24 hours' and published_at <= now()),
    'by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', c.ccy, 'articles_24h', c.n24, 'sentiment_24h', c.s24, 'articles_7d', c.n7, 'sentiment_7d', c.s7) order by c.n7 desc) from (
        select substr(t.tk, 7) ccy,
          count(*) filter (where t.published_at >= now() - interval '24 hours') n24,
          round(sum(t.s * t.r) filter (where t.published_at >= now() - interval '24 hours') / nullif(sum(t.r) filter (where t.published_at >= now() - interval '24 hours'), 0), 4) s24,
          count(*) n7, round(sum(t.s * t.r) / nullif(sum(t.r), 0), 4) s7
        from (select e ->> 'ticker' tk, (e ->> 'sentiment')::numeric s, (e ->> 'relevance')::numeric r, n.published_at
              from market.news_events n, jsonb_array_elements(n.entities) e
              where n.published_at >= now() - interval '7 days' and n.published_at <= now() and e ->> 'ticker' like 'FOREX:%' and (e ->> 'relevance')::numeric >= 0.3) t
        group by 1) c), '[]'::jsonb),
    'articles', coalesce((select jsonb_agg(a order by a.published_at desc) from (
        select n.published_at, n.title, n.url, n.sentiment_score, n.raw_payload ->> 'source' source, n.raw_payload ->> 'vendor' vendor,
               (select coalesce(jsonb_agg(substr(e ->> 'ticker', 7)), '[]'::jsonb) from jsonb_array_elements(n.entities) e where e ->> 'ticker' like 'FOREX:%' and (e ->> 'relevance')::numeric >= 0.3) currencies
        from market.news_events n where n.published_at <= now() order by n.published_at desc limit least(greatest(p_limit, 1), 200)) a), '[]'::jsonb));
end $function$;
revoke all on function public.get_news(integer) from public, anon;
grant execute on function public.get_news(integer) to authenticated;

-- Official central-bank press feeds every two hours, 05:12-21:12 UTC. GDELT is throttled (HTTP 429) from the shared Edge Function address, so it is not scheduled.
select cron.schedule('news-central-banks-refresh', '12 5-21/2 * * *', $job$
  select net.http_post(
    url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/news-ingestion',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := '{"dry_run": false, "source": "central_banks"}'::jsonb,
    timeout_milliseconds := 60000);
$job$);

-- Eight future-dated Bank of Canada calendar rows were stored before the guard existed; they are excluded from every read. Deleting them is an owner task: delete from market.news_events where published_at > now();
