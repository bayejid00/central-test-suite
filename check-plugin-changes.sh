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

# Report file (overwrites existing file)
REPORT_FILE="$REPORT_DIR/security-report.txt"

CRITICAL_COUNT=0
WARNING_COUNT=0
REVIEW_COUNT=0

# Directories to exclude from analysis
EXCLUDE_DIRS=(
    "node_modules"
    ".git"
    ".github"
    "vendor"
    "tests"
    "dist"
    "build"
    "security-reports"
)

# Build grep exclusion pattern matching directory boundaries, e.g. '(^|/)(node_modules|\.git|build)(/|$)'
# Escape dots in directory names and join with |
ESCAPED_EXCLUDES=$(printf '%s|' "${EXCLUDE_DIRS[@]}" | sed 's/\./\\./g' | sed 's/|$//')
GREP_EXCLUDES="(^|/)(${ESCAPED_EXCLUDES})(/|$)"

# Pattern to exclude minified css/js files
MINIFIED_PATTERN='\.min\.(css|js)$'

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

# Get list of changed files first, then filter out excluded directories and minified files
ALL_CHANGED_FILES=$(git diff --name-only "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" || true)
FILTERED_FILES=$(echo "$ALL_CHANGED_FILES" | grep -vE "$GREP_EXCLUDES" | grep -vE "$MINIFIED_PATTERN" || true)

# Get diff only for filtered files (properly excludes entire files from build folders)
if [ -n "$FILTERED_FILES" ]; then
    FILTERED_DIFF=$(echo "$FILTERED_FILES" | xargs git diff "$BASE_BRANCH"..."$CURRENT_BRANCH" -- 2>/dev/null || true)
else
    FILTERED_DIFF=""
fi

# Get only the added lines (new code) from the filtered diff
NEW_CODE=$(echo "$FILTERED_DIFF" | grep '^+' | grep -v '^+++' || true)

# Show list of changed files (excluding excluded directories)
output "📁 Changed files:"
output "------------------------------------------"
CHANGED_FILES=$(git diff --name-status "$BASE_BRANCH"..."$CURRENT_BRANCH" -- "$PLUGIN_PATH" | grep -vE "$GREP_EXCLUDES" | grep -vE "$MINIFIED_PATTERN" || true)
output "$CHANGED_FILES"
output ""

output "=========================================="
output "🛡️  SECURITY ANALYSIS"
output "=========================================="
output ""

# Function to check for security patterns in new code
# Args: pattern (regex), message (description), severity (emoji prefix)
# The function counts issues by severity for the summary report
check_security() {
    local pattern="$1"
    local message="$2"
    local severity="$3"
    local matches
    matches=$(echo "$NEW_CODE" | grep -E -n -i "$pattern" 2>/dev/null)
    if [ -n "$matches" ]; then
        output "$severity $message"
        output "$(echo "$matches" | head -10)"
        output ""
        # Count by severity for final summary
        case $severity in
            *CRITICAL*) CRITICAL_COUNT=$((CRITICAL_COUNT + 1)) ;;
            *WARNING*)  WARNING_COUNT=$((WARNING_COUNT + 1)) ;;
            *REVIEW*)   REVIEW_COUNT=$((REVIEW_COUNT + 1)) ;;
        esac
    fi
}

output "Checking for security vulnerabilities in NEW code..."
output ""

# ============================================
# SECURITY CHECK CATEGORIES
# ============================================
# This script performs automated security analysis across multiple categories:
# 1. PHP Security (SQL Injection, XSS, Dangerous Functions)
# 2. Input Validation & Sanitization
# 3. CSRF & Nonce Verification
# 4. File & Serialization Issues
# 5. JavaScript Security (DOM-XSS, Prototype Pollution)
# 6. WordPress Specific (Options, Posts, Users, Capabilities)
# 7. Hardcoded Secrets Detection
# 8. Positive Security Patterns (Good practices found)
#
# Note: High false-positive rate - manual review recommended

# ============================================
# PHP SECURITY CHECKS
# ============================================

