param(
    [string]$CurrentTag,
    [string]$PreviousTag,
    [bool]$CreateRelease = $false,
    [string]$OutputFile = "CHANGELOG.md"
)

function ValidateEnv() {
    # Ensure we are in a git repository
    if (-not (Test-Path ".git")) {
        Write-Error "Not a git repository."
        return $false
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not available in PATH."
        return $false
    }
    return $true
}

function ValidateInput([string]$fromTag, [string]$toTag) {
    $deployTagPrefix = "prod-"
    $versionTagPrefix = "v"

    if ($fromTag) {
        # Validate FROM tag exists
        $tagExists = git tag --list $fromTag
        if (-not $tagExists) {
            Write-Error "Tag '$fromTag' does not exist in this repository."
            return
        }
    }

    if ($toTag) {
        # Validate TO tag exists
        $tagExists = git tag --list $toTag
        if (-not $tagExists) {
            Write-Error "Tag '$toTag' does not exist in this repository."
            return
        }
    }

    # Determine FROM tag if not provided
    if (-not $fromTag) {
        $latestCommit = "HEAD"

        # Try to get a tag on this commit matching the filter
        $fromTag = git tag --merged HEAD --points-at $latestCommit --list "$deployTagPrefix*" --sort=-creatordate | Select-Object -First 1

        if (-not $fromTag) {
            $fromTag = $latestCommit
        }

        if (-not $fromTag) {
            Write-Error "No tags reachable from this branch. Cannot generate changelog."
            return
        }
    }

    # Determine TO reference (prefer latest reachable tag on branch)
    if (-not $toTag) {
        $toTag = git tag --merged HEAD --list "$deployTagPrefix*" --sort=-creatordate | Where-Object { $_ -ne $fromTag } | Select-Object -First 1
    }
    
    $versionTag = git tag --points-at $latestCommit --list "$versionTagPrefix*" --sort=-creatordate | Select-Object -First 1
    if (-not $versionTag) {
        $versionTag = $fromTag
    }
    
    if ($fromTag -match '[\d]{8}-[\d]{6}') {
        $tagDatePart = $matches[0]
        $tagDate = [datetime]::ParseExact($tagDatePart, 'yyyyMMdd-HHmmss', $null)
        $releaseDate = $tagDate.ToString("dd-MM-yyyy")
    }
    else {
        $tagDate = git for-each-ref "refs/tags/$fromTag" --format="%(taggerdate)"
        if ($tagDate) {
            $releaseDate = [datetime]::ParseExact($tagDate, "ddd MMM dd HH:mm:ss yyyy K", $null).ToString("dd-MM-yyyy")
        }
    }

    if (-not $releaseDate) {
        $releaseDate = Get-Date -Format "dd-MM-yyyy"
    }

    if ($versionTag -match 'v(?<version>[\d\.]{7,})-[\w]+') {
        $version = $matches.version
    }
    else {
        $version = $versionTag
    }

    return [pscustomobject]@{
        LatestTag   = $fromTag
        PreviousTag = $toTag
        VersionTag  = $versionTag
        Version     = $version
        ReleaseDate = $releaseDate
    }
}

function GetLogDiff([string]$fromTag, [string]$toTag) {
    # Confirm there are commits in range
    $commitCount = git rev-list --count "$fromTag..$toTag"
    if ($commitCount -eq 0) {
        Write-Host "No commits between $fromTag and $toTag."
        return
    }

    Write-Host "Generating changelog [$commitCount] from $fromTag to $toTag..."
    return git log "$fromTag..$toTag" --pretty="%s"
}

function ParseLogs([string[]]$raw) {
    # JIRA-123: BE/FOO description / message [tags]
    $pattern = '^(?<jira>[A-Z]{3,5}-\d+)[:\s]*(?<abbr>(?:[A-Z]{2}))?[\s\/]+(?<desc>[\w\s\/]+)(?:\s+\/)[\s\/]*(?<msg>[^\[]+)?(?<tags>\[.*\])?$'
    # Merge branch 'foo' into feature/JIRA-123-FOO-description
    $pattern2 = '(?<jira>[A-Z]{3,5}-\d+)-(?<desc>[\w-]+)'

    $result = foreach ($line in $raw) {
        if ($line -match $pattern) {
            [pscustomobject]@{
                JiraKey = $matches.jira
                Abbrev  = $matches.abbr
                Desc    = $matches.desc
                Message = $matches.msg.Trim()
            }
        }
        elseif ($line -match $pattern2) {
            [pscustomobject]@{
                JiraKey = $matches.jira
                Abbrev  = ""
                Desc    = $matches.desc -replace '-', ' '
                Message = ""
            }
        }
        else {
            # fallback if something doesn’t match
            [pscustomobject]@{
                JiraKey = ""
                Abbrev  = ""
                Desc    = ""
                Message = $line.Trim()
            }
        }
    }

    return $result
}

