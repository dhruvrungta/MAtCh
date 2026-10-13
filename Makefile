SHELL := /bin/bash

PROJECT   := Match.xcodeproj
SCHEME    := Match
DERIVED   := build/DerivedData
APP       := $(DERIVED)/Build/Products/Debug/Match.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Match.app
MOCK_HOST ?= 127.0.0.1
MOCK_PORT ?= 8765
MOCK_BASE ?= http://127.0.0.1:$(MOCK_PORT)
SIGN_NAME := Match Self-Signed

# Every build is signed with the stable self-signed identity when it is installed.
# Without it (CI, or before tools/make_signing_cert.sh has been run) fall back to
# ad-hoc signing and say so.
HAVE_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -c '"$(SIGN_NAME)"')
ifeq ($(HAVE_IDENTITY),0)
SIGN_OVERRIDE := CODE_SIGN_IDENTITY=-
$(warning "$(SIGN_NAME)" is not in the keychain: signing ad-hoc. Run tools/make_signing_cert.sh once to fix this.)
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)' \
	$(SIGN_OVERRIDE)

# Keeps compiler diagnostics and test results; drops the rest of xcodebuild's output.
TEST_FILTER := grep -E '^/.*: (error|warning):|^(✘|✔ Suite|✔ Test run)|Testing failed|\*\* TEST'

.PHONY: gen build check-names test run mock run-mock test-mock check-release clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCODEBUILD) -configuration Debug -quiet build

# Fails if the reference project's name appears anywhere outside SPEC.md and README.md,
# or in any commit message. The pattern is written with a bracket so this file passes.
check-names:
	@if grep -rniI 'l[a]tch' --exclude=SPEC.md --exclude=README.md --exclude-dir=.git --exclude-dir=build --exclude-dir=DerivedData . ; then \
		echo "check-names: forbidden name found in the files above"; exit 1; \
	fi
	@if git rev-parse --git-dir >/dev/null 2>&1 && git log --format=%B 2>/dev/null | grep -iq 'l[a]tch'; then \
		echo "check-names: forbidden name found in a commit message"; exit 1; \
	fi
	@echo "check-names: ok"

test: check-names gen
	@set -o pipefail; $(XCODEBUILD) -configuration Debug test 2>&1 | $(TEST_FILTER)

run: build
	-pkill -x Match
	open -n $(APP)

mock:
	python3 tools/mock_portal.py --host $(MOCK_HOST) --port $(MOCK_PORT)

run-mock: build
	-pkill -x Match
	open -n $(APP) --args -MatchPortalBase $(MOCK_BASE)

# Runs the end-to-end tests against a mock portal started for the occasion.
test-mock: check-names gen
	@python3 tools/mock_portal.py --host $(MOCK_HOST) --port $(MOCK_PORT) --quiet & \
	MOCK_PID=$$!; trap "kill $$MOCK_PID 2>/dev/null" EXIT; sleep 1; \
	set -o pipefail; TEST_RUNNER_MATCH_MOCK_BASE=$(MOCK_BASE) $(XCODEBUILD) -configuration Debug test \
		-only-testing:MatchTests/MockPortalTests 2>&1 | $(TEST_FILTER)

# Proves that the Release build carries no trace of the debug-only portal override.
check-release: gen
	$(XCODEBUILD) -configuration Release -quiet build
	@if strings -a $(RELEASE_APP)/Contents/MacOS/Match | grep -q 'MatchPortalBase'; then \
		echo "check-release: the Release binary contains the debug portal override"; exit 1; \
	fi
	@echo "check-release: ok"

clean:
	rm -rf build
