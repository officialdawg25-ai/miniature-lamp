-- Operator control layer: per-account operating mode, kill switch and editable risk policy.
-- Every change goes through an owner-checked SECURITY DEFINER function, is validated server-side and is written to the immutable execution audit log.
-- The risk gate and the execution-host claim read these columns, so the browser cannot bypass them. Live execution cannot be enabled from here.
alter table trading.accounts
  add column if not exists operating_mode text not null default 'demo' check (operating_mode in ('research', 'paper', 'demo', 'restricted_live')),
  add column if not exists kill_switch boolean not null default false,
  add column if not exists kill_switch_reason text,
  add column if not exists kill_switch_at timestamptz;

-- Risk gate: block on kill switch, research mode and live mode (live stays disabled until separately authorised).
do $do$
declare
  d text := pg_get_functiondef('trading.evaluate_execution_risk(uuid,uuid,trading.side,numeric,text,numeric,numeric,numeric,uuid)'::regprocedure);
  anchor constant text := E'  if not a.active then blocked := array_append(blocked, ''account_inactive''::text); end if;\n';
  extra constant text := E'  if a.kill_switch then blocked := array_append(blocked, ''kill_switch_active''::text); end if;\n'
    || E'  if a.operating_mode = ''research'' then blocked := array_append(blocked, ''operating_mode_research_no_orders''::text); end if;\n'
    || E'  if a.operating_mode = ''restricted_live'' then blocked := array_append(blocked, ''live_execution_not_enabled''::text); end if;\n';
begin
  if position(anchor in d) = 0 then raise exception 'risk gate anchor not found'; end if;
  if position('kill_switch_active' in d) > 0 then return; end if;
  execute replace(d, anchor, anchor || extra);
end
$do$;

-- Execution host: a stopped account or a mode other than demo hands out nothing.
do $do$
declare
  d text := pg_get_functiondef('public.host_claim_requests(uuid,integer)'::regprocedure);
  anchor constant text := 'or a.execution_mode <> ''human_approval'' then return out; end if;';
begin
  if position(anchor in d) = 0 then raise exception 'claim anchor not found'; end if;
  if position('a.kill_switch' in d) > 0 then return; end if;
  execute replace(d, anchor, 'or a.execution_mode <> ''human_approval'' or a.kill_switch or a.operating_mode <> ''demo'' then return out; end if;');
end
$do$;

create or replace function public.get_account_controls()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(), 'accounts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'name', a.name, 'broker', a.broker, 'platform', a.platform, 'currency', a.currency_code, 'broker_mode', a.metadata ->> 'broker_mode',
      'role', m.role, 'active', a.active, 'operating_mode', a.operating_mode, 'execution_mode', a.execution_mode,
      'kill_switch', a.kill_switch, 'kill_switch_reason', a.kill_switch_reason, 'kill_switch_at', a.kill_switch_at,
      'initial_balance', a.initial_balance,
      'policy', jsonb_build_object('max_risk_per_trade', a.max_risk_per_trade, 'risk_per_trade_fraction', a.metadata -> 'risk_per_trade_fraction',
        'max_daily_loss', a.max_daily_loss, 'max_weekly_loss', a.max_weekly_loss, 'max_open_trades', a.max_open_trades,
        'max_aggregate_open_risk', a.metadata -> 'max_aggregate_open_risk', 'max_setup_age_minutes', coalesce(a.metadata -> 'max_setup_age_minutes', to_jsonb(1440))),
      'audit', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'event', e.event_type, 'before', e.before_state, 'after', e.after_state, 'reason', e.metadata ->> 'reason') order by e.occurred_at desc)
        from (select * from trading.execution_audit_events x where x.account_id = a.id and x.entity_type = 'account_control' order by x.occurred_at desc limit 20) e), '[]'::jsonb)
    ) order by a.name)
    from trading.accounts a join trading.account_members m on m.account_id = a.id and m.user_id = uid and m.active), '[]'::jsonb));
end $function$;

