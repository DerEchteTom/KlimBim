param (
    [Parameter(Mandatory = $true)]
    [string]$IPAddress
)

function Resolve-HostName {
    param (
        [string]$IP
    )
    try {
        $result = [System.Net.Dns]::GetHostEntry($IP)
        return $result.HostName
    } catch {
        return "Unresolved"
    }
}

$resolvedHost = Resolve-HostName -IP $IPAddress
Write-Output "ResolvedHost for $IPAddress → $resolvedHost"