#!/bin/bash

# Script to check new code changes in WordPress plugin
# Compares current branch with master branch and checks for security issues
# Usage: ./check-plugin-changes.sh /path/to/plugin [--current_branch=branch_name] [--base_branch=branch_name]

# Default values
CURRENT_BRANCH=""
BASE_BRANCH="master"
FULL_PLUGIN_PATH=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --current_branch=*)
            CURRENT_BRANCH="${arg#*=}"
            ;;
        --base_branch=*)
            BASE_BRANCH="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: $0 /path/to/plugin [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --current_branch=NAME   Branch to check (default: current git branch)"
            echo "  --base_branch=NAME      Branch to compare against (default: master)"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 /path/to/plugin --current_branch=feature-branch --base_branch=main"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # First non-option argument is the plugin path
            if [ -z "$FULL_PLUGIN_PATH" ]; then
                FULL_PLUGIN_PATH="$arg"
            fi
            ;;
    esac
done

# Check if plugin path argument is provided
if [ -z "$FULL_PLUGIN_PATH" ]; then
    echo "Usage: $0 /path/to/plugin [--current_branch=branch_name] [--base_branch=branch_name]"
    echo "Example: $0 /Users/th10/wp-projects/central-test-suite/security-reports/location-weather --current_branch=dev"
    echo "Use --help for more options"
    exit 1
fi

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Extract plugin folder name from path
PLUGIN_NAME=$(basename "$FULL_PLUGIN_PATH")

