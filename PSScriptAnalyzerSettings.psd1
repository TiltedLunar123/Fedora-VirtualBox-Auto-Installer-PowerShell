@{
    ExcludeRules = @(
        # This is a CLI script with colored console output — Write-Host is intentional.
        'PSAvoidUsingWriteHost',

        # Internal helper functions called within a single script — ShouldProcess adds
        # no value here since the top-level script already controls execution flow.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
