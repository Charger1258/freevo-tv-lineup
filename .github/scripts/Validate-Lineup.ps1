<#
.SYNOPSIS
    Checks a FREEVO TV lineup before you publish it.
.DESCRIPTION
    Applies the same rules the TV applies, so anything reported here is exactly what the app would drop.
    Errors stop a rotation; warnings are things the app tolerates but that usually mean a typo.
    Exits non-zero when there are errors, so it can gate a push.
.EXAMPLE
    .\Validate-Lineup.ps1
    .\Validate-Lineup.ps1 -Path C:\path\to\lineup.json
#>
param([string]$Path = (Join-Path $PSScriptRoot 'lineup.json'))

$ErrorActionPreference = 'Stop'
$MINUTE, $HOUR, $DAY = 60000L, 3600000L, 86400000L
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$problems = [System.Collections.Generic.List[string]]::new()
function Fail([string]$message) { $problems.Add("ERROR $message") }
function Warn([string]$message) { $problems.Add("warn  $message") }
function When($ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime.ToString('s') }
function Items($value) { return @(foreach ($entry in @($value)) { if ($null -ne $entry) { $entry } }) }

if (-not (Test-Path $Path)) { Write-Error "No lineup file at '$Path'."; exit 1 }
try { $lineup = ConvertFrom-Json (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) } catch { Write-Error "Not valid JSON: $_"; exit 1 }

$revision = if ($lineup.revision) { [long]$lineup.revision } else { 0 }
if ($revision -lt 1) { Warn 'revision is missing; give the lineup a number and raise it on every rotation.' }
$zoneName = if ($lineup.timezone) { [string]$lineup.timezone } else { 'UTC' }
try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($zoneName) }
catch { Fail "timezone '$zoneName' is not a known zone; the app reads offset-free times as UTC."; $zone = [TimeZoneInfo]::Utc }

function Test-Playable([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    try { $uri = [uri]$url } catch { return $false }
    return $uri.Scheme -eq 'https' -and $uri.Host -eq 'flixtor.to' -and $uri.AbsolutePath.StartsWith('/watch/')
}
function To-Epoch([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $clean = $text.Trim().Replace(' ', 'T')
    if ($clean -match '^\d{13}$') { return [long]$clean }
    if ($clean -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$') {
        $pattern = if ($clean.Length -gt 16) { 'yyyy-MM-ddTHH:mm:ss' } else { 'yyyy-MM-ddTHH:mm' }
        try {
            $local = [DateTime]::ParseExact($clean, $pattern, [System.Globalization.CultureInfo]::InvariantCulture)
            return ([DateTimeOffset]::new([TimeZoneInfo]::ConvertTimeToUtc($local, $zone))).ToUnixTimeMilliseconds()
        } catch { return $null }
    }
    if ($clean -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})$') {
        foreach ($pattern in @('yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-ddTHH:mmK')) {
            try { return ([DateTimeOffset]::ParseExact($clean, $pattern, [System.Globalization.CultureInfo]::InvariantCulture)).ToUnixTimeMilliseconds() } catch { }
        }
    }
    return $null
}

$titleIds = [System.Collections.Generic.HashSet[string]]::new()
$titles = Items $lineup.content
if ($titles.Count -gt 4000) { Fail "content has $($titles.Count) titles; the app reads the first 4000." }
foreach ($item in $titles) {
    $id = [string]$item.id
    if (-not (Test-Playable $id)) { Fail "title '$id' is not a playable https://flixtor.to/watch/... page and will never air."; continue }
    $title = [string]$item.title
    if ($title.Trim() -eq '') { Fail "the entry for $id has no title." }
    if ($title.Length -gt 200) { Fail "the title for $id is longer than 200 characters." }
    if (-not $titleIds.Add($id)) { Warn "title $id is published twice; the first entry is used." }
    $poster = [string]$item.poster
    if ($poster -ne '' -and -not $poster.StartsWith('https://')) { Warn "title $id has non-HTTPS artwork; the app drops the image, not the title." }
    $series = [string]$item.series
    if ($series -ne '' -and -not (Test-Playable $series)) { Fail "title $id names series '$series', which is not a playable page, so the app treats it as a film." }
    $duration = if ($item.duration) { [long]$item.duration } else { 0 }
    $minutes = if ($item.minutes) { [int]$item.minutes } else { 0 }
    if ($duration -lt (3 * $MINUTE) -or $duration -gt (12 * $HOUR)) {
        if ($minutes -lt 3 -or $minutes -gt 720) { Fail "title $id has no usable length: give duration in milliseconds, or minutes between 3 and 720." }
        else { Warn "title $id gives only minutes; the app corrects the length once it has played it." }
    }
}

