#!/usr/bin/env pwsh
# SPDX-License-Identifier: GPL-2.0-or-later

$tag = 'float!'

$ErrorActionPreference = 'Stop'

# ── Sequence editor mode ───────────────────────────────────────────────────────
# Git sets GIT_REFLOG_ACTION=rebase and calls us with the rebase todo file as
# the last argument.  We sort float! commits to the end, then hand off to the
# real editor.
if ($env:GIT_REFLOG_ACTION -eq 'rebase') {
    $file = $args[-1]

    $floats   = [System.Collections.Generic.List[string]]::new()
    $header   = [System.Collections.Generic.List[string]]::new()
    $tail     = [System.Collections.Generic.List[string]]::new()
    $inHeader = $true

    foreach ($line in (Get-Content -LiteralPath $file)) {
        if ($inHeader) {
            if ($line -eq '') {
                $inHeader = $false
                continue          # skip the blank separator line; we re-add it below
            }
            $parts = $line -split ' ', 3
            $act   = $parts[0]
            $dsc   = if ($parts.Count -ge 3) { $parts[2] } else { '' }
            if (($act -eq 'p' -or $act -eq 'pick') -and $dsc.StartsWith($tag)) {
                $floats.Add($line)
            } else {
                $header.Add($line)
            }
        } else {
            $tail.Add($line)
        }
    }

    $all = $header + $floats + @('') + $tail
    [System.IO.File]::WriteAllText(
        $file,
        ($all -join "`n") + "`n",
        [System.Text.UTF8Encoding]::new($false)   # UTF-8 without BOM, LF line endings
    )

    # Invoke the real editor (e.g. "vim", "code --wait") with the same args git
    # passed to us so the user can review / further edit the rebase list.
    $editorTokens = ((& git var GIT_EDITOR).Trim()) -split '\s+'
    $editorArgs   = @($editorTokens | Select-Object -Skip 1) + @($args)
    & $editorTokens[0] @editorArgs
    exit $LASTEXITCODE
}

# ── Pre-push hook mode ─────────────────────────────────────────────────────────
# The installed pre-push wrapper calls us with -PrePush followed by the remote
# name and URL that git passes to the hook.
if ($args.Count -ge 1 -and $args[0] -eq '-PrePush') {
    $remote = if ($args.Count -ge 2) { $args[1] } else { '' }
    $z40    = '0000000000000000000000000000000000000000'

    while ($null -ne ($inputLine = [Console]::In.ReadLine())) {
        $inputLine = $inputLine.Trim()
        if ($inputLine -eq '') { continue }

        $parts = $inputLine -split '\s+'
        if ($parts.Count -lt 4) { continue }
        $lref = $parts[0]; $lsha = $parts[1]; $rref = $parts[2]; $rsha = $parts[3]

        if ($lsha -eq $z40) { continue }   # handle delete – nothing to check

        $range = if ($rsha -eq $z40) { $lsha } else { "${rsha}..${lsha}" }

        # Find the last float! commit in the push range
        $commit   = $null
        $logLines = & git log --format=oneline --grep "^$tag" $range 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($logLine in $logLines) {
                $logParts = ($logLine -as [string]) -split ' ', 2
                if ($logParts.Count -ge 2 -and $logParts[1].StartsWith($tag)) {
                    $commit = $logParts[0]
                }
            }
        }

        if ($commit) {
            $parent = (& git rev-parse "${commit}^").Trim()
            $branch = $rref -replace '^refs/heads/', ''
            [Console]::Error.WriteLine("Found $tag commit in $lref, not pushing. Try this instead:")
            [Console]::Error.WriteLine('')
            [Console]::Error.WriteLine("git push $remote ${parent}:${branch}")
            [Console]::Error.WriteLine('')
            exit 1
        }
    }
    exit 0
}

# ── Interactive mode: install / uninstall / show info ─────────────────────────
$usage = @"
Usage: $($MyInvocation.MyCommand.Name) [-i] [-u] [-f] [-h]

-i install git-float hooks
-u uninstall git-float hooks
-f force install/uninstall
-h show this help
"@

