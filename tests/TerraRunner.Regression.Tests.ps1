# Requires PowerShell 7 and Pester. All cases run in temporary directories.
$here = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $here 'terra-runner.ps1'
$mock = Join-Path $PSScriptRoot 'mock-opencode.ps1'

Describe 'Terra Runner safe command dispatch' {
    BeforeEach {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ('terra-runner-regression-' + [guid]::NewGuid().ToString('N'))
        $script:repo = Join-Path $script:root 'project'
        $script:state = Join-Path $script:root 'state'
        $script:calls = Join-Path $script:root 'opencode.calls.log'
        [void][IO.Directory]::CreateDirectory($script:repo)
        $script:config = Join-Path $script:root 'config.json'
        $settings = [ordered]@{
            schemaVersion=2; openCodeCommand=$mock; agent='build'; model='test/model'
            projects=@([ordered]@{ id='safe-project'; path=$script:repo; branch='main'; roadmap='ROADMAP.md'; progress='PROGRESS.md' })
            budget=[ordered]@{ mode='daily'; dailyUsd=5.0; reserveUsd=0.5; emergencyStopUsd=4.95; allowUnlimited=$false; requireGlobalOpenCodeStats=$true; stopOnZeroCostWithTokens=$true; balance=[ordered]@{ source='snapshot'; id='test-account'; minimumUsd=1.0; iterationReserveUsd=0.5; maxAgeMinutes=5; command=''; arguments=@() } }
            execution=[ordered]@{ pollSeconds=1; maxIterationMinutes=1; maxIterationsPerRun=2; maxConsecutiveNoProgress=2; maxConsecutiveDocumentationOnly=2; maxRawLogMiB=1 }
            logs=[ordered]@{ root=$script:state; retainDays=7; maxIterationsPerProject=10; maxTotalMiBPerProject=10; reportRetainDays=7 }
        }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $env:TERRA_MOCK_CALL_LOG = $script:calls
        $env:TERRA_MOCK_COST = '0.15'
        $env:TERRA_MOCK_ALL_COST = '0.15'
    }
    AfterEach {
        Remove-Item Env:TERRA_MOCK_CALL_LOG,Env:TERRA_MOCK_COST,Env:TERRA_MOCK_ALL_COST -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'does not start an agent for Status' {
        & $runner -Project safe-project -Config $script:config -Status
        (Get-Content -LiteralPath $script:calls -Raw) | Should Not Match '(?m)^run(?:\s|$)'
    }
    It 'grants bounded local infrastructure bootstrap to the development prompt' {
        $prompt = Get-Content -LiteralPath (Join-Path $here 'terra-prompt.md') -Raw
        $prompt | Should Match 'start.*Docker Desktop'
        $prompt | Should Match 'already-installed local development infrastructure'
        $prompt | Should Match 'Do not install, upgrade, uninstall, or reconfigure system software'
        $prompt | Should Match 'Do not.*request elevation'
    }
    It 'uses UTF-8 for PowerShell UI events carrying roadmap titles' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match '\$OutputEncoding\s*=\s*\$Utf8NoBom'
        $source | Should Match '\[Console\]::OutputEncoding\s*=\s*\$Utf8NoBom'
    }
    It 'waits for transient Git and OpenCode network recovery instead of stopping a run' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Wait-ForGitRemotePublish'
        $source | Should Match 'schannel'
        $source | Should Match "Write-UiEvent 'network-waiting'"
        $source | Should Match 'function Wait-ForOpenCodeRecovery'
        $source | Should Not Match 'Transient TLS/SSL failure retry limit'
    }
    It 'uses bounded retries only for a recognised transient provider interruption in Continuous mode' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Get-TransientProviderFailure'
        $source | Should Match 'provider\.invalid-output'
        $source | Should Match 'function Wait-ForTransientProviderRetry'
        $source | Should Match "Write-UiEvent 'provider-retry-waiting'"
        $source | Should Match '\$Continuous -and \$null -ne \$transientProviderFailure'
        $source | Should Match 'transient-provider-retries-exhausted'
    }
    It 'composes each worker prompt with committed project instructions' {
        $worker = Get-Content -LiteralPath (Join-Path $here 'terra-worker.ps1') -Raw
        $worker | Should Match '\[Parameter\(Mandatory\)\]\[string\]\$ProjectInstructionsFile'
        $worker | Should Match 'Get-Content -LiteralPath \$ProjectInstructionsFile'
        $worker | Should Match 'cannot relax global safety rules'
        $worker | Should Match 'stage and commit exactly this existing file'
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Test-OnlyProjectInstructionsChanges'
    }
    It 'validates an optional project-owned integration harness and passes only its path to the worker' {
        $worker = Get-Content -LiteralPath (Join-Path $here 'terra-worker.ps1') -Raw
        $worker | Should Match '\[string\]\$IntegrationHarnessFile'
        $worker | Should Match 'Do not read, print, copy, pass, or edit \.env credentials'
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Resolve-ProjectIntegrationHarnessFile'
        $source | Should Match 'Configured integration harness was not found'
        $source | Should Match "'-IntegrationHarnessFile'"
    }
    It 'creates a normal hooked WIP checkpoint only after a clean worker result' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Save-TerraWipCheckpoint'
        $source | Should Match 'wip\(terra\): checkpoint'
        $source | Should Match "'diff','--cached','--check'"
        $source | Should Match '\$exitCode -eq 0 -and \$eventErrors -eq 0'
    }
    It 'records only redacted OpenCode stream-error types in iteration summaries' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match '\$streamErrorTypes'
        $source | Should Match 'ErrorTypes = @\(\$streamErrorTypes \| ForEach-Object \{ \$_ \}\)'
        $source | Should Not Match 'streamErrorTypes\.ToArray\('
        $source | Should Match 'eventErrorTypes = @\(\$eventErrorTypes\)'
    }
    It 'recognises a clean OpenCode stop event without classifying it as a provider failure' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'function Test-CleanWorkerStop'
        $source | Should Match "OpenCode ended with a clean stop event"
        $source | Should Match 'cleanWorkerStop = \$cleanWorkerStop'
    }

    It 'emits a redacted runner failure event when internal result finalisation throws' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match "\$failureReason = 'runner-internal-error'"
        $source | Should Match "project-git-repository-required"
    }
    It 'requires an explicit selected-task marker before OpenCode tool use' {
        $prompt = Get-Content -LiteralPath (Join-Path $here 'terra-prompt.md') -Raw
        $prompt | Should Match 'TERRA_SELECTED_TASK: <task ID>'
        $prompt | Should Match 'Before using any tool'
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'Test-RoadmapTaskPending \$RoadmapFile \$candidate'
    }
    It 'requires autonomous decomposition before a broad roadmap item becomes a WIP loop' {
        $prompt = Get-Content -LiteralPath (Join-Path $here 'terra-prompt.md') -Raw
        $prompt | Should Match '## Roadmap task sizing'
        $prompt | Should Match 'autonomously decompose it instead of making another WIP slice'
        $prompt | Should Match 'non-checkbox.*parent'
        $prompt | Should Match 'fresh unused `PREFIX-####` IDs'
        $prompt | Should Match 'Stay within the selected task''s direct scope'
    }
    It 'does not start an agent for Report' {
        & $runner -Project safe-project -Config $script:config -Report
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'does not start an agent for ProxyTest' {
        & $runner -Project safe-project -Config $script:config -ProxyTest
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'validates a configured proxy route without overwriting the Host automatic variable' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.proxy = [ordered]@{ activeRouteId='invalid-proxy'; routes=@([ordered]@{ id='invalid-proxy'; name='Invalid'; protocol='http'; host='127.0.0.1'; port=0 }) }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $threw = $false; $message = ''
        try { & $runner -Project safe-project -Config $script:config -ProxyTest } catch { $threw = $true; $message = $_.Exception.Message }
        $threw | Should Be $true
        $message | Should Match 'Configured proxy route is invalid'
        $message | Should Not Match 'перезаписать переменную Host|overwrite.*Host'
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'emits a redacted, structured proxy diagnostic for a failed CONNECT test' {
        $source = Get-Content -LiteralPath $runner -Raw
        $source | Should Match 'TERRA_PROXY_TEST_ERROR:'
        $source | Should Match 'ConvertTo-SafeProxyTestDetail'
        $source | Should Match "--fail --head https://example.com/"
    }
    It 'does not start an agent when no execution command is selected' {
        & $runner -Project safe-project -Config $script:config
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'requires an explicit profile for schema v10 development commands' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.schemaVersion = 10; $settings.Remove('model'); $settings.Remove('budget')
        $settings['openCode'] = [ordered]@{ accounts=@(); profiles=@() }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $threw = $false; $message = ''
        try { & $runner -Project safe-project -Config $script:config -DryRun } catch { $threw = $true; $message = $_.Exception.Message }
        $threw | Should Be $true; $message | Should Match 'requires -ProfileId'
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'uses an explicit schema v10 profile for Status without starting OpenCode' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.schemaVersion = 10; $settings.Remove('model'); $settings.Remove('budget')
        $settings['openCode'] = [ordered]@{ accounts=@(); profiles=@([ordered]@{
            id='local-profile'; model='local/mock'; provider='local'; credentialId=''; credentialLabel=''
            policy='local'; authStoreId=''; reasoningVariant=''; showThinking=$false
            limitPolicy=[ordered]@{ mode='critical' }; usageSource=[ordered]@{ kind='none' }; runControls=[ordered]@{ maxIterations=0 }
        }) }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        & $runner -Project safe-project -Config $script:config -Status -ProfileId local-profile
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'validates a main-window project auth store before any OpenCode command' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.schemaVersion = 10; $settings.Remove('model'); $settings.Remove('budget')
        $settings['openCode'] = [ordered]@{ accounts=@(); profiles=@([ordered]@{
            id='local-profile'; model='local/mock'; provider='local'; credentialId=''; credentialLabel=''
            policy='local'; authStoreId=''; reasoningVariant=''; showThinking=$false
            limitPolicy=[ordered]@{ mode='critical' }; usageSource=[ordered]@{ kind='none' }; runControls=[ordered]@{ maxIterations=0 }
        }) }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $threw = $false; $message = ''
        try { & $runner -Project safe-project -Config $script:config -Status -ProfileId local-profile -AuthStoreId project-auth-test } catch { $threw = $true; $message = $_.Exception.Message }
        $threw | Should Be $true; $message | Should Match 'not initialized'
        (Test-Path -LiteralPath $script:calls) | Should Be $false
        $db = Join-Path $script:root 'opencode-stores/project-auth-test/opencode.db'; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $db)); [IO.File]::WriteAllText($db,'mock')
        & $runner -Project safe-project -Config $script:config -Status -ProfileId local-profile -AuthStoreId project-auth-test
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'rejects unsafe project auth store IDs before OpenCode starts' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.schemaVersion = 10; $settings.Remove('model'); $settings.Remove('budget')
        $settings['openCode'] = [ordered]@{ accounts=@(); profiles=@([ordered]@{
            id='local-profile'; model='local/mock'; provider='local'; credentialId=''; credentialLabel=''
            policy='local'; authStoreId=''; reasoningVariant=''; showThinking=$false
            limitPolicy=[ordered]@{ mode='critical' }; usageSource=[ordered]@{ kind='none' }; runControls=[ordered]@{ maxIterations=0 }
        }) }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $threw = $false; $message = ''
        try { & $runner -Project safe-project -Config $script:config -Status -ProfileId local-profile -AuthStoreId '../escape' } catch { $threw = $true; $message = $_.Exception.Message }
        $threw | Should Be $true; $message | Should Match 'Unsafe OpenCode auth store ID'
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'creates and clears only the selected project control files' {
        & $runner -Project safe-project -Config $script:config -Stop
        $projectData = Join-Path $script:state 'safe-project'
        (Test-Path -LiteralPath (Join-Path $projectData 'STOP')) | Should Be $true
        & $runner -Project safe-project -Config $script:config -Abort
        (Test-Path -LiteralPath (Join-Path $projectData 'ABORT')) | Should Be $true
        & $runner -Project safe-project -Config $script:config -ClearStop
        (Test-Path -LiteralPath (Join-Path $projectData 'STOP')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $projectData 'ABORT')) | Should Be $false
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'addresses instance controls without touching legacy project controls' {
        $id = [guid]::NewGuid().ToString()
        $runtime = Join-Path $script:root 'runtime/instances'; [void][IO.Directory]::CreateDirectory($runtime)
        $instance = [ordered]@{ id=$id; projectId='safe-project'; profile=[ordered]@{ id='profile'; model='local/mock'; provider='local'; policy='local'; authStoreId=''; reasoningVariant=''; showThinking=$false }; launch=[ordered]@{ command='idle'; maxIterations=0 }; state='idle' }
        $instance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runtime "$id.json") -Encoding utf8
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable; $settings.schemaVersion=7; $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        & $runner -Project safe-project -Config $script:config -InstanceId $id -Stop
        (Test-Path -LiteralPath (Join-Path $script:root "runtime/controls/$id/STOP")) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $script:state 'safe-project/STOP')) | Should Be $false
    }
    It 'disables Terra budget snapshots and validation for an instance' {
        $id = [guid]::NewGuid().ToString()
        $runtime = Join-Path $script:root 'runtime/instances'; [void][IO.Directory]::CreateDirectory($runtime)
        $instance = [ordered]@{ id=$id; projectId='safe-project'; profile=[ordered]@{ id='profile'; model='local/mock'; provider='local'; policy='local'; authStoreId=''; reasoningVariant=''; showThinking=$false }; launch=[ordered]@{ command='idle'; maxIterations=0 }; state='idle' }
        $instance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runtime "$id.json") -Encoding utf8
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $settings.schemaVersion = 9; $settings.Remove('model'); $settings.Remove('budget'); $settings['openCode'] = [ordered]@{ accounts=@(); profiles=@() }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        $threw = $false
        try { & $runner -Project safe-project -Config $script:config -InstanceId $id -Status } catch { $threw = $true }
        $threw | Should Be $false
        (Test-Path -LiteralPath (Join-Path $script:state 'safe-project/budgets')) | Should Be $false
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'keeps reports isolated by project ID' {
        $settings = Get-Content -LiteralPath $script:config -Raw | ConvertFrom-Json -AsHashtable
        $secondRepo = Join-Path $script:root 'second-project'
        [void][IO.Directory]::CreateDirectory($secondRepo)
        $settings.projects += [ordered]@{ id='second-project'; path=$secondRepo; branch='main'; roadmap='ROADMAP.md'; progress='PROGRESS.md' }
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:config -Encoding utf8
        & $runner -Project safe-project -Config $script:config -Report
        & $runner -Project second-project -Config $script:config -Report
        (Test-Path -LiteralPath (Join-Path $script:state 'safe-project/reports')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $script:state 'second-project/reports')) | Should Be $true
        (Test-Path -LiteralPath $script:calls) | Should Be $false
    }
    It 'accepts dot and comma decimal balance input without binding it as an iteration limit' {
        $module = Join-Path $here 'terra-core.psm1'
        Import-Module $module -Force
        (ConvertTo-TerraMoney '96.11') | Should Be ([decimal]96.11)
        (ConvertTo-TerraMoney '96,11') | Should Be ([decimal]96.11)
        foreach ($invalid in @('1,000.00','-1','NaN')) {
            $threw = $false
            try { $null = ConvertTo-TerraMoney $invalid } catch { $threw = $true }
            $threw | Should Be $true
        }
    }
}
