-- Read-only snapshot for the central-bank page: derived decision history, deterministic FOMC statement changes and the language-model
-- news analyses. Interpretation is returned with its verification counts and labelled as interpretation; nothing here feeds decisions.
create or replace function public.get_central_bank_intelligence()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
begin
  if (select auth.uid()) is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    'decisions', (select coalesce(jsonb_agg(jsonb_build_object('bank', b.code, 'name', b.name, 'recent', r.recent, 'counts', r.counts) order by b.code), '[]'::jsonb)
      from macro.central_banks b
      cross join lateral (select
          (select coalesce(jsonb_agg(jsonb_build_object('date', coalesce(d.meeting_date, d.decision_time::date), 'type', d.decision_type, 'from', d.previous_rate, 'to', d.new_rate)
                                     order by coalesce(d.meeting_date, d.decision_time::date) desc), '[]'::jsonb)
             from (select * from macro.policy_decisions d where d.central_bank_id = b.id and d.decision_type <> 'superseded'
                   order by coalesce(d.meeting_date, d.decision_time::date) desc limit 6) d) recent,
          (select jsonb_object_agg(t, n) from (select d.decision_type t, count(*) n from macro.policy_decisions d
             where d.central_bank_id = b.id and d.decision_type <> 'superseded' group by 1) c) counts) r
      where b.active and exists (select 1 from macro.policy_decisions d where d.central_bank_id = b.id)),
    'fomc_changes', (select coalesce(jsonb_agg(jsonb_build_object('date', c.doc_date, 'previous', c.prev_doc_date, 'similarity', c.jaccard,
          'added', c.added, 'removed', c.removed, 'policy_sentence', c.policy_sentence, 'dissent', c.dissent_recorded, 'url', s.url) order by c.doc_date desc), '[]'::jsonb)
      from (select * from macro.fomc_statement_changes_current order by doc_date desc limit 4) c join macro.fomc_statements s on s.doc_date = c.doc_date),
    'fomc_statements_stored', (select count(*) from macro.fomc_statements),
    'analyses', (select coalesce(jsonb_agg(jsonb_build_object('title', n.title, 'url', n.url, 'publisher', n.publisher, 'published_at', n.published_at,
          'importance', a.importance, 'evidence', a.evidence_sufficiency, 'input_basis', a.input_basis, 'summary', a.output->>'summary',
          'interpretation', a.output->'interpretation'->>'text', 'policy_signals', a.output->'policy_signals',
          'verified', a.verification->'counts'->'verified', 'unverified', a.verification->'counts'->'unverified', 'model', a.model, 'prompt_version', a.prompt_version)
          order by n.published_at desc), '[]'::jsonb)
      from (select * from intelligence.news_analyses where status = 'completed' order by created_at desc limit 15) a join market.news_events n on n.id = a.news_id),
    'analysis_counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from intelligence.news_analyses group by 1) s));
end $function$;
revoke all on function public.get_central_bank_intelligence() from public, anon;
grant execute on function public.get_central_bank_intelligence() to authenticated;
