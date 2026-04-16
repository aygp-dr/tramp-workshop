.PHONY: lint test test-pbt test-all clean

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

# Run all tests
test-all: test test-pbt

clean:
	rm -f *.elc
