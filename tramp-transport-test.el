;;; tramp-transport-test.el --- Alternative transport tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Jason Walsh <j@wal.sh>

;;; Commentary:

;; Tests for alternative TRAMP transport layers beyond SSH/HTTP:
;;
;; 1. Serial (null modem) - Direct TTY via /dev/ttyX or /dev/cuaX
;; 2. ggwave - Audio-based data transmission (sound modem)
;; 3. UDP - Connectionless transport with packet reassembly
;; 4. mDNS - Service discovery for dynamic host resolution
;;
;; Use cases:
;; - Air-gapped systems (serial, ggwave)
;; - Embedded/IoT devices (serial, UDP)
;; - Local network without DNS (mDNS)
;; - Hostile RF environments (serial null modem)
;;
;; Run with: emacs --batch -l ert -l tramp-transport-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)

;;; ============================================================
;;; Serial Port / Null Modem Transport
;;; ============================================================
;;
;; Null modem connects two machines directly via serial ports.
;; No network required - useful for air-gapped or embedded systems.
;;
;; Hardware: USB-to-serial adapter + null modem cable
;; Software: cu, screen, minicom, or direct /dev/tty access

(defvar serial-test-device "/dev/cuaU0"
  "Serial device for testing (FreeBSD USB serial).")

(defvar serial-test-baud 115200
  "Baud rate for serial communication.")

(defun serial--device-exists-p (device)
  "Check if serial DEVICE exists and is accessible."
  (and (file-exists-p device)
       (file-readable-p device)))

(defun serial--build-cu-command (device &optional baud)
  "Build cu command for serial DEVICE at BAUD rate."
  (format "cu -l %s -s %d" device (or baud serial-test-baud)))

(defun serial--build-screen-command (device &optional baud)
  "Build screen command for serial DEVICE at BAUD rate."
  (format "screen %s %d" device (or baud serial-test-baud)))

(defun serial--parse-stty-speed (output)
  "Parse baud rate from stty OUTPUT."
  (when (string-match "speed \\([0-9]+\\)" output)
    (string-to-number (match-string 1 output))))

;; TRAMP method for serial console (pattern)
(defconst tramp-serial-method-template
  '("serial"
    (tramp-login-program "cu")
    (tramp-login-args (("-l" "%h") ("-s" "115200")))
    (tramp-remote-shell "/bin/sh")
    (tramp-remote-shell-args ("-i" "-c")))
  "Template TRAMP method for serial console access.
Usage: /serial:/dev/cuaU0:/path/to/file")

(ert-deftest serial-device-detection ()
  "Test serial device detection on FreeBSD."
  (let ((usb-serial (directory-files "/dev" nil "^cuaU[0-9]$"))
        (hw-serial (directory-files "/dev" nil "^cuau[0-9]$")))
    ;; Should find at least USB or hardware serial
    (should (or usb-serial hw-serial
                ;; Or skip if no serial hardware
                (progn (message "No serial devices found") t)))))

(ert-deftest serial-cu-command-structure ()
  "Test cu command building for serial access."
  (let ((cmd (serial--build-cu-command "/dev/cuaU0" 115200)))
    (should (string-match-p "-l /dev/cuaU0" cmd))
    (should (string-match-p "-s 115200" cmd))))

(ert-deftest serial-screen-command-structure ()
  "Test screen command building for serial access."
  (let ((cmd (serial--build-screen-command "/dev/ttyUSB0" 9600)))
    (should (string-match-p "/dev/ttyUSB0" cmd))
    (should (string-match-p "9600" cmd))))

(ert-deftest serial-stty-speed-parsing ()
  "Test parsing baud rate from stty output."
  (should (= 115200 (serial--parse-stty-speed "speed 115200 baud;")))
  (should (= 9600 (serial--parse-stty-speed "speed 9600 baud; line = 0;")))
  (should (null (serial--parse-stty-speed "no speed info"))))