# SQL Injection checks
output "── SQL Injection (PHP) ──"
check_security '\$wpdb->query.*\$_' "⚠️  Direct query with user input (use \$wpdb->prepare())" "🔴 CRITICAL:"
check_security '\$wpdb->get_.*\$_' "⚠️  Database query with user input - use \$wpdb->prepare()" "🔴 CRITICAL:"
check_security '\$wpdb->get_' "⚠️  Database query - verify \$wpdb->prepare() is used" "🟡 WARNING:"
check_security 'esc_sql' "⚠️  esc_sql found - prefer \$wpdb->prepare()" "🟡 WARNING:"
check_security 'query.*SELECT.*FROM.*\$' "⚠️  Raw SQL with variable - potential injection" "🔴 CRITICAL:"
check_security 'query.*INSERT.*INTO.*\$' "⚠️  Raw SQL INSERT with variable - potential injection" "🔴 CRITICAL:"
check_security 'query.*UPDATE.*SET.*\$' "⚠️  Raw SQL UPDATE with variable - potential injection" "🔴 CRITICAL:"
check_security 'query.*DELETE.*FROM.*\$' "⚠️  Raw SQL DELETE with variable - potential injection" "🔴 CRITICAL:"

# XSS checks
output "── Cross-Site Scripting (XSS) ──"
check_security 'echo.*\$_\(GET\|POST\|REQUEST\)' "⚠️  Echoing user input without escaping" "🔴 CRITICAL:"
check_security 'print.*\$_\(GET\|POST\|REQUEST\)' "⚠️  Printing user input without escaping" "🔴 CRITICAL:"
check_security '<?=.*\$_' "⚠️  Short echo tag with user input - XSS risk" "🔴 CRITICAL:"
check_security '<?=.*\$' "⚠️  Short echo tag with variable - ensure proper escaping" "🟡 WARNING:"
check_security 'printf.*\$_' "⚠️  printf with user input - potential XSS" "🔴 CRITICAL:"
check_security 'vprintf.*\$_' "⚠️  vprintf with user input - potential XSS" "🔴 CRITICAL:"

# Output Escaping
output "── Output Escaping ──"
check_security 'echo.*\$' "ℹ️  Echo with variable - verify esc_html/esc_attr is used" "🟡 REVIEW:"

# CSRF checks
output "── CSRF Protection ──"
check_security 'admin_post_' "ℹ️  Admin POST handler - verify wp_nonce check exists" "🟡 REVIEW:"
check_security 'wp_ajax_' "ℹ️  AJAX handler - verify wp_nonce check exists" "🟡 REVIEW:"
check_security 'admin_init.*\$_POST' "⚠️  admin_init with POST - verify nonce & capability check" "🟡 WARNING:"
check_security 'init.*\$_POST\[' "⚠️  init hook with POST data - verify nonce check" "🟡 WARNING:"

# Dangerous PHP functions
output "── Dangerous PHP Functions ──"
check_security '\beval\s*(' "⚠️  eval() - HIGH RISK, allows arbitrary code execution" "🔴 CRITICAL:"
check_security '\bassert\s*(' "⚠️  assert() - can execute code if string passed" "🔴 CRITICAL:"
check_security '\bcreate_function' "⚠️  create_function() - deprecated, use closures instead" "🔴 CRITICAL:"
check_security 'preg_replace.*\/.*e' "⚠️  preg_replace with /e modifier - code execution risk" "🔴 CRITICAL:"
check_security 'call_user_func.*\$_' "⚠️  call_user_func with user input - arbitrary function call" "🔴 CRITICAL:"
check_security 'call_user_func_array.*\$_' "⚠️  call_user_func_array with user input" "🔴 CRITICAL:"
check_security '[^.]\bexec\s*(' "⚠️  exec() - command execution" "🔴 CRITICAL:"
check_security '\bsystem\s*(' "⚠️  system() - command execution" "🔴 CRITICAL:"
check_security '\bshell_exec' "⚠️  shell_exec() - command execution" "🔴 CRITICAL:"
check_security '\bpassthru' "⚠️  passthru() - command execution" "🔴 CRITICAL:"
check_security '\bpopen\s*(' "⚠️  popen() - process execution" "🔴 CRITICAL:"
check_security '\bproc_open' "⚠️  proc_open() - process execution" "🔴 CRITICAL:"
check_security '\bpcntl_exec' "⚠️  pcntl_exec() - process execution" "🔴 CRITICAL:"
check_security 'backtick\|\`.*\$' "⚠️  Backtick operator with variable - command execution" "🔴 CRITICAL:"

