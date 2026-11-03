<#
  Terra Runner 1.4 - interactive PowerShell 7 console.
  This UI changes only the runner configuration and invokes the existing runner.
  It never edits the development repository directly.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [switch]$SelfTest,
    [switch]$Portable,
    [string]$Config = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or newer is required.' }
$script:Root = $PSScriptRoot
$script:Runner = Join-Path $script:Root 'terra-runner.ps1'
$script:Project = ''
$script:Settings = $null
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
Import-Module (Join-Path $script:Root 'terra-core.psm1') -Force -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($Config) -and -not $Portable) {
    $script:ConfigFile = Join-Path (Get-TerraAppDataRoot -InstallRoot $script:Root) 'terra-config.json'
} else {
    $script:ConfigFile = Resolve-TerraConfigPath -Config $Config -Portable:$Portable -InstallRoot $script:Root
}
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Terra Runner 1.5 | OpenCode' } catch { }

function Read-Settings {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) { throw "Missing configuration: $script:ConfigFile" }
    $script:Settings = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
    if ($null -eq $script:Settings -or $null -eq $script:Settings.projects -or @($script:Settings.projects).Count -eq 0) {
        throw 'Config must contain at least one project.'
    }
    if ($null -eq $script:Settings.budget -or $null -eq $script:Settings.execution -or $null -eq $script:Settings.logs) {
        throw 'Config is missing budget/execution/logs settings.'
    }
    if ([string]::IsNullOrWhiteSpace($script:Project) -or @($script:Settings.projects | Where-Object { $_.id -eq $script:Project }).Count -ne 1) {
        $script:Project = [string]$script:Settings.projects[0].id
    }
}
function Write-Settings {
    $original = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8
    $backupDir = Join-Path (Split-Path -Parent $script:ConfigFile) 'data/config-backups'
    [void][IO.Directory]::CreateDirectory($backupDir)
    $name = 'terra-config-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json'
    [IO.File]::WriteAllText((Join-Path $backupDir $name),$original,[Text.UTF8Encoding]::new($false))
    $json = ConvertTo-Json -InputObject $script:Settings -Depth 60
    $roundtrip = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 60
    if ($null -eq $roundtrip.budget -or @($roundtrip.projects).Count -eq 0) { throw 'Failed to validate saved configuration.' }
    $tmp = $script:ConfigFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp,($json + "`n"),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp,$script:ConfigFile,$true)
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
    # Keep only 20 timestamped backups created by this UI.
    @(Get-ChildItem -LiteralPath $backupDir -File -Filter 'terra-config-*.json' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 20) |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Write-Host 'Настройки сохранены. Копия: data/config-backups/' -ForegroundColor Green
}
function Write-Line([string]$Text = '',[string]$Color='Gray') { Write-Host $Text -ForegroundColor $Color }
function Divider { Write-Line ('─'*78) 'DarkGray' }
function Render-Bar([double]$Fraction,[int]$Width = 28) {
    $ratio = [Math]::Min(1.0,[Math]::Max(0.0,$Fraction))
    $filled = [int][Math]::Round($ratio*$Width)
    return ('█'*$filled) + ('░'*($Width-$filled))
}
function Money([decimal]$Value) { return (Format-TerraMoney $Value) }
function Pause-Menu { [void](Read-Host '  Нажмите Enter, чтобы вернуться в меню') }
function Read-Choice([string]$Prompt) { return ([string](Read-Host ('  ' + $Prompt))).Trim().ToLowerInvariant() }
function Read-Text([string]$Title,[string]$Current,[bool]$AllowEmpty=$false) {
    while ($true) {
        Write-Line "  $Title (current: $Current)" 'DarkCyan'
        $answer = Read-Host '  Новое значение (Enter = без изменений)'
        if ([string]::IsNullOrEmpty($answer)) { return $Current }
        $answer = $answer.Trim()
        if ($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($answer)) { return $answer }
        Write-Line '  Требуется значение.' 'Yellow'
    }
}
function Read-Decimal([string]$Title,[decimal]$Current,[decimal]$Min=0,[decimal]$Max=1000000000) {
    while ($true) {
        $raw = Read-Host ('  {0} [{1}]' -f $Title,$Current.ToString('0.####',$script:Invariant))
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Current }
        try { return (ConvertTo-TerraMoney -Text $raw -Minimum $Min -Maximum $Max) }
        catch { }
        Write-Line "  Введите число от $Min to $Max." 'Yellow'
    }
}
function Read-RequiredAmount([string]$Title) {
    while ($true) {
        $entered = Read-Host ('  ' + $Title + ' (enter an amount)')
        try { return (ConvertTo-TerraMoney -Text $entered) }
        catch { Write-Line $_.Exception.Message 'Yellow' }
    }
}
function Read-Integer([string]$Title,[int]$Current,[int]$Min=1,[int]$Max=1000000) {
    while ($true) {
        $raw = Read-Host "  $Title [$Current]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Current }
        $val = 0
        if ([int]::TryParse($raw.Trim(),[ref]$val) -and $val -ge $Min -and $val -le $Max) { return $val }
        Write-Line "  Введите целое число от $Min to $Max." 'Yellow'
    }
}
function Confirm([string]$Message) {
    return ((Read-Choice "$Message [y/n]") -in @('y','yes'))
}
function Get-SelectedProject {
    $matches = @($script:Settings.projects | Where-Object { $_.id -eq $script:Project })
    if ($matches.Count -ne 1) { throw "Project '$script:Project' not found." }
    return $matches[0]
}
function Get-StorageRoot {
    $root = [string]$script:Settings.logs.root
    if (-not [IO.Path]::IsPathRooted($root)) { $root = Join-Path (Split-Path -Parent $script:ConfigFile) $root }
    return $root
}
function Get-BudgetStatePath {
    $id = [string]$script:Settings.budget.balance.id
    if ($id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Invalid balance ID.' }
    return Join-Path (Join-Path (Get-StorageRoot) 'budgets') ($id + '.json')
}
function Latest-Summary {
    $logdir = Join-Path (Join-Path (Get-StorageRoot) $script:Project) 'logs'
    if (-not (Test-Path -LiteralPath $logdir)) { return $null }
    $last = Get-ChildItem -LiteralPath $logdir -Recurse -File -Filter '*.summary.json' |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $last) { return $null }
    try { return (Get-Content -LiteralPath $last.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50) }
    catch { return $null }
}
function Show-Header {
    Clear-Host
    Write-Line '╔══════════════════════════════════════════════════════════════════════════════╗' 'Cyan'
    Write-Line '║                         TERRA RUNNER  1.4                                  ║' 'Cyan'
    Write-Line '║                  Автономная разработка через OpenCode                            ║' 'DarkCyan'
    Write-Line '╚══════════════════════════════════════════════════════════════════════════════╝' 'Cyan'
    Write-Line "  ПРОЕКТ    $script:Project" 'White'
    $projectConfig = Get-SelectedProject
    Write-Line "  ВЕТКА     $($projectConfig.branch)" 'Gray'
    Write-Line "  МОДЕЛЬ    $($script:Settings.model)" 'Gray'
    $budget = $script:Settings.budget
    $mode = [string]$budget.mode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'daily' }
    $budgetText = switch ($mode) {
        'daily'     { 'Daily ' + (Money ([double]$budget.dailyUsd)) + ' / reserve ' + (Money ([double]$budget.reserveUsd)) }
        'balance'   { 'Balance floor ' + (Money ([double]$budget.balance.minimumUsd)) + ' / reserve ' + (Money ([double]$budget.balance.iterationReserveUsd)) }
        'hybrid'    { 'Daily + balance floor (both required)' }
        'unlimited' { 'UNLIMITED - no runner monetary cap' }
        default     { "Unknown mode: $mode" }
    }
    Write-Line "  БЮДЖЕТ    $budgetText" $(if ($mode -eq 'unlimited') { 'Yellow' } else { 'Green' })
    $roadmapPath = Join-Path ([string]$projectConfig.path) ([string]$projectConfig.roadmap)
    if (Test-Path -LiteralPath $roadmapPath) {
        $done = 0; $pending = 0
        foreach ($line in [IO.File]::ReadLines($roadmapPath)) {
            if ($line -match '^\s*-\s*\[[xX]\].*\bNTD-\d{4,}\b') { $done++ }
            if ($line -match '^\s*-\s*\[ \].*\bNTD-\d{4,}\b') { $pending++ }
        }
        $total = $done + $pending
        if ($total -gt 0) {
            Write-Line ('  ЗАДАЧИ    [{0}] {1}/{2} ({3:N0}%)' -f (Render-Bar ($done/[double]$total) 26),$done,$total,(100*$done/[double]$total)) 'DarkCyan'
        }
    }
    $summary = Latest-Summary
    if ($null -ne $summary) {
        $lastText = ('{0} | {1} tasks | {2} | {3}' -f $summary.id,$summary.doneAfter,$summary.branch,$summary.stoppedReason)
        Write-Line "  ПОСЛ.ЦИКЛ $lastText" 'DarkGray'
    }
    Divider
}
function Invoke-Runner {
    [CmdletBinding(PositionalBinding=$false)]
    param([Parameter(Mandatory)][hashtable]$Command)
    $Arguments = @($Command.Keys | Sort-Object | ForEach-Object { "-$_" })
    Write-Line ''
    Write-Line ('  Запуск: ' + ($Arguments -join ' ')) 'Cyan'
    Divider
    try {
        $invokeParameters = @{ Project=$script:Project; Config=$script:ConfigFile }
        foreach ($key in $Command.Keys) { $invokeParameters[$key] = $Command[$key] }
        & $script:Runner @invokeParameters
        Write-Line ''
        Write-Line '  Команда завершена.' 'Green'
    } catch {
        Write-Line ''
        Write-Line ('  ОШИБКА: ' + $_.Exception.Message) 'Red'
        Write-Line '  Проверьте ошибки и логи до следующего запуска.' 'Yellow'
    }
    Pause-Menu
}
function Invoke-OfflineTests {
    Divider
    Write-Line '  Проверка интерфейса и ядра в изолированном тестовом окружении...' 'Cyan'
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    foreach ($test in @('terra-ui-selftest.ps1','terra-selftest.ps1')) {
        $file = Join-Path (Join-Path $script:Root 'tests') $test
        if (-not (Test-Path -LiteralPath $file)) { throw "Не найден тест: $file" }
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $file
        if ($LASTEXITCODE -ne 0) { throw "Самотест $test завершён с кодом $LASTEXITCODE" }
    }
    Write-Line '  Все самотесты завершились успешно.' 'Green'
}
function Configure-Budget {
    while ($true) {
        Show-Header
        $b = $script:Settings.budget
        Write-Line '  НАСТРОЙКИ БЮДЖЕТА' 'White'
        Write-Line "    1  Выбрать режим (сейчас: $($b.mode))" 'Gray'
        Write-Line ('    2  Лимит в сутки / резерв: {0} / {1}' -f (Money ([double]$b.dailyUsd)),(Money ([double]$b.reserveUsd)))
        Write-Line ('    3  Минимум на счёте / резерв: {0} / {1}' -f (Money ([double]$b.balance.minimumUsd)),(Money ([double]$b.balance.iterationReserveUsd)))
        Write-Line "    4  Источник баланса and ID: $($b.balance.source) / $($b.balance.id)"
        Write-Line '    5  Задать или сверить текущий баланс' 'Green'
        Write-Line '    6  Показать текущий бюджет' 'Cyan'
        Write-Line '    0  Назад'
        Divider
        $choice = Read-Choice 'Выберите пункт'
        try {
            switch ($choice) {
                '0' { return }
                '1' {
                    Write-Line '  1 = сутки | 2 = остаток | 3 = оба | 4 = без лимита'
                    $modeChoice = Read-Choice 'Режим бюджета'
                    $newMode = switch ($modeChoice) { '1' {'daily'} '2' {'balance'} '3' {'hybrid'} '4' {'unlimited'} default {''} }
                    if (-not $newMode) { Write-Line '  Неизвестный пункт.' 'Yellow'; Pause-Menu; break }
                    if ($newMode -eq 'unlimited') {
                        Write-Line '  ВНИМАНИЕ: денежный лимит отключён. Возможны неограниченные расходы.' 'Yellow'
                        $approval = Read-Host '  Введите UNLIMITED для подтверждения'
                        if ($approval -cne 'UNLIMITED') { Write-Line '  Отменено.' 'Yellow'; Pause-Menu; break }
                        $b.allowUnlimited = $true
                    }
                    $b.mode = $newMode
                    Write-Settings
                    if ($newMode -in @('balance','hybrid') -and $b.balance.source -eq 'snapshot' -and -not (Test-Path (Get-BudgetStatePath))) {
                        Write-Line '  Снимок баланса не найден. Перед запуском выберите пункт 5.' 'Yellow'
                        Pause-Menu
                    }
                }
                '2' {
                    $cap = Read-Decimal 'Лимит за сутки, USD' ([double]$b.dailyUsd) 0.01
                    $reserve = Read-Decimal 'Резерв на следующую итерацию, USD' ([double]$b.reserveUsd) 0.0 ($cap - 0.001)
                    $emergency = Read-Decimal 'Аварийный порог, USD' ([Math]::Min([double]$b.emergencyStopUsd,$cap)) 0.001 $cap
                    if ($reserve -ge $cap) { throw 'Reserve must be smaller than daily limit.' }
                    $b.dailyUsd = $cap; $b.reserveUsd = $reserve; $b.emergencyStopUsd = $emergency
                    Write-Settings
                }
                '3' {
                    $minimum = Read-Decimal 'Неснижаемый остаток, USD' ([double]$b.balance.minimumUsd)
                    $reserve = Read-Decimal 'Резерв на следующую итерацию, USD' ([double]$b.balance.iterationReserveUsd)
                    $b.balance.minimumUsd = $minimum; $b.balance.iterationReserveUsd = $reserve
                    Write-Settings
                }
                '4' {
                    Write-Line '  1 = ручной снимок | 2 = внешняя команда баланса'
                    $source = Read-Choice 'Источник баланса'
                    if ($source -notin @('1','2')) { break }
                    $id = Read-Text 'ID баланса (латиница/цифры/дефисы)' ([string]$b.balance.id)
                    if ($id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Invalid balance account ID.' }
                    $b.balance.id = $id
                    if ($source -eq '1') { $b.balance.source = 'snapshot' }
                    if ($source -eq '2') {
                        $b.balance.source = 'command'
                        $b.balance.command = Read-Text 'Команда или файл получения баланса' ([string]$b.balance.command)
                        $argsText = Read-Host '  Первый аргумент (Enter — без аргументов)'
                        $arguments = @()
                        if (-not [string]::IsNullOrWhiteSpace($argsText)) { $arguments += $argsText }
                        while ($arguments.Count -gt 0 -and $arguments.Count -lt 20) {
                            $arg = Read-Host '  Следующий аргумент (Enter — завершить)'
                            if ([string]::IsNullOrEmpty($arg)) { break }
                            $arguments += $arg
                        }
                        $b.balance.arguments = $arguments
                        $b.balance.maxAgeMinutes = Read-Integer 'Макс. возраст данных о балансе, мин' ([int]$b.balance.maxAgeMinutes)
                        Write-Line '  Внешняя команда должна вернуть JSON: {"balanceUsd":100,"observedAt":"2026-11-03T20:00:00+03:00"}.' 'Yellow'
                    }
                    Write-Settings
                }
                '5' {
                    if ([string]$b.mode -notin @('balance','hybrid')) {
                        Write-Line '  Сначала переключитесь в режим остатка или гибридный.' 'Yellow'; Pause-Menu; break
                    }
                    if ([string]$b.balance.source -ne 'snapshot') {
                        Write-Line '  Ручной снимок недоступен для внешнего источника.' 'Yellow'; Pause-Menu; break
                    }
                    Write-Line '  ВАЖНО: введите реальный остаток, проверенный у провайдера.' 'Yellow'
                    $actual = Read-RequiredAmount 'Фактический остаток, USD'
                    if (-not (Confirm ('Set recorded balance to ' + (Money $actual) + '?'))) { break }
                    $existing = Test-Path -LiteralPath (Get-BudgetStatePath)
                    if ($existing -and -not (Confirm 'Снимок уже есть. Пересверить по текущему остатку?')) { break }
                    $runnerArgs = @{ SetBalanceUsd=$actual.ToString($script:Invariant) }
                    if ($existing) { $runnerArgs.ReconcileBalance = $true }
                    Invoke-Runner -Command $runnerArgs
                }
                '6' { Invoke-Runner -Command @{ Status=$true } }
                default { Write-Line '  Неизвестный пункт.' 'Yellow'; Start-Sleep -Milliseconds 550 }
            }
        } catch { Write-Line ('  ОШИБКА: ' + $_.Exception.Message) 'Red'; Pause-Menu; Read-Settings }
    }
}
function Configure-Execution {
    while ($true) {
        Show-Header
        $e = $script:Settings.execution
        Write-Line '  МОДЕЛЬ И ПАРАМЕТРЫ ЗАПУСКА' 'White'
        Write-Line "    1  Model: $($script:Settings.model)"
        Write-Line "    2  Agent: $($script:Settings.agent)"
        Write-Line "    3  Максимум итераций за запуск: $($e.maxIterationsPerRun)"
        Write-Line "    4  Таймаут / опрос: $($e.maxIterationMinutes) min / $($e.pollSeconds) s"
        Write-Line "    5  Лимит итераций без прогресса: $($e.maxConsecutiveNoProgress)"
        Write-Line "    6  Лимит итераций с одной документацией: $($e.maxConsecutiveDocumentationOnly)"
        Write-Line "    7  Макс. ошибок инструментов за итерацию: $($e.maxToolErrorsPerIteration)"
        Write-Line "    0  Назад"
        Divider
        $choice = Read-Choice 'Выберите пункт'
        switch ($choice) {
            '0' { return }
            '1' { $script:Settings.model = Read-Text 'Модель OpenCode (provider/model)' ([string]$script:Settings.model); Write-Settings }
            '2' { $script:Settings.agent = Read-Text 'Имя агента OpenCode' ([string]$script:Settings.agent); Write-Settings }
            '3' { $e.maxIterationsPerRun = Read-Integer 'Максимум итераций за запуск' ([int]$e.maxIterationsPerRun) 1 1000; Write-Settings }
            '4' {
                $e.maxIterationMinutes = Read-Decimal 'Таймаут одной итерации (мин)' ([double]$e.maxIterationMinutes) 1 1440
                $e.pollSeconds = Read-Decimal 'Интервал проверки (сек)' ([double]$e.pollSeconds) 1 300
                Write-Settings
            }
            '5' { $e.maxConsecutiveNoProgress = Read-Integer 'Остановка после N итераций без задач' ([int]$e.maxConsecutiveNoProgress); Write-Settings }
            '6' { $e.maxConsecutiveDocumentationOnly = Read-Integer 'Остановка после N итераций только с документацией' ([int]$e.maxConsecutiveDocumentationOnly); Write-Settings }
            '7' { $e.maxToolErrorsPerIteration = Read-Integer 'Допустимо ошибок инструментов за итерацию' ([int]$e.maxToolErrorsPerIteration) 0 10000; Write-Settings }
            default { }
        }
    }
}
function Configure-Logs {
    while ($true) {
        Show-Header
        $l = $script:Settings.logs
        Write-Line '  РОТАЦИЯ ЛОГОВ ПО ПРОЕКТАМ' 'White'
        Write-Line "    1  Хранение логов: $($l.retainDays) days"
        Write-Line "    2  Макс. комплектов: $($l.maxIterationsPerProject)"
        Write-Line "    3  Макс. объём на проект: $($l.maxTotalMiBPerProject) MiB"
        Write-Line "    4  Хранение отчётов: $($l.reportRetainDays) days"
        Write-Line "    5  Корень хранения: $($l.root)"
        Write-Line '    0  Назад'
        Divider
        $choice = Read-Choice 'Выберите пункт'
        switch ($choice) {
            '0' { return }
            '1' { $l.retainDays = Read-Integer 'Хранение логов, дней' ([int]$l.retainDays); Write-Settings }
            '2' { $l.maxIterationsPerProject = Read-Integer 'Макс. комплектов логов на проект' ([int]$l.maxIterationsPerProject); Write-Settings }
            '3' { $l.maxTotalMiBPerProject = Read-Decimal 'Макс. объём логов на проект (МиБ)' ([double]$l.maxTotalMiBPerProject) 1.0; Write-Settings }
            '4' { $l.reportRetainDays = Read-Integer 'Хранение отчётов, дней' ([int]$l.reportRetainDays); Write-Settings }
            '5' { $l.root = Read-Text 'Корневая папка данных Runner' ([string]$l.root); Write-Settings }
            default { }
        }
    }
}
function Configure-Projects {
    while ($true) {
        Show-Header
        Write-Line '  ПРОЕКТЫ (ОТДЕЛЬНЫЕ ЛОГИ И ОТЧЁТЫ)' 'White'
        $entries = @($script:Settings.projects)
        for ($i=0; $i -lt $entries.Count; $i++) {
            $selected = if ([string]$entries[$i].id -eq $script:Project) { '*' } else { ' ' }
            Write-Line ('    {0} {1}  {2}  [{3}]' -f ($i+1),$selected,$entries[$i].id,$entries[$i].branch) 'Gray'
        }
        Write-Line '    A  Добавить проект'
        Write-Line '    E  Изменить настройки выбранного проекта'
        Write-Line '    0  Назад'
        Divider
        $choice = Read-Choice 'Выберите проект'
        if ($choice -eq '0') { return }
        if ($choice -eq 'e') {
            $p = Get-SelectedProject
            $path = Read-Text 'Путь к проекту' ([string]$p.path)
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                Write-Line '  Папка проекта не существует.' 'Yellow'; Pause-Menu; continue
            }
            $branch = Read-Text 'Ветка Git' ([string]$p.branch)
            $roadmap = Read-Text 'Roadmap' ([string]$p.roadmap)
            $progress = Read-Text 'Progress' ([string]$p.progress)
            $p.path = $path; $p.branch = $branch; $p.roadmap = $roadmap; $p.progress = $progress
            Write-Settings
            continue
        }
        if ($choice -eq 'a') {
            Write-Line '  Примечание: существующий prompt и TODO-парсер ориентированы на задачи NTD.' 'Yellow'
            if (-not (Confirm 'Добавить проект с текущими общими правилами Terra?')) { continue }
            $id = Read-Text 'ID нового проекта' ''
            if ($id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { Write-Line '  Неправильный ID проекта.' 'Yellow'; Pause-Menu; continue }
            if (@($entries | Where-Object { $_.id -eq $id }).Count -gt 0) { Write-Line '  Проект с таким ID уже существует.' 'Yellow'; Pause-Menu; continue }
            $path = Read-Text 'Абсолютный путь к проекту' ''
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { Write-Line '  Папка не найдена.' 'Yellow'; Pause-Menu; continue }
            $branch = Read-Text 'Требуемая ветка Git' 'codex/terra'
            $roadmap = Read-Text 'Имя файла roadmap' 'NTD-ROADMAP.md'
            $progress = Read-Text 'Имя файла progress' 'NTD-PROGRESS.md'
            $entry = [ordered]@{ id=$id; path=$path; branch=$branch; roadmap=$roadmap; progress=$progress }
            $script:Settings.projects = @($script:Settings.projects) + @($entry)
            Write-Settings
            $script:Project = $id
            continue
        }
        $idx=0
        if ([int]::TryParse($choice,[ref]$idx) -and $idx -gt 0 -and $idx -le $entries.Count) {
            $script:Project = [string]$entries[$idx-1].id
            return
        }
    }
}
function Open-LogFolder {
    $target = Join-Path (Join-Path (Get-StorageRoot) $script:Project) 'logs'
    [void][IO.Directory]::CreateDirectory($target)
    if ($IsWindows) { Invoke-Item -LiteralPath $target }
    else { Write-Line "  Логи: $target" 'Cyan'; Pause-Menu }
}
function Invoke-SelfTest {
    $config = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
    foreach ($name in @('budget','execution','logs','projects')) {
        if ($null -eq $config[$name]) { throw "Missing config property $name" }
    }
    if (@($config.projects).Count -lt 1) { throw 'No projects' }
    foreach ($sourceFile in @((Join-Path $script:Root 'terra-ui.ps1'),(Join-Path $script:Root 'terra-runner.ps1'))) {
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($sourceFile,[ref]$tokens,[ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { throw "Ошибки синтаксиса в ${sourceFile}: $($parseErrors -join '; ')" }
    }
    Write-Line 'PASS: PowerShell 7 parsed UI and runner scripts.' 'Green'
    $bar = Render-Bar 0.5 10
    if ($bar.Length -ne 10) { throw 'Progress bar must use fixed width' }
    if ((Money 1.5) -ne '$1.50') { throw 'Currency formatting error' }
    Write-Line 'PASS: configuration, progress bar and currency rendering.' 'Green'
    $copy = Join-Path ([IO.Path]::GetTempPath()) ('terra-ui-' + [guid]::NewGuid().ToString('N'))
    $originalCfg = $script:ConfigFile
    try {
        [void][IO.Directory]::CreateDirectory($copy)
        $script:ConfigFile = Join-Path $copy 'terra-config.json'
        [IO.File]::WriteAllText($script:ConfigFile,(ConvertTo-Json -InputObject $config -Depth 60),[Text.UTF8Encoding]::new($false))
        $script:Settings = $config
        $script:Settings.model = 'openai/test-model-for-selftest'
        # Save to a temporary configuration, not to the user's real config.
        Write-Settings
        Read-Settings
        if ($script:Settings.model -cne 'openai/test-model-for-selftest') { throw 'Config save/read test failed' }
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $copy 'data/config-backups') -Filter 'terra-config-*.json')
        if ($backups.Count -lt 1) { throw 'No configuration backup was created.' }
        Write-Line 'PASS: temporary configuration roundtrip and backup.' 'Green'
    } finally {
        $script:ConfigFile = $originalCfg
        if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Recurse -Force }
        Read-Settings
    }
}

