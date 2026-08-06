import com.android.build.api.dsl.LibraryExtension
import com.android.build.api.dsl.ApplicationExtension

allprojects {
    repositories {
        google { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
    }
}

// 强制所有 Android 子项目（含 Flutter 插件模块）使用 compileSdk 36，
// 否则 file_picker 等插件以其自身较低的 compileSdk 构建，会因
// flutter_plugin_android_lifecycle 要求 ≥36 而在 checkDebugAarMetadata 失败。
subprojects {
    afterEvaluate {
        extensions.findByType<LibraryExtension>()?.compileSdk = 36
        extensions.findByType<ApplicationExtension>()?.compileSdk = 36
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

// 强制所有子项目（含 add_2_calendar 等 Flutter 插件）Kotlin 编译目标为 JVM 17，
// 否则插件模块在 JDK 25 下 Kotlin 目标(25) 与 Java 目标(17) 不一致，报
// "Inconsistent JVM Target Compatibility" 而构建失败。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