# Serialization
output "── Serialization Issues ──"
check_security 'unserialize\s*\(\s*\$_' "⚠️  unserialize with user input - object injection risk" "🔴 CRITICAL:"
check_security 'unserialize\s*\(\s*\$\w*\[.POST\|GET\|REQUEST\' "⚠️  unserialize with user input - object injection risk" "🔴 CRITICAL:"
check_security 'maybe_unserialize.*\$_' "⚠️  maybe_unserialize with user input - verify source" "🟡 WARNING:"

# File operations
output "── File Operations ──"
check_security 'file_get_contents.*\$_' "⚠️  file_get_contents with user input - SSRF/LFI risk" "🔴 CRITICAL:"
check_security 'file_get_contents.*\$' "⚠️  file_get_contents with variable - verify path" "🟡 WARNING:"
check_security 'file_put_contents.*\$_' "⚠️  file_put_contents with user input - arbitrary write" "🔴 CRITICAL:"
check_security 'file_put_contents' "⚠️  file_put_contents - verify path & permissions" "🟡 WARNING:"
check_security 'fopen.*\$_' "⚠️  fopen with user input - path traversal risk" "🔴 CRITICAL:"
check_security 'fwrite.*\$_' "⚠️  fwrite with user input - arbitrary file write" "🔴 CRITICAL:"
check_security 'readfile.*\$_' "⚠️  readfile with user input - LFI risk" "🔴 CRITICAL:"
check_security 'include.*\$_' "⚠️  include with user input - LFI vulnerability" "🔴 CRITICAL:"
check_security 'include_once.*\$_' "⚠️  include_once with user input - LFI vulnerability" "🔴 CRITICAL:"
check_security 'require.*\$_' "⚠️  require with user input - LFI vulnerability" "🔴 CRITICAL:"
check_security 'require_once.*\$_' "⚠️  require_once with user input - LFI vulnerability" "🔴 CRITICAL:"
check_security 'include.*\$' "⚠️  Dynamic include - verify path is safe" "🟡 WARNING:"
check_security 'require.*\$' "⚠️  Dynamic require - verify path is safe" "🟡 WARNING:"
check_security 'move_uploaded_file' "⚠️  File upload - verify type, size & destination" "🟡 WARNING:"
check_security 'copy.*\$_' "⚠️  copy with user input - arbitrary file operations" "🔴 CRITICAL:"
check_security 'rename.*\$_' "⚠️  rename with user input - file manipulation risk" "🔴 CRITICAL:"
check_security 'unlink.*\$_' "⚠️  unlink with user input - arbitrary file deletion" "🔴 CRITICAL:"
check_security 'rmdir.*\$_' "⚠️  rmdir with user input - directory deletion risk" "🔴 CRITICAL:"
check_security 'mkdir.*\$_' "⚠️  mkdir with user input - verify path" "🟡 WARNING:"
check_security 'chmod.*\$_' "⚠️  chmod with user input - permission manipulation" "🔴 CRITICAL:"

# Variable manipulation
output "── Variable Manipulation ──"
check_security 'extract\s*(' "⚠️  extract() - can overwrite variables, avoid with user data" "🔴 CRITICAL:"
check_security 'parse_str.*\$_' "⚠️  parse_str with user input - variable injection" "🔴 CRITICAL:"
check_security 'parse_str' "⚠️  parse_str() - use second parameter to avoid variable injection" "🟡 WARNING:"
check_security '\$\$' "⚠️  Variable variables (\$\$) - verify source is trusted" "🟡 WARNING:"
check_security 'compact.*\$_' "⚠️  compact with user input - variable exposure risk" "🟡 WARNING:"

# Encoding/Decoding
output "── Encoding/Decoding ──"
check_security 'base64_decode.*\$_' "⚠️  base64_decode with user input - potential code injection" "🔴 CRITICAL:"
check_security 'base64_decode' "⚠️  base64_decode() - verify source is trusted" "🟡 WARNING:"
check_security 'gzinflate\|gzuncompress\|gzdecode' "⚠️  Compression functions - often used to hide malicious code" "🟡 WARNING:"
check_security 'str_rot13' "⚠️  str_rot13 - sometimes used to obfuscate malicious code" "🟡 WARNING:"

