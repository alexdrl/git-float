# git-float


## What is this?

git-float is a script to help manage "floating commits". That is commits that you
keep rebasing locally and are not meant for upstreaming or just not ready yet.

Using `git pull -r` git will automatically rebase local commits after pulling the
latest changes. However when you want to push some commits you first need
to rebase your commits to move the floating commits last, and then find the
SHA of the last non-floating commit that is ready to be pushed before doing
```sh
git push origin <SHA>:master
```
This process is where git-float will help you.


## Requirements

[PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`) must be
available on your `PATH`.  On Windows, Git for Windows is required so that git
hooks can be executed.

## How to use git-float

Mark your floating commits with the prefix `float!` in the commit header.
Enter your local git repository, and run
```pwsh
pwsh /path/to/git-float.ps1 -i
```
This will install a filter that automatically moves floating commits to the
end of the list when doing `git rebase -i`. It will also install a pre-push
hook that prevents you from pushing floating commits, and if you do it will
find the last non-floating commit SHA and suggest you use
```pwsh
git push <remote> <SHA>:<remote branch>
```
instead.

If you no longer want to use git-float, just do
```pwsh
pwsh /path/to/git-float.ps1 -u
```
to uninstall the hooks again.

### How the hooks work

* **Sequence editor** – git config `sequence.editor` is set to
  `pwsh -NonInteractive -File <path>/git-float.ps1`.  Git passes the rebase
  todo file as an argument and sets `GIT_REFLOG_ACTION=rebase`; the script
  sorts `float!` commits to the end and then opens the real `GIT_EDITOR` so
  you can review the list.

* **Pre-push hook** – a small `#!/bin/sh` wrapper is written to
  `.git/hooks/pre-push`.  It delegates to `git-float.ps1 -PrePush` so that
  all platform logic remains in PowerShell.  Git for Windows ships with a
  bundled bash that runs this wrapper transparently.


## Licence

git-float released under GPLv2 or later to be compatible with [git].

[git]: https://git-scm.com/
