param([Parameter(Mandatory=$true)][string]$SiteRoot)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:SiteRoot = [IO.Path]::GetFullPath($SiteRoot)
$script:ToolRoot = $PSScriptRoot
$script:BackupRoot = Join-Path $script:ToolRoot 'Backups'
$script:LogRoot = Join-Path $script:ToolRoot 'Logs'
$script:LogFile = Join-Path $script:LogRoot ('manager-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:ResourceModels = @{}
$script:Updates = [Collections.ArrayList]::new()
$script:GalleryImages = @()
$script:CurrentResourcePage = 'forms.html'
$script:CurrentSectionIndex = -1
$script:CurrentUpdateIndex = -1
$script:LoadingResourceUi = $false
$script:LoadingUpdateUi = $false
$script:UndoDeleteStack = [Collections.ArrayList]::new()
$script:ShortLinks = [Collections.ArrayList]::new()
$script:LoadingShortLinkUi = $false

New-Item -ItemType Directory -Force -Path $script:BackupRoot, $script:LogRoot | Out-Null

$requiredFiles = @('index.html','gallery.html','forms.html','documents.html','Policies.html','sample\gallery\view.html','sample\gallery\gallery.html')
$missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:SiteRoot $_) -PathType Leaf) })
if ($missingFiles.Count) {
    [Windows.Forms.MessageBox]::Show("The website manager could not find required site files under:`n$script:SiteRoot`n`nMissing: $($missingFiles -join ', ')",'Website folder not found','OK','Error') | Out-Null
    exit 2
}

function Write-ManagerLog([string]$Message, [string]$Level = 'INFO') {
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    if ($script:LogBox -and -not $script:LogBox.IsDisposed) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Get-SiteText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return [IO.File]::ReadAllText($Path)
}

