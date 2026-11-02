allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val localAppData = System.getenv("LOCALAPPDATA")
val localBuildRoot = localAppData ?: "${System.getProperty("user.home")}/.cache"
rootProject.layout.buildDirectory.set(
    file("$localBuildRoot/SYNC/build/${rootProject.projectDir.parentFile.name}"),
)
val newBuildDir: Directory = rootProject.layout.buildDirectory.get()

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
