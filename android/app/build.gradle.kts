plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.todolist"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.todolist"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // 开启 R8 代码压缩与资源收缩；配合 proguard-rules.pro 保留
            // flutter_local_notifications 的 Gson 模型，避免 release 定时通知崩溃。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

// 符号链接快照问题根治（根因与决策，详见跨项目记忆）：
// Gradle 9.1 对"非正则文件"快照严格拒绝，本机工程在 D 盘、Gradle/Kotlin 缓存在 C 盘，
// 跨卷导致两类符号链接问题：
//   1) merge*NativeLibs 对 libflutter.so 符号链接快照失败 —— 用下方 doNotTrackState 兜底绕过；
//   2) 独立 Kotlin 守护进程把 .class 跨卷写成符号链接 —— 主修复在 gradle.properties：
//      kotlin.compiler.execution.strategy=in-process（编译器进 Gradle 守护进程内编译，无独立守护进程缓存可跨卷复用），
//      配合 kotlin.incremental=false 每次重编译写普通文件。
// 说明：曾尝试降级到 Gradle 8.14 想绕开，但本机 JDK 是 25.0.2、Gradle 8.14 不支持 JDK 25 会 1 秒即崩，
// 故最终留在 Gradle 9.1 + in-process 策略。compile*Kotlin 绝不能加 doNotTrackState
// —— Kotlin 增量编译器依赖任务状态，禁用会报 "Changes are not tracked"。
//   3) packageRelease / packageDebug 的 dex-renamer-state.txt 符号链接 ——
//      ⚠️ 这类任务【不能】doNotTrackState（会反过来报 "Changes are not tracked" 直接失败）。
//      真正修复见下方：把 Gradle 临时目录也放到 D 盘（gradle.properties 的 org.gradle.jvmargs
//      加 -Djava.io.tmpdir=D:/workbuddy/.gradle/tmp），让 dex-renamer 的临时文件与 build 输出同盘，
//      跨卷 move 不再退化成符号链接；并偶尔 `flutter clean` 清掉已残留的符号链接。
tasks.configureEach {
    // 只关闭"不依赖增量变化检测"的任务的状态追踪，避开 Gradle 9.1 对符号链接的严格快照。
    // packageRelease/packageDebug 必须保留状态追踪（否则报 Changes are not tracked）。
    // 其余任务（Kotlin / merge*JniLib / merge*Dex / Resources / R8 / package*）保持状态追踪，
    // 配合同盘临时目录，它们在构建里能正常产出普通文件。彻底根因是临时目录与 build 同盘。
    if (name.contains("NativeLibs", ignoreCase = true) ||
        name.contains("NativeSymbolTables", ignoreCase = true)) {
        doNotTrackState("跨盘符号链接快照保护（原生库合并 / 原生符号表）")
    }
}
