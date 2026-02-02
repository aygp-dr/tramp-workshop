;;; tramp-bastille-workshop.el --- Workshop helpers for jail-based agent workflows  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Jason Walsh <j@wal.sh>
;; Keywords: comm, processes, convenience
;; URL: https://github.com/aygp-dr/tramp-workshop

;;; Commentary:

;; Interactive helpers for the TRAMP + Bastille jail workshop.
;; Provides convenience commands for the three-hop topology:
;;
;;   Laptop -> Restricted Host (operator) -> Sandbox Host -> Jail
;;
;; This file demonstrates several TRAMP patterns:
;; 1. Custom method registration (bastille/jexec)
;; 2. Multi-hop with proxy alist (auto-routing)
;; 3. Connection-local variables per jail
;; 4. Interactive shell/compile/dired inside jails
;; 5. Agent-aware project management (beads integration)

;;; Code:

(require 'tramp-bastille)

;;; --- Configuration ---

(defgroup tramp-bastille-workshop nil
  "Workshop configuration for TRAMP + Bastille jail workflows."
  :group 'tramp
  :prefix "jail-")

(defcustom jail-sandbox-host "sandbox"
  "SSH host alias for the sandbox machine.
This should match an entry in ~/.ssh/config."
  :type 'string
  :group 'tramp-bastille-workshop)

(defcustom jail-sandbox-user "jwalsh"
  "Username on the sandbox host."
  :type 'string
  :group 'tramp-bastille-workshop)

(defcustom jail-default-root "/root/"
  "Default root directory inside jails."
  :type 'string
  :group 'tramp-bastille-workshop)

(defcustom jail-known-jails
  '("agent-aygp" "agent-dsp" "agent-a" "agent-b" "agent-dsp-dr")
  "List of known jail names for completion."
  :type '(repeat string)
  :group 'tramp-bastille-workshop)

;;; --- Proxy Configuration ---

(defun jail-configure-proxy (&optional host user)
  "Set up `tramp-default-proxies-alist' for jail auto-routing.
Any jail matching \"agent-.*\" will automatically proxy through
HOST as USER.  With prefix arg, prompts for HOST and USER."
  (interactive
   (when current-prefix-arg
     (list (read-string "Sandbox host: " jail-sandbox-host)
           (read-string "Sandbox user: " jail-sandbox-user))))
  (let ((h (or host jail-sandbox-host))
        (u (or user jail-sandbox-user)))
    (add-to-list 'tramp-default-proxies-alist
                 `("agent-.*" nil ,(format "/ssh:%s@%s:" u h)))
    (message "Proxy configured: agent-* -> /ssh:%s@%s:" u h)))

;;; --- Interactive Commands ---

(defun jail-read-name ()
  "Read a jail name with completion."
  (completing-read "Jail: " jail-known-jails nil nil nil nil
                   (car jail-known-jails)))

(defun jail-tramp-prefix (jail)
  "Return the TRAMP prefix for JAIL."
  (format "/bastille:%s:" jail))

;;;###autoload
(defun jail-find-file (jail path)
  "Open PATH inside Bastille JAIL.
With `tramp-default-proxies-alist' configured, this auto-routes
through the sandbox host."
  (interactive
   (list (jail-read-name)
         (read-string "Path: " jail-default-root)))
  (find-file (concat (jail-tramp-prefix jail) path)))

;;;###autoload
(defun jail-dired (jail &optional directory)
  "Open dired in JAIL at DIRECTORY."
  (interactive (list (jail-read-name)))
  (let ((dir (or directory jail-default-root)))
    (dired (concat (jail-tramp-prefix jail) dir))))

;;;###autoload
(defun jail-shell (jail)
  "Open a shell buffer connected to JAIL."
  (interactive (list (jail-read-name)))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (shell (format "*jail:%s*" jail))))

;;;###autoload
(defun jail-eshell (jail)
  "Open eshell connected to JAIL."
  (interactive (list (jail-read-name)))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (eshell t)))

;;;###autoload
(defun jail-compile (jail command)
  "Run COMMAND inside JAIL via `compile'."
  (interactive
   (list (jail-read-name)
         (read-string "Command: " "gmake check")))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (compile command)))

;;;###autoload
(defun jail-term (jail)
  "Open an ansi-term connected to JAIL."
  (interactive (list (jail-read-name)))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (ansi-term "/bin/sh" (format "jail:%s" jail))))

;;; --- Beads (bd) Integration ---

;;;###autoload
(defun jail-beads-ready (jail)
  "Show available beads work in JAIL."
  (interactive (list (jail-read-name)))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (shell-command "bd ready" "*bd-ready*")))

;;;###autoload
(defun jail-beads-list (jail)
  "List all open beads in JAIL."
  (interactive (list (jail-read-name)))
  (let ((default-directory (concat (jail-tramp-prefix jail) jail-default-root)))
    (shell-command "bd list --status=open" "*bd-list*")))

;;; --- Multi-Jail Dashboard ---

;;;###autoload
(defun jail-dashboard ()
  "Show a summary of all known jails.
Opens a buffer with jail names and their git/beads status."
  (interactive)
  (with-current-buffer (get-buffer-create "*jail-dashboard*")
    (erase-buffer)
    (insert "=== Jail Dashboard ===\n\n")
    (insert (format "%-20s %-15s %s\n" "Jail" "Method" "Path"))
    (insert (make-string 60 ?-) "\n")
    (dolist (jail jail-known-jails)
      (insert (format "%-20s %-15s %s\n"
                      jail "bastille"
                      (concat (jail-tramp-prefix jail) jail-default-root))))
    (insert "\n")
    (insert "Keybindings:\n")
    (insert "  f  jail-find-file     Open file in jail\n")
    (insert "  d  jail-dired         Dired in jail\n")
    (insert "  s  jail-shell         Shell in jail\n")
    (insert "  c  jail-compile       Compile in jail\n")
    (insert "  b  jail-beads-ready   Show available work\n")
    (insert "  q  quit-window        Close dashboard\n")
    (goto-char (point-min))
    (display-buffer (current-buffer))))

;;; --- Workshop Exercises ---

;; Exercise 1: Basic Access
;;   M-x jail-find-file -> agent-dsp-dr -> /root/.bashrc
;;   Verify you can read files inside the jail.

;; Exercise 2: Multi-hop Transparency
;;   C-x C-f /bastille:agent-dsp-dr:/etc/resolv.conf
;;   Note: TRAMP auto-routes through sandbox if proxy alist configured.

;; Exercise 3: Shell + Beads
;;   M-x jail-shell -> agent-dsp-dr
;;   In shell: bd ready && bd list --status=open

;; Exercise 4: Compile
;;   M-x jail-compile -> agent-dsp-dr -> "gmake check"
;;   Errors in *compilation* should have clickable TRAMP paths.

;; Exercise 5: Cross-Jail Comparison
;;   Open same file in two jails side-by-side:
;;   C-x C-f /bastille:agent-a:/root/.bashrc
;;   C-x 3
;;   C-x C-f /bastille:agent-b:/root/.bashrc
;;   Note: completely isolated filesystems.

;; Exercise 6: Agent Identity Verification
;;   M-x jail-shell in agent-aygp
;;   Run: gh api user --jq '.login'
;;   M-x jail-shell in agent-dsp-dr
;;   Run: gh api user --jq '.login'
;;   Should show different identities.

(provide 'tramp-bastille-workshop)
;;; tramp-bastille-workshop.el ends here
