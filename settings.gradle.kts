rootProject.name = "food-delivery-blueprint"

// This repository holds specification documents rather than application source.
// The single Gradle module exists to verify those specifications: it executes
// db/schema.sql and asserts the integrity rules the design depends on, and it
// checks the cross-references between the documents.
include(":tools:verification")