$action = 'info'
$force  = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        '-i'    { $action = 'install' }
        '-u'    { $action = 'uninstall' }
        '-f'    { $force = $true }
        '-h'    { Write-Host $usage; exit 0 }
        default { [Console]::Error.WriteLine($usage); exit 1 }
    }
}

$null = & git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('not a git repo, please run this script from a git repository')
    exit 1
}

# Resolve the canonical absolute path to this script so it can be stored in
# git config and reproduced verbatim for comparison later.
$self = (Resolve-Path -LiteralPath $PSCommandPath).Path

$seqedit = ''
$seqOut  = & git config sequence.editor 2>&1
if ($LASTEXITCODE -eq 0) { $seqedit = "$seqOut".Trim() }

$hookspath = (& git rev-parse --git-path hooks).Trim()

# Use forward slashes in stored paths so the values are valid in both pwsh and
# the #!/bin/sh wrapper that git for Windows uses to invoke hooks.
$selfFwd = $self -replace '\\', '/'
$seqCmd  = "pwsh -NonInteractive -File `"$selfFwd`""

$hookFile = Join-Path $hookspath 'pre-push'
$hookMark = '# git-float-hook'

function Get-HookContent {
    # Returns a minimal POSIX shell wrapper.  Git for Windows uses its bundled
    # bash to run hooks, so this one-liner is sufficient on all platforms.
    "#!/bin/sh`n$hookMark`nexec pwsh -NonInteractive -File `"$selfFwd`" -PrePush `"`$@`"`n"
}

function Test-OurHook {
    if (-not (Test-Path -LiteralPath $hookFile)) { return $false }
    $c = Get-Content -LiteralPath $hookFile -Raw -ErrorAction SilentlyContinue
    return $null -ne $c -and $c -match [regex]::Escape($hookMark)
}

switch ($action) {
    'install' {
        if ($seqedit -eq $seqCmd) {
            Write-Host 'rebase sequence filter already installed'
        } elseif ($seqedit -ne '' -and -not $force) {
            Write-Host "rebase sequence editor set to '$seqedit'. skipping"
        } else {
            Write-Host 'setting rebase sequence editor'
            & git config sequence.editor $seqCmd
        }

        if (Test-OurHook) {
            Write-Host 'pre-push hook already installed'
        } elseif ((Test-Path -LiteralPath $hookFile) -and -not $force) {
            Write-Host 'pre-push hook exists, but not us. skipping'
        } else {
            Write-Host 'installing pre-push hook'
            [System.IO.File]::WriteAllText(
                $hookFile,
                (Get-HookContent),
                [System.Text.UTF8Encoding]::new($false)
            )
        }
    }
    'uninstall' {
        if ($seqedit -eq '') {
            Write-Host 'rebase sequence filter not installed'
        } elseif ($force -or $seqedit -eq $seqCmd) {
            Write-Host 'removing rebase sequence filter'
            & git config --local --unset sequence.editor
        } else {
            Write-Host "rebase sequence editor set to '$seqedit'. skipping"
        }

        if (-not (Test-Path -LiteralPath $hookFile)) {
            Write-Host 'pre-push hook not installed'
        } elseif ($force -or (Test-OurHook)) {
            Write-Host 'removing pre-push hook'
            Remove-Item -LiteralPath $hookFile -Force
        } else {
            Write-Host 'pre-push hook exists, but not us. skipping'
        }
    }
    default {
        if ($seqedit -eq $seqCmd) {
            Write-Host 'rebase sequence filter installed'
        } elseif ($seqedit -ne '') {
            Write-Host "rebase sequence editor set to '$seqedit'"
        } else {
            Write-Host 'rebase sequence filter not installed'
        }

        if (Test-OurHook) {
            Write-Host 'pre-push hook installed'
        } elseif (Test-Path -LiteralPath $hookFile) {
            $hookItem = Get-Item -LiteralPath $hookFile -ErrorAction SilentlyContinue
            if ($hookItem -and $hookItem.LinkType) {
                Write-Host "pre-push hook points to '$($hookItem.Target)'"
            } else {
                Write-Host 'pre-push hook exists, but not us'
            }
        } else {
            Write-Host 'pre-push hook not installed'
        }
    }
}
