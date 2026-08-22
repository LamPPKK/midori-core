package io.github.lamppkk.xanhbrowser.lite.webkit

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.wpewebkit.wpeview.WPEView

@RunWith(AndroidJUnit4::class)
class WpeForkApiContractTest {
    @Test
    fun sourceForkExposesReviewedIsolatedBridgeApi() {
        assumeTrue(BuildConfig.XANH_WPE_SOURCE_FORK)
        val callback = Class.forName(
            "org.wpewebkit.wpeview.WPEView\$IsolatedScriptMessageCallback",
        )
        val resultCallback = Class.forName("org.wpewebkit.wpeview.WPECallback")
        val type = WPEView::class.java

        assertEquals(
            Boolean::class.javaPrimitiveType,
            type.getMethod(
                "installIsolatedBridge",
                String::class.java,
                String::class.java,
                String::class.java,
                callback,
            ).returnType,
        )
        assertEquals(
            Void.TYPE,
            type.getMethod("removeIsolatedBridge").returnType,
        )
        assertEquals(
            Void.TYPE,
            type.getMethod(
                "callIsolatedJavascriptFunction",
                String::class.java,
                Map::class.java,
                String::class.java,
                resultCallback,
            ).returnType,
        )
    }
}
