-- Method 2 of the statement comparison: normalise typography before splitting (31 statements use non-breaking hyphens and 19 use
-- curly apostrophes, which made an unchanged sentence look changed when the Fed's web formatting changed). Method 1 rows are kept;
-- the view macro.fomc_statement_changes_current exposes the newest method only.
create or replace function macro.statement_sentences_v2(p_body text) returns text[] language sql immutable set search_path to '' as $$
  select macro.statement_sentences(translate(p_body, '‑‐–—’‘“”' || chr(160), '----''''"" '))
$$;

create or replace function macro.refresh_fomc_statement_changes() returns integer language plpgsql security definer set search_path to '' as $function$
declare n integer;
begin
  with s as (
    select doc_date, available_at, content_fingerprint fp, body, macro.statement_sentences_v2(body) sent,
           lag(doc_date) over w prev_date, lag(content_fingerprint) over w prev_fp, lag(macro.statement_sentences_v2(body)) over w prev_sent
    from macro.fomc_statements window w as (order by doc_date)
  )
  insert into macro.fomc_statement_changes(doc_date, prev_doc_date, available_at, doc_fingerprint, prev_fingerprint, method_version, sentences,
                                           sentences_added, sentences_removed, jaccard, added, removed, policy_sentence, dissent_recorded)
  select s.doc_date, s.prev_date, s.available_at, s.fp, s.prev_fp, 2, cardinality(s.sent),
         cardinality(a.added), cardinality(r.removed),
         case when s.prev_sent is null then null else round(
           (select count(*) from unnest(s.sent) x where x = any(s.prev_sent))::numeric
           / nullif((select count(*) from (select unnest(s.sent) union select unnest(s.prev_sent)) u), 0), 4) end,
         a.added, r.removed,
         (select x from unnest(s.sent) x where x like '%federal funds rate%' and x like '%target%' order by (x ~ '(decided|decision)') desc, length(x) limit 1),
         s.body ~* 'voting against' or translate(s.body, '‑–—', '---') ~ 'by an? \d+\s*-\s*[1-9]\d*\s+vote'
  from s
  cross join lateral (select coalesce(array_agg(x order by x), '{}') added from unnest(s.sent) x where s.prev_sent is not null and not x = any(s.prev_sent)) a
  cross join lateral (select coalesce(array_agg(x order by x), '{}') removed from unnest(coalesce(s.prev_sent, '{}')) x where not x = any(s.sent)) r
  on conflict (doc_fingerprint, prev_fingerprint, method_version) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;
revoke all on function macro.refresh_fomc_statement_changes() from public, anon, authenticated;

create or replace view macro.fomc_statement_changes_current with (security_invoker = true) as
select c.* from macro.fomc_statement_changes c
where c.method_version = (select max(method_version) from macro.fomc_statement_changes);
revoke all on macro.fomc_statement_changes_current from public, anon, authenticated;
grant select on macro.fomc_statement_changes_current to service_role;

select macro.refresh_fomc_statement_changes();
