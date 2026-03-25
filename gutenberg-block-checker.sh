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
# 4. Statistics
########################################

echo "➡️  Gathering plugin statistics..."

# Count files
TOTAL_PHP_FILES=$(eval "find \"\$PLUGIN_ROOT\" -type f -name \"*.php\" $FIND_EXCLUDES" | wc -l | tr -d ' ')
TOTAL_JS_FILES=$(eval "find \"\$PLUGIN_ROOT\" -type f \\( -name \"*.js\" -o -name \"*.jsx\" -o -name \"*.ts\" -o -name \"*.tsx\" \\) $FIND_EXCLUDES" | wc -l | tr -d ' ')
TOTAL_CSS_FILES=$(eval "find \"\$PLUGIN_ROOT\" -type f \\( -name \"*.css\" -o -name \"*.scss\" \\) $FIND_EXCLUDES" | wc -l | tr -d ' ')
TOTAL_PHP_LINES=$(eval "find \"\$PLUGIN_ROOT\" -type f -name \"*.php\" $FIND_EXCLUDES -exec cat {} \;" 2>/dev/null | wc -l | tr -d ' ')

cat > "$REPORT_DIR/00-statistics.txt" <<EOF
Plugin Statistics
=================
Plugin Name: $PLUGIN_NAME
Total PHP Files: $TOTAL_PHP_FILES
Total JavaScript/TypeScript Files: $TOTAL_JS_FILES
Total CSS/SCSS Files: $TOTAL_CSS_FILES
Total PHP Lines: $TOTAL_PHP_LINES
Excluded Directories: ${EXCLUDE_DIRS[*]}
Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')
EOF

echo "   ✓ Found $TOTAL_PHP_FILES PHP files, $TOTAL_JS_FILES JS/TS files, $TOTAL_CSS_FILES CSS/SCSS files"

########################################
# 5. Dependency Installation
########################################

if [ -f "$PLUGIN_ROOT/package.json" ] && [ ! -d "$PLUGIN_ROOT/node_modules" ]; then
    echo "➡️  package.json found, running npm install..."
    (cd "$PLUGIN_ROOT" && npm install) > "$REPORT_DIR/01-npm-install.txt" 2>&1
    echo "   ✅ npm install complete."
fi

########################################
# 6. PHP Coding Standards
########################################

echo "➡️  Running PHP Coding Standards (WordPress)..."

{
    echo "PHP Coding Standards (WordPress)"
    echo "================================="
    echo "Standard: WordPress"
    echo "Checked: PHP files (excluding vendor, node_modules, build, dist, tests)"
    echo ""
    echo "Full Report:"
    echo "-------------"
} > "$REPORT_DIR/02-phpcs-wordpress.txt"