function Initialize-TerraConfiguration {
    if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) { return $true }
    $legacyConfig = Join-Path $script:Root 'terra-config.json'
    if (-not $Portable -and (Test-Path -LiteralPath $legacyConfig -PathType Leaf)) {
        $targetRoot = Split-Path -Parent $script:ConfigFile
        [void][IO.Directory]::CreateDirectory($targetRoot)
        $backup = Join-Path $targetRoot ('legacy-config-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Copy-Item -LiteralPath $legacyConfig -Destination $backup -Force
        Copy-Item -LiteralPath $legacyConfig -Destination $script:ConfigFile -Force
        $migrated = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
        if ($migrated.logs -and -not [IO.Path]::IsPathRooted([string]$migrated.logs.root)) {
            $migrated.logs.root = Join-Path $targetRoot 'projects'
            $migrated.schemaVersion = 3
            [IO.File]::WriteAllText($script:ConfigFile,(ConvertTo-Json $migrated -Depth 60),[Text.UTF8Encoding]::new($false))
        }
        Write-Host "Migrated a copy of the legacy configuration to $script:ConfigFile" -ForegroundColor Green
        return $true
    }

    Write-Host 'Welcome to Terra Runner. Setup creates configuration only; it never starts OpenCode.' -ForegroundColor Cyan
    $projectPath = Read-Host 'Project folder (leave blank to cancel setup)'
    if ([string]::IsNullOrWhiteSpace($projectPath)) { return $false }
    if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) { throw 'Project folder does not exist.' }
    $projectPath = (Resolve-Path -LiteralPath $projectPath).ProviderPath
    $projectId = ([IO.Path]::GetFileName($projectPath) -replace '[^a-zA-Z0-9_.-]','-').Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($projectId)) { $projectId = 'project-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
    $branch = Read-Host 'Git branch [main]'; if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }
    $roadmap = Read-Host 'Roadmap file [ROADMAP.md]'; if ([string]::IsNullOrWhiteSpace($roadmap)) { $roadmap = 'ROADMAP.md' }
    $progress = Read-Host 'Progress file [PROGRESS.md]'; if ([string]::IsNullOrWhiteSpace($progress)) { $progress = 'PROGRESS.md' }
    $openCode = Read-Host 'OpenCode command [opencode]'; if ([string]::IsNullOrWhiteSpace($openCode)) { $openCode = 'opencode' }
    $root = Split-Path -Parent $script:ConfigFile
    [void][IO.Directory]::CreateDirectory($root)
    $settings = [ordered]@{
        schemaVersion=3; openCodeCommand=$openCode; agent='build'; model=''
        projects=@([ordered]@{ id=$projectId; path=$projectPath; branch=$branch; roadmap=$roadmap; progress=$progress })
        budget=[ordered]@{ mode='daily'; dailyUsd=5.0; reserveUsd=0.5; emergencyStopUsd=4.95; allowUnlimited=$false; requireGlobalOpenCodeStats=$true; stopOnZeroCostWithTokens=$true; balance=[ordered]@{ source='snapshot'; id='default-account'; minimumUsd=5.0; iterationReserveUsd=0.5; maxAgeMinutes=5; command=''; arguments=@() } }
        execution=[ordered]@{ pollSeconds=20; maxIterationMinutes=45; maxIterationsPerRun=500; maxConsecutiveNoProgress=3; maxConsecutiveDocumentationOnly=12; maxToolErrorsPerIteration=15; pauseBetweenIterationsSeconds=3; maxRawLogMiB=80 }
        logs=[ordered]@{ root=(Join-Path $root 'projects'); retainDays=21; maxIterationsPerProject=150; maxTotalMiBPerProject=300; reportRetainDays=60 }
    }
    [IO.File]::WriteAllText($script:ConfigFile,((ConvertTo-Json $settings -Depth 60) + "`n"),[Text.UTF8Encoding]::new($false))
    Write-Host 'Settings saved. Run Validate project before starting development.' -ForegroundColor Green
    return $true
}

