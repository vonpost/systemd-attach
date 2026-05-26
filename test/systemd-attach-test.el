;;; systemd-attach-test.el --- Tests for systemd-attach -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'systemd-attach)

(ert-deftest systemd-attach-unit-name-is-service ()
  (should (equal (systemd-attach--unit-name "systemd-attach-abc")
                 "systemd-attach-abc.service"))
  (should (equal (systemd-attach--unit-name "bad unit!")
                 "bad-unit.service")))

(ert-deftest systemd-attach-working-directory-local ()
  (should (equal (systemd-attach--working-directory "/tmp/example/")
                 "/tmp/example")))

(ert-deftest systemd-attach-working-directory-tramp ()
  (should (equal (systemd-attach--working-directory "/ssh:host:/var/tmp/project/")
                 "/var/tmp/project")))

(ert-deftest systemd-attach-target-matching-is-not-ssh-specific ()
  (let* ((directory "/sudo:root@host:/tmp/project/")
         (session (systemd-attach--make-session
                   :id "known"
                   :unit "systemd-attach-known.service"
                   :command "echo known"
                   :default-directory directory
                   :working-directory "/tmp/project"
                   :remote "host"))
         (systemd-attach--sessions (list session))
         (systemd-attach--sessions-loaded t))
    (should (eq (systemd-attach--known-session-by-unit
                 "systemd-attach-known.service"
                 "/sudo:root@host:/other/")
                session))
    (should-not (systemd-attach--known-session-by-unit
                 "systemd-attach-known.service"
                 "/ssh:root@host:/tmp/project/"))))