# Find git repo root from plugin path
REPO_DIR=$(cd "$FULL_PLUGIN_PATH" && git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_DIR" ]; then
    echo "Error: Could not find git repository for $FULL_PLUGIN_PATH"
    exit 1
fi

# Get relative plugin path from repo root
PLUGIN_PATH=$(realpath --relative-to="$REPO_DIR" "$FULL_PLUGIN_PATH" 2>/dev/null || echo "${FULL_PLUGIN_PATH#$REPO_DIR/}")

# Create report directory
REPORT_DIR="$SCRIPT_DIR/new-code-check/$PLUGIN_NAME"
mkdir -p "$REPORT_DIR"

# Report file with timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$REPORT_DIR/security-report_$TIMESTAMP.txt"

ISSUES_FOUND=0

cd "$REPO_DIR" || exit 1

# Get current branch name if not specified
if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH=$(git branch --show-current)
fi

# Verify the specified branch exists
if ! git rev-parse --verify "$CURRENT_BRANCH" >/dev/null 2>&1; then
    echo "Error: Branch '$CURRENT_BRANCH' does not exist"
    exit 1
fi

# Verify base branch exists
if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    echo "Error: Base branch '$BASE_BRANCH' does not exist"
    exit 1
fi

# Function to output to both console and report file
output() {
    echo "$1"
    echo "$1" >> "$REPORT_FILE"
}

# Initialize report file
echo "" > "$REPORT_FILE"

output "=========================================="
output "🔍 WordPress Plugin Security Check"
output "=========================================="
output "Plugin: $PLUGIN_NAME"
output "Plugin Path: $PLUGIN_PATH"
output "Current branch: $CURRENT_BRANCH"
output "Comparing with: $BASE_BRANCH"
output "Date: $(date)"
output "=========================================="
output ""

# Get only the added lines (new code) from the diff
NEW_CODE=$(git diff "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" | grep '^+' | grep -v '^+++')

# Show list of changed files
output "📁 Changed files:"
output "------------------------------------------"
CHANGED_FILES=$(git diff --name-status "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH")
output "$CHANGED_FILES"
output ""

output "=========================================="
output "🛡️  SECURITY ANALYSIS"
output "=========================================="
output ""

# Function to check for pattern and report
check_security() {
    local pattern="$1"
    local message="$2"
    local severity="$3"
    local matches
    matches=$(echo "$NEW_CODE" | grep -n -i "$pattern" 2>/dev/null)
    if [ -n "$matches" ]; then
        output "$severity $message"
        output "$(echo "$matches" | head -10)"
        output ""
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
}

output "Checking for security vulnerabilities in NEW code..."
output ""

# SQL Injection checks
output "── SQL Injection ──"
check_security '\$wpdb->query.*\$_' "⚠️  Direct query with user input (use \$wpdb->prepare())" "🔴 CRITICAL:"
check_security '\$wpdb->get_' "⚠️  Database query - verify \$wpdb->prepare() is used" "🟡 WARNING:"
check_security 'esc_sql' "⚠️  esc_sql found - prefer \$wpdb->prepare()" "🟡 WARNING:"

# XSS checks
output "── Cross-Site Scripting (XSS) ──"
check_security 'echo.*\$_\(GET\|POST\|REQUEST\)' "⚠️  Echoing user input without escaping" "🔴 CRITICAL:"
check_security 'print.*\$_\(GET\|POST\|REQUEST\)' "⚠️  Printing user input without escaping" "🔴 CRITICAL:"
check_security '<?=.*\$' "⚠️  Short echo tag with variable - ensure proper escaping" "🟡 WARNING:"

# Check for missing escape functions in output
output "── Output Escaping ──"
check_security 'echo.*\$' "ℹ️  Echo with variable - verify esc_html/esc_attr is used" "🟡 REVIEW:"

# CSRF checks
output "── CSRF Protection ──"
check_security 'admin_post_' "ℹ️  Admin POST handler - verify wp_nonce check exists" "🟡 REVIEW:"
check_security 'wp_ajax_' "ℹ️  AJAX handler - verify wp_nonce check exists" "🟡 REVIEW:"
check_security '\$_POST\[' "ℹ️  POST data usage - verify nonce verification" "🟡 REVIEW:"

# Dangerous functions
output "── Dangerous Functions ──"
check_security 'eval\s*(' "⚠️  eval() usage detected - HIGH RISK" "🔴 CRITICAL:"
# PHP exec() - dangerous
check_security '[^.]exec\s*(' "⚠️  PHP exec() usage detected - HIGH RISK" "🔴 CRITICAL:"
# JS child_process exec - dangerous
check_security 'child_process' "⚠️  child_process module - potential command execution" "🔴 CRITICAL:"
check_security 'require.*child_process\|from.*child_process' "⚠️  child_process import detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'execSync\|spawnSync' "⚠️  Synchronous command execution detected" "🔴 CRITICAL:"
check_security 'system\s*(' "⚠️  system() usage detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'shell_exec' "⚠️  shell_exec() usage detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'passthru' "⚠️  passthru() usage detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'popen\s*(' "⚠️  popen() usage detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'proc_open' "⚠️  proc_open() usage detected - HIGH RISK" "🔴 CRITICAL:"
check_security 'unserialize' "⚠️  unserialize() - use maybe_unserialize() or validate input" "🔴 CRITICAL:"
check_security 'base64_decode' "⚠️  base64_decode() - verify source is trusted" "🟡 WARNING:"
# JS specific dangerous functions
check_security 'new Function\s*(' "⚠️  new Function() - similar to eval, HIGH RISK" "🔴 CRITICAL:"
check_security 'setTimeout.*\$\|setInterval.*\$' "⚠️  setTimeout/setInterval with string - potential code execution" "🟡 WARNING:"

# File operations
output "── File Operations ──"
check_security 'file_get_contents.*\$' "⚠️  file_get_contents with variable - verify path" "🟡 WARNING:"
check_security 'file_put_contents' "⚠️  file_put_contents - verify write permissions & path" "🟡 WARNING:"
check_security 'fopen.*\$' "⚠️  fopen with variable - verify path is safe" "🟡 WARNING:"
check_security 'include.*\$' "⚠️  Dynamic include - potential LFI vulnerability" "🔴 CRITICAL:"
check_security 'require.*\$' "⚠️  Dynamic require - potential LFI vulnerability" "🔴 CRITICAL:"
check_security 'move_uploaded_file' "⚠️  File upload handling - verify proper validation" "🟡 WARNING:"

# Input sanitization
output "── Input Sanitization ──"
check_security '\$_GET\[' "ℹ️  \$_GET usage - verify sanitize_text_field/intval" "🟡 REVIEW:"
check_security '\$_POST\[' "ℹ️  \$_POST usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_REQUEST\[' "ℹ️  \$_REQUEST usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_COOKIE\[' "ℹ️  \$_COOKIE usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_SERVER\[' "ℹ️  \$_SERVER usage - some values need sanitization" "🟡 REVIEW:"

# WordPress specific checks
output "── WordPress Best Practices ──"
check_security 'ABSPATH' "✅ ABSPATH check found (good practice)" "🟢 INFO:"
check_security 'current_user_can' "✅ Capability check found (good practice)" "🟢 INFO:"
check_security 'wp_verify_nonce' "✅ Nonce verification found (good practice)" "🟢 INFO:"
check_security 'sanitize_' "✅ Sanitization function found (good practice)" "🟢 INFO:"
check_security 'esc_html\|esc_attr\|esc_url\|wp_kses' "✅ Escaping function found (good practice)" "🟢 INFO:"

output ""
output "=========================================="
output "📊 SUMMARY"
output "=========================================="
output "Files changed: $(git diff --name-only "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" | wc -l | tr -d ' ')"
output "Lines added:   $(git diff "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" | grep -c '^+' || echo 0)"
output "Lines removed: $(git diff "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" | grep -c '^-' || echo 0)"
output "------------------------------------------"
if [ $ISSUES_FOUND -eq 0 ]; then
    output "✅ No obvious security issues detected!"
else
    output "⚠️  Found $ISSUES_FOUND potential issue(s) to review"
fi
output "=========================================="
output ""
output "Note: This is an automated check. Manual code review is still recommended."
output "Legend: 🔴 CRITICAL | 🟡 WARNING/REVIEW | 🟢 GOOD PRACTICE"
output ""
output "Report saved to: $REPORT_FILE"

echo ""
echo "📄 Report saved to: $REPORT_FILE"
