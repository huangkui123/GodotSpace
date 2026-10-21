$ErrorActionPreference = 'Stop'
Add-Type -Path @((Join-Path $PSScriptRoot 'usb_transport.cs'), (Join-Path $PSScriptRoot 'usb_transport_test.cs'))
[UsbTransportTests]::Run()
Write-Output 'USB transport tests passed: framing, TS CRC/PTS, HTTP authentication, late join, disconnect, camera and ACK relay'
