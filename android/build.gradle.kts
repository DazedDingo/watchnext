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
// Force JVM 17 across all Flutter plugins. Some plugins (e.g.
// receive_sharing_intent) default their Java tasks to 1.8 while the Kotlin
// compiler runs on 17, which breaks with "Inconsistent JVM-target
// compatibility". Align both sides here to avoid per-plugin patches.
// NOTE: this must run BEFORE the evaluationDependsOn(":app") block below,
// otherwise the subprojects have already started evaluating and Gradle
// rejects late afterEvaluate hooks.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val androidExt = ext as com.android.build.gradle.BaseExtension
            androidExt.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
            androidExt.compileOptions.targetCompatibility = JavaVersion.VERSION_17
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
