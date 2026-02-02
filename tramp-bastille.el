;;; tramp-bastille.el --- TRAMP method for FreeBSD Bastille jails  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Jason Walsh <j@wal.sh>
;; Keywords: comm, processes
;; URL: https://github.com/aygp-dr/tramp-workshop
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (tramp "2.7"))

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Provides TRAMP access to FreeBSD Bastille thin jails.
;;
;; ## Usage
;;
;; Open a file inside a running Bastille jail:
;;
;;     C-x C-f /bastille:JAIL:/path/to/file
;;
;; Where:
;;     JAIL     is the jail name (e.g., agent-alpha)
;;
;; With multi-hop (SSH to sandbox host, then enter jail):
;;
;;     C-x C-f /ssh:operator@sandbox|bastille:agent-alpha:/root/project/file.py
;;
;; With `tramp-default-proxies-alist' configured, the SSH hop is automatic:
;;
;;     C-x C-f /bastille:agent-alpha:/root/project/file.py
;;
;; Alternative method using jexec(8) directly:
;;
;;     C-x C-f /jexec:agent-alpha:/root/project/file.py
;;
;; ## Requirements
;;
;; - FreeBSD with jail(8) support
;; - Bastille jail manager (https://bastillebsd.org)
;; - Passwordless sudo for `bastille console' on the jail host
;;
;; ## Motivation
;;
;; This method enables Emacs-based development workflows where AI coding
;; agents run inside isolated FreeBSD jails.  The operator edits files,
;; runs tests, and tracks issues (via beads/bd) inside jails without
;; leaving Emacs.  See the companion paper:
;; https://wal.sh/research/2026-agent-isolation-freebsd-jails.html

;;; Code:

(require 'tramp)

;;;###autoload
(defcustom tramp-bastille-program "bastille"
  "Name of the Bastille jail manager program."
  :group 'tramp
  :version "31.1"
  :type '(choice (const "bastille")
                 (string)))

;;;###autoload
(defconst tramp-bastille-method "bastille"
  "TRAMP method name to connect to Bastille jails.")

;;;###autoload
(defconst tramp-jexec-method "jexec"
  "TRAMP method name to connect to FreeBSD jails via jexec(8).")

;; Bastille method: `sudo bastille console <jail>'
;; The %h placeholder is the jail name (TRAMP "host").
;; bastille console provides an interactive shell.
(add-to-list 'tramp-methods
  `(,tramp-bastille-method
    (tramp-login-program "sudo")
    (tramp-login-args (("bastille") ("console") ("%h")))
    (tramp-direct-async (,tramp-default-remote-shell "-c"))
    (tramp-remote-shell ,tramp-default-remote-shell)
    (tramp-remote-shell-login ("-l"))
    (tramp-remote-shell-args ("-i" "-c"))
    (tramp-completion-use-cache nil)))

;; jexec method: `sudo jexec <jail> /bin/sh'
;; Lower-level alternative that doesn't require Bastille.
(add-to-list 'tramp-methods
  '("jexec"
    (tramp-login-program "sudo")
    (tramp-login-args (("jexec") ("%h") ("/bin/sh")))
    (tramp-remote-shell "/bin/sh")
    (tramp-remote-shell-args ("-i" "-c"))
    (tramp-completion-use-cache nil)))

;; Enable multi-hop completion for bastille method
(add-to-list 'tramp-completion-multi-hop-methods tramp-bastille-method)

(defun tramp-bastille--completion-function (_method)
  "List Bastille jails available for connection.

This function is used by `tramp-set-completion-function', please
see its function help for a description of the format."
  (when-let* ((raw-list
               (shell-command-to-string "sudo bastille list 2>/dev/null"))
              (lines (split-string raw-list "\n" 'omit-nulls))
              ;; bastille list output: JID  State  IP  Hostname  Path
              ;; Skip the header line, extract jail names (column 4 = hostname)
              (names (seq-filter
                      (lambda (name)
                        (and name (not (string= name "Hostname"))))
                      (mapcar (lambda (line)
                                (nth 3 (split-string line)))
                              (cdr lines)))))
    (mapcar (lambda (name) (list nil name)) names)))

(defun tramp-jexec--completion-function (_method)
  "List FreeBSD jails available for connection via jls(8).

This function is used by `tramp-set-completion-function', please
see its function help for a description of the format."
  (when-let* ((raw-list
               (shell-command-to-string "sudo jls -q name 2>/dev/null"))
              (names (split-string raw-list "\n" 'omit-nulls)))
    (mapcar (lambda (name) (list nil name)) names)))

(tramp-set-completion-function
 tramp-bastille-method
 '((tramp-bastille--completion-function "")))

(tramp-set-completion-function
 tramp-jexec-method
 '((tramp-jexec--completion-function "")))

;;; --- AWS ECS Exec Method ---

;; ECS Exec uses `aws ecs execute-command' to shell into Fargate/EC2 tasks.
;; Requires: aws CLI v2 with Session Manager plugin installed.
;; The %h placeholder is CLUSTER.TASK (dot-separated).

;;;###autoload
(defconst tramp-ecs-method "ecs"
  "TRAMP method name to connect to AWS ECS containers via execute-command.")

(add-to-list 'tramp-methods
  '("ecs"
    (tramp-login-program "aws")
    (tramp-login-args (("ecs") ("execute-command")
                       ("--interactive")
                       ("--command" "%l")
                       ("--task" "%h")
                       ("--cluster" "%u")))
    (tramp-remote-shell "/bin/sh")
    (tramp-remote-shell-args ("-i" "-c"))
    (tramp-completion-use-cache nil)))

;; Usage:
;;   /ecs:CLUSTER@TASK-ID:/path/to/file
;;
;; Example:
;;   /ecs:my-cluster@abc123def456:/app/config.yml
;;
;; With proxy (SSM through bastion):
;;   /ssh:bastion|ecs:my-cluster@abc123:/app/config.yml

(provide 'tramp-bastille)
;;; tramp-bastille.el ends here
