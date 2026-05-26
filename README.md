# systemd-attach

`systemd-attach` is an Emacs package for starting durable, noninteractive shell
jobs with `systemd-run --user`.

It is intended to feel like a remote-safe `async-shell-command`: launch a long
job locally or through TRAMP, disconnect Emacs or your laptop, then later view,
follow, stop, delete, or rerun the job from Emacs. Output is read from
`journalctl`.

This is not a `screen`, `tmux`, or `dtach` replacement. Version 0.1 treats stdin
as unsupported after launch. Commands that prompt, run curses interfaces, open
REPLs, or require a live terminal are expected to hang or fail.

## Provenance

This package was vibe-coded with AI assistance rather than handcrafted
line-by-line. Treat it as practical experimental tooling: review the source and
test against your own Emacs/TRAMP/systemd setup before relying on it.

## Requirements

- Emacs 28.1 or newer
- `systemd-run`
- `systemctl`
- `journalctl`
- `/bin/sh`
- A working user systemd manager on the target host

For TRAMP usage, those programs must exist on the remote host and the remote
user must be able to run user units.

## Installation

From a GitHub checkout with `use-package` and `vc`:

```elisp
(use-package systemd-attach
  :vc (:url "https://github.com/USER/systemd-attach"
       :rev :newest)
  :demand t
  :bind
  ("M-&" . systemd-attach-shell-command)
  :custom
  (systemd-attach-open-after-start 'follow))
```

With `straight.el`:

```elisp
(use-package systemd-attach
  :straight (:host github :repo "USER/systemd-attach")
  :demand t
  :bind
  ("M-&" . systemd-attach-shell-command)
  :custom
  (systemd-attach-open-after-start 'follow))
```

With Doom Emacs:

```elisp
;; packages.el
(package! systemd-attach
  :recipe (:host github :repo "USER/systemd-attach"))

;; config.el
(use-package! systemd-attach
  :demand t
  :bind
  ("M-&" . systemd-attach-shell-command)
  :custom
  (systemd-attach-open-after-start 'follow))
```

With `use-package` from a local checkout:

```elisp
(use-package systemd-attach
  :load-path "/path/to/systemd-attach"
  :demand t
  :bind
  ("M-&" . systemd-attach-shell-command)
  :custom
  (systemd-attach-open-after-start 'follow))
```

`package.el` can also install the single-file package directly:

```elisp
M-x package-install-file RET /path/to/systemd-attach/systemd-attach.el RET
```

Manual `load-path` setup is also supported:

```elisp
(add-to-list 'load-path "/path/to/systemd-attach")
(require 'systemd-attach)
```

## Usage

Start a durable job:

```elisp
M-x systemd-attach-shell-command
```

Useful commands:

- `systemd-attach-shell-command`: start a command as a transient user service.
- `systemd-attach-dashboard`: show the current local/TRAMP target dashboard.
- `systemd-attach-dashboard-known`: show all locally known sessions.
- `systemd-attach-open-session`: choose a known session and view output.
- `systemd-attach-follow-session`: follow live journal output.
- `systemd-attach-view-session`: show recent journal output.
- `systemd-attach-view-session-compilation`: show output in `compilation-mode`.
- `systemd-attach-refresh-session`: refresh cached unit state and exit status.
- `systemd-attach-kill-session`: stop a running unit.
- `systemd-attach-rerun-session`: rerun a recorded command.
- `systemd-attach-delete-session`: remove local metadata.
- `systemd-attach-cleanup-sessions`: remove old local metadata for the current target.
- `systemd-attach-cleanup-known-sessions`: remove old local metadata across all known targets.
- `systemd-attach-copy-command`: copy the original command.
- `systemd-attach-copy-output`: copy recent output.
- `systemd-attach-dired-do-shell-command`: run a Dired shell-style command through systemd-attach.
- `systemd-attach-dired-command`: run a command from the current Dired directory.
- `systemd-attach-dired-command-with-marked-files`: run a command with marked files appended.

To make it easy to use as an `async-shell-command` alternative:

```elisp
(global-set-key (kbd "M-&") #'systemd-attach-shell-command)
```

## Dashboard

Run:

```elisp
M-x systemd-attach-dashboard
```

The default dashboard is scoped to the current target: the local machine, or
the TRAMP host from the current `default-directory`. It combines live units from
`systemctl --user list-units 'systemd-attach-*.service'` with saved local
metadata for the same target, so completed `--collect` jobs still appear after
systemd unloads the transient unit. If a discovered unit matches local metadata,
the row is enriched with the original command, directory, origin, and creation
time.