function Save-SiteText([string]$Path, [string]$Content) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $script:SiteRoot.TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'The target file is outside the website folder.' }
    $backupFolderName = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
    $backupDir = Join-Path $script:BackupRoot $backupFolderName
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $relative = $full.Substring($script:SiteRoot.TrimEnd('\').Length).TrimStart('\')
    $backup = Join-Path $backupDir $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    $fileExists = Test-Path -LiteralPath $full -PathType Leaf
    $bytes = $script:Utf8.GetBytes($Content)
    $hasBom = $false
    if ($fileExists) {
        $oldBytes = [IO.File]::ReadAllBytes($full)
        $hasBom = $oldBytes.Length -ge 3 -and $oldBytes[0] -eq 239 -and $oldBytes[1] -eq 187 -and $oldBytes[2] -eq 191
    }
    if ($hasBom) {
        $withBom = [byte[]]::new($bytes.Length + 3)
        $withBom[0] = 239; $withBom[1] = 187; $withBom[2] = 191
        [Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
        $bytes = $withBom
    }
    $temp = $full + '.manager-tmp'
    [IO.File]::WriteAllBytes($temp, $bytes)
    if ($fileExists) { [IO.File]::Replace($temp, $full, $backup) }
    else { Move-Item -LiteralPath $temp -Destination $full }
    $backupRelative = Join-Path $backupFolderName $relative
    Write-ManagerLog "Saved $relative (backup: Backups\$backupRelative)"
}

function Get-HtmlText([string]$Text) {
    $plain = [regex]::Replace($Text, '(?is)<br\s*/?>', ' ')
    $plain = [regex]::Replace($plain, '(?is)<[^>]+>', '')
    return [Net.WebUtility]::HtmlDecode($plain).Trim()
}

function ConvertTo-Html([string]$Text) { return [Net.WebUtility]::HtmlEncode([string]$Text) }

function Get-Attr([string]$Attributes, [string]$Name) {
    $match = [regex]::Match($Attributes, '(?is)\b' + [regex]::Escape($Name) + '\s*=\s*(["''])(.*?)\1')
    if ($match.Success) { return [Net.WebUtility]::HtmlDecode($match.Groups[2].Value) }
    return ''
}

function Get-DivBlock([string]$Html, [int]$StartIndex, [int]$OpenLength) {
    $tokens = [regex]::Matches($Html.Substring($StartIndex), '(?is)</?div\b[^>]*>')
    $depth = 0
    foreach ($token in $tokens) {
        if ($token.Value -match '(?is)^</div') { $depth-- } else { $depth++ }
        if ($depth -eq 0) {
            $end = $StartIndex + $token.Index + $token.Length
            return [pscustomobject]@{ Start = $StartIndex; End = $end; Html = $Html.Substring($StartIndex, $end - $StartIndex) }
        }
    }
    throw 'Could not find the closing div for a managed content block.'
}

function Get-ResourceSections([string]$PagePath) {
    $html = Get-SiteText $PagePath
    $result = [Collections.ArrayList]::new()
    $commentsRemoved = [regex]::Replace($html, '(?is)<!--.*?-->', { param($m) (' ' * $m.Length) })
    $openings = [regex]::Matches($commentsRemoved, '(?is)<div\b[^>]*class\s*=\s*(["''])[^"'']*\blight_card\b[^"'']*\1[^>]*>')
    foreach ($opening in $openings) {
        $block = Get-DivBlock $commentsRemoved $opening.Index $opening.Length
        if ($block.Html -notmatch '(?is)eng_dhiv_heading_box') { continue }
        $eng = [regex]::Match($block.Html, '(?is)<h4\b[^>]*>(.*?)</h4>')
        $div = [regex]::Match($block.Html, '(?is)<h4_d\b[^>]*>(.*?)</h4_d>')
        if (-not $eng.Success) { continue }
        $section = [pscustomobject]@{
            English = Get-HtmlText $eng.Groups[1].Value
            Dhivehi = if ($div.Success) { Get-HtmlText $div.Groups[1].Value } else { '' }
            Items = [Collections.ArrayList]::new()
        }
        $anchors = [regex]::Matches($block.Html, '(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')
        foreach ($anchor in $anchors) {
            $href = Get-Attr $anchor.Groups['attrs'].Value 'href'
            $label = Get-HtmlText $anchor.Groups['body'].Value
            if ($href -and $label) {
                [void]$section.Items.Add([pscustomobject]@{ Name = $label; Href = $href; SourceFile = '' })
            }
        }
        [void]$result.Add($section)
    }
    return ,$result
}

function Get-ResourcePageName([string]$PagePath) {
    switch ($PagePath) {
        'forms.html' { 'Forms' }
        'documents.html' { 'Documents' }
        'Policies.html' { 'Policies' }
    }
}

function Save-ResourcePage([string]$PagePath) {
    $path = Join-Path $script:SiteRoot $PagePath
    $html = Get-SiteText $path
    $scan = [regex]::Replace($html, '(?is)<!--.*?-->', { param($m) (' ' * $m.Length) })
    $openings = [regex]::Matches($scan, '(?is)<div\b[^>]*class\s*=\s*(["''])[^"'']*\blight_card\b[^"'']*\1[^>]*>')
    $blocks = [Collections.ArrayList]::new()
    foreach ($opening in $openings) {
        $block = Get-DivBlock $scan $opening.Index $opening.Length
        if ($block.Html -match '(?is)eng_dhiv_heading_box' -and $block.Html -match '(?is)<h4\b') { [void]$blocks.Add($block) }
    }
    if (-not $blocks.Count) { throw "No bilingual light-card sections were found in $PagePath." }
    $models = $script:ResourceModels[$PagePath]
    $folder = if ($PagePath -eq 'Policies.html') { 'documents' } else { [IO.Path]::GetFileNameWithoutExtension($PagePath) }
    foreach ($section in $models) {
        $folderName = ([regex]::Replace($section.English, '[^\w -]', '')).Trim().TrimEnd('.', ' ')
        if (-not $folderName) { $folderName = 'Files' }
        foreach ($item in $section.Items) {
            if (-not $item.SourceFile) { continue }
            $relative = Join-Path $folder (Join-Path $folderName ([IO.Path]::GetFileName($item.SourceFile)))
            $target = Join-Path $script:SiteRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            if ([IO.Path]::GetFullPath($item.SourceFile) -ne [IO.Path]::GetFullPath($target)) {
                $base = [IO.Path]::GetFileNameWithoutExtension($target)
                $ext = [IO.Path]::GetExtension($target)
                $suffix = 2
                while (Test-Path -LiteralPath $target) {
                    $target = Join-Path (Split-Path -Parent $target) ("$base ($suffix)$ext")
                    $relative = Join-Path $folder (Join-Path $folderName ([IO.Path]::GetFileName($target)))
                    $suffix++
                }
                Copy-Item -LiteralPath $item.SourceFile -Destination $target
                Write-ManagerLog "Copied resource file to $relative"
            }
            $item.Href = ($relative -replace '\\', '/')
            $item.SourceFile = ''
        }
    }

    $newline = if ($html.Contains("`r`n")) { "`r`n" } else { "`n" }
    $rendered = foreach ($section in $models) {
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('<div class="light_card">')
        $lines.Add('  <div class="eng_dhiv_heading_box">')
        $lines.Add('    <h4>' + (ConvertTo-Html $section.English) + '</h4>')
        $lines.Add('    <h4_d>' + (ConvertTo-Html $section.Dhivehi) + '</h4_d>')
        $lines.Add('  </div>')
        foreach ($item in $section.Items) {
            if (-not $item.Name -or -not $item.Href) { continue }
            $lines.Add('  <a href="' + (ConvertTo-Html $item.Href) + '">')
            $lines.Add('    <t class="doc_content">' + (ConvertTo-Html $item.Name) + '</t>')
            $lines.Add('  </a>')
        }
        $lines.Add('</div>')
        $lines -join $newline
    }
    $replacement = ($rendered -join ($newline + $newline + '    <br/><br/>' + $newline + $newline))
    $first = $blocks[0]
    $last = $blocks[$blocks.Count - 1]
    $html = $html.Substring(0, $first.Start) + $replacement + $html.Substring($last.End)
    Save-SiteText $path $html
}

function Get-UpdateItems {
    $html = Get-SiteText (Join-Path $script:SiteRoot 'index.html')
    $open = [regex]::Match($html, '(?is)<div\b(?=[^>]*\bid\s*=\s*["'']news_scroll["''])[^>]*>')
    if (-not $open.Success) { throw 'Could not find the homepage news list #news_scroll.' }
    $block = Get-DivBlock $html $open.Index $open.Length
    $inner = [regex]::Replace($block.Html.Substring($open.Length, $block.Html.Length - $open.Length - 6), '(?is)<!--.*?-->', '')
    $items = [Collections.ArrayList]::new()
    $anchors = [regex]::Matches($inner, '(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')
    foreach ($anchor in $anchors) {
        if ((Get-Attr $anchor.Groups['attrs'].Value 'class') -notmatch '(^|\s)news_item(\s|$)') { continue }
        $body = $anchor.Groups['body'].Value
        $tag = [regex]::Match($body, '(?is)<tag\b[^>]*>(.*?)</tag>')
        $title = [regex]::Match($body, '(?is)<t\b[^>]*>(.*?)</t>')
        $date = [regex]::Match($body, '(?is)<date\b[^>]*>(.*?)</date>')
        if (-not $title.Success) { continue }
        [void]$items.Add([pscustomobject]@{
            Tag = if ($tag.Success) { Get-HtmlText $tag.Groups[1].Value } else { 'UPDATE' }
            Title = Get-HtmlText $title.Groups[1].Value
            Date = if ($date.Success) { Get-HtmlText $date.Groups[1].Value } else { '' }
            Href = Get-Attr $anchor.Groups['attrs'].Value 'href'
        })
    }
    return ,$items
}

function Save-UpdateItems {
    $path = Join-Path $script:SiteRoot 'index.html'
    $html = Get-SiteText $path
    $open = [regex]::Match($html, '(?is)<div\b(?=[^>]*\bid\s*=\s*["'']news_scroll["''])[^>]*>')
    if (-not $open.Success) { throw 'Could not find the homepage news list #news_scroll.' }
    $block = Get-DivBlock $html $open.Index $open.Length
    $newline = if ($html.Contains("`r`n")) { "`r`n" } else { "`n" }
    $itemsHtml = foreach ($item in $script:Updates) {
        if (-not $item.Title -or -not $item.Href) { continue }
        '    <a href="' + (ConvertTo-Html $item.Href) + '" class="news_item">' + $newline +
        '      <div class="news_card">' + $newline +
        '        <tag>' + (ConvertTo-Html $item.Tag) + '</tag>' + $newline +
        '        <t>' + (ConvertTo-Html $item.Title) + '</t>' + $newline +
        '        <date>' + (ConvertTo-Html $item.Date) + '</date>' + $newline +
        '      </div>' + $newline +
        '    </a>'
    }
    $content = $newline + [string]::Join(($newline + $newline), [string[]]$itemsHtml) + $newline + '  '
    $innerStart = $block.Start + $open.Length
    $innerLength = $block.End - 6 - $innerStart
    $html = $html.Substring(0, $innerStart) + $content + $html.Substring($innerStart + $innerLength)
    Save-SiteText $path $html
}

function Get-ShortLinkEntries {
    $shortRoot = Join-Path $script:SiteRoot 'l'
    $items = [Collections.ArrayList]::new()
    if (-not (Test-Path -LiteralPath $shortRoot -PathType Container)) { return ,$items }
    $descriptionMap = @{}
    $metadataPath = Join-Path $script:ToolRoot 'short-links.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $metadataPath -Raw))
            foreach ($entry in $metadata) { if ($entry.Slug) { $descriptionMap[[string]$entry.Slug] = [string]$entry.Description } }
        } catch { Write-ManagerLog "Could not read short link descriptions: $($_.Exception.Message)" 'WARN' }
    }
    $rootPrefix = [IO.Path]::GetFullPath($shortRoot).TrimEnd('\') + '\'
    foreach ($file in (Get-ChildItem -LiteralPath $shortRoot -Filter '*.html' -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\','/')
        if ($relative -ieq 'index.html') { continue }
        $isFolderIndex = $file.Name -ieq 'index.html' -and (Split-Path $relative -Parent)
        if ($isFolderIndex) { $slug = (Split-Path $relative -Parent).Replace('\','/') }
        else { $slug = [IO.Path]::ChangeExtension($relative, $null) }
        $html = [IO.File]::ReadAllText($file.FullName)
        $targetMatch = [regex]::Match($html, '(?is)window\.location\.replace\(\s*["''](?<target>.*?)["'']\s*\)')
        if (-not $targetMatch.Success) { $targetMatch = [regex]::Match($html, '(?is)<meta\b[^>]*http-equiv\s*=\s*["'']?refresh["'']?[^>]*content\s*=\s*["''][^"'']*?url\s*=\s*(?<q>["'']?)(?<target>[^"'';>]+)\k<q>') }
        $target = if ($targetMatch.Success) { [Net.WebUtility]::HtmlDecode($targetMatch.Groups['target'].Value.Trim()) } else { '' }
        $displayPath = if ($isFolderIndex) { $slug } else { $relative }
        [void]$items.Add([pscustomobject]@{
            Slug = $slug
            DisplayPath = $displayPath
            FilePath = $relative
            Target = $target
            Description = if ($descriptionMap.ContainsKey($slug)) { $descriptionMap[$slug] } else { '' }
            IsFolder = [bool]$isFolderIndex
            IsNew = $false
        })
    }
    return ,$items
}

function Save-ShortLinkMetadata {
    $metadataPath = Join-Path $script:ToolRoot 'short-links.json'
    $entries = @($script:ShortLinks | Where-Object { -not $_.IsNew } | ForEach-Object { [pscustomobject]@{Slug=$_.Slug;Description=$_.Description} })
    $json = ConvertTo-Json -InputObject $entries -Depth 4
    [IO.File]::WriteAllText($metadataPath, $json, [Text.UTF8Encoding]::new($true))
}

function Get-ShortLinkAddress([object]$Item) {
    $path = if ($Item.IsFolder) { '/l/' + $Item.Slug.Trim('/') + '/' } else { '/l/' + $Item.FilePath }
    return 'https://muhyiddin.edu.mv' + $path
}

function Refresh-ShortLinkList([int]$SelectIndex = -1) {
    $script:LoadingShortLinkUi = $true
    $script:shortLinkList.Items.Clear()
    foreach ($item in $script:ShortLinks) {
        $state = if ($item.IsNew) { '  |  NEW' } else { '' }
        $summary = if ($item.Description) { $item.Description } else { $item.Target }
        [void]$script:shortLinkList.Items.Add("$($item.Slug)$state  |  $summary")
    }
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $script:shortLinkList.Items.Count) { $script:shortLinkList.SelectedIndex = $SelectIndex }
    $script:shortLinkCount.Text = "$($script:ShortLinks.Count) shortened links"
    $script:LoadingShortLinkUi = $false
    Load-ShortLinkEditor $script:shortLinkList.SelectedIndex
}

function Load-ShortLinkEditor([int]$Index) {
    $script:LoadingShortLinkUi = $true
    if ($Index -lt 0 -or $Index -ge $script:ShortLinks.Count) {
        $script:shortLinkPath.Text=''; $script:shortLinkUrl.Text=''; $script:shortLinkTarget.Text=''; $script:shortLinkDescription.Text=''
        $script:shortLinkPath.ReadOnly=$true; $script:shortLinkStatus.Text='Choose a short link or create a new one.'
    } else {
        $item=$script:ShortLinks[$Index]
        $script:shortLinkPath.Text=if ($item.IsNew) { $item.Slug } else { $item.DisplayPath }
        $script:shortLinkPath.ReadOnly=(-not [bool]$item.IsNew)
        $script:shortLinkUrl.Text=if ($item.IsNew -and $item.Slug) { 'https://muhyiddin.edu.mv/l/' + $item.Slug.Trim('/') + '/' } elseif (-not $item.IsNew) { Get-ShortLinkAddress $item } else { '' }
        $script:shortLinkTarget.Text=$item.Target
        $script:shortLinkDescription.Text=$item.Description
        $script:shortLinkStatus.Text=if ($item.IsNew) { 'Choose a short folder name, destination, and optional note.' } else { 'Edit the destination or internal note, then save this short link.' }
    }
    $script:LoadingShortLinkUi = $false
}

function Save-SelectedShortLink {
    $index=$script:shortLinkList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:ShortLinks.Count) { throw 'Choose a short link or create a new one first.' }
    $item=$script:ShortLinks[$index]
    $target=$script:shortLinkTarget.Text.Trim()
    $description=$script:shortLinkDescription.Text.Trim()
    $uri=$null
    if (-not [Uri]::TryCreate($target,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')) { throw 'Enter a complete destination URL starting with http:// or https://.' }
    if ($item.IsNew) {
        $slug=$script:shortLinkPath.Text.Trim()
        if ($slug -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw 'Use one short folder name with letters, numbers, hyphens, or underscores.' }
        if (@($script:ShortLinks | Where-Object { -not $_.IsNew -and $_.Slug -ieq $slug }).Count) { throw 'A short link with that folder name already exists.' }
        $item.Slug=$slug; $item.DisplayPath=$slug; $item.FilePath=($slug + '/index.html'); $item.IsFolder=$true
    }
    $shortRoot=Join-Path $script:SiteRoot 'l'
    $filePath=Join-Path $shortRoot ($item.FilePath.Replace('/', '\'))
    $rootPrefix=[IO.Path]::GetFullPath($shortRoot).TrimEnd('\')+'\'
    $fullPath=[IO.Path]::GetFullPath($filePath)
    if (-not $fullPath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'The short link path is outside the l folder.' }
    if ($item.IsNew -and (Test-Path -LiteralPath $fullPath)) { throw 'A redirect file already exists at that short path.' }
    $parent=Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $relativeDirectory=Split-Path ($item.FilePath.Replace('/','\')) -Parent
    $directoryDepth=if ($relativeDirectory) { @($relativeDirectory -split '[\\/]' | Where-Object { $_ }).Count } else { 0 }
    $assetPrefix='../' * ($directoryDepth + 1)
    $escapedTarget=ConvertTo-Html $target
    $javascriptTarget=ConvertTo-Json -InputObject $target -Compress
    $html='<!DOCTYPE html>'+[Environment]::NewLine+
        '<html lang="en">'+[Environment]::NewLine+
        '<head>'+[Environment]::NewLine+
        '    <meta charset="UTF-8">'+[Environment]::NewLine+
        '    <meta http-equiv="refresh" content="0; url='+$escapedTarget+'">'+[Environment]::NewLine+
        '    <title>Redirecting...</title>'+[Environment]::NewLine+
        '    <link rel="stylesheet" href="'+$assetPrefix+'styles/image-loading.css">'+[Environment]::NewLine+
        '</head>'+[Environment]::NewLine+
        '<body>'+[Environment]::NewLine+
        '    <script>window.location.replace('+$javascriptTarget+');</script>'+[Environment]::NewLine+
        '    <script src="'+$assetPrefix+'scripts/image-loading.js" defer></script>'+[Environment]::NewLine+
        '</body>'+[Environment]::NewLine+
        '</html>'+[Environment]::NewLine
    Save-SiteText $fullPath $html
    $item.Target=$target; $item.Description=$description; $item.IsNew=$false
    Save-ShortLinkMetadata
    Refresh-ShortLinkList -SelectIndex $index
    $script:shortLinkStatus.Text='Short link saved. Description is stored privately in the manager tool.'
    Write-ManagerLog "Saved shortened link /l/$($item.Slug)."
}

function Get-AlbumNumber([string]$Name) {
    if ($Name -match '^(\d+)\.') { return [int]$Matches[1] }
    return 0
}

function ConvertTo-GalleryDate([string]$Text) {
    $match = [regex]::Match($Text, '^\s*(\d{1,2})[-/](\d{1,2})[-/](\d{4})\s*$')
    if (-not $match.Success) { return $null }
    try {
        $day = [int]$match.Groups[1].Value
        $month = [int]$match.Groups[2].Value
        $year = [int]$match.Groups[3].Value
        $value = [datetime]::new($year, $month, $day)
        return $value.ToString('d-M-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch { return $null }
}

function Get-AlbumDetails([IO.DirectoryInfo]$Directory) {
    $number = Get-AlbumNumber $Directory.Name
    $title = $Directory.Name
    $date = ''
    if ($Directory.Name -match '^\d+\.\s*(.*?)\s*\((.*?)\)\s*$') { $title = $Matches[1].Trim(); $date = $Matches[2].Trim() }
    $cover = Get-ChildItem -LiteralPath $Directory.FullName -File | Where-Object { $_.Name -match '^cover\.(jpg|jpeg|png|gif|webp)$' } | Select-Object -First 1
    return [pscustomobject]@{ Number = $number; Folder = $Directory.Name; Title = $title; Date = $date; Cover = if ($cover) { $cover.Name } else { '' } }
}

function Get-UnlistedAlbumNames {
    $path = Join-Path $script:ToolRoot 'gallery-unlisted.txt'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    # One-time compatibility with the first manager version's JSON state.
    $legacyPath = Join-Path $script:ToolRoot 'gallery-unlisted.json'
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        try { return @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $legacyPath -Raw) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        catch { Write-ManagerLog "Could not read prior unlisted gallery state. $($_.Exception.Message)" 'WARN' }
    }
    return @()
}

function Save-UnlistedAlbumNames([string[]]$Names) {
    $uniqueNames = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $path = Join-Path $script:ToolRoot 'gallery-unlisted.txt'
    [IO.File]::WriteAllLines($path, [string[]]$uniqueNames, [Text.UTF8Encoding]::new($true))
}

function Get-OrderedAlbumDirectories {
    $galleryRoot = Join-Path $script:SiteRoot 'gallery'
    $all = @(Get-ChildItem -LiteralPath $galleryRoot -Directory | Where-Object { (Get-AlbumNumber $_.Name) -gt 0 } | Sort-Object @{Expression={Get-AlbumNumber $_.Name};Descending=$true})
    $hiddenNames = @(Get-UnlistedAlbumNames)
    $listed = @($all | Where-Object { $hiddenNames -notcontains $_.Name })
    $orderPath = Join-Path $script:ToolRoot 'gallery-order.json'
    if (-not (Test-Path -LiteralPath $orderPath -PathType Leaf)) { return $listed }

    try { $savedNames = @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $orderPath -Raw)) }
    catch { Write-ManagerLog "Could not read saved gallery order; using album numbers. $($_.Exception.Message)" 'WARN'; return $listed }
    $rank = @{}
    for ($i = 0; $i -lt $savedNames.Count; $i++) { $rank[[string]$savedNames[$i]] = $i }
    return @($listed | Sort-Object @{Expression={ if ($rank.ContainsKey($_.Name)) { $rank[$_.Name] } else { -100000 - (Get-AlbumNumber $_.Name) } }})
}

function Save-GalleryOrderManifest([string[]]$FolderNames) {
    $names = @($FolderNames)
    $json = ConvertTo-Json -InputObject $names -Depth 3
    [IO.File]::WriteAllText((Join-Path $script:ToolRoot 'gallery-order.json'), $json, [Text.UTF8Encoding]::new($true))
}

function Save-GalleryOrder([string[]]$FolderNames) {
    $galleryRoot = Join-Path $script:SiteRoot 'gallery'
    $allDirectories = @(Get-ChildItem -LiteralPath $galleryRoot -Directory | Where-Object { (Get-AlbumNumber $_.Name) -gt 0 })
    if ($FolderNames.Count -ne $allDirectories.Count) { throw 'The album list changed while ordering. Refresh it and try again.' }

    $operations = [Collections.ArrayList]::new()
    $targetNames = @{}
    for ($i=0; $i -lt $FolderNames.Count; $i++) {
        $oldName = [string]$FolderNames[$i]
        $directory = $allDirectories | Where-Object { $_.Name -ceq $oldName } | Select-Object -First 1
        if (-not $directory) { throw "Album folder not found: $oldName" }
        $folderMatch = [regex]::Match($oldName, '^\d+\.(.*)$')
        if (-not $folderMatch.Success) { throw "Album folder has an unsupported name: $oldName" }
        $newName = ([string]($FolderNames.Count - $i)) + '.' + $folderMatch.Groups[1].Value
        if ($targetNames.ContainsKey($newName)) { throw "Two albums would have the same folder name: $newName" }
        $targetNames[$newName] = $true
        [void]$operations.Add([pscustomobject]@{
            OldName = $oldName
            NewName = $newName
            OldPath = $directory.FullName
            StagePath = Join-Path $galleryRoot ('.manager-reorder-' + [guid]::NewGuid().ToString('N'))
        })
    }

    try {
        foreach ($operation in $operations) { Move-Item -LiteralPath $operation.OldPath -Destination $operation.StagePath }
        foreach ($operation in $operations) { Move-Item -LiteralPath $operation.StagePath -Destination (Join-Path $galleryRoot $operation.NewName) }
    }
    catch {
        for ($reverseIndex=$operations.Count-1; $reverseIndex -ge 0; $reverseIndex--) {
            $operation=$operations[$reverseIndex]
            $current = if (Test-Path -LiteralPath $operation.StagePath -PathType Container) { $operation.StagePath } else { Join-Path $galleryRoot $operation.NewName }
            if ((Test-Path -LiteralPath $current -PathType Container) -and -not (Test-Path -LiteralPath $operation.OldPath)) {
                Move-Item -LiteralPath $current -Destination $operation.OldPath
            }
        }
        throw "Album renumbering failed and was rolled back: $($_.Exception.Message)"
    }

    # Keep any in-site links to album view pages working after the folders change.
    $toolPrefix = $script:ToolRoot.TrimEnd('\') + '\'
    $siteHtmlFiles = Get-ChildItem -LiteralPath $script:SiteRoot -Filter '*.html' -File -Recurse | Where-Object { -not $_.FullName.StartsWith($toolPrefix, [StringComparison]::OrdinalIgnoreCase) }
    foreach ($file in $siteHtmlFiles) {
        $content = Get-SiteText $file.FullName
        $updated = $content
        $tokens = [Collections.ArrayList]::new()
        $tokenId = [guid]::NewGuid().ToString('N')
        for ($i=0; $i -lt $operations.Count; $i++) {
            $operation = $operations[$i]
            $oldEncoded = [Uri]::EscapeDataString($operation.OldName)
            $newEncoded = [Uri]::EscapeDataString($operation.NewName)
            $rawToken = '__GALLERY_RENAME_RAW_' + $tokenId + '_' + $i + '__'
            $encodedToken = '__GALLERY_RENAME_ENCODED_' + $tokenId + '_' + $i + '__'
            $updated = $updated.Replace($oldEncoded, $encodedToken).Replace($operation.OldName, $rawToken)
            [void]$tokens.Add([pscustomobject]@{ RawToken=$rawToken; EncodedToken=$encodedToken; NewName=$operation.NewName; NewEncoded=$newEncoded })
        }
        foreach ($token in $tokens) { $updated = $updated.Replace($token.RawToken, $token.NewName).Replace($token.EncodedToken, $token.NewEncoded) }
        if ($updated -cne $content) { Save-SiteText $file.FullName $updated }
    }

    $newOrder = @($operations | ForEach-Object NewName)
    Save-GalleryOrderManifest ([string[]]$newOrder)
    foreach ($operation in $operations) {
        if ($operation.OldName -cne $operation.NewName) { Write-ManagerLog "Renamed album folder '$($operation.OldName)' to '$($operation.NewName)'." }
    }
    Write-ManagerLog "Saved order for $($operations.Count) album folders."
}

function Set-AlbumListing([string]$FolderName, [bool]$Listed) {
    $hidden = [Collections.ArrayList]::new()
    foreach ($name in (Get-UnlistedAlbumNames)) { if ($name -ne $FolderName) { [void]$hidden.Add([string]$name) } }
    if (-not $Listed -and -not $hidden.Contains($FolderName)) { [void]$hidden.Add($FolderName) }
    Save-UnlistedAlbumNames ([string[]]$hidden.ToArray())
    Update-GalleryPages
    Refresh-AlbumList
    for ($i=0; $i -lt $script:galleryModels.Count; $i++) {
        if ($script:galleryModels[$i].Folder -eq $FolderName) { $script:galleryList.SelectedIndex=$i; break }
    }
    $verb = if ($Listed) { 'listed' } else { 'unlisted; album files were kept' }
    $script:galleryStatus.Text = "Album $verb."
    Write-ManagerLog "Album '$FolderName' $verb."
}

function Remove-GalleryAlbum([string]$FolderName) {
    $galleryRoot = [IO.Path]::GetFullPath((Join-Path $script:SiteRoot 'gallery'))
    $source = [IO.Path]::GetFullPath((Join-Path $galleryRoot $FolderName))
    if (-not $source.StartsWith(($galleryRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The album path is outside the gallery folder.' }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'The album folder no longer exists.' }
    $backupParent = Join-Path $script:BackupRoot ('DeletedAlbums\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
    $backup = Join-Path $backupParent $FolderName
    Copy-Item -LiteralPath $source -Destination $backupParent -Recurse
    if (-not (Test-Path -LiteralPath $backup -PathType Container)) { throw 'The recoverable album backup could not be confirmed; album files were left in place.' }
    Remove-Item -LiteralPath $source -Recurse -Force

    $hidden = @((Get-UnlistedAlbumNames) | Where-Object { $_ -ne $FolderName })
    $remainingAlbums = @(Get-AlbumList | ForEach-Object { $_.Folder })
    Save-GalleryOrderManifest ([string[]]$remainingAlbums)
    Save-UnlistedAlbumNames ([string[]]$hidden)
    Update-GalleryPages
    Refresh-AlbumList
    $script:galleryStatus.Text = "Album files removed. A backup is available in Backups\DeletedAlbums."
    Write-ManagerLog "Removed album '$FolderName'; recoverable copy saved in $backup."
    return $backup
}

function Update-UndoDeleteButton {
    if (-not $script:undoDeleteButton) { return }
    $script:undoDeleteButton.Enabled = $script:UndoDeleteStack.Count -gt 0
    if ($script:UndoDeleteStack.Count) {
        $last = $script:UndoDeleteStack[$script:UndoDeleteStack.Count - 1]
        $script:undoDeleteTip.SetToolTip($script:undoDeleteButton, "Undo the most recent delete: $($last.Description)")
    } else { $script:undoDeleteTip.SetToolTip($script:undoDeleteButton, 'Undo the most recent deletion from this manager session.') }
}

function Register-UndoDelete([object]$Record) {
    [void]$script:UndoDeleteStack.Add($Record)
    Update-UndoDeleteButton
}

function Undo-LastDelete {
    if (-not $script:UndoDeleteStack.Count) { return }
    $record = $script:UndoDeleteStack[$script:UndoDeleteStack.Count - 1]
    try {
        switch ($record.Kind) {
            'GalleryAlbum' {
                $galleryRoot = Join-Path $script:SiteRoot 'gallery'
                $destination = Join-Path $galleryRoot $record.Folder
                if (Test-Path -LiteralPath $destination) { throw "Cannot restore '$($record.Folder)' because a folder with that name already exists." }
                if (-not (Test-Path -LiteralPath $record.Backup -PathType Container)) { throw 'The recoverable album backup could not be found.' }
                Copy-Item -LiteralPath $record.Backup -Destination $galleryRoot -Recurse
                $hidden = [Collections.ArrayList]::new()
                foreach ($name in (Get-UnlistedAlbumNames)) { if ($name -ne $record.Folder) { [void]$hidden.Add([string]$name) } }
                if (-not $record.IsListed -and -not $hidden.Contains($record.Folder)) { [void]$hidden.Add([string]$record.Folder) }
                Save-UnlistedAlbumNames ([string[]]$hidden.ToArray())
                $models = [Collections.ArrayList]::new()
                foreach ($model in (Get-AlbumList)) { [void]$models.Add($model) }
                $restored = Get-AlbumDetails (Get-Item -LiteralPath $destination)
                $restored | Add-Member -NotePropertyName IsListed -NotePropertyValue ([bool]$record.IsListed)
                $insertAt = [Math]::Max(0, [Math]::Min([int]$record.DisplayIndex, $models.Count))
                $models.Insert($insertAt, $restored)
                Save-GalleryOrder ([string[]]@($models | ForEach-Object { $_.Folder }))
                Update-GalleryPages
                Refresh-AlbumList
                $script:galleryStatus.Text = "Restored album '$($record.Title)' and rebuilt the gallery."
            }
            'Update' {
                $script:Updates.Insert([Math]::Min([int]$record.Index, $script:Updates.Count), $record.Item)
                Refresh-UpdateList -SelectIndex $record.Index
                Load-UpdateEditor $record.Index
            }
            'ShortLink' {
                $shortRoot=Join-Path $script:SiteRoot 'l'
                $destination=Join-Path $shortRoot ($record.Item.FilePath.Replace('/', '\'))
                if (Test-Path -LiteralPath $destination) { throw 'A file or folder already exists at the original short link path.' }
                if (-not (Test-Path -LiteralPath $record.Backup)) { throw 'The recoverable short link backup could not be found.' }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                Copy-Item -LiteralPath $record.Backup -Destination (Split-Path -Parent $destination) -Recurse
                $script:ShortLinks.Insert([Math]::Min([int]$record.Index, $script:ShortLinks.Count), $record.Item)
                Save-ShortLinkMetadata
                Refresh-ShortLinkList -SelectIndex $record.Index
                $script:shortLinkStatus.Text='Short link restored.'
            }
            'ShortLinkDraft' {
                $script:ShortLinks.Insert([Math]::Min([int]$record.Index, $script:ShortLinks.Count), $record.Item)
                Refresh-ShortLinkList -SelectIndex $record.Index
            }
            'GalleryImage' {
                $albumPath=Join-Path (Join-Path $script:SiteRoot 'gallery') $record.Folder
                if (-not (Test-Path -LiteralPath $albumPath -PathType Container)) { throw 'The original gallery album no longer exists.' }
                if (-not (Test-Path -LiteralPath $record.Backup -PathType Leaf)) { throw 'The recoverable image backup could not be found.' }
                $destination=Join-Path $albumPath $record.FileName
                $promotedTarget=if ($record.PromotedTo) { Join-Path $albumPath $record.PromotedTo } else { '' }
                if ((Test-Path -LiteralPath $destination) -and (-not $promotedTarget -or $destination -ne $promotedTarget)) { throw "An image named '$($record.FileName)' already exists in this album." }
                if ($promotedTarget -and (Test-Path -LiteralPath $promotedTarget)) {
                    $promotedOriginal=Join-Path $albumPath $record.PromotedFrom
                    if (Test-Path -LiteralPath $promotedOriginal) { throw "Cannot restore the former cover because '$($record.PromotedFrom)' already exists." }
                    Move-Item -LiteralPath $promotedTarget -Destination $promotedOriginal
                }
                if (Test-Path -LiteralPath $destination) { throw "An image named '$($record.FileName)' already exists in this album." }
                Copy-Item -LiteralPath $record.Backup -Destination $albumPath
                Update-GalleryPages
                Refresh-AlbumList
                for ($albumIndex=0; $albumIndex -lt $script:galleryModels.Count; $albumIndex++) { if ($script:galleryModels[$albumIndex].Folder -eq $record.Folder) { $script:galleryList.SelectedIndex=$albumIndex; break } }
                Load-AlbumImageGallery -SelectImage $record.FileName
                $script:albumImageStatus.Text="Restored '$($record.FileName)' and rebuilt this album's gallery page."
            }
            'ResourceSection' {
                $models = $script:ResourceModels[$record.Page]
                $models.Insert([Math]::Min([int]$record.Index, $models.Count), $record.Section)
                if ($script:CurrentResourcePage -eq $record.Page) { Refresh-ResourceSectionList -SelectIndex $record.Index }
                $script:resourceStatus.Text = 'Section restored in the editor. Save changes to this page to apply it.'
            }
            'ResourceLink' {
                $sectionIndex = -1
                for ($candidate = 0; $candidate -lt $script:ResourceModels[$record.Page].Count; $candidate++) {
                    if ([object]::ReferenceEquals($script:ResourceModels[$record.Page][$candidate], $record.Section)) { $sectionIndex = $candidate; break }
                }
                if ($sectionIndex -lt 0) {
                    $matchingSectionIndices = @()
                    for ($candidate = 0; $candidate -lt $script:ResourceModels[$record.Page].Count; $candidate++) {
                        $section = $script:ResourceModels[$record.Page][$candidate]
                        if ($section.English -ceq $record.SectionEnglish -and $section.Dhivehi -ceq $record.SectionDhivehi) { $matchingSectionIndices += $candidate }
                    }
                    if ($matchingSectionIndices.Count -eq 1) { $sectionIndex = $matchingSectionIndices[0] }
                    elseif ($record.SectionIndex -ge 0 -and $record.SectionIndex -lt $script:ResourceModels[$record.Page].Count) { $sectionIndex = $record.SectionIndex }
                }
                if ($sectionIndex -lt 0) { throw 'The original resource section could not be identified. It may have been removed.' }
                $items = $script:ResourceModels[$record.Page][$sectionIndex].Items
                $items.Insert([Math]::Min([int]$record.Index, $items.Count), $record.Item)
                if ($script:CurrentResourcePage -eq $record.Page) {
                    Refresh-ResourceSectionList -SelectIndex $sectionIndex
                    $script:resourceItems.SelectedIndex = $record.Index
                }
                $script:resourceStatus.Text = 'Link restored in the editor. Save changes to this page to apply it.'
            }
            default { throw 'This deletion type cannot be restored.' }
        }
        $script:UndoDeleteStack.RemoveAt($script:UndoDeleteStack.Count - 1)
        Update-UndoDeleteButton
        Write-ManagerLog "Undid deletion: $($record.Description)."
    }
    catch {
        Write-ManagerLog "Undo failed: $($_.Exception.Message)" 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Undo could not be completed','OK','Error') | Out-Null
    }
}

function Update-GalleryPages {
    $galleryRoot = Join-Path $script:SiteRoot 'gallery'
    $viewTemplatePath = Join-Path $script:SiteRoot 'sample\gallery\view.html'
    $galleryTemplatePath = Join-Path $script:SiteRoot 'sample\gallery\gallery.html'
    $viewTemplate = Get-SiteText $viewTemplatePath
    $galleryTemplate = Get-SiteText $galleryTemplatePath
    # The shared gallery template lives two folders down; root gallery.html does not.
    $galleryTemplate = $galleryTemplate.Replace('../../', '')
    $allAlbums = @(Get-ChildItem -LiteralPath $galleryRoot -Directory | Where-Object { (Get-AlbumNumber $_.Name) -gt 0 })
    $albums = @(Get-OrderedAlbumDirectories)
    foreach ($directory in $allAlbums) {
        $details = Get-AlbumDetails $directory
        $photos = @(Get-ChildItem -LiteralPath $directory.FullName -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|gif|webp)$' } | Sort-Object @{Expression={if ($_.Name -match '^cover\.') { 0 } else { 1 } }}, Name)
        if (-not $photos.Count) { throw "Album '$($directory.Name)' has no supported images." }
        $imageHtml = foreach ($photo in $photos) {
            $src = [Uri]::EscapeDataString($photo.Name)
            '            <img class="image" src="' + $src + '" loading="lazy" decoding="async">'
        }
        $page = $viewTemplate.Replace('{{TITLE}}', (ConvertTo-Html $details.Title)).Replace('{{DATE}}', (ConvertTo-Html $details.Date)).Replace('{{IMAGE_LIST}}', ($imageHtml -join [Environment]::NewLine))
        Save-SiteText (Join-Path $directory.FullName 'view.html') $page
    }
    $cards = foreach ($directory in $albums) {
        $details = Get-AlbumDetails $directory
        if (-not $details.Cover) { throw "Album '$($directory.Name)' needs a cover.jpg, cover.png, or supported cover image." }
        $folderUrl = [Uri]::EscapeDataString($directory.Name)
        $coverUrl = [Uri]::EscapeDataString($details.Cover)
        '    <a href="gallery/' + $folderUrl + '/view.html">' + [Environment]::NewLine +
        '      <div class="light_card">' + [Environment]::NewLine +
        '        <img class="image" src="gallery/' + $folderUrl + '/' + $coverUrl + '" loading="lazy" decoding="async">' + [Environment]::NewLine +
        '        <h6>' + (ConvertTo-Html $details.Title) + '</h6>' + [Environment]::NewLine +
        '        <date>' + (ConvertTo-Html $details.Date) + '</date>' + [Environment]::NewLine +
        '      </div>' + [Environment]::NewLine +
        '    </a>'
    }
    $galleryPage = $galleryTemplate.Replace('{{ALBUM_LIST}}', ($cards -join ([Environment]::NewLine + [Environment]::NewLine)))
    Save-SiteText (Join-Path $script:SiteRoot 'gallery.html') $galleryPage
    Write-ManagerLog "Gallery generated from $($albums.Count) numbered album folders."
}

function Update-AlbumImageControls {
    if (-not $script:addAlbumImage) { return }
    $hasAlbum=$script:galleryList.SelectedIndex -ge 0 -and $script:galleryList.SelectedIndex -lt $script:galleryModels.Count
    $script:addAlbumImage.Enabled=$hasAlbum
    $script:removeAlbumImage.Enabled=$hasAlbum -and -not [string]::IsNullOrWhiteSpace($script:SelectedAlbumImageName)
}

function Select-AlbumImage([string]$Name) {
    $script:SelectedAlbumImageName=$Name
    $script:albumImageStatus.Text="Selected: $Name"
    foreach ($tile in $script:albumImageFlow.Controls) {
        if ($tile.Tag -eq $Name) { $tile.BackColor=[Drawing.Color]::FromArgb(255,239,239); $tile.Padding=[Windows.Forms.Padding]::new(2); $tile.BorderStyle='Fixed3D' }
        else { $tile.BackColor=[Drawing.Color]::White; $tile.Padding=[Windows.Forms.Padding]::new(0); $tile.BorderStyle='FixedSingle' }
    }
    Update-AlbumImageControls
}

function Clear-AlbumImageTiles {
    foreach ($tile in @($script:albumImageFlow.Controls)) {
        foreach ($child in @($tile.Controls)) {
            if ($child -is [Windows.Forms.PictureBox] -and $child.Image) { $oldImage=$child.Image; $child.Image=$null; $oldImage.Dispose() }
            $child.Dispose()
        }
        $tile.Dispose()
    }
    $script:albumImageFlow.Controls.Clear()
}

function Load-AlbumImageGallery([string]$SelectImage = '') {
    Clear-AlbumImageTiles
    $script:SelectedAlbumImageName=$SelectImage
    $index=$script:galleryList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:galleryModels.Count) {
        $script:albumImageHeading.Text='Select an album to view its images'
        $script:albumImageCount.Text='0 images'
        $script:albumImageStatus.Text='Choose an album on the left. Its photos will appear here.'
        Update-AlbumImageControls
        return
    }
    $album=$script:galleryModels[$index]
    $albumPath=Join-Path (Join-Path $script:SiteRoot 'gallery') $album.Folder
    $script:albumImageHeading.Text="$($album.Title)  |  $($album.Date)"
    $photos=@(Get-ChildItem -LiteralPath $albumPath -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|gif|webp)$' } | Sort-Object @{Expression={if ($_.Name -match '^cover\.(jpg|jpeg|png|gif|webp)$') { 0 } else { 1 } }}, Name)
    $script:albumImageCount.Text="$($photos.Count) images"
    if (-not $photos.Count) { $script:albumImageStatus.Text='This album has no supported image files.'; Update-AlbumImageControls; return }
    foreach ($photo in $photos) {
        $tile=[Windows.Forms.Panel]::new(); $tile.Size=[Drawing.Size]::new(150,136); $tile.Margin=[Windows.Forms.Padding]::new(6); $tile.BackColor=[Drawing.Color]::White; $tile.BorderStyle='FixedSingle'; $tile.Tag=$photo.Name
        $preview=[Windows.Forms.PictureBox]::new(); $preview.Location=[Drawing.Point]::new(5,5); $preview.Size=[Drawing.Size]::new(138,96); $preview.SizeMode='Zoom'; $preview.BackColor=[Drawing.Color]::FromArgb(244,242,242); $preview.Tag=$photo.Name
        $source=$null
        try {
            $source=[Drawing.Image]::FromFile($photo.FullName)
            $scale=[Math]::Min(138.0/$source.Width,96.0/$source.Height)
            $thumbWidth=[Math]::Max(1,[int][Math]::Round($source.Width*$scale)); $thumbHeight=[Math]::Max(1,[int][Math]::Round($source.Height*$scale))
            $preview.Image=[Drawing.Bitmap]::new($source,$thumbWidth,$thumbHeight)
        } catch { $preview.BackColor=[Drawing.Color]::FromArgb(231,224,224) }
        finally { if ($source) { $source.Dispose() } }
        $caption=New-UiLabel $photo.Name 6 106 136 24 $true; $caption.AutoEllipsis=$true; $caption.Tag=$photo.Name
        $tile.Controls.Add($preview); $tile.Controls.Add($caption)
        $tile.Add_Click({ param($sender,$eventArgs) Select-AlbumImage ([string]$sender.Tag) })
        $preview.Add_Click({ param($sender,$eventArgs) Select-AlbumImage ([string]$sender.Tag) })
        $caption.Add_Click({ param($sender,$eventArgs) Select-AlbumImage ([string]$sender.Tag) })
        [void]$script:albumImageFlow.Controls.Add($tile)
    }
    $script:albumImageStatus.Text=if ($SelectImage) { "Selected: $SelectImage" } else { 'Select an image to remove it.' }
    if ($SelectImage) { Select-AlbumImage $SelectImage } else { Update-AlbumImageControls }
}

function Add-AlbumImages {
    $index=$script:galleryList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:galleryModels.Count) { $script:albumImageStatus.Text='Select an album first.'; return }
    $dialog=[Windows.Forms.OpenFileDialog]::new(); $dialog.Title='Add images to this album'; $dialog.Filter='Image files|*.jpg;*.jpeg;*.png;*.gif;*.webp|All files|*.*'; $dialog.Multiselect=$true
    if ($dialog.ShowDialog($script:form) -ne [Windows.Forms.DialogResult]::OK) { return }
    $album=$script:galleryModels[$index]; $albumPath=Join-Path (Join-Path $script:SiteRoot 'gallery') $album.Folder; $added=0
    try {
        foreach ($source in $dialog.FileNames) {
            if ([IO.Path]::GetExtension($source) -notmatch '^\.(jpg|jpeg|png|gif|webp)$') { continue }
            $name=[IO.Path]::GetFileName($source); $target=Join-Path $albumPath $name
            if (Test-Path -LiteralPath $target) {
                $base=[IO.Path]::GetFileNameWithoutExtension($name); $extension=[IO.Path]::GetExtension($name); $suffix=2
                do { $name="$base ($suffix)$extension"; $target=Join-Path $albumPath $name; $suffix++ } while (Test-Path -LiteralPath $target)
            }
            Copy-Item -LiteralPath $source -Destination $target
            $added++
        }
        if (-not $added) { throw 'No supported image files were selected.' }
        Update-GalleryPages
        Load-AlbumImageGallery
        $script:albumImageStatus.Text="Added $added image(s) to '$($album.Title)' and rebuilt its gallery page."
        Write-ManagerLog "Added $added image(s) to gallery album '$($album.Folder)'."
    } catch {
        $script:albumImageStatus.Text="Could not add images: $($_.Exception.Message)"
        Write-ManagerLog $script:albumImageStatus.Text 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not add album images','OK','Error') | Out-Null
    }
}

function Remove-SelectedAlbumImage {
    $index=$script:galleryList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:galleryModels.Count -or -not $script:SelectedAlbumImageName) { return }
    $album=$script:galleryModels[$index]; $albumPath=Join-Path (Join-Path $script:SiteRoot 'gallery') $album.Folder
    $name=$script:SelectedAlbumImageName; $source=Join-Path $albumPath $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $script:albumImageStatus.Text='That image file no longer exists.'; Load-AlbumImageGallery; return }
    $photos=@(Get-ChildItem -LiteralPath $albumPath -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|gif|webp)$' })
    if ($photos.Count -le 1) { $script:albumImageStatus.Text='An album must keep at least one image. Add another image before removing this one.'; return }
    $answer=[Windows.Forms.MessageBox]::Show($script:form,"Remove '$name' from '$($album.Title)'? Its file will be backed up so Undo delete can restore it.",'Remove album image','YesNo','Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $backupParent=Join-Path $script:BackupRoot ('DeletedAlbumImages\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
        $backup=Join-Path $backupParent $name
        Copy-Item -LiteralPath $source -Destination $backup
        $cover=$album.Cover; $promotedFrom=''; $promotedTo=''
        $isCover=[string]::Equals($cover,$name,[StringComparison]::OrdinalIgnoreCase)
        $otherCovers=@($photos | Where-Object { $_.Name -ne $name -and $_.Name -match '^cover\.(jpg|jpeg|png|gif|webp)$' })
        $replacement=$null
        if ($isCover -and -not $otherCovers.Count) { $replacement=$photos | Where-Object { $_.Name -ne $name } | Sort-Object Name | Select-Object -First 1 }
        Remove-Item -LiteralPath $source -Force
        if ($replacement) {
            $promotedFrom=$replacement.Name; $promotedTo='cover'+$replacement.Extension.ToLowerInvariant()
            try { Move-Item -LiteralPath (Join-Path $albumPath $promotedFrom) -Destination (Join-Path $albumPath $promotedTo) }
            catch { Copy-Item -LiteralPath $backup -Destination $source; throw }
        }
        Register-UndoDelete ([pscustomobject]@{Kind='GalleryImage';Description="image '$name' from '$($album.Title)'";Folder=$album.Folder;FileName=$name;Backup=$backup;PromotedFrom=$promotedFrom;PromotedTo=$promotedTo})
        Update-GalleryPages
        Refresh-AlbumList $index
        Load-AlbumImageGallery
        $script:albumImageStatus.Text="Removed '$name' from the album. Use Undo delete to restore it."
        Write-ManagerLog "Removed image '$name' from album '$($album.Folder)'; recoverable copy saved in $backup."
    } catch {
        $script:albumImageStatus.Text="Could not remove image: $($_.Exception.Message)"
        Write-ManagerLog $script:albumImageStatus.Text 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not remove album image','OK','Error') | Out-Null
    }
}

function New-UiLabel([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 22, [bool]$Muted = $false) {
    $control = [Windows.Forms.Label]::new()
    $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X, $Y)
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $control.ForeColor = if ($Muted) { [Drawing.Color]::FromArgb(112, 108, 108) } else { [Drawing.Color]::FromArgb(46, 42, 42) }
    $control.Font = [Drawing.Font]::new('Segoe UI', 9)
    return $control
}

function New-UiTextBox([int]$X, [int]$Y, [int]$Width, [int]$Height = 30, [bool]$Multiline = $false) {
    $control = [Windows.Forms.TextBox]::new()
    $control.Location = [Drawing.Point]::new($X, $Y)
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $control.BorderStyle = 'FixedSingle'
    $control.BackColor = [Drawing.Color]::White
    $control.Font = [Drawing.Font]::new('Segoe UI', 9.5)
    $control.Multiline = $Multiline
    return $control
}

function New-UiButton([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 34, [bool]$Primary = $false) {
    $control = [Windows.Forms.Button]::new()
    $control.Text = $Text
    $control.Location = [Drawing.Point]::new($X, $Y)
    $control.Size = [Drawing.Size]::new($Width, $Height)
    $control.FlatStyle = 'Flat'
    $control.Font = [Drawing.Font]::new('Segoe UI Semibold', 9)
    if ($Primary) {
        $control.BackColor = [Drawing.Color]::FromArgb(151, 39, 43)
        $control.ForeColor = [Drawing.Color]::White
        $control.FlatAppearance.BorderSize = 0
        $control.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(125, 31, 36)
    }
    else {
        $control.BackColor = [Drawing.Color]::White
        $control.ForeColor = [Drawing.Color]::FromArgb(87, 55, 55)
        $control.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(224, 215, 215)
        $control.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(250, 240, 240)
    }
    return $control
}

function Get-AlbumList {
    $listedDirs = @(Get-OrderedAlbumDirectories)
    $allDirs = @(Get-ChildItem -LiteralPath (Join-Path $script:SiteRoot 'gallery') -Directory | Where-Object { (Get-AlbumNumber $_.Name) -gt 0 } | Sort-Object @{Expression={Get-AlbumNumber $_.Name};Descending=$true})
    $result = [Collections.ArrayList]::new()
    foreach ($directory in $listedDirs) { $details=Get-AlbumDetails $directory; $details | Add-Member -NotePropertyName IsListed -NotePropertyValue $true; [void]$result.Add($details) }
    foreach ($directory in $allDirs) {
        if ($directory.Name -notin @($listedDirs | ForEach-Object Name)) { $details=Get-AlbumDetails $directory; $details | Add-Member -NotePropertyName IsListed -NotePropertyValue $false; [void]$result.Add($details) }
    }
    return $result.ToArray()
}

function Draw-AlbumList([int]$SelectIndex = -1) {
    $script:galleryList.Items.Clear()
    foreach ($album in $script:galleryModels) {
        $visibility = if ($album.IsListed) { 'LISTED' } else { 'UNLISTED' }
        $coverState = if ($album.Cover) { 'cover ready' } else { 'cover missing' }
        [void]$script:galleryList.Items.Add(('{0}. {1}  |  {2}  |  {3}  |  {4}' -f $album.Number, $album.Title, $album.Date, $visibility, $coverState))
    }
    $listedCount = @($script:galleryModels | Where-Object { $_.IsListed }).Count
    $unlistedCount = $script:galleryModels.Count - $listedCount
    $script:galleryCount.Text = "$listedCount listed | $unlistedCount unlisted | $($script:galleryModels.Count) total"
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $script:galleryList.Items.Count) { $script:galleryList.SelectedIndex = $SelectIndex }
    Update-GalleryAlbumControls
}

function Update-GalleryAlbumControls {
    $index = $script:galleryList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:galleryModels.Count) {
        $moveAlbumUp.Enabled=$false; $moveAlbumDown.Enabled=$false; $albumUnlist.Enabled=$false; $albumRelist.Enabled=$false; $albumDelete.Enabled=$false
        return
    }
    $album=$script:galleryModels[$index]
    $albumUnlist.Enabled=[bool]$album.IsListed; $albumRelist.Enabled=(-not [bool]$album.IsListed); $albumDelete.Enabled=$true
    $canMoveUp=$album.IsListed -and $index -gt 0 -and $script:galleryModels[$index-1].IsListed
    $canMoveDown=$album.IsListed -and $index -lt $script:galleryModels.Count-1 -and $script:galleryModels[$index+1].IsListed
    $moveAlbumUp.Enabled=$canMoveUp; $moveAlbumDown.Enabled=$canMoveDown
}

function Refresh-AlbumList([int]$SelectIndex = -1) {
    $script:galleryModels = @(Get-AlbumList)
    Draw-AlbumList $SelectIndex
}

function Set-GallerySource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $script:GalleryImages = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|gif|webp)$' } | Sort-Object Name)
    $script:galleryFolder.Text = $Path
    $script:coverChoice.Items.Clear()
    foreach ($image in $script:GalleryImages) { [void]$script:coverChoice.Items.Add($image.Name) }
    $script:coverChoice.Enabled = $script:GalleryImages.Count -gt 0
    if ($script:coverChoice.Enabled) { $script:coverChoice.SelectedIndex = 0 }
    $script:galleryStatus.Text = if ($script:GalleryImages.Count) { "$($script:GalleryImages.Count) photos ready to import." } else { 'No JPG, PNG, GIF, or WebP photos found in that folder.' }
    if (-not $script:GalleryImages.Count) { Clear-GalleryCoverPreview }
}

function Clear-GalleryCoverPreview {
    if ($script:coverPreview.Image) { $old=$script:coverPreview.Image; $script:coverPreview.Image=$null; $old.Dispose() }
}

function Update-GalleryCoverPreview {
    if (-not $script:GalleryImages.Count -or $script:coverChoice.SelectedIndex -lt 0) { Clear-GalleryCoverPreview; return }
    $file = $script:GalleryImages[$script:coverChoice.SelectedIndex]
    try {
        $source = [Drawing.Image]::FromFile($file.FullName)
        $scale = [Math]::Min(172.0 / $source.Width, 100.0 / $source.Height)
        $width = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
        $thumb = [Drawing.Bitmap]::new($source, $width, $height)
        $source.Dispose()
        Clear-GalleryCoverPreview
        $script:coverPreview.Image = $thumb
    }
    catch { Clear-GalleryCoverPreview; $script:galleryStatus.Text = "Cover preview unavailable: $($_.Exception.Message)" }
}

function Refresh-UpdateList([int]$SelectIndex = -1) {
    $script:LoadingUpdateUi = $true
    $script:updateList.Items.Clear()
    foreach ($item in $script:Updates) { [void]$script:updateList.Items.Add("$($item.Tag)  |  $($item.Title)") }
    if ($script:Updates.Count -and $SelectIndex -ge 0 -and $SelectIndex -lt $script:Updates.Count) { $script:updateList.SelectedIndex = $SelectIndex }
    $script:updateCount.Text = "$($script:Updates.Count) homepage updates"
    $script:LoadingUpdateUi = $false
    Load-UpdateEditor $script:updateList.SelectedIndex
}

function Load-UpdateEditor([int]$Index) {
    $script:CurrentUpdateIndex = $Index
    if ($Index -lt 0 -or $Index -ge $script:Updates.Count) {
        $script:updateTag.Text = ''; $script:updateTitle.Text = ''; $script:updateDate.Text = ''; $script:updateHref.Text = ''
        return
    }
    $item = $script:Updates[$Index]
    $script:updateTag.Text = $item.Tag
    $script:updateTitle.Text = $item.Title
    $script:updateDate.Text = $item.Date
    $script:updateHref.Text = $item.Href
}

function Commit-UpdateEditor {
    if ($script:CurrentUpdateIndex -lt 0 -or $script:CurrentUpdateIndex -ge $script:Updates.Count) { return }
    $item = $script:Updates[$script:CurrentUpdateIndex]
    $item.Tag = $script:updateTag.Text.Trim()
    $item.Title = $script:updateTitle.Text.Trim()
    $item.Date = $script:updateDate.Text.Trim()
    $item.Href = $script:updateHref.Text.Trim()
}

function Refresh-ResourceSectionList([int]$SelectIndex = -1) {
    $script:LoadingResourceUi = $true
    $script:resourceSections.Items.Clear()
    $models = $script:ResourceModels[$script:CurrentResourcePage]
    foreach ($section in $models) {
        $label = $section.English
        if ($section.Dhivehi) { $label += '  |  ' + $section.Dhivehi }
        [void]$script:resourceSections.Items.Add($label)
    }
    if ($models.Count -and $SelectIndex -ge 0 -and $SelectIndex -lt $models.Count) { $script:resourceSections.SelectedIndex = $SelectIndex }
    $script:LoadingResourceUi = $false
    Load-ResourceSection $script:resourceSections.SelectedIndex
}

function Load-ResourceItem([int]$Index) {
    $script:LoadingResourceUi = $true
    $script:CurrentItemIndex = $Index
    $sectionIndex = $script:resourceSections.SelectedIndex
    if ($sectionIndex -lt 0 -or $sectionIndex -ge $script:ResourceModels[$script:CurrentResourcePage].Count -or $Index -lt 0) {
        $script:resourceItemName.Text = ''; $script:resourceItemHref.Text = ''; $script:resourceItemHref.ReadOnly = $false
        $script:LoadingResourceUi = $false
        return
    }
    $items = $script:ResourceModels[$script:CurrentResourcePage][$sectionIndex].Items
    if ($Index -ge $items.Count) { $script:resourceItemName.Text = ''; $script:resourceItemHref.Text = ''; $script:LoadingResourceUi = $false; return }
    $item = $items[$Index]
    $script:resourceItemName.Text = $item.Name
    $script:resourceItemHref.Text = $item.Href
    $script:resourceItemHref.ReadOnly = [bool]$item.SourceFile
    $script:LoadingResourceUi = $false
}

function Load-ResourceSection([int]$Index) {
    $script:LoadingResourceUi = $true
    $script:CurrentSectionIndex = $Index
    $script:CurrentItemIndex = -1
    $script:resourceItems.Items.Clear()
    if ($Index -lt 0 -or $Index -ge $script:ResourceModels[$script:CurrentResourcePage].Count) {
        $script:resourceEnglish.Text = ''; $script:resourceDhivehi.Text = ''
        $script:resourceItemName.Text = ''; $script:resourceItemHref.Text = ''
        $script:resourceSectionTitle.Text = 'Choose or add a section'
        $script:LoadingResourceUi = $false
        return
    }
    $section = $script:ResourceModels[$script:CurrentResourcePage][$Index]
    $script:resourceEnglish.Text = $section.English
    $script:resourceDhivehi.Text = $section.Dhivehi
    $script:resourceSectionTitle.Text = $section.English
    foreach ($item in $section.Items) { [void]$script:resourceItems.Items.Add($item.Name) }
    if ($section.Items.Count) { $script:resourceItems.SelectedIndex = 0; Load-ResourceItem 0 }
    else { Load-ResourceItem -1 }
    $script:LoadingResourceUi = $false
    Update-ResourceOrderControls
}

function Update-ResourceOrderControls {
    if (-not $script:resourceMoveUp) { return }
    $sectionIndex = $script:resourceSections.SelectedIndex
    $sectionCount = $script:ResourceModels[$script:CurrentResourcePage].Count
    $script:resourceMoveUp.Enabled = $sectionIndex -gt 0
    $script:resourceMoveDown.Enabled = $sectionIndex -ge 0 -and $sectionIndex -lt ($sectionCount - 1)
    $itemIndex = $script:resourceItems.SelectedIndex
    $itemCount = 0
    if ($sectionIndex -ge 0 -and $sectionIndex -lt $sectionCount) { $itemCount = $script:ResourceModels[$script:CurrentResourcePage][$sectionIndex].Items.Count }
    $script:itemMoveUp.Enabled = $itemIndex -gt 0
    $script:itemMoveDown.Enabled = $itemIndex -ge 0 -and $itemIndex -lt ($itemCount - 1)
}

function Refresh-ResourcePage([string]$Page) {
    $script:CurrentResourcePage = $Page
    if (-not $script:ResourceModels.ContainsKey($Page)) { $script:ResourceModels[$Page] = Get-ResourceSections (Join-Path $script:SiteRoot $Page) }
    Refresh-ResourceSectionList -SelectIndex 0
    $script:resourcePageName.Text = (Get-ResourcePageName $Page)
}

function Add-ResourceFile {
    $sectionIndex = $script:resourceSections.SelectedIndex
    if ($sectionIndex -lt 0) {
        $script:resourceStatus.Text = 'Add or select a section first.'
        return
    }
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Choose a form, document, or policy file'
    $dialog.Filter = 'Documents and files|*.pdf;*.doc;*.docx;*.xls;*.xlsx;*.ppt;*.pptx;*.png;*.jpg;*.jpeg;*.zip|All files|*.*'
    if ($dialog.ShowDialog($script:form) -ne [Windows.Forms.DialogResult]::OK) { return }
    $section = $script:ResourceModels[$script:CurrentResourcePage][$sectionIndex]
    $name = [IO.Path]::GetFileName($dialog.FileName)
    $display = [IO.Path]::GetFileNameWithoutExtension($name)
    $folder = [regex]::Replace($section.English, '[^\w -]', '').Trim().TrimEnd('.', ' ')
    if (-not $folder) { $folder = 'Files' }
    $pageFolder = if ($script:CurrentResourcePage -eq 'Policies.html') { 'documents' } else { [IO.Path]::GetFileNameWithoutExtension($script:CurrentResourcePage) }
    $href = ($pageFolder + '/' + $folder + '/' + $name) -replace '\\', '/'
    [void]$section.Items.Add([pscustomobject]@{ Name = $display; Href = $href; SourceFile = $dialog.FileName })
    Refresh-ResourceSectionList -SelectIndex $sectionIndex
    $script:resourceItems.SelectedIndex = $section.Items.Count - 1
    $script:resourceStatus.Text = 'File queued. Save changes to copy it into the website.'
}

# Window shell
$script:form = [Windows.Forms.Form]::new()
$script:form.Text = 'Muhyiddin School | Website Manager'
$script:form.StartPosition = 'CenterScreen'
$script:form.ClientSize = [Drawing.Size]::new(1160, 850)
$script:form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$script:form.MaximizeBox = $false
$script:form.Font = [Drawing.Font]::new('Segoe UI', 9)
$script:form.BackColor = [Drawing.Color]::FromArgb(246, 245, 245)

$top = [Windows.Forms.Panel]::new()
$top.Location = [Drawing.Point]::new(0, 0); $top.Size = [Drawing.Size]::new(1160, 82)
$top.Add_Paint({ param($sender, $e) $b=[Drawing.Drawing2D.LinearGradientBrush]::new($sender.ClientRectangle,[Drawing.Color]::FromArgb(157,42,47),[Drawing.Color]::FromArgb(105,27,34),0); $e.Graphics.FillRectangle($b,$sender.ClientRectangle); $b.Dispose() })
$script:form.Controls.Add($top)
$brand = New-UiLabel 'MUHYIDDIN SCHOOL' 94 12 420 18
$brand.ForeColor = [Drawing.Color]::FromArgb(255, 231, 231); $brand.BackColor = [Drawing.Color]::Transparent; $brand.Font = [Drawing.Font]::new('Segoe UI Semibold', 8.5); $top.Controls.Add($brand)
$title = New-UiLabel 'Website Manager (Embedded) v1.0.0' 92 31 500 40
$title.ForeColor = [Drawing.Color]::White; $title.BackColor = [Drawing.Color]::Transparent; $title.Font = [Drawing.Font]::new('Segoe UI Semibold', 21); $top.Controls.Add($title)
$credit = New-UiLabel 'Developed by saaiqSAS, backed by Codex' 700 54 430 18 $true
$credit.ForeColor = [Drawing.Color]::FromArgb(255, 232, 232); $credit.BackColor = [Drawing.Color]::Transparent; $credit.TextAlign = 'MiddleRight'; $credit.Font = [Drawing.Font]::new('Segoe UI', 8.5); $top.Controls.Add($credit)
$rootLabel = New-UiLabel $script:SiteRoot 700 23 430 26 $true
$rootLabel.ForeColor = [Drawing.Color]::FromArgb(255, 246, 246); $rootLabel.BackColor = [Drawing.Color]::Transparent; $rootLabel.TextAlign = 'MiddleRight'; $rootLabel.AutoEllipsis=$true; $rootLabel.Font = [Drawing.Font]::new('Segoe UI', 9); $top.Controls.Add($rootLabel)
$schoolMark = [Windows.Forms.PictureBox]::new()
$schoolMark.Location = [Drawing.Point]::new(22, 13); $schoolMark.Size = [Drawing.Size]::new(56, 56); $schoolMark.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom; $schoolMark.BackColor = [Drawing.Color]::Transparent
$iconPath = Join-Path $script:ToolRoot 'Muh_icon.png'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $schoolMark.Image = [Drawing.Image]::FromFile($iconPath) }
$top.Controls.Add($schoolMark)

$tabs = [Windows.Forms.TabControl]::new()
$tabs.Location = [Drawing.Point]::new(16, 94); $tabs.Size = [Drawing.Size]::new(1128, 626); $tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Font = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
$script:form.Controls.Add($tabs)
$tabGallery = [Windows.Forms.TabPage]::new('Gallery')
$tabUpdates = [Windows.Forms.TabPage]::new('Latest Updates')
$tabResources = [Windows.Forms.TabPage]::new('Forms | Documents | Policies')
$tabShortLinks = [Windows.Forms.TabPage]::new('Short Links')
foreach ($tab in @($tabGallery,$tabUpdates,$tabResources,$tabShortLinks)) { $tab.BackColor = [Drawing.Color]::FromArgb(246,245,245); $tabs.TabPages.Add($tab) }

# Gallery tab
$script:galleryList = [Windows.Forms.ListBox]::new(); $script:galleryList.Location=[Drawing.Point]::new(18,48); $script:galleryList.Size=[Drawing.Size]::new(350,380); $script:galleryList.Font=[Drawing.Font]::new('Segoe UI',9); $script:galleryList.IntegralHeight=$false; $tabGallery.Controls.Add($script:galleryList)
$tabGallery.Controls.Add((New-UiLabel 'EXISTING ALBUMS' 20 18 300 22))
$moveAlbumUp = New-UiButton 'Move up' 18 435 168 32; $tabGallery.Controls.Add($moveAlbumUp)
$moveAlbumDown = New-UiButton 'Move down' 198 435 170 32; $tabGallery.Controls.Add($moveAlbumDown)
$albumUnlist = New-UiButton 'Unlist' 18 474 104 32; $tabGallery.Controls.Add($albumUnlist)
$albumRelist = New-UiButton 'Re-list' 128 474 104 32; $tabGallery.Controls.Add($albumRelist)
$albumDelete = New-UiButton 'Delete files' 238 474 130 32; $albumDelete.ForeColor=[Drawing.Color]::FromArgb(151,39,43); $tabGallery.Controls.Add($albumDelete)
$script:galleryCount = New-UiLabel '' 20 518 330 24 $true; $tabGallery.Controls.Add($script:galleryCount)
$rebuild = New-UiButton 'Save order and rebuild gallery' 18 555 350 40 $false; $tabGallery.Controls.Add($rebuild)
$galleryPanel = [Windows.Forms.TabControl]::new(); $galleryPanel.Location=[Drawing.Point]::new(390,18); $galleryPanel.Size=[Drawing.Size]::new(700,595); $galleryPanel.BackColor=[Drawing.Color]::White; $tabGallery.Controls.Add($galleryPanel)
$albumCreatePage=[Windows.Forms.TabPage]::new('New Album'); $albumCreatePage.BackColor=[Drawing.Color]::White
$albumImagesPage=[Windows.Forms.TabPage]::new('Album Images'); $albumImagesPage.BackColor=[Drawing.Color]::White
$galleryPanel.TabPages.Add($albumImagesPage); $galleryPanel.TabPages.Add($albumCreatePage)
$albumCreatePage.Controls.Add((New-UiLabel 'ADD A NEW EVENT ALBUM' 25 20 500 25))
$albumCreatePage.Controls.Add((New-UiLabel 'Choose a folder containing the downloaded event photos.' 25 51 630 22 $true))
$script:galleryFolder = New-UiTextBox 25 82 525 32; $script:galleryFolder.ReadOnly=$true; $albumCreatePage.Controls.Add($script:galleryFolder)
$galleryBrowse = New-UiButton 'Browse...' 560 81 112 34; $albumCreatePage.Controls.Add($galleryBrowse)
$albumCreatePage.Controls.Add((New-UiLabel 'EVENT NAME' 25 135 300 20))
$script:galleryTitle = New-UiTextBox 25 159 420 34; $albumCreatePage.Controls.Add($script:galleryTitle)
$albumCreatePage.Controls.Add((New-UiLabel 'EVENT DATE' 466 135 190 20))
$script:galleryDate = New-UiTextBox 465 159 205 34; $script:galleryDate.Text=(Get-Date).ToString('d-M-yyyy'); $albumCreatePage.Controls.Add($script:galleryDate)
$albumCreatePage.Controls.Add((New-UiLabel 'COVER PHOTO' 25 212 300 20))
$script:coverChoice = [Windows.Forms.ComboBox]::new(); $script:coverChoice.Location=[Drawing.Point]::new(25,237); $script:coverChoice.Size=[Drawing.Size]::new(645,34); $script:coverChoice.DropDownStyle='DropDownList'; $script:coverChoice.Enabled=$false; $albumCreatePage.Controls.Add($script:coverChoice)
$script:coverPreview = [Windows.Forms.PictureBox]::new(); $script:coverPreview.Location=[Drawing.Point]::new(486,286); $script:coverPreview.Size=[Drawing.Size]::new(184,118); $script:coverPreview.SizeMode='Zoom'; $script:coverPreview.BackColor=[Drawing.Color]::FromArgb(242,239,239); $script:coverPreview.BorderStyle='FixedSingle'; $albumCreatePage.Controls.Add($script:coverPreview)
$albumCreatePage.Controls.Add((New-UiLabel 'COVER PREVIEW' 487 407 180 18 $true))
$script:galleryStatus = New-UiLabel 'Select a photo folder to begin.' 25 290 430 42 $true; $script:galleryStatus.AutoEllipsis=$true; $albumCreatePage.Controls.Add($script:galleryStatus)
$galleryHelp = New-UiLabel 'The selected cover is used for the album card. Move albums, then save. Saving order renumbers folders and updates links; unlisted albums stay on disk.' 25 352 430 78 $true; $albumCreatePage.Controls.Add($galleryHelp)
$addAlbum = New-UiButton 'Create album and update gallery' 25 520 645 46 $true; $albumCreatePage.Controls.Add($addAlbum)
$script:albumImageHeading=New-UiLabel 'Select an album to view its images' 18 12 470 24; $script:albumImageHeading.Font=[Drawing.Font]::new('Segoe UI Semibold',10); $albumImagesPage.Controls.Add($script:albumImageHeading)
$script:albumImageCount=New-UiLabel '0 images' 510 14 150 20 $true; $script:albumImageCount.TextAlign='MiddleRight'; $albumImagesPage.Controls.Add($script:albumImageCount)
$script:albumImageFlow=[Windows.Forms.FlowLayoutPanel]::new(); $script:albumImageFlow.Location=[Drawing.Point]::new(14,42); $script:albumImageFlow.Size=[Drawing.Size]::new(660,420); $script:albumImageFlow.AutoScroll=$true; $script:albumImageFlow.WrapContents=$true; $script:albumImageFlow.FlowDirection='LeftToRight'; $script:albumImageFlow.BackColor=[Drawing.Color]::FromArgb(248,247,247); $albumImagesPage.Controls.Add($script:albumImageFlow)
$script:addAlbumImage=New-UiButton '+ Add images' 14 472 140 34; $script:addAlbumImage.Enabled=$false; $albumImagesPage.Controls.Add($script:addAlbumImage)
$script:removeAlbumImage=New-UiButton 'Remove selected' 164 472 150 34; $script:removeAlbumImage.ForeColor=[Drawing.Color]::FromArgb(151,39,43); $script:removeAlbumImage.Enabled=$false; $albumImagesPage.Controls.Add($script:removeAlbumImage)
$script:albumImageStatus=New-UiLabel 'Select an album to view its images.' 14 516 650 32 $true; $script:albumImageStatus.AutoEllipsis=$true; $albumImagesPage.Controls.Add($script:albumImageStatus)

# Latest updates tab
$script:updateList = [Windows.Forms.ListBox]::new(); $script:updateList.Location=[Drawing.Point]::new(18,48); $script:updateList.Size=[Drawing.Size]::new(350,470); $script:updateList.Font=[Drawing.Font]::new('Segoe UI',9); $script:updateList.IntegralHeight=$false; $tabUpdates.Controls.Add($script:updateList)
$tabUpdates.Controls.Add((New-UiLabel 'HOMEPAGE UPDATE CARDS' 20 18 340 22))
$script:updateCount = New-UiLabel '' 20 526 340 24 $true; $tabUpdates.Controls.Add($script:updateCount)
$updateAdd = New-UiButton '+ Add' 20 563 80 36; $tabUpdates.Controls.Add($updateAdd)
$updateRemove = New-UiButton 'Remove' 108 563 92 36; $tabUpdates.Controls.Add($updateRemove)
$updateUp = New-UiButton 'Move up' 208 563 76 36; $tabUpdates.Controls.Add($updateUp)
$updateDown = New-UiButton 'Move down' 292 563 76 36; $tabUpdates.Controls.Add($updateDown)
$updatePanel=[Windows.Forms.Panel]::new(); $updatePanel.Location=[Drawing.Point]::new(390,18); $updatePanel.Size=[Drawing.Size]::new(700,595); $updatePanel.BackColor=[Drawing.Color]::White; $updatePanel.BorderStyle='FixedSingle'; $tabUpdates.Controls.Add($updatePanel)
$updatePanel.Controls.Add((New-UiLabel 'UPDATE DETAILS' 25 20 500 25))
$updatePanel.Controls.Add((New-UiLabel 'CATEGORY TAG' 25 62 300 20)); $script:updateTag=New-UiTextBox 25 86 300 32; $updatePanel.Controls.Add($script:updateTag)
$updatePanel.Controls.Add((New-UiLabel 'DISPLAY DATE' 345 62 300 20)); $script:updateDate=New-UiTextBox 345 86 325 32; $updatePanel.Controls.Add($script:updateDate)
$updatePanel.Controls.Add((New-UiLabel 'UPDATE TITLE' 25 137 620 20)); $script:updateTitle=New-UiTextBox 25 161 645 34; $updatePanel.Controls.Add($script:updateTitle)
$updatePanel.Controls.Add((New-UiLabel 'CLICK DESTINATION (PAGE OR URL)' 25 213 620 20)); $script:updateHref=New-UiTextBox 25 237 645 34; $updatePanel.Controls.Add($script:updateHref)
$updatePanel.Controls.Add((New-UiLabel 'Examples: documents.html  |  Policies.html  |  news/imgs/timetable.png' 25 278 630 22 $true))
$updatePanel.Controls.Add((New-UiLabel 'Select an update on the left, edit its fields, then save. New cards appear in this order.' 25 345 630 50 $true))
$updateSave=New-UiButton 'Save homepage updates' 25 520 645 46 $true; $updatePanel.Controls.Add($updateSave)

# Resource management tab
$script:resourcePage = [Windows.Forms.ComboBox]::new(); $script:resourcePage.Location=[Drawing.Point]::new(20,18); $script:resourcePage.Size=[Drawing.Size]::new(280,34); $script:resourcePage.DropDownStyle='DropDownList'; [void]$script:resourcePage.Items.AddRange(@('Forms','Documents','Policies')); $tabResources.Controls.Add($script:resourcePage)
$script:resourcePageName=New-UiLabel '' 320 22 350 22 $true; $tabResources.Controls.Add($script:resourcePageName)
$script:resourceSections=[Windows.Forms.ListBox]::new(); $script:resourceSections.Location=[Drawing.Point]::new(20,70); $script:resourceSections.Size=[Drawing.Size]::new(330,340); $script:resourceSections.Font=[Drawing.Font]::new('Segoe UI',9); $script:resourceSections.IntegralHeight=$false; $tabResources.Controls.Add($script:resourceSections)
$sectionAdd=New-UiButton '+ Section' 20 420 150 34; $tabResources.Controls.Add($sectionAdd)
$sectionRemove=New-UiButton 'Remove section' 180 420 170 34; $tabResources.Controls.Add($sectionRemove)
$script:resourceMoveUp=New-UiButton 'Move up' 20 462 150 34; $tabResources.Controls.Add($script:resourceMoveUp)
$script:resourceMoveDown=New-UiButton 'Move down' 180 462 170 34; $tabResources.Controls.Add($script:resourceMoveDown)
$script:resourceSectionTitle=New-UiLabel 'Choose or add a section' 382 68 550 24; $script:resourceSectionTitle.Font=[Drawing.Font]::new('Segoe UI Semibold',10); $tabResources.Controls.Add($script:resourceSectionTitle)
$tabResources.Controls.Add((New-UiLabel 'ENGLISH TITLE' 382 102 310 18)); $script:resourceEnglish=New-UiTextBox 382 123 340 32; $tabResources.Controls.Add($script:resourceEnglish)
$tabResources.Controls.Add((New-UiLabel 'DHIVEHI TITLE' 740 102 320 18)); $script:resourceDhivehi=New-UiTextBox 740 123 348 32; $script:resourceDhivehi.RightToLeft='Yes'; $tabResources.Controls.Add($script:resourceDhivehi)
$tabResources.Controls.Add((New-UiLabel 'LINKS AND FILES IN THIS SECTION' 382 174 650 21))
$script:resourceItems=[Windows.Forms.ListBox]::new(); $script:resourceItems.Location=[Drawing.Point]::new(382,199); $script:resourceItems.Size=[Drawing.Size]::new(706,145); $script:resourceItems.IntegralHeight=$false; $script:resourceItems.Font=[Drawing.Font]::new('Segoe UI',9); $tabResources.Controls.Add($script:resourceItems)
$itemAdd=New-UiButton '+ Link / file' 382 354 150 32; $tabResources.Controls.Add($itemAdd)
$itemRemove=New-UiButton 'Remove link' 542 354 150 32; $tabResources.Controls.Add($itemRemove)
$script:itemMoveUp=New-UiButton 'Move link up' 382 394 150 32; $tabResources.Controls.Add($script:itemMoveUp)
$script:itemMoveDown=New-UiButton 'Move link down' 542 394 150 32; $tabResources.Controls.Add($script:itemMoveDown)
$tabResources.Controls.Add((New-UiLabel 'LINK LABEL' 382 438 300 18)); $script:resourceItemName=New-UiTextBox 382 459 300 31; $tabResources.Controls.Add($script:resourceItemName)
$tabResources.Controls.Add((New-UiLabel 'DESTINATION' 696 438 300 18)); $script:resourceItemHref=New-UiTextBox 696 459 300 31; $tabResources.Controls.Add($script:resourceItemHref)
$itemBrowse=New-UiButton 'File...' 1004 458 84 33; $tabResources.Controls.Add($itemBrowse)
$script:resourceStatus=New-UiLabel 'Add or select a section to manage its English and Dhivehi titles and links.' 382 502 700 35 $true; $tabResources.Controls.Add($script:resourceStatus)
$resourceSave=New-UiButton 'Save changes to this page' 382 554 706 46 $true; $tabResources.Controls.Add($resourceSave)

# Short links tab
$script:shortLinkList=[Windows.Forms.ListBox]::new(); $script:shortLinkList.Location=[Drawing.Point]::new(18,48); $script:shortLinkList.Size=[Drawing.Size]::new(350,470); $script:shortLinkList.Font=[Drawing.Font]::new('Segoe UI',9); $script:shortLinkList.IntegralHeight=$false; $tabShortLinks.Controls.Add($script:shortLinkList)
$tabShortLinks.Controls.Add((New-UiLabel 'EXISTING SHORT LINKS' 20 18 340 22))
$script:shortLinkCount=New-UiLabel '' 20 526 340 24 $true; $tabShortLinks.Controls.Add($script:shortLinkCount)
$shortLinkAdd=New-UiButton '+ New link' 20 563 155 36; $tabShortLinks.Controls.Add($shortLinkAdd)
$shortLinkDelete=New-UiButton 'Delete link' 185 563 155 36; $shortLinkDelete.ForeColor=[Drawing.Color]::FromArgb(151,39,43); $tabShortLinks.Controls.Add($shortLinkDelete)
$shortLinkPanel=[Windows.Forms.Panel]::new(); $shortLinkPanel.Location=[Drawing.Point]::new(390,18); $shortLinkPanel.Size=[Drawing.Size]::new(700,595); $shortLinkPanel.BackColor=[Drawing.Color]::White; $shortLinkPanel.BorderStyle='FixedSingle'; $tabShortLinks.Controls.Add($shortLinkPanel)
$shortLinkPanel.Controls.Add((New-UiLabel 'SHORT LINK DETAILS' 25 20 500 25))
$shortLinkPanel.Controls.Add((New-UiLabel 'FOLDER NAME' 25 58 645 20)); $script:shortLinkPath=New-UiTextBox 25 81 645 32; $shortLinkPanel.Controls.Add($script:shortLinkPath)
$shortLinkPanel.Controls.Add((New-UiLabel 'FINAL LINK' 25 121 545 20)); $script:shortLinkUrl=New-UiTextBox 25 144 535 32; $script:shortLinkUrl.ReadOnly=$true; $shortLinkPanel.Controls.Add($script:shortLinkUrl)
$shortLinkCopy=New-UiButton 'Copy link' 570 143 100 34; $shortLinkPanel.Controls.Add($shortLinkCopy)
$shortLinkPanel.Controls.Add((New-UiLabel 'DESTINATION URL' 25 185 645 20)); $script:shortLinkTarget=New-UiTextBox 25 208 645 32; $shortLinkPanel.Controls.Add($script:shortLinkTarget)
$shortLinkPanel.Controls.Add((New-UiLabel 'INTERNAL DESCRIPTION (ONLY STORED IN THIS MANAGER)' 25 254 645 20)); $script:shortLinkDescription=New-UiTextBox 25 277 645 130 $true; $script:shortLinkDescription.ScrollBars='Vertical'; $shortLinkPanel.Controls.Add($script:shortLinkDescription)
$shortLinkPanel.Controls.Add((New-UiLabel 'New links use /l/folder-name/ and redirect to the destination above.' 25 411 645 24 $true))
$script:shortLinkStatus=New-UiLabel 'Choose a short link or create a new one.' 25 440 645 35 $true; $shortLinkPanel.Controls.Add($script:shortLinkStatus)
$shortLinkSave=New-UiButton 'Save short link' 25 520 645 46 $true; $shortLinkPanel.Controls.Add($shortLinkSave)
$shortLinkCopy.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:shortLinkUrl.Text)) {
        try { [Windows.Forms.Clipboard]::SetText($script:shortLinkUrl.Text); $script:shortLinkStatus.Text='Final link copied to the clipboard.' }
        catch { $script:shortLinkStatus.Text="Could not copy link: $($_.Exception.Message)" }
    }
})

# Persistent activity log
$logLabel = New-UiLabel 'ACTIVITY LOG' 18 727 250 18
$logLabel.Font=[Drawing.Font]::new('Segoe UI Semibold',8.5); $script:form.Controls.Add($logLabel)
$script:LogBox=[Windows.Forms.RichTextBox]::new(); $script:LogBox.Location=[Drawing.Point]::new(16,748); $script:LogBox.Size=[Drawing.Size]::new(1128,88); $script:LogBox.Anchor='Bottom,Left,Right'; $script:LogBox.ReadOnly=$true; $script:LogBox.BackColor=[Drawing.Color]::FromArgb(34,34,37); $script:LogBox.ForeColor=[Drawing.Color]::FromArgb(230,224,224); $script:LogBox.BorderStyle='FixedSingle'; $script:LogBox.Font=[Drawing.Font]::new('Consolas',8.5); $script:form.Controls.Add($script:LogBox)
$script:undoDeleteTip=[Windows.Forms.ToolTip]::new()
$script:undoDeleteButton=New-UiButton 'Undo delete' 990 721 154 24
$script:undoDeleteButton.Anchor='Bottom,Right'; $script:undoDeleteButton.Font=[Drawing.Font]::new('Segoe UI Semibold',8.5); $script:form.Controls.Add($script:undoDeleteButton)
$script:undoDeleteButton.Add_Click({ Undo-LastDelete })
Update-UndoDeleteButton

# Load existing content
foreach ($page in @('forms.html','documents.html','Policies.html')) { $script:ResourceModels[$page] = Get-ResourceSections (Join-Path $script:SiteRoot $page) }
$script:Updates = Get-UpdateItems
Refresh-AlbumList -SelectIndex 0
Refresh-UpdateList -SelectIndex 0
Refresh-ResourcePage 'forms.html'
$script:ShortLinks = Get-ShortLinkEntries
Refresh-ShortLinkList -SelectIndex 0
$script:resourcePage.SelectedIndex = 0
Write-ManagerLog "Manager started for $script:SiteRoot"
Write-ManagerLog "Loaded $($script:galleryModels.Count) albums, $($script:Updates.Count) homepage updates, and resource sections."

# Gallery actions
$script:shortLinkList.Add_SelectedIndexChanged({
    if (-not $script:LoadingShortLinkUi) { Load-ShortLinkEditor $script:shortLinkList.SelectedIndex }
})
$script:shortLinkPath.Add_TextChanged({
    if ($script:LoadingShortLinkUi) { return }
    $index=$script:shortLinkList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:ShortLinks.Count -or -not $script:ShortLinks[$index].IsNew) { return }
    $slug=$script:shortLinkPath.Text.Trim()
    $script:shortLinkUrl.Text=if ($slug -match '^[A-Za-z0-9][A-Za-z0-9_-]*$') { 'https://muhyiddin.edu.mv/l/'+$slug+'/' } else { '' }
})
$shortLinkAdd.Add_Click({
    $newItem=[pscustomobject]@{Slug='';DisplayPath='';FilePath='';Target='';Description='';IsFolder=$true;IsNew=$true}
    [void]$script:ShortLinks.Add($newItem)
    Refresh-ShortLinkList -SelectIndex ($script:ShortLinks.Count-1)
    $script:shortLinkPath.Focus()
})
$shortLinkSave.Add_Click({
    try { Save-SelectedShortLink }
    catch {
        $script:shortLinkStatus.Text=$_.Exception.Message
        Write-ManagerLog "Short link save failed: $($_.Exception.Message)" 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not save short link','OK','Error') | Out-Null
    }
})
$shortLinkDelete.Add_Click({
    $index=$script:shortLinkList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:ShortLinks.Count) { return }
    $item=$script:ShortLinks[$index]
    $address=Get-ShortLinkAddress $item
    $answer=[Windows.Forms.MessageBox]::Show($script:form,"Delete '$address'? The redirect file will be backed up first.",'Delete short link','YesNo','Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    try {
        if ($item.IsNew) {
            $script:ShortLinks.RemoveAt($index)
            Register-UndoDelete ([pscustomobject]@{Kind='ShortLinkDraft';Description='unsaved short link';Index=$index;Item=$item})
        } else {
            $shortRoot=[IO.Path]::GetFullPath((Join-Path $script:SiteRoot 'l'))
            $source=[IO.Path]::GetFullPath((Join-Path $shortRoot ($item.FilePath.Replace('/', '\'))))
            $rootPrefix=$shortRoot.TrimEnd('\')+'\'
            if (-not $source.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'The short link path is outside the l folder.' }
            if (-not (Test-Path -LiteralPath $source)) { throw 'The redirect file no longer exists.' }
            $backupParent=Join-Path $script:BackupRoot ('DeletedShortLinks\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
            Copy-Item -LiteralPath $source -Destination $backupParent -Recurse
            $backup=Join-Path $backupParent (Split-Path $source -Leaf)
            if (-not (Test-Path -LiteralPath $backup)) { throw 'The recoverable short link backup could not be confirmed.' }
            Remove-Item -LiteralPath $source -Recurse -Force
            $script:ShortLinks.RemoveAt($index)
            Register-UndoDelete ([pscustomobject]@{Kind='ShortLink';Description="short link '$address'";Index=$index;Item=$item;Backup=$backup})
            Save-ShortLinkMetadata
        }
        Refresh-ShortLinkList -SelectIndex ([Math]::Min($index,$script:ShortLinks.Count-1))
        $script:shortLinkStatus.Text='Short link deleted. Use Undo delete to restore it during this session.'
        Write-ManagerLog "Deleted shortened link $address."
    } catch {
        $script:shortLinkStatus.Text=$_.Exception.Message
        Write-ManagerLog "Short link delete failed: $($_.Exception.Message)" 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not delete short link','OK','Error') | Out-Null
    }
})

$galleryBrowse.Add_Click({
    $dialog=[Windows.Forms.FolderBrowserDialog]::new(); $dialog.Description='Choose the folder containing event photos.'; $dialog.ShowNewFolderButton=$false
    if ($dialog.ShowDialog($script:form) -eq [Windows.Forms.DialogResult]::OK) { Set-GallerySource $dialog.SelectedPath }
})
$script:coverChoice.Add_SelectedIndexChanged({ Update-GalleryCoverPreview })
$script:galleryFolder.AllowDrop=$true
$script:galleryFolder.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect=[Windows.Forms.DragDropEffects]::Copy } else { $_.Effect=[Windows.Forms.DragDropEffects]::None }
})
$script:galleryFolder.Add_DragDrop({
    $paths=$_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0] -PathType Container)) { Set-GallerySource $paths[0] }
})
$moveAlbumUp.Add_Click({
    $index=$script:galleryList.SelectedIndex
    if ($index -le 0 -or -not $script:galleryModels[$index].IsListed -or -not $script:galleryModels[$index-1].IsListed) { return }
    $item=$script:galleryModels[$index]; $script:galleryModels[$index]=$script:galleryModels[$index-1]; $script:galleryModels[$index-1]=$item
    Draw-AlbumList ($index-1)
    $script:galleryStatus.Text='Order changed. Click Save order and rebuild gallery to apply it.'
})
$moveAlbumDown.Add_Click({
    $index=$script:galleryList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:galleryModels.Count-1 -or -not $script:galleryModels[$index].IsListed -or -not $script:galleryModels[$index+1].IsListed) { return }
    $item=$script:galleryModels[$index]; $script:galleryModels[$index]=$script:galleryModels[$index+1]; $script:galleryModels[$index+1]=$item
    Draw-AlbumList ($index+1)
    $script:galleryStatus.Text='Order changed. Click Save order and rebuild gallery to apply it.'
})
$script:galleryList.Add_SelectedIndexChanged({ Update-GalleryAlbumControls; Load-AlbumImageGallery })
$script:addAlbumImage.Add_Click({ Add-AlbumImages })
$script:removeAlbumImage.Add_Click({ Remove-SelectedAlbumImage })
$albumUnlist.Add_Click({
    $index=$script:galleryList.SelectedIndex; if ($index -lt 0) { return }
    $album=$script:galleryModels[$index]
    if (-not $album.IsListed) { return }
    $message="Remove '$($album.Title)' from the public gallery list? Its album folder and direct view page will remain on the website."
    $answer=[Windows.Forms.MessageBox]::Show($script:form,$message,'Change gallery listing','YesNo','Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    try { Set-AlbumListing $album.Folder $false }
    catch { $script:galleryStatus.Text="Could not update listing: $($_.Exception.Message)"; Write-ManagerLog $script:galleryStatus.Text 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$script:galleryStatus.Text,'Gallery listing failed','OK','Error') | Out-Null }
})
$albumRelist.Add_Click({
    $index=$script:galleryList.SelectedIndex; if ($index -lt 0) { return }
    $album=$script:galleryModels[$index]
    if ($album.IsListed) { return }
    $message="Add '$($album.Title)' back to the public gallery list?"
    $answer=[Windows.Forms.MessageBox]::Show($script:form,$message,'Restore gallery album','YesNo','Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    try { Set-AlbumListing $album.Folder $true }
    catch { $script:galleryStatus.Text="Could not restore album: $($_.Exception.Message)"; Write-ManagerLog $script:galleryStatus.Text 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$script:galleryStatus.Text,'Could not restore album','OK','Error') | Out-Null }
})
$albumDelete.Add_Click({
    $index=$script:galleryList.SelectedIndex; if ($index -lt 0) { return }
    $album=$script:galleryModels[$index]
    $message="Permanently remove '$($album.Title)' and its album folder? A full copy will first be saved under MUHYIDDIN_WEBSITE_MANAGER_TOOL\Backups\DeletedAlbums."
    $answer=[Windows.Forms.MessageBox]::Show($script:form,$message,'Delete gallery album files','YesNo','Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    try {
        $backup=Remove-GalleryAlbum $album.Folder
        Register-UndoDelete ([pscustomobject]@{Kind='GalleryAlbum';Description="gallery album '$($album.Title)'";Folder=$album.Folder;Title=$album.Title;Backup=$backup;IsListed=[bool]$album.IsListed;DisplayIndex=$index})
    }
    catch { $script:galleryStatus.Text="Could not remove album: $($_.Exception.Message)"; Write-ManagerLog $script:galleryStatus.Text 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$script:galleryStatus.Text,'Album removal failed','OK','Error') | Out-Null }
})
$addAlbum.Add_Click({
    if (-not $script:GalleryImages.Count) { $script:galleryStatus.Text='Choose a folder containing supported image files first.'; return }
    $name=$script:galleryTitle.Text.Trim().TrimEnd('.', ' ')
    if (-not $name) { $script:galleryStatus.Text='Enter the event name.'; return }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { $script:galleryStatus.Text='Remove characters that are not allowed in folder names.'; return }
    $date=ConvertTo-GalleryDate $script:galleryDate.Text
    if (-not $date) { $script:galleryStatus.Text='Enter a valid date as day-month-year, for example 23-9-2026.'; return }
    $highest=0; foreach ($album in $script:galleryModels) { $highest=[Math]::Max($highest,$album.Number) }
    $folderName='{0}. {1} ({2})' -f ($highest+1),$name,$date
    $destination=Join-Path (Join-Path $script:SiteRoot 'gallery') $folderName
    if (Test-Path -LiteralPath $destination) { $script:galleryStatus.Text='That album folder already exists. Check the title and date.'; return }
    $confirm=[Windows.Forms.MessageBox]::Show($script:form,"Create '$folderName' with $($script:GalleryImages.Count) photos and rebuild all gallery pages?",'Confirm album','YesNo','Question')
    if ($confirm -ne [Windows.Forms.DialogResult]::Yes) { return }
    $stage=Join-Path (Join-Path $script:SiteRoot 'gallery') ('.manager-import-'+[guid]::NewGuid().ToString('N'))
    try {
        $addAlbum.Enabled=$false; $script:galleryStatus.Text='Copying photos and generating gallery pages...'; $script:form.Refresh()
        New-Item -ItemType Directory -Path $stage | Out-Null
        $cover=$script:GalleryImages[$script:coverChoice.SelectedIndex]
        Copy-Item -LiteralPath $cover.FullName -Destination (Join-Path $stage ('cover'+$cover.Extension.ToLowerInvariant()))
        $n=1
        foreach ($image in $script:GalleryImages) { if ($image.FullName -eq $cover.FullName) { continue }; Copy-Item -LiteralPath $image.FullName -Destination (Join-Path $stage ('photo-{0:D3}{1}' -f $n,$image.Extension.ToLowerInvariant())); $n++ }
        Move-Item -LiteralPath $stage -Destination $destination
        Update-GalleryPages
        Refresh-AlbumList
        $script:galleryStatus.Text="Added $folderName successfully."
        Write-ManagerLog "Added gallery album $folderName with $($script:GalleryImages.Count) photos."
    }
    catch {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        $script:galleryStatus.Text="Gallery import failed: $($_.Exception.Message)"; Write-ManagerLog $script:galleryStatus.Text 'ERROR'
        [Windows.Forms.MessageBox]::Show($script:form,$script:galleryStatus.Text,'Gallery import failed','OK','Error') | Out-Null
    }
    finally { $addAlbum.Enabled=$true }
})
$rebuild.Add_Click({
    try {
        $rebuild.Enabled=$false
        Save-GalleryOrder @($script:galleryModels | ForEach-Object { $_.Folder })
        Update-GalleryPages
        Refresh-AlbumList
        Write-ManagerLog 'Gallery order saved and gallery pages rebuilt.'
    }
    catch { Write-ManagerLog $_.Exception.Message 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Gallery update failed','OK','Error') | Out-Null }
    finally { $rebuild.Enabled=$true }
})

# Homepage latest updates actions
$script:updateList.Add_SelectedIndexChanged({
    if (-not $script:LoadingUpdateUi -and $script:updateList.SelectedIndex -ne $script:CurrentUpdateIndex) { Commit-UpdateEditor; Load-UpdateEditor $script:updateList.SelectedIndex }
})
$updateAdd.Add_Click({
    Commit-UpdateEditor
    [void]$script:Updates.Add([pscustomobject]@{Tag='UPDATE';Title='';Date=(Get-Date).ToString('d/M/yyyy');Href=''})
    Refresh-UpdateList -SelectIndex ($script:Updates.Count-1)
    $script:updateTitle.Focus()
})
$updateRemove.Add_Click({
    $index=$script:updateList.SelectedIndex
    if ($index -lt 0) { return }
    Commit-UpdateEditor
    $item=$script:Updates[$index]
    $script:Updates.RemoveAt($index)
    Register-UndoDelete ([pscustomobject]@{Kind='Update';Description="homepage update '$($item.Title)'";Page='index.html';Index=$index;Item=$item})
    $next=[Math]::Min($index,$script:Updates.Count-1); Refresh-UpdateList -SelectIndex $next
    if ($next -lt 0) { Load-UpdateEditor -1 }
})
$updateUp.Add_Click({
    $index=$script:updateList.SelectedIndex; if ($index -le 0) { return }; Commit-UpdateEditor
    $item=$script:Updates[$index]; $script:Updates.RemoveAt($index); $script:Updates.Insert($index-1,$item); Refresh-UpdateList -SelectIndex ($index-1)
})
$updateDown.Add_Click({
    $index=$script:updateList.SelectedIndex; if ($index -lt 0 -or $index -ge $script:Updates.Count-1) { return }; Commit-UpdateEditor
    $item=$script:Updates[$index]; $script:Updates.RemoveAt($index); $script:Updates.Insert($index+1,$item); Refresh-UpdateList -SelectIndex ($index+1)
})
$updateSave.Add_Click({
    Commit-UpdateEditor
    if (@($script:Updates | Where-Object { -not $_.Title -or -not $_.Href }).Count) { [Windows.Forms.MessageBox]::Show($script:form,'Every update needs a title and click destination. Remove incomplete rows or finish their details.','Check update cards','OK','Warning') | Out-Null; return }
    try { Save-UpdateItems; Refresh-UpdateList -SelectIndex $script:updateList.SelectedIndex; Write-ManagerLog "Saved $($script:Updates.Count) homepage update cards." }
    catch { Write-ManagerLog $_.Exception.Message 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not save updates','OK','Error') | Out-Null }
})

# Bilingual resource sections actions
$script:resourcePage.Add_SelectedIndexChanged({
    $page=switch ($script:resourcePage.SelectedItem) { 'Forms' {'forms.html'} 'Documents' {'documents.html'} 'Policies' {'Policies.html'} }
    if ($page) { Refresh-ResourcePage $page }
})
$script:resourceSections.Add_SelectedIndexChanged({
    if (-not $script:LoadingResourceUi -and $script:resourceSections.SelectedIndex -ne $script:CurrentSectionIndex) { Load-ResourceSection $script:resourceSections.SelectedIndex }
    Update-ResourceOrderControls
})
$script:resourceItems.Add_SelectedIndexChanged({
    if (-not $script:LoadingResourceUi -and $script:resourceItems.SelectedIndex -ne $script:CurrentItemIndex) { Load-ResourceItem $script:resourceItems.SelectedIndex }
    Update-ResourceOrderControls
})
$script:resourceEnglish.Add_TextChanged({
    $i=$script:resourceSections.SelectedIndex; if (-not $script:LoadingResourceUi -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage].Count) { $script:ResourceModels[$script:CurrentResourcePage][$i].English=$script:resourceEnglish.Text; $script:resourceSectionTitle.Text=$script:resourceEnglish.Text }
})
$script:resourceEnglish.Add_Leave({
    $i=$script:resourceSections.SelectedIndex
    if (-not $script:LoadingResourceUi -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage].Count) {
        $section=$script:ResourceModels[$script:CurrentResourcePage][$i]
        $label=$section.English; if ($section.Dhivehi) { $label += '  |  ' + $section.Dhivehi }
        $script:LoadingResourceUi=$true; $script:resourceSections.BeginUpdate(); $script:resourceSections.Items[$i]=$label; $script:resourceSections.EndUpdate(); $script:LoadingResourceUi=$false
    }
})
$script:resourceDhivehi.Add_TextChanged({
    $i=$script:resourceSections.SelectedIndex; if (-not $script:LoadingResourceUi -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage].Count) { $script:ResourceModels[$script:CurrentResourcePage][$i].Dhivehi=$script:resourceDhivehi.Text }
})
$script:resourceItemName.Add_TextChanged({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex
    if (-not $script:LoadingResourceUi -and $s -ge 0 -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage][$s].Items.Count) { $script:ResourceModels[$script:CurrentResourcePage][$s].Items[$i].Name=$script:resourceItemName.Text }
})
$script:resourceItemName.Add_Leave({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex
    if (-not $script:LoadingResourceUi -and $s -ge 0 -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage][$s].Items.Count) {
        $script:LoadingResourceUi=$true; $script:resourceItems.BeginUpdate(); $script:resourceItems.Items[$i]=$script:ResourceModels[$script:CurrentResourcePage][$s].Items[$i].Name; $script:resourceItems.EndUpdate(); $script:LoadingResourceUi=$false
    }
})
$script:resourceItemHref.Add_TextChanged({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex
    if (-not $script:LoadingResourceUi -and $s -ge 0 -and $i -ge 0 -and $i -lt $script:ResourceModels[$script:CurrentResourcePage][$s].Items.Count -and -not $script:ResourceModels[$script:CurrentResourcePage][$s].Items[$i].SourceFile) { $script:ResourceModels[$script:CurrentResourcePage][$s].Items[$i].Href=$script:resourceItemHref.Text }
})
$sectionAdd.Add_Click({
    $models=$script:ResourceModels[$script:CurrentResourcePage]
    [void]$models.Add([pscustomobject]@{English='New Section';Dhivehi='';Items=[Collections.ArrayList]::new()})
    $index=$models.Count-1; Refresh-ResourceSectionList -SelectIndex $index; $script:resourceEnglish.Focus(); $script:resourceStatus.Text='Enter the English and Dhivehi headings, then add links or files.'
})
$sectionRemove.Add_Click({
    $index=$script:resourceSections.SelectedIndex; if ($index -lt 0) { return }
    $section=$script:ResourceModels[$script:CurrentResourcePage][$index]; $name=$section.English
    $answer=[Windows.Forms.MessageBox]::Show($script:form,"Remove the section '$name' and its links from this page? Existing files on disk will be kept.",'Remove section','YesNo','Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $script:ResourceModels[$script:CurrentResourcePage].RemoveAt($index)
    Register-UndoDelete ([pscustomobject]@{Kind='ResourceSection';Description="section '$name' on $script:CurrentResourcePage";Page=$script:CurrentResourcePage;Index=$index;Section=$section})
    Refresh-ResourceSectionList -SelectIndex ([Math]::Min($index,$script:ResourceModels[$script:CurrentResourcePage].Count-1))
    Write-ManagerLog "Removed section '$name' from $script:CurrentResourcePage (page save pending)."
})
$script:resourceMoveUp.Add_Click({
    $i=$script:resourceSections.SelectedIndex; $models=$script:ResourceModels[$script:CurrentResourcePage]
    if ($i -le 0 -or $i -ge $models.Count) { return }
    $section=$models[$i]; $models[$i]=$models[$i-1]; $models[$i-1]=$section
    Refresh-ResourceSectionList -SelectIndex ($i-1)
    $script:resourceStatus.Text='Section moved. Save changes to this page to apply the new order.'
    Write-ManagerLog "Moved section up on $script:CurrentResourcePage (page save pending)."
})
$script:resourceMoveDown.Add_Click({
    $i=$script:resourceSections.SelectedIndex; $models=$script:ResourceModels[$script:CurrentResourcePage]
    if ($i -lt 0 -or $i -ge ($models.Count-1)) { return }
    $section=$models[$i]; $models[$i]=$models[$i+1]; $models[$i+1]=$section
    Refresh-ResourceSectionList -SelectIndex ($i+1)
    $script:resourceStatus.Text='Section moved. Save changes to this page to apply the new order.'
    Write-ManagerLog "Moved section down on $script:CurrentResourcePage (page save pending)."
})
$itemAdd.Add_Click({
    $s=$script:resourceSections.SelectedIndex; if ($s -lt 0) { $script:resourceStatus.Text='Add or select a section first.'; return }
    [void]$script:ResourceModels[$script:CurrentResourcePage][$s].Items.Add([pscustomobject]@{Name='New link';Href='';SourceFile=''})
    Refresh-ResourceSectionList -SelectIndex $s; $script:resourceItems.SelectedIndex=$script:ResourceModels[$script:CurrentResourcePage][$s].Items.Count-1; $script:resourceItemName.Focus()
})
$itemRemove.Add_Click({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex; if ($s -lt 0 -or $i -lt 0) { return }
    $section=$script:ResourceModels[$script:CurrentResourcePage][$s]; $item=$section.Items[$i]
    $script:ResourceModels[$script:CurrentResourcePage][$s].Items.RemoveAt($i)
    Register-UndoDelete ([pscustomobject]@{Kind='ResourceLink';Description="link '$($item.Name)' in '$($section.English)'";Page=$script:CurrentResourcePage;Section=$section;SectionEnglish=$section.English;SectionDhivehi=$section.Dhivehi;SectionIndex=$s;Index=$i;Item=$item})
    Refresh-ResourceSectionList -SelectIndex $s; $script:resourceItems.SelectedIndex=[Math]::Min($i,$script:resourceItems.Items.Count-1)
    if ($script:resourceItems.SelectedIndex -lt 0) { Load-ResourceItem -1 }
})
$script:itemMoveUp.Add_Click({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex
    if ($s -lt 0 -or $i -le 0) { return }
    $items=$script:ResourceModels[$script:CurrentResourcePage][$s].Items
    if ($i -ge $items.Count) { return }
    $item=$items[$i]; $items[$i]=$items[$i-1]; $items[$i-1]=$item
    Refresh-ResourceSectionList -SelectIndex $s; $script:resourceItems.SelectedIndex=$i-1
    $script:resourceStatus.Text='Link moved. Save changes to this page to apply the new order.'
    Write-ManagerLog "Moved a link up within '$($script:ResourceModels[$script:CurrentResourcePage][$s].English)' (page save pending)."
})
$script:itemMoveDown.Add_Click({
    $s=$script:resourceSections.SelectedIndex; $i=$script:resourceItems.SelectedIndex
    if ($s -lt 0 -or $i -lt 0) { return }
    $items=$script:ResourceModels[$script:CurrentResourcePage][$s].Items
    if ($i -ge ($items.Count-1)) { return }
    $item=$items[$i]; $items[$i]=$items[$i+1]; $items[$i+1]=$item
    Refresh-ResourceSectionList -SelectIndex $s; $script:resourceItems.SelectedIndex=$i+1
    $script:resourceStatus.Text='Link moved. Save changes to this page to apply the new order.'
    Write-ManagerLog "Moved a link down within '$($script:ResourceModels[$script:CurrentResourcePage][$s].English)' (page save pending)."
})
$itemBrowse.Add_Click({ Add-ResourceFile })
$resourceSave.Add_Click({
    try {
        $page=$script:CurrentResourcePage
        foreach ($section in $script:ResourceModels[$page]) {
            if (-not $section.English.Trim()) { throw 'Every section needs an English title.' }
            foreach ($item in $section.Items) { if (-not $item.Name.Trim() -or -not $item.Href.Trim() -and -not $item.SourceFile) { throw "Finish or remove the incomplete link in '$($section.English)'." } }
        }
        Save-ResourcePage $page
        $script:ResourceModels[$page]=Get-ResourceSections (Join-Path $script:SiteRoot $page)
        Refresh-ResourceSectionList -SelectIndex 0
        $script:resourceStatus.Text="Saved bilingual sections to $page."
        Write-ManagerLog "Saved $($script:ResourceModels[$page].Count) bilingual sections to $page."
    }
    catch { $script:resourceStatus.Text=$_.Exception.Message; Write-ManagerLog $script:resourceStatus.Text 'ERROR'; [Windows.Forms.MessageBox]::Show($script:form,$_.Exception.Message,'Could not save resources','OK','Error') | Out-Null }
})

$galleryPanel.SelectedTab=$albumImagesPage
Load-AlbumImageGallery
[void]$script:form.ShowDialog()
