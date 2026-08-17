package blueprint.verification

import java.io.File
import java.sql.Connection
import java.sql.DriverManager

/**
 * Locates the repository root by walking up from the working directory until
 * the schema file is found. Gradle runs tests with the module directory as the
 * working directory, so the path cannot be assumed.
 */
object RepoLayout {
    val root: File by lazy {
        generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .firstOrNull { File(it, "db/schema.sql").isFile }
            ?: error("Could not locate the repository root (no db/schema.sql found above the working directory)")
    }

    val schemaFile: File get() = File(root, "db/schema.sql")
}

/**
 * Executes db/schema.sql against a real SQLite engine.
 *
 * JDBC executes one statement per call, so the script must be split. A naive
 * split on ';' would corrupt every trigger, because a trigger body contains its
 * own statements between BEGIN and END. The splitter below therefore treats a
 * CREATE TRIGGER as open until a line reading `END;`, and strips line comments
 * only when the `--` sits outside a string literal.
 */
object SqliteScript {

    fun openSchemaDatabase(): Connection {
        val connection = DriverManager.getConnection("jdbc:sqlite::memory:")
        execute(connection, RepoLayout.schemaFile.readText())
        // Foreign keys default to OFF in SQLite and violations are silently
        // ignored without this. The production app sets it per connection via a
        // RoomDatabase.Callback; the verification must do the same or the
        // referential rules would go untested.
        connection.createStatement().use { it.execute("PRAGMA foreign_keys = ON") }
        return connection
    }

    fun execute(connection: Connection, script: String) {
        connection.createStatement().use { statement ->
            for (sql in split(script)) {
                statement.execute(sql)
            }
        }
    }

    internal fun split(script: String): List<String> {
        val statements = mutableListOf<String>()
        val buffer = StringBuilder()
        var inTriggerBody = false

        for (rawLine in script.lines()) {
            val line = stripLineComment(rawLine).trimEnd()
            if (buffer.isEmpty() && line.isBlank()) continue

            if (buffer.isEmpty() && line.trimStart().uppercase().startsWith("CREATE TRIGGER")) {
                inTriggerBody = true
            }

            buffer.appendLine(line)

            val trimmed = line.trim()
            val complete = if (inTriggerBody) {
                trimmed.uppercase() == "END;"
            } else {
                trimmed.endsWith(";")
            }

            if (complete) {
                val sql = buffer.toString().trim()
                if (sql.isNotEmpty()) statements += sql
                buffer.setLength(0)
                inTriggerBody = false
            }
        }
        return statements
    }

    /** Removes a trailing `-- comment`, ignoring any `--` inside a quoted literal. */
    private fun stripLineComment(line: String): String {
        var inString = false
        var index = 0
        while (index < line.length) {
            val ch = line[index]
            when {
                ch == '\'' -> inString = !inString
                !inString && ch == '-' && index + 1 < line.length && line[index + 1] == '-' ->
                    return line.substring(0, index)
            }
            index++
        }
        return line
    }
}
