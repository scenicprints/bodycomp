import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing config from android/key.properties if present.
// Locally this points at upload-keystore.jks; in CI the workflow writes
// this file (and decodes the keystore) from encrypted secrets.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasSigning = keystorePropertiesFile.exists()

android {
    namespace = "com.scenicprints.bodycomp"
    // mobile_scanner 7.x requires compileSdk 36 / minSdk 23 — pin explicitly
    // so the build doesn't depend on the Flutter SDK's defaults.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by the ota_update plugin
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.scenicprints.bodycomp"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasSigning) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the persistent upload key when available so installed
            // apps can update in place. Falls back to debug for local `flutter run`.
            signingConfig = if (hasSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Don't shrink/obfuscate — ML Kit (barcode scanner) breaks when its
            // reflection-loaded classes are stripped. Keep rules are kept too,
            // in case shrinking is ever turned back on.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backport of newer Java APIs the ota_update plugin relies on
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