create or replace function public.update_risk_policy(
  p_account_id uuid, p_reason text, p_max_risk_per_trade numeric default null, p_risk_fraction numeric default null,
  p_max_daily_loss numeric default null, p_max_weekly_loss numeric default null, p_max_open_trades integer default null,
  p_max_aggregate_open_risk numeric default null, p_max_setup_age_minutes numeric default null)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); a trading.accounts%rowtype; before jsonb; after jsonb; n_per numeric; n_agg numeric; n_week numeric; md jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p_account_id and m.user_id = uid and m.active and m.role = 'owner') then
    raise exception 'only an account owner can change the risk policy' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then raise exception 'a reason of at least 5 characters is required'; end if;
  select * into a from trading.accounts where id = p_account_id for update;
  if not found then raise exception 'account not found'; end if;
  if p_max_risk_per_trade is not null and p_max_risk_per_trade <= 0 then raise exception 'max risk per trade must be positive'; end if;
  if p_risk_fraction is not null and (p_risk_fraction <= 0 or p_risk_fraction > 0.10) then raise exception 'risk fraction must be above 0 and at most 0.10'; end if;
  if p_max_daily_loss is not null and p_max_daily_loss <= 0 then raise exception 'daily loss limit must be positive'; end if;
  if p_max_weekly_loss is not null and p_max_weekly_loss <= 0 then raise exception 'weekly loss limit must be positive'; end if;
  if p_max_open_trades is not null and (p_max_open_trades < 1 or p_max_open_trades > 20) then raise exception 'max open trades must be between 1 and 20'; end if;
  if p_max_aggregate_open_risk is not null and p_max_aggregate_open_risk <= 0 then raise exception 'aggregate open risk must be positive'; end if;
  if p_max_setup_age_minutes is not null and (p_max_setup_age_minutes < 1 or p_max_setup_age_minutes > 10080) then raise exception 'setup age must be between 1 and 10080 minutes'; end if;
  n_per := coalesce(p_max_risk_per_trade, a.max_risk_per_trade);
  n_week := coalesce(p_max_weekly_loss, a.max_weekly_loss);
  n_agg := coalesce(p_max_aggregate_open_risk, case when a.metadata ->> 'max_aggregate_open_risk' ~ '^[0-9]+(\.[0-9]+)?$' then (a.metadata ->> 'max_aggregate_open_risk')::numeric end);
  if n_per > n_week then raise exception 'max risk per trade cannot exceed the weekly loss limit'; end if;
  if n_agg is not null and n_per > n_agg then raise exception 'max risk per trade cannot exceed aggregate open risk'; end if;
  before := jsonb_build_object('max_risk_per_trade', a.max_risk_per_trade, 'risk_per_trade_fraction', a.metadata -> 'risk_per_trade_fraction', 'max_daily_loss', a.max_daily_loss,
    'max_weekly_loss', a.max_weekly_loss, 'max_open_trades', a.max_open_trades, 'max_aggregate_open_risk', a.metadata -> 'max_aggregate_open_risk', 'max_setup_age_minutes', a.metadata -> 'max_setup_age_minutes');
  md := a.metadata;
  if p_risk_fraction is not null then md := jsonb_set(md, '{risk_per_trade_fraction}', to_jsonb(p_risk_fraction)); end if;
  if p_max_aggregate_open_risk is not null then md := jsonb_set(md, '{max_aggregate_open_risk}', to_jsonb(p_max_aggregate_open_risk)); end if;
  if p_max_setup_age_minutes is not null then md := jsonb_set(md, '{max_setup_age_minutes}', to_jsonb(p_max_setup_age_minutes)); end if;
  update trading.accounts set max_risk_per_trade = n_per, max_daily_loss = coalesce(p_max_daily_loss, max_daily_loss), max_weekly_loss = n_week,
    max_open_trades = coalesce(p_max_open_trades, max_open_trades), metadata = md where id = p_account_id;
  select jsonb_build_object('max_risk_per_trade', x.max_risk_per_trade, 'risk_per_trade_fraction', x.metadata -> 'risk_per_trade_fraction', 'max_daily_loss', x.max_daily_loss,
    'max_weekly_loss', x.max_weekly_loss, 'max_open_trades', x.max_open_trades, 'max_aggregate_open_risk', x.metadata -> 'max_aggregate_open_risk', 'max_setup_age_minutes', x.metadata -> 'max_setup_age_minutes')
    into after from trading.accounts x where x.id = p_account_id;
  insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
  values (p_account_id, 'account_control', p_account_id, 'risk_policy_updated', uid, 'owner', before, after, jsonb_build_object('reason', btrim(p_reason)));
  return after;