phpcs "$PLUGIN_ROOT" \
  --standard=WordPress \
  --extensions=php \
  --ignore=*/vendor/*,*/node_modules/*,*/build/*,*/.git/*,*/gutenberg-reports/*,*/dist/*,*/tests/* \
  --report=full \
  >> "$REPORT_DIR/02-phpcs-wordpress.txt" 2>&1 || true

# Generate summary report
phpcs "$PLUGIN_ROOT" \
  --standard=WordPress \
  --extensions=php \
  --ignore=*/vendor/*,*/node_modules/*,*/build/*,*/.git/*,*/gutenberg-reports/*,*/dist/*,*/tests/* \
  --report=summary \
  >> "$REPORT_DIR/02-phpcs-wordpress.txt" 2>&1 || true

PHPCS_ERRORS=$(grep -c "ERROR" "$REPORT_DIR/02-phpcs-wordpress.txt" || echo "0")
PHPCS_WARNINGS=$(grep -c "WARNING" "$REPORT_DIR/02-phpcs-wordpress.txt" || echo "0")

if [ "$PHPCS_ERRORS" -gt 0 ] || [ "$PHPCS_WARNINGS" -gt 0 ]; then
    echo "   ⚠️  Found $PHPCS_ERRORS errors and $PHPCS_WARNINGS warnings"
else
    echo "   ✅ No coding standard violations found"
fi

########################################
# 7. JavaScript Coding Standards (ESLint)
########################################

echo "➡️  Running JavaScript Coding Standards (ESLint)..."

if [ -f "$PLUGIN_ROOT/node_modules/.bin/eslint" ]; then
    {
        echo "JavaScript Coding Standards (ESLint)"
        echo "====================================="
        echo "Extensions: .js, .jsx, .ts, .tsx"
        echo "Excluded: build/, dist/, vendor/, node_modules/"
        echo ""
        echo "Stylish Report:"
        echo "---------------"
    } > "$REPORT_DIR/03-eslint.txt"
    
    (cd "$PLUGIN_ROOT" && "$PLUGIN_ROOT/node_modules/.bin/eslint" . \
      --ext .js,.jsx,.ts,.tsx \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/' \
      --format stylish) >> "$REPORT_DIR/03-eslint.txt" 2>&1 || true
    
    # Generate JSON report for detailed analysis
    (cd "$PLUGIN_ROOT" && "$PLUGIN_ROOT/node_modules/.bin/eslint" . \
      --ext .js,.jsx,.ts,.tsx \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/' \
      --format json \
      --output-file "$REPORT_DIR/03-eslint-results.json") 2>&1 || true
    
    ESLINT_ERRORS=$(jq '[.[].messages[] | select(.severity==2)] | length' "$REPORT_DIR/03-eslint-results.json" 2>/dev/null || echo "0")
    ESLINT_WARNINGS=$(jq '[.[].messages[] | select(.severity==1)] | length' "$REPORT_DIR/03-eslint-results.json" 2>/dev/null || echo "0")
    ESLINT_PROBLEMS=$((ESLINT_ERRORS + ESLINT_WARNINGS))
    
    if [ "$ESLINT_PROBLEMS" -gt 0 ]; then
        echo "   ⚠️  Found $ESLINT_ERRORS errors and $ESLINT_WARNINGS warnings"
    else
        echo "   ✅ No linting issues found"
    fi
else
    echo "   ⚠️  ESLint not found, skipping."
    echo "ESLint not found. Please add it as a dev dependency to your package.json" > "$REPORT_DIR/03-eslint.txt"
    ESLINT_ERRORS=0
    ESLINT_WARNINGS=0
    ESLINT_PROBLEMS=0
fi

########################################
# 8. CSS/SCSS Coding Standards (Stylelint)
########################################

echo "➡️  Running CSS/SCSS Coding Standards (Stylelint)..."

if [ -f "$PLUGIN_ROOT/node_modules/.bin/stylelint" ]; then
    {
        echo "CSS/SCSS Coding Standards (Stylelint)"
        echo "====================================="
        echo "Extensions: .css, .scss"
        echo "Excluded: build/, dist/, vendor/, node_modules/"
        echo ""
        echo "Report:"
        echo "-------"
    } > "$REPORT_DIR/04-stylelint.txt"
    
    (cd "$PLUGIN_ROOT" && "$PLUGIN_ROOT/node_modules/.bin/stylelint" "**/*.{css,scss}" \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/') >> "$REPORT_DIR/04-stylelint.txt" 2>&1 || true
    
    # Generate JSON report
    (cd "$PLUGIN_ROOT" && "$PLUGIN_ROOT/node_modules/.bin/stylelint" "**/*.{css,scss}" \
      --ignore-path .gitignore \
      --ignore-pattern 'build/' \
      --ignore-pattern 'dist/' \
      --ignore-pattern 'vendor/' \
      --ignore-pattern 'node_modules/' \
      --formatter json \
      --output-file "$REPORT_DIR/04-stylelint-results.json") 2>&1 || true
    
    STYLELINT_ERRORS=$(jq '[.[] | select(.errored==true)] | length' "$REPORT_DIR/04-stylelint-results.json" 2>/dev/null || echo "0")
    STYLELINT_WARNINGS=$(jq '[.[].warnings[] | select(.severity=="warning")] | length' "$REPORT_DIR/04-stylelint-results.json" 2>/dev/null || echo "0")
    STYLELINT_PROBLEMS=$((STYLELINT_ERRORS + STYLELINT_WARNINGS))
    
    if [ "$STYLELINT_PROBLEMS" -gt 0 ]; then
        echo "   ⚠️  Found $STYLELINT_ERRORS files with errors and $STYLELINT_WARNINGS warnings"
    else
        echo "   ✅ No style issues found"
    fi
else
    echo "   ⚠️  Stylelint not found, skipping."
    echo "Stylelint not found. Please add it as a dev dependency to your package.json" > "$REPORT_DIR/04-stylelint.txt"
    STYLELINT_ERRORS=0
    STYLELINT_WARNINGS=0
    STYLELINT_PROBLEMS=0
