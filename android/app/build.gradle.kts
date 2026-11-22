import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun Map<*, *>.section(key: String): Map<*, *> = get(key) as? Map<*, *> ?: emptyMap<Any, Any>()

android {
    namespace = "net.icycloud.fdtodolist"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "net.icycloud.fdtodolist"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        val firebaseConfig = file("google-services.json")
        if (firebaseConfig.isFile) {
            val config = JsonSlurper().parse(firebaseConfig) as Map<*, *>
            val project = config.section("project_info")
            val client = (config["client"] as List<*>).filterIsInstance<Map<*, *>>().firstOrNull {
                it.section("client_info").section("android_client_info")["package_name"] == applicationId
            } ?: error("google-services.json 缺少 ${applicationId} 的 Android 配置")
            val apiKey = (client["api_key"] as List<*>).filterIsInstance<Map<*, *>>().first()["current_key"]
            resValue("string", "google_app_id", client.section("client_info")["mobilesdk_app_id"].toString())
            resValue("string", "gcm_defaultSenderId", project["project_number"].toString())
            resValue("string", "project_id", project["project_id"].toString())
            resValue("string", "google_api_key", apiKey.toString())
        }
    }

    val signingPath = System.getenv("GXTODO_KEYSTORE")
    if (signingPath != null) {
        signingConfigs.create("release") {
            storeFile = file(signingPath)
            storePassword = System.getenv("GXTODO_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("GXTODO_KEY_ALIAS")
            keyPassword = System.getenv("GXTODO_KEY_PASSWORD")
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("release")
    }
}

dependencies {
    implementation("com.google.firebase:firebase-messaging:24.1.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
