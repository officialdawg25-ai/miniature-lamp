"""Pure order-handling logic for the MT5 demo execution host. No MetaTrader5 import, so it can be unit-tested anywhere."""
from __future__ import annotations

from decimal import Decimal, ROUND_FLOOR


def comment_for(request_id: str) -> str:
    """MT5 comments hold 31 characters. 'rq' plus 28 hex characters of the request id identifies the order across restarts."""
    return "rq" + request_id.replace("-", "")[:28]


def spec_from_symbol_info(base_symbol: str, info, account_currency: str) -> dict:
    """Build the specification row the platform stores. `info` is MT5's symbol_info result (any object with these attributes)."""
    return {
        "symbol": base_symbol,
        "contract_size": float(info.trade_contract_size),
        "tick_size": float(info.trade_tick_size),
        "tick_value": float(info.trade_tick_value),
        "volume_min": float(info.volume_min),
        "volume_step": float(info.volume_step),
        "volume_max": float(info.volume_max),
        "account_currency": account_currency,
    }


def volume_ok(volume: float, spec: dict) -> bool:
    step = Decimal(str(spec["volume_step"]))
    v = Decimal(str(volume))
    if v < Decimal(str(spec["volume_min"])) or v > Decimal(str(spec["volume_max"])):
        return False
    return (v / step) == (v / step).to_integral_value()


def round_price(price: float, tick_size: float) -> float:
    t = Decimal(str(tick_size))
    return float((Decimal(str(price)) / t).to_integral_value() * t)


def validate_request(req: dict, spec: dict) -> list[str]:
    """Second, independent check on the host. The platform has already gated the request; the host refuses anything malformed."""
    problems: list[str] = []
    if req.get("side") not in ("long", "short"):
        problems.append("side must be long or short")
    if req.get("order_type") not in ("market", "limit"):
        problems.append("only market and limit orders are supported")
    if not req.get("stop_loss"):
        problems.append("stop loss is mandatory")
    price = req.get("price")
    if not price or float(price) <= 0:
        problems.append("reference price missing")
    if not volume_ok(float(req.get("volume") or 0), spec):
        problems.append("volume violates the broker's minimum, step or maximum")
    if price and req.get("stop_loss"):
        p, s = float(price), float(req["stop_loss"])
        if req.get("side") == "long" and s >= p:
            problems.append("stop must be below the entry for a long")
        if req.get("side") == "short" and s <= p:
            problems.append("stop must be above the entry for a short")
    return problems


def build_order(req: dict, spec: dict, symbol_name: str, bid: float, ask: float, constants, max_deviation_points: int = 20) -> dict:
    """Return an MT5 order request dict. `constants` is the MetaTrader5 module (or a stand-in with the same attribute names)."""
    long_side = req["side"] == "long"
    tick = spec["tick_size"]
    if req["order_type"] == "market":
        action = constants.TRADE_ACTION_DEAL
        otype = constants.ORDER_TYPE_BUY if long_side else constants.ORDER_TYPE_SELL
        price = ask if long_side else bid
    else:
        action = constants.TRADE_ACTION_PENDING
        otype = constants.ORDER_TYPE_BUY_LIMIT if long_side else constants.ORDER_TYPE_SELL_LIMIT
        price = float(req["price"])
    order = {
        "action": action, "symbol": symbol_name, "volume": float(req["volume"]), "type": otype,
        "price": round_price(price, tick), "sl": round_price(float(req["stop_loss"]), tick),
        "deviation": max_deviation_points, "magic": 20261012, "comment": comment_for(req["request_id"]),
        "type_time": constants.ORDER_TIME_GTC, "type_filling": constants.ORDER_FILLING_IOC if req["order_type"] == "market" else constants.ORDER_FILLING_RETURN,
    }
    if req.get("take_profit"):
        order["tp"] = round_price(float(req["take_profit"]), tick)
    return order


def worse_than_reference(req: dict, bid: float, ask: float, tick_size: float, max_slippage_ticks: int = 30) -> bool:
    """For market orders: refuse when the live price is further from the approved reference price than the allowed slippage."""
    if req["order_type"] != "market":
        return False
    live = ask if req["side"] == "long" else bid
    adverse = (live - float(req["price"])) if req["side"] == "long" else (float(req["price"]) - live)
    return adverse > max_slippage_ticks * tick_size
