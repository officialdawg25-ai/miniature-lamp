# Paid historical data: what to buy and how it is loaded

The platform cannot measure an economic **surprise** or what was **priced in** without two kinds of paid history. The tables that hold them already exist (migration `20261013470000_paid_data_contracts.sql`) and stay empty until the data is bought. Nothing is estimated in the meantime.

## What to obtain (in order of research value)

| Dataset | Minimum content | Why |
|---|---|---|
| Consensus forecasts | For each release (US NFP, CPI, core CPI, PCE, GDP, retail sales, ISM; euro-area HICP flash; UK CPI; Japan CPI): the consensus value **with the time it was observed** (ideally each revision of the consensus), 2010 on | Surprise = first print minus the last consensus known before the release |
| First-print actuals | The value **as first released**, with the release timestamp; later revisions as separate rows | Revised data was not known on the day; using it is look-ahead |
| Policy expectations | Fed funds futures and/or meeting-dated OIS (USD; ideally EUR, GBP, JPY too), end-of-day or intraday, 2010 on | Lets the platform measure the policy surprise at each central-bank meeting instead of using the 2-year yield as a proxy |

Licence terms must permit storing the history in this database for internal research. Record those terms in `licence_note` on every import.

## Loading

Imports run only with the service role, through `macro.import_paid_data(provider, dataset, licence_note, source_file, rows)`. `dataset` is one of `consensus`, `actuals` or `rate_expectations`, and `rows` is a JSON array.

- **consensus**: `release_key`, `period_label`, `scheduled_release_at`, `observed_at`, `forecast`, `unit`; optional `forecast_low`, `forecast_high`, `contributors`.
- **actuals**: `release_key`, `period_label`, `released_at`, `actual`, `unit`; optional `revision` (0 = first print, the default).
- **rate_expectations**: `currency`, `instrument`, `observed_at`, `implied_rate` (percent); optional `meeting_date`.

Guarantees:
- Each call creates a batch row in `macro.data_import_batches` with counts of rows received, accepted, duplicate and rejected, plus the first 200 rejection reasons.
- Imports are insert-only. A row that is already stored is counted as a duplicate and never overwritten.
- A consensus row observed at or after its release is rejected, and so is any row timestamped in the future.
- `macro.release_surprises` pairs each first print with the last consensus observed strictly before the release.

Release keys follow `COUNTRY_INDICATOR[_VARIANT]`, e.g. `US_NFP`, `US_CPI_YOY`, `US_CORE_CPI_MOM`, `EZ_HICP_FLASH_YOY`, `UK_CPI_YOY`, `JP_CPI_YOY`. Use the same key for a release across every provider.

## After loading

Any research that uses this data is registered in the ledger before the first surprise is computed, as with every other hypothesis. Loading the data does not by itself change any strategy status.