fi

########################################
# 9. Block.json Validation
########################################

echo "➡️  Scanning for block.json files..."

{
    echo "Block.json Files"
    echo "================"
    echo ""
} > "$REPORT_DIR/05-block-json.txt"

BLOCK_JSON_COUNT=0
while IFS= read -r -d '' block_json; do
    BLOCK_JSON_COUNT=$((BLOCK_JSON_COUNT + 1))
    RELATIVE_PATH=$(echo "$block_json" | sed "s|$PLUGIN_ROOT/||")
    echo "Found: $RELATIVE_PATH" >> "$REPORT_DIR/05-block-json.txt"
    
    # Validate JSON syntax
    if jq empty "$block_json" 2>/dev/null; then
        echo "  ✅ Valid JSON syntax" >> "$REPORT_DIR/05-block-json.txt"
        
        # Check required fields
        NAME=$(jq -r '.name // "missing"' "$block_json" 2>/dev/null)
        TITLE=$(jq -r '.title // "missing"' "$block_json" 2>/dev/null)
        CATEGORY=$(jq -r '.category // "missing"' "$block_json" 2>/dev/null)
        
        echo "  - Name: $NAME" >> "$REPORT_DIR/05-block-json.txt"
        echo "  - Title: $TITLE" >> "$REPORT_DIR/05-block-json.txt"
        echo "  - Category: $CATEGORY" >> "$REPORT_DIR/05-block-json.txt"
        
        # Check for common fields
        [ "$(jq -r '.description' "$block_json" 2>/dev/null)" != "null" ] && echo "  - Has description" >> "$REPORT_DIR/05-block-json.txt"
        [ "$(jq -r '.icon' "$block_json" 2>/dev/null)" != "null" ] && echo "  - Has icon" >> "$REPORT_DIR/05-block-json.txt"
        [ "$(jq -r '.supports' "$block_json" 2>/dev/null)" != "null" ] && echo "  - Has supports configuration" >> "$REPORT_DIR/05-block-json.txt"
        [ "$(jq -r '.attributes' "$block_json" 2>/dev/null)" != "null" ] && echo "  - Has attributes" >> "$REPORT_DIR/05-block-json.txt"
    else
        echo "  ❌ Invalid JSON syntax" >> "$REPORT_DIR/05-block-json.txt"
    fi
    echo "" >> "$REPORT_DIR/05-block-json.txt"
done < <(eval "find \"\$PLUGIN_ROOT\" -name 'block.json' -type f $FIND_EXCLUDES -print0")

echo "Summary: Found $BLOCK_JSON_COUNT block.json file(s)" >> "$REPORT_DIR/05-block-json.txt"
echo "   Found $BLOCK_JSON_COUNT block.json file(s)"

########################################
# 10. React/JSX Component Analysis
########################################

echo "➡️  Analyzing React components..."

{
    echo "React/JSX Component Analysis"
    echo "============================"
    echo ""
    echo "Component Files:"
    echo "----------------"
} > "$REPORT_DIR/06-react-components.txt"

REACT_COMPONENTS=0
while IFS= read -r -d '' jsx_file; do
    RELATIVE_PATH=$(echo "$jsx_file" | sed "s|$PLUGIN_ROOT/||")
    
    # Check if file contains React components
    if grep -q "\(function\|const\|class\).*extends.*Component\|=>.*{" "$jsx_file" 2>/dev/null; then
        REACT_COMPONENTS=$((REACT_COMPONENTS + 1))
        echo "$RELATIVE_PATH" >> "$REPORT_DIR/06-react-components.txt"
        
        # Check for hooks usage
        USES_STATE=$(grep -c "useState" "$jsx_file" 2>/dev/null || echo "0")
        USES_EFFECT=$(grep -c "useEffect" "$jsx_file" 2>/dev/null || echo "0")
        USES_REF=$(grep -c "useRef" "$jsx_file" 2>/dev/null || echo "0")
        
        [ "$USES_STATE" -gt 0 ] && echo "  - Uses useState ($USES_STATE times)" >> "$REPORT_DIR/06-react-components.txt"
        [ "$USES_EFFECT" -gt 0 ] && echo "  - Uses useEffect ($USES_EFFECT times)" >> "$REPORT_DIR/06-react-components.txt"
        [ "$USES_REF" -gt 0 ] && echo "  - Uses useRef ($USES_REF times)" >> "$REPORT_DIR/06-react-components.txt"
        
        # Check for WordPress block editor components
        grep -q "@wordpress/block-editor" "$jsx_file" && echo "  - Imports from @wordpress/block-editor" >> "$REPORT_DIR/06-react-components.txt"
        grep -q "@wordpress/components" "$jsx_file" && echo "  - Imports from @wordpress/components" >> "$REPORT_DIR/06-react-components.txt"
        
        echo "" >> "$REPORT_DIR/06-react-components.txt"
    fi