$numbers = @{}
$channelIds = [System.Collections.Generic.HashSet[string]]::new()
$channels = Items $lineup.channels
if ($channels.Count -eq 0) { Fail 'a lineup with no channels is rejected outright, and the app keeps its built-in lineup.' }
if ($channels.Count -gt 40) { Fail "channels has $($channels.Count) entries; the app stops at 40." }
foreach ($channel in $channels) {
    $id = [string]$channel.id
    if ($id -notmatch '^[a-z][a-z0-9_]{1,23}$' -or $id.StartsWith('live_')) {
        Fail "channel id '$id' must be 2-24 lowercase letters, digits, or underscores, and cannot start with live_ (that prefix belongs to the viewer)."; continue }
    if (-not $channelIds.Add($id)) { Fail "channel id $id appears twice; the app keeps the first one and ignores this one."; continue }
    $number = if ($channel.number) { [int]$channel.number } else { 0 }
    if ($number -lt 2 -or $number -gt 199) { Fail "channel $id has number $number; a published lineup stays in 2-199 because viewers own 200 and above."; continue }
    if ($numbers.ContainsKey($number)) { Fail "channel $id reuses number $number, already used by channel $($numbers[$number])." } else { $numbers[$number] = $id }
    $name = [string]$channel.name
    if ($name.Trim() -eq '' -or $name.Length -gt 60) { Fail "channel $id needs a name of 1-60 characters." }
    if (([string]$channel.description).Length -gt 200) { Fail "channel $id has a description longer than 200 characters." }
    $color = [string]$channel.color
    if ($color -ne '' -and $color -notmatch '^#[0-9a-fA-F]{6}$') { Fail "channel $id colour '$color' must be #RRGGBB." }
    $kind = if ($channel.kind) { ([string]$channel.kind).ToLower() } else { 'any' }
    if (@('any', 'movies', 'episodes') -notcontains $kind) { Fail "channel $id kind '$($channel.kind)' must be any, movies, or episodes; live stations are added by the viewer, never published." }
    $wheel = @(Items $channel.wheel | ForEach-Object { [string]$_ })
    if ($wheel.Count -gt 400) { Fail "channel $id has a $($wheel.Count) entry wheel; the app reads the first 400." }
    foreach ($entry in $wheel) {
        if (-not $titleIds.Contains($entry)) { Fail "channel $id wheels a title the lineup never published: $entry" }
    }
    if ($wheel.Count -eq 0) { Warn "channel $id has no wheel, so the app rotates whatever is in the viewer's own library." }
    $airings = Items $channel.schedule
    if ($airings.Count -gt 600) { Fail "channel $id publishes $($airings.Count) airings; the app reads the first 600." }
    $accepted = [System.Collections.Generic.List[object]]::new()
    foreach ($airing in $airings) {
        $title = [string]$airing.id
        if (-not $titleIds.Contains($title)) { Fail "channel $id pins a title the lineup never published: $title"; continue }
        $start = To-Epoch ([string]$airing.start)
        if ($null -eq $start) { Fail "channel $id has an unreadable start '$($airing.start)' for $title."; continue }
        if ($start -lt ($now - 30 * $DAY) -or $start -gt ($now + 30 * $DAY)) {
            Fail "channel $id pins $title at $(When $start), more than 30 days from today, which the app ignores."; continue }
        $end = To-Epoch ([string]$airing.end)
        if ($null -ne $end -and $end -le $start) { Fail "channel $id ends an airing of $title before it starts."; continue }
        if ($null -eq $end) { Warn "channel $id pins $title with no end; the app runs it for the title's own length." }
        elseif ($end - $start -gt 24 * $HOUR) { Warn "channel $id pins $title for over a day; the app trims it to 24 hours." }
        $through = if ($null -ne $end) { $end } else { $start + 24 * $HOUR }
        foreach ($earlier in $accepted) {
            if ($earlier.end -gt $start -and $earlier.start -lt $through) {
                Fail "channel $id pins $title at $(When $start) on top of an airing that already runs to $(When $earlier.end)."
                $through = $start
            }
        }
        if ($through -gt $start) { $accepted.Add([pscustomobject]@{ start = $start; end = $through }) }
    }
}

Write-Host "Lineup: $Path"
Write-Host "  revision $revision  |  $($channels.Count) channels  |  $($titles.Count) titles  |  times in $zoneName"
if ($problems.Count -eq 0) { Write-Host '  OK: the app will publish every channel, title, and airing in this file.'; exit 0 }
foreach ($problem in $problems) { Write-Host "  $problem" }
$errors = @($problems | Where-Object { $_ -like 'ERROR*' })
Write-Host "  $($errors.Count) error(s), $($problems.Count - $errors.Count) warning(s)."
exit $(if ($errors.Count -gt 0) { 1 } else { 0 })
