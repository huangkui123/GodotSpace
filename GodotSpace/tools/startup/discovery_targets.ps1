$ErrorActionPreference = 'Stop'
# Use actual IPv4 masks: adapters need not be /24. No WMI/admin access required.
$targets = @('127.0.0.1', '255.255.255.255')
foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($adapter.OperationalStatus -ne 'Up' -or $adapter.NetworkInterfaceType -eq 'Loopback') { continue }
    foreach ($unicast in $adapter.GetIPProperties().UnicastAddresses) {
        if ($unicast.Address.AddressFamily -ne 'InterNetwork' -or $null -eq $unicast.IPv4Mask) { continue }
        $address = $unicast.Address.GetAddressBytes()
        $mask = $unicast.IPv4Mask.GetAddressBytes()
        if ($address[0] -eq 169 -and $address[1] -eq 254) { continue }
        if (($mask | Where-Object { $_ -ne 255 }).Count -eq 0) { continue }
        $broadcast = for ($i = 0; $i -lt 4; $i++) { $address[$i] -bor (255 -bxor $mask[$i]) }
        $targets += $broadcast -join '.'
    }
}
ConvertTo-Json -InputObject @($targets | Select-Object -Unique) -Compress
