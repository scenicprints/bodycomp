# Keep Google ML Kit (used by mobile_scanner for barcode scanning).
# Without these, R8 can strip classes ML Kit loads via reflection, causing
# a "null object reference" crash when the scanner starts.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-dontwarn com.google.mlkit.**

# mobile_scanner plugin
-keep class dev.steenbakker.mobile_scanner.** { *; }