# Input sanitization
output "── Input Sources ──"
check_security '\$_GET\[' "ℹ️  \$_GET usage - verify sanitize_text_field/intval" "🟡 REVIEW:"
check_security '\$_POST\[' "ℹ️  \$_POST usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_REQUEST\[' "ℹ️  \$_REQUEST usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_COOKIE\[' "ℹ️  \$_COOKIE usage - verify sanitization" "🟡 REVIEW:"
check_security '\$_SERVER\[.REQUEST_URI' "⚠️  \$_SERVER[REQUEST_URI] - needs escaping for output" "🟡 WARNING:"
check_security '\$_SERVER\[.PHP_SELF' "⚠️  \$_SERVER[PHP_SELF] - XSS risk, use esc_url()" "🟡 WARNING:"
check_security '\$_SERVER\[.HTTP_' "⚠️  \$_SERVER[HTTP_*] - user-controlled headers, sanitize" "🟡 WARNING:"
check_security '\$_FILES\[' "ℹ️  \$_FILES usage - verify proper upload validation" "🟡 REVIEW:"
check_security 'php://input' "⚠️  php://input - raw input stream, validate carefully" "🟡 WARNING:"

# Information disclosure
output "── Information Disclosure ──"
check_security 'phpinfo\s*(' "⚠️  phpinfo() - exposes server information" "🔴 CRITICAL:"
check_security 'var_dump.*\$_' "⚠️  var_dump with user data - debug output" "🟡 WARNING:"
check_security 'print_r.*\$_' "⚠️  print_r with user data - debug output" "🟡 WARNING:"
check_security 'debug_backtrace' "⚠️  debug_backtrace - may expose sensitive info" "🟡 WARNING:"
check_security 'error_reporting.*-1\|E_ALL' "⚠️  Full error reporting - disable in production" "🟡 WARNING:"
check_security 'display_errors.*on\|1' "⚠️  display_errors on - disable in production" "🟡 WARNING:"
check_security 'WP_DEBUG.*true' "⚠️  WP_DEBUG true - should be false in production" "🟡 WARNING:"

# ============================================
# JAVASCRIPT SECURITY CHECKS
# ============================================
output ""
output "── JavaScript Security ──"

# DOM-based XSS
check_security 'innerHTML.*=' "⚠️  innerHTML assignment - potential XSS, use textContent" "🟡 WARNING:"
check_security 'outerHTML.*=' "⚠️  outerHTML assignment - potential XSS" "🟡 WARNING:"
check_security 'document\.write' "⚠️  document.write - XSS risk, avoid using" "🔴 CRITICAL:"
check_security 'document\.writeln' "⚠️  document.writeln - XSS risk, avoid using" "🔴 CRITICAL:"
check_security '\.html\s*(' "⚠️  jQuery .html() - potential XSS, verify input" "🟡 WARNING:"
check_security 'dangerouslySetInnerHTML.*\$\|dangerouslySetInnerHTML.*{.*\$' "⚠️  React dangerouslySetInnerHTML with variable - sanitize input" "🟡 WARNING:"
check_security 'v-html' "⚠️  Vue v-html directive - potential XSS" "🟡 WARNING:"
check_security '\[innerHTML\]' "⚠️  Angular innerHTML binding - potential XSS" "🟡 WARNING:"

# Dangerous JS functions
check_security '\beval\s*(' "⚠️  JavaScript eval() - arbitrary code execution" "🔴 CRITICAL:"
check_security '\bnew\s+Function\s*(' "⚠️  new Function() - similar to eval" "🔴 CRITICAL:"
check_security "setTimeout\\s*\\(\\s*[\"']" "⚠️  setTimeout with string - use function instead" "🟡 WARNING:"
check_security "setInterval\\s*\\(\\s*[\"']" "⚠️  setInterval with string - use function instead" "🟡 WARNING:"

# Node.js specific
check_security '\bchild_process' "⚠️  child_process module - command execution risk" "🔴 CRITICAL:"
check_security '\brequire.*child_process\|from.*child_process' "⚠️  child_process import" "🔴 CRITICAL:"
check_security '\bexecSync\|spawnSync' "⚠️  Sync command execution" "🔴 CRITICAL:"
check_security '\brequire\s*\(.*\+\|require\s*\(.*\$' "⚠️  Dynamic require - potential code injection" "🔴 CRITICAL:"

# Prototype pollution
check_security '__proto__' "⚠️  __proto__ access - prototype pollution risk" "🔴 CRITICAL:"
check_security 'constructor\[.prototype' "⚠️  constructor.prototype access - prototype pollution" "🔴 CRITICAL:"
check_security 'Object\.assign.*req\.' "⚠️  Object.assign with request data - prototype pollution" "🟡 WARNING:"

# URL handling
check_security 'location\.href.*=' "⚠️  location.href assignment - open redirect risk" "🟡 WARNING:"
check_security 'location\.replace' "⚠️  location.replace - open redirect risk" "🟡 WARNING:"
check_security 'window\.open.*\$\|window\.open.*\+' "⚠️  window.open with variable - verify URL" "🟡 WARNING:"

# ============================================
# WORDPRESS SPECIFIC CHECKS
# ============================================
output ""
output "── WordPress Security ──"

# Dangerous WordPress functions
check_security 'wp_remote_get.*\$_\|wp_remote_post.*\$_' "⚠️  Remote request with user input - SSRF risk" "🔴 CRITICAL:"
check_security 'wp_safe_remote' "[GOOD] Using wp_safe_remote (good practice)" "🟢 INFO:"
check_security 'update_option.*\$_' "⚠️  update_option with user input - verify capability" "🔴 CRITICAL:"
check_security 'delete_option.*\$_' "⚠️  delete_option with user input - verify capability" "🔴 CRITICAL:"
check_security 'add_option.*\$_' "⚠️  add_option with user input - verify capability" "🟡 WARNING:"
check_security 'update_user_meta.*\$_' "⚠️  update_user_meta with user input - verify permissions" "🟡 WARNING:"
check_security 'update_post_meta.*\$_' "⚠️  update_post_meta with user input - verify permissions" "🟡 WARNING:"
check_security 'wp_insert_post.*\$_' "⚠️  wp_insert_post with user input - verify sanitization" "🟡 WARNING:"
check_security 'wp_update_post.*\$_' "⚠️  wp_update_post with user input - verify sanitization" "🟡 WARNING:"
check_security 'wp_delete_post.*\$_' "⚠️  wp_delete_post with user input - verify capability" "🔴 CRITICAL:"
check_security 'switch_to_blog.*\$_' "⚠️  switch_to_blog with user input - multisite risk" "🔴 CRITICAL:"
check_security 'wpdb->query.*\$_' "⚠️  Direct wpdb query with user input" "🔴 CRITICAL:"
check_security 'add_query_arg.*echo\|print.*add_query_arg' "⚠️  add_query_arg output - wrap with esc_url()" "🟡 WARNING:"

# Authentication/Authorization
output ""
output "── Authentication & Authorization ──"
check_security 'is_admin\s*(' "⚠️  is_admin() - doesn't check user capability, use current_user_can()" "🟡 WARNING:"
check_security 'wp_set_auth_cookie' "⚠️  wp_set_auth_cookie - verify proper authentication flow" "🟡 WARNING:"
check_security 'wp_create_user.*\$_' "⚠️  wp_create_user with user input - registration security" "🟡 WARNING:"
check_security 'wp_insert_user.*\$_' "⚠️  wp_insert_user with user input - verify validation" "🟡 WARNING:"
check_security 'wp_update_user.*\$_' "⚠️  wp_update_user with user input - verify permissions" "🟡 WARNING:"
check_security 'add_user_to_blog.*\$_' "⚠️  add_user_to_blog with user input - multisite security" "🟡 WARNING:"
check_security 'set_role.*\$_' "⚠️  set_role with user input - privilege escalation risk" "🔴 CRITICAL:"
check_security 'add_cap.*\$_\|remove_cap.*\$_' "⚠️  Capability modification with user input" "🔴 CRITICAL:"

# Hardcoded secrets
output ""
output "── Hardcoded Secrets ──"
check_security "password.*=.*[\"'].{6,}" "⚠️  Possible hardcoded password" "🔴 CRITICAL:"
check_security "api_key.*=.*[\"'].{10,}" "⚠️  Possible hardcoded API key" "🔴 CRITICAL:"
check_security "secret.*=.*[\"'].{10,}" "⚠️  Possible hardcoded secret" "🔴 CRITICAL:"
check_security 'api_secret\|apiSecret\|API_SECRET' "⚠️  API secret reference - ensure not hardcoded" "🟡 WARNING:"
check_security 'private_key\|privateKey\|PRIVATE_KEY' "⚠️  Private key reference - ensure secure storage" "🟡 WARNING:"
check_security 'Authorization.*Bearer.*[A-Za-z0-9]' "⚠️  Possible hardcoded bearer token" "🔴 CRITICAL:"

# ============================================
# GOOD PRACTICES (Positive indicators)
# ============================================
output ""
output "── ✅ Good Security Practices Found ──"
check_security 'defined.*ABSPATH\|ABSPATH.*defined' "✅ ABSPATH check (prevents direct access)" "🟢 INFO:"
check_security 'current_user_can' "✅ Capability check found" "🟢 INFO:"
check_security 'wp_verify_nonce\|check_admin_referer\|check_ajax_referer' "✅ Nonce verification found" "🟢 INFO:"
check_security 'wp_nonce_field\|wp_create_nonce' "✅ Nonce creation found" "🟢 INFO:"
check_security 'sanitize_text_field\|sanitize_email\|sanitize_title' "✅ Input sanitization found" "🟢 INFO:"
check_security 'absint\|intval' "✅ Integer sanitization found" "🟢 INFO:"
check_security 'esc_html\|esc_attr\|esc_url\|esc_js' "✅ Output escaping found" "🟢 INFO:"
check_security 'wp_kses\|wp_kses_post' "✅ HTML sanitization found" "🟢 INFO:"
check_security '\$wpdb->prepare' "✅ Prepared statements found" "🟢 INFO:"
check_security 'wp_safe_redirect\|wp_redirect.*exit' "✅ Safe redirect pattern found" "🟢 INFO:"

output ""
output "=========================================="
output "📊 SUMMARY"
output "=========================================="
output "Files changed: $(echo "$CHANGED_FILES" | sed '/^\s*$/d' | wc -l | tr -d ' ')"
output "Lines added:   $(echo "$FILTERED_DIFF" | grep -c '^+' || echo 0)"
output "Lines removed: $(echo "$FILTERED_DIFF" | grep -c '^-' || echo 0)"
output "------------------------------------------"
output "🔴 Critical issues:  $CRITICAL_COUNT"
output "🟡 Warnings:         $WARNING_COUNT"
output "🔵 Items to review:  $REVIEW_COUNT"
output "------------------------------------------"
TOTAL_ISSUES=$((CRITICAL_COUNT + WARNING_COUNT))
if [ $TOTAL_ISSUES -eq 0 ]; then
    output "✅ No obvious security issues detected!"
elif [ $CRITICAL_COUNT -gt 0 ]; then
    output "🚨 ATTENTION: $CRITICAL_COUNT critical issue(s) require immediate review!"
else
    output "⚠️  Found $WARNING_COUNT warning(s) to review"
fi
output "=========================================="
output ""
output "Note: This is an automated check. Manual code review is still recommended."
output "False positives may occur. Always verify findings in context."
output ""
output "Legend:"
output "  🔴 CRITICAL - High risk, requires immediate attention"
output "  🟡 WARNING  - Medium risk, should be reviewed"
output "  🔵 REVIEW   - Low risk, verify proper implementation"
output "  🟢 INFO     - Good security practice detected"
output ""
output "Report saved to: $REPORT_FILE"

echo ""
echo "=========================================="
echo "📊 Results: 🔴 $CRITICAL_COUNT critical | 🟡 $WARNING_COUNT warnings | 🔵 $REVIEW_COUNT review"
echo "=========================================="
echo "📄 Report saved to: $REPORT_FILE"
