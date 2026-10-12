"""MT5 demo execution host.

Runs on a Windows machine that has MetaTrader 5 installed and logged in to a DEMO account. It pulls approved requests from the
platform, checks them again, and (only when SEND_DEMO_ORDERS=1) sends them to the demo account. Credentials are read from
environment variables on this machine and are never sent to the platform. There is no live-account code path: the host exits
unless MT5 reports the account as a demo account.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

import host_logic as logic

PLATFORM_URL = os.environ.get("PLATFORM_URL", "https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/execution-host-api")
HOST_TOKEN = os.environ.get("HOST_TOKEN", "")
SYMBOLS = [s.strip().upper() for s in os.environ.get("SYMBOLS", "USDJPY,XAUUSD").split(",") if s.strip()]
SUFFIX = os.environ.get("SYMBOL_SUFFIX", "")          # some brokers append a suffix to symbol names on certain account types
SEND_ORDERS = os.environ.get("SEND_DEMO_ORDERS", "0") == "1"   # default is a dry run: orders are checked, never sent
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))
STOP_FILE = os.environ.get("STOP_FILE", "STOP")        # create this file to stop the host at the next poll
STATE_SECONDS = int(os.environ.get("STATE_SECONDS", "300"))   # how often account state and closed deals are reported


def api(action: str, **payload) -> dict:
    data = json.dumps({"action": action, **payload}).encode()
    req = urllib.request.Request(PLATFORM_URL, data=data, method="POST", headers={"Content-Type": "application/json", "x-host-token": HOST_TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"platform returned {e.code}: {body}") from None


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def connect(mt5):
    login, password, server = os.environ.get("MT5_LOGIN"), os.environ.get("MT5_PASSWORD"), os.environ.get("MT5_SERVER")
    kwargs = {}
    if login and password and server:
        kwargs = {"login": int(login), "password": password, "server": server}
    if not mt5.initialize(**kwargs):
        raise SystemExit(f"MT5 initialize failed: {mt5.last_error()}")
    info = mt5.account_info()
    if info is None:
        raise SystemExit("MT5 has no logged-in account")
    if info.trade_mode != mt5.ACCOUNT_TRADE_MODE_DEMO:
        mt5.shutdown()
        raise SystemExit("REFUSING TO RUN: this MT5 account is not a demo account. This host only works with demo accounts.")
    return info


def sync_specs(mt5, account_currency: str) -> None:
    specs = []
    for base in SYMBOLS:
        name = base + SUFFIX
        info = mt5.symbol_info(name)
        if info is None or not mt5.symbol_select(name, True):
            log(f"symbol {name} not available on this account; skipped")
            continue
        specs.append(logic.spec_from_symbol_info(base, info, account_currency))
    if specs:
        log(f"synced {api('sync_specs', specs=specs).get('specs_upserted')} symbol specifications")


def report_state(mt5, deals_days: int = 7) -> None:
    """Send the account snapshot and recent trade deals. The platform stores a snapshot only when something changed or 5 minutes passed."""
    info = mt5.account_info()
    if info is None:
        return
    snap = logic.build_snapshot(info, mt5.positions_get(), mt5.orders_get(), SUFFIX)
    result = api("snapshot", snapshot=snap)
    for flag in result.get("flags", []):
        log(f"RECONCILIATION {flag.get('severity', '').upper()} {flag.get('code')}: {flag.get('detail')}")
    now = time.time()
    deals = mt5.history_deals_get(now - deals_days * 86400, now + 3600)
    batch = logic.build_deals(deals, SUFFIX)
    for i in range(0, len(batch), 200):
        api("deals", deals=batch[i:i + 200])


def already_ordered(mt5, request_id: str) -> bool:
    comment = logic.comment_for(request_id)
    return any(x.comment == comment for x in (mt5.positions_get() or ())) or any(x.comment == comment for x in (mt5.orders_get() or ()))


def handle(mt5, req: dict, specs: dict) -> None:
    rid = req["request_id"]
    base = req["symbol"]
    name = base + SUFFIX
    spec = specs.get(base)

    def reject(reason: str, **detail) -> None:
        log(f"{rid} rejected: {reason}")
        api("report", request_id=rid, state="rejected", detail={"reason": reason, **detail})

    if spec is None:
        return reject("no local specification for symbol")
    problems = logic.validate_request(req, spec)
    if problems:
        return reject("; ".join(problems))
    if already_ordered(mt5, rid):
        return reject("an order or position with this request id already exists")
    tick = mt5.symbol_info_tick(name)
    if tick is None:
        return reject("no live price")
    if logic.worse_than_reference(req, tick.bid, tick.ask, spec["tick_size"]):
        return reject("live price moved too far from the approved reference price")
    order = logic.build_order(req, spec, name, tick.bid, tick.ask, mt5)
    check = mt5.order_check(order)
    if check is None or check.retcode != 0:
        return reject("broker pre-check failed", retcode=getattr(check, "retcode", None), comment=getattr(check, "comment", None))
    if not SEND_ORDERS:
        return reject("dry_run_no_order_sent", dry_run=True, would_send=order)
    api("report", request_id=rid, state="sent", detail={"dry_run": False, "order": order})
    result = mt5.order_send(order)
    if result is None or result.retcode not in (mt5.TRADE_RETCODE_DONE, mt5.TRADE_RETCODE_PLACED):
        return reject("broker rejected the order", retcode=getattr(result, "retcode", None), comment=getattr(result, "comment", None))
    api("report", request_id=rid, state="acknowledged", detail={"dry_run": False, "ticket": result.order, "deal": result.deal, "price": result.price, "volume": result.volume, "retcode": result.retcode})
    log(f"{rid} acknowledged ticket={result.order}")


def main() -> None:
    if len(HOST_TOKEN) < 32:
        raise SystemExit("HOST_TOKEN is not set. Create one with make_token.py and set it as an environment variable.")
    try:
        import MetaTrader5 as mt5  # only available on Windows
    except ImportError:
        raise SystemExit("The MetaTrader5 package is not installed (pip install MetaTrader5, Windows only).")
    info = connect(mt5)
    log(f"connected to a demo account (currency {info.currency}); orders {'WILL' if SEND_ORDERS else 'will NOT'} be sent (SEND_DEMO_ORDERS)")
    log(f"platform says: {api('ping')}")
    sync_specs(mt5, info.currency)
    specs = {}
    for base in SYMBOLS:
        si = mt5.symbol_info(base + SUFFIX)
        if si is not None:
            specs[base] = logic.spec_from_symbol_info(base, si, info.currency)
    failures = 0
    last_state = 0.0
    while not os.path.exists(STOP_FILE):
        try:
            # State first: the platform blocks new requests when its broker snapshot is more than 15 minutes old.
            if time.time() - last_state >= STATE_SECONDS:
                report_state(mt5)
                last_state = time.time()
            claimed = api("claim", limit=5).get("requests", [])
            for req in claimed:
                handle(mt5, req, specs)
            if claimed:
                report_state(mt5)
                last_state = time.time()
            failures = 0
        except Exception as e:  # keep running; back off if the platform or MT5 is unavailable
            failures += 1
            log(f"error: {e}")
            time.sleep(min(300, POLL_SECONDS * 2 ** min(failures, 5)))
        time.sleep(POLL_SECONDS)
    log("STOP file found; shutting down")
    mt5.shutdown()


if __name__ == "__main__":
    main()
