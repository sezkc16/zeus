package com.lagradost.cloudstream3.plugins

import java.lang.reflect.Modifier
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * ABI guard for Compose-built plugins (Phisher's Cinefreak/Comix): their dex
 * reads `Plugin.$stable` from the superclass static initializer, so the field
 * must exist on `Plugin` itself as a public static final int. The engine
 * applies no Compose compiler plugin, so the field is declared manually in
 * [Plugin]'s companion object with `@JvmField` (value 8 = Unstable: the
 * class has mutable properties, so 0 would falsely describe it as stable).
 *
 * If the Compose compiler plugin is ever enabled on the engine build, this
 * manual field must go first — two `$stable` fields on one class is a
 * duplicate-field compile error.
 */
class PluginCompatibilityTest {
    @Test
    fun pluginHasStableField() {
        val field = Plugin::class.java.getDeclaredField("\$stable")
        assertEquals(Int::class.javaPrimitiveType, field.type)
        assertTrue(Modifier.isPublic(field.modifiers), "\$stable must be public")
        assertTrue(Modifier.isStatic(field.modifiers), "\$stable must be static")
        assertTrue(Modifier.isFinal(field.modifiers), "\$stable must be final")
        assertEquals(8, field.getInt(null))
    }
}
