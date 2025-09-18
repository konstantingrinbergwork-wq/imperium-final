#!/bin/bash
set -euo pipefail

SOURCE="/opt/imperium"
TARGET_BRANCH="release-clean"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

echo "ULTIMATE IMPERIUM CLEANER - $([ "$DRY_RUN" = true ] && echo "DRY RUN" || echo "EXECUTE")"

# Умный whitelist на основе реального анализа
CLEAN_DIRS=(
    "migrations"
    "db" 
    "sql"
    "api"
    "adapt_pack"
    "pinf_install"
    "etc"
    "tools"
    "tests"
    ".github"
)

CLEAN_FILES=(
    "README*"
    "LICENSE*" 
    "requirements*.txt"
    "pyproject.toml"
    "poetry.lock"
    "Dockerfile*"
    "docker-compose*.yml"
    "Makefile"
    "*.sh"
    ".env.example"
    ".gitignore"
    ".gitattributes"
    ".editorconfig"
)

# Умное исключение мусора
JUNK_PATTERNS=(
    "backups"          # 3.6GB архивов
    "venv"             # 298MB Python окружение  
    "logs"             # 1219 логов
    "__pycache__"      # 717 Python cache
    "node_modules"     # Node зависимости
    "ops/prometheus/data"  # Данные мониторинга
    "*.log"
    "*.tar.gz"
    "*.zip"
    "*.pyc"
    "*.bak"
    "*.tmp"
)

TEMP="/tmp/imperium_ultra_clean"
rm -rf "$TEMP" && mkdir -p "$TEMP"

echo "Анализ файлов..."
total_size=0
file_count=0

# Собираем только нужные файлы
for dir in "${CLEAN_DIRS[@]}"; do
    if [[ -d "$SOURCE/$dir" ]]; then
        echo "Сканируем $dir..."
        find "$SOURCE/$dir" -type f | while read -r file; do
            rel_path="${file#$SOURCE/}"
            is_junk=false
            
            # Проверяем на мусор
            for pattern in "${JUNK_PATTERNS[@]}"; do
                if [[ "$rel_path" == *"$pattern"* ]]; then
                    is_junk=true
                    break
                fi
            done
            
            if [[ "$is_junk" == false ]]; then
                echo "$rel_path" >> "$TEMP/include.txt"
                size=$(stat -c%s "$file" 2>/dev/null || echo 0)
                echo "$size" >> "$TEMP/sizes.txt"
            fi
        done
    fi
done

# Добавляем корневые файлы
for pattern in "${CLEAN_FILES[@]}"; do
    find "$SOURCE" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | while read -r file; do
        rel_path="${file#$SOURCE/}"
        echo "$rel_path" >> "$TEMP/include.txt"
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        echo "$size" >> "$TEMP/sizes.txt"
    done
done

# Статистика
if [[ -f "$TEMP/include.txt" ]]; then
    file_count=$(wc -l < "$TEMP/include.txt")
    total_size=$(awk '{sum+=$1} END {print int(sum/1048576)}' "$TEMP/sizes.txt" 2>/dev/null || echo 0)
else
    file_count=0
    total_size=0
fi

echo
echo "=== РЕЗУЛЬТАТ АНАЛИЗА ==="
echo "Файлов к включению: $file_count"
echo "Примерный размер: ${total_size} MB"
echo "Статус: $([ $file_count -le 2000 ] && [ $total_size -le 200 ] && echo "✅ В пределах лимитов" || echo "❌ ПРЕВЫШАЕТ ЛИМИТЫ")"

echo
echo "Первые 20 файлов для включения:"
head -20 "$TEMP/include.txt" 2>/dev/null || echo "Нет файлов"

if [[ "$DRY_RUN" == false ]]; then
    if [[ $file_count -eq 0 ]]; then
        echo "❌ Нет файлов для включения!"
        exit 1
    fi
    
    echo
    read -p "Создать чистую ветку $TARGET_BRANCH? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Создаю orphan ветку..."
        git checkout --orphan "$TARGET_BRANCH" 2>/dev/null || git checkout "$TARGET_BRANCH"
        git rm -rf . 2>/dev/null || true
        
        copied_count=0
        while IFS= read -r rel_path; do
            src="$SOURCE/$rel_path"
            dst="./$rel_path"
            
            if [[ -f "$src" ]]; then
                mkdir -p "$(dirname "$dst")"
                cp "$src" "$dst"
                ((copied_count++))
            fi
        done < "$TEMP/include.txt"
        
        # Добавляем конфиги
        cp .gitignore . 2>/dev/null || true
        cp .gitattributes . 2>/dev/null || true
        cp .editorconfig . 2>/dev/null || true
        cp .env.example . 2>/dev/null || true
        
        echo "✅ Скопировано файлов: $copied_count"
        echo "✅ Готово! Следующие шаги:"
        echo "   git add ."
        echo "   git commit -m 'Clean release: core code and migrations only'"
        echo "   git push origin $TARGET_BRANCH"
    fi
fi

rm -rf "$TEMP"
