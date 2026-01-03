param(
  [int]$BookId = 1,
  [int]$Requests = 50,
  [int]$Concurrency = 20,
  [int[]]$Ports = @(8081, 8083, 8084)
)

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($BookId -lt 0) {
  Write-Error "Book id must be a positive integer"
  exit 1
}

if ($Requests -lt 1) {
  Write-Error "Requests must be a positive integer"
  exit 1
}

if ($Concurrency -lt 1) {
  Write-Error "Concurrency must be a positive integer"
  exit 1
}

if (-not $Ports -or $Ports.Count -eq 0) {
  Write-Error "Provide at least one port (example: -Ports 8081,8083,8084)"
  exit 1
}

Write-Host "== Load test =="
Write-Host "BookId=$BookId Requests=$Requests"
Write-Host "Ports=$($Ports -join ',')"
Write-Host "Concurrency=$Concurrency"
Write-Host ""

$jobs = @()
$results = @()

for ($i = 1; $i -le $Requests; $i++) {
  while ($jobs.Count -ge $Concurrency) {
    $completed = Wait-Job -Any $jobs
    $results += Receive-Job $completed
    Remove-Job $completed
    $jobs = $jobs | Where-Object { $_.Id -ne $completed.Id }
  }

  $port = $Ports[($i - 1) % $Ports.Count]
  $url = "http://localhost:$port/api/books/$BookId/borrow"

  $jobs += Start-Job -ScriptBlock {
    param($u, $p)
    try {
      $resp = Invoke-WebRequest -Uri $u -Method POST -UseBasicParsing
      [PSCustomObject]@{ Port = $p; Status = $resp.StatusCode; Body = $resp.Content }
    } catch {
      if ($_.Exception.Response -ne $null) {
        $status = $_.Exception.Response.StatusCode.value__
        $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        $body = $reader.ReadToEnd()
        [PSCustomObject]@{ Port = $p; Status = $status; Body = $body }
      } else {
        [PSCustomObject]@{ Port = $p; Status = -1; Body = $_.Exception.Message }
      }
    }
  } -ArgumentList $url, $port
}

if ($jobs.Count -gt 0) {
  $results += $jobs | Wait-Job | Receive-Job
  $jobs | Remove-Job
}

$stopwatch.Stop()
$success  = ($results | Where-Object { $_.Status -eq 200 }).Count
$conflict = ($results | Where-Object { $_.Status -eq 409 }).Count
$other    = $Requests - $success - $conflict
$durationSeconds = [math]::Max(1, [math]::Ceiling($stopwatch.Elapsed.TotalSeconds))
$rate = [math]::Round($Requests / $durationSeconds, 2)

Write-Host "== Results =="
Write-Host "Success (200):  $success"
Write-Host "Conflict (409): $conflict"
Write-Host "Other:          $other"
Write-Host "Duration:       $($stopwatch.Elapsed.TotalSeconds.ToString('0.###'))s (approx $rate req/s)"
Write-Host ""
Write-Host "Results by port:"

foreach ($port in $Ports) {
  $portResults = $results | Where-Object { $_.Port -eq $port }
  $pSuccess = ($portResults | Where-Object { $_.Status -eq 200 }).Count
  $pConflict = ($portResults | Where-Object { $_.Status -eq 409 }).Count
  $pOther = $portResults.Count - $pSuccess - $pConflict
  Write-Host " - $port -> 200:$pSuccess 409:$pConflict other:$pOther"
}
