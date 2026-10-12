-- Read model for the research ledger page: every hypothesis with its frozen specification, status history and stored runs (summary and checks, not the trade lists).
create or replace function public.get_research_ledger()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(), 'hypotheses', coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', h.key, 'title', h.title, 'rationale', h.rationale, 'instruments', h.instruments, 'horizon', h.horizon, 'status', h.status,
      'status_changed_at', h.status_changed_at, 'registered_at', h.created_at, 'specification', h.specification,
      'history', coalesce((select jsonb_agg(jsonb_build_object('to', s.to_status, 'reason', s.reason, 'at', s.changed_at) order by s.changed_at) from intelligence.hypothesis_status_history s where s.hypothesis_id = h.id), '[]'::jsonb),
      'runs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'at', r.created_at, 'code_version', r.code_version, 'symbol', r.symbol, 'data', r.data_summary,
          'passed', coalesce(r.result -> 'passed', r.result -> 'verdict' -> 'passed'),
          'checks', coalesce(r.result -> 'checks', r.result -> 'verdict' -> 'checks'),
          'headline', jsonb_build_object('trades', coalesce(r.result -> 'base' -> 'n', r.result -> 'days'), 'mean_net', r.result -> 'base' -> 'mean', 'unit', r.result -> 'unit',
            'sharpe', r.result -> 'metrics' -> 'sharpe', 'p', coalesce(r.result -> 'base' -> 'p_one_sided', r.result -> 'p_value'), 'ci', r.result -> 'base' -> 'boot_ci_95'))
        order by r.created_at desc) from intelligence.backtest_runs r where r.hypothesis_id = h.id), '[]'::jsonb)
    ) order by h.created_at desc) from intelligence.research_hypotheses h), '[]'::jsonb));
end $function$;
revoke all on function public.get_research_ledger() from public, anon;
grant execute on function public.get_research_ledger() to authenticated;
