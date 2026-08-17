package blueprint.verification

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.sql.Connection
import java.sql.SQLException
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull

/**
 * Executes db/schema.sql and asserts that the integrity rules the design
 * depends on are enforced by SQLite itself, rather than by application code.
 *
 * A rule that only lives in a repository method can be bypassed by the next
 * repository method someone writes. These tests exist so that a migration
 * cannot quietly drop a constraint without failing the build.
 */
@DisplayName("Schema invariants")
class SchemaInvariantsTest {

    private lateinit var db: Connection

    /** Fixed epoch-millis timestamp, so results do not depend on the clock. */
    private val t = 1_700_000_000_000L

    @BeforeEach
    fun setUp() {
        db = SqliteScript.openSchemaDatabase()
        seedCatalog()
    }

    @AfterEach
    fun tearDown() = db.close()

    // ---------------------------------------------------------------- fixtures

    private fun exec(sql: String) = db.createStatement().use { it.executeUpdate(sql) }

    private fun <T> queryOne(sql: String, read: (java.sql.ResultSet) -> T): T =
        db.createStatement().use { statement ->
            statement.executeQuery(sql).use { rs ->
                check(rs.next()) { "Query returned no rows: $sql" }
                read(rs)
            }
        }

    private fun seedCatalog() {
        exec("INSERT INTO users(id,phone_number,created_at,updated_at) VALUES(1,'+919876543210',$t,$t)")
        exec(
            "INSERT INTO addresses(id,user_id,line1,city,postal_code,is_default,created_at,updated_at) " +
                "VALUES(1,1,'221B Baker St','London','NW1',1,$t,$t)"
        )
        exec("INSERT INTO restaurants(id,remote_id,name,cached_at,created_at,updated_at) VALUES(1,'r1','Tandoori Hut',$t,$t,$t)")
        exec("INSERT INTO restaurants(id,remote_id,name,cached_at,created_at,updated_at) VALUES(2,'r2','Sushi Co',$t,$t,$t)")
        exec("INSERT INTO menu_categories(id,remote_id,restaurant_id,name) VALUES(1,'c1',1,'Starters')")
        exec(
            "INSERT INTO menu_items(id,remote_id,restaurant_id,category_id,name,base_price,created_at,updated_at) " +
                "VALUES(1,'m1',1,1,'Paneer Tikka',28000,$t,$t)"
        )
    }

    private fun openCart(id: Int, restaurantId: Int) =
        exec("INSERT INTO carts(id,user_id,restaurant_id,created_at,updated_at) VALUES($id,1,$restaurantId,$t,$t)")

    private fun placeOrder() = exec(
        "INSERT INTO orders(id,user_id,restaurant_id,address_id,restaurant_name,delivery_address_snapshot," +
            "item_total,delivery_fee,tax_amount,discount_amount,grand_total,expected_delivery_at," +
            "placed_at,idempotency_key,created_at,updated_at) " +
            "VALUES(1,1,1,1,'Tandoori Hut','221B',56000,3000,4200,5000,58200,${t + 1_680_000},$t,'idem-1',$t,$t)"
    )

    private fun awaitCashCollection() {
        exec(
            "INSERT INTO payments(id,order_id,method,amount,status,initiated_at,created_at,updated_at) " +
                "VALUES(1,1,'CASH',58200,'AWAITING_COLLECTION',$t,$t,$t)"
        )
        exec("INSERT INTO cash_collections(id,payment_id,order_id,amount_due,created_at,updated_at) VALUES(1,1,1,58200,$t,$t)")
    }

    private fun dispatchOrder() {
        exec("UPDATE orders SET status='CONFIRMED'        WHERE id=1")
        exec("UPDATE orders SET status='PREPARING'        WHERE id=1")
        exec("UPDATE orders SET status='READY_FOR_PICKUP' WHERE id=1")
        exec("UPDATE orders SET status='OUT_FOR_DELIVERY' WHERE id=1")
    }

    // ------------------------------------------------------------- multi-cart

    @Test
    @DisplayName("parallel carts across different restaurants are allowed")
    fun parallelCartsAllowed() {
        openCart(id = 1, restaurantId = 1)
        openCart(id = 2, restaurantId = 2)

        val openCarts = queryOne("SELECT COUNT(*) FROM carts WHERE status='OPEN'") { it.getInt(1) }
        assertEquals(2, openCarts, "a user must be able to hold one cart per restaurant simultaneously")
    }

    @Test
    @DisplayName("a second OPEN cart for the same restaurant is rejected")
    fun duplicateOpenCartRejected() {
        openCart(id = 1, restaurantId = 1)
        assertFailsWith<SQLException> { openCart(id = 3, restaurantId = 1) }
    }

    @Test
    @DisplayName("an identical item configuration cannot be duplicated within a cart")
    fun duplicateConfigSignatureRejected() {
        openCart(id = 1, restaurantId = 1)
        val insert =
            "INSERT INTO cart_items(cart_id,menu_item_id,quantity,unit_base_price,unit_options_price," +
                "config_signature,created_at,updated_at) VALUES(1,1,2,28000,4000,'sig-a',$t,$t)"
        exec(insert)
        assertFailsWith<SQLException> { exec(insert) }
    }

    @Test
    @DisplayName("v_cart_summary aggregates quantity and item total correctly")
    fun cartSummaryAggregates() {
        openCart(id = 1, restaurantId = 1)
        exec(
            "INSERT INTO cart_items(cart_id,menu_item_id,quantity,unit_base_price,unit_options_price," +
                "config_signature,created_at,updated_at) VALUES(1,1,2,28000,4000,'sig-a',$t,$t)"
        )

        val (quantity, itemTotal) = queryOne(
            "SELECT total_quantity,item_total FROM v_cart_summary WHERE cart_id=1"
        ) { it.getInt(1) to it.getInt(2) }

        assertEquals(2, quantity)
        assertEquals(64000, itemTotal, "(28000 base + 4000 options) * 2")
    }

