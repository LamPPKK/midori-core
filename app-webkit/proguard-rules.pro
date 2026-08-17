# WPEView initializes Java and native entry points by class name in auxiliary
# processes. Keep the bridge and generated service classes intact.
-keep class org.wpewebkit.** { *; }
-keep class org.freedesktop.gstreamer.** { *; }
