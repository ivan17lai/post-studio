import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Android refuses to replace an installed app unless the new APK carries the
// same signature, and the default debug key is generated per machine. That made
// a build from one computer impossible to install over a build from another,
// and made every CI run produce a mutually incompatible APK.
//
// So every build signs with keystore/dev.jks, which is committed on purpose:
// sharing it is what lets any machine — or CI — produce an APK that upgrades
// the ones built elsewhere. It signs development and test builds only.
//
// For a Play release, drop an upload key at android/key.properties (ignored by
// git, see android/.gitignore) with storeFile/storePassword/keyAlias/keyPassword
// entries; release builds then use it in place of the shared key.
val uploadKeyProperties =
    Properties().apply {
        val propertiesFile = rootProject.file("key.properties")
        if (propertiesFile.exists()) {
            FileInputStream(propertiesFile).use { load(it) }
        }
    }
val hasUploadKey = uploadKeyProperties.getProperty("storeFile") != null

android {
    namespace = "com.igapp.igapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.igapp.igapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake { cppFlags += "-std=c++17" }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("dev") {
            storeFile = rootProject.file("keystore/dev.jks")
            storeType = "PKCS12"
            storePassword = "poststudiodev"
            keyAlias = "dev"
            keyPassword = "poststudiodev"
        }

        if (hasUploadKey) {
            create("upload") {
                storeFile = rootProject.file(uploadKeyProperties.getProperty("storeFile"))
                storeType = uploadKeyProperties.getProperty("storeType") ?: "PKCS12"
                storePassword = uploadKeyProperties.getProperty("storePassword")
                keyAlias = uploadKeyProperties.getProperty("keyAlias")
                keyPassword = uploadKeyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("dev")
        }
        release {
            signingConfig = signingConfigs.getByName(if (hasUploadKey) "upload" else "dev")
        }
    }
}

flutter {
    source = "../.."
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
