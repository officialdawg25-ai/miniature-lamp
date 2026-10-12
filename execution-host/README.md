# MT5 demo execution host

Runs on a **Windows** machine (a small VPS is fine) with MetaTrader 5 installed and logged in to an Exness **demo** account.
It pulls approved requests from the platform, checks them a second time, and sends them to the demo account.
A phone or a library computer cannot run it, because the MetaTrader5 Python package only works on Windows.

## Safety rules built in
- **Demo only.** The host exits if MT5 reports anything other than a demo account. There is no live-account code path, and the database rejects any host whose mode is not `demo`.
- **Dry run by default.** Orders are checked with the broker's own pre-check and then reported as `dry_run_no_order_sent`. Nothing is sent until you set `SEND_DEMO_ORDERS=1`.
- **Pull model.** The platform never connects to the broker. The host calls the platform over HTTPS.
- **No credentials leave this machine.** MT5 login, password and server are read from environment variables here. The platform only ever sees a hash of the host token.
- **Every request is checked three times:** the platform's risk gate when it is created, again when the host claims it (including human approval and the broker's volume rules), and again on the host (stop loss, volume step, price drift, duplicate order).
- **Stop switch.** Create a file named `STOP` next to the script and the host exits at the next poll. Setting the account inactive in the platform also stops all claims.

## Setup (on the Windows machine)
1. Install Python 3.10+ and MetaTrader 5. Log MT5 in to the demo account once, and enable *Tools > Options > Expert Advisors > Allow algorithmic trading*.
2. `pip install MetaTrader5`
3. Create the host secret: `python make_token.py`. Keep the `HOST_TOKEN` it prints on this machine. Copy only the `TOKEN_HASH` to whoever registers the host.
4. Set environment variables (PowerShell example, do not paste them anywhere else):
   ```
   setx HOST_TOKEN "<the token from step 3>"
   setx MT5_LOGIN "<demo login>"
   setx MT5_PASSWORD "<demo trading password>"
   setx MT5_SERVER "<demo server name>"
   setx SYMBOLS "USDJPY,XAUUSD"
   ```
   If the broker adds a suffix to symbol names on this account type, also set `SYMBOL_SUFFIX` (for example `c` or `m`). Check Market Watch for the real names.
5. Run `python mt5_host.py`. It connects, syncs the symbol specifications to the platform, and starts polling. It stays in dry-run mode until you also set `SEND_DEMO_ORDERS=1`.

## One-time registration (platform side, SQL editor)
The account must be flagged as demo and require human approval. All risk limits must be in the unit MT5 reports for that account
(on a cent account that is cents, so 100 means 1 dollar). Mixing units would make every limit 100 times too loose or too tight.
```sql
insert into trading.accounts (name, broker, platform, currency_code, execution_mode, initial_balance,
  max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
values ('Exness demo cent', 'Exness', 'MT5', 'USD', 'human_approval', <balance in MT5 unit>,
  <max risk per trade>, <max daily loss>, <max weekly loss>, 2,
  '{"broker_mode":"demo","unit":"cent","max_aggregate_open_risk":<limit>}');
-- add yourself as the owner so you can approve requests:
insert into trading.account_members (account_id, user_id, role) values ('<account id>', '<your user id>', 'owner');
select trading.register_execution_host('<account id>', 'exness-demo-vps', '<TOKEN_HASH from step 3>');
```

## Tests
`python -m unittest test_host_logic` (no MetaTrader needed).

## What it does not do yet
It does not reconcile broker positions back into the platform's position and P&L tables, and it does not manage open orders after they are placed. Those are the next pieces.
