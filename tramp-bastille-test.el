;;; tramp-bastille-test.el --- Property-based tests for tramp-bastille  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Jason Walsh <j@wal.sh>

;;; Commentary:

;; Property-based tests for the jail name parsing functions.
;; Run with: emacs --batch -l ert -l tramp-bastille.el -l tramp-bastille-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tramp-bastille)

;;; --- Test Data Generators ---

(defun pbt--random-string (length &optional charset)
  "Generate a random string of LENGTH using CHARSET.
CHARSET defaults to alphanumeric + hyphen (valid jail names)."
  (let ((chars (or charset "abcdefghijklmnopqrstuvwxyz0123456789-")))
    (apply #'string
           (cl-loop repeat length
                    collect (aref chars (random (length chars)))))))

(defun pbt--random-jail-name ()
  "Generate a random valid jail name.
Jail names: alphanumeric + hyphen, 1-64 chars, not starting with hyphen."
  (let* ((len (1+ (random 20)))
         (first-char (aref "abcdefghijklmnopqrstuvwxyz" (random 26)))
         (rest (pbt--random-string (1- len))))
    (concat (char-to-string first-char) rest)))

(defun pbt--random-ip ()
  "Generate a random IPv4 address."
  (format "%d.%d.%d.%d"
          (random 256) (random 256) (random 256) (random 256)))

(defun pbt--random-jid ()
  "Generate a random JID (1-999)."
  (number-to-string (1+ (random 999))))

