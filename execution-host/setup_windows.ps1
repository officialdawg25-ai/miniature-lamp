# One-time Windows setup for the Institutional AI MT5 demo execution host.
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "This bridge requires Windows." }
if (-not (Get-Command py -ErrorAction SilentlyContinue)) { throw "Python Launcher py.exe not found. Reinstall Python with the launcher enabled." }
$pyVersion = & py -c "import sys,struct; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor)+';'+str(struct.calcsize('P')*8))"
if ($LASTEXITCODE -ne 0) { throw "Python could not start." }
$parts = $pyVersion -split ";"
if ([version]($parts[0]+".0") -lt [version]"3.10.0") { throw "Python 3.10 or newer is required. Detected $($parts[0])." }
if ($parts[1] -ne "64") { throw "64-bit Python is required. Detected $($parts[1])-bit." }

Write-Host "[1/4] Installing dependencies..." -ForegroundColor Cyan
& py -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }
& py -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw "Dependency installation failed." }

Write-Host "[2/4] Verifying MetaTrader5 package..." -ForegroundColor Cyan
& py -c "import MetaTrader5 as mt5; print('MetaTrader5 package:', mt5.__version__)"
if ($LASTEXITCODE -ne 0) { throw "MetaTrader5 package cannot be imported." }

Write-Host "[3/4] Generating a local host credential..." -ForegroundColor Cyan
$tokenLines = & py -c "import secrets,hashlib; t=secrets.token_urlsafe(48); print(t); print(hashlib.sha256(t.encode()).hexdigest())"
if ($LASTEXITCODE -ne 0 -or $tokenLines.Count -lt 2) { throw "Token generation failed." }
$hostToken = $tokenLines[0].Trim()
$tokenHash = $tokenLines[1].Trim()

[Environment]::SetEnvironmentVariable("HOST_TOKEN", $hostToken, "User")
[Environment]::SetEnvironmentVariable("PLATFORM_URL", "https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/execution-host-api", "User")
[Environment]::SetEnvironmentVariable("SYMBOLS", "XAUUSD", "User")
[Environment]::SetEnvironmentVariable("SYMBOL_SUFFIX", "", "User")
[Environment]::SetEnvironmentVariable("SEND_DEMO_ORDERS", "0", "User")
[Environment]::SetEnvironmentVariable("POLL_SECONDS", "15", "User")
[Environment]::SetEnvironmentVariable("STATE_SECONDS", "300", "User")

$env:HOST_TOKEN = $hostToken
$env:PLATFORM_URL = "https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/execution-host-api"
$env:SYMBOLS = "XAUUSD"
$env:SYMBOL_SUFFIX = ""
$env:SEND_DEMO_ORDERS = "0"
$env:POLL_SECONDS = "15"
$env:STATE_SECONDS = "300"
$hostToken = $null
$tokenLines = $null

Write-Host "[4/4] Setup complete." -ForegroundColor Green
Write-Host "Instrument: XAUUSD | Account mode: DEMO | Execution: DRY RUN ONLY" -ForegroundColor Yellow
Write-Host "Copy this TOKEN_HASH and send it to ChatGPT for registration in your existing Supabase account:"
Write-Host $tokenHash -ForegroundColor Green
Write-Host "Never share HOST_TOKEN, your MT5 password, or broker login credentials."
Write-Host "Keep MT5 open on your Exness DEMO account. Then run .\start_windows.ps1"
