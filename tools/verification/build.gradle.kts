plugins {
    kotlin("jvm") version "2.0.21"
}

repositories {
    mavenCentral()
}

dependencies {
    // sqlite-jdbc is the only way to drive a real SQLite engine from the JVM.
    // The schema must be executed by SQLite itself -- asserting against a
    // reimplementation would prove nothing about the DDL that actually ships.
    testImplementation("org.xerial:sqlite-jdbc:3.47.2.0")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    jvmToolchain(21)
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
    }
}
