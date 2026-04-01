@{
    ExcludeRules = @(
        # This is a CLI script with colored console output — Write-Host is intentional.
        'PSAvoidUsingWriteHost',

        # Internal helper functions called within a single script — ShouldProcess adds
        # no value here since the top-level script already controls execution flow.
        'PSUseShouldProcessForStateChangingFunctions',

        # Script-level params are consumed inside Main() — PSScriptAnalyzer cannot trace
        # usage across function boundaries within the same file.
        'PSReviewUnusedParameter',

        # VM provisioning script accepts passwords as plain strings by design — they are
        # hashed to SHA-512 before being written to the Kickstart file.
        'PSAvoidUsingPlainTextForPassword',

        # Standalone script, not a module — approved verbs and singular nouns are
        # conventions for published cmdlets, not internal automation scripts.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # Variables assigned for clarity or side effects (e.g. capturing output to discard it).
        'PSUseDeclaredVarsMoreThanAssignments',

        # File contains emoji characters for terminal output — BOM is not required.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
