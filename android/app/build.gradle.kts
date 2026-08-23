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
        // 仅出 arm64-v8a：目标机 RMX3350 为 arm64，且单 ABI 可把 APK 控制在 ~85MB，
        // 与 Gitee 发行版 1GB 配额（约 11 个版本）的轮转预判一致；fat APK 会更快触顶。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // 固定 release 签名：凭据从环境变量读取，绝不硬编码进仓库文件。
    // 使用方式（构建前 export）：
    //   YOUTIAO_KEYSTORE=E:/WorkBuddy/6/youtiao-release-keys/youtiao-release.jks
    //   YOUTIAO_KEY_ALIAS=youtiao
    //   YOUTIAO_KEYSTORE_PASSWORD=youtiao-release-2026
    //   YOUTIAO_KEY_PASSWORD=youtiao-release-2026
    // keystore 存放于项目外（E:/WorkBuddy/6/youtiao-release-keys/），不会被 git 跟踪，
    // 且不再依赖 AGP 自动生成的 debug keystore，避免跨机/重建导致的签名漂移（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
    val keystorePath = System.getenv("YOUTIAO_KEYSTORE")
    val keyAliasName = System.getenv("YOUTIAO_KEY_ALIAS") ?: "youtiao"
    val keystorePassword = System.getenv("YOUTIAO_KEYSTORE_PASSWORD")
    val releaseKeyPassword = System.getenv("YOUTIAO_KEY_PASSWORD")
    val useFixedReleaseSigning = keystorePath != null && keystorePassword != null && releaseKeyPassword != null

    if (useFixedReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(keystorePath!!)
                storePassword = keystorePassword
                keyAlias = keyAliasName
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // 优先用固定 release keystore；若环境变量未设置则回退 debug（保持本地 flutter run --release 可用）。
            signingConfig = if (useFixedReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 注：本机 Gradle 9.1 + JDK 25 在 release 构建中对 minifyReleaseWithR8 的
            // output-metadata.json / resourceShrinkingParams 快照报 "not a regular file"
            // （Gradle 9.1 严格快照 + JDK 25 文件属性读取的兼容问题，doNotTrackState 对该输入属性无效）。
            // 为稳定出包，暂时关闭 R8 压缩与资源收缩（APK 体积略增，功能完全一致）；
            // proguard 规则保留以备后续在兼容 JDK 上重新开启。
            isMinifyEnabled = false
            isShrinkResources = false
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
//   4) compileFlutterBuildRelease 对 flutter_assets/NOTICES.Z、processReleaseManifestForPackage 对
//      packaged_manifests 下的 AndroidManifest.xml 快照失败，报 "not a regular file"。
//      ⚠️ 这些文件实际上是【Windows reparse-point 符号链接】（Git Bash 的 ls/find -type l 检测不到，
//      因为它们不是 POSIX 符号链接）。根因是工程在 D 盘、Gradle/Kotlin 缓存在 C 盘、Flutter SDK 在 C 盘，
//      跨卷时 Gradle/Flutter 的硬链接（hardlink）创建失败，退化成 reparse 符号链接；Gradle 9.1 严格快照
//      拒绝访问 reparse 点，故报错。
//   根治方向：把 GRADLE_USER_HOME 设到 D 盘，使 Gradle/Kotlin 缓存与 build/ 同卷。跨卷时硬链接退化成
//   reparse 符号链接的根因消失，缓存→build 的 staging 均为常规文件，merge*/process* 等消费任务不再报
//   "not a regular file"。仅 Flutter 自身构建任务（compileFlutterBuild*/copyFlutterAssets*，产出在
//   build 内部、仍可能含符号链接）需要 doNotTrackState 跳过其输出快照。
//   ⚠️ 以下任务【绝不能】doNotTrackState，否则报 "Changes are not tracked" 直接失败：
//   - *Dex*（mergeExtDexRelease 等需增量追踪）
//   - *Kotlin*（Kotlin 增量编译器依赖任务状态，含 compile*Kotlin）
//   - packageRelease / packageDebug / packageReleaseResources（打包任务）
//   - merge* 系列（mergeReleaseJniLibFolders 等增量合并器）
//   - process* 系列（processReleaseResources 等必须追踪增量变更；D: 同卷下其输入已是常规文件，无需 untrack）
//   故白名单严格限定为：Native / CMake / JsonModel（原生）/ Flutter（Flutter 构建任务）。
tasks.configureEach {
    if (name.contains("Native", ignoreCase = true) ||
        name.contains("CMake", ignoreCase = true) ||
        name.contains("JsonModel", ignoreCase = true) ||
        name.contains("Flutter", ignoreCase = true)
    ) {
        doNotTrackState("Gradle 9.1 跨盘符号链接快照保护（原生/CMake/Flutter 生产任务）")
    }
}
