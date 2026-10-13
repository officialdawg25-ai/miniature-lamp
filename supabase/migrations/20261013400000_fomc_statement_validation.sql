-- FOMC statement validation. The "a" press release on a statement date is usually the statement but not always: on 2008-12-16 it
-- is a Term Auction Facility result. Stored rows are not changed; instead a deterministic check decides what counts as a statement,
-- the reader view only exposes rows that pass it, new non-statement pages are stored under their own doc_type, and dates without a
-- valid statement are retried with the next URL suffix (b, c, d) until one passes or all four have been tried.
create or replace function macro.is_fomc_statement(p_body text) returns boolean language sql immutable set search_path to '' as $$
  select coalesce(left(p_body, 200) ilike '%FOMC statement%'
                  or (p_body ilike '%Federal Open Market Committee%' and p_body ilike '%federal funds rate%'), false)
$$;

-- One row per statement date: the newest extraction of a page that passes the check (v1 and v2 rows of one page share the URL).
create or replace view macro.fomc_statements with (security_invoker = true) as
select distinct on (d.doc_date) d.id, d.doc_date, d.url, d.available_at, d.fetched_at, d.content_fingerprint, d.body,
       coalesce((d.metadata->>'extraction_version')::int, 1) as extraction_version
from macro.central_bank_documents d
where d.bank_code = 'FED' and d.doc_type = 'fomc_statement' and macro.is_fomc_statement(d.body)
order by d.doc_date, coalesce((d.metadata->>'extraction_version')::int, 1) desc, d.fetched_at desc;
revoke all on macro.fomc_statements from public, anon, authenticated;
grant select on macro.fomc_statements to service_role;

create or replace function macro.request_fomc_statements(p_limit integer default 20)
returns integer language plpgsql security definer set search_path to '' as $function$
declare m record; n integer := 0; u text; sfx text;
begin
  for m in select f.statement_date from macro.fomc_meetings f
           where f.statement_date < current_date
             and not exists (select 1 from macro.central_bank_documents d where d.bank_code = 'FED' and d.doc_type = 'fomc_statement'
                             and d.doc_date = f.statement_date and macro.is_fomc_statement(d.body))
             and not exists (select 1 from macro.document_fetches q where q.doc_type = 'fomc_statement' and q.doc_date = f.statement_date and q.collected_at is null)
           order by f.statement_date desc limit least(greatest(p_limit, 1), 40) loop
    select s into sfx from unnest(array['a', 'b', 'c', 'd']) s
     where not exists (select 1 from macro.document_fetches q where q.doc_type = 'fomc_statement' and q.doc_date = m.statement_date
                       and q.url = 'https://www.federalreserve.gov/newsevents/pressreleases/monetary' || to_char(m.statement_date, 'YYYYMMDD') || s || '.htm')
     order by s limit 1;
    continue when sfx is null;  -- all suffixes tried: the date stays without a statement rather than guessing further
    u := 'https://www.federalreserve.gov/newsevents/pressreleases/monetary' || to_char(m.statement_date, 'YYYYMMDD') || sfx || '.htm';
    insert into macro.document_fetches(request_id, bank_code, doc_type, doc_date, url)
      values (net.http_get(u, timeout_milliseconds := 30000), 'FED', 'fomc_statement', m.statement_date, u);
    n := n + 1;
  end loop;
  return n;
end $function$;
revoke all on function macro.request_fomc_statements(integer) from public, anon, authenticated;

create or replace function macro.collect_document_fetches_v2(p_reextract boolean)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare q record; r record; txt text; ok boolean; stored integer := 0; other integer := 0; failed integer := 0;
begin
  for q in select * from macro.document_fetches where (collected_at is null) or (p_reextract and outcome = 'stored') loop
    select status_code, content into r from net._http_response where id = q.request_id;
    if not found then
      if q.collected_at is null and q.requested_at < now() - interval '2 hours' then update macro.document_fetches set collected_at = now(), outcome = 'response_expired' where request_id = q.request_id; failed := failed + 1; end if;
      continue;
    end if;
    txt := case when r.status_code = 200 then macro.extract_fed_article(r.content) end;
    if txt is null or length(txt) < 200 then
      if q.collected_at is null then update macro.document_fetches set collected_at = now(), outcome = 'http_' || coalesce(r.status_code::text, 'error') || case when r.status_code = 200 then '_no_article' else '' end where request_id = q.request_id; end if;
      failed := failed + 1; continue;
    end if;
    ok := q.doc_type <> 'fomc_statement' or macro.is_fomc_statement(txt);
    insert into macro.central_bank_documents(bank_code, doc_type, doc_date, url, available_at, content_fingerprint, body, metadata)
      values (q.bank_code, case when ok then q.doc_type else 'fed_press_release_other' end, q.doc_date, q.url, (q.doc_date + time '14:00') at time zone 'America/New_York',
              encode(sha256(convert_to(txt, 'UTF8')), 'hex'), txt,
              jsonb_build_object('source', 'federalreserve.gov press release', 'extraction_version', 2, 'statement_check', ok,
                                 'extraction', 'article container to page footer; comments, markup and media footer removed', 'html_length', length(r.content),
                                 'availability_precision', 'scheduled release time; approximate for 2011-2013 press-conference days'))
      on conflict (url, content_fingerprint) do nothing;
    if q.collected_at is null then update macro.document_fetches set collected_at = now(), outcome = case when ok then 'stored' else 'stored_not_statement' end where request_id = q.request_id; end if;
    if ok then stored := stored + 1; else other := other + 1; end if;
  end loop;
  return jsonb_build_object('stored', stored, 'not_statement', other, 'failed', failed);
end $function$;
revoke all on function macro.collect_document_fetches_v2(boolean) from public, anon, authenticated;
