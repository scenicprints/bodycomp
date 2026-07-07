import java.util.Properties
import java.io.FileInputStream

// ═══════════════════════════════════════════════════════════════════════
//  BodyComp — Wear OS companion app (standalone, native Android Views).
//
//  Shows the live coached run (phase, countdown, Pause/Stop) on a Pixel
//  Watch. Talks to the phone over the Wearable Data Layer, so it MUST share
//  the phone app's applicationId AND be signed with the SAME key.
// ═══════════════════════════════════════════════════════════════════════

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Track the phone app's version straight from the root pubspec.yaml so the
// two stay in lock-step (Wear pairing prefers matching version codes).
val pubspecText = rootProject.file("../pubspec.yaml").readText()
val versionMatch =
    Regex("""(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)""").find(pubspecText)
val appVersionName = versionMatch?.groupValues?.get(1) ?: "1.0.0"
val appVersionCode = versionMatch?.groupValues?.get(2)?.toInt() ?: 1

// Same signing story as :app — key.properties is written by CI from secrets.
// The keystore lives under app/, so resolve it there (not under wear/).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasSigning = keystorePropertiesFile.exists()

android {
    namespace = "com.scenicprints.bodycomp.wear"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // MUST match the phone app for the Data Layer to pair the two.
        applicationId = "com.scenicprints.bodycomp"
        minSdk = 30 // Wear OS 3+ (Pixel Watch)
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
            // Sign with the SAME upload key as the phone app when available, so
            // the two apps are recognised as a pair by the Wearable Data Layer.
            signingConfig = if (hasSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    // Wearable Data Layer (MessageClient / NodeClient).
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
}
