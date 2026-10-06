# Phase 6 A: Acrylic INI parsing for the first-visit DNS topology evidence.
#
# Extracted from the guest harness so the contract tests can exercise the
# parser without a VM. The guest harness reads the WHOLE file (the Phase 5.3
# tail read cut PrimaryServerAddress) and keeps the section-qualified upstream
# addresses and affinity masks; the values are non-secret lab data.

function ConvertFrom-OpenPathAcrylicIniText {
    <#
    .SYNOPSIS
    Parses an AcrylicConfiguration.ini text into section-qualified keys.
    .DESCRIPTION
    Returns an ordered dictionary whose keys are `<Section>.<Key>` (or `<Key>`
    outside a section) for the upstream addresses, the affinity masks and the
    related switches. Commented lines (`; Key=value`) are ignored. The
    interesting key set is the one the lane has always reported:

      *ServerAddress$            (Primary/Secondary/.../Denary)
      *DomainNameAffinityMask$   (AddressCacheDomainNameAffinityMask)
      *QueryTypeAffinityMask$    (AddressCacheQueryTypeAffinityMask)
      UseWindowsHostsFile$
      ^Enable$
      AddressCache*
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text = '')

    $acrylic = [ordered]@{}
    $section = ''
    foreach ($line in @(($Text -split "`r?`n"))) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $section = $Matches[1].Trim()
            continue
        }
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $key = $Matches[1]
            # Phase 6 A: the value must be captured BEFORE any other -match.
            # The previous version matched $key right here, which overwrote
            # $Matches and made $Matches[2] $null, so every value was stored
            # empty (all 39 INI keys in run 37473535860).
            $value = ([string]$Matches[2]).Trim()
            if ($key -match 'ServerAddress$|DomainNameAffinityMask$|QueryTypeAffinityMask$|UseWindowsHostsFile$|^Enable$|AddressCache') {
                $qualified = if ($section) { "$section.$key" } else { $key }
                $acrylic[$qualified] = $value
            }
        }
    }
    return $acrylic
}

Export-ModuleMember -Function ConvertFrom-OpenPathAcrylicIniText
