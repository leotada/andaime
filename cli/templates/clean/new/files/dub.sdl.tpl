name "{{app}}"
description "An andaime application (clean template)"
targetType "executable"
mainSourceFile "source/main.d"
// JSON, query strings, OpenAPI and database columns spell field names in snake_case, so the domain's structs need no
// andaime attribute (docs: "One policy for the whole project")
versions "AndaimeNamingSnakeCase"
dependency "andaime" {{andaimeSource}}
{{#pg}}
dependency "andaime:pg" {{andaimeSource}}
{{/pg}}
// andaime:dependencies

configuration "application" {
}

// `dub test`: the unittests of source/ and tests/ (source/main.d is left out)
configuration "unittest" {
    sourcePaths "source" "tests"
    importPaths "source" "tests"
}