function Categorize([object[]]$logs) {
    $categories = [ordered]@{
        "Features"     = "^\s*(implement|introduce|new|feature|upgrade|add|use|create)[ed]*\s+"
        "Improvements" = "^\s*(improve|set|increase|adjust|change|enable|disable|update|replace|check|show|modernize|optimi[sz][e|ation]|tweak|try|enhance|reduce|revise|rework|avoid|streamline|simplif[y|ied]|modif[y|ied])[ed]*\s+"
        "Bug Fixes"    = "^\s*(fix|bug|log|error|solve|resolve|corrected|patch|revert|restore|repair|handle|prevent|crash|leak|fault|broken|hang|stall|fail|issue)[ed]*\s+"
        "CI/CD"        = "(ci|build|deploy|k6|tests)"
        "Refactor"     = "^\s*(refactor|remove|cleanup|clean|move|rename|restructure|reorganize|eliminate)[ed]*\s+"
        "Other"        = ".*"
    }

    # group by commit message text
    $grouped = $logs | Group-Object Message

    $categorized = @{}
    foreach ($g in $grouped) {
        $msg = $g.Name
        $msgLower = $msg.ToLower()

        $category = $categories.Keys |
        Where-Object { $msgLower -match $categories[$_] } | Select-Object -First 1

        if (-not $category) { $category = "Other" }

        $categorized[$category] += , $g
    }
    return $categorized
}

function CreateMarkdown([string]$version, [string]$fromTag, [string]$toTag, [string]$releaseDate, [hashtable]$categorized) {
    $jiraBase = "https://jira.atlassian.net/browse/"
    $gitlabBase = "https://gitlab.com/projects/project"
    $compareUrl = "$gitlabBase/-/compare/$fromTag...$toTag"
    $categories = @(
        "Features"
        "Improvements"
        "Bug Fixes"
        "CI/CD"
        "Refactor"
        "Other"
    )
    
    $md = @()
    $md += "# Changelog"
    $md += ""
    $md += "## [$version]($compareUrl) ($releaseDate)"

    foreach ($category in $categories) {
        if (-not $categorized.ContainsKey($category)) {
            continue
        }

        $items = $categorized[$category]
        if (-not $items -or $items.Count -eq 0) { 
            continue
        }

        $groupedByTicket = $items.Group | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Message) -and -not [string]::IsNullOrWhiteSpace($_.JiraKey) } `
        | Group-Object JiraKey | Sort-Object Name
        if ($groupedByTicket.Count -eq 0) {
            continue
        }

        $md += ""
        $md += ""
        $md += "### $category"

        foreach ($subGrp in $groupedByTicket) {
            $changes = $subGrp.Group | ForEach-Object { $_.Message.Trim() } | Select-Object -Unique

            if ($changes.Count -gt 0) {
                $representative = $subGrp.Group | Select-Object -First 1

                $jiraLink = Convert-JiraLink $subGrp.Name $jiraBase
                $line = "- $jiraLink " + $representative.Desc
                if ($subGrp.Count -gt 1) {
                    $line += " [$($subGrp.Count)]"
                }
                
                $md += "$line"

                foreach ($change in $changes) {
                    $md += "`t- $change"
                }
            }
        }
    }

    return $md -join "`n"
}

function Convert-JiraLink([string]$key, [string]$jiraBaseUrl) {
    if (-not $key) { return "" }
    return "[$key]($jiraBaseUrl$key)"
}

if (-not (ValidateEnv)) {
    exit 1
}

$tags = ValidateInput $CurrentTag $PreviousTag
if (-not $tags) {
    exit 1
}

$raw = GetLogDiff $tags.PreviousTag $tags.LatestTag
if (-not $raw) {
    Write-Host "No new commits. $commitCount"
    exit 0
}

$parsed = ParseLogs $raw
$categorized = Categorize $parsed
$changelog = CreateMarkdown $tags.Version $tags.PreviousTag $tags.LatestTag $tags.ReleaseDate $categorized

Set-Content -Encoding UTF8 -Path $OutputFile -Value $changelog
Write-Host "Changelog written to $OutputFile"
