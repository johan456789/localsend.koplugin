#!/bin/bash
#
# Run all tests for localsend-cli (Go + Lua)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "  LocalSend CLI Test Suite"
echo "=============================================="
echo

# Track failures
FAILED=0

# ----------------------------------------------
# Go Tests (with race detector)
# ----------------------------------------------
echo -e "${YELLOW}Running Go unit tests with race detector...${NC}"
if go test ./... -race -count=1; then
    echo -e "${GREEN}✓ Go unit tests passed${NC}"
else
    echo -e "${RED}✗ Go unit tests failed${NC}"
    FAILED=1
fi
echo

# ----------------------------------------------
# Go Integration Tests (with race detector)
# ----------------------------------------------
echo -e "${YELLOW}Running Go integration tests with race detector...${NC}"
if go test ./internal/localsend/... -tags=integration -race -count=1; then
    echo -e "${GREEN}✓ Go integration tests passed${NC}"
else
    echo -e "${RED}✗ Go integration tests failed${NC}"
    FAILED=1
fi
echo

# ----------------------------------------------
# Lua Tests
# ----------------------------------------------
echo -e "${YELLOW}Running Lua tests...${NC}"
cd lua
if busted spec/; then
    echo -e "${GREEN}✓ Lua tests passed${NC}"
else
    echo -e "${RED}✗ Lua tests failed${NC}"
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