(ert-deftest systemd-attach-run-args-are-noninteractive ()
  (let* ((systemd-attach-default-properties
          '("StandardInput=null" "StandardOutput=journal"))
         (args (systemd-attach--systemd-run-args
                "systemd-attach-test"
                "systemd-attach-test.service"
                "/tmp"
                "echo hello"
                t
                'test)))
    (should (member "--no-block" args))
    (should (member "--collect" args))
    (should (member "--json=short" args))
    (should (member "StandardInput=null" args))
    (should (member "StandardOutput=journal" args))
    (should (equal (car (last args 3)) "/bin/sh"))
    (should (equal (cadr (last args 3)) "-lc"))
    (should (string-match-p "echo hello" (car (last args))))
    (should (string-match-p "\\[systemd-attach metadata: " (car (last args))))
    (should (string-match-p "\\[systemd-attach exit status: %s\\]"
                            (car (last args))))))

(ert-deftest systemd-attach-journal-args-do-not-filter-invocation ()
  (let ((session (systemd-attach--make-session
                  :id "id"
                  :unit "id.service"
                  :invocation-id "deadbeef")))
    (should (equal (systemd-attach--journal-args session nil 10)
                   '("--user-unit" "id.service"
                     "--output" "cat"
                     "--no-pager"
                     "--lines" "10")))))

(ert-deftest systemd-attach-metadata-roundtrip ()
  (let* ((metadata-json
          (systemd-attach--metadata-json
           "id" "id.service" "/tmp/project" "echo 'hi'" "test"))
         (output (concat "noise\n"
                         systemd-attach--metadata-marker-prefix
                         metadata-json "]\n"
                         "more\n"))
         (metadata (systemd-attach--extract-metadata output)))
    (should (equal (systemd-attach--metadata-get metadata 'id) "id"))
    (should (equal (systemd-attach--metadata-get metadata 'unit)
                   "id.service"))
    (should (equal (systemd-attach--metadata-get metadata 'command)
                   "echo 'hi'"))
    (should (equal (systemd-attach--metadata-get metadata 'working_directory)
                   "/tmp/project"))
    (should (equal (systemd-attach--metadata-get metadata 'origin)
                   "test"))))

(ert-deftest systemd-attach-quotes-tramp-file-for-target ()
  (should (equal (systemd-attach--shell-quote-remote-file
                  "/ssh:host:/tmp/a file.txt")
                 "/tmp/a\\ file.txt"))
  (should (equal (systemd-attach--shell-quote-remote-file
                  "/tmp/a file.txt")
                 "/tmp/a\\ file.txt")))

(ert-deftest systemd-attach-detects-json-option-error ()
  (should (systemd-attach--json-option-error-p
           "systemd-run: unrecognized option '--json=short'"))
  (should-not (systemd-attach--json-option-error-p
               "Failed to connect to bus")))

(ert-deftest systemd-attach-parse-json-run-output ()
  (should (equal (systemd-attach--parse-run-output
                  "{\"unit\":\"abc.service\",\"invocation_id\":\"deadbeef\"}\n")
                 '("abc.service" . "deadbeef"))))

(ert-deftest systemd-attach-parse-text-run-output ()
  (should (equal (systemd-attach--parse-run-output
                  "Running as unit: abc.service\n")
                 '("abc.service"))))

(ert-deftest systemd-attach-parse-properties ()
  (should (equal (systemd-attach--parse-properties
                  "ActiveState=active\nSubState=running\nResult=success\n")
                 '(("ActiveState" . "active")
                   ("SubState" . "running")
                   ("Result" . "success")))))

(ert-deftest systemd-attach-parse-unit-list ()
  (should (equal (systemd-attach--parse-unit-list
                  "systemd-attach-a.service loaded active running one\n● systemd-attach-b.service loaded failed failed two\nother.service loaded active running other\n")
                 '("systemd-attach-a.service"
                   "systemd-attach-b.service"
                   "other.service"))))

(ert-deftest systemd-attach-extracts-last-exit-code ()
  (should (equal (systemd-attach--extract-exit-code
                  "x\n[systemd-attach exit status: 1]\ny\n[systemd-attach exit status: 0]\n")
                 0))
  (should-not (systemd-attach--extract-exit-code "no marker")))

(ert-deftest systemd-attach-display-output-hides-internal-lines ()
  (let ((output
         (concat "Starting systemd-attach id...\n"
                 "[systemd-attach metadata: {}]\n"
                 ".\n..\nfile\n"
                 "[systemd-attach exit status: 0]\n"
                 "\e]0;\a\n"
                 "Started systemd-attach id.\n")))
    (should (equal (systemd-attach--display-output output)
                   ".\n..\nfile\n\n"))))

(ert-deftest systemd-attach-replace-header-updates-state ()
  (let ((session (systemd-attach--make-session
                  :id "id"
                  :unit "id.service"
                  :command "echo hi"
                  :working-directory "/tmp"
                  :state "starting")))
    (with-temp-buffer
      (setq systemd-attach-session session)
      (systemd-attach--insert-header session)
      (setq systemd-attach--content-start-marker (copy-marker (point) nil))
      (insert "payload\n")
      (setf (systemd-attach-session-state session) "finished"
            (systemd-attach-session-exit-code session) 0)
      (systemd-attach--replace-header session)
      (should (string-match-p "State:.*finished" (buffer-string)))
      (should (string-match-p "payload" (buffer-string))))))

(ert-deftest systemd-attach-visible-session-buffers-finds-matching-buffers ()
  (let ((session (systemd-attach--make-session :id "id"))
        (other (systemd-attach--make-session :id "other"))
        matching
        nonmatching)
    (unwind-protect
        (progn
          (setq matching (generate-new-buffer " *systemd-attach-test-a*")
                nonmatching (generate-new-buffer " *systemd-attach-test-b*"))
          (with-current-buffer matching
            (setq systemd-attach-session session))
          (with-current-buffer nonmatching
            (setq systemd-attach-session other))
          (should (memq matching
                        (systemd-attach--visible-session-buffers session)))
          (should-not (memq nonmatching
                            (systemd-attach--visible-session-buffers session))))
      (when (buffer-live-p matching)
        (kill-buffer matching))
      (when (buffer-live-p nonmatching)
        (kill-buffer nonmatching)))))

(ert-deftest systemd-attach-session-roundtrip ()
  (let* ((temp-file (make-temp-file "systemd-attach-sessions"))
         (systemd-attach-session-file temp-file)
         (systemd-attach--sessions nil)
         (systemd-attach--sessions-loaded nil)
         (session (systemd-attach--make-session
                   :id "id"
                   :unit "id.service"
                   :command "echo hi"
                   :default-directory "/tmp/"
                   :working-directory "/tmp"
                   :origin "test"
                   :created-at "2026-05-25T00:00:00Z")))
    (unwind-protect
        (progn
          (systemd-attach--put-session session)
          (setq systemd-attach--sessions nil
                systemd-attach--sessions-loaded nil)
          (should (equal (systemd-attach-session-command
                          (systemd-attach--session-by-id "id"))
                         "echo hi")))
      (delete-file temp-file))))

(ert-deftest systemd-attach-loads-old-session-structs ()
  (let* ((temp-file (make-temp-file "systemd-attach-sessions"))
         (systemd-attach-session-file temp-file)
         (systemd-attach--sessions nil)
         (systemd-attach--sessions-loaded nil))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(#s(systemd-attach-session \"old\" \"old.service\" nil \"echo old\" \"/tmp/\" \"/tmp\" nil \"manual\" \"2026-05-25T00:00:00Z\" \"starting\" nil nil nil))\n"))
          (let ((session (systemd-attach--session-by-id "old")))
            (should (equal (systemd-attach-session-command session)
                           "echo old"))
            (should-not (systemd-attach-session-refresh-error session))))
      (delete-file temp-file))))

(ert-deftest systemd-attach-cleanup-current-target-terminal-sessions ()
  (let* ((temp-file (make-temp-file "systemd-attach-sessions"))
         (systemd-attach-session-file temp-file)
         (local-finished
          (systemd-attach--make-session
           :id "local-finished"
           :unit "local-finished.service"
           :default-directory "/tmp/project/"
           :working-directory "/tmp/project"
           :state "finished"))
         (local-active
          (systemd-attach--make-session
           :id "local-active"
           :unit "local-active.service"
           :default-directory "/tmp/project/"
           :working-directory "/tmp/project"
           :state "active"))
         (remote-finished
          (systemd-attach--make-session
           :id "remote-finished"
           :unit "remote-finished.service"
           :default-directory "/ssh:host:/tmp/project/"
           :working-directory "/tmp/project"
           :state "finished"))
         (systemd-attach--sessions
          (list local-finished local-active remote-finished))
         (systemd-attach--sessions-loaded t)
         (default-directory "/tmp/"))
    (unwind-protect
        (progn
          (should (= (systemd-attach--cleanup-sessions
                      (lambda (session)
                        (and (systemd-attach--same-target-p
                              (systemd-attach--session-directory session)
                              default-directory)
                             (systemd-attach--session-terminal-p session))))
                     1))
          (should-not (systemd-attach--session-by-id "local-finished"))
          (should (systemd-attach--session-by-id "local-active"))
          (should (systemd-attach--session-by-id "remote-finished")))
      (delete-file temp-file))))

(ert-deftest systemd-attach-dashboard-builds-entries ()
  (let* ((sessions
          (list
           (systemd-attach--make-session
            :id "id"
            :unit "id.service"
            :command "echo dashboard"
            :working-directory "/tmp/dashboard"
            :remote "host"
            :origin "test"
            :created-at "2026-05-25T00:00:00Z"
            :state "active"
            :sub-state "running"
            :exit-code 0)))
         (entries (systemd-attach--dashboard-entries sessions)))
    (should (equal (caar entries) "id"))
    (should (equal (aref (cadar entries) 0) "active/running"))
    (should (equal (aref (cadar entries) 1) "host"))
    (should (equal (aref (cadar entries) 2) "test"))
    (should (equal (aref (cadar entries) 3) "0"))
    (should (equal (aref (cadar entries) 6) "echo dashboard"))
    (should (eq (get-text-property 0 'face (aref (cadar entries) 0))
                'systemd-attach-state-active))))

(ert-deftest systemd-attach-discovers-known-target-session ()
  (let* ((directory "/ssh:host:/tmp/project/")
         (session (systemd-attach--make-session
                   :id "known"
                   :unit "systemd-attach-known.service"
                   :command "echo known"
                   :default-directory directory
                   :working-directory "/tmp/project"
                   :remote "host"))
         (systemd-attach--sessions (list session))
         (systemd-attach--sessions-loaded t))
    (should (eq (systemd-attach--known-session-by-unit
                 "systemd-attach-known.service"
                 "/ssh:host:/other/")
                session))
    (should-not (systemd-attach--known-session-by-unit
                 "systemd-attach-known.service"
                 "/ssh:other:/tmp/project/"))))

(ert-deftest systemd-attach-known-target-sessions-include-completed-local ()
  (let* ((local (systemd-attach--make-session
                 :id "local"
                 :unit "systemd-attach-local.service"
                 :command "echo local"
                 :default-directory "/tmp/project/"
                 :working-directory "/tmp/project"
                 :state "finished"))
         (remote (systemd-attach--make-session
                  :id "remote"
                  :unit "systemd-attach-remote.service"
                  :command "echo remote"
                  :default-directory "/ssh:host:/tmp/project/"
                  :working-directory "/tmp/project"
                  :state "finished"))
         (systemd-attach--sessions (list local remote))
         (systemd-attach--sessions-loaded t))
    (should (equal (systemd-attach--known-target-sessions "/home/me/")
                   (list local)))
    (should (equal (systemd-attach--known-target-sessions
                    "/ssh:host:/other/")
                   (list remote)))))

(ert-deftest systemd-attach-merge-sessions-prefers-live-discovery ()
  (let ((live (systemd-attach--make-session
               :id "live"
               :unit "same.service"
               :command "<discovered>"))
        (known (systemd-attach--make-session
                :id "known"
                :unit "same.service"
                :command "echo known"))
        (other (systemd-attach--make-session
                :id "other"
                :unit "other.service"
                :command "echo other")))
    (should (equal (systemd-attach--merge-sessions-by-unit
                    (list live) (list known other))
                   (list live other)))))

(ert-deftest systemd-attach-builds-discovered-session ()
  (let ((session (systemd-attach--discovered-session
                  "systemd-attach-abc.service"
                  "/ssh:host:/tmp/project/")))
    (should (equal (systemd-attach-session-id session)
                   "systemd-attach-abc"))
    (should (equal (systemd-attach-session-command session)
                   "<discovered>"))
    (should (equal (systemd-attach-session-working-directory session)
                   "/tmp/project"))
    (should (equal (systemd-attach-session-remote session)
                   "host"))))

(ert-deftest systemd-attach-applies-metadata-to-discovered-session ()
  (let* ((session (systemd-attach--discovered-session
                   "systemd-attach-abc.service"
                   "/ssh:host:/tmp/project/"))
         (metadata
          `((id . "systemd-attach-abc")
            (unit . "systemd-attach-abc.service")
            (command . "make test")
            (working_directory . "/tmp/project")
            (origin . "shell-command")
            (created_at . "2026-05-25T12:00:00Z"))))
    (systemd-attach--apply-metadata session metadata "/ssh:host:/tmp/project/")
    (should (equal (systemd-attach-session-command session) "make test"))
    (should (equal (systemd-attach-session-origin session) "shell-command"))
    (should (equal (systemd-attach-session-created-at session)
                   "2026-05-25T12:00:00Z"))))

(ert-deftest systemd-attach-rerun-rejects-discovered-session ()
  (let ((session (systemd-attach--make-session
                  :id "id"
                  :unit "id.service"
                  :command "<discovered>"
                  :default-directory "/tmp/")))
    (should-error (systemd-attach-rerun-session session)
                  :type 'error)))

(ert-deftest systemd-attach-dired-command-uses-dired-directory ()
  (let ((dired-directory "/tmp/project/")
        captured-command
        captured-directory
        captured-origin)
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'systemd-attach-start)
               (lambda (command origin)
                 (setq captured-command command
                       captured-directory default-directory
                       captured-origin origin))))
      (systemd-attach-dired-command "make train")
      (should (equal captured-command "make train"))
      (should (equal captured-directory "/tmp/project/"))
      (should (eq captured-origin 'dired)))))

(ert-deftest systemd-attach-dired-command-appends-marked-files ()
  (let ((dired-directory "/ssh:host:/tmp/project/")
        captured-command
        captured-directory)
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'dired-get-marked-files)
               (lambda (&rest _)
                 '("/ssh:host:/tmp/project/a file.txt"
                   "/ssh:host:/tmp/project/b.txt")))
              ((symbol-function 'systemd-attach-start)
               (lambda (command origin)
                 (ignore origin)
                 (setq captured-command command
                       captured-directory default-directory))))
      (systemd-attach-dired-command-with-marked-files "python train.py")
      (should (equal captured-command
                     "python train.py /tmp/project/a\\ file.txt /tmp/project/b.txt"))
      (should (equal captured-directory "/ssh:host:/tmp/project/")))))

(ert-deftest systemd-attach-dired-do-shell-command-reuses-dired-expansion ()
  (let ((dired-directory "/tmp/project/")
        captured-command
        captured-directory
        captured-origin)
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'systemd-attach-start)
               (lambda (command origin)
                 (setq captured-command command
                       captured-directory default-directory
                       captured-origin origin))))
      (systemd-attach-dired-do-shell-command
       "tar cf archive.tar *"
       nil
       '("a file.txt" "b.txt"))
      (should (equal captured-command
                     "tar cf archive.tar a\\ file.txt b.txt"))
      (should (equal captured-directory "/tmp/project/"))
      (should (eq captured-origin 'dired)))))

(ert-deftest systemd-attach-dired-prefix-binds-shell-style-command ()
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "&") #'systemd-attach-dired-do-shell-command)
    (should (eq (lookup-key map (kbd "&"))
                #'systemd-attach-dired-do-shell-command)))
  (should (equal (systemd-attach--evil-prefix-key "SPC m" "&")
                 (kbd "SPC m &"))))

(ert-deftest systemd-attach-dashboard-refreshes-nonterminal-states ()
  (let ((starting (systemd-attach--make-session :state "starting"))
        (active (systemd-attach--make-session :state "active"))
        (finished (systemd-attach--make-session :state "finished"))
        (failed (systemd-attach--make-session :state "failed"))
        (unknown (systemd-attach--make-session :state nil)))
    (should (systemd-attach--session-needs-refresh-p starting))
    (should (systemd-attach--session-needs-refresh-p active))
    (should (systemd-attach--session-needs-refresh-p unknown))
    (should-not (systemd-attach--session-needs-refresh-p finished))
    (should-not (systemd-attach--session-needs-refresh-p failed))))

(ert-deftest systemd-attach-dashboard-ret-views-session ()
  (should (eq (lookup-key systemd-attach-dashboard-mode-map (kbd "RET"))
              #'systemd-attach-dashboard-view)))

(ert-deftest systemd-attach-dashboard-x-cleans-up-sessions ()
  (should (eq (lookup-key systemd-attach-dashboard-mode-map (kbd "x"))
              #'systemd-attach-dashboard-cleanup)))

(ert-deftest systemd-attach-dashboard-falls-back-on-discovery-error ()
  (let ((known (systemd-attach--make-session
                :id "known"
                :unit "known.service"
                :command "echo known"
                :default-directory "/ssh:host:/tmp/"
                :working-directory "/tmp")))
    (with-temp-buffer
      (systemd-attach-dashboard-mode)
      (setq systemd-attach-dashboard-scope 'target
            systemd-attach-dashboard-directory "/ssh:host:/tmp/")
      (cl-letf (((symbol-function 'systemd-attach--target-dashboard-sessions)
                 (lambda (_) (error "remote unavailable")))
                ((symbol-function 'systemd-attach--known-target-sessions)
                 (lambda (_) (list known)))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (systemd-attach-dashboard-refresh)
        (should (equal systemd-attach-dashboard-sessions (list known)))
        (should (equal (systemd-attach-session-state known) "error"))
        (should (equal (systemd-attach-session-refresh-error known)
                       "remote unavailable"))))))

(ert-deftest systemd-attach-dashboard-evil-prefix-key ()
  (let ((systemd-attach-dashboard-evil-prefix "SPC m"))
    (should (equal (systemd-attach--dashboard-prefix-key "RET")
                   (kbd "SPC m RET")))
    (should (equal (systemd-attach--dashboard-prefix-key "R")
                   (kbd "SPC m R")))))

(ert-deftest systemd-attach-evil-prefix-key ()
  (should (equal (systemd-attach--evil-prefix-key "SPC m" "c")
                 (kbd "SPC m c")))
  (should (equal (systemd-attach--evil-prefix-key "SPC m" "m")
                 (kbd "SPC m m"))))

(ert-deftest systemd-attach-evil-define-key-uses-keymap-symbol ()
  (let (captured)
    (cl-letf (((symbol-function 'evil-define-key)
               (lambda (&rest _) nil))
              ((symbol-function 'eval)
               (lambda (form &optional _lexical)
                 (setq captured form))))
      (systemd-attach--evil-define-key
       'normal 'dired-mode-map
       (kbd "SPC m &") #'systemd-attach-dired-do-shell-command)
      (should (equal (nth 2 captured) 'dired-mode-map))
      (should-not (keymapp (nth 2 captured))))))

(ert-deftest systemd-attach-integration-starts-echo ()
  (unless (getenv "SYSTEMD_ATTACH_INTEGRATION")
    (ert-skip "Set SYSTEMD_ATTACH_INTEGRATION=1 to run systemd integration tests"))
  (dolist (program '("systemd-run" "systemctl" "journalctl"))
    (unless (executable-find program)
      (ert-skip (format "%s not found" program))))
  (let* ((temp-file (make-temp-file "systemd-attach-sessions"))
         (systemd-attach-session-file temp-file)
         (systemd-attach-open-after-start nil)
         (systemd-attach--sessions nil)
         (systemd-attach--sessions-loaded nil))
    (unwind-protect
        (let ((session (systemd-attach-start "printf integration-ok" 'ert)))
          (sleep-for 1)
          (let ((output (systemd-attach--call-or-error
                         systemd-attach-journalctl-program
                         (systemd-attach--journal-args session nil 20)
                         default-directory)))
            (should (string-match-p "integration-ok" output))))
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))

(provide 'systemd-attach-test)

;;; systemd-attach-test.el ends here