done < <(eval "find \"\$PLUGIN_ROOT\" -type f \\( -name '*.jsx' -o -name '*.tsx' -o -name '*.js' \\) $FIND_EXCLUDES -print0")

echo "" >> "$REPORT_DIR/06-react-components.txt"
echo "Summary: Found $REACT_COMPONENTS React component file(s)" >> "$REPORT_DIR/06-react-components.txt"
echo "   Found $REACT_COMPONENTS React component file(s)"

########################################
# 11. Jest Tests
########################################

echo "➡️  Running Jest tests..."

if [ -f "$PLUGIN_ROOT/package.json" ] && grep -q '"test":' "$PLUGIN_ROOT/package.json"; then
    {
        echo "Jest Test Results"
        echo "================="
        echo ""
    } > "$REPORT_DIR/07-jest.txt"
    
    (cd "$PLUGIN_ROOT" && npm test -- --ci --json --outputFile="$REPORT_DIR/07-jest-results.json") >> "$REPORT_DIR/07-jest.txt" 2>&1 || true
    
    if [ -f "$REPORT_DIR/07-jest-results.json" ]; then
        JEST_TESTS=$(jq '.numTotalTests // 0' "$REPORT_DIR/07-jest-results.json" 2>/dev/null || echo "0")
        JEST_PASSED=$(jq '.numPassedTests // 0' "$REPORT_DIR/07-jest-results.json" 2>/dev/null || echo "0")
        JEST_FAILED=$(jq '.numFailedTests // 0' "$REPORT_DIR/07-jest-results.json" 2>/dev/null || echo "0")
        JEST_SUITES=$(jq '.numTotalTestSuites // 0' "$REPORT_DIR/07-jest-results.json" 2>/dev/null || echo "0")
        
        {
            echo ""
            echo "Test Summary:"
            echo "-------------"
            echo "Total Test Suites: $JEST_SUITES"
            echo "Total Tests: $JEST_TESTS"
            echo "Tests Passed: $JEST_PASSED"
            echo "Tests Failed: $JEST_FAILED"
        } >> "$REPORT_DIR/07-jest.txt"
        
        if [ "$JEST_FAILED" -gt 0 ]; then
            echo "   ❌ Ran $JEST_TESTS tests, $JEST_FAILED failed"
        else
            echo "   ✅ All $JEST_TESTS tests passed"
        fi
    else
        JEST_TESTS=0
        JEST_PASSED=0
        JEST_FAILED=0
        echo "   ⚠️  Could not parse Jest results"
    fi
else
    echo "   ⚠️  No Jest test script found in package.json, skipping."
    echo "No Jest test script found in package.json." > "$REPORT_DIR/07-jest.txt"
    JEST_TESTS=0
    JEST_PASSED=0
    JEST_FAILED=0
fi

########################################
# 12. Summary Report
########################################

echo "➡️  Generating detailed summary report..."