(defun pbt--generate-bastille-line (jail-name)
  "Generate a bastille list output line for JAIL-NAME."
  (let ((jid (pbt--random-jid))
        (boot (if (zerop (random 2)) "on" "off"))
        (prio (number-to-string (random 100)))
        (state (nth (random 3) '("Up" "Down" "Starting")))
        (type (nth (random 2) '("thin" "thick")))
        (ip (pbt--random-ip))
        (ports "-")
        (release "14.3-RELEASE")
        (tags "-"))
    (format " %-4s %-15s %-5s %-5s %-6s %-6s %-15s %-16s %-13s %s"
            jid jail-name boot prio state type ip ports release tags)))

(defun pbt--generate-bastille-output (jail-names)
  "Generate full bastille list output for JAIL-NAMES."
  (concat
   " JID  Name            Boot  Prio  State  Type   IP Address      Published Ports  Release       Tags\n"
   (mapconcat #'pbt--generate-bastille-line jail-names "\n")))

;;; --- Property Tests ---

(ert-deftest pbt-parse-extracts-correct-name ()
  "Property: parsing a line always extracts the correct jail name."
  (dotimes (_ 100)
    (let* ((expected-name (pbt--random-jail-name))
           (line (pbt--generate-bastille-line expected-name))
           (parsed (tramp-bastille--parse-jail-name line)))
      (should (equal parsed expected-name)))))

(ert-deftest pbt-parse-header-returns-nil ()
  "Property: parsing the header line returns nil."
  (let ((header " JID  Name            Boot  Prio  State  Type   IP Address      Published Ports  Release       Tags"))
    (should (null (tramp-bastille--parse-jail-name header)))))

(ert-deftest pbt-parse-empty-returns-nil ()
  "Property: parsing empty/whitespace lines returns nil."
  (should (null (tramp-bastille--parse-jail-name "")))
  (should (null (tramp-bastille--parse-jail-name "   ")))
  (should (null (tramp-bastille--parse-jail-name "\t\t"))))

(ert-deftest pbt-parse-single-field-returns-nil ()
  "Property: parsing lines with < 2 fields returns nil."
  (should (null (tramp-bastille--parse-jail-name "1")))
  (should (null (tramp-bastille--parse-jail-name "  123  "))))

(ert-deftest pbt-completion-returns-all-jails ()
  "Property: completion function returns all jails from output."
  (dotimes (_ 20)
    (let* ((num-jails (1+ (random 10)))
           (expected-names (cl-loop repeat num-jails
                                    collect (pbt--random-jail-name)))
           (output (pbt--generate-bastille-output expected-names)))
      ;; Mock shell-command-to-string
      (cl-letf (((symbol-function 'shell-command-to-string)
                 (lambda (_cmd) output)))
        (let ((result (tramp-bastille--completion-function "")))
          ;; Result format: ((nil "name1") (nil "name2") ...)
          (should (= (length result) num-jails))
          (should (equal (mapcar #'cadr result) expected-names)))))))

(ert-deftest pbt-completion-empty-output ()
  "Property: empty bastille output returns nil."
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (_cmd) "")))
    (should (null (tramp-bastille--completion-function "")))))

(ert-deftest pbt-completion-header-only ()
  "Property: header-only output returns nil."
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (_cmd) " JID  Name  Boot  Prio  State\n")))
    (should (null (tramp-bastille--completion-function "")))))

;;; --- Edge Case Tests ---

(ert-deftest edge-case-jail-names ()
  "Test parsing handles various valid jail name patterns."
  (dolist (name '("a" "agent-alpha" "jail123" "my-jail-2024"
                  "x" "a-b-c-d-e" "test0" "UPPER" "MixedCase"))
    (let* ((line (pbt--generate-bastille-line name))
           (parsed (tramp-bastille--parse-jail-name line)))
      (should (equal parsed name)))))

(ert-deftest edge-case-wide-columns ()
  "Test parsing handles varying column widths."
  (let ((wide-line " 999  very-long-jail-name-here  on    99    Up     thin   192.168.255.255  8080:80,443:443  14.3-RELEASE  tag1,tag2"))
    (should (equal (tramp-bastille--parse-jail-name wide-line)
                   "very-long-jail-name-here"))))

(ert-deftest edge-case-minimal-columns ()
  "Test parsing handles minimal valid input."
  (should (equal (tramp-bastille--parse-jail-name "1 jail") "jail"))
  (should (equal (tramp-bastille--parse-jail-name "  1   jail  ") "jail")))

;;; --- Regression Tests ---

(ert-deftest regression-column-3-bug ()
  "Regression: ensure we parse column 1 (Name), not column 3 (Prio).
This was the original bug where '99' was returned instead of jail names."
  (let ((line " 1    agent-alpha     on    99    Up     thin   10.0.0.10"))
    (should (equal (tramp-bastille--parse-jail-name line) "agent-alpha"))
    (should-not (equal (tramp-bastille--parse-jail-name line) "99"))))

(ert-deftest regression-real-bastille-output ()
  "Test against actual bastille list output format."
  (let ((real-output " JID  Name            Boot  Prio  State  Type   IP Address  Published Ports  Release       Tags
 1    agent-a         on    99    Up     thin   10.0.0.20   -                14.3-RELEASE  -
 2    agent-adbudget  on    99    Up     thin   10.0.0.41   -                14.3-RELEASE  -
 3    agent-aygp      on    99    Up     thin   10.0.0.10   -                14.3-RELEASE  -"))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_cmd) real-output)))
      (let ((result (tramp-bastille--completion-function "")))
        (should (equal (mapcar #'cadr result)
                       '("agent-a" "agent-adbudget" "agent-aygp")))))))

;;; --- Type Hardening Tests ---

(ert-deftest type-parse-returns-string-or-nil ()
  "Property: parse function always returns string or nil."
  (dotimes (_ 50)
    (let* ((line (pbt--generate-bastille-line (pbt--random-jail-name)))
           (result (tramp-bastille--parse-jail-name line)))
      (should (or (null result) (stringp result))))))

(ert-deftest type-completion-returns-list-of-pairs ()
  "Property: completion function returns list of (nil string) pairs."
  (dotimes (_ 10)
    (let* ((names (cl-loop repeat (1+ (random 5))
                           collect (pbt--random-jail-name)))
           (output (pbt--generate-bastille-output names)))
      (cl-letf (((symbol-function 'shell-command-to-string)
                 (lambda (_cmd) output)))
        (let ((result (tramp-bastille--completion-function "")))
          (should (listp result))
          (dolist (pair result)
            (should (listp pair))
            (should (= (length pair) 2))
            (should (null (car pair)))
            (should (stringp (cadr pair)))))))))

;;; --- Multi-Runtime Parsing Tests ---
;;
;; These tests demonstrate PBT patterns applicable to parsing output from
;; various container runtimes (Docker, Podman, Kubernetes, jls, etc.)

(defun pbt--generate-docker-ps-line (container-name)
  "Generate a docker ps output line for CONTAINER-NAME."
  (let ((id (pbt--random-string 12 "0123456789abcdef"))
        (image (format "%s:%s"
                       (pbt--random-string 8)
                       (nth (random 3) '("latest" "v1.0" "alpine"))))
        (command (format "\"/bin/sh -c '%s'\"" (pbt--random-string 10)))
        (created (nth (random 4) '("2 hours ago" "3 days ago" "5 minutes ago" "About an hour ago")))
        (status (nth (random 3) '("Up 2 hours" "Exited (0) 3 days ago" "Up 5 minutes")))
        (ports "")
        (names container-name))
    (format "%-12s   %-20s   %-30s   %-15s   %-25s   %-10s   %s"
            id image command created status ports names)))

(defun pbt--generate-kubectl-pods-line (pod-name)
  "Generate a kubectl get pods output line for POD-NAME."
  (let ((ready (format "%d/%d" (random 3) (1+ (random 3))))
        (status (nth (random 4) '("Running" "Pending" "Completed" "CrashLoopBackOff")))
        (restarts (number-to-string (random 10)))
        (age (nth (random 4) '("2d" "5h30m" "10m" "3d12h"))))
    (format "%-40s   %-5s   %-20s   %-3s   %s"
            pod-name ready status restarts age)))

(defun pbt--parse-docker-container-name (line)
  "Parse container name from docker ps output LINE.
Returns name or nil."
  (when-let* ((fields (split-string line nil 'omit-nulls))
              ((>= (length fields) 7))
              (name (car (last fields)))
              ((not (string= name "NAMES"))))
    name))

(defun pbt--parse-kubectl-pod-name (line)
  "Parse pod name from kubectl get pods output LINE.
Returns name or nil."
  (when-let* ((fields (split-string line nil 'omit-nulls))
              ((>= (length fields) 5))
              (name (car fields))
              ((not (string= name "NAME"))))
    name))

(ert-deftest pbt-docker-parse-extracts-name ()
  "Property: docker ps line parsing extracts container name."
  (dotimes (_ 50)
    (let* ((expected (concat "container-" (pbt--random-string 8)))
           (line (pbt--generate-docker-ps-line expected))
           (parsed (pbt--parse-docker-container-name line)))
      (should (equal parsed expected)))))

(ert-deftest pbt-kubectl-parse-extracts-name ()
  "Property: kubectl get pods line parsing extracts pod name."
  (dotimes (_ 50)
    (let* ((expected (concat "pod-" (pbt--random-string 8) "-" (pbt--random-string 5)))
           (line (pbt--generate-kubectl-pods-line expected))
           (parsed (pbt--parse-kubectl-pod-name line)))
      (should (equal parsed expected)))))

(ert-deftest pbt-docker-header-returns-nil ()
  "Property: docker ps header line returns nil."
  (let ((header "CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES"))
    (should (null (pbt--parse-docker-container-name header)))))

(ert-deftest pbt-kubectl-header-returns-nil ()
  "Property: kubectl get pods header line returns nil."
  (let ((header "NAME   READY   STATUS   RESTARTS   AGE"))
    (should (null (pbt--parse-kubectl-pod-name header)))))

;;; --- Consistency Property: All Parsers Return String|Nil ---

(ert-deftest pbt-all-parsers-return-string-or-nil ()
  "Property: all container name parsers return string or nil, never throw."
  (let ((test-inputs '(""
                       "   "
                       "single"
                       "1 2"
                       "a b c d e f g h i j k l m"
                       "NAME  something"
                       "Hostname")))
    (dolist (input test-inputs)
      ;; Bastille
      (let ((result (tramp-bastille--parse-jail-name input)))
        (should (or (null result) (stringp result))))
      ;; Docker
      (let ((result (pbt--parse-docker-container-name input)))
        (should (or (null result) (stringp result))))
      ;; Kubectl
      (let ((result (pbt--parse-kubectl-pod-name input)))
        (should (or (null result) (stringp result)))))))

(provide 'tramp-bastille-test)
;;; tramp-bastille-test.el ends here
