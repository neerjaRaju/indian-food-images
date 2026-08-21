import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

/*
 * ============================================================
 * KEYSTORE
 * ============================================================
 */

val keystoreProperties = Properties()
val keystorePropertiesFile =
    rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use {
        keystoreProperties.load(it)
    }
}

/*
 * ============================================================
 * ANDROID
 * ============================================================
 */

android {
    namespace = "com.zrix.indian_food_calories"

    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    /*
     * Java 17
     */
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        isCoreLibraryDesugaringEnabled = true
    }

    /*
     * AGP 9 / Kotlin compilerOptions DSL
     */
    kotlin {
        compilerOptions {
            jvmTarget.set(
                JvmTarget.JVM_17
            )
        }
    }

    /*
     * ========================================================
     * DEFAULT CONFIG
     * ========================================================
     */

    defaultConfig {
        applicationId =
            "com.zrix.indian_food_calories"

        minSdk =
            flutter.minSdkVersion

        targetSdk =
            flutter.targetSdkVersion

        versionCode =
            flutter.versionCode

        versionName =
            flutter.versionName
    }

    /*
     * ========================================================
     * ANDROID RESOURCES
     * ========================================================
     */

    androidResources {
        localeFilters +=
            setOf(
                "en",
                "hi",
            )
    }

    /*
     * ========================================================
     * SIGNING
     * ========================================================
     */

    signingConfigs {
        create("release") {

            if (keystorePropertiesFile.exists()) {

                keyAlias =
                    keystoreProperties["keyAlias"]
                        ?.toString()

                keyPassword =
                    keystoreProperties["keyPassword"]
                        ?.toString()

                storePassword =
                    keystoreProperties["storePassword"]
                        ?.toString()

                val storeFilePath =
                    keystoreProperties["storeFile"]
                        ?.toString()

                if (!storeFilePath.isNullOrBlank()) {
                    storeFile =
                        file(storeFilePath)
                }
            }
        }
    }

    /*
     * ========================================================
     * BUILD TYPES
     * ========================================================
     */

    buildTypes {

        getByName("debug") {
            versionNameSuffix = "-debug"
        }

        getByName("release") {

            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }

            isMinifyEnabled = true
            isShrinkResources = true

            proguardFiles(
                getDefaultProguardFile(
                    "proguard-android-optimize.txt"
                ),
                "proguard-rules.pro",
            )
        }
    }

    /*
     * ========================================================
     * PACKAGING
     * ========================================================
     */

    packaging {
        resources {
            excludes +=
                setOf(
                    "META-INF/*.kotlin_module",
                    "META-INF/LICENSE*",
                    "META-INF/NOTICE*",
                    "DebugProbesKt.bin",
                )
        }

        jniLibs {
            useLegacyPackaging = true
        }
    }

    /*
     * ========================================================
     * APP BUNDLE
     * ========================================================
     */

    bundle {

        density {
            enableSplit = true
        }

        abi {
            enableSplit = true
        }

        language {
            enableSplit = false
        }
    }

    /*
     * ========================================================
     * LINT
     * ========================================================
     */

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

/*
 * ============================================================
 * FLUTTER
 * ============================================================
 */

flutter {
    source = "../.."
}

/*
 * ============================================================
 * DEPENDENCIES
 * ============================================================
 */

dependencies {

    coreLibraryDesugaring(
        "com.android.tools:desugar_jdk_libs:2.1.2"
    )
}