.PHONY: lint test test-pbt test-pty test-transport test-all clean

EMACS ?= emacs

# Byte-compile check
lint:
	$(EMACS) -Q --batch \
		-L . \
		-f batch-byte-compile \
		tramp-bastille.el \
		tramp-bastille-workshop.el

# Basic load test
test:
	$(EMACS) -Q --batch \
		-L . \
		--eval '(require (quote tramp))' \
		--eval '(require (quote tramp-bastille))' \
		--eval '(require (quote tramp-bastille-workshop))' \
		--eval '(message "tramp-bastille loaded OK")' \
		--eval '(cl-assert (assoc "bastille" tramp-methods))' \
		--eval '(cl-assert (assoc "jexec" tramp-methods))' \
		--eval '(message "All assertions passed")'

# Property-based tests for parsing functions
test-pbt:
	$(EMACS) -Q --batch \
		-L . \
		-l ert \
		-l tramp-bastille.el \
		-l tramp-bastille-test.el \
		-f ert-run-tests-batch-and-exit

# PTY/terminal tests (requires running jails)
test-pty:
	$(EMACS) -Q --batch \
		-L . \
		-l ert \
		-l tramp-pty-test.el \
		-f ert-run-tests-batch-and-exit

# Alternative transport tests (serial, ggwave, UDP, mDNS)
test-transport:
	$(EMACS) -Q --batch \
		-L . \
		-l ert \
		-l tramp-transport-test.el \
		-f ert-run-tests-batch-and-exit

# Run all tests
test-all: test test-pbt test-pty test-transport

clean:
	rm -f *.elc