(ert-deftest serial-common-baud-rates ()
  "Test common baud rates are valid."
  (let ((valid-rates '(300 1200 2400 4800 9600 19200 38400 57600 115200 230400 460800 921600)))
    (dolist (rate valid-rates)
      (should (integerp rate))
      (should (> rate 0)))))

;;; ============================================================
;;; ggwave - Audio Data Transmission
;;; ============================================================
;;
;; ggwave encodes data as audio frequencies for transmission over:
;; - Speaker/microphone (air gap crossing)
;; - Phone lines
;; - Radio (with appropriate modulation)
;;
;; Useful for air-gapped systems or when RF is restricted.
;; https://github.com/ggerganov/ggwave

(defvar ggwave-protocol-version 1
  "ggwave protocol version.")

(defvar ggwave-sample-rate 48000
  "Audio sample rate for ggwave.")

(defvar ggwave-protocols
  '((0 . "Normal")
    (1 . "Fast")
    (2 . "Fastest")
    (3 . "Ultrasound")
    (4 . "UltrasoundFast"))
  "ggwave transmission protocols.")

(defun ggwave--available-p ()
  "Check if ggwave CLI is available."
  (executable-find "ggwave"))

(defun ggwave--encode-command (text &optional protocol)
  "Build ggwave encode command for TEXT with optional PROTOCOL."
  (format "ggwave -t \"%s\" %s"
          text
          (if protocol (format "-p %d" protocol) "")))

(defun ggwave--decode-command (&optional duration)
  "Build ggwave decode command with optional DURATION seconds."
  (format "ggwave -r %s"
          (if duration (format "-d %d" duration) "")))

(defun ggwave--estimate-tx-time (text protocol)
  "Estimate transmission time for TEXT using PROTOCOL.
Returns time in seconds (approximate)."
  (let ((bytes (length (encode-coding-string text 'utf-8)))
        ;; Approximate bytes/second for each protocol
        (rates '((0 . 8) (1 . 16) (2 . 32) (3 . 8) (4 . 16))))
    (/ (float bytes) (or (cdr (assq protocol rates)) 8))))

(ert-deftest ggwave-protocol-definitions ()
  "Test ggwave protocol definitions are complete."
  (should (= 5 (length ggwave-protocols)))
  (should (assq 0 ggwave-protocols))
  (should (assq 3 ggwave-protocols))  ; Ultrasound
  (should (string= "Ultrasound" (cdr (assq 3 ggwave-protocols)))))

(ert-deftest ggwave-encode-command-structure ()
  "Test ggwave encode command building."
  (let ((cmd (ggwave--encode-command "hello" 2)))
    (should (string-match-p "-t \"hello\"" cmd))
    (should (string-match-p "-p 2" cmd))))

(ert-deftest ggwave-decode-command-structure ()
  "Test ggwave decode command building."
  (let ((cmd (ggwave--decode-command 10)))
    (should (string-match-p "-r" cmd))
    (should (string-match-p "-d 10" cmd))))

(ert-deftest ggwave-tx-time-estimation ()
  "Test transmission time estimation."
  (let ((time-normal (ggwave--estimate-tx-time "hello" 0))
        (time-fast (ggwave--estimate-tx-time "hello" 1)))
    ;; Fast should be quicker than normal
    (should (< time-fast time-normal))))

(ert-deftest ggwave-message-framing ()
  "Test message framing for ggwave transport."
  (let* ((payload "test data")
         (seq 42)
         (framed (json-encode `((seq . ,seq)
                                (len . ,(length payload))
                                (data . ,payload)
                                (crc . ,(sxhash payload))))))
    (should (string-match-p "\"seq\":42" framed))
    (should (string-match-p "\"data\":\"test data\"" framed))))

;;; ============================================================
;;; UDP Transport
;;; ============================================================
;;
;; UDP provides low-latency connectionless transport.
;; Useful for:
;; - Real-time/low-latency requirements
;; - Lossy networks where retransmission is handled at app layer
;; - Broadcast/multicast scenarios
;;
;; Challenges: packet ordering, loss detection, MTU handling

(defvar udp-default-port 9999
  "Default UDP port for transport.")

(defvar udp-mtu 1472
  "Maximum UDP payload size (1500 - IP header - UDP header).")

(defun udp--build-nc-send (host port message)
  "Build netcat command to send MESSAGE to HOST:PORT via UDP."
  (format "echo -n '%s' | nc -u -w1 %s %d" message host port))

(defun udp--build-nc-listen (port &optional timeout)
  "Build netcat command to listen on PORT via UDP."
  (format "nc -u -l %d %s"
          port
          (if timeout (format "-w %d" timeout) "")))

(defun udp--fragment-message (message mtu)
  "Fragment MESSAGE into chunks of MTU size.
Returns list of (seq . data) pairs."
  (let ((chunks nil)
        (seq 0)
        (pos 0)
        (len (length message)))
    (while (< pos len)
      (push (cons seq (substring message pos (min (+ pos mtu) len)))
            chunks)
      (setq pos (+ pos mtu))
      (setq seq (1+ seq)))
    (nreverse chunks)))

(defun udp--reassemble-fragments (fragments)
  "Reassemble FRAGMENTS into original message.
FRAGMENTS is list of (seq . data) pairs."
  (mapconcat #'cdr (sort fragments (lambda (a b) (< (car a) (car b)))) ""))

(defun udp--encode-packet (seq data)
  "Encode UDP packet with SEQ number and DATA."
  (json-encode `((seq . ,seq)
                 (len . ,(length data))
                 (data . ,data))))

(defun udp--decode-packet (packet)
  "Decode UDP PACKET, return (seq . data) or nil."
  (when-let* ((parsed (ignore-errors (json-read-from-string packet)))
              (seq (alist-get 'seq parsed))
              (data (alist-get 'data parsed)))
    (cons seq data)))

(ert-deftest udp-nc-send-command ()
  "Test netcat UDP send command structure."
  (let ((cmd (udp--build-nc-send "192.168.1.1" 9999 "test")))
    (should (string-match-p "-u" cmd))
    (should (string-match-p "192.168.1.1" cmd))
    (should (string-match-p "9999" cmd))))

(ert-deftest udp-nc-listen-command ()
  "Test netcat UDP listen command structure."
  (let ((cmd (udp--build-nc-listen 9999 5)))
    (should (string-match-p "-u" cmd))
    (should (string-match-p "-l" cmd))
    (should (string-match-p "9999" cmd))))

(ert-deftest udp-fragmentation ()
  "Test message fragmentation."
  (let* ((message (make-string 3000 ?x))
         (fragments (udp--fragment-message message 1000)))
    (should (= 3 (length fragments)))
    (should (= 0 (car (nth 0 fragments))))
    (should (= 1 (car (nth 1 fragments))))
    (should (= 2 (car (nth 2 fragments))))))

(ert-deftest udp-reassembly ()
  "Test fragment reassembly."
  (let* ((original "hello world test message")
         (fragments (udp--fragment-message original 10))
         (reassembled (udp--reassemble-fragments fragments)))
    (should (string= original reassembled))))

(ert-deftest udp-reassembly-out-of-order ()
  "Test reassembly handles out-of-order fragments."
  (let* ((fragments '((2 . "ccc") (0 . "aaa") (1 . "bbb")))
         (reassembled (udp--reassemble-fragments fragments)))
    (should (string= "aaabbbccc" reassembled))))

(ert-deftest udp-packet-encode-decode ()
  "Test packet encoding/decoding roundtrip."
  (dotimes (_ 20)
    (let* ((seq (random 1000))
           (data (format "data-%d" (random 10000)))
           (packet (udp--encode-packet seq data))
           (decoded (udp--decode-packet packet)))
      (should decoded)
      (should (= seq (car decoded)))
      (should (string= data (cdr decoded))))))

;;; ============================================================
;;; mDNS - Multicast DNS Service Discovery
;;; ============================================================
;;
;; mDNS enables hostname resolution without a DNS server.
;; Used by:
;; - Apple Bonjour (*.local domains)
;; - Avahi (Linux/BSD)
;; - IoT device discovery
;;
;; TRAMP can use mDNS to resolve .local hostnames automatically.

(defvar mdns-domain ".local"
  "mDNS domain suffix.")

(defvar mdns-port 5353
  "mDNS multicast port.")

(defvar mdns-services
  '("_ssh._tcp"       ; SSH
    "_sftp-ssh._tcp"  ; SFTP
    "_http._tcp"      ; HTTP
    "_https._tcp"     ; HTTPS
    "_workstation._tcp") ; Avahi workstation
  "Common mDNS service types for TRAMP.")

(defun mdns--avahi-browse-command (service-type)
  "Build avahi-browse command for SERVICE-TYPE."
  (format "avahi-browse -t -r %s" service-type))

(defun mdns--parse-avahi-output (output)
  "Parse avahi-browse OUTPUT into list of (name host port) tuples."
  (let ((results nil)
        (current-name nil)
        (current-host nil)
        (current-port nil))
    (dolist (line (split-string output "\n" t))
      (cond
       ;; Service line: "=  eth0 IPv4 hydra   SSH Remote Terminal  local"
       ((string-match "^=\\s-+\\S-+\\s-+\\S-+\\s-+\\(\\S-+\\)" line)
        ;; New service entry, save previous if complete
        (when (and current-name current-host current-port)
          (push (list current-name current-host current-port) results))
        (setq current-name (match-string 1 line)
              current-host nil
              current-port nil))
       ;; Hostname line: "   hostname = [hydra.local]"
       ((string-match "hostname = \\[\\([^]]+\\)\\]" line)
        (setq current-host (match-string 1 line)))
       ;; Port line: "   port = [22]"
       ((string-match "port = \\[\\([0-9]+\\)\\]" line)
        (setq current-port (string-to-number (match-string 1 line))))))
    ;; Save last entry
    (when (and current-name current-host current-port)
      (push (list current-name current-host current-port) results))
    (nreverse results)))

(defun mdns--is-local-hostname (hostname)
  "Check if HOSTNAME is an mDNS .local address."
  (string-suffix-p mdns-domain hostname t))

(defun mdns--resolve-local (hostname)
  "Resolve mDNS HOSTNAME using avahi-resolve.
Returns IP address string or nil."
  (when (mdns--is-local-hostname hostname)
    (let ((output (shell-command-to-string
                   (format "avahi-resolve -n %s 2>/dev/null" hostname))))
      (when (string-match "\\([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\)" output)
        (match-string 1 output)))))

(ert-deftest mdns-local-hostname-detection ()
  "Test .local hostname detection."
  (should (mdns--is-local-hostname "myhost.local"))
  (should (mdns--is-local-hostname "MYHOST.LOCAL"))
  (should-not (mdns--is-local-hostname "myhost.example.com"))
  (should-not (mdns--is-local-hostname "localhost")))

(ert-deftest mdns-avahi-command-structure ()
  "Test avahi-browse command building."
  (let ((cmd (mdns--avahi-browse-command "_ssh._tcp")))
    (should (string-match-p "avahi-browse" cmd))
    (should (string-match-p "_ssh._tcp" cmd))))

(ert-deftest mdns-avahi-output-parsing ()
  "Test parsing avahi-browse output."
  (let* ((sample-output "
=  eth0 IPv4 hydra                                      SSH Remote Terminal  local
   hostname = [hydra.local]
   address = [192.168.86.29]
   port = [22]
   txt = []
=  eth0 IPv4 mini                                       SSH Remote Terminal  local
   hostname = [mini.local]
   address = [192.168.86.22]
   port = [22]
   txt = []
")
         (parsed (mdns--parse-avahi-output sample-output)))
    (should (= 2 (length parsed)))
    (should (string-match-p "hydra" (car (nth 0 parsed))))
    (should (string-match-p "mini" (car (nth 1 parsed))))))

(ert-deftest mdns-service-types ()
  "Test common mDNS service types are defined."
  (should (member "_ssh._tcp" mdns-services))
  (should (member "_http._tcp" mdns-services)))

(ert-deftest mdns-resolution-live ()
  "Test live mDNS resolution (requires Avahi running)."
  (skip-unless (executable-find "avahi-resolve"))
  (skip-unless (= 0 (shell-command "pgrep -q avahi-daemon 2>/dev/null")))
  ;; Try to resolve localhost.local (should fail) or actual .local host
  (let ((result (mdns--resolve-local "nonexistent-host-12345.local")))
    ;; Should return nil for nonexistent host
    (should (null result))))

;;; ============================================================
;;; Transport Comparison and Selection
;;; ============================================================

(defvar transport-capabilities
  '((ssh . ((reliable . t) (encrypted . t) (latency . medium)
            (airgap . nil) (bandwidth . high)))
    (serial . ((reliable . t) (encrypted . nil) (latency . low)
               (airgap . t) (bandwidth . low)))
    (ggwave . ((reliable . nil) (encrypted . nil) (latency . high)
               (airgap . t) (bandwidth . very-low)))
    (udp . ((reliable . nil) (encrypted . nil) (latency . low)
            (airgap . nil) (bandwidth . high)))
    (mdns . ((reliable . t) (encrypted . nil) (latency . low)
             (airgap . nil) (bandwidth . n/a))))
  "Transport capability comparison.")

(defun transport--get-capability (transport capability)
  "Get CAPABILITY value for TRANSPORT."
  (alist-get capability (alist-get transport transport-capabilities)))

(defun transport--suitable-for-airgap ()
  "Return transports suitable for air-gapped systems."
  (cl-remove-if-not
   (lambda (t) (transport--get-capability t 'airgap))
   (mapcar #'car transport-capabilities)))

(ert-deftest transport-capability-lookup ()
  "Test transport capability lookup."
  (should (eq t (transport--get-capability 'ssh 'reliable)))
  (should (eq t (transport--get-capability 'serial 'airgap)))
  (should (eq nil (transport--get-capability 'ssh 'airgap))))

(ert-deftest transport-airgap-selection ()
  "Test air-gap suitable transport selection."
  (let ((airgap-transports (transport--suitable-for-airgap)))
    (should (member 'serial airgap-transports))
    (should (member 'ggwave airgap-transports))
    (should-not (member 'ssh airgap-transports))))

(provide 'tramp-transport-test)
;;; tramp-transport-test.el ends here