    // ---------------------------------------------------------- order integrity

    @Test
    @DisplayName("a bill whose lines do not sum to grand_total is rejected")
    fun billMustBalance() {
        assertFailsWith<SQLException> {
            exec(
                "INSERT INTO orders(id,user_id,restaurant_id,address_id,restaurant_name,delivery_address_snapshot," +
                    "item_total,delivery_fee,tax_amount,grand_total,placed_at,idempotency_key,created_at,updated_at) " +
                    "VALUES(99,1,1,1,'Tandoori Hut','221B',56000,3000,4200,99999,$t,'idem-bad',$t,$t)"
            )
        }
    }

    @Test
    @DisplayName("a replayed idempotency_key cannot create a duplicate order")
    fun idempotencyKeyIsUnique() {
        placeOrder()
        assertFailsWith<SQLException> {
            exec(
                "INSERT INTO orders(id,user_id,restaurant_id,restaurant_name,delivery_address_snapshot," +
                    "item_total,grand_total,placed_at,idempotency_key,created_at,updated_at) " +
                    "VALUES(2,1,1,'T','x',100,100,$t,'idem-1',$t,$t)"
            )
        }
    }

    @Test
    @DisplayName("line_total must equal (base + options) * quantity")
    fun lineTotalArithmeticEnforced() {
        placeOrder()
        assertFailsWith<SQLException> {
            exec(
                "INSERT INTO order_items(order_id,item_name,quantity,unit_base_price,unit_options_price,line_total) " +
                    "VALUES(1,'X',2,1000,100,9999)"
            )
        }
    }

    @Test
    @DisplayName("every status transition is audited automatically")
    fun statusTransitionsAreAudited() {
        placeOrder()
        exec("UPDATE orders SET status='CONFIRMED' WHERE id=1")
        exec("UPDATE orders SET status='PREPARING' WHERE id=1")

        val rows = queryOne("SELECT COUNT(*) FROM order_status_history WHERE order_id=1") { it.getInt(1) }
        assertEquals(2, rows, "the audit trigger must record each accepted transition")
    }

    // -------------------------------------------------------------- payments

    @Test
    @DisplayName("an order cannot hold two live payment attempts")
    fun singleLivePaymentAttempt() {
        placeOrder()
        awaitCashCollection()
        assertFailsWith<SQLException> {
            exec(
                "INSERT INTO payments(id,order_id,method,amount,status,initiated_at,created_at,updated_at) " +
                    "VALUES(2,1,'UPI',58200,'PENDING',$t,$t,$t)"
            )
        }
    }

    @Test
    @DisplayName("cash cannot be collected before the order is dispatched")
    fun cashRequiresDispatch() {
        placeOrder()
        awaitCashCollection()
        exec("UPDATE orders SET status='CONFIRMED' WHERE id=1")
        exec("UPDATE orders SET status='PREPARING' WHERE id=1")

        assertFailsWith<SQLException> {
            exec("UPDATE cash_collections SET collection_status='COLLECTED',amount_collected=58200 WHERE id=1")
        }
    }

    @Test
    @DisplayName("cash collection succeeds once the order is out for delivery")
    fun cashCollectedAfterDispatch() {
        placeOrder()
        awaitCashCollection()
        dispatchOrder()

        exec(
            "UPDATE cash_collections SET collection_status='COLLECTED',amount_collected=60000," +
                "change_returned=1800 WHERE id=1"
        )

        val status = queryOne("SELECT collection_status FROM cash_collections WHERE id=1") { it.getString(1) }
        assertEquals("COLLECTED", status)
    }

    @Test
    @DisplayName("v_active_orders joins live payment and cash posture onto the order")
    fun activeOrderProjection() {
        placeOrder()
        awaitCashCollection()
        dispatchOrder()

        val row = queryOne(
            "SELECT status,payment_method,cash_amount_due FROM v_active_orders WHERE order_id=1"
        ) { Triple(it.getString(1), it.getString(2), it.getInt(3)) }

        assertNotNull(row)
        assertEquals("OUT_FOR_DELIVERY", row.first)
        assertEquals("CASH", row.second)
        assertEquals(58200, row.third)
    }

    // -------------------------------------------------------- terminal states

    @Test
    @DisplayName("a terminal order cannot regress to an earlier status")
    fun terminalOrdersAreFrozen() {
        placeOrder()
        dispatchOrder()
        exec("UPDATE orders SET status='DELIVERED' WHERE id=1")

        assertFailsWith<SQLException> { exec("UPDATE orders SET status='PREPARING' WHERE id=1") }
    }

    @Test
    @DisplayName("a delivered order drops out of the active set")
    fun deliveredOrderLeavesActiveView() {
        placeOrder()
        dispatchOrder()
        exec("UPDATE orders SET status='DELIVERED' WHERE id=1")

        val active = queryOne("SELECT COUNT(*) FROM v_active_orders") { it.getInt(1) }
        assertEquals(0, active)
    }

    // ------------------------------------------------------------- addresses

    @Test
    @DisplayName("a user cannot have two default addresses")
    fun singleDefaultAddress() {
        assertFailsWith<SQLException> {
            exec(
                "INSERT INTO addresses(user_id,line1,city,postal_code,is_default,created_at,updated_at) " +
                    "VALUES(1,'2 Elm','London','E1',1,$t,$t)"
            )
        }
    }
}
