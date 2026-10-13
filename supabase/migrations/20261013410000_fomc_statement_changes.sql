-- Deterministic statement-to-statement comparison of FOMC statements (no language model). Each validated statement is split into
-- normalised sentences (header, date line and the list of voting members removed; a member's initial does not end a sentence) and compared with the previous validated statement: sentences added and
-- removed, Jaccard similarity of the sentence sets, the policy-rate sentence and whether a dissent is recorded. Rows are keyed by
-- both content fingerprints and the method version, so a re-extracted page or a new method adds rows and never rewrites old ones.
-- available_at is the later statement's release time: nothing here is known before that statement is public.
create table if not exists macro.fomc_statement_changes (
  id uuid primary key default gen_random_uuid(),
  doc_date date not null,
  prev_doc_date date,
  available_at timestamptz not null,
  doc_fingerprint text not null,
  prev_fingerprint text,
  method_version integer not null,
  sentences integer not null,
  sentences_added integer not null,
  sentences_removed integer not null,
  jaccard numeric,
  added text[] not null,
  removed text[] not null,
  policy_sentence text,
  dissent_recorded boolean not null,
  created_at timestamptz not null default now(),
  unique nulls not distinct (doc_fingerprint, prev_fingerprint, method_version)
);
alter table macro.fomc_statement_changes enable row level security;
revoke all on macro.fomc_statement_changes from public, anon, authenticated;
grant select on macro.fomc_statement_changes to service_role;

create or replace function macro.statement_sentences(p_body text) returns text[] language sql immutable set search_path to '' as $$
  select coalesce(array_agg(distinct s order by s), '{}')
  from (select btrim(lower(regexp_replace(x, '\s+', ' ', 'g'))) s
        from regexp_split_to_table(
               regexp_replace(regexp_replace(replace(replace(p_body, '–', '-'), '—', '-'),
                              '^.*?(For immediate release|For release at .{1,20}?(EST|EDT|ET)\M)\s*', '', 'i'),
                              '\s*Voting for .*$', '', 'i'),
               '(?<=[a-z0-9)%]{2}[.;:])\s+(?=[A-Z])') x) t
  where length(s) > 3
$$;

create or replace function macro.refresh_fomc_statement_changes() returns integer language plpgsql security definer set search_path to '' as $function$
declare n integer;
begin
  with s as (
    select doc_date, available_at, content_fingerprint fp, body, macro.statement_sentences(body) sent,
           lag(doc_date) over w prev_date, lag(content_fingerprint) over w prev_fp, lag(macro.statement_sentences(body)) over w prev_sent
    from macro.fomc_statements window w as (order by doc_date)
  )
  insert into macro.fomc_statement_changes(doc_date, prev_doc_date, available_at, doc_fingerprint, prev_fingerprint, method_version, sentences,
                                           sentences_added, sentences_removed, jaccard, added, removed, policy_sentence, dissent_recorded)
  select s.doc_date, s.prev_date, s.available_at, s.fp, s.prev_fp, 1, cardinality(s.sent),
         cardinality(a.added), cardinality(r.removed),
         case when s.prev_sent is null then null else round(
           (select count(*) from unnest(s.sent) x where x = any(s.prev_sent))::numeric
           / nullif((select count(*) from (select unnest(s.sent) union select unnest(s.prev_sent)) u), 0), 4) end,
         a.added, r.removed,
         (select x from unnest(s.sent) x where x like '%federal funds rate%' and x like '%target%' order by (x ~ '(decided|decision)') desc, length(x) limit 1),
         s.body ~* 'voting against' or replace(s.body, '–', '-') ~ 'by an? \d+\s*-\s*[1-9]\d*\s+vote'
  from s
  cross join lateral (select coalesce(array_agg(x order by x), '{}') added from unnest(s.sent) x where s.prev_sent is not null and not x = any(s.prev_sent)) a
  cross join lateral (select coalesce(array_agg(x order by x), '{}') removed from unnest(coalesce(s.prev_sent, '{}')) x where not x = any(s.sent)) r
  on conflict (doc_fingerprint, prev_fingerprint, method_version) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;
revoke all on function macro.refresh_fomc_statement_changes() from public, anon, authenticated;

select macro.refresh_fomc_statement_changes();
select cron.schedule('fomc-statement-changes', '55 20 * * 1-5', $job$ select macro.refresh_fomc_statement_changes(); $job$);
