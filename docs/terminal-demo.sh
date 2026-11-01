#!/usr/bin/env bash
# A staged terminal session for the LCARS theme screenshot (docs/screenshots.sh).
# Prints made-up dev output in the theme's colours, then sits at a fake prompt.
# Run with bash so your own shell prompt and config never appear.

printf '\033]0;claude\007'
clear

r=$'\033[31m' g=$'\033[32m' y=$'\033[33m' b=$'\033[34m' m=$'\033[35m' c=$'\033[36m'
d=$'\033[90m' o=$'\033[0m' B=$'\033[1m'

prompt() { printf '%s\n' "${c}checkout-api${o} on ${m}feature/apple-pay${o} ${y}❯${o} $1"; }

prompt "git status"
cat <<OUT
On branch feature/apple-pay
Changes to be committed:
	${g}modified:   src/checkout/PaymentSheet.tsx${o}
	${g}new file:   src/checkout/applePay.ts${o}

Changes not staged for commit:
	${r}modified:   src/checkout/CartSummary.tsx${o}

Untracked files:
	${r}tests/applePay.test.ts${o}

OUT

prompt "git log --oneline --graph -5"
cat <<OUT
${r}*${o} ${y}a3f9c21${o} (${B}${c}HEAD -> ${g}feature/apple-pay${o}) Add Apple Pay payment sheet
${r}*${o} ${y}7be41d0${o} Extract card form into its own component
${r}*${o} ${y}c08d5e7${o} (${r}origin/main${o}, ${g}main${o}) Fix rounding in order totals
${r}*${o} ${y}19ac3b4${o} Bump stripe-js to 4.2.0
${r}*${o} ${y}e5d7720${o} Add checkout analytics events

OUT

prompt "npm test"
cat <<OUT
 ${B}PASS${o}  ${g}✓${o} tests/cart.test.ts ${d}(12 tests)${o}
 ${B}PASS${o}  ${g}✓${o} tests/totals.test.ts ${d}(8 tests)${o}
 ${B}FAIL${o}  ${r}✗${o} tests/applePay.test.ts

  ${r}●${o} applePay › completes payment with a valid token
    ${d}expect(${r}received${d}).toBe(${g}expected${d})${o}
    Expected: ${g}"succeeded"${o}
    Received: ${r}"requires_action"${o}

  ${y}○${o} ${y}skipped${o} applePay › handles a declined card

Tests:  ${r}1 failed${o}, ${y}1 skipped${o}, ${g}20 passed${o}, 22 total
Time:   ${b}2.41 s${o}

OUT

printf '%s' "$(prompt "")"
printf ' '
exec sleep 100000
