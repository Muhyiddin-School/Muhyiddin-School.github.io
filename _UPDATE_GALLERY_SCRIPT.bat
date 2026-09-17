@echo off
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
set "GALLERY=%ROOT%gallery"
set "TEMPLATE=%ROOT%sample\gallery\view.html"
set "GALLERY_TEMPLATE=%ROOT%sample\gallery\gallery.html"

if not exist "%GALLERY%" (
    echo ERROR: Gallery folder not found:
    echo %GALLERY%
    pause
    exit /b
)

if not exist "%TEMPLATE%" (
    echo ERROR: Template file not found:
    echo %TEMPLATE%
    pause
    exit /b
)

if not exist "%GALLERY_TEMPLATE%" (
    echo ERROR: Gallery template file not found:
    echo %GALLERY_TEMPLATE%
    pause
    exit /b
)

echo.
echo ========================================
echo Updating Gallery
echo ========================================
echo.


rem ============================================================
rem PART 1 - CREATE view.html FOR EACH ALBUM
rem ============================================================

for /d %%D in ("%GALLERY%\*") do (

    set "FOLDER=%%~nxD"
    set "TITLE=!FOLDER!"
    set "DATE="
    set "REST="
    set "NUMBER="

    rem --------------------------------------------------------
    rem Get album number
    rem --------------------------------------------------------

    for /f "tokens=1 delims=." %%A in ("!FOLDER!") do (
        set "NUMBER=%%A"
    )

    rem --------------------------------------------------------
    rem Get everything before the first (
    rem --------------------------------------------------------

    for /f "tokens=1,* delims=(" %%A in ("!FOLDER!") do (
        set "TITLE=%%A"
        set "REST=%%B"
    )

    rem --------------------------------------------------------
    rem Get everything inside the parentheses
    rem --------------------------------------------------------

    if defined REST (
        for /f "tokens=1 delims=)" %%A in ("!REST!") do (
            set "DATE=%%A"
        )
    )

    rem --------------------------------------------------------
    rem Remove album number from title
    rem Example:
    rem 3. Gallery 3 test -> Gallery 3 test
    rem --------------------------------------------------------

    for /f "tokens=1,* delims=." %%A in ("!TITLE!") do (
        set "TITLE=%%B"
    )

    rem Remove leading space
    if defined TITLE (
        if "!TITLE:~0,1!"==" " set "TITLE=!TITLE:~1!"
    )

    rem Remove trailing space
    if "!TITLE:~-1!"==" " set "TITLE=!TITLE:~0,-1!"

    echo Processing album:
    echo   Folder: !FOLDER!
    echo   Number: !NUMBER!
    echo   Title:  !TITLE!
    echo   Date:   !DATE!

    rem --------------------------------------------------------
    rem Create temporary copy of view template
    rem --------------------------------------------------------

    copy /Y "%TEMPLATE%" "%%D\view.html.tmp" >nul

    rem --------------------------------------------------------
    rem Replace TITLE
    rem --------------------------------------------------------

    powershell -NoProfile -Command ^
        "$p='%%D\view.html.tmp'; $c=Get-Content -Raw -LiteralPath $p; $c=$c.Replace('{{TITLE}}','!TITLE!'); Set-Content -LiteralPath $p -Value $c -NoNewline"

    rem --------------------------------------------------------
    rem Replace DATE
    rem --------------------------------------------------------

    powershell -NoProfile -Command ^
        "$p='%%D\view.html.tmp'; $c=Get-Content -Raw -LiteralPath $p; $c=$c.Replace('{{DATE}}','!DATE!'); Set-Content -LiteralPath $p -Value $c -NoNewline"

    rem --------------------------------------------------------
    rem Create image list
    rem cover.* is excluded
    rem --------------------------------------------------------

    >"%%D\images.tmp" (
        for %%F in (
            "%%D\*.jpg"
            "%%D\*.jpeg"
            "%%D\*.png"
            "%%D\*.gif"
            "%%D\*.webp"
        ) do (
            if exist "%%~F" (
                if /I not "%%~nxF"=="cover.jpg" if /I not "%%~nxF"=="cover.jpeg" if /I not "%%~nxF"=="cover.png" if /I not "%%~nxF"=="cover.gif" if /I not "%%~nxF"=="cover.webp" (
                    echo ^<img class="image" src="%%~nxF"^>
                )
            )
        )
    )

    rem --------------------------------------------------------
    rem Replace IMAGE_LIST
    rem --------------------------------------------------------

    powershell -NoProfile -Command ^
        "$p='%%D\view.html.tmp'; $i='%%D\images.tmp'; $c=Get-Content -Raw -LiteralPath $p; $img=Get-Content -Raw -LiteralPath $i; $c=$c.Replace('{{IMAGE_LIST}}',$img.TrimEnd()); Set-Content -LiteralPath $p -Value $c -NoNewline"

    rem --------------------------------------------------------
    rem Remove temporary image list
    rem --------------------------------------------------------

    del /q "%%D\images.tmp" >nul 2>&1

    rem --------------------------------------------------------
    rem Replace old view.html
    rem --------------------------------------------------------

    move /Y "%%D\view.html.tmp" "%%D\view.html" >nul

    echo   Created: %%D\view.html
    echo.
)


rem ============================================================
rem PART 2 - CREATE ROOT gallery.html
rem ============================================================

echo ========================================
echo Updating main gallery.html
echo ========================================
echo.

rem ------------------------------------------------------------
rem Create temporary copy of gallery template
rem ------------------------------------------------------------

copy /Y "%GALLERY_TEMPLATE%" "%ROOT%gallery.html.tmp" >nul


rem ============================================================
rem CREATE ALBUM LIST
rem Albums sorted by NUMBER - highest first
rem ============================================================

powershell -NoProfile -Command ^
    "$gallery=$env:GALLERY;" ^
    "$output=Join-Path $env:ROOT 'album_list.tmp';" ^
    "$q=[char]34;" ^
    "$albums=Get-ChildItem -LiteralPath $gallery -Directory | ForEach-Object {" ^
    "    $folder=$_.Name;" ^
    "    $title=$folder;" ^
    "    $dateText='';" ^
    "    $number=0;" ^
    "    if ($folder -match '^(\d+)\.\s*(.*?)\s*\((.*?)\)') {" ^
    "        $number=[int]$matches[1];" ^
    "        $title=$matches[2].Trim();" ^
    "        $dateText=$matches[3].Trim();" ^
    "    }" ^
    "    $cover=Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $_.Name -match '^cover\.(jpg|jpeg|png|gif|webp)$' } | Select-Object -First 1;" ^
    "    if ($cover) {" ^
    "        [PSCustomObject]@{Folder=$folder;Title=$title;DateText=$dateText;Number=$number;Cover=$cover.Name}" ^
    "    }" ^
    "} | Sort-Object Number -Descending;" ^
    "$html=foreach ($album in $albums) {" ^
    "    '<a href=' + $q + 'gallery/' + $album.Folder + '/view.html' + $q + '>' + [Environment]::NewLine +" ^
    "    '    <div class=' + $q + 'light_card' + $q + '>' + [Environment]::NewLine +" ^
    "    '        <img class=' + $q + 'image' + $q + ' src=' + $q + 'gallery/' + $album.Folder + '/' + $album.Cover + $q + '>' + [Environment]::NewLine +" ^
    "    '        <h6>' + $album.Title + '</h6>' + [Environment]::NewLine +" ^
    "    '        <date>' + $album.DateText + '</date>' + [Environment]::NewLine +" ^
    "    '    </div>' + [Environment]::NewLine +" ^
    "    '</a>' + [Environment]::NewLine +" ^
    "    ''" ^
    "};" ^
    "$html -join [Environment]::NewLine | Set-Content -LiteralPath $output -NoNewline"


rem ============================================================
rem REPLACE ALBUM_LIST IN GALLERY TEMPLATE
rem ============================================================

powershell -NoProfile -Command ^
    "$p='%ROOT%gallery.html.tmp'; $i='%ROOT%album_list.tmp'; $c=Get-Content -Raw -LiteralPath $p; $a=Get-Content -Raw -LiteralPath $i; $c=$c.Replace('{{ALBUM_LIST}}',$a.TrimEnd()); Set-Content -LiteralPath $p -Value $c -NoNewline"


rem ============================================================
rem REMOVE TEMPORARY ALBUM LIST
rem ============================================================

del /q "%ROOT%album_list.tmp" >nul 2>&1


rem ============================================================
rem REPLACE OLD gallery.html
rem ============================================================

move /Y "%ROOT%gallery.html.tmp" "%ROOT%gallery.html" >nul

echo Created: %ROOT%gallery.html
echo Albums sorted by number - highest first
echo.


rem ============================================================
rem FINISHED
rem ============================================================

echo ========================================
echo Finished.
echo ========================================
echo.

pause