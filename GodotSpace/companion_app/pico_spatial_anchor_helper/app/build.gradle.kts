plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

val removeGodotImportSidecars by tasks.registering(Delete::class) {
    delete(
        fileTree("src/main/res") {
            include("mipmap-*/*.webp.import")
        },
        fileTree("build") {
            include("**/mipmap-*/*.webp.import")
        },
    )
}

tasks.named("preBuild") {
    dependsOn(removeGodotImportSidecars)
}

android {
    namespace = "com.picospatialanchor.helper"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.picospatialanchor.helper"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
}

dependencies {
    implementation(files("libs/capturelib-release.aar"))
    implementation(files("libs/tob_api-release.aar"))
    implementation(files("libs/tobservicelib-4.3.24.aar"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    implementation(libs.androidx.activity)
    implementation(libs.androidx.constraintlayout)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
