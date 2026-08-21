# ---------------------------------------------------------------------------
# Indian Food Calories — R8 / ProGuard rules
# ---------------------------------------------------------------------------

# Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Google Mobile Ads
-keep class com.google.android.gms.ads.** { *; }
-keep public class com.google.android.gms.ads.MobileAds { public *; }
-dontwarn com.google.android.gms.**

# Play Core / deferred components are referenced by the engine but not used
# here; silence the warnings rather than pulling the library in.
-dontwarn com.google.android.play.core.**

# ML Kit barcode scanning (mobile_scanner)
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# sqflite
-keep class com.tekartik.sqflite.** { *; }

# Keep annotations used for reflection by several plugins
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Crash reports stay readable
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
