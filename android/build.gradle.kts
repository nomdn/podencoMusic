allprojects {
    repositories {
        // 国内镜像优先，官方仓库兜底
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
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
    // AGP 9 会给库模块也注册 lintVital*（release 前 lint 检查）。audio_service /
    // audio_session 等旧插件带着老 AGP 的 lint 元数据，在 AGP 9 的 lint 分析器上
    // 直接崩（LintClient 链接错误），且 lint 不参与 APK 产物 —— 整组关掉。
    // 静态检查交给 flutter analyze / flutter test。
    tasks.matching { it.name.contains("lintVital") }.configureEach {
        enabled = false
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
