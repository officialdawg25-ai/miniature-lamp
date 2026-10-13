-- Official central-bank documents (FOMC statements first), fetched from federalreserve.gov through pg_net and stored as plain text.
-- Versioned by content fingerprint: if a page later changes, the new text is a new row and the original stays, so what was public
-- at any time can be reconstructed. available_at is the scheduled release time (statements: 14:00 New York, approximate before 2013).
create table if not exists macro.central_bank_documents (
  id uuid primary key default gen_random_uuid(),
  bank_code text not null,
  doc_type text not null,
  doc_date date not null,
  url text not null,
  available_at timestamptz not null,
  fetched_at timestamptz not null default now(),
  content_fingerprint text not null,
  body text not null,
  metadata jsonb not null default '{}'::jsonb,
  unique (url, content_fingerprint)
);
alter table macro.central_bank_documents enable row level security;
revoke all on macro.central_bank_documents from public, anon, authenticated;
grant select, insert on macro.central_bank_documents to service_role;

create table if not exists macro.document_fetches (
  request_id bigint primary key,
  bank_code text not null,
  doc_type text not null,
  doc_date date not null,
  url text not null,
  requested_at timestamptz not null default now(),
  collected_at timestamptz,
  outcome text
);
alter table macro.document_fetches enable row level security;
revoke all on macro.document_fetches from public, anon, authenticated;

-- Queue up to p_limit FOMC statements (scheduled meetings already past) that are not stored yet and not already in flight.
create or replace function macro.request_fomc_statements(p_limit integer default 20)
returns integer language plpgsql security definer set search_path to '' as $function$
declare m record; n integer := 0; u text;
begin
  for m in select f.statement_date from macro.fomc_meetings f
           where f.statement_date < current_date
             and not exists (select 1 from macro.central_bank_documents d where d.bank_code = 'FED' and d.doc_type = 'fomc_statement' and d.doc_date = f.statement_date)
             and not exists (select 1 from macro.document_fetches q where q.doc_type = 'fomc_statement' and q.doc_date = f.statement_date and (q.collected_at is null or q.outcome = 'stored') and q.requested_at > now() - interval '1 day')
           order by f.statement_date desc limit least(greatest(p_limit, 1), 40) loop
    u := 'https://www.federalreserve.gov/newsevents/pressreleases/monetary' || to_char(m.statement_date, 'YYYYMMDD') || 'a.htm';
    insert into macro.document_fetches(request_id, bank_code, doc_type, doc_date, url)
      values (net.http_get(u, timeout_milliseconds := 30000), 'FED', 'fomc_statement', m.statement_date, u);
    n := n + 1;
  end loop;
  return n;
end $function$;

-- Collect finished responses: extract the article text (from the article container to the page footer), strip markup, store.
create or replace function macro.collect_document_fetches()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare q record; r record; txt text; a integer; b integer; stored integer := 0; failed integer := 0;
begin
  for q in select * from macro.document_fetches where collected_at is null loop
    select status_code, content, error_msg, timed_out into r from net._http_response where id = q.request_id;
    if not found then
      if q.requested_at < now() - interval '2 hours' then update macro.document_fetches set collected_at = now(), outcome = 'response_expired' where request_id = q.request_id; failed := failed + 1; end if;
      continue;
    end if;
    a := position('id="article"' in coalesce(r.content, ''));
    b := position('Last Update' in coalesce(r.content, ''));
    if r.status_code is distinct from 200 or a = 0 then
      update macro.document_fetches set collected_at = now(), outcome = 'http_' || coalesce(r.status_code::text, 'error') where request_id = q.request_id; failed := failed + 1; continue;
    end if;
    txt := substring(r.content from a for case when b > a then b - a else 20000 end);
    txt := regexp_replace(txt, '<(script|style)[^>]*>.*?</\1>', ' ', 'gi');
    txt := regexp_replace(txt, '<[^>]+>', ' ', 'g');
    txt := replace(replace(replace(replace(replace(txt, '&nbsp;', ' '), '&amp;', '&'), '&#39;', ''''), '&quot;', '"'), '&ndash;', '-');
    txt := btrim(regexp_replace(substring(txt from position('>' in txt) + 1), '\s+', ' ', 'g'));
    insert into macro.central_bank_documents(bank_code, doc_type, doc_date, url, available_at, content_fingerprint, body, metadata)
      values (q.bank_code, q.doc_type, q.doc_date, q.url, (q.doc_date + time '14:00') at time zone 'America/New_York',
              encode(sha256(convert_to(txt, 'UTF8')), 'hex'), txt,
              jsonb_build_object('source', 'federalreserve.gov press release', 'extraction', 'article container to page footer, markup stripped', 'html_length', length(r.content),
                                 'availability_precision', 'scheduled release time; approximate for 2011-2013 press-conference days'))
      on conflict (url, content_fingerprint) do nothing;
    update macro.document_fetches set collected_at = now(), outcome = 'stored' where request_id = q.request_id; stored := stored + 1;
  end loop;
  return jsonb_build_object('stored', stored, 'failed', failed);
end $function$;
revoke all on function macro.request_fomc_statements(integer) from public, anon, authenticated;
revoke all on function macro.collect_document_fetches() from public, anon, authenticated;

-- After each scheduled statement (and to finish the backfill in small batches): request at 20:30 UTC on weekdays, collect at 20:45.
select cron.schedule('fomc-statements-request', '30 20 * * 1-5', $job$ select macro.request_fomc_statements(10); $job$);
select cron.schedule('fomc-statements-collect', '45 20 * * 1-5', $job$ select macro.collect_document_fetches(); $job$);
