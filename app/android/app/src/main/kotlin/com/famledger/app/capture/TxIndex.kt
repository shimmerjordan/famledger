package com.famledger.app.capture

/**
 * captureId → 流水 id 映射的有序索引：按插入顺序只保留最新 [MAX] 条。
 * 纯函数、不碰 Android API，好单测；持久化格式是换行分隔（captureId 里没有换行）。
 */
object TxIndex {
    const val MAX = 300

    /** 把 [id] 放到末尾（已存在就先挪走），超过 [max] 时从最老的开始挤。返回 (新顺序, 被挤掉的)。 */
    fun push(order: List<String>, id: String, max: Int = MAX): Pair<List<String>, List<String>> {
        val next = ArrayList<String>(order.size + 1)
        for (x in order) if (x != id) next.add(x)
        next.add(id)
        val overflow = next.size - max
        if (overflow <= 0) return next to emptyList()
        return next.subList(overflow, next.size).toList() to next.subList(0, overflow).toList()
    }

    fun encode(order: List<String>): String = order.joinToString("\n")

    fun decode(raw: String?): List<String> =
        if (raw.isNullOrEmpty()) emptyList() else raw.split('\n').filter { it.isNotEmpty() }
}
