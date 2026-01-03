#!/bin/bash
#
# Run all tests for localsend-cli (Go + Lua)
#
# Usage: ./test.sh [--verbose|-v]
#   --verbose, -v  Show all test output (default: only show failures)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
VERBOSE=0
for arg in "$@"; do
    case $arg in
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
    esac
done

echo "=============================================="
echo "  LocalSend CLI Test Suite"
echo "=============================================="
echo

# Track failures
FAILED=0

# Helper function to run tests quietly
# Usage: run_test "description" "command..."
run_test() {
    local desc="$1"
    shift
    local cmd=("$@")

    if [ $VERBOSE -eq 1 ]; then
        echo -e "${YELLOW}Running ${desc}...${NC}"
        if "${cmd[@]}"; then
            echo -e "${GREEN}✓ ${desc} passed${NC}"
            return 0
        else
            echo -e "${RED}✗ ${desc} failed${NC}"
            return 1
        fi
    else
        echo -ne "${YELLOW}Running ${desc}...${NC} "
        local output
        if output=$("${cmd[@]}" 2>&1); then
            echo -e "${GREEN}✓${NC}"
            return 0
        else
            echo -e "${RED}✗${NC}"
            echo -e "${RED}--- ${desc} output ---${NC}"
            echo "$output"
            echo -e "${RED}--- end output ---${NC}"
            return 1
        fi
    fi
}

# ----------------------------------------------
# Go Tests (with race detector)
# ----------------------------------------------
if ! run_test "Go unit tests (race)" go test ./... -race -count=1; then
    FAILED=1
fi

# ----------------------------------------------
# Go Integration Tests (with race detector)
# ----------------------------------------------
if ! run_test "Go integration tests (race)" go test ./internal/localsend/... -tags=integration -race -count=1; then
    FAILED=1
fi

# ----------------------------------------------
# Lua Tests
# ----------------------------------------------
cd lua
if ! run_test "Lua tests" busted spec/; then
    FAILED=1
fi
cd ..

echo
# ----------------------------------------------
# Summary
# ----------------------------------------------
echo "=============================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}  All tests passed!${NC}"
else
    echo -e "${RED}  Some tests failed${NC}"
fi
echo "=============================================="

exit $FAILED
