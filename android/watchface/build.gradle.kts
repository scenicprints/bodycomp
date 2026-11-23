import java.util.Properties
import java.io.FileInputStream

// ═══════════════════════════════════════════════════════════════════════
//  BodyComp — calorie-balance watch face (Watch Face Format).
//
//  A WFF face is a resource-only APK: no code at all (hasCode="false"), just
//  res/raw/watchface.xml plus a font and a preview image. It therefore has
//  to be its OWN package, separate from the :wear app. All of its numbers
//  come from CalorieComplicationService in :wear, so the two are installed
//  together.
//
//  res/raw/watchface.xml is generated — edit tools/gen_watchface.py.
// ═══════════════════════════════════════════════════════════════════════

plugins {
    id("com.android.application")
}

// Track the phone app's version from the root pubspec.yaml, like :wear.
val pubspecText = rootProject.file("../pubspec.yaml").readText()
val versionMatch =
    Regex("""(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)""").find(pubspecText)
val appVersionName = versionMatch?.groupValues?.get(1) ?: "1.0.0"
val appVersionCode = versionMatch?.groupValues?.get(2)?.toInt() ?: 1

// Same signing story as :app and :wear — key.properties is written by CI.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasSigning = keystorePropertiesFile.exists()

android {
    namespace = "com.scenicprints.bodycomp.watchface"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.scenicprints.bodycomp.watchface"
        minSdk = 33 // Watch Face Format v1 (Wear OS 4+)
        targetSdk = 34
        versionCode = appVersionCode
        versionName = appVersionName
    }

    signingConfigs {
        create("release") {
            if (hasSigning) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile =
                    rootProject.file("app/" + (keystoreProperties["storeFile"] as String))
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // As in Google's WFF samples: minify so no code is packaged, but
            // never shrink resources — the face IS its resources.
            isMinifyEnabled = true
            isShrinkResources = false
        }
    }
}
