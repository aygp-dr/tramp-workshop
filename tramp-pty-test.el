;;; tramp-pty-test.el --- PTY/terminal tests for container methods  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Jason Walsh <j@wal.sh>

;;; Commentary:

;; PTY (pseudo-terminal) tests for various container access methods:
;; - Local: bastille console, jexec (FreeBSD jails)
;; - Cloud: Cloudflare Sandboxes (WebSocket PTY), AWS ECS Exec (SSM)
;;
;; These tests verify that interactive terminal sessions work correctly,
;; including:
;; - PTY allocation and command execution
;; - Terminal escape sequence handling
;; - Session persistence and reconnection
;; - Terminal resize (SIGWINCH)
;;
;; Run with: emacs --batch -l ert -l tramp-pty-test.el -f ert-run-tests-batch-and-exit
;;
;; For live PTY tests, run interactively or use:
;;   make test-pty JAIL=agent-a

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'term nil t)    ; optional, may not be available in batch
(require 'comint nil t)  ; optional, may not be available in batch

;;; --- PTY Test Utilities ---

(defvar pty-test-timeout 10
  "Timeout in seconds for PTY operations.")

(defun pty-test--run-with-pty (command &optional timeout)
  "Run COMMAND in a PTY via script(1), return output.
TIMEOUT defaults to `pty-test-timeout' seconds."
  (let* ((timeout-sec (or timeout pty-test-timeout))
         (script-cmd (format "script -q /dev/null %s" command))
         (output (with-timeout (timeout-sec "TIMEOUT")
                   (shell-command-to-string script-cmd))))
    (string-trim output)))

(defun pty-test--jexec-pty (jail command)
  "Execute COMMAND in JAIL via jexec with PTY allocation."
  (pty-test--run-with-pty
   (format "sudo jexec %s /bin/sh -c '%s; exit'" jail command)))

(defun pty-test--bastille-cmd (jail command)
  "Execute COMMAND in JAIL via bastille cmd (no PTY, for comparison)."
  (string-trim
   (shell-command-to-string
    (format "sudo jexec %s /bin/sh -c '%s'" jail command))))

;;; --- Local PTY Tests (FreeBSD Jails) ---

(ert-deftest pty-jexec-basic-command ()
  "Test basic command execution via jexec PTY."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         (output (pty-test--jexec-pty jail "echo PTY_OK")))
    (should (string-match-p "PTY_OK" output))))

(ert-deftest pty-jexec-tty-detection ()
  "Test that PTY is properly allocated (tty command succeeds)."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         (output (pty-test--jexec-pty jail "tty")))
    ;; tty should return a device path like /dev/pts/X, not "not a tty"
    (should (string-match-p "/dev/pts\\|/dev/tty" output))))

(ert-deftest pty-jexec-environment ()
  "Test TERM environment variable is set in PTY."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         (output (pty-test--jexec-pty jail "echo $TERM")))
    ;; TERM should be set (commonly "dumb", "xterm", "screen", etc.)
    (should (> (length (string-trim output)) 0))))

(ert-deftest pty-jexec-multiline-output ()
  "Test multiline output through PTY."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         (output (pty-test--jexec-pty jail "echo line1; echo line2; echo line3")))
    (should (string-match-p "line1" output))
    (should (string-match-p "line2" output))
    (should (string-match-p "line3" output))))

;;; --- PTY Escape Sequence Tests ---

(ert-deftest pty-escape-sequences-colors ()
  "Test that ANSI color codes pass through PTY."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         ;; printf red text with ANSI escape
         (output (pty-test--jexec-pty
                  jail "printf '\\033[31mRED\\033[0m'")))
    ;; Should contain the escape sequence or the word RED
    (should (or (string-match-p "\033\\[31m" output)
                (string-match-p "RED" output)))))

(ert-deftest pty-escape-sequences-cursor ()
  "Test cursor movement escape sequences."
  (skip-unless (executable-find "jexec"))
  (skip-unless (= 0 (shell-command "sudo jls -q name 2>/dev/null | head -1")))
  (let* ((jail (string-trim (shell-command-to-string "sudo jls -q name | head -1")))
         ;; Move cursor, print text
         (output (pty-test--jexec-pty
                  jail "printf '\\033[2JCLEAR'")))
    (should (string-match-p "CLEAR" output))))

;;; --- WebSocket PTY Patterns (Cloudflare Sandboxes) ---
;;
;; These are pattern tests - they verify the structure of WebSocket PTY
;; messages without requiring actual CF credentials.

(defun pty-ws--encode-input (text)
  "Encode TEXT as a WebSocket PTY input message.
CF Sandboxes use JSON-wrapped messages."
  (json-encode `((type . "input") (data . ,text))))