end $function$;

create or replace function public.set_account_mode(p_account_id uuid, p_reason text, p_operating_mode text default null, p_execution_mode text default null)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); a trading.accounts%rowtype; before jsonb; after jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p_account_id and m.user_id = uid and m.active and m.role = 'owner') then
    raise exception 'only an account owner can change the operating mode' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then raise exception 'a reason of at least 5 characters is required'; end if;
  if p_operating_mode is not null and p_operating_mode not in ('research', 'paper', 'demo') then
    raise exception 'operating mode % cannot be selected here: live execution is disabled and needs a separate authorisation', p_operating_mode;
  end if;
  if p_execution_mode is not null and p_execution_mode not in ('analysis_only', 'human_approval') then
    raise exception 'execution mode % cannot be selected here: automated execution is not enabled', p_execution_mode;
  end if;
  select * into a from trading.accounts where id = p_account_id for update;
  if not found then raise exception 'account not found'; end if;
  if p_operating_mode = 'demo' and coalesce(a.metadata ->> 'broker_mode', '') <> 'demo' then raise exception 'demo mode needs a demo broker account'; end if;
  before := jsonb_build_object('operating_mode', a.operating_mode, 'execution_mode', a.execution_mode);
  update trading.accounts set operating_mode = coalesce(p_operating_mode, operating_mode), execution_mode = coalesce(p_execution_mode, execution_mode::text)::trading.execution_mode where id = p_account_id;
  select jsonb_build_object('operating_mode', x.operating_mode, 'execution_mode', x.execution_mode) into after from trading.accounts x where x.id = p_account_id;
  insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
  values (p_account_id, 'account_control', p_account_id, 'mode_changed', uid, 'owner', before, after, jsonb_build_object('reason', btrim(p_reason)));
  return after;
end $function$;

create or replace function public.set_kill_switch(p_account_id uuid, p_engaged boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); r text; a trading.accounts%rowtype; after jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  select m.role into r from trading.account_members m where m.account_id = p_account_id and m.user_id = uid and m.active;
  if r is null or (p_engaged and r not in ('owner', 'risk_manager')) or (not p_engaged and r <> 'owner') then
    raise exception 'not permitted: any owner or risk manager can engage the kill switch, only an owner can release it' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then raise exception 'a reason of at least 5 characters is required'; end if;
  select * into a from trading.accounts where id = p_account_id for update;
  if not found then raise exception 'account not found'; end if;
  update trading.accounts set kill_switch = p_engaged, kill_switch_reason = case when p_engaged then btrim(p_reason) end, kill_switch_at = case when p_engaged then now() end where id = p_account_id;
  after := jsonb_build_object('kill_switch', p_engaged);
  insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
  values (p_account_id, 'account_control', p_account_id, case when p_engaged then 'kill_switch_engaged' else 'kill_switch_released' end, uid, r, jsonb_build_object('kill_switch', a.kill_switch), after, jsonb_build_object('reason', btrim(p_reason)));
  insert into trading.risk_events(account_id, event_type, severity, message, metrics)
  values (p_account_id, case when p_engaged then 'kill_switch_engaged' else 'kill_switch_released' end, case when p_engaged then 'critical' else 'warning' end,
    case when p_engaged then 'Kill switch engaged: no new orders will be authorised or handed to the host.' else 'Kill switch released.' end, jsonb_build_object('reason', btrim(p_reason), 'actor', uid));
  return after;
end $function$;

revoke all on function public.get_account_controls() from public, anon;
revoke all on function public.update_risk_policy(uuid, text, numeric, numeric, numeric, numeric, integer, numeric, numeric) from public, anon;
revoke all on function public.set_account_mode(uuid, text, text, text) from public, anon;
revoke all on function public.set_kill_switch(uuid, boolean, text) from public, anon;
grant execute on function public.get_account_controls() to authenticated;
grant execute on function public.update_risk_policy(uuid, text, numeric, numeric, numeric, numeric, integer, numeric, numeric) to authenticated;
grant execute on function public.set_account_mode(uuid, text, text, text) to authenticated;
grant execute on function public.set_kill_switch(uuid, boolean, text) to authenticated;
