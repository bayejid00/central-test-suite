#!/usr/bin/env bash

set -euo pipefail

########################################
# 0. Configuration & Constants
########################################

# Define excluded directories
EXCLUDE_DIRS=(
    "node_modules"
    ".git"
    ".github"
    "vendor"
    "tests"
    "dist"
    "build"
    "gutenberg-reports"
    "security-reports"
    "qa-reports"
)

# Build find exclusion patterns dynamically
FIND_EXCLUDES=""
for dir in "${EXCLUDE_DIRS[@]}"; do
    FIND_EXCLUDES="${FIND_EXCLUDES} ! -path '*/${dir}/*'"
done

# Build grep exclusion pattern dynamically
GREP_EXCLUDES="/($(IFS='|'; echo "${EXCLUDE_DIRS[*]}"))"

########################################
# 1. Input validation & argument parsing
########################################

PLUGIN_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -*)
            echo "❌ Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$PLUGIN_ROOT" ]; then
                PLUGIN_ROOT="$1"
            else
                echo "❌ Multiple plugin paths provided"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$PLUGIN_ROOT" ]; then
    echo "❌ Usage: $0 <path-to-plugin>"
    echo
    echo "Examples:"
    echo "  $0 ../wp-content/plugins/my-gutenberg-plugin"
    exit 1
fi

########################################
# 2. Resolve paths safely
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$PLUGIN_ROOT" = /* ]]; then
    PLUGIN_ROOT="$(cd "$PLUGIN_ROOT" && pwd)"
else
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/$PLUGIN_ROOT" && pwd)"
fi

if [ ! -d "$PLUGIN_ROOT" ]; then
    echo "❌ Error: Plugin directory not found:"
    echo "   $PLUGIN_ROOT"
    exit 1
fi

PLUGIN_NAME="$(basename "$PLUGIN_ROOT")"

# Reports are generated in the same directory as this script
REPORT_BASE="$SCRIPT_DIR/gutenberg-reports"
REPORT_DIR="$REPORT_BASE/$PLUGIN_NAME"

mkdir -p "$REPORT_DIR"

########################################
# 3. Header
########################################

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        📖 WordPress Gutenberg Block Code Checker                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 Plugin: $PLUGIN_NAME"
echo "📂 Plugin root: $PLUGIN_ROOT"
echo "📋 Reports directory: $REPORT_DIR"
echo "🕐 Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "────────────────────────────────────────────────────────────────────"

########################################
# 4. Dependency Installation
########################################

if [ -f "$PLUGIN_ROOT/package.json" ] && [ ! -d "$PLUGIN_ROOT/node_modules" ]; then
    echo "➡️  package.json found, running npm install..."
    (cd "$PLUGIN_ROOT" && npm install) > "$REPORT_DIR/00-npm-install.txt" 2>&1
    echo "   ✅ npm install complete."
fi

########################################
# 5. PHP Coding Standards
########################################

echo "➡️  Running PHP Coding Standards (WordPress)..."

phpcs "$PLUGIN_ROOT" \
  --standard=WordPress \
  --extensions=php \
  --ignore=*/vendor/*,*/node_modules/*,*/build/*,*/.git/*,*/gutenberg-reports/*,*/dist/*,*/tests/* \
  --report=full \
  > "$REPORT_DIR/01-phpcs-wordpress.txt" 2>&1 || true

PHPCS_ERRORS=$(grep -c "ERROR" "$REPORT_DIR/01-phpcs-wordpress.txt" || echo "0")
PHPCS_WARNINGS=$(grep -c "WARNING" "$REPORT_DIR/01-phpcs-wordpress.txt" || echo "0")

echo "   Found $PHPCS_ERRORS errors and $PHPCS_WARNINGS warnings."

########################################
# 6. JavaScript Coding Standards (ESLint)
########################################

echo "➡️  Running JavaScript Coding Standards (ESLint)..."

if [ -f "$PLUGIN_ROOT/node_modules/.bin/eslint" ]; then
    "$PLUGIN_ROOT/node_modules/.bin/eslint" . \
      --ext .js,.jsx,.ts,.tsx \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/' \
      --format stylish \
      > "$REPORT_DIR/02-eslint.txt" 2>&1 || true
    ESLINT_PROBLEMS=$(grep -c "problem" "$REPORT_DIR/02-eslint.txt" || echo "0")
    echo "   Found $ESLINT_PROBLEMS problems."
else
    echo "   ⚠️  ESLint not found, skipping."
    echo "ESLint not found. Please add it as a dev dependency to your package.json" > "$REPORT_DIR/02-eslint.txt"
fi

########################################
# 7. CSS/SCSS Coding Standards (Stylelint)
########################################

echo "➡️  Running CSS/SCSS Coding Standards (Stylelint)..."

if [ -f "$PLUGIN_ROOT/node_modules/.bin/stylelint" ]; then
    "$PLUGIN_ROOT/node_modules/.bin/stylelint" "**/*.{css,scss}" \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/' \
      --custom-formatter stylish \
      > "$REPORT_DIR/03-stylelint.txt" 2>&1 || true
    STYLELINT_PROBLEMS=$(grep -c "✖" "$REPORT_DIR/03-stylelint.txt" || echo "0")
    echo "   Found $STYLELINT_PROBLEMS problems."
