# The gate for this repository: what CI (.github/workflows/ci.yml) runs, with the same
# images. Run it before every commit.
BASH_BIN   := $(shell command -v /opt/homebrew/bin/bash 2>/dev/null || command -v bash)
ACTIONLINT = rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667
SHELLCHECK = koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
GITLEAKS   = zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f

.PHONY: check lint test pins secrets
check: lint pins test secrets

lint:
	docker run --rm -v "$$PWD:/repo:ro" -w /repo $(ACTIONLINT) -color
	docker run --rm -v "$$PWD:/mnt:ro" -w /mnt $(SHELLCHECK) scripts/*.sh
	jq -e . default.json > /dev/null

pins:
	$(BASH_BIN) scripts/check-pins.sh

test:
	$(BASH_BIN) scripts/ghcr-retention-selftest.sh

secrets:
	docker run --rm -v "$$PWD:/repo:ro" -w /repo $(GITLEAKS) dir --no-banner --redact /repo
