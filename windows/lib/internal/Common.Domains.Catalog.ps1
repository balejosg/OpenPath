# Single owner of the static Windows domain catalogs (Microsoft system roots,
# Firefox system roots, captive-portal probe domains). Pure literal lists with
# no dependencies: safe to dot-source into the unelevated native messaging host
# (staged via NativeHost.ArtifactCatalog.ps1) and into RuntimeDependency.Policy.ps1.
# Loaded by Common.psm1 before Common.Domains.ps1.

function Get-OpenPathMicrosoftSystemDomains {
    <#
    .SYNOPSIS
        Returns Microsoft system, component update, identity, and CDN roots that must stay reachable
    #>
    return @(
        '*.windowsupdate.com',
        'windowsupdate.com',
        'windowsupdate.microsoft.com',
        'update.microsoft.com',
        'delivery.mp.microsoft.com',
        'do.dsp.mp.microsoft.com',
        'api.cdp.microsoft.com',
        'definitionupdates.microsoft.com',
        'download.microsoft.com',
        'download.windowsupdate.com',
        'go.microsoft.com',
        'adl.windows.com',
        'tsfe.trafficshaping.dsp.mp.microsoft.com',
        'wdcp.microsoft.com',
        'wdcpalt.microsoft.com',
        'wd.microsoft.com',
        'smartscreen-prod.microsoft.com',
        'crl.microsoft.com',
        'www.microsoft.com',
        'msftconnecttest.com',
        'www.msftconnecttest.com',
        'wns.windows.com',
        'displaycatalog.mp.microsoft.com',
        'storequality.microsoft.com',
        'dsx.mp.microsoft.com',
        'edge.microsoft.com',
        'config.edge.skype.com',
        'iecvlist.microsoft.com',
        'manage.microsoft.com',
        'dm.microsoft.com',
        'graph.microsoft.com',
        'login.microsoft.com',
        'login.live.com',
        'login.microsoftonline.com',
        'aadcdn.msauth.net',
        'aadcdn.msftauth.net',
        'azureedge.net',
        'blob.core.windows.net'
    )
}

function Get-OpenPathFirefoxSystemDomains {
    <#
    .SYNOPSIS
        Returns Firefox update, security, extension, and component service roots that must stay reachable
    #>
    return @(
        'aus5.mozilla.org',
        'firefox.settings.services.mozilla.com',
        'firefox-settings-attachments.cdn.mozilla.net',
        'content-signature-2.cdn.mozilla.net',
        'download.mozilla.org',
        'download.cdn.mozilla.net',
        'archive.mozilla.org',
        'ftp.mozilla.org',
        'safebrowsing.googleapis.com',
        'addons.mozilla.org',
        'versioncheck.addons.mozilla.org',
        'services.addons.mozilla.org',
        'ciscobinary.openh264.org',
        'redirector.gvt1.com',
        'clients2.googleusercontent.com'
    )
}

function Get-OpenPathCaptivePortalProbeDomains {
    <#
    .SYNOPSIS
        Connectivity-probe endpoints used by Test-OpenPathCaptivePortalState and the
        OS captive-portal detectors. They must stay resolvable in EVERY DNS mode:
        in limited portal mode the watchdog can only observe 'Authenticated' (and
        close portal mode autonomously) if these resolve through the portal upstream.
    #>
    return @(
        'detectportal.firefox.com',
        'connectivity-check.ubuntu.com',
        'captive.apple.com',
        'www.msftconnecttest.com',
        'msftconnecttest.com',
        'clients3.google.com'
    )
}
