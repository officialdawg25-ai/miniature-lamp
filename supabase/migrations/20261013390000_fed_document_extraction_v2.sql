-- Extraction v2 for federalreserve.gov press releases: remove HTML comments, decode numeric entities and drop the media-inquiry
-- footer. Each stored row records its extraction_version; v1 rows (first 20 statements) are kept and v2 rows are added next to
-- them, because a new fingerprint from a new extractor is not a change to the published page. Readers use the highest version.
create or replace function macro.extract_fed_article(p_html text) returns text language plpgsql immutable set search_path to '' as $function$
declare a integer; b integer; t text;
begin
  a := position('id="article"' in coalesce(p_html, ''));
  if a = 0 then return null; end if;
  b := position('Last Update' in p_html);
  t := substring(p_html from a for case when b > a then b - a else 20000 end);
  t := substring(t from position('>' in t) + 1);
  t := regexp_replace(t, '<!--.*?-->', ' ', 'g');
  t := regexp_replace(t, '<(script|style)[^>]*>.*?</(script|style)>', ' ', 'gi');
  t := regexp_replace(t, '<[^>]+>', ' ', 'g');
  t := replace(replace(replace(replace(replace(replace(replace(t, '&nbsp;', ' '), '&#160;', ' '), '&amp;', '&'), '&#39;', ''''), '&quot;', '"'), '&ndash;', '-'), '&mdash;', '-');
  t := regexp_replace(t, '-->', ' ', 'g');
  t := regexp_replace(t, 'For media inquiries.*$', '', 'i');
  t := regexp_replace(t, '\s+Share\s+', ' ', 'i');
  return btrim(regexp_replace(t, '\s+', ' ', 'g'));
end $function$;

create or replace function macro.collect_document_fetches_v2(p_reextract boolean)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare q record; r record; txt text; stored integer := 0; failed integer := 0;
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
    insert into macro.central_bank_documents(bank_code, doc_type, doc_date, url, available_at, content_fingerprint, body, metadata)
      values (q.bank_code, q.doc_type, q.doc_date, q.url, (q.doc_date + time '14:00') at time zone 'America/New_York',
              encode(sha256(convert_to(txt, 'UTF8')), 'hex'), txt,
              jsonb_build_object('source', 'federalreserve.gov press release', 'extraction_version', 2,
                                 'extraction', 'article container to page footer; comments, markup and media footer removed', 'html_length', length(r.content),
                                 'availability_precision', 'scheduled release time; approximate for 2011-2013 press-conference days'))
      on conflict (url, content_fingerprint) do nothing;
    if q.collected_at is null then update macro.document_fetches set collected_at = now(), outcome = 'stored' where request_id = q.request_id; end if;
    stored := stored + 1;
  end loop;
  return jsonb_build_object('stored', stored, 'failed', failed);
end $function$;
revoke all on function macro.collect_document_fetches_v2(boolean) from public, anon, authenticated;
-- The scheduled job keeps calling the original name; it now delegates to v2 (no overload, so the call stays unambiguous).
create or replace function macro.collect_document_fetches()
returns jsonb language sql security definer set search_path to '' as $$ select macro.collect_document_fetches_v2(false) $$;
revoke all on function macro.collect_document_fetches() from public, anon, authenticated;
