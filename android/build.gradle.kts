allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// The health 13.x plugin pulls androidx.health.connect:connect-client alpha,
// which demands a newer compileSdk than some plugin modules declare (they sit
// at android-34). Force the plugin modules to compile against our SDK 36 so
// the AAR-metadata check passes. Skip ":app" — it is already on 36 AND has
// been eagerly evaluated by the evaluationDependsOn line above, so registering
// an afterEvaluate on it would throw.
subprojects {
    if (name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android")
            if (androidExt is com.android.build.gradle.BaseExtension) {
                androidExt.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
