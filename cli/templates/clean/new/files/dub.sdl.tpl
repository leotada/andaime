name "{{app}}"
description "An andaime application (clean template)"
targetType "executable"
mainSourceFile "source/main.d"
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