New runs write a small `systemd-attach` metadata header to their journal output,
including the original command, working directory, origin, and creation time.
That lets the target dashboard recover enough information to rerun jobs even
when local metadata is missing. Older runs without this header can still be
viewed, followed, or stopped, but cannot be rerun unless local metadata exists.

For the old metadata-first view across all saved remotes, use:

```elisp
M-x systemd-attach-dashboard-known
```

In the known-sessions dashboard, `g` refreshes rows whose cached state still
looks live, such as `starting`, `active`, or `stopping`. `R` force-refreshes
every row and may reconnect to old TRAMP hosts.

Dashboard keys:

- `RET` or `v`: view output.
- `f`: follow output.
- `g`: refresh/redraw the current dashboard.
- `R`: force-refresh state for all sessions.
- `k`: stop the selected unit.
- `!`: rerun the selected command.
- `d`: delete local metadata for the selected session.
- `x`: clean up terminal local metadata in the current dashboard scope.

If Evil is loaded, `RET` is also bound in Evil normal state for the dashboard
buffer. Dashboard actions are additionally available under
`systemd-attach-dashboard-evil-prefix`, which defaults to Doom's localleader
style prefix, `SPC m`:

- `SPC m RET` or `SPC m v`: view output.
- `SPC m f`: follow output.
- `SPC m g`: refresh live-looking sessions and redraw.
- `SPC m R`: force-refresh state for all sessions.
- `SPC m k`: stop the selected unit.
- `SPC m !`: rerun the selected command.
- `SPC m d`: delete local metadata for the selected session.
- `SPC m x`: clean up terminal local metadata in the current dashboard scope.

Single-key Evil movement and operators are left alone.

Cleanup only edits the local session metadata file. It does not stop systemd
units and does not delete journal history. By default, cleanup removes sessions
whose cached state is `finished`, `failed`, or `inactive`, plus sessions with a
recorded exit code. Use a prefix argument with the cleanup commands to wipe all
metadata in the selected scope after confirmation.

## Dired

In a Dired buffer:

- `M-x systemd-attach-dired-do-shell-command` starts a durable command using Dired's normal shell-command marked-file expansion.
- `M-x systemd-attach-dired-command` starts a durable command in the current Dired directory.
- `M-x systemd-attach-dired-command-with-marked-files` starts a durable command and appends marked regular files as shell-quoted arguments.

By default, Dired also gets a small prefix map:

- `C-c C-s &`: run a Dired shell-style command through systemd-attach.
- `C-c C-s c`: run a command in the current Dired directory.
- `C-c C-s m`: run a command with marked files appended.

If Evil is loaded, Dired also gets Doom-style localleader bindings under
`systemd-attach-dired-evil-prefix`, which defaults to `SPC m`:

- `SPC m &`: run a Dired shell-style command through systemd-attach.
- `SPC m c`: run a command in the current Dired directory.
- `SPC m m`: run a command with marked files appended.

The shell-style command follows Dired's usual `!' behavior for marked files:
whitespace-surrounded `*' is replaced by the full marked file list, `?' runs
once per file, and otherwise file names are appended. For TRAMP Dired buffers,
commands run on the target host.

## Org Babel

After `ob-shell` loads, shell blocks can opt in with `:systemd-attach t`:

```org
#+begin_src shell :systemd-attach t
sleep 10
echo done
#+end_src
```

The block returns a marker like:

```text
[systemd-attach: systemd-attach-20260525T120000-abcdef]
```

## TRAMP

Run `systemd-attach-shell-command` from a TRAMP buffer or with a TRAMP
`default-directory`. Emacs process APIs will execute `systemd-run`,
`systemctl`, and `journalctl` on the remote host.

Session metadata is stored locally, while the process and logs remain on the
target host.

## Testing

Run unit tests:

```sh
emacs --batch -L . -l systemd-attach.el -l test/systemd-attach-test.el \
  -f ert-run-tests-batch-and-exit
```

Integration tests are disabled by default because they require a working user
systemd bus:

```sh
SYSTEMD_ATTACH_INTEGRATION=1 emacs --batch -L . -l systemd-attach.el \
  -l test/systemd-attach-test.el -f ert-run-tests-batch-and-exit
```