else
    echo "   ⚠️  Stylelint not found, skipping."
    echo "Stylelint not found. Please add it as a dev dependency to your package.json" > "$REPORT_DIR/03-stylelint.txt"
fi

########################################
# 8. Jest Tests
########################################

echo "➡️  Running Jest tests..."

if [ -f "$PLUGIN_ROOT/package.json" ] && grep -q '"test":' "$PLUGIN_ROOT/package.json"; then
    (cd "$PLUGIN_ROOT" && npm test -- --ci --json --outputFile="$REPORT_DIR/04-jest-results.json") > "$REPORT_DIR/04-jest.txt" 2>&1 || true
    JEST_TESTS=$(jq '.numTotalTests' "$REPORT_DIR/04-jest-results.json" 2>/dev/null || echo "0")
    JEST_FAILED=$(jq '.numFailedTests' "$REPORT_DIR/04-jest-results.json" 2>/dev/null || echo "0")
    echo "   Ran $JEST_TESTS tests, $JEST_FAILED failed."
else
    echo "   ⚠️  No Jest test script found in package.json, skipping."
    echo "No Jest test script found in package.json." > "$REPORT_DIR/04-jest.txt"
fi

########################################
# 9. Summary Report
########################################

echo "➡️  Generating summary report..."

{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           GUTENBERG BLOCK CODE ANALYSIS SUMMARY                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Plugin: $PLUGIN_NAME"
    echo "Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "SUMMARY"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "PHPCS (WordPress): $PHPCS_ERRORS errors, $PHPCS_WARNINGS warnings"
    echo "ESLint: $ESLINT_PROBLEMS problems found"
    echo "Stylelint: $STYLELINT_PROBLEMS problems found"
    if [ -f "$PLUGIN_ROOT/package.json" ] && grep -q '"test":' "$PLUGIN_ROOT/package.json"; then
        echo "Jest Tests: $JEST_TESTS tests run, $JEST_FAILED failed"
    else
        echo "Jest Tests: Not run (no test script found)"
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "DETAILED REPORTS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    for report in "$REPORT_DIR"/*.txt; do
        if [ -f "$report" ]; then
            echo "📄 $(basename "$report")"
        fi
    done
    if [ -f "$REPORT_DIR/04-jest-results.json" ]; then
        echo "📄 $(basename "$REPORT_DIR/04-jest-results.json")"
    fi

} > "$REPORT_DIR/00-SUMMARY.txt"

########################################
# 10. Final Summary
########################################

echo "────────────────────────────────────────────────────────────────────"
echo "✅ Gutenberg block code analysis completed for: $PLUGIN_NAME"
echo ""
echo "📌 Reports generated in: $REPORT_DIR"
echo ""
echo "📄 Report files:"
ls -1 "$REPORT_DIR" | while read -r file; do
    echo "   - $file"
done
echo ""
echo "📊 Quick view summary: cat $REPORT_DIR/00-SUMMARY.txt"
echo "────────────────────────────────────────────────────────────────────"
