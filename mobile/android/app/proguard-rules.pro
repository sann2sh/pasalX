# Flutter & native JNI hooks
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# SQLCipher / sqlite3 native bindings
-keep class net.zetetic.** { *; }
-keep class org.sqlite.** { *; }
-dontwarn net.zetetic.**
-dontwarn org.sqlite.**

# flutter_secure_storage & Google Tink
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# mobile_scanner / ML Kit barcode scanning
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.mlkit_vision_barcode.**

# Flutter deferred components (not used)
-dontwarn com.google.android.play.core.**

