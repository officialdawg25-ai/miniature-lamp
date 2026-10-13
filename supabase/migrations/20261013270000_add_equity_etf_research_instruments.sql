-- Research-only reference series for the month-end hedge-rebalancing test: SPY (US equities) and EZU (euro-area equities, USD-priced).
-- Inactive, so no ticket, gate or host path treats them as tradable; daily bars arrive through intraday-twelvedata.
insert into core.instruments(symbol, name, instrument_type, price_precision, active, metadata)
select v.symbol, v.name, 'other', 2, false, jsonb_build_object('research_only', true, 'kind', 'equity ETF', 'vendor', 'Twelve Data')
from (values ('SPY', 'SPDR S&P 500 ETF (US equities)'), ('EZU', 'iShares MSCI Eurozone ETF (euro-area equities, USD)')) v(symbol, name)
where not exists (select 1 from core.instruments i where i.symbol = v.symbol);
