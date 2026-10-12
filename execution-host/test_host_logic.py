import unittest
from types import SimpleNamespace as NS

import host_logic as h

SPEC = {"contract_size": 1000, "tick_size": 0.001, "tick_value": 0.0064, "volume_min": 0.01, "volume_step": 0.01, "volume_max": 100}
C = NS(TRADE_ACTION_DEAL=1, TRADE_ACTION_PENDING=5, ORDER_TYPE_BUY=0, ORDER_TYPE_SELL=1, ORDER_TYPE_BUY_LIMIT=2, ORDER_TYPE_SELL_LIMIT=3,
       ORDER_TIME_GTC=0, ORDER_FILLING_IOC=1, ORDER_FILLING_RETURN=2)
REQ = {"request_id": "123e4567-e89b-12d3-a456-426614174000", "symbol": "USDJPY", "side": "long", "volume": 0.04, "order_type": "limit", "price": 150.1, "stop_loss": 149.6, "take_profit": 151.0}


class Logic(unittest.TestCase):
    def test_comment_fits_mt5_limit(self):
        self.assertLessEqual(len(h.comment_for(REQ["request_id"])), 31)

    def test_volume_rules(self):
        self.assertTrue(h.volume_ok(0.04, SPEC))
        self.assertFalse(h.volume_ok(0.005, SPEC))   # below minimum
        self.assertFalse(h.volume_ok(0.055, SPEC))   # off the step
        self.assertFalse(h.volume_ok(101, SPEC))     # above maximum

    def test_valid_request_has_no_problems(self):
        self.assertEqual(h.validate_request(REQ, SPEC), [])

    def test_missing_stop_is_refused(self):
        self.assertIn("stop loss is mandatory", h.validate_request({**REQ, "stop_loss": None}, SPEC))

    def test_stop_on_wrong_side_is_refused(self):
        self.assertTrue(h.validate_request({**REQ, "stop_loss": 150.5}, SPEC))
        self.assertTrue(h.validate_request({**REQ, "side": "short", "stop_loss": 149.0}, SPEC))

    def test_unsupported_order_type_is_refused(self):
        self.assertTrue(h.validate_request({**REQ, "order_type": "stop"}, SPEC))

    def test_limit_order_build(self):
        o = h.build_order(REQ, SPEC, "USDJPYc", 150.09, 150.11, C)
        self.assertEqual(o["action"], C.TRADE_ACTION_PENDING)
        self.assertEqual(o["type"], C.ORDER_TYPE_BUY_LIMIT)
        self.assertEqual(o["price"], 150.1)
        self.assertEqual(o["sl"], 149.6)
        self.assertEqual(o["symbol"], "USDJPYc")

    def test_market_order_uses_ask_for_long_and_bid_for_short(self):
        m = {**REQ, "order_type": "market"}
        self.assertEqual(h.build_order(m, SPEC, "X", 150.09, 150.11, C)["price"], 150.11)
        s = {**m, "side": "short", "stop_loss": 150.6, "take_profit": 149.0}
        self.assertEqual(h.build_order(s, SPEC, "X", 150.09, 150.11, C)["price"], 150.09)

    def test_slippage_guard(self):
        m = {**REQ, "order_type": "market"}
        self.assertFalse(h.worse_than_reference(m, 150.09, 150.11, 0.001))
        self.assertTrue(h.worse_than_reference(m, 150.30, 150.35, 0.001))
        self.assertFalse(h.worse_than_reference(REQ, 1, 1, 0.001))   # limit orders are not slippage-checked

    def test_spec_from_symbol_info(self):
        info = NS(trade_contract_size=1000, trade_tick_size=0.001, trade_tick_value=0.0064, volume_min=0.01, volume_step=0.01, volume_max=100)
        s = h.spec_from_symbol_info("USDJPY", info, "USC")
        self.assertEqual((s["symbol"], s["volume_min"], s["account_currency"]), ("USDJPY", 0.01, "USC"))


if __name__ == "__main__":
    unittest.main()
