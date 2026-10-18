name "{{app}}"
description "An andaime application (clean template)"
targetType "executable"
mainSourceFile "source/main.d"
dependency "andaime" path="{{andaimePath}}"
{{#pg}}
dependency "andaime-pg" path="{{andaimePath}}/drivers/pg"
{{/pg}}
// andaime:dependencies

configuration "application" {
}

// `dub test`: the unittests of source/ and tests/ (source/main.d is left out)
configuration "unittest" {
    sourcePaths "source" "tests"
    importPaths "source" "tests"
}
