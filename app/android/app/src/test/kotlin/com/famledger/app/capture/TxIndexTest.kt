package com.famledger.app.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class TxIndexTest {
    @Test
    fun `push appends and moves an existing id to the end`() {
        val (order, evicted) = TxIndex.push(listOf("a", "b", "c"), "b", max = 10)
        assertEquals(listOf("a", "c", "b"), order)
        assertEquals(emptyList<String>(), evicted)
    }

    @Test
    fun `push evicts the oldest beyond max`() {
        var order = emptyList<String>()
        val evictedAll = ArrayList<String>()
        for (i in 0 until 305) {
            val (next, evicted) = TxIndex.push(order, "cap-$i")
            order = next
            evictedAll += evicted
        }
        assertEquals(TxIndex.MAX, order.size)
        assertEquals("cap-5", order.first())
        assertEquals("cap-304", order.last())
        assertEquals((0 until 5).map { "cap-$it" }, evictedAll)
    }

    @Test
    fun `encode and decode round trip, garbage decodes to empty`() {
        val order = listOf("cap-1", "cap-2")
        assertEquals(order, TxIndex.decode(TxIndex.encode(order)))
        assertEquals(emptyList<String>(), TxIndex.decode(null))
        assertEquals(emptyList<String>(), TxIndex.decode(""))
        assertEquals(listOf("x"), TxIndex.decode("\nx\n"))
    }
}
