package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EnglishAppsTests {
    @Test fun parseAndSerializeRoundTrip() {
        assertEquals(emptySet<String>(), EnglishApps.parse(null))
        assertEquals(emptySet<String>(), EnglishApps.parse(" \n\n"))
        val apps = setOf("com.b.app", "com.a.app")
        assertEquals("com.a.app\ncom.b.app", EnglishApps.serialize(apps))
        assertEquals(apps, EnglishApps.parse(EnglishApps.serialize(apps)))
        assertEquals(setOf("x.y"), EnglishApps.parse(" x.y \n"))
    }

    @Test fun toggleAddsAndRemoves() {
        val a = EnglishApps.toggled(emptySet(), "com.a", true)
        assertEquals(setOf("com.a"), a)
        assertEquals(setOf("com.a"), EnglishApps.toggled(a, "com.a", true))
        assertEquals(emptySet<String>(), EnglishApps.toggled(a, "com.a", false))
    }

    @Test fun forcesOnlyListedAppsNeverItself() {
        val apps = setOf("com.term", "com.viettelex.android")
        assertTrue(EnglishApps.forces("com.term", apps, "com.viettelex.android"))
        assertFalse(EnglishApps.forces("com.chat", apps, "com.viettelex.android"))
        assertFalse("ô thử gõ trong app VietTelex", EnglishApps.forces("com.viettelex.android", apps, "com.viettelex.android"))
        assertFalse(EnglishApps.forces(null, apps))
        assertFalse(EnglishApps.forces("", apps))
    }
}
