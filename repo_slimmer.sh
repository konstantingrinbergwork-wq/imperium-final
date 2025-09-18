#!/bin/bash
set -euo pipefail

SOURCE_DIR="/opt/imperium"
DRY_RUN=false
TARGET_BRANCH="release-clean"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --branch) TARGET_BRANCH="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo "Repository Slimmer - $([ "$DRY_RUN" = true ] && echo "DRY RUN" || echo "EXECUTE")"

INCLUDE_PATTERNS=("api" "adapt_pack" "sql" "db" "migrations" "pinf_install" "etc" "conf" "config" "docs" "tools" "tests" ".github" "README*" "LICENSE*" "requirements*.txt" "pyproject.toml" "poetry.lock" "Dockerfile*" "docker-compose*.yml" "Makefile" "*.sh" ".env.example" ".editorconfig")

EXCLUDE_PATTERNS=("logs" "*.log" "*.log.*" "*.log.gz" "ops/prometheus/data" "*/venv" "venv" "__pycache__" "node_modules" "*.tar.gz" "*.zip" "*.dump" "*.bak" "*.tmp" "*.swp" ".env" "*.secret" "*password*" "*jwt*" "*token*" "*.pyc" "*.pyo" ".pytest_cache" ".mypy_cache" "*.prom")

TEMP_DIR="/tmp/imperium_clean_$$"
mkdir -p "$TEMP_DIR"
INCLUDE_LIST="$TEMP_DIR/include.txt"
EXCLUDE_LIST="$TEMP_DIR/exclude.txt"
BIG_FILES="$TEMP_DIR/big_files.txt"

echo "Scanning files..."
find "$SOURCE_DIR" -type f | while read -r file; do
    rel_path="${file#$SOURCE_DIR/}"
    should_include=false
    should_exclude=false
    file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    
    for pattern in "${INCLUDE_PATTERNS[@]}"; do
        if [[ "$rel_path" == $pattern ]] || [[ "$rel_path" == *"/$pattern"* ]] || [[ "$(basename "$file")" == $pattern ]]; then
            should_include=true
            break
        fi
    done
    
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$rel_path" == *"$pattern"* ]] || [[ "$(basename "$file")" == $pattern ]]; then
            should_exclude=true
            break
        fi
    done
    
    if [[ $file_size -gt 1048576 ]]; then
        echo "$((file_size / 1048576)) MB: $rel_path" >> "$BIG_FILES"
    fi
    
    if [[ "$should_include" == true ]] && [[ "$should_exclude" == false ]]; then
        echo "$rel_path" >> "$INCLUDE_LIST"
    else
        echo "$rel_path" >> "$EXCLUDE_LIST"
    fi
done

include_count=$(wc -l < "$INCLUDE_LIST" 2>/dev/null || echo 0)
exclude_count=$(wc -l < "$EXCLUDE_LIST" 2>/dev/null || echo 0)

total_size=0
while read -r file; do
    full_path="$SOURCE_DIR/$file"
    if [[ -f "$full_path" ]]; then
        size=$(stat -c%s "$full_path" 2>/dev/null || echo 0)
        total_size=$((total_size + size))
    fi
done < "$INCLUDE_LIST" 2>/dev/null || true
total_mb=$((total_size / 1048576))

echo
echo "STATISTICS:"
echo "  Files to include: $include_count"
echo "  Files to exclude: $exclude_count"
echo "  Estimated size: ${total_mb} MB"
echo "  Status: $([ $include_count -le 2000 ] && [ $total_mb -le 200 ] && echo "Within limits" || echo "EXCEEDS LIMITS")"

echo
echo "Top 20 files to include:"
head -20 "$INCLUDE_LIST" 2>/dev/null || echo "None"

echo
echo "Top 20 files to exclude:"
head -20 "$EXCLUDE_LIST" 2>/dev/null || echo "None"

echo
echo "Big files (>1MB):"
head -20 "$BIG_FILES" 2>/dev/null || echo "None"

if [[ "$DRY_RUN" == false ]]; then
    echo
    read -p "Create clean branch $TARGET_BRANCH? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git checkout --orphan "$TARGET_BRANCH" 2>/dev/null || git checkout "$TARGET_BRANCH"
        git rm -rf . 2>/dev/null || true
        
        while read -r file; do
            source_file="$SOURCE_DIR/$file"
            target_file="./$file"
            if [[ -f "$source_file" ]]; then
                mkdir -p "$(dirname "$target_file")"
                cp "$source_file" "$target_file"
            fi
        done < "$INCLUDE_LIST"
        
        echo "Clean branch created successfully!"
    fi
fi

rm -rf "$TEMP_DIR"
