#!/usr/bin/env python3
"""
Schema validation harness for [DATABASE_NAME].

Executes db/schema.sql against an in-memory SQLite database and asserts that the
integrity rules the design depends on are actually enforced by the storage layer
-- not merely by application code.

This is a design-verification tool, not application source. Run it in CI on every
change to schema.sql so a migration cannot silently drop a constraint.

    python3 db/validate_schema.py

Requires SQLite >= 3.8.0 (partial indices). Android API 21+ ships 3.8.6+.
"""

import os
import sqlite3
import sys

SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")
T = 1_700_000_000_000  # fixed epoch-millis timestamp for determinism

results = []


def check(label, fn, expect_fail=False):
    """Run fn; record whether its success/failure matched expectations."""
    try:
        fn()
        ok = not expect_fail
        detail = "" if ok else "expected rejection, but the write succeeded"
    except sqlite3.Error as exc:
        ok = expect_fail
        detail = "" if ok else str(exc)
    results.append((label, ok, detail))


def main():
    con = sqlite3.connect(":memory:")
    con.executescript(open(SCHEMA).read())
    con.execute("PRAGMA foreign_keys = ON")
    x = lambda sql, *a: con.execute(sql, a)

    # ---- fixtures ---------------------------------------------------------
    x("INSERT INTO users(id,phone_number,created_at,updated_at) VALUES(1,'+919876543210',?,?)", T, T)
    x("INSERT INTO addresses(id,user_id,line1,city,postal_code,is_default,created_at,updated_at)"
      " VALUES(1,1,'221B Baker St','London','NW1',1,?,?)", T, T)
    for rid, name in ((1, "Tandoori Hut"), (2, "Sushi Co")):
        x("INSERT INTO restaurants(id,remote_id,name,cached_at,created_at,updated_at)"
          " VALUES(?,?,?,?,?,?)", rid, f"r{rid}", name, T, T, T)
    x("INSERT INTO menu_categories(id,remote_id,restaurant_id,name) VALUES(1,'c1',1,'Starters')")
    x("INSERT INTO menu_items(id,remote_id,restaurant_id,category_id,name,base_price,created_at,updated_at)"
      " VALUES(1,'m1',1,1,'Paneer Tikka',28000,?,?)", T, T)

    # ---- MULTI-CART INVARIANTS -------------------------------------------
    check("carts: parallel carts across different restaurants are allowed", lambda: (
        x("INSERT INTO carts(id,user_id,restaurant_id,created_at,updated_at) VALUES(1,1,1,?,?)", T, T),
        x("INSERT INTO carts(id,user_id,restaurant_id,created_at,updated_at) VALUES(2,1,2,?,?)", T, T)))

    check("carts: a second OPEN cart for the same restaurant is rejected", lambda:
          x("INSERT INTO carts(id,user_id,restaurant_id,created_at,updated_at) VALUES(3,1,1,?,?)", T, T),
          expect_fail=True)

    x("INSERT INTO cart_items(cart_id,menu_item_id,quantity,unit_base_price,unit_options_price,"
      "config_signature,created_at,updated_at) VALUES(1,1,2,28000,4000,'sig-a',?,?)", T, T)

    check("cart_items: an identical item configuration cannot be duplicated", lambda:
          x("INSERT INTO cart_items(cart_id,menu_item_id,quantity,unit_base_price,unit_options_price,"
            "config_signature,created_at,updated_at) VALUES(1,1,1,28000,4000,'sig-a',?,?)", T, T),
          expect_fail=True)

    row = x("SELECT total_quantity,item_total FROM v_cart_summary WHERE cart_id=1").fetchone()
    results.append(("v_cart_summary: aggregates quantity and item total correctly",
                    row == (2, 64000), f"got {row}"))

    # ---- ORDER INTEGRITY --------------------------------------------------
    check("orders: a bill whose lines do not sum to grand_total is rejected", lambda:
          x("INSERT INTO orders(id,user_id,restaurant_id,address_id,restaurant_name,"
            "delivery_address_snapshot,item_total,delivery_fee,tax_amount,grand_total,"
            "placed_at,idempotency_key,created_at,updated_at)"
            " VALUES(99,1,1,1,'Tandoori Hut','221B',56000,3000,4200,99999,?,'idem-bad',?,?)", T, T, T),
          expect_fail=True)

    x("INSERT INTO orders(id,user_id,restaurant_id,address_id,restaurant_name,"
      "delivery_address_snapshot,item_total,delivery_fee,tax_amount,discount_amount,grand_total,"
      "expected_delivery_at,placed_at,idempotency_key,created_at,updated_at)"
      " VALUES(1,1,1,1,'Tandoori Hut','221B',56000,3000,4200,5000,58200,?,?,'idem-1',?,?)",
      T + 1_680_000, T, T, T)

    check("orders: a replayed idempotency_key cannot create a duplicate order", lambda:
          x("INSERT INTO orders(id,user_id,restaurant_id,restaurant_name,delivery_address_snapshot,"
            "item_total,grand_total,placed_at,idempotency_key,created_at,updated_at)"
            " VALUES(2,1,1,'T','x',100,100,?,'idem-1',?,?)", T, T, T),
          expect_fail=True)

    check("order_items: line_total must equal (base + options) * quantity", lambda:
          x("INSERT INTO order_items(order_id,item_name,quantity,unit_base_price,"
            "unit_options_price,line_total) VALUES(1,'X',2,1000,100,9999)"),
          expect_fail=True)

    # ---- STATE MACHINE ----------------------------------------------------
    x("UPDATE orders SET status='CONFIRMED' WHERE id=1")
    x("UPDATE orders SET status='PREPARING'  WHERE id=1")
    n = x("SELECT COUNT(*) FROM order_status_history WHERE order_id=1").fetchone()[0]
    results.append(("order_status_history: every transition is audited automatically",
                    n == 2, f"expected 2 rows, got {n}"))

    # ---- PAYMENT / COD ----------------------------------------------------
    x("INSERT INTO payments(id,order_id,method,amount,status,initiated_at,created_at,updated_at)"
      " VALUES(1,1,'CASH',58200,'AWAITING_COLLECTION',?,?,?)", T, T, T)

    check("payments: an order cannot hold two live payment attempts", lambda:
          x("INSERT INTO payments(id,order_id,method,amount,status,initiated_at,created_at,updated_at)"
            " VALUES(2,1,'UPI',58200,'PENDING',?,?,?)", T, T, T),
          expect_fail=True)

    x("INSERT INTO cash_collections(id,payment_id,order_id,amount_due,created_at,updated_at)"
      " VALUES(1,1,1,58200,?,?)", T, T)

    check("cash_collections: cash cannot be collected before the order is dispatched", lambda:
          x("UPDATE cash_collections SET collection_status='COLLECTED',amount_collected=58200 WHERE id=1"),
          expect_fail=True)

    x("UPDATE orders SET status='READY_FOR_PICKUP'  WHERE id=1")
    x("UPDATE orders SET status='OUT_FOR_DELIVERY' WHERE id=1")

    check("cash_collections: collection succeeds once out for delivery", lambda:
          x("UPDATE cash_collections SET collection_status='COLLECTED',amount_collected=60000,"
            "change_returned=1800 WHERE id=1"))

    row = x("SELECT status,payment_method,cash_amount_due,item_count"
            " FROM v_active_orders WHERE order_id=1").fetchone()
    results.append(("v_active_orders: joins live payment and cash posture onto the order",
                    row is not None and row[0] == "OUT_FOR_DELIVERY"
                    and row[1] == "CASH" and row[2] == 58200, f"got {row}"))

    # ---- TERMINAL STATES --------------------------------------------------
    x("UPDATE orders SET status='DELIVERED' WHERE id=1")
    check("orders: a terminal order cannot regress to an earlier status", lambda:
          x("UPDATE orders SET status='PREPARING' WHERE id=1"),
          expect_fail=True)

    n = x("SELECT COUNT(*) FROM v_active_orders").fetchone()[0]
    results.append(("v_active_orders: a delivered order drops out of the active set",
                    n == 0, f"expected 0, got {n}"))

    # ---- ADDRESSES --------------------------------------------------------
    check("addresses: a user cannot have two default addresses", lambda:
          x("INSERT INTO addresses(user_id,line1,city,postal_code,is_default,created_at,updated_at)"
            " VALUES(1,'2 Elm','London','E1',1,?,?)", T, T),
          expect_fail=True)

    # ---- report -----------------------------------------------------------
    width = max(len(label) for label, _, _ in results)
    for label, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        line = f"  {label:<{width}}  {status}"
        if not ok and detail:
            line += f"\n      -> {detail}"
        print(line)

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n  {passed}/{len(results)} invariants enforced by the schema")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
