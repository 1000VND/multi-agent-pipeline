param([string]$RepoPath, [string]$ReadyFile, [string]$CallsFile)
# Loopback-only HTTP fixture, independent of the fake client process tree.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$listener.LocalEndpoint.Port | Set-Content -LiteralPath $ReadyFile
$busy = $true
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = [IO.StreamReader]::new($stream)
      $request = $reader.ReadLine()
      while ($reader.ReadLine()) { }
      Add-Content -LiteralPath $CallsFile -Value $request
      $path = ($request -split ' ')[1] -replace '\?.*$', ''
      $body = '{}'
      if ($path -match '/abort$') { $busy = $false; $body = 'true' }
      elseif ($path -eq '/session/status') {
        if ($busy) { $body = '{"fake-session-1":{"type":"busy"}}' }
      } elseif ($path -eq '/session') {
        $body = ConvertTo-Json -InputObject @(@{id='fake-session-1'; directory=$RepoPath}) -Compress
      } else { $body = @{id='fake-session-1'; directory=$RepoPath} | ConvertTo-Json -Compress }
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
      $stream.Write($header,0,$header.Length)
      $stream.Write($bytes,0,$bytes.Length)
      $stream.Flush()
    } finally { $client.Close() }
  }
} finally { $listener.Stop() }
