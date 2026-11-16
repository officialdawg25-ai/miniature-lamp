# Start the Institutional AI MT5 demo bridge.
$ErrorActionPreference = "Stop"
if (-not $env:HOST_TOKEN) { $env:HOST_TOKEN = [Environment]::GetEnvironmentVariable("HOST_TOKEN", "User") }
if (-not $env:PLATFORM_URL) { $env:PLATFORM_URL = [Environment]::GetEnvironmentVariable("PLATFORM_URL", "User") }
if (-not $env:SYMBOLS) { $env:SYMBOLS = [Environment]::GetEnvironmentVariable("SYMBOLS", "User") }
if (-not $env:SEND_DEMO_ORDERS) { $env:SEND_DEMO_ORDERS = "0" }

if (-not $env:HOST_TOKEN) { throw "HOST_TOKEN is missing. Run .\setup_windows.ps1 first." }
if ($env:SEND_DEMO_ORDERS -ne "0") { throw "Safety stop: this launcher only permits SEND_DEMO_ORDERS=0." }
if (-not (Get-Process -Name terminal64,terminal -ErrorAction SilentlyContinue)) {
  throw "MetaTrader 5 is not running. Open MT5, log into your Exness DEMO account, then run this script again."
}

Write-Host "Starting Institutional AI MT5 bridge..." -ForegroundColor Cyan
Write-Host "Instrument: XAUUSD | Mode: DEMO | Orders: DRY RUN ONLY" -ForegroundColor Yellow
Write-Host "Stop with Ctrl+C, or create a file named STOP in this folder."
& py .\mt5_host.py
if ($LASTEXITCODE -ne 0) { throw "MT5 host exited with code $LASTEXITCODE." }