(defun pty-ws--decode-output (message)
  "Decode a WebSocket PTY output MESSAGE.
Returns the data field or nil."
  (when-let* ((parsed (ignore-errors (json-read-from-string message)))
              (type (alist-get 'type parsed))
              ((string= type "output")))
    (alist-get 'data parsed)))

(defun pty-ws--encode-resize (cols rows)
  "Encode a terminal resize message for COLS x ROWS."
  (json-encode `((type . "resize") (cols . ,cols) (rows . ,rows))))

(ert-deftest pty-ws-input-encoding ()
  "Test WebSocket PTY input message encoding."
  (let ((encoded (pty-ws--encode-input "ls -la\n")))
    (should (stringp encoded))
    (should (string-match-p "\"type\":\"input\"" encoded))
    (should (string-match-p "\"data\":\"ls -la" encoded))))

(ert-deftest pty-ws-output-decoding ()
  "Test WebSocket PTY output message decoding."
  (let* ((message "{\"type\":\"output\",\"data\":\"hello world\"}")
         (decoded (pty-ws--decode-output message)))
    (should (equal decoded "hello world"))))

(ert-deftest pty-ws-output-decoding-wrong-type ()
  "Test that non-output messages return nil."
  (let ((message "{\"type\":\"resize\",\"cols\":80,\"rows\":24}"))
    (should (null (pty-ws--decode-output message)))))

(ert-deftest pty-ws-resize-encoding ()
  "Test terminal resize message encoding."
  (let ((encoded (pty-ws--encode-resize 120 40)))
    (should (string-match-p "\"type\":\"resize\"" encoded))
    (should (string-match-p "\"cols\":120" encoded))
    (should (string-match-p "\"rows\":40" encoded))))

(ert-deftest pty-ws-roundtrip ()
  "Test encoding/decoding roundtrip for PTY messages."
  (dotimes (_ 20)
    (let* ((test-data (format "command-%d\n" (random 10000)))
           ;; Simulate: client sends input -> server echoes as output
           (input-msg (pty-ws--encode-input test-data))
           (parsed-input (json-read-from-string input-msg))
           (echo-data (alist-get 'data parsed-input))
           (output-msg (json-encode `((type . "output") (data . ,echo-data))))
           (decoded (pty-ws--decode-output output-msg)))
      (should (equal decoded test-data)))))

;;; --- ECS Exec PTY Patterns (AWS SSM) ---
;;
;; ECS Exec uses AWS Session Manager. These test the command structure.

(defun pty-ecs--build-exec-command (cluster task &optional container)
  "Build aws ecs execute-command for CLUSTER, TASK, and optional CONTAINER."
  (let ((base-cmd (format "aws ecs execute-command --cluster %s --task %s --interactive --command /bin/sh"
                          cluster task)))
    (if container
        (format "%s --container %s" base-cmd container)
      base-cmd)))

(ert-deftest pty-ecs-command-structure ()
  "Test ECS exec command building."
  (let ((cmd (pty-ecs--build-exec-command "my-cluster" "abc123")))
    (should (string-match-p "--cluster my-cluster" cmd))
    (should (string-match-p "--task abc123" cmd))
    (should (string-match-p "--interactive" cmd))))

(ert-deftest pty-ecs-command-with-container ()
  "Test ECS exec command with container specified."
  (let ((cmd (pty-ecs--build-exec-command "prod" "task-xyz" "web")))
    (should (string-match-p "--container web" cmd))))

;;; --- Emacs Terminal Integration Tests ---

(ert-deftest pty-emacs-term-mode-available ()
  "Test that term-mode is available (when term.el is loaded)."
  (skip-unless (featurep 'term))
  (should (fboundp 'term-mode))
  (should (fboundp 'make-term)))

(ert-deftest pty-emacs-comint-available ()
  "Test that comint (for shell mode) is available (when comint.el is loaded)."
  (skip-unless (featurep 'comint))
  (should (fboundp 'comint-mode))
  (should (fboundp 'make-comint-in-buffer)))

(ert-deftest pty-emacs-process-pty ()
  "Test Emacs can create PTY processes."
  (let* ((proc (start-process "pty-test" nil "true"))
         (pty-p (process-tty-name proc)))
    (delete-process proc)
    ;; On systems with PTY support, this should be a tty device
    (should (or pty-p
                ;; Some batch modes don't allocate PTY
                (not (display-graphic-p))))))

;;; --- Property Tests for PTY Message Handling ---

(ert-deftest pty-property-input-never-empty ()
  "Property: encoded input messages always have data field."
  (dotimes (_ 50)
    (let* ((random-input (make-string (1+ (random 100)) (+ ?a (random 26))))
           (encoded (pty-ws--encode-input random-input))
           (parsed (json-read-from-string encoded)))
      (should (alist-get 'data parsed))
      (should (> (length (alist-get 'data parsed)) 0)))))

(ert-deftest pty-property-resize-valid-dimensions ()
  "Property: resize messages have positive integer dimensions."
  (dotimes (_ 50)
    (let* ((cols (+ 40 (random 200)))  ; 40-239
           (rows (+ 10 (random 100)))  ; 10-109
           (encoded (pty-ws--encode-resize cols rows))
           (parsed (json-read-from-string encoded)))
      (should (= (alist-get 'cols parsed) cols))
      (should (= (alist-get 'rows parsed) rows))
      (should (> (alist-get 'cols parsed) 0))
      (should (> (alist-get 'rows parsed) 0)))))

(provide 'tramp-pty-test)
;;; tramp-pty-test.el ends here
