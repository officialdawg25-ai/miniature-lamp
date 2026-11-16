# Institutional AI — Windows MT5 demo execution host

This bridge connects the existing Institutional AI Supabase project to a MetaTrader 5 desktop terminal running on **Windows**. It is configured for the existing Exness **demo** account and **XAUUSD only**.

The PC initiates outbound HTTPS requests to Supabase. Supabase never connects directly to the broker. MT5 login credentials remain on the PC.

## Safety defaults

- The host refuses to run unless MT5 reports a DEMO account.
- Orders are dry-run by default. The Windows setup writes `SEND_DEMO_ORDERS=0`.
- The launcher refuses to start if that value is changed.
- The platform account remains in human-approval mode; every request is checked again by the platform and host.
- The local `STOP` file or Ctrl+C stops the host.
- The token secret is stored in the current Windows user's environment. Only its SHA-256 hash is shared for registration.
- No MT5 password, login or server value is required in this script if MT5 is already logged in interactively.

## One-time Windows setup

1. Download the repository ZIP from the branch containing this setup, extract it, and open the `execution-host` folder.
2. Open MetaTrader 5 and log in to the correct Exness **demo** account.
3. In MT5, open Market Watch and confirm the gold symbol name. It is normally `XAUUSD`. If Exness displays a suffix (for example `XAUUSDm`), note the suffix.
4. Open PowerShell in this folder and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\setup_windows.ps1
   ```

5. The setup installs the Python dependency, creates a unique host secret, and prints a `TOKEN_HASH`. Send **only that hash** to the project operator for registration against the existing Supabase demo account.
6. After the host is registered, run:

   ```powershell
   .\start_windows.ps1
   ```

The console should report a successful platform ping, XAUUSD symbol-specification sync, and periodic account snapshots. Keep this PowerShell window and MT5 open.

## If the broker uses a gold-symbol suffix

The bridge defaults to `XAUUSD`. If Market Watch shows `XAUUSDm`, run this once in PowerShell:

```powershell
[Environment]::SetEnvironmentVariable("SYMBOL_SUFFIX", "m", "User")
$env:SYMBOL_SUFFIX = "m"
```

Replace `m` with the actual suffix shown in your terminal, then restart the bridge.

## Stop the host

Press `Ctrl+C`, or create an empty file named `STOP` in this folder. Delete `STOP` before starting it again.

## Tests (no MT5 terminal required)

```powershell
py -m unittest -v test_host_logic
```

GitHub Actions runs these pure-Python order-logic tests automatically for changes to this folder.

## Reconciliation and fail-safes

Every five minutes (and after each handled request) the host reports account balance, equity, open positions, pending orders and recent trade deals. The platform blocks new requests when the last broker snapshot is older than 15 minutes. Broker positions, pending orders and in-flight requests count toward the open-trade limit.

## Current scope

The bridge synchronizes broker symbol specifications, account snapshots and trade deals, and polls for already-authorized execution requests. It does not yet manage open positions (trailing stops or early closes), and broker snapshots/deals remain the source of truth for demo execution reconciliation.

**Do not enable live trading through this bridge.** This integration is intentionally demo-only.
