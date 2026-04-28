#!/usr/bin/env bash

set -uo pipefail

########################################
# 0. Configuration & Constants
########################################

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

# Safe find helper — avoids eval by building the argument array directly.
# Usage: find_php_files <root> [extra find args...]
find_php_files() {
    local root="$1"
    shift
    local cmd=(find "$root" -type f -name "*.php")
    for dir in "${EXCLUDE_DIRS[@]}"; do
        cmd+=(-not -path "*/${dir}/*")
    done
    [[ $# -gt 0 ]] && cmd+=("$@")
    "${cmd[@]}"
}

# Build grep exclusion pattern dynamically
GREP_EXCLUDES="/($(IFS="|"; echo "${EXCLUDE_DIRS[*]}"))"

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
    echo "  $0 /Applications/MAMP/htdocs/ftl-lw/wp-content/plugins/location-weather"
    echo "  $0 ../wp-content/plugins/my-plugin"
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
REPORT_BASE="$SCRIPT_DIR/security-reports"
REPORT_DIR="$REPORT_BASE/$PLUGIN_NAME"

mkdir -p "$REPORT_DIR"

########################################
# 3. Header
########################################

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        🔒 WordPress Plugin Security Analyzer                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 Plugin: $PLUGIN_NAME"
echo "📂 Plugin root: $PLUGIN_ROOT"
echo "📋 Reports directory: $REPORT_DIR"
echo "🕐 Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "────────────────────────────────────────────────────────────────────"
echo "🔍 Excluded directories: ${EXCLUDE_DIRS[*]}"
echo "────────────────────────────────────────────────────────────────────"

########################################
# 4. Statistics
########################################

echo "➡️  Gathering plugin statistics..."

TOTAL_PHP_FILES=$(find_php_files "$PLUGIN_ROOT" | wc -l | tr -d ' ')
# -exec … {} + batches files per invocation — faster than {} \;
TOTAL_PHP_LINES=$(find_php_files "$PLUGIN_ROOT" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')

cat > "$REPORT_DIR/00-statistics.txt" <<EOF
Plugin Statistics
=================
Plugin Name: $PLUGIN_NAME
Total PHP Files: $TOTAL_PHP_FILES
Total PHP Lines: $TOTAL_PHP_LINES
Excluded Directories: ${EXCLUDE_DIRS[*]}
Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')
EOF

echo "   ✓ Found $TOTAL_PHP_FILES PHP files ($TOTAL_PHP_LINES lines)"

########################################
# 5. Direct access protection check
########################################

echo "➡️  Checking ABSPATH / WPINC guards..."

# Pass the plugin root via env var to avoid shell-injection through the heredoc.
# The single-quoted <<'PHP' delimiter prevents bash from expanding anything inside.
PLUGIN_ROOT="$PLUGIN_ROOT" php <<'PHP' > "$REPORT_DIR/01-missing-abspath-guards.txt"
<?php

$pluginRoot = realpath(getenv('PLUGIN_ROOT'));
$found = 0;

$rii = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($pluginRoot, RecursiveDirectoryIterator::SKIP_DOTS),
    RecursiveIteratorIterator::LEAVES_ONLY
);

$skipDirs = [
    DIRECTORY_SEPARATOR . 'node_modules' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . '.git' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . '.github' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . 'vendor' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . 'tests' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . 'dist' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . 'build' . DIRECTORY_SEPARATOR,
    DIRECTORY_SEPARATOR . 'security-reports' . DIRECTORY_SEPARATOR,
];

echo "Missing ABSPATH/WPINC Guards\n";
echo "============================\n";
echo "Files without direct access protection:\n\n";

foreach ($rii as $file) {
    if ($file->getExtension() !== 'php') {
        continue;
    }

    $path = $file->getPathname();

    foreach ($skipDirs as $dir) {
        if (strpos($path, $dir) !== false) {
            continue 2;
        }
    }

    $content = @file_get_contents($path);
    if ($content === false) {
        continue;
    }

    if (
        strpos($content, "defined( 'ABSPATH' )") === false &&
        strpos($content, 'defined("ABSPATH")') === false &&
        strpos($content, "defined('ABSPATH')") === false &&
        strpos($content, 'WPINC') === false
    ) {
        $relativePath = str_replace($pluginRoot . DIRECTORY_SEPARATOR, '', $path);
        echo "⚠️  " . $relativePath . "\n";
        $found++;
    }
}

if ($found === 0) {
    echo "✅ All PHP files have proper direct access protection.\n";
} else {
    echo "\n────────────────────────────────────────\n";
    echo "Total files missing guards: $found\n";
}
PHP

MISSING_GUARDS=$(grep -c "⚠️" "$REPORT_DIR/01-missing-abspath-guards.txt" 2>/dev/null || echo "0")
if [ "$MISSING_GUARDS" -gt 0 ]; then
    echo "   ⚠️  Found $MISSING_GUARDS files without ABSPATH guards"
else
    echo "   ✅ All files have ABSPATH guards"
fi

########################################
# 6. High-risk functions scan
########################################

echo "➡️  Scanning for dangerous functions..."

{
    echo "High-Risk Functions Scan"
    echo "========================"
    echo "Scanning for: eval, exec, shell_exec, passthru, system, popen, proc_open, base64_decode"
    echo ""
} > "$REPORT_DIR/02-high-risk-functions.txt"

HIGH_RISK_COUNT=0

for func in "eval" "exec" "shell_exec" "passthru" "system" "popen" "proc_open" "base64_decode"; do
    MATCHES=$(grep -rn --include="*.php" "\b${func}\s*(" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || true)
    if [ -n "$MATCHES" ]; then
        echo "🔴 $func() found:" >> "$REPORT_DIR/02-high-risk-functions.txt"
        echo "$MATCHES" | while read -r line; do
            echo "   $line" >> "$REPORT_DIR/02-high-risk-functions.txt"
        done
        echo "" >> "$REPORT_DIR/02-high-risk-functions.txt"
        HIGH_RISK_COUNT=$((HIGH_RISK_COUNT + $(echo "$MATCHES" | wc -l | tr -d ' ')))
    fi
done

if [ "$HIGH_RISK_COUNT" -eq 0 ]; then
    echo "✅ No high-risk functions detected." >> "$REPORT_DIR/02-high-risk-functions.txt"
    echo "   ✅ No high-risk functions found"
else
    echo "────────────────────────────────────────" >> "$REPORT_DIR/02-high-risk-functions.txt"
    echo "Total high-risk function calls: $HIGH_RISK_COUNT" >> "$REPORT_DIR/02-high-risk-functions.txt"
    echo "   🔴 Found $HIGH_RISK_COUNT high-risk function calls"
fi

########################################
# 7. SQL Injection vulnerability scan
########################################

echo "➡️  Scanning for SQL injection vulnerabilities..."

{
    echo "SQL Injection Vulnerability Scan"
    echo "================================="
    echo ""
} > "$REPORT_DIR/03-sql-injection.txt"

{
    echo "Direct \$wpdb queries (potential SQL injection):"
    echo "------------------------------------------------"
    grep -rn --include="*.php" '\$wpdb->query(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "Direct \$wpdb->get_* calls:"
    echo "--------------------------"
    grep -rn --include="*.php" '\$wpdb->get_' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | grep -v "get_blog_prefix\|get_charset_collate" || echo "None found"
    echo ""

    echo "\$wpdb->prepare() usage (GOOD):"
    echo "------------------------------"
    PREPARE_COUNT=$(grep -rn --include="*.php" '\$wpdb->prepare' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
    echo "Found $PREPARE_COUNT uses of \$wpdb->prepare()"
} >> "$REPORT_DIR/03-sql-injection.txt"

DIRECT_QUERIES=$(grep -rn --include="*.php" '\$wpdb->query(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $DIRECT_QUERIES direct \$wpdb->query() calls"

########################################
# 8. XSS vulnerability scan
########################################

echo "➡️  Scanning for XSS vulnerabilities..."

{
    echo "XSS Vulnerability Scan"
    echo "======================"
    echo ""

    echo "Unescaped echo statements (potential XSS):"
    echo "------------------------------------------"
    # Exclude lines that already wrap the output in an escaping function
    grep -rn --include="*.php" 'echo \$' "$PLUGIN_ROOT" 2>/dev/null \
        | grep -vE "$GREP_EXCLUDES" \
        | grep -vE 'esc_html|esc_attr|esc_url|esc_js|wp_kses|intval|absint|sanitize_' \
        | head -50 || echo "None found"
    echo ""

    echo "phpcs:ignore comments (bypassed checks):"
    echo "----------------------------------------"
    grep -rn --include="*.php" 'phpcs:ignore' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "Escaping function usage summary:"
    echo "--------------------------------"
    echo "esc_html(): $(grep -r --include="*.php" 'esc_html(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "esc_attr(): $(grep -r --include="*.php" 'esc_attr(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "esc_url(): $(grep -r --include="*.php" 'esc_url(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "esc_js(): $(grep -r --include="*.php" 'esc_js(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "wp_kses*(): $(grep -r --include="*.php" 'wp_kses' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
} > "$REPORT_DIR/04-xss-vulnerabilities.txt"

PHPCS_IGNORE=$(grep -rn --include="*.php" 'phpcs:ignore' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $PHPCS_IGNORE phpcs:ignore comments"

########################################
# 9. User input handling scan
########################################

echo "➡️  Scanning user input handling..."

{
    echo "User Input Handling Scan"
    echo "========================"
    echo ""

    echo "\$_GET usage:"
    echo "------------"
    grep -rn --include="*.php" '\$_GET\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "\$_POST usage:"
    echo "-------------"
    grep -rn --include="*.php" '\$_POST\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "\$_REQUEST usage:"
    echo "----------------"
    grep -rn --include="*.php" '\$_REQUEST\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "\$_COOKIE usage:"
    echo "---------------"
    grep -rn --include="*.php" '\$_COOKIE\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "Sanitization function usage:"
    echo "----------------------------"
    echo "sanitize_text_field(): $(grep -r --include="*.php" 'sanitize_text_field(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "sanitize_email(): $(grep -r --include="*.php" 'sanitize_email(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "absint(): $(grep -r --include="*.php" 'absint(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "intval(): $(grep -r --include="*.php" 'intval(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "wp_unslash(): $(grep -r --include="*.php" 'wp_unslash(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
} > "$REPORT_DIR/05-user-input-handling.txt"

GET_USAGE=$(grep -rn --include="*.php" '\$_GET\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
POST_USAGE=$(grep -rn --include="*.php" '\$_POST\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $GET_USAGE \$_GET and $POST_USAGE \$_POST usages"

########################################
# 10. AJAX handlers scan
########################################

echo "➡️  Scanning AJAX & REST handlers..."

{
    echo "AJAX & REST Handlers Scan"
    echo "========================="
    echo ""

    echo "wp_ajax_ handlers (authenticated):"
    echo "-----------------------------------"
    grep -rn --include="*.php" "add_action.*wp_ajax_[^n]" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "wp_ajax_nopriv_ handlers (PUBLIC - verify security!):"
    echo "------------------------------------------------------"
    grep -rn --include="*.php" "wp_ajax_nopriv_" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "REST API routes:"
    echo "----------------"
    grep -rn --include="*.php" "register_rest_route" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/06-ajax-rest-handlers.txt"

NOPRIV_AJAX=$(grep -rn --include="*.php" "wp_ajax_nopriv_" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$NOPRIV_AJAX" -gt 0 ]; then
    echo "   ⚠️  Found $NOPRIV_AJAX public (nopriv) AJAX handlers"
else
    echo "   ✅ No public AJAX handlers"
fi

########################################
# 11. Nonce & capability checks
########################################

echo "➡️  Scanning nonce & capability checks..."

{
    echo "Nonce & Capability Checks"
    echo "========================="
    echo ""

    echo "Nonce verification:"
    echo "-------------------"
    echo "wp_verify_nonce(): $(grep -r --include="*.php" 'wp_verify_nonce' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "check_admin_referer(): $(grep -r --include="*.php" 'check_admin_referer' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "check_ajax_referer(): $(grep -r --include="*.php" 'check_ajax_referer' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo "wp_nonce_field(): $(grep -r --include="*.php" 'wp_nonce_field(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo ""

    echo "Capability checks:"
    echo "------------------"
    echo "current_user_can(): $(grep -r --include="*.php" 'current_user_can(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ') uses"
    echo ""

    echo "Nonce verification locations:"
    echo "-----------------------------"
    grep -rn --include="*.php" 'wp_verify_nonce' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/07-nonce-capability-checks.txt"

NONCE_COUNT=$(grep -r --include="*.php" 'wp_verify_nonce\|check_admin_referer\|check_ajax_referer' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
CAP_COUNT=$(grep -r --include="*.php" 'current_user_can(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $NONCE_COUNT nonce checks and $CAP_COUNT capability checks"

########################################
# 12. Deprecated functions scan
########################################

echo "➡️  Scanning for deprecated functions..."

{
    echo "Deprecated Functions Scan"
    echo "========================="
    echo ""

    echo "FILTER_SANITIZE_STRING (deprecated PHP 8.1+):"
    echo "----------------------------------------------"
    grep -rn --include="*.php" 'FILTER_SANITIZE_STRING' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "mysql_* functions (deprecated):"
    echo "-------------------------------"
    grep -rn --include="*.php" '\bmysql_' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "ereg() function (deprecated):"
    echo "-----------------------------"
    grep -rn --include="*.php" '\bereg(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "create_function() (deprecated PHP 7.2+):"
    echo "----------------------------------------"
    grep -rn --include="*.php" 'create_function(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "split() function (deprecated):"
    echo "------------------------------"
    grep -rn --include="*.php" '\bsplit(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/08-deprecated-functions.txt"

DEPRECATED=$(grep -rn --include="*.php" 'FILTER_SANITIZE_STRING\|\bmysql_\|\bereg(\|create_function(\|\bsplit(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$DEPRECATED" -gt 0 ]; then
    echo "   ⚠️  Found $DEPRECATED deprecated function usages"
else
    echo "   ✅ No deprecated functions found"
fi

########################################
# 13. Object Injection scan
########################################

echo "➡️  Scanning for object injection vulnerabilities..."

{
    echo "Object Injection Vulnerability Scan"
    echo "===================================="
    echo ""

    echo "unserialize() usage (potential object injection):"
    echo "--------------------------------------------------"
    grep -rn --include="*.php" '\bunserialize(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "maybe_unserialize() usage (safer):"
    echo "-----------------------------------"
    grep -rn --include="*.php" 'maybe_unserialize(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/09-object-injection.txt"

UNSERIALIZE=$(grep -rn --include="*.php" '\bunserialize(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$UNSERIALIZE" -gt 0 ]; then
    echo "   ⚠️  Found $UNSERIALIZE unserialize() calls"
else
    echo "   ✅ No unsafe unserialize() calls"
fi

########################################
# 14. Hardcoded credentials scan
########################################

echo "➡️  Scanning for hardcoded credentials..."

{
    echo "Hardcoded Credentials Scan"
    echo "=========================="
    echo ""

    echo "Potential API keys/secrets:"
    echo "---------------------------"
    grep -rn --include="*.php" -iE "(api[_-]?key|secret[_-]?key|password|token|auth)\s*[=:>]\s*['\"][a-zA-Z0-9]" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | head -30 || echo "None found"
    echo ""

    echo "define() with potential secrets:"
    echo "---------------------------------"
    grep -rn --include="*.php" -iE "define\s*\(\s*['\"].*?(KEY|SECRET|TOKEN|PASSWORD)" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/10-hardcoded-credentials.txt"

HARDCODED=$(grep -rn --include="*.php" -iE "(api[_-]?key|secret|password|token)\s*[=:>]\s*['\"][a-zA-Z0-9]" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$HARDCODED" -gt 0 ]; then
    echo "   ⚠️  Found $HARDCODED potential hardcoded credentials"
else
    echo "   ✅ No obvious hardcoded credentials"
fi

########################################
# 15. File operations scan
########################################

echo "➡️  Scanning file operations..."

{
    echo "File Operations Scan"
    echo "===================="
    echo ""

    echo "file_put_contents():"
    echo "--------------------"
    grep -rn --include="*.php" 'file_put_contents(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "file_get_contents():"
    echo "--------------------"
    grep -rn --include="*.php" 'file_get_contents(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "fopen()/fwrite():"
    echo "-----------------"
    grep -rn --include="*.php" '\bfopen(\|\bfwrite(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/11-file-operations.txt"

FILE_OPS=$(grep -rn --include="*.php" 'file_put_contents(\|file_get_contents(\|fopen(\|fwrite(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $FILE_OPS file operation calls"

########################################
# 16. Remote requests scan
########################################

echo "➡️  Scanning remote HTTP requests..."

{
    echo "Remote HTTP Requests Scan"
    echo "========================="
    echo ""

    echo "wp_remote_* (WordPress HTTP API):"
    echo "----------------------------------"
    grep -rn --include="*.php" 'wp_remote_' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "curl functions:"
    echo "---------------"
    grep -rn --include="*.php" '\bcurl_' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "Remote URLs in code:"
    echo "--------------------"
    grep -rn --include="*.php" -E "https?://[^'\"\s]+" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES|wordpress\.org|w3\.org|schema\.org|openweathermap\.org|weatherapi\.com" | head -20 || echo "None found"
} > "$REPORT_DIR/12-remote-requests.txt"

REMOTE_CALLS=$(grep -rn --include="*.php" 'wp_remote_\|curl_' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
echo "   Found $REMOTE_CALLS remote HTTP calls"

########################################
# 17. Uninstall safety check
########################################

echo "➡️  Checking uninstall safety..."

{
    echo "Uninstall Safety Check"
    echo "======================"
    echo ""

    if [ -f "$PLUGIN_ROOT/uninstall.php" ]; then
        echo "✅ uninstall.php found"
        echo ""
        echo "Content preview:"
        echo "----------------"
        head -50 "$PLUGIN_ROOT/uninstall.php"
    else
        echo "⚠️  uninstall.php NOT found"
    fi
    echo ""

    echo "register_uninstall_hook usage:"
    echo "------------------------------"
    grep -rn --include="*.php" "register_uninstall_hook" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/13-uninstall-safety.txt"

if [ -f "$PLUGIN_ROOT/uninstall.php" ]; then
    echo "   ✅ uninstall.php exists"
else
    echo "   ⚠️  uninstall.php not found"
fi

########################################
# 18. Dynamic includes scan (LFI risk)
########################################

echo "➡️  Scanning for dynamic includes..."

{
    echo "Dynamic Include/Require Scan"
    echo "============================"
    echo ""

    echo "include/require with variable paths (potential LFI):"
    echo "-----------------------------------------------------"
    grep -rn --include="*.php" -E "(include|require)(_once)?\s*[\('\"]*\s*\\\$" "$PLUGIN_ROOT" 2>/dev/null \
        | grep -vE "$GREP_EXCLUDES" \
        || echo "None found"
    echo ""

    echo "include/require with user-controlled superglobals (HIGH RISK):"
    echo "----------------------------------------------------------------"
    grep -rn --include="*.php" -E "(include|require)(_once)?\s*.*\\\$_(GET|POST|REQUEST|COOKIE|SERVER)" "$PLUGIN_ROOT" 2>/dev/null \
        | grep -vE "$GREP_EXCLUDES" \
        || echo "None found"
} > "$REPORT_DIR/14-dynamic-includes.txt"

DYNAMIC_INCLUDES=$(grep -rn --include="*.php" -E "(include|require)(_once)?\s*[\('\"]*\s*\\\$" "$PLUGIN_ROOT" 2>/dev/null \
    | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$DYNAMIC_INCLUDES" -gt 0 ]; then
    echo "   ⚠️  Found $DYNAMIC_INCLUDES dynamic include/require statements"
else
    echo "   ✅ No dynamic includes found"
fi

########################################
# 19. File upload vulnerability scan
########################################

echo "➡️  Scanning file upload handling..."

{
    echo "File Upload Vulnerability Scan"
    echo "=============================="
    echo ""

    echo "\$_FILES usage:"
    echo "--------------"
    grep -rn --include="*.php" '\$_FILES\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "wp_handle_upload() (safe WordPress upload handler):"
    echo "----------------------------------------------------"
    grep -rn --include="*.php" 'wp_handle_upload(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "wp_check_filetype*() (MIME type validation):"
    echo "--------------------------------------------"
    grep -rn --include="*.php" 'wp_check_filetype' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "move_uploaded_file() — prefer wp_handle_upload():"
    echo "--------------------------------------------------"
    grep -rn --include="*.php" 'move_uploaded_file(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/15-file-uploads.txt"

FILE_UPLOADS=$(grep -rn --include="*.php" '\$_FILES\[' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$FILE_UPLOADS" -gt 0 ]; then
    echo "   ⚠️  Found $FILE_UPLOADS \$_FILES usages — verify MIME and extension checks"
else
    echo "   ✅ No file upload handling found"
fi

########################################
# 20. Redirect safety scan
########################################

echo "➡️  Scanning redirect safety..."

{
    echo "Redirect Safety Scan"
    echo "===================="
    echo ""

    echo "wp_redirect() — prefer wp_safe_redirect() for user-controlled URLs:"
    echo "---------------------------------------------------------------------"
    grep -rn --include="*.php" '\bwp_redirect(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "wp_safe_redirect() (GOOD):"
    echo "--------------------------"
    grep -rn --include="*.php" 'wp_safe_redirect(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
    echo ""

    echo "header('Location:') — direct redirect, bypasses WordPress:"
    echo "------------------------------------------------------------"
    grep -rn --include="*.php" -i "header\s*(\s*['\"]Location" "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" || echo "None found"
} > "$REPORT_DIR/16-redirect-safety.txt"

UNSAFE_REDIRECT=$(grep -rn --include="*.php" '\bwp_redirect(' "$PLUGIN_ROOT" 2>/dev/null | grep -vE "$GREP_EXCLUDES" | wc -l | tr -d ' ')
if [ "$UNSAFE_REDIRECT" -gt 0 ]; then
    echo "   ⚠️  Found $UNSAFE_REDIRECT wp_redirect() calls (prefer wp_safe_redirect)"
else
    echo "   ✅ No wp_redirect() calls found"
fi

########################################
# 21. AJAX handlers missing capability checks
########################################

echo "➡️  Checking AJAX handlers for missing capability checks..."

# PHP does the cross-reference: find every add_action('wp_ajax_*') registration,
# locate the callback function body in the codebase, and report any that lack
# a current_user_can() call — the exact class of vulnerability shown in CVEs where
# nonce checks exist but privilege level is never verified.
PLUGIN_ROOT="$PLUGIN_ROOT" php <<'PHP' > "$REPORT_DIR/17-ajax-missing-capability.txt"
<?php

$pluginRoot = realpath(getenv('PLUGIN_ROOT'));
$skipDirs   = ['node_modules', '.git', '.github', 'vendor', 'tests', 'dist', 'build', 'security-reports'];

// Collect all PHP files, honouring excluded dirs
$allFiles = [];
$rii = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($pluginRoot, RecursiveDirectoryIterator::SKIP_DOTS),
    RecursiveIteratorIterator::LEAVES_ONLY
);
foreach ($rii as $file) {
    if ($file->getExtension() !== 'php') continue;
    $path = $file->getPathname();
    foreach ($skipDirs as $d) {
        if (strpos($path, DIRECTORY_SEPARATOR . $d . DIRECTORY_SEPARATOR) !== false) continue 2;
    }
    $allFiles[] = $path;
}

// ── Step 1: collect all wp_ajax_* hook registrations ─────────────────────────
// Handles: 'callback', "callback", array($this,'method'), [$this,'method']
$handlers = [];
foreach ($allFiles as $path) {
    $lines = file($path);
    foreach ($lines as $i => $line) {
        if (!preg_match(
            "/add_action\s*\(\s*['\"]wp_ajax_(nopriv_)?([^'\"]+)['\"](.+)/",
            $line, $m
        )) continue;

        $nopriv = !empty($m[1]);
        $hook   = 'wp_ajax_' . $m[1] . $m[2];
        $rest   = $m[3];

        // Extract the callback name (method or function)
        $callback = '';
        if (preg_match("/['\"](\w+)['\"](?:\s*[\),])/", $rest, $cm)) {
            $callback = $cm[1];
        }

        if ($callback !== '') {
            $handlers[] = [
                'hook'     => $hook,
                'callback' => $callback,
                'nopriv'   => $nopriv,
                'file'     => str_replace($pluginRoot . DIRECTORY_SEPARATOR, '', $path),
                'line'     => $i + 1,
            ];
        }
    }
}

// ── Step 2: for each callback, find its function body and inspect it ──────────
echo "AJAX Handlers Missing Capability Checks\n";
echo "========================================\n\n";

$issues  = 0;
$checked = 0;

foreach ($handlers as $h) {
    foreach ($allFiles as $path) {
        $content = file_get_contents($path);

        // Locate "function callback_name(...) {"
        if (!preg_match(
            '/function\s+' . preg_quote($h['callback'], '/') . '\s*\([^)]*\)\s*\{/s',
            $content, $found, PREG_OFFSET_CAPTURE
        )) continue;

        // Walk the brace tree to extract the complete function body
        $start = $found[0][1] + strlen($found[0][0]) - 1;
        $depth = 0;
        $body  = '';
        for ($pos = $start, $len = strlen($content); $pos < $len; $pos++) {
            $c = $content[$pos];
            if ($c === '{')      $depth++;
            elseif ($c === '}') { $depth--; if ($depth === 0) break; }
            $body .= $c;
        }

        $checked++;
        if (strpos($body, 'current_user_can') === false) {
            $rel = str_replace($pluginRoot . DIRECTORY_SEPARATOR, '', $path);
            echo "WARNING: {$h['file']}:{$h['line']}\n";
            echo "  Hook:     {$h['hook']}" . ($h['nopriv'] ? ' (PUBLIC/nopriv)' : ' (authenticated)') . "\n";
            echo "  Callback: {$h['callback']}()  [defined in $rel]\n";
            echo "  Issue:    AJAX callback has no current_user_can() capability check\n\n";
            $issues++;
        }
        break; // found the function definition — stop searching other files
    }
}

if ($issues === 0) {
    $msg = $checked > 0
        ? "OK All $checked located AJAX callbacks have capability checks.\n"
        : "OK No AJAX handlers found or no callback functions could be located.\n";
    echo $msg;
} else {
    echo "Total AJAX handlers missing capability checks: $issues\n";
}
PHP

AJAX_NO_CAP=$(grep -c "^WARNING:" "$REPORT_DIR/17-ajax-missing-capability.txt" 2>/dev/null || echo "0")
if [ "$AJAX_NO_CAP" -gt 0 ]; then
    echo "   🔴 Found $AJAX_NO_CAP AJAX handlers missing capability checks"
else
    echo "   ✅ All located AJAX handlers have capability checks"
fi

########################################
# 22. REST routes missing permission_callback
########################################

echo "➡️  Checking REST routes for missing permission_callback..."

PLUGIN_ROOT="$PLUGIN_ROOT" php <<'PHP' > "$REPORT_DIR/18-rest-missing-permission.txt"
<?php

$pluginRoot = realpath(getenv('PLUGIN_ROOT'));
$skipDirs   = ['node_modules', '.git', '.github', 'vendor', 'tests', 'dist', 'build', 'security-reports'];

$allFiles = [];
$rii = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($pluginRoot, RecursiveDirectoryIterator::SKIP_DOTS),
    RecursiveIteratorIterator::LEAVES_ONLY
);
foreach ($rii as $file) {
    if ($file->getExtension() !== 'php') continue;
    $path = $file->getPathname();
    foreach ($skipDirs as $d) {
        if (strpos($path, DIRECTORY_SEPARATOR . $d . DIRECTORY_SEPARATOR) !== false) continue 2;
    }
    $allFiles[] = $path;
}

echo "REST Routes Missing permission_callback\n";
echo "========================================\n\n";

$issues = 0;
$open   = 0;

foreach ($allFiles as $path) {
    $content = file_get_contents($path);
    $lines   = explode("\n", $content);

    foreach ($lines as $i => $line) {
        if (strpos($line, 'register_rest_route') === false) continue;

        // Grab the next ~25 lines to capture the route array definition
        $chunk = implode("\n", array_slice($lines, $i, 25));
        $rel   = str_replace($pluginRoot . DIRECTORY_SEPARATOR, '', $path);

        if (strpos($chunk, 'permission_callback') === false) {
            echo "WARNING: $rel:" . ($i + 1) . "\n";
            echo "  Issue: register_rest_route() with no permission_callback detected\n";
            echo "  Fix:   Add 'permission_callback' to restrict access, or '__return_true' for intentionally public routes\n\n";
            $issues++;
        } elseif (preg_match("/'permission_callback'\s*=>\s*'__return_true'/", $chunk)) {
            echo "OPEN:   $rel:" . ($i + 1) . "\n";
            echo "  Note:  Route uses __return_true — intentionally public, verify this is correct\n\n";
            $open++;
        }
    }
}

if ($issues === 0 && $open === 0) {
    echo "OK All REST routes have a permission_callback.\n";
} else {
    echo "Total routes missing permission_callback: $issues\n";
    echo "Total intentionally public routes (__return_true): $open\n";
}
PHP

REST_NO_PERM=$(grep -c "^WARNING:" "$REPORT_DIR/18-rest-missing-permission.txt" 2>/dev/null || echo "0")
REST_OPEN=$(grep -c "^OPEN:" "$REPORT_DIR/18-rest-missing-permission.txt" 2>/dev/null || echo "0")
if [ "$REST_NO_PERM" -gt 0 ]; then
    echo "   🔴 Found $REST_NO_PERM REST routes missing permission_callback"
elif [ "$REST_OPEN" -gt 0 ]; then
    echo "   ⚠️  Found $REST_OPEN intentionally public REST routes — verify intent"
else
    echo "   ✅ All REST routes have permission_callback"
fi

########################################
# 23. Generate Summary Report
########################################

echo "➡️  Generating summary report..."

{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           SECURITY ANALYSIS SUMMARY REPORT                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Plugin: $PLUGIN_NAME"
    echo "Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Plugin Path: $PLUGIN_ROOT"
    echo "Excluded Directories: ${EXCLUDE_DIRS[*]}"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "STATISTICS"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Total PHP Files: $TOTAL_PHP_FILES"
    echo "Total PHP Lines: $TOTAL_PHP_LINES"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "SECURITY FINDINGS SUMMARY"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    # Use plain-text severity labels — emoji chars have variable display width
    # and break printf column alignment in most terminals.
    echo "┌─────────────────────────────────────┬──────────┬─────────────────┐"
    echo "│ Check                               │ Count    │ Severity        │"
    echo "├─────────────────────────────────────┼──────────┼─────────────────┤"
    printf "│ %-35s │ %8s │ %-15s │\n" "Missing ABSPATH guards"      "$MISSING_GUARDS"    "$([ "$MISSING_GUARDS" -gt 0 ]    && echo "MEDIUM"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "High-risk functions"          "$HIGH_RISK_COUNT"   "$([ "$HIGH_RISK_COUNT" -gt 0 ]   && echo "CRITICAL"  || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Direct DB queries"            "$DIRECT_QUERIES"    "$([ "$DIRECT_QUERIES" -gt 0 ]    && echo "REVIEW"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "phpcs:ignore comments"        "$PHPCS_IGNORE"      "$([ "$PHPCS_IGNORE" -gt 0 ]      && echo "REVIEW"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Public AJAX handlers"         "$NOPRIV_AJAX"       "$([ "$NOPRIV_AJAX" -gt 0 ]       && echo "REVIEW"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Deprecated functions"         "$DEPRECATED"        "$([ "$DEPRECATED" -gt 0 ]        && echo "MEDIUM"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Unsafe unserialize()"         "$UNSERIALIZE"       "$([ "$UNSERIALIZE" -gt 0 ]       && echo "CRITICAL"  || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Potential hardcoded creds"    "$HARDCODED"         "$([ "$HARDCODED" -gt 0 ]         && echo "CRITICAL"  || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "Dynamic includes (LFI risk)"  "$DYNAMIC_INCLUDES"  "$([ "$DYNAMIC_INCLUDES" -gt 0 ]  && echo "HIGH"      || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "File uploads (\$_FILES)"      "$FILE_UPLOADS"      "$([ "$FILE_UPLOADS" -gt 0 ]      && echo "REVIEW"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "wp_redirect() calls"          "$UNSAFE_REDIRECT"   "$([ "$UNSAFE_REDIRECT" -gt 0 ]   && echo "REVIEW"    || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "AJAX missing capability check" "$AJAX_NO_CAP"       "$([ "$AJAX_NO_CAP" -gt 0 ]       && echo "CRITICAL"  || echo "OK")"
    printf "│ %-35s │ %8s │ %-15s │\n" "REST missing permission_cb"    "$REST_NO_PERM"      "$([ "$REST_NO_PERM" -gt 0 ]      && echo "CRITICAL"  || echo "OK")"
    echo "└─────────────────────────────────────┴──────────┴─────────────────┘"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "SECURITY MEASURES FOUND"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Nonce verifications: $NONCE_COUNT"
    echo "Capability checks:   $CAP_COUNT"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "DETAILED REPORTS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    for report in "$REPORT_DIR"/*.txt; do
        [ -f "$report" ] && echo "  $(basename "$report")"
    done
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "RECOMMENDATIONS"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""

    if [ "$HIGH_RISK_COUNT" -gt 0 ]; then
        echo "CRITICAL: Review high-risk function usage in 02-high-risk-functions.txt"
    fi
    if [ "$UNSERIALIZE" -gt 0 ]; then
        echo "CRITICAL: Replace unserialize() with maybe_unserialize()"
    fi
    if [ "$HARDCODED" -gt 0 ]; then
        echo "CRITICAL: Move hardcoded credentials to wp-config.php or options"
    fi
    if [ "$DYNAMIC_INCLUDES" -gt 0 ]; then
        echo "HIGH: Review dynamic includes in 14-dynamic-includes.txt for LFI risk"
    fi
    if [ "$DEPRECATED" -gt 0 ]; then
        echo "MEDIUM: Update deprecated functions for PHP 8.x compatibility"
    fi
    if [ "$MISSING_GUARDS" -gt 0 ]; then
        echo "MEDIUM: Add ABSPATH checks to all PHP files"
    fi
    if [ "$NOPRIV_AJAX" -gt 0 ]; then
        echo "REVIEW: Verify public AJAX handlers have proper security"
    fi
    if [ "$DIRECT_QUERIES" -gt 0 ]; then
        echo "REVIEW: Ensure all DB queries use \$wpdb->prepare()"
    fi
    if [ "$FILE_UPLOADS" -gt 0 ]; then
        echo "REVIEW: Ensure \$_FILES handling uses wp_handle_upload() with MIME validation"
    fi
    if [ "$UNSAFE_REDIRECT" -gt 0 ]; then
        echo "REVIEW: Consider replacing wp_redirect() with wp_safe_redirect()"
    fi
    if [ "$AJAX_NO_CAP" -gt 0 ]; then
        echo "CRITICAL: AJAX callbacks missing current_user_can() — see 17-ajax-missing-capability.txt"
        echo "          Add capability check alongside the existing nonce check in each handler."
    fi
    if [ "$REST_NO_PERM" -gt 0 ]; then
        echo "CRITICAL: REST routes with no permission_callback — see 18-rest-missing-permission.txt"
        echo "          Add a permission_callback that calls current_user_can() or return WP_Error."
    fi
    if [ "$REST_OPEN" -gt 0 ]; then
        echo "REVIEW:   $REST_OPEN REST routes use __return_true — confirm public access is intentional."
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════════"

} > "$REPORT_DIR/00-SUMMARY.txt"

########################################
# Final Summary
########################################

echo ""
echo "────────────────────────────────────────────────────────────────────"
echo "✅ Security analysis completed for: $PLUGIN_NAME"
echo ""
echo "📌 Reports generated in: $REPORT_DIR"
echo ""
echo "📄 Report files:"
ls -1 "$REPORT_DIR"/*.txt | while read -r file; do
    echo "   - $(basename "$file")"
done
echo ""
echo "📊 Quick view summary: cat $REPORT_DIR/00-SUMMARY.txt"
echo "────────────────────────────────────────────────────────────────────"
