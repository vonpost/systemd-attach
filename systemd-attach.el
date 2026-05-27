;;; systemd-attach.el --- Durable shell jobs via systemd-run -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: dcol
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: processes, terminals, tools
;; URL: https://github.com/dcol/systemd-attach

;; This package was vibe-coded with AI assistance rather than handcrafted
;; line-by-line.  Treat it as practical experimental tooling: review the source
;; and test against your own Emacs/TRAMP/systemd setup before relying on it.

;;; Commentary:

;; systemd-attach starts noninteractive shell commands as transient user
;; services with systemd-run.  It is intended for long-running local or TRAMP
;; jobs that should survive Emacs, SSH, or laptop disconnects.  "Attach" means
;; view or follow journal output and manage the unit; it does not provide a
;; reattachable stdin/TTY like screen, tmux, or dtach.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'dired)
(require 'dired-aux)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)

(defgroup systemd-attach nil
  "Run durable noninteractive shell jobs with systemd-run."
  :group 'processes
  :prefix "systemd-attach-")

(defcustom systemd-attach-systemd-run-program "systemd-run"
  "Program used to start transient systemd services."
  :type 'string)

(defcustom systemd-attach-systemctl-program "systemctl"
  "Program used to query and stop transient systemd services."
  :type 'string)

(defcustom systemd-attach-journalctl-program "journalctl"
  "Program used to read transient service output."
  :type 'string)

(defcustom systemd-attach-tail-program "tail"
  "Program used to read and follow file-backed session output."
  :type 'string)

(defcustom systemd-attach-output-backend 'journal
  "Output backend used for new systemd-attach sessions.
The `journal' backend writes output to journald and reads it with journalctl.
The `file' backend redirects stdout and stderr inside the wrapper to a log file
on the target host, useful for systems where journald is unavailable or stale."
  :type '(choice (const :tag "journalctl" journal)
                 (const :tag "file" file)))

(defcustom systemd-attach-file-log-directory "~/.cache/systemd-attach"
  "Directory on the target host used for file-backed session logs.
For TRAMP sessions this is interpreted on the remote target."
  :type 'string)

(defcustom systemd-attach-shell-program "/bin/sh"
  "Shell used to execute commands."
  :type 'string)

(defcustom systemd-attach-unit-prefix "systemd-attach"
  "Prefix used for generated transient unit names."
  :type 'string)

(defcustom systemd-attach-session-file
  (locate-user-emacs-file "systemd-attach/sessions.el")
  "File where local session metadata is stored."
  :type 'file)

(defcustom systemd-attach-default-tail-lines 200
  "Number of journal lines to show by default."
  :type 'integer)

(defcustom systemd-attach-open-after-start 'follow
  "How to display a session after starting it.
Valid values are nil, `view', and `follow'."
  :type '(choice (const :tag "Do not open" nil)
                 (const :tag "View recent output" view)
                 (const :tag "Follow output" follow)))

(defcustom systemd-attach-default-properties
  '("StandardInput=null"
    "StandardOutput=journal"
    "StandardError=journal"
    "KillMode=control-group")
  "Additional service properties passed to systemd-run with --property."
  :type '(repeat string))

(defcustom systemd-attach-use-json-output t
  "Whether to ask systemd-run for JSON output when starting jobs.
If the target systemd-run does not support this option, systemd-attach retries
without it.  The fallback still starts jobs, but invocation ids may be absent."
  :type 'boolean)

(defcustom systemd-attach-dashboard-evil-prefix "SPC m"
  "Evil normal-state prefix for dashboard action keys.
The default follows Doom Emacs' major-mode localleader convention.  Set this to
nil to disable prefixed Evil dashboard bindings."
  :type '(choice (const :tag "Disable" nil)
                 string))

(defcustom systemd-attach-dired-evil-prefix "SPC m"
  "Evil normal-state prefix for systemd-attach Dired action keys.
The default follows Doom Emacs' major-mode localleader convention.  Set this to
nil to disable prefixed Evil Dired bindings."
  :type '(choice (const :tag "Disable" nil)
                 string))

(defcustom systemd-attach-hide-internal-output t
  "Whether session buffers hide systemd-attach metadata and manager noise."
  :type 'boolean)

(defcustom systemd-attach-start-refresh-delay 1.0
  "Seconds after starting a job before refreshing visible session headers.
Set to nil to disable delayed refresh."
  :type '(choice (const :tag "Disable" nil)
                 number))

(defcustom systemd-attach-visible-refresh-max-attempts 30
  "Maximum automatic header refresh attempts for visible session buffers.
This polling stops early when the session reaches a terminal state or when a
refresh fails, for example because a TRAMP connection is no longer available."
  :type 'integer)

(defcustom systemd-attach-cleanup-terminal-states
  '("finished" "failed" "inactive")
  "Session states considered safe to remove during metadata cleanup."
  :type '(repeat string))

(defcustom systemd-attach-delete-file-logs-on-cleanup t
  "Whether cleanup also deletes exact file-backed session logs.
Only sessions using the `file' output backend are affected.  Missing files are
ignored.  TRAMP or filesystem errors are reported but do not abort metadata
cleanup."
  :type 'boolean)

(defcustom systemd-attach-dired-prefix-key (kbd "C-c C-s")
  "Prefix key for systemd-attach commands in Dired buffers.
Set to nil to avoid installing Dired keybindings."
  :type '(choice (const :tag "Disable" nil)
                 key-sequence))

(defface systemd-attach-state-active
  '((t :inherit success :weight bold))
  "Face for active systemd-attach sessions.")

(defface systemd-attach-state-success
  '((t :inherit font-lock-comment-face))
  "Face for successfully finished systemd-attach sessions.")

(defface systemd-attach-state-failed
  '((t :inherit error :weight bold))
  "Face for failed systemd-attach sessions.")

(defface systemd-attach-state-unknown
  '((t :inherit warning :weight bold))
  "Face for unknown systemd-attach session states.")

(defface systemd-attach-header-label
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for labels in systemd-attach output buffers.")

(defface systemd-attach-header-value
  '((t :inherit font-lock-string-face))
  "Face for values in systemd-attach output buffers.")

(defvar systemd-attach--sessions nil)
(defvar systemd-attach--sessions-loaded nil)
(defvar systemd-attach-dashboard-buffer-name "*systemd-attach*")
(defvar systemd-attach-dashboard-known-buffer-name "*systemd-attach-known*")
(defvar-local systemd-attach-session nil)
(defvar-local systemd-attach--content-start-marker nil)
(defvar-local systemd-attach-dashboard-scope 'target)
(defvar-local systemd-attach-dashboard-directory nil)
(defvar-local systemd-attach-dashboard-sessions nil)
(defconst systemd-attach--exit-marker-prefix "[systemd-attach exit status: ")
(defconst systemd-attach--metadata-marker-prefix "[systemd-attach metadata: ")

(cl-defstruct (systemd-attach-session
               (:constructor systemd-attach--make-session))
  id
  unit
  invocation-id
  command
  default-directory
  working-directory
  remote
  origin
  created-at
  state
  sub-state
  result
  exit-code
  refresh-error
  output-backend
  log-file)

(defun systemd-attach--now-string ()
  "Return the current time as an ISO-like UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun systemd-attach--random-hex ()
  "Return a short random hexadecimal string."
  (format "%06x" (random #x1000000)))

(defun systemd-attach--slug (string)
  "Return STRING reduced to systemd-unit-friendly characters."
  (let ((slug (replace-regexp-in-string "[^[:alnum:]_.:-]+" "-" string)))
    (string-trim slug "-+" "-+")))

(defun systemd-attach--generate-id ()
  "Generate a unique session id."
  (format "%s-%s-%s"
          (systemd-attach--slug systemd-attach-unit-prefix)
          (format-time-string "%Y%m%dT%H%M%S" nil t)
          (systemd-attach--random-hex)))

(defun systemd-attach--unit-name (id)
  "Return a transient service unit name for ID."
  (concat (systemd-attach--slug id) ".service"))

(defun systemd-attach--remote-name (directory)
  "Return a display name for DIRECTORY's TRAMP remote, or nil."
  (when (file-remote-p directory)
    (or (file-remote-p directory 'host)
        (file-remote-p directory 'method))))

(defun systemd-attach--working-directory (directory)
  "Return DIRECTORY as seen by the target host."
  (directory-file-name
   (or (and (file-remote-p directory)
            (file-remote-p directory 'localname))
       (expand-file-name directory))))

(defun systemd-attach--session-directory (session)
  "Return SESSION's process execution directory."
  (or (systemd-attach-session-default-directory session)
      default-directory))

(defun systemd-attach--target-local-file-name (file)
  "Return FILE as a target-local path if FILE is remote."
  (or (and (file-remote-p file)
           (file-remote-p file 'localname))
      (expand-file-name file)))

(defun systemd-attach--file-log-directory (directory)
  "Return the Emacs file name for file-backed logs under DIRECTORY's target."
  (file-name-as-directory
   (expand-file-name systemd-attach-file-log-directory directory)))

(defun systemd-attach--file-log-file (id directory)
  "Return the target-local log file path for ID under DIRECTORY's target."
  (systemd-attach--target-local-file-name
   (expand-file-name (concat id ".log")
                     (systemd-attach--file-log-directory directory))))

(defun systemd-attach--ensure-file-log-directory (directory)
  "Create the file-backed log directory under DIRECTORY's target."
  (make-directory (systemd-attach--file-log-directory directory) t))

(defun systemd-attach--json-encode (object)
  "Encode OBJECT as compact JSON."
  (if (fboundp 'json-serialize)
      (json-serialize object :false-object nil)
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-false nil))
      (json-encode object))))

(defun systemd-attach--metadata-json (id unit working-directory command origin
                                               &optional output-backend log-file)
  "Return JSON metadata for a systemd-attach run."
  (systemd-attach--json-encode
   `((version . 1)
     (id . ,id)
     (unit . ,unit)
     (command . ,command)
     (working_directory . ,working-directory)
     (origin . ,(if origin (format "%s" origin) "manual"))
     (created_at . ,(systemd-attach--now-string))
     (output_backend . ,(and output-backend
                             (format "%s" output-backend)))
     (log_file . ,log-file))))

(defun systemd-attach--shell-single-quote (string)
  "Return STRING safely quoted for POSIX shell single-quote context."
  (concat "'" (replace-regexp-in-string "'" "'\\\\''" string t t) "'"))

(defun systemd-attach--wrapped-command (command metadata-json &optional log-file)
  "Return shell text that runs COMMAND and logs its exit status.
The user command is evaluated in a subshell so a plain `exit' in COMMAND does
not prevent the status marker from being emitted by the wrapper.  If LOG-FILE is
non-nil, stdout and stderr are redirected there before any output is emitted."
  (format "%sprintf '%%s\\n' %s\n( %s\n)\nsystemd_attach_status=$?\nprintf '\\n%s%%s]\\n' \"$systemd_attach_status\"\nexit \"$systemd_attach_status\""
          (if log-file
              (format "systemd_attach_log=%s\nexec >> \"$systemd_attach_log\" 2>&1\n"
                      (systemd-attach--shell-single-quote log-file))
            "")
          (systemd-attach--shell-single-quote
           (concat systemd-attach--metadata-marker-prefix metadata-json "]"))
          command
          systemd-attach--exit-marker-prefix))

(defun systemd-attach--service-properties (output-backend)
  "Return systemd-run service properties for OUTPUT-BACKEND."
  (let ((properties systemd-attach-default-properties))
    (if (eq output-backend 'file)
        (append
         (cl-remove-if
          (lambda (property)
            (string-match-p "\\`Standard\\(?:Output\\|Error\\)=" property))
          properties)
         '("StandardOutput=null" "StandardError=null"))
      properties)))

(defun systemd-attach--systemd-run-args (id unit working-directory command
                                           &optional json-output origin
                                           output-backend log-file)
  "Build systemd-run arguments for ID, UNIT, WORKING-DIRECTORY, and COMMAND."
  (append
   (list "--user"
         "--no-block"
         "--collect"
         "--unit" unit
         "--description" (format "systemd-attach %s" id)
         "--service-type=exec"
         "--working-directory" working-directory
         "--property" (format "SyslogIdentifier=%s" id))
   (when json-output
     (list "--json=short"))
   (cl-mapcan (lambda (property) (list "--property" property))
              (systemd-attach--service-properties output-backend))
   (list systemd-attach-shell-program "-lc"
         (systemd-attach--wrapped-command
          command
          (systemd-attach--metadata-json
           id unit working-directory command origin output-backend log-file)
          log-file))))

(defun systemd-attach--journal-args (session &optional follow lines)
  "Build journalctl arguments for SESSION.
If FOLLOW is non-nil, follow new output.  If LINES is non-nil, limit output to
that many recent entries."
  (append
   (list "--user-unit" (systemd-attach-session-unit session)
         "--output" "cat"
         "--no-pager")
   (cond
    (follow (list "--follow" "--lines" (number-to-string (or lines systemd-attach-default-tail-lines))))
    (lines (list "--lines" (number-to-string lines))))))

(defun systemd-attach--systemctl-show-args (session)
  "Build systemctl show arguments for SESSION."
  (list "--user" "show" (systemd-attach-session-unit session)
        "--property" "ActiveState"
        "--property" "SubState"
        "--property" "Result"
        "--property" "ExecMainStatus"
        "--property" "MainPID"
        "--no-pager"))

(defun systemd-attach--call (program args directory)
  "Run PROGRAM with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT)."
  (let ((default-directory directory))
    (with-temp-buffer
      (let ((exit-code (apply #'process-file program nil t nil args)))
        (cons exit-code (buffer-string))))))

(defun systemd-attach--call-or-error (program args directory)
  "Run PROGRAM with ARGS in DIRECTORY and return output or signal an error."
  (pcase-let ((`(,exit-code . ,output)
               (systemd-attach--call program args directory)))
    (unless (zerop exit-code)
      (error "%s failed with exit code %s: %s"
             program exit-code (string-trim output)))
    output))

(defun systemd-attach--json-option-error-p (output)
  "Return non-nil if OUTPUT looks like systemd-run rejected --json."
  (string-match-p
   (rx (or "unrecognized option" "unknown option" "invalid option")
       (*? anychar)
       "--json")
   output))

(defun systemd-attach--start-call (args directory)
  "Run systemd-run with ARGS in DIRECTORY and return output.
Retry without --json=short if the target systemd-run does not support it."
  (pcase-let ((`(,exit-code . ,output)
               (systemd-attach--call systemd-attach-systemd-run-program
                                     args directory)))
    (if (zerop exit-code)
        output
      (if (and (member "--json=short" args)
               (systemd-attach--json-option-error-p output))
          (systemd-attach--call-or-error
           systemd-attach-systemd-run-program
           (remove "--json=short" args)
           directory)
        (error "%s failed with exit code %s: %s"
               systemd-attach-systemd-run-program exit-code
               (string-trim output))))))

(defun systemd-attach--parse-run-output (output)
  "Parse systemd-run OUTPUT and return (UNIT . INVOCATION-ID)."
  (let ((unit nil)
        (invocation-id nil))
    (condition-case nil
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol))
          (let ((object (json-parse-string output :object-type 'alist)))
            (setq unit (alist-get 'unit object))
            (setq invocation-id (alist-get 'invocation_id object))))
      (error nil))
    (unless unit
      (when (string-match "\\(?:Running as unit\\|Started\\)[^A-Za-z0-9_.@-]*\\([A-Za-z0-9_.@:-]+\\.service\\)" output)
        (setq unit (match-string 1 output))))
    (cons unit invocation-id)))

(defun systemd-attach--parse-properties (output)
  "Parse systemctl property OUTPUT into an alist."
  (let (properties)
    (dolist (line (split-string output "\n" t))
      (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" line)
        (push (cons (match-string 1 line) (match-string 2 line)) properties)))
    (nreverse properties)))

(defun systemd-attach--extract-exit-code (output)
  "Return the last systemd-attach exit code marker in OUTPUT, or nil."
  (let ((start 0)
        code)
    (while (string-match
            (concat (regexp-quote systemd-attach--exit-marker-prefix)
                    "\\([0-9]+\\)\\]")
            output start)
      (setq code (string-to-number (match-string 1 output)))
      (setq start (match-end 0)))
    code))

(defun systemd-attach--extract-metadata (output)
  "Return the first systemd-attach metadata object found in OUTPUT."
  (let ((start 0)
        metadata)
    (while (and (not metadata)
                (string-match
                 (concat "^" (regexp-quote systemd-attach--metadata-marker-prefix)
                         "\\(.*\\)\\]$")
                 output start))
      (setq start (match-end 0))
      (condition-case nil
          (setq metadata
                (json-parse-string (match-string 1 output)
                                   :object-type 'alist))
        (error nil)))
    metadata))

(defun systemd-attach--metadata-get (metadata key)
  "Return KEY from METADATA alist."
  (or (alist-get key metadata)
      (alist-get (symbol-name key) metadata nil nil #'equal)
      (alist-get (intern (replace-regexp-in-string "_" "-" (symbol-name key)))
                 metadata)
      (alist-get (replace-regexp-in-string "_" "-" (symbol-name key))
                 metadata nil nil #'equal)))

(defun systemd-attach--internal-output-line-p (line)
  "Return non-nil if LINE is internal systemd-attach output."
  (or (string-prefix-p systemd-attach--metadata-marker-prefix line)
      (string-prefix-p systemd-attach--exit-marker-prefix line)
      (string-match-p "\\`Starting systemd-attach .*\\.\\.\\.\\'" line)
      (string-match-p "\\`Started systemd-attach .*\\.\\'" line)))

(defun systemd-attach--strip-osc (string)
  "Remove terminal title OSC sequences from STRING."
  (let ((without-esc
         (replace-regexp-in-string "\e\\][^\a]*\a" "" string t t)))
    (replace-regexp-in-string "^\\]0;.*\a$" "" without-esc t t)))

(defun systemd-attach--display-output (output)
  "Return OUTPUT suitable for display to users."
  (let ((output (systemd-attach--strip-osc output)))
    (if (not systemd-attach-hide-internal-output)
        output
      (string-join
       (cl-remove-if #'systemd-attach--internal-output-line-p
                     (split-string output "\n"))
       "\n"))))

(defun systemd-attach--safe-session-slot (session accessor)
  "Return ACCESSOR value for SESSION, or nil if unavailable.
This is used to migrate old persisted `systemd-attach-session' structs after
the struct grows new slots."
  (condition-case nil
      (funcall accessor session)
    (error nil)))

(defun systemd-attach--normalize-session (session)
  "Return SESSION in the current `systemd-attach-session' struct shape."
  (if (not (systemd-attach-session-p session))
      session
    (systemd-attach--make-session
     :id (systemd-attach--safe-session-slot
          session #'systemd-attach-session-id)
     :unit (systemd-attach--safe-session-slot
            session #'systemd-attach-session-unit)
     :invocation-id (systemd-attach--safe-session-slot
                     session #'systemd-attach-session-invocation-id)
     :command (systemd-attach--safe-session-slot
               session #'systemd-attach-session-command)
     :default-directory (systemd-attach--safe-session-slot
                         session #'systemd-attach-session-default-directory)
     :working-directory (systemd-attach--safe-session-slot
                         session #'systemd-attach-session-working-directory)
     :remote (systemd-attach--safe-session-slot
              session #'systemd-attach-session-remote)
     :origin (systemd-attach--safe-session-slot
              session #'systemd-attach-session-origin)
     :created-at (systemd-attach--safe-session-slot
                  session #'systemd-attach-session-created-at)
     :state (systemd-attach--safe-session-slot
             session #'systemd-attach-session-state)
     :sub-state (systemd-attach--safe-session-slot
                 session #'systemd-attach-session-sub-state)
     :result (systemd-attach--safe-session-slot
              session #'systemd-attach-session-result)
     :exit-code (systemd-attach--safe-session-slot
                 session #'systemd-attach-session-exit-code)
     :refresh-error (systemd-attach--safe-session-slot
                     session #'systemd-attach-session-refresh-error)
     :output-backend (systemd-attach--safe-session-slot
                      session #'systemd-attach-session-output-backend)
     :log-file (systemd-attach--safe-session-slot
                session #'systemd-attach-session-log-file))))

(defun systemd-attach--load-sessions ()
  "Load session metadata if needed."
  (unless systemd-attach--sessions-loaded
    (setq systemd-attach--sessions
          (if (file-readable-p systemd-attach-session-file)
              (condition-case nil
                  (with-temp-buffer
                    (insert-file-contents systemd-attach-session-file)
                    (if (eobp)
                        nil
                      (let ((data (read (current-buffer))))
                        (if (listp data)
                            (mapcar #'systemd-attach--normalize-session data)
                          nil))))
                (error nil))
            nil))
    (setq systemd-attach--sessions-loaded t)))

(defun systemd-attach--save-sessions ()
  "Save session metadata."
  (make-directory (file-name-directory systemd-attach-session-file) t)
  (with-temp-file systemd-attach-session-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 systemd-attach--sessions (current-buffer))
      (insert "\n"))))

(defun systemd-attach--put-session (session)
  "Insert or replace SESSION in the metadata store."
  (setq session (systemd-attach--normalize-session session))
  (systemd-attach--load-sessions)
  (setq systemd-attach--sessions
        (cons session
              (cl-remove (systemd-attach-session-id session)
                         systemd-attach--sessions
                         :key #'systemd-attach-session-id
                         :test #'equal)))
  (systemd-attach--save-sessions)
  session)

(defun systemd-attach-sessions ()
  "Return known systemd-attach sessions, newest first."
  (systemd-attach--load-sessions)
  systemd-attach--sessions)

(defun systemd-attach--session-by-id (id)
  "Return the session with ID."
  (cl-find id (systemd-attach-sessions)
           :key #'systemd-attach-session-id
           :test #'equal))

(defun systemd-attach--session-summary (session)
  "Return a compact SESSION summary for completion."
  (format "%-10s %-18s %-12s %s"
          (or (systemd-attach-session-state session) "unknown")
          (or (systemd-attach-session-remote session) "local")
          (or (systemd-attach-session-origin session) "manual")
          (systemd-attach-session-command session)))

(defun systemd-attach--session-status (session)
  "Return a compact status string for SESSION."
  (let ((state (or (systemd-attach-session-state session) "unknown"))
        (sub-state (systemd-attach-session-sub-state session)))
    (if (and sub-state (not (string-empty-p sub-state)))
        (format "%s/%s" state sub-state)
      state)))

(defun systemd-attach--session-state-face (session)
  "Return a face for SESSION state."
  (let ((state (systemd-attach-session-state session))
        (result (systemd-attach-session-result session))
        (exit-code (systemd-attach-session-exit-code session)))
    (cond
     ((or (member state '("failed" "error"))
          (and exit-code (not (zerop exit-code)))
          (and result (not (member result '("" "success")))))
      'systemd-attach-state-failed)
     ((member state '("active" "activating" "reloading"))
      'systemd-attach-state-active)
     ((or (member state '("finished" "inactive"))
          (and exit-code (zerop exit-code)))
      'systemd-attach-state-success)
     (t 'systemd-attach-state-unknown))))

(defun systemd-attach--session-exit-string (session)
  "Return SESSION's exit code as a string."
  (if (numberp (systemd-attach-session-exit-code session))
      (number-to-string (systemd-attach-session-exit-code session))
    ""))

(defun systemd-attach--session-output-backend (session)
  "Return SESSION's output backend."
  (or (systemd-attach-session-output-backend session) 'journal))

(defun systemd-attach--session-log-file (session)
  "Return SESSION's target-local log file, deriving it when possible."
  (or (systemd-attach-session-log-file session)
      (and (eq (systemd-attach--session-output-backend session) 'file)
           (systemd-attach--file-log-file
            (systemd-attach-session-id session)
            (systemd-attach--session-directory session)))))

(defun systemd-attach--read-file-output (session &optional lines)
  "Read file-backed output for SESSION, optionally limited to LINES."
  (let ((log-file (or (systemd-attach--session-log-file session)
                      (error "Session has no file-backed log path"))))
    (systemd-attach--call-or-error
     systemd-attach-tail-program
     (if lines
         (list "-n" (number-to-string lines) log-file)
       (list "-n" "+1" log-file))
     (systemd-attach--session-directory session))))

(defun systemd-attach--read-output (session &optional lines)
  "Read SESSION output from its configured backend."
  (pcase (systemd-attach--session-output-backend session)
    ('file (systemd-attach--read-file-output session lines))
    (_ (systemd-attach--call-or-error
        systemd-attach-journalctl-program
        (systemd-attach--journal-args session nil lines)
        (systemd-attach--session-directory session)))))

(defun systemd-attach--session-needs-refresh-p (session)
  "Return non-nil if SESSION has a nonterminal cached state."
  (member (systemd-attach-session-state session)
          '(nil "starting" "activating" "active" "reloading"
                "deactivating" "stopping")))

(defun systemd-attach--session-terminal-p (session)
  "Return non-nil if SESSION is safe to treat as terminal."
  (or (numberp (systemd-attach-session-exit-code session))
      (member (systemd-attach-session-state session)
              systemd-attach-cleanup-terminal-states)))

(defun systemd-attach--same-target-p (left right)
  "Return non-nil if directories LEFT and RIGHT are on the same target."
  (equal (file-remote-p left) (file-remote-p right)))

(defun systemd-attach--unit-id (unit)
  "Return a session id derived from UNIT."
  (if (string-suffix-p ".service" unit)
      (substring unit 0 (- (length ".service")))
    unit))

(defun systemd-attach--unit-pattern ()
  "Return systemd unit glob for systemd-attach transient units."
  (format "%s-*.service" (systemd-attach--slug systemd-attach-unit-prefix)))

(defun systemd-attach--list-units-args ()
  "Return systemctl arguments for discovering systemd-attach units."
  (list "--user" "list-units" "--all" "--no-legend" "--no-pager"
        "--plain" (systemd-attach--unit-pattern)))

(defun systemd-attach--parse-unit-list (output)
  "Parse systemctl list-units OUTPUT and return unit names."
  (let (units)
    (dolist (line (split-string output "\n" t))
      (when (string-match "\\`\\s-*\\(?:●\\s-*\\)?\\([^[:space:]]+\\.service\\)\\b" line)
        (push (match-string 1 line) units)))
    (nreverse units)))

(defun systemd-attach--known-session-by-unit (unit directory)
  "Return a known session for UNIT on DIRECTORY's target, or nil."
  (cl-find-if
   (lambda (session)
     (and (equal (systemd-attach-session-unit session) unit)
          (systemd-attach--same-target-p
           (systemd-attach--session-directory session)
           directory)))
   (systemd-attach-sessions)))

(defun systemd-attach--known-target-sessions (directory)
  "Return known sessions for DIRECTORY's local or TRAMP target."
  (cl-remove-if-not
   (lambda (session)
     (systemd-attach--same-target-p
      (systemd-attach--session-directory session)
      directory))
   (systemd-attach-sessions)))

(defun systemd-attach--merge-sessions-by-unit (&rest session-lists)
  "Merge SESSION-LISTS, keeping the first session seen for each unit."
  (let ((seen (make-hash-table :test #'equal))
        merged)
    (dolist (sessions session-lists)
      (dolist (session sessions)
        (let ((unit (systemd-attach-session-unit session)))
          (unless (gethash unit seen)
            (puthash unit t seen)
            (push session merged)))))
    (nreverse merged)))

(defun systemd-attach--discovered-session (unit directory)
  "Return a minimal session for discovered UNIT at DIRECTORY."
  (let ((id (systemd-attach--unit-id unit)))
    (systemd-attach--make-session
     :id id
     :unit unit
     :command "<discovered>"
     :default-directory directory
     :working-directory (systemd-attach--working-directory directory)
     :remote (systemd-attach--remote-name directory)
     :origin "discovered"
     :created-at ""
     :state "unknown")))

(defun systemd-attach--apply-metadata (session metadata directory)
  "Apply journal METADATA to SESSION using DIRECTORY as target context."
  (when metadata
    (let ((id (systemd-attach--metadata-get metadata 'id))
          (unit (systemd-attach--metadata-get metadata 'unit))
          (command (systemd-attach--metadata-get metadata 'command))
          (working-directory
           (systemd-attach--metadata-get metadata 'working_directory))
          (origin (systemd-attach--metadata-get metadata 'origin))
          (created-at (systemd-attach--metadata-get metadata 'created_at))
          (output-backend
           (systemd-attach--metadata-get metadata 'output_backend))
          (log-file (systemd-attach--metadata-get metadata 'log_file)))
      (when (and id (stringp id))
        (setf (systemd-attach-session-id session) id))
      (when (and unit (stringp unit))
        (setf (systemd-attach-session-unit session) unit))
      (when (and command (stringp command))
        (setf (systemd-attach-session-command session) command))
      (when (and working-directory (stringp working-directory))
        (setf (systemd-attach-session-working-directory session)
              working-directory))
      (when (and origin (stringp origin))
        (setf (systemd-attach-session-origin session) origin))
      (when (and created-at (stringp created-at))
        (setf (systemd-attach-session-created-at session) created-at))
      (when (and output-backend (stringp output-backend))
        (setf (systemd-attach-session-output-backend session)
              (intern output-backend)))
      (when (and log-file (stringp log-file))
        (setf (systemd-attach-session-log-file session) log-file))
      (setf (systemd-attach-session-default-directory session)
            (or (systemd-attach-session-default-directory session)
                directory)
            (systemd-attach-session-remote session)
            (or (systemd-attach-session-remote session)
                (systemd-attach--remote-name directory)))))
  session)

(defun systemd-attach--discover-target-sessions (directory)
  "Discover systemd-attach sessions on DIRECTORY's local or TRAMP target."
  (pcase-let ((`(,exit-code . ,output)
               (systemd-attach--call systemd-attach-systemctl-program
                                     (systemd-attach--list-units-args)
                                     directory)))
    (unless (zerop exit-code)
      (error "%s failed with exit code %s: %s"
             systemd-attach-systemctl-program exit-code
             (string-trim output)))
    (let (sessions)
      (dolist (unit (systemd-attach--parse-unit-list output))
        (push (or (systemd-attach--known-session-by-unit unit directory)
                  (systemd-attach--discovered-session unit directory))
              sessions))
      (nreverse sessions))))

(defun systemd-attach--target-dashboard-sessions (directory)
  "Return dashboard sessions for DIRECTORY's target.
This combines currently loaded systemd units with saved local metadata for the
same target so completed collected jobs remain visible."
  (systemd-attach--merge-sessions-by-unit
   (systemd-attach--discover-target-sessions directory)
   (systemd-attach--known-target-sessions directory)))

(defun systemd-attach--truncate (string width)
  "Return STRING truncated to WIDTH characters."
  (truncate-string-to-width (or string "") width nil nil t))

(defun systemd-attach--read-session (&optional prompt)
  "Read and return a known session."
  (or systemd-attach-session
      (let* ((sessions (systemd-attach-sessions))
             (table (mapcar (lambda (session)
                              (cons (systemd-attach-session-id session) session))
                            sessions))
             (id (completing-read
                  (or prompt "Systemd-attach session: ")
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata
                          (annotation-function
                           . (lambda (candidate)
                               (let ((session (cdr (assoc candidate table))))
                                 (when session
                                   (concat " " (systemd-attach--session-summary session)))))))
                      (complete-with-action action table string pred)))
                  nil t)))
        (or (cdr (assoc id table))
            (error "Unknown session: %s" id)))))

(defun systemd-attach--buffer-name (session &optional suffix)
  "Return a buffer name for SESSION and optional SUFFIX."
  (format "*systemd-attach%s: %s*"
          (if suffix (concat "-" suffix) "")
          (systemd-attach-session-id session)))

(defun systemd-attach--insert-header (session)
  "Insert a metadata header for SESSION."
  (setq session (systemd-attach--normalize-session session))
  (dolist (row `(("Session" . ,(systemd-attach-session-id session))
                 ("Unit" . ,(systemd-attach-session-unit session))
                 ("Remote" . ,(or (systemd-attach-session-remote session)
                                  "local"))
                 ("Dir" . ,(systemd-attach-session-working-directory session))
                 ("State" . ,(format "%s/%s result=%s exit=%s"
                                      (or (systemd-attach-session-state session)
                                          "unknown")
                                      (or (systemd-attach-session-sub-state session)
                                          "unknown")
                                      (or (systemd-attach-session-result session)
                                          "unknown")
                                      (if (numberp (systemd-attach-session-exit-code session))
                                          (number-to-string
                                           (systemd-attach-session-exit-code session))
                                        "unknown")))
                 ("Backend" . ,(format "%s"
                                         (systemd-attach--session-output-backend
                                          session)))
                 ("Log" . ,(systemd-attach--session-log-file session))
                 ("Refresh" . ,(or (systemd-attach-session-refresh-error session)
                                    "ok"))
                 ("Command" . ,(systemd-attach-session-command session))))
    (insert (propertize (format "%-8s" (concat (car row) ":"))
                        'face 'systemd-attach-header-label))
    (insert " ")
    (insert (propertize (or (cdr row) "") 'face 'systemd-attach-header-value))
    (insert "\n"))
  (insert "\n"))

(defun systemd-attach--replace-header (session)
  "Replace the current buffer header with SESSION metadata."
  (let ((inhibit-read-only t)
        (end (or (and (markerp systemd-attach--content-start-marker)
                      (marker-position systemd-attach--content-start-marker))
                 (point-min))))
    (save-excursion
      (goto-char (point-min))
      (delete-region (point-min) end)
      (systemd-attach--insert-header session)
      (setq systemd-attach--content-start-marker (copy-marker (point) nil)))))

(defun systemd-attach--refresh-session-buffer-header (buffer)
  "Refresh systemd-attach header in BUFFER.
Return the refreshed session, or nil if BUFFER is not a session buffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when systemd-attach-session
        (setq systemd-attach-session
              (systemd-attach--normalize-session systemd-attach-session))
        (condition-case err
            (systemd-attach-refresh-session systemd-attach-session)
          (error
           (setf (systemd-attach-session-refresh-error systemd-attach-session)
                 (error-message-string err))))
        (systemd-attach--replace-header systemd-attach-session)
        systemd-attach-session))))

(defun systemd-attach--visible-session-buffers (session)
  "Return live buffers displaying SESSION."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (and systemd-attach-session
            (equal (systemd-attach-session-id systemd-attach-session)
                   (systemd-attach-session-id session)))))
   (buffer-list)))

(defun systemd-attach--schedule-visible-refresh (session &optional attempt)
  "Schedule a delayed refresh for visible buffers displaying SESSION.
ATTEMPT is the current zero-based polling attempt."
  (when systemd-attach-start-refresh-delay
    (run-at-time
     systemd-attach-start-refresh-delay nil
     (lambda (session attempt)
       (let ((refreshed nil))
         (dolist (buffer (systemd-attach--visible-session-buffers session))
           (when-let ((buffer-session
                       (systemd-attach--refresh-session-buffer-header buffer)))
             (setq refreshed buffer-session)))
         (when (and refreshed
                    (systemd-attach--session-needs-refresh-p refreshed)
                    (not (systemd-attach-session-refresh-error refreshed))
                    (< (1+ attempt)
                       systemd-attach-visible-refresh-max-attempts))
           (systemd-attach--schedule-visible-refresh refreshed (1+ attempt)))))
     session
     (or attempt 0))))

;;;###autoload
(defun systemd-attach-start (command &optional origin)
  "Start COMMAND as a durable noninteractive systemd user service.
ORIGIN is a short symbol or string describing the caller."
  (interactive (list (read-shell-command "Systemd-attach command: ")))
  (let* ((directory default-directory)
         (id (systemd-attach--generate-id))
         (unit (systemd-attach--unit-name id))
         (working-directory (systemd-attach--working-directory directory))
         (output-backend systemd-attach-output-backend)
         (log-file (and (eq output-backend 'file)
                        (systemd-attach--file-log-file id directory)))
         (args (progn
                 (unless (memq output-backend '(journal file))
                   (error "Unknown systemd-attach output backend: %S"
                          output-backend))
                 (when log-file
                   (systemd-attach--ensure-file-log-directory directory))
                 (systemd-attach--systemd-run-args
                  id unit working-directory command
                  systemd-attach-use-json-output origin
                  output-backend log-file)))
         (output (systemd-attach--start-call args directory))
         (parsed (systemd-attach--parse-run-output output))
         (actual-unit (or (car parsed) unit))
         (session (systemd-attach--make-session
                   :id id
                   :unit actual-unit
                   :invocation-id (cdr parsed)
                   :command command
                   :default-directory directory
                   :working-directory working-directory
                   :remote (systemd-attach--remote-name directory)
                   :origin (if origin (format "%s" origin) "manual")
                   :created-at (systemd-attach--now-string)
                   :state "starting"
                   :output-backend output-backend
                   :log-file log-file)))
    (systemd-attach--put-session session)
    (message "Started %s as %s" id actual-unit)
    (pcase systemd-attach-open-after-start
      ('view (systemd-attach-view-session session))
      ('follow (systemd-attach-follow-session session)))
    (systemd-attach--schedule-visible-refresh session)
    session))

;;;###autoload
(defun systemd-attach-shell-command (command)
  "Read COMMAND and start it with `systemd-attach-start'."
  (interactive (list (read-shell-command "Systemd-attach shell command: ")))
  (systemd-attach-start command 'shell-command))

(defun systemd-attach--shell-quote-remote-file (file)
  "Return FILE shell-quoted for the target host."
  (shell-quote-argument
   (or (and (file-remote-p file)
            (file-remote-p file 'localname))
       file)))

(defun systemd-attach--dired-directory ()
  "Return the current Dired directory."
  (unless (derived-mode-p 'dired-mode)
    (error "Not in a Dired buffer"))
  (file-name-as-directory
   (expand-file-name
    (if (consp dired-directory)
        (car dired-directory)
      dired-directory))))

(defun systemd-attach--dired-marked-files ()
  "Return marked Dired files, excluding directories."
  (require 'dired)
  (dired-get-marked-files nil nil #'file-regular-p))

;;;###autoload
(defun systemd-attach-dired-command (command)
  "Start COMMAND in the current Dired directory."
  (interactive (list (read-shell-command "Systemd-attach Dired command: ")))
  (let ((default-directory (systemd-attach--dired-directory)))
    (systemd-attach-start command 'dired)))

;;;###autoload
(defun systemd-attach-dired-command-with-marked-files (command)
  "Start COMMAND with marked Dired files appended as shell arguments.
The command runs in the current Dired directory.  File arguments use
target-local paths for TRAMP buffers."
  (interactive
   (list (read-shell-command "Systemd-attach Dired command for marked files: ")))
  (let* ((default-directory (systemd-attach--dired-directory))
         (files (systemd-attach--dired-marked-files)))
    (unless files
      (error "No marked files"))
    (systemd-attach-start
     (string-join
      (cons command (mapcar #'systemd-attach--shell-quote-remote-file files))
      " ")
     'dired)))

;;;###autoload
(defun systemd-attach-dired-do-shell-command (command &optional arg file-list)
  "Run Dired shell COMMAND on marked files through systemd-attach.
This reuses Dired's own command reader and expansion semantics: whitespace
surrounded `*' is replaced by the full marked file list, `?' runs once per file,
and otherwise Dired appends file names using its normal shell quoting rules."
  (interactive
   (let ((files (dired-get-marked-files t current-prefix-arg nil nil t)))
     (list (dired-read-shell-command "Systemd-attach on %s: "
                                     current-prefix-arg files)
           current-prefix-arg
           files))
   dired-mode)
  (let ((default-directory (systemd-attach--dired-directory)))
    (cl-letf (((symbol-function 'dired-run-shell-command)
               (lambda (expanded-command)
                 (systemd-attach-start expanded-command 'dired)
                 nil)))
      (dired-do-shell-command command arg file-list))))

;;;###autoload
(defun systemd-attach-refresh-session (&optional session)
  "Refresh and return SESSION state from systemctl and recent journal output."
  (interactive)
  (let* ((session (or session (systemd-attach--read-session)))
         (directory (systemd-attach--session-directory session))
         (state-output (systemd-attach--call
                        systemd-attach-systemctl-program
                        (systemd-attach--systemctl-show-args session)
                        directory))
         (session-output (condition-case nil
                             (systemd-attach--read-output session 80)
                           (error ""))))
    (when-let ((metadata (systemd-attach--extract-metadata session-output)))
      (systemd-attach--apply-metadata session metadata directory))
    (if (zerop (car state-output))
        (let* ((props (systemd-attach--parse-properties (cdr state-output)))
               (active (cdr (assoc "ActiveState" props)))
               (sub (cdr (assoc "SubState" props)))
               (result (cdr (assoc "Result" props)))
               (status (cdr (assoc "ExecMainStatus" props))))
          (setf (systemd-attach-session-state session) active
                (systemd-attach-session-sub-state session) sub
                (systemd-attach-session-result session) result
                (systemd-attach-session-refresh-error session) nil)
          (when (and status (string-match-p "\\`[0-9]+\\'" status))
            (setf (systemd-attach-session-exit-code session)
                  (string-to-number status))))
      (setf (systemd-attach-session-state session) "unknown"
            (systemd-attach-session-sub-state session) "unloaded"
            (systemd-attach-session-refresh-error session)
            (string-trim (cdr state-output))))
    (when-let ((exit-code (systemd-attach--extract-exit-code session-output)))
      (setf (systemd-attach-session-exit-code session) exit-code)
      (when (member (systemd-attach-session-state session) '("unknown" nil))
        (setf (systemd-attach-session-state session)
              (if (zerop exit-code) "finished" "failed")))
      (setf (systemd-attach-session-refresh-error session) nil))
    (systemd-attach--put-session session)
    (when (called-interactively-p 'interactive)
      (message "%s: %s/%s exit=%s"
               (systemd-attach-session-id session)
               (or (systemd-attach-session-state session) "unknown")
               (or (systemd-attach-session-sub-state session) "unknown")
               (or (systemd-attach-session-exit-code session) "unknown")))
    session))

;;;###autoload
(defun systemd-attach-open-session ()
  "Read a known session and view its output."
  (interactive)
  (systemd-attach-view-session (systemd-attach--read-session)))

(defun systemd-attach--dashboard-known-sessions ()
  "Return sessions displayed in the current dashboard."
  (or systemd-attach-dashboard-sessions
      (systemd-attach-sessions)))

(defun systemd-attach--dashboard-session-by-id (id)
  "Return displayed dashboard session with ID."
  (cl-find id (systemd-attach--dashboard-known-sessions)
           :key #'systemd-attach-session-id
           :test #'equal))

(defun systemd-attach--dashboard-session-at-point ()
  "Return the dashboard session at point."
  (let ((id (tabulated-list-get-id)))
    (or (and id (systemd-attach--dashboard-session-by-id id))
        (error "No systemd-attach session at point"))))

(defun systemd-attach--dashboard-entries (sessions)
  "Return `tabulated-list-entries' for SESSIONS."
  (mapcar
   (lambda (session)
     (let ((id (systemd-attach-session-id session)))
       (list id
             (vector
              (propertize (systemd-attach--session-status session)
                          'face (systemd-attach--session-state-face session))
              (or (systemd-attach-session-remote session) "local")
              (or (systemd-attach-session-origin session) "manual")
              (systemd-attach--session-exit-string session)
              (or (systemd-attach-session-created-at session) "")
              (systemd-attach--truncate
               (systemd-attach-session-working-directory session) 32)
              (systemd-attach--truncate
               (systemd-attach-session-command session) 80)))))
   sessions))

(defun systemd-attach--refresh-sessions (sessions &optional refresh-state)
  "Refresh SESSIONS according to REFRESH-STATE and return them."
  (dolist (session sessions)
    (when (or refresh-state
              (systemd-attach--session-needs-refresh-p session))
      (condition-case err
          (systemd-attach-refresh-session session)
        (error
         (setf (systemd-attach-session-state session) "error"
               (systemd-attach-session-sub-state session)
               (error-message-string err)
               (systemd-attach-session-refresh-error session)
               (error-message-string err))
         (when (systemd-attach--session-by-id
                (systemd-attach-session-id session))
           (systemd-attach--put-session session))))))
  sessions)

(defun systemd-attach--mark-refresh-error (sessions message)
  "Mark SESSIONS with refresh error MESSAGE and return them."
  (dolist (session sessions)
    (setf (systemd-attach-session-state session) "error"
          (systemd-attach-session-sub-state session) message
          (systemd-attach-session-refresh-error session) message))
  sessions)

(defun systemd-attach-dashboard-refresh (&optional refresh-state)
  "Refresh the dashboard.
With REFRESH-STATE, force state refresh for every row."
  (interactive "P")
  (setq systemd-attach-dashboard-sessions
        (pcase systemd-attach-dashboard-scope
          ('known (systemd-attach--refresh-sessions
                   (systemd-attach-sessions) refresh-state))
          (_ (let ((directory (or systemd-attach-dashboard-directory
                                  default-directory)))
               (condition-case err
                   (systemd-attach--refresh-sessions
                    (systemd-attach--target-dashboard-sessions directory)
                    (or refresh-state t))
                 (error
                  (message "systemd-attach dashboard refresh failed: %s"
                           (error-message-string err))
                  (systemd-attach--mark-refresh-error
                   (systemd-attach--known-target-sessions directory)
                   (error-message-string err))))))))
  (setq tabulated-list-entries
        (systemd-attach--dashboard-entries
         systemd-attach-dashboard-sessions))
  (tabulated-list-print t))

(defun systemd-attach-dashboard-view ()
  "View output for the dashboard session at point."
  (interactive)
  (systemd-attach-view-session (systemd-attach--dashboard-session-at-point)))

(defun systemd-attach-dashboard-follow ()
  "Follow output for the dashboard session at point."
  (interactive)
  (systemd-attach-follow-session (systemd-attach--dashboard-session-at-point)))

(defun systemd-attach-dashboard-kill ()
  "Stop the dashboard session at point."
  (interactive)
  (systemd-attach-kill-session (systemd-attach--dashboard-session-at-point))
  (systemd-attach-dashboard-refresh))

(defun systemd-attach-dashboard-rerun ()
  "Rerun the dashboard session at point."
  (interactive)
  (systemd-attach-rerun-session (systemd-attach--dashboard-session-at-point))
  (systemd-attach-dashboard-refresh))

(defun systemd-attach-dashboard-delete ()
  "Delete local metadata for the dashboard session at point."
  (interactive)
  (systemd-attach-delete-session (systemd-attach--dashboard-session-at-point))
  (systemd-attach-dashboard-refresh))

(defvar systemd-attach--last-log-cleanup-errors nil)

(defun systemd-attach--session-log-file-name (session)
  "Return SESSION's log file as an Emacs file name for its target."
  (when-let ((log-file (systemd-attach--session-log-file session)))
    (let ((directory (systemd-attach--session-directory session)))
      (cond
       ((file-remote-p log-file) log-file)
       ((file-name-absolute-p log-file)
        (concat (or (file-remote-p directory) "") log-file))
       (t (expand-file-name log-file directory))))))

(defun systemd-attach--delete-session-log-file (session)
  "Delete SESSION's exact file-backed log file if configured.
Return nil on success or a human-readable error string on failure."
  (when (and systemd-attach-delete-file-logs-on-cleanup
             (eq (systemd-attach--session-output-backend session) 'file))
    (condition-case err
        (when-let ((log-file (systemd-attach--session-log-file-name session)))
          (when (file-exists-p log-file)
            (delete-file log-file)))
      (error
       (format "%s: %s"
               (systemd-attach-session-id session)
               (error-message-string err))))))

(defun systemd-attach--cleanup-sessions (predicate)
  "Delete local metadata for sessions matching PREDICATE.
Return the number of deleted sessions.  If file-log deletion fails, details are
stored in `systemd-attach--last-log-cleanup-errors'."
  (systemd-attach--load-sessions)
  (let* ((removed (cl-remove-if-not predicate systemd-attach--sessions))
         (kept (cl-remove-if predicate systemd-attach--sessions)))
    (setq systemd-attach--last-log-cleanup-errors
          (delq nil (mapcar #'systemd-attach--delete-session-log-file removed)))
    (setq systemd-attach--sessions kept)
    (systemd-attach--save-sessions)
    (length removed)))

(defun systemd-attach--cleanup-message (count scope all)
  "Report that COUNT sessions were cleaned up from SCOPE.
ALL non-nil means the cleanup removed all metadata in scope, not just terminal
sessions."
  (let ((message-text
         (format "Deleted %s %s session metadata entr%s from %s"
                 count
                 (if all "total" "terminal")
                 (if (= count 1) "y" "ies")
                 scope)))
    (if systemd-attach--last-log-cleanup-errors
        (message "%s; %s log deletion error%s: %s"
                 message-text
                 (length systemd-attach--last-log-cleanup-errors)
                 (if (= (length systemd-attach--last-log-cleanup-errors) 1)
                     ""
                   "s")
                 (string-join systemd-attach--last-log-cleanup-errors "; "))
      (message "%s" message-text))))

;;;###autoload
(defun systemd-attach-cleanup-sessions (&optional all)
  "Delete old local metadata for the current target.
By default this removes only terminal sessions, as defined by
`systemd-attach-cleanup-terminal-states' or sessions with a recorded exit code.
With prefix argument ALL, delete all local metadata for the current target.
This never stops systemd units and never removes journal history.  When
`systemd-attach-delete-file-logs-on-cleanup' is non-nil, exact file-backed logs
for removed sessions are deleted too."
  (interactive "P")
  (let ((directory default-directory))
    (when (or (not all)
              (yes-or-no-p
               (format "Delete all systemd-attach metadata for %s? "
                       (or (file-remote-p directory) "local"))))
      (systemd-attach--cleanup-message
       (systemd-attach--cleanup-sessions
        (lambda (session)
          (and (systemd-attach--same-target-p
                (systemd-attach--session-directory session)
                directory)
               (or all (systemd-attach--session-terminal-p session)))))
       (or (file-remote-p directory) "local")
       all))))

;;;###autoload
(defun systemd-attach-cleanup-known-sessions (&optional all)
  "Delete old local metadata across all known targets.
By default this removes only terminal sessions.  With prefix argument ALL,
delete every locally known metadata entry after confirmation.  This never stops
systemd units and never removes journal history.  When
`systemd-attach-delete-file-logs-on-cleanup' is non-nil, exact file-backed logs
for removed sessions are deleted too."
  (interactive "P")
  (when (or (not all)
            (yes-or-no-p "Delete all locally known systemd-attach metadata? "))
    (systemd-attach--cleanup-message
     (systemd-attach--cleanup-sessions
      (lambda (session)
        (or all (systemd-attach--session-terminal-p session))))
     "all known targets"
     all)))

(defun systemd-attach-dashboard-cleanup (&optional all)
  "Clean up local metadata for the current dashboard scope.
Without prefix argument ALL, delete terminal sessions only.  With ALL, delete
all local metadata in the current dashboard scope after confirmation."
  (interactive "P")
  (pcase systemd-attach-dashboard-scope
    ('known (systemd-attach-cleanup-known-sessions all))
    (_ (let ((default-directory (or systemd-attach-dashboard-directory
                                    default-directory)))
         (systemd-attach-cleanup-sessions all))))
  (systemd-attach-dashboard-refresh))

(defvar systemd-attach-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'systemd-attach-dashboard-view)
    (define-key map (kbd "v") #'systemd-attach-dashboard-view)
    (define-key map (kbd "f") #'systemd-attach-dashboard-follow)
    (define-key map (kbd "g") #'systemd-attach-dashboard-refresh)
    (define-key map (kbd "r") #'systemd-attach-dashboard-refresh)
    (define-key map (kbd "R") (lambda ()
                                (interactive)
                                (systemd-attach-dashboard-refresh t)))
    (define-key map (kbd "k") #'systemd-attach-dashboard-kill)
    (define-key map (kbd "!") #'systemd-attach-dashboard-rerun)
    (define-key map (kbd "d") #'systemd-attach-dashboard-delete)
    (define-key map (kbd "x") #'systemd-attach-dashboard-cleanup)
    map))

(define-derived-mode systemd-attach-dashboard-mode tabulated-list-mode
  "Systemd-Attach"
  "Major mode for browsing systemd-attach sessions."
  (setq tabulated-list-format
        [("State" 22 t)
         ("Host" 18 t)
         ("Origin" 12 t)
         ("Exit" 6 t)
         ("Created" 22 t)
         ("Directory" 34 t)
         ("Command" 0 t)])
  (setq header-line-format
        '(:eval
          (format "Scope: %s  Target: %s"
                  systemd-attach-dashboard-scope
                  (or systemd-attach-dashboard-directory "all known"))))
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Created" . t))
  (add-hook 'tabulated-list-revert-hook
            #'systemd-attach-dashboard-refresh nil t)
  (tabulated-list-init-header))

(defun systemd-attach--dashboard-prefix-key (key)
  "Return dashboard Evil prefix binding for KEY."
  (kbd (string-join (list systemd-attach-dashboard-evil-prefix key) " ")))

(defun systemd-attach--evil-prefix-key (prefix key)
  "Return Evil prefixed key using PREFIX and KEY."
  (kbd (string-join (list prefix key) " ")))

(defun systemd-attach--evil-define-key (state keymap-symbol &rest bindings)
  "Define Evil BINDINGS for STATE in KEYMAP-SYMBOL.
This avoids compile-time Evil macro expansion while still passing a keymap
symbol, not an evaluated keymap object, to `evil-define-key'."
  (when (and (symbolp keymap-symbol)
             (fboundp 'evil-define-key))
    (eval
     (append (list 'evil-define-key
                   (list 'quote state)
                   keymap-symbol)
             (mapcar (lambda (binding) (list 'quote binding))
                     bindings)))))

(defun systemd-attach--dashboard-evil-define-keys ()
  "Define optional Evil normal-state dashboard keys."
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'systemd-attach-dashboard-mode 'normal))
  (systemd-attach--evil-define-key
   'normal 'systemd-attach-dashboard-mode-map
   (kbd "RET") #'systemd-attach-dashboard-view)
  (when systemd-attach-dashboard-evil-prefix
    (systemd-attach--evil-define-key
     'normal 'systemd-attach-dashboard-mode-map
     (systemd-attach--dashboard-prefix-key "RET")
     #'systemd-attach-dashboard-view
     (systemd-attach--dashboard-prefix-key "v")
     #'systemd-attach-dashboard-view
     (systemd-attach--dashboard-prefix-key "f")
     #'systemd-attach-dashboard-follow
     (systemd-attach--dashboard-prefix-key "g")
     #'systemd-attach-dashboard-refresh
     (systemd-attach--dashboard-prefix-key "r")
     #'systemd-attach-dashboard-refresh
     (systemd-attach--dashboard-prefix-key "R")
     (lambda ()
       (interactive)
       (systemd-attach-dashboard-refresh t))
     (systemd-attach--dashboard-prefix-key "k")
     #'systemd-attach-dashboard-kill
     (systemd-attach--dashboard-prefix-key "!")
     #'systemd-attach-dashboard-rerun
     (systemd-attach--dashboard-prefix-key "d")
     #'systemd-attach-dashboard-delete
     (systemd-attach--dashboard-prefix-key "x")
     #'systemd-attach-dashboard-cleanup)))

(defun systemd-attach--dired-evil-define-keys ()
  "Define optional Evil normal-state Dired keys."
  (when (and systemd-attach-dired-evil-prefix
             (boundp 'dired-mode-map))
    (systemd-attach--evil-define-key
     'normal 'dired-mode-map
     (systemd-attach--evil-prefix-key systemd-attach-dired-evil-prefix "&")
     #'systemd-attach-dired-do-shell-command
     (systemd-attach--evil-prefix-key systemd-attach-dired-evil-prefix "c")
     #'systemd-attach-dired-command
     (systemd-attach--evil-prefix-key systemd-attach-dired-evil-prefix "m")
     #'systemd-attach-dired-command-with-marked-files)))

(with-eval-after-load 'evil
  (systemd-attach--dashboard-evil-define-keys)
  (systemd-attach--dired-evil-define-keys))

(with-eval-after-load 'dired
  (when systemd-attach-dired-prefix-key
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "&") #'systemd-attach-dired-do-shell-command)
      (define-key map (kbd "c") #'systemd-attach-dired-command)
      (define-key map (kbd "m")
                  #'systemd-attach-dired-command-with-marked-files)
      (define-key dired-mode-map systemd-attach-dired-prefix-key map)))
  (systemd-attach--dired-evil-define-keys))

;;;###autoload
(defun systemd-attach-dashboard (&optional refresh-state)
  "Show the systemd-attach dashboard for the current target.
The target is the local or TRAMP host from the current `default-directory'.
With prefix argument REFRESH-STATE, force-refresh every displayed row."
  (interactive "P")
  (let ((target-directory default-directory)
        (buffer (get-buffer-create systemd-attach-dashboard-buffer-name)))
    (with-current-buffer buffer
      (systemd-attach-dashboard-mode)
      (setq systemd-attach-dashboard-scope 'target
            systemd-attach-dashboard-directory target-directory)
      (systemd-attach-dashboard-refresh refresh-state))
    (pop-to-buffer buffer)))

;;;###autoload
(defun systemd-attach-dashboard-known (&optional refresh-state)
  "Show all locally known systemd-attach sessions.
With prefix argument REFRESH-STATE, force-refresh every displayed row."
  (interactive "P")
  (let ((buffer (get-buffer-create systemd-attach-dashboard-known-buffer-name)))
    (with-current-buffer buffer
      (systemd-attach-dashboard-mode)
      (setq systemd-attach-dashboard-scope 'known
            systemd-attach-dashboard-directory nil)
      (systemd-attach-dashboard-refresh refresh-state))
    (pop-to-buffer buffer)))

;;;###autoload
(defun systemd-attach-view-session (&optional session lines compilation)
  "View SESSION output.
Optional LINES limits output to the last LINES entries.  With interactive prefix
argument, use `compilation-mode'."
  (interactive
   (list (systemd-attach--read-session)
         systemd-attach-default-tail-lines
         current-prefix-arg))
  (let* ((session (or session (systemd-attach--read-session)))
         (lines (or lines systemd-attach-default-tail-lines))
         (buffer (get-buffer-create (systemd-attach--buffer-name session)))
         (inhibit-read-only t)
         (output (systemd-attach--read-output session lines)))
    (condition-case nil
        (systemd-attach-refresh-session session)
      (error nil))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (setq systemd-attach-session session)
      (systemd-attach--insert-header session)
      (setq systemd-attach--content-start-marker (copy-marker (point) nil))
      (let ((start (point)))
        (insert (systemd-attach--display-output output))
        (ansi-color-apply-on-region start (point)))
      (goto-char (point-min))
      (if compilation
          (progn
            (require 'compile)
            (compilation-mode))
        (special-mode))
      (setq buffer-read-only t))
    (pop-to-buffer buffer)))

;;;###autoload
(defun systemd-attach-view-session-compilation (&optional session lines)
  "View SESSION output in `compilation-mode'."
  (interactive (list (systemd-attach--read-session)
                     systemd-attach-default-tail-lines))
  (systemd-attach-view-session session lines t))

(defun systemd-attach--follow-filter (process string)
  "Insert PROCESS output STRING into its buffer."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t)
            (moving (= (point) (process-mark process))))
        (save-excursion
          (goto-char (process-mark process))
          (let ((start (point)))
            (insert (systemd-attach--display-output string))
            (ansi-color-apply-on-region start (point)))
          (set-marker (process-mark process) (point)))
        (when moving
          (goto-char (process-mark process)))))))

;;;###autoload
(defun systemd-attach-follow-session (&optional session lines)
  "Follow SESSION output."
  (interactive (list (systemd-attach--read-session)
                     systemd-attach-default-tail-lines))
  (let* ((session (or session (systemd-attach--read-session)))
         (buffer (get-buffer-create (systemd-attach--buffer-name session "follow")))
         (output-backend (systemd-attach--session-output-backend session))
         (program (if (eq output-backend 'file)
                      systemd-attach-tail-program
                    systemd-attach-journalctl-program))
         (args (if (eq output-backend 'file)
                   (list "-n" (number-to-string
                                (or lines systemd-attach-default-tail-lines))
                         "-f" (or (systemd-attach--session-log-file session)
                                    (error "Session has no file-backed log path")))
                 (systemd-attach--journal-args session t lines)))
         (default-directory (systemd-attach--session-directory session)))
    (when-let ((old-process (get-buffer-process buffer)))
      (when (process-live-p old-process)
        (delete-process old-process)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (setq systemd-attach-session session)
      (systemd-attach--insert-header session)
      (setq systemd-attach--content-start-marker (copy-marker (point) nil))
      (special-mode)
      (setq buffer-read-only t))
    (let ((process (apply #'start-file-process
                          (format "systemd-attach-follow-%s"
                                  (systemd-attach-session-id session))
                          buffer
                          program
                          args)))
      (set-process-filter process #'systemd-attach--follow-filter)
      (set-process-sentinel
       process
       (lambda (process _event)
         (unless (process-live-p process)
           (systemd-attach--refresh-session-buffer-header
            (process-buffer process)))))
      (set-process-query-on-exit-flag process nil)
      (with-current-buffer buffer
        (set-marker (process-mark process) (point-max))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun systemd-attach-kill-session (&optional session)
  "Stop SESSION's transient systemd unit."
  (interactive)
  (let* ((session (or session (systemd-attach--read-session)))
         (output (systemd-attach--call-or-error
                  systemd-attach-systemctl-program
                  (list "--user" "stop" (systemd-attach-session-unit session))
                  (systemd-attach--session-directory session))))
    (setf (systemd-attach-session-state session) "stopping")
    (systemd-attach--put-session session)
    (message "Stopped %s%s"
             (systemd-attach-session-id session)
             (if (string-empty-p (string-trim output))
                 ""
               (concat ": " (string-trim output))))))

;;;###autoload
(defun systemd-attach-rerun-session (&optional session)
  "Start a new session using SESSION's command and directory."
  (interactive)
  (let ((session (or session (systemd-attach--read-session))))
    (when (equal (systemd-attach-session-command session) "<discovered>")
      (error "Cannot rerun discovered session without saved command metadata"))
    (let ((default-directory (systemd-attach--session-directory session)))
      (systemd-attach-start (systemd-attach-session-command session) 'rerun))))

;;;###autoload
(defun systemd-attach-delete-session (&optional session)
  "Delete SESSION from local metadata.
This does not remove journal history and does not stop active units."
  (interactive)
  (let ((session (or session (systemd-attach--read-session))))
    (systemd-attach--load-sessions)
    (setq systemd-attach--sessions
          (cl-remove (systemd-attach-session-id session)
                     systemd-attach--sessions
                     :key #'systemd-attach-session-id
                     :test #'equal))
    (systemd-attach--save-sessions)
    (message "Deleted metadata for %s" (systemd-attach-session-id session))))

;;;###autoload
(defun systemd-attach-copy-command (&optional session)
  "Copy SESSION's original command to the kill ring."
  (interactive)
  (let ((session (or session (systemd-attach--read-session))))
    (kill-new (systemd-attach-session-command session))
    (message "Copied command for %s" (systemd-attach-session-id session))))

;;;###autoload
(defun systemd-attach-copy-output (&optional session lines)
  "Copy recent SESSION output to the kill ring.
With interactive prefix argument, prompt for LINES."
  (interactive
   (list (systemd-attach--read-session)
         (if current-prefix-arg
             (read-number "Output lines: " systemd-attach-default-tail-lines)
           systemd-attach-default-tail-lines)))
  (let* ((session (or session (systemd-attach--read-session)))
         (output (systemd-attach--read-output session lines)))
    (kill-new (systemd-attach--display-output output))
    (message "Copied output for %s" (systemd-attach-session-id session))))

(defun systemd-attach--org-param-enabled-p (params)
  "Return non-nil if PARAMS request systemd-attach execution."
  (let ((value (cdr (assq :systemd-attach params))))
    (and value
         (not (member (format "%s" value) '("nil" "no" "false" "0"))))))

(defun systemd-attach--org-shell-command (body params)
  "Build a shell command from Org Babel BODY and PARAMS."
  (let ((cmdline (cdr (assq :cmdline params))))
    (string-join (delq nil (list body cmdline)) " ")))

(defun systemd-attach--org-babel-execute-shell (orig-fun body params)
  "Advice ORIG-FUN to run BODY with systemd-attach when PARAMS request it."
  (if (systemd-attach--org-param-enabled-p params)
      (let ((session (systemd-attach-start
                      (systemd-attach--org-shell-command body params)
                      'org-babel)))
        (format "[systemd-attach: %s]" (systemd-attach-session-id session)))
    (funcall orig-fun body params)))

(with-eval-after-load 'ob-shell
  (advice-add 'org-babel-execute:shell
              :around #'systemd-attach--org-babel-execute-shell))

(provide 'systemd-attach)

;;; systemd-attach.el ends here