if (-not (Test-Path -LiteralPath $script:Runner -PathType Leaf)) { throw "Main runner script missing: $script:Runner" }
if (-not (Initialize-TerraConfiguration)) { Write-Host 'Setup cancelled.'; return }
Read-Settings
if ($SelfTest) { Invoke-SelfTest; return }
while ($true) {
    Show-Header
    Write-Line '  ГЛАВНОЕ МЕНЮ' 'White'
    Write-Line '    1  Одна итерация разработки' 'Green'
    Write-Line '    2  Автономный цикл разработки' 'Green'
    Write-Line '    3  Проверка готовности (DryRun)' 'Cyan'
    Write-Line '    4  Текущий бюджет и статус' 'Cyan'
    Write-Line '    5  Настройки бюджета' 'White'
    Write-Line '    6  Модель и параметры выполнения' 'White'
    Write-Line '    7  Выбрать / добавить проект' 'White'
    Write-Line '    8  Ротация и хранение логов' 'White'
    Write-Line "    9  Отчёт по проекту за сегодня" 'White'
    Write-Line '    T  Офлайн-самотест (без API-расходов)' 'Cyan'
    Write-Line '    L  Открыть папку логов' 'Gray'
    Write-Line '    S  Остановить после итерации' 'Yellow'
    Write-Line '    A  Аварийно остановить итерацию' 'Red'
    Write-Line '    C  Сбросить флаги остановки' 'Yellow'
    Write-Line '    0  Выход' 'Gray'
    Divider
    $choice = Read-Choice 'Выберите пункт'
    switch ($choice) {
        '1' { Invoke-Runner -Command @{ Once=$true; ShowProgress=$true } }
        '2' {
            Write-Line '  Это запустит платные API-запросы до остановки по лимитам.' 'Yellow'
            if (Confirm 'Начать автономную разработку?') { Invoke-Runner -Command @{ Continuous=$true; ShowProgress=$true } }
        }
        '3' { Invoke-Runner -Command @{ DryRun=$true } }
        '4' { Invoke-Runner -Command @{ Status=$true } }
        '5' { Configure-Budget }
        '6' { Configure-Execution }
        '7' { Configure-Projects }
        '8' { Configure-Logs }
        '9' { Invoke-Runner -Command @{ Report=$true } }
        't' {
            try { Invoke-OfflineTests }
            catch { Write-Line ('  Ошибка самотеста: ' + $_.Exception.Message) 'Red' }
            Pause-Menu
        }
        'l' { Open-LogFolder }
        's' { Invoke-Runner -Command @{ Stop=$true } }
        'a' {
            Write-Line '  Активный OpenCode завершится при следующей проверке.' 'Red'
            if (Confirm 'Аварийно остановить текущую итерацию?') { Invoke-Runner -Command @{ Abort=$true } }
        }
        'c' { Invoke-Runner -Command @{ ClearStop=$true } }
        '0' { return }
        default { Write-Line '  Выберите допустимый пункт.' 'Yellow'; Start-Sleep -Milliseconds 550 }
    }
}
