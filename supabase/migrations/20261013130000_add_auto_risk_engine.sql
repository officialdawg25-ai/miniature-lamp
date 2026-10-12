-- Automatic risk engine. The owner sets a policy in percent of equity; the engine turns it into dollar limits whenever equity changes and blocks new
-- entries when capital is threatened. It only ever narrows what the existing risk gate allows: it cannot open a trade, approve a request or release a kill switch.
--
-- Equity source: the latest broker snapshot when an execution host is active and the snapshot is under 15 minutes old (balance detected automatically; the
-- first broker observation replaces the platform's starting balance, audited); otherwise the paper ledger (starting balance + realized + unrealized P&L).
-- Limits: per trade = equity x trade fraction; daily = equity at the start of the UTC day x daily fraction; weekly = equity at the start of the ISO week x weekly
-- fraction; open risk = equity x aggregate fraction. Rounded down to the cent, so a limit never exceeds its percentage.
-- Protection: drawdown from the equity peak at the policy limit engages the kill switch (only an owner can release it); equity below the day or week start by the
-- daily or weekly fraction blocks new entries until the next day or week; a broker margin level below the policy minimum blocks new entries; the host claim
-- refuses an order whose margin would push the margin level under that minimum. Exness Standard publishes a 60% margin call and a 0% stop out; the engine
-- uses the levels MT5 reports for the account and keeps its own minimum far above them.

alter table trading.broker_snapshots add column if not exists broker_terms jsonb;
-- The actual insert time, so several snapshots in one transaction (or a burst) order correctly.
alter table trading.broker_snapshots alter column taken_at set default clock_timestamp();

create or replace function trading.refresh_risk_limits(p_account_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  a trading.accounts%rowtype; pol jsonb; st jsonb; snap trading.broker_snapshots%rowtype; has_host boolean; src text; eq numeric; bal numeric;
  peak numeric; day_start numeric; week_start numeric; today text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD');
  wk text := to_char(date_trunc('week', now() at time zone 'UTC'), 'YYYY-MM-DD');
  f_trade numeric; f_daily numeric; f_weekly numeric; f_agg numeric; f_dd numeric; min_ml numeric;
  per numeric; daily numeric; weekly numeric; agg numeric; ml numeric := null; dd numeric; blocks jsonb := '[]'::jsonb; owner uuid; summary jsonb;
begin
  select * into a from trading.accounts where id = p_account_id for update;
  if not found then raise exception 'account not found'; end if;
  pol := a.metadata -> 'risk_policy';
  if pol is null or coalesce((pol ->> 'enabled')::boolean, false) is not true then return jsonb_build_object('enabled', false); end if;
  f_trade := (pol ->> 'risk_per_trade_fraction')::numeric; f_daily := (pol ->> 'daily_loss_fraction')::numeric; f_weekly := (pol ->> 'weekly_loss_fraction')::numeric;
  f_agg := (pol ->> 'aggregate_open_risk_fraction')::numeric; f_dd := (pol ->> 'max_drawdown_fraction')::numeric; min_ml := (pol ->> 'min_margin_level_pct')::numeric;
  st := coalesce(a.metadata -> 'auto_risk', '{}'::jsonb);
  select m.user_id into owner from trading.account_members m where m.account_id = a.id and m.role = 'owner' and m.active order by m.created_at limit 1;

  select exists (select 1 from trading.execution_hosts h where h.account_id = a.id and h.active) into has_host;
  if has_host then select * into snap from trading.broker_snapshots s where s.account_id = a.id order by s.taken_at desc limit 1; end if;
  if has_host and snap.id is not null and snap.taken_at >= now() - interval '15 minutes' then
    src := 'broker'; eq := snap.equity; bal := snap.balance;
    if coalesce((st ->> 'broker_balance_adopted')::boolean, false) is not true then
      if a.initial_balance is distinct from bal then
        insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
        values (a.id, 'account_control', a.id, 'starting_balance_detected_from_broker', null, 'risk_engine', jsonb_build_object('initial_balance', a.initial_balance),
                jsonb_build_object('initial_balance', bal), jsonb_build_object('reason', 'First broker snapshot from the execution host; the broker balance is authoritative', 'snapshot_id', snap.id));
        update trading.accounts set initial_balance = bal where id = a.id;
      end if;
      st := (st - 'peak_equity' - 'day_start_equity' - 'week_start_equity' - 'day' - 'week')
            || jsonb_build_object('broker_balance_adopted', true, 'adopted_at', now(), 'adopted_balance', bal);
    end if;
  elsif has_host and snap.id is not null then
    src := 'broker_stale'; eq := snap.equity; bal := snap.balance;
  else
    src := 'paper'; eq := (trading.paper_account_summary(a.id) ->> 'equity')::numeric;
    bal := a.initial_balance + coalesce((select sum(l.realized_pnl) from trading.account_ledger l where l.account_id = a.id), 0);
  end if;

  peak := greatest(coalesce((st ->> 'peak_equity')::numeric, eq), eq);
  day_start := case when st ->> 'day' = today and st ? 'day_start_equity' then (st ->> 'day_start_equity')::numeric else eq end;
  week_start := case when st ->> 'week' = wk and st ? 'week_start_equity' then (st ->> 'week_start_equity')::numeric else eq end;
  per := greatest(round(floor(eq * f_trade * 100) / 100, 2), 0);
  daily := greatest(round(floor(day_start * f_daily * 100) / 100, 2), 0);
  weekly := greatest(round(floor(week_start * f_weekly * 100) / 100, 2), 0);
  agg := greatest(round(floor(eq * f_agg * 100) / 100, 2), 0);

  if eq is null or eq <= 0 then blocks := blocks || '["equity_not_positive"]'::jsonb; end if;
  dd := case when peak > 0 then 1 - eq / peak else null end;
  if dd is not null and dd >= f_dd then
    blocks := blocks || '["max_drawdown_reached"]'::jsonb;
    if not a.kill_switch then
      update trading.accounts set kill_switch = true, kill_switch_at = now(),
        kill_switch_reason = format('Risk engine: equity %s is %s%% below its peak %s (limit %s%%). An owner must review and release.', round(eq, 2), round(dd * 100, 1), round(peak, 2), round(f_dd * 100, 1))
      where id = a.id;
      insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
      values (a.id, 'account_control', a.id, 'kill_switch_engaged', null, 'risk_engine', jsonb_build_object('kill_switch', false), jsonb_build_object('kill_switch', true),
              jsonb_build_object('reason', 'Maximum drawdown reached', 'equity', eq, 'peak_equity', peak, 'drawdown', dd));
      insert into trading.risk_events(account_id, event_type, severity, message, metrics)
      values (a.id, 'kill_switch_engaged', 'critical', 'Risk engine engaged the kill switch: maximum drawdown reached.', jsonb_build_object('equity', eq, 'peak_equity', peak, 'drawdown', dd));
    end if;
  end if;
  if eq <= day_start * (1 - f_daily) then blocks := blocks || '["daily_equity_loss_limit"]'::jsonb; end if;
  if eq <= week_start * (1 - f_weekly) then blocks := blocks || '["weekly_equity_loss_limit"]'::jsonb; end if;
  if src = 'broker' and coalesce(snap.margin_used, 0) > 0 then
    ml := eq / snap.margin_used * 100;
    if ml < min_ml then blocks := blocks || '["margin_level_below_minimum"]'::jsonb; end if;
  end if;

  if per is distinct from a.max_risk_per_trade or daily is distinct from a.max_daily_loss or weekly is distinct from a.max_weekly_loss
     or agg is distinct from nullif(a.metadata ->> 'max_aggregate_open_risk', '')::numeric then
    insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
    values (a.id, 'account_control', a.id, 'risk_limits_recomputed', null, 'risk_engine',
      jsonb_build_object('max_risk_per_trade', a.max_risk_per_trade, 'max_daily_loss', a.max_daily_loss, 'max_weekly_loss', a.max_weekly_loss, 'max_aggregate_open_risk', a.metadata -> 'max_aggregate_open_risk'),
      jsonb_build_object('max_risk_per_trade', per, 'max_daily_loss', daily, 'max_weekly_loss', weekly, 'max_aggregate_open_risk', agg),
      jsonb_build_object('reason', 'Recomputed from the risk policy and ' || src || ' equity ' || round(eq, 2)));
  end if;

  summary := jsonb_build_object('enabled', true, 'equity_source', src, 'equity', eq, 'balance', bal, 'peak_equity', peak, 'drawdown', dd,
    'day', today, 'day_start_equity', day_start, 'week', wk, 'week_start_equity', week_start, 'margin_level_pct', ml,
    'broker_terms', case when src in ('broker', 'broker_stale') then snap.broker_terms end, 'snapshot_at', snap.taken_at,
    'limits', jsonb_build_object('per_trade', per, 'daily', daily, 'weekly', weekly, 'aggregate_open', agg), 'blocks', blocks, 'refreshed_at', now());
  update trading.accounts set max_risk_per_trade = per, max_daily_loss = daily, max_weekly_loss = weekly,
    metadata = metadata || jsonb_build_object('max_aggregate_open_risk', agg, 'risk_per_trade_fraction', f_trade,
      'auto_risk', (st || summary) - 'enabled')
  where id = a.id;
  return summary;
end $function$;
revoke all on function trading.refresh_risk_limits(uuid) from public, anon, authenticated;

-- Equity changes: a new broker snapshot or a paper ledger entry.
create or replace function trading.trg_refresh_risk_limits()
returns trigger language plpgsql security definer set search_path to '' as $function$
begin
  perform trading.refresh_risk_limits(new.account_id);
  return null;
end $function$;
create or replace trigger broker_snapshots_refresh_risk after insert on trading.broker_snapshots for each row execute function trading.trg_refresh_risk_limits();
create or replace trigger account_ledger_refresh_risk after insert on trading.account_ledger for each row execute function trading.trg_refresh_risk_limits();

-- The host stores the broker terms MT5 reports (leverage, margin-call and stop-out levels).
create or replace function public.host_report_snapshot(p_host_id uuid, p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog' as $function$
declare
  h trading.execution_hosts%rowtype; prev trading.broker_snapshots%rowtype; pos jsonb; ord jsonb; bal numeric; eq numeric; stored boolean := false; terms jsonb;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  bal := (p_snapshot ->> 'balance')::numeric; eq := (p_snapshot ->> 'equity')::numeric;
  pos := coalesce(p_snapshot -> 'positions', '[]'::jsonb); ord := coalesce(p_snapshot -> 'orders', '[]'::jsonb);
  terms := case when jsonb_typeof(p_snapshot -> 'terms') = 'object' then jsonb_strip_nulls(jsonb_build_object(
    'leverage', (p_snapshot -> 'terms' ->> 'leverage')::numeric, 'margin_level', (p_snapshot -> 'terms' ->> 'margin_level')::numeric,
    'margin_call_level', (p_snapshot -> 'terms' ->> 'margin_call_level')::numeric, 'stop_out_level', (p_snapshot -> 'terms' ->> 'stop_out_level')::numeric,
    'margin_so_mode', (p_snapshot -> 'terms' ->> 'margin_so_mode')::numeric)) end;
  if bal is null or eq is null or jsonb_typeof(pos) <> 'array' or jsonb_typeof(ord) <> 'array' or jsonb_array_length(pos) > 50 or jsonb_array_length(ord) > 50 then
    raise exception 'invalid snapshot';
  end if;
  select * into prev from trading.broker_snapshots s where s.account_id = h.account_id order by s.taken_at desc limit 1;
  if not found or prev.positions is distinct from pos or prev.orders is distinct from ord or prev.taken_at < now() - interval '5 minutes'
     or prev.equity is distinct from eq or prev.balance is distinct from bal then
    insert into trading.broker_snapshots(account_id, host_id, balance, equity, margin_used, free_margin, currency, position_count, positions, orders, broker_terms)
    values (h.account_id, h.id, bal, eq, (p_snapshot ->> 'margin_used')::numeric, (p_snapshot ->> 'free_margin')::numeric, left(p_snapshot ->> 'currency', 8), jsonb_array_length(pos), pos, ord, terms);
    stored := true;
  end if;
  return jsonb_build_object('stored', stored, 'flags', trading.reconcile_account(h.account_id));
end;
$function$;

-- Risk gate: refresh the limits first, then block on every engine block.
do $do$
declare
  d text := pg_get_functiondef('trading.evaluate_execution_risk(uuid,uuid,trading.side,numeric,text,numeric,numeric,numeric,uuid)'::regprocedure);
  a1 constant text := E'  select * into a from trading.accounts where id = p_account_id;\n  if not found then\n    raise exception ''account not found'';';
  a2 constant text := E'  if a.kill_switch then blocked := array_append(blocked, ''kill_switch_active''::text); end if;\n';
begin
  if position('refresh_risk_limits' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception 'risk gate anchors not found'; end if;
  d := replace(d, a1, E'  perform trading.refresh_risk_limits(p_account_id);\n' || a1);
  d := replace(d, a2, a2 || E'  if jsonb_typeof(a.metadata -> ''auto_risk'' -> ''blocks'') = ''array'' then\n'
    || E'    for i in 0 .. jsonb_array_length(a.metadata -> ''auto_risk'' -> ''blocks'') - 1 loop blocked := array_append(blocked, (''auto_risk:'' || (a.metadata -> ''auto_risk'' -> ''blocks'' ->> i))::text); end loop;\n'
    || E'  end if;\n');
  execute d;
end
$do$;

-- Host claim: refuse an order whose margin would take the margin level below the policy minimum, or when leverage is unknown on an automatic account.
do $do$
declare
  d text := pg_get_functiondef('public.host_claim_requests(uuid,integer)'::regprocedure);
  anchor constant text := E'      elsif abs(round(r.quantity / sp.volume_step) * sp.volume_step - r.quantity) > sp.volume_step * 1e-6 then why := ''quantity not a multiple of the broker volume step'';\n      end if;';
  extra constant text := E'\n      if why is null and coalesce((a.metadata -> ''risk_policy'' ->> ''enabled'')::boolean, false) then\n'
    || E'        declare snap trading.broker_snapshots%rowtype; lev numeric; req_margin numeric; after_level numeric;\n'
    || E'        begin\n'
    || E'          select * into snap from trading.broker_snapshots s where s.account_id = r.account_id order by s.taken_at desc limit 1;\n'
    || E'          lev := nullif((snap.broker_terms ->> ''leverage'')::numeric, 0);\n'
    || E'          if lev is null then why := ''broker leverage unknown; margin cannot be verified'';\n'
    || E'          elsif sym like ''USD%'' then req_margin := r.quantity * sp.contract_size / lev;\n'
    || E'          elsif sym like ''%USD'' and r.requested_price > 0 then req_margin := r.quantity * sp.contract_size * r.requested_price / lev;\n'
    || E'          else why := ''margin check supports USD pairs and XAUUSD only''; end if;\n'
    || E'          if why is null then\n'
    || E'            after_level := snap.equity / nullif(coalesce(snap.margin_used, 0) + req_margin, 0) * 100;\n'
    || E'            if req_margin > coalesce(snap.free_margin, 0) or after_level < (a.metadata -> ''risk_policy'' ->> ''min_margin_level_pct'')::numeric then\n'
    || E'              why := format(''insufficient margin headroom: order needs %s, margin level after it would be %s%%'', round(req_margin, 2), round(after_level));\n'
    || E'            end if;\n'
    || E'          end if;\n'
    || E'        end;\n'
    || E'      end if;';
begin
  if position('margin cannot be verified' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception 'claim anchor not found'; end if;
  execute replace(d, anchor, anchor || extra);
end
$do$;

-- Manual dollar limits are refused while the engine is on; the percentages are changed instead.
do $do$
declare
  d text := pg_get_functiondef('public.update_risk_policy(uuid,text,numeric,numeric,numeric,numeric,integer,numeric,numeric)'::regprocedure);
  anchor constant text := E'  select * into a from trading.accounts where id = p_account_id for update;\n  if not found then raise exception ''account not found''; end if;\n';
begin
  if position('automatic risk management is on' in d) > 0 then return; end if;
  if position(anchor in d) = 0 then raise exception 'policy anchor not found'; end if;
  execute replace(d, anchor, anchor || E'  if coalesce((a.metadata -> ''risk_policy'' ->> ''enabled'')::boolean, false) and (p_max_risk_per_trade is not null or p_risk_fraction is not null or p_max_daily_loss is not null or p_max_weekly_loss is not null or p_max_aggregate_open_risk is not null) then\n'
    || E'    raise exception ''automatic risk management is on: change the percentages instead of the dollar limits'';\n  end if;\n');
end
$do$;

create or replace function public.set_auto_risk_policy(p_account_id uuid, p_reason text, p_enabled boolean,
  p_risk_per_trade numeric, p_daily_loss numeric, p_weekly_loss numeric, p_aggregate_open_risk numeric, p_max_drawdown numeric, p_min_margin_level_pct numeric)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); a trading.accounts%rowtype; pol jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p_account_id and m.user_id = uid and m.active and m.role = 'owner') then
    raise exception 'only an account owner can change the risk policy' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then raise exception 'a reason of at least 5 characters is required'; end if;
  if p_risk_per_trade is null or p_risk_per_trade <= 0 or p_risk_per_trade > 0.05 then raise exception 'risk per trade must be above 0 and at most 5%%'; end if;
  if p_daily_loss is null or p_daily_loss < p_risk_per_trade or p_daily_loss > 0.20 then raise exception 'daily loss must be at least the per-trade risk and at most 20%%'; end if;
  if p_weekly_loss is null or p_weekly_loss < p_daily_loss or p_weekly_loss > 0.40 then raise exception 'weekly loss must be at least the daily loss and at most 40%%'; end if;
  if p_aggregate_open_risk is null or p_aggregate_open_risk < p_risk_per_trade or p_aggregate_open_risk > 0.10 then raise exception 'open risk must be at least the per-trade risk and at most 10%%'; end if;
  if p_max_drawdown is null or p_max_drawdown < p_weekly_loss or p_max_drawdown > 0.50 then raise exception 'maximum drawdown must be at least the weekly loss and at most 50%%'; end if;
  if p_min_margin_level_pct is null or p_min_margin_level_pct < 150 or p_min_margin_level_pct > 5000 then raise exception 'minimum margin level must be between 150%% and 5000%%'; end if;
  select * into a from trading.accounts where id = p_account_id for update;
  pol := jsonb_build_object('enabled', p_enabled, 'risk_per_trade_fraction', p_risk_per_trade, 'daily_loss_fraction', p_daily_loss, 'weekly_loss_fraction', p_weekly_loss,
    'aggregate_open_risk_fraction', p_aggregate_open_risk, 'max_drawdown_fraction', p_max_drawdown, 'min_margin_level_pct', p_min_margin_level_pct,
    'broker_reference', 'Exness Standard publishes a 60% margin call and 0% stop out; the engine uses the levels MT5 reports and keeps its own minimum above them');
  insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
  values (a.id, 'account_control', a.id, 'auto_risk_policy_updated', uid, 'owner', coalesce(a.metadata -> 'risk_policy', '{}'::jsonb), pol, jsonb_build_object('reason', btrim(p_reason)));
  update trading.accounts set metadata = metadata || jsonb_build_object('risk_policy', pol) where id = a.id;
  return trading.refresh_risk_limits(a.id);
end $function$;
revoke all on function public.set_auto_risk_policy(uuid, text, boolean, numeric, numeric, numeric, numeric, numeric, numeric) from public, anon;
grant execute on function public.set_auto_risk_policy(uuid, text, boolean, numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;

-- Day and week roll-over and stale-snapshot detection between events.
select cron.schedule('risk-engine-refresh', '*/15 * * * *', $job$
  select trading.refresh_risk_limits(id) from trading.accounts where active and coalesce((metadata -> 'risk_policy' ->> 'enabled')::boolean, false);
$job$);
