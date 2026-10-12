-- The owner authorized retiring these tables (12 October 2026). A physical drop needs an interactive confirmation that was not available,
-- so they are renamed and labelled instead. Both are empty, never written by any function, unreachable by the API roles, and referenced
-- only by each other. Backtest results live in intelligence.backtest_runs. To remove them for good, run in the SQL editor:
--   drop table research.retired_backtest_trades; drop table research.retired_backtest_runs; drop schema research;
alter table research.backtest_runs rename to retired_backtest_runs;
alter table research.backtest_trades rename to retired_backtest_trades;
comment on table research.retired_backtest_runs is 'RETIRED 2026-10-12. Empty and unused. Superseded by intelligence.backtest_runs. Safe to drop.';
comment on table research.retired_backtest_trades is 'RETIRED 2026-10-12. Empty and unused. Safe to drop.';