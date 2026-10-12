-- trading.approve_paper_execution returned table(execution_request_id, status, broker_dispatch_state, approved_by). Inside the function,
-- the unqualified `status` and `broker_dispatch_state` in the UPDATE ... WHERE clause were ambiguous between those output parameters and the
-- table columns, so every call failed with "column reference status is ambiguous" and human approval could never succeed.
-- The tables were empty, so the path had never run. Found by supabase/tests/trading_risk_gate.sql. Same logic, with the table aliased.
create or replace function trading.approve_paper_execution(p_execution_request_id uuid)
returns table(execution_request_id uuid, status text, broker_dispatch_state text, approved_by uuid)
language plpgsql
security definer
set search_path to 'trading', 'public', 'pg_catalog', 'auth'
as $function$
declare
  v_user_id uuid := auth.uid();
  r trading.execution_requests%rowtype;
  a trading.accounts%rowtype;
  rd trading.risk_decisions%rowtype;
  v_role text;
  v_updated trading.execution_requests%rowtype;
begin
  if v_user_id is null then raise exception 'authenticated user required'; end if;

  select * into r from trading.execution_requests where id = p_execution_request_id for update;
  if not found then raise exception 'execution request not found'; end if;

  select * into a from trading.accounts where id = r.account_id;
  if not found then raise exception 'account not found'; end if;
  if not a.active then raise exception 'account execution circuit breaker is active'; end if;
  if a.execution_mode <> 'human_approval' then raise exception 'paper approval requires account execution_mode=human_approval'; end if;

  select am.role into v_role
  from trading.account_members am
  where am.account_id = r.account_id
    and am.user_id = v_user_id
    and am.active = true
    and am.role in ('owner','risk_manager');
  if v_role is null then raise exception 'approval authority denied'; end if;

  if r.broker_dispatch_state <> 'not_dispatched' then raise exception 'execution request is already dispatched or processed'; end if;
  if r.status <> 'manual_review' then raise exception 'only manual-review execution requests can be approved'; end if;
  if r.risk_decision_id is null then raise exception 'risk decision required before approval'; end if;

  select * into rd from trading.risk_decisions
  where id = r.risk_decision_id and account_id = r.account_id and setup_id = r.setup_id;
  if not found then raise exception 'risk decision not found or account/setup mismatch'; end if;
  if rd.decision = 'blocked' then raise exception 'blocked risk decision cannot be overridden by paper approval'; end if;
  if rd.execution_mode <> a.execution_mode then raise exception 'risk decision execution mode is stale'; end if;

  update trading.execution_requests er
  set status = 'authorized',
      metadata = er.metadata || jsonb_build_object(
        'paper_approval', jsonb_build_object(
          'approved_by', v_user_id,
          'approved_role', v_role,
          'approved_at', now(),
          'risk_decision_at_approval', rd.decision,
          'human_override', (rd.decision = 'manual_review')
        )
      )
  where er.id = r.id and er.status = 'manual_review' and er.broker_dispatch_state = 'not_dispatched'
  returning * into v_updated;
  if not found then raise exception 'approval race or request state changed'; end if;

  insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
  values (
    r.account_id, r.setup_id, 'paper_execution_approved',
    case when rd.decision = 'manual_review' then 'warning' else 'info' end,
    case when rd.decision = 'manual_review'
      then 'Human approval overrode a manual-review risk outcome for paper execution; broker dispatch remains disabled.'
      else 'Manual approval granted for paper execution; broker dispatch remains disabled.'
    end,
    jsonb_build_object(
      'execution_request_id', r.id,
      'risk_decision_id', r.risk_decision_id,
      'risk_decision', rd.decision,
      'approved_by', v_user_id,
      'approved_role', v_role,
      'execution_mode', a.execution_mode,
      'broker_dispatch_state', 'not_dispatched',
      'human_override', (rd.decision = 'manual_review')
    )
  );

  return query select v_updated.id, v_updated.status, v_updated.broker_dispatch_state, v_user_id;
end;
$function$;
