package blueprint.verification

import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertTrue

/**
 * Every deliverable in this repository is Markdown that links to other Markdown,
 * so a renamed heading breaks navigation with no other symptom. This verifies
 * that each relative link resolves to a file that exists and that each
 * `#fragment` matches a heading actually present in the target document.
 *
 * External URLs are deliberately not fetched -- that would make the build
 * depend on the availability of third-party sites.
 */
@DisplayName("Document cross-references")
class DocumentLinksTest {

    private val linkPattern = Regex("""\[([^\]]*)]\(([^)]+)\)""")
    private val headingPattern = Regex("""^#{1,6}\s+(.*)$""", RegexOption.MULTILINE)
    private val fencePattern = Regex("""```.*?```""", RegexOption.DOT_MATCHES_ALL)

    /** Approximates GitHub's heading-anchor algorithm. */
    private fun slugify(heading: String): String = heading.trim().lowercase()
        .replace(Regex("""[^\w\s-]"""), "")
        .replace(Regex("""\s+"""), "-")
        .trim('-')

    private fun markdownFiles(): List<File> = RepoLayout.root
        .walkTopDown()
        .onEnter { it.name != ".git" && it.name != "build" && it.name != ".gradle" }
        .filter { it.isFile && it.extension == "md" }
        .sortedBy { it.path }
        .toList()

    @Test
    @DisplayName("every relative link resolves and every anchor exists")
    fun crossReferencesResolve() {
        val documents = markdownFiles()
        assertTrue(documents.isNotEmpty(), "expected specification documents to be present")

        val anchors: Map<File, Set<String>> = documents.associateWith { file ->
            headingPattern.findAll(file.readText())
                .map { slugify(it.groupValues[1]) }
                .toSet()
        }

        val failures = mutableListOf<String>()
        var checked = 0

        for (document in documents) {
            // Strip fenced blocks so the ASCII wireframes and DDL snippets are
            // not scanned for links.
            val body = fencePattern.replace(document.readText(), "")
            val relativePath = document.relativeTo(RepoLayout.root).path

            for (match in linkPattern.findAll(body)) {
                val link = match.groupValues[2].trim()
                if (link.startsWith("http://") || link.startsWith("https://") || link.startsWith("mailto:")) {
                    continue
                }

                checked++
                val filePart = link.substringBefore('#')
                val fragment = link.substringAfter('#', missingDelimiterValue = "")

                val target = if (filePart.isEmpty()) {
                    document
                } else {
                    File(document.parentFile, filePart).canonicalFile.also {
                        if (!it.exists()) {
                            failures += "$relativePath: broken file link -> $link"
                            return@also
                        }
                    }
                }

                if (!target.exists()) continue

                if (fragment.isNotEmpty() && target.extension == "md") {
                    val known = anchors[documents.firstOrNull { it.canonicalFile == target }] ?: emptySet()
                    if (fragment !in known) {
                        failures += "$relativePath: broken anchor -> $link"
                    }
                }
            }
        }

        println("  checked $checked relative links across ${documents.size} document(s)")
        assertTrue(
            failures.isEmpty(),
            "unresolved cross-references:\n" + failures.joinToString("\n") { "  - $it" }
        )
    }
}
