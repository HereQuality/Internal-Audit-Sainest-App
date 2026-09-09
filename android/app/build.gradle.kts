import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // FCM push (fcm_service.dart) — reads android/app/google-services.json
    // (gitignored, see NOTIFICATIONS.md's "FCM push setup"); this plugin
    // is what generates the resources firebase_core/firebase_messaging
    // read at runtime from it. A build with the file missing fails loudly
    // at Gradle sync, not silently — see that same doc section before
    // touching this if the file is ever absent again.
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config, loaded from android/key.properties (gitignored —
// see https://flutter.dev/to/reference-keystore). Falls back to no release
// signing config present if the file hasn't been generated yet, so debug
// builds/CI checkouts without the keystore still configure.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.hqepl.audit360"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications' exact-alarm scheduling path uses
        // java.time APIs that need desugaring below API 26.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.hqepl.audit360"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_local_notifications 18.x / android_alarm_manager_plus need
        // 23+ (flutter.minSdkVersion alone may be lower on older Flutter defaults).
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Renames the built APK from Flutter's default app-<buildType>.apk to
// Q_Audit360-<buildType>.apk (e.g. Q_Audit360-release.apk). outputFileName
// is only exposed on the internal VariantOutputImpl, not the public
// VariantOutput interface, hence the cast.
androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            (output as com.android.build.api.variant.impl.VariantOutputImpl)
                .outputFileName.set("Q_Audit360-${variant.buildType}.apk")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