{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           GUTENBERG BLOCK CODE ANALYSIS SUMMARY                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Plugin: $PLUGIN_NAME"
    echo "Plugin Path: $PLUGIN_ROOT"
    echo "Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "FILE STATISTICS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "PHP Files: $TOTAL_PHP_FILES ($TOTAL_PHP_LINES lines)"
    echo "JavaScript/TypeScript Files: $TOTAL_JS_FILES"
    echo "CSS/SCSS Files: $TOTAL_CSS_FILES"
    echo "Block.json Files: $BLOCK_JSON_COUNT"
    echo "React Components: $REACT_COMPONENTS"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "CODE QUALITY SUMMARY"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "┌─────────────────────────────────────┬──────────┬──────────┬─────────────────┐"
    echo "│ Check                               │ Errors   │ Warnings │ Status          │"
    echo "├─────────────────────────────────────┼──────────┼──────────┼─────────────────┤"
    printf "│ %-35s │ %8s │ %8s │ %-15s │\n" "PHPCS (WordPress Standard)" "$PHPCS_ERRORS" "$PHPCS_WARNINGS" "$([ "$PHPCS_ERRORS" -eq 0 ] && echo "✅ OK" || echo "❌ Issues Found")"
    printf "│ %-35s │ %8s │ %8s │ %-15s │\n" "ESLint (JavaScript/TypeScript)" "$ESLINT_ERRORS" "$ESLINT_WARNINGS" "$([ "$ESLINT_PROBLEMS" -eq 0 ] && echo "✅ OK" || echo "⚠️  Issues Found")"
    printf "│ %-35s │ %8s │ %8s │ %-15s │\n" "Stylelint (CSS/SCSS)" "$STYLELINT_ERRORS" "$STYLELINT_WARNINGS" "$([ "$STYLELINT_PROBLEMS" -eq 0 ] && echo "✅ OK" || echo "⚠️  Issues Found")"
    echo "└─────────────────────────────────────┴──────────┴──────────┴─────────────────┘"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "JEST TEST RESULTS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    if [ "$JEST_TESTS" -gt 0 ]; then
        echo "Total Tests: $JEST_TESTS"
        echo "Passed: $JEST_PASSED"
        echo "Failed: $JEST_FAILED"
        echo "Success Rate: $(awk "BEGIN {printf \"%.1f%%\", ($JEST_PASSED/$JEST_TESTS)*100}")" 2>/dev/null || echo "N/A"
        [ "$JEST_FAILED" -eq 0 ] && echo "Status: ✅ All tests passed" || echo "Status: ❌ Some tests failed"
    else
        echo "No Jest tests found or executed"
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "GUTENBERG BLOCK ANALYSIS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Block.json Files: $BLOCK_JSON_COUNT"
    echo "React Component Files: $REACT_COMPONENTS"
    echo ""
    if [ "$BLOCK_JSON_COUNT" -gt 0 ]; then
        echo "✅ Block metadata files detected"
    else
        echo "⚠️  No block.json files found"
    fi
    echo ""
    if [ "$REACT_COMPONENTS" -gt 0 ]; then
        echo "✅ React components detected"
    else
        echo "⚠️  No React components detected"
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "OVERALL SCORE"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Calculate overall score
    TOTAL_ISSUES=$((PHPCS_ERRORS + ESLINT_ERRORS + STYLELINT_ERRORS + JEST_FAILED))
    
    if [ "$TOTAL_ISSUES" -eq 0 ]; then
        echo "🎉 EXCELLENT: No critical issues found!"
    elif [ "$TOTAL_ISSUES" -le 10 ]; then
        echo "✅ GOOD: Only minor issues found ($TOTAL_ISSUES total)"
    elif [ "$TOTAL_ISSUES" -le 50 ]; then
        echo "⚠️  NEEDS IMPROVEMENT: Some issues found ($TOTAL_ISSUES total)"
    else
        echo "❌ NEEDS ATTENTION: Multiple issues found ($TOTAL_ISSUES total)"
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "RECOMMENDATIONS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    
    if [ "$PHPCS_ERRORS" -gt 0 ]; then
        echo "🔴 Fix PHP coding standard errors (see 02-phpcs-wordpress.txt)"
    fi
    if [ "$ESLINT_ERRORS" -gt 0 ]; then
        echo "🔴 Fix JavaScript/TypeScript errors (see 03-eslint.txt)"
    fi
    if [ "$JEST_FAILED" -gt 0 ]; then
        echo "🔴 Fix failing tests (see 07-jest.txt)"
    fi
    if [ "$PHPCS_WARNINGS" -gt 0 ]; then
        echo "⚠️  Review PHP coding standard warnings"
    fi
    if [ "$ESLINT_WARNINGS" -gt 0 ]; then
        echo "⚠️  Review JavaScript/TypeScript warnings"
    fi
    if [ "$BLOCK_JSON_COUNT" -eq 0 ]; then
        echo "💡 Consider adding block.json files for better block metadata"
    fi
    if [ "$JEST_TESTS" -eq 0 ]; then
        echo "💡 Consider adding unit tests with Jest"
    fi
    
    if [ "$TOTAL_ISSUES" -eq 0 ]; then
        echo "✅ No critical recommendations - code quality is excellent!"
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
    for report in "$REPORT_DIR"/*.json; do
        if [ -f "$report" ]; then
            echo "📄 $(basename "$report")"
        fi
    done
    echo ""
    echo "════════════════════════════════════════════════════════════════════"

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
