#!/bin/bash
# Вызвываем chmod +x 00-index.sh; из командной строки чтоб сделать файл исполняемым

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Список скриптов в правильном порядке
SCRIPTS=(
  "0-PreSetup.sh"
  "1-RKE2-Server.sh"
  "2-RKE2-Agent.sh"
  "3-Rancher.sh"
  "4-Longhorn.sh"
  "5-ArgoCD.sh"
  "6-Grafana.sh"
  "7-PostgreSQL.sh"
)

echo -e "${GREEN}Устанаваем права на выполнение скриптов...${NC}"
for script in "${SCRIPTS[@]}"; do
  if [ -f "$script" ]; then
    chmod +x "$script"
    echo -e "${GREEN}  ✓ Права установлены для: $script${NC}"
  else
    echo -e "${YELLOW}  Файл $script не найден, пропускаем${NC}"
  fi
done
echo -e "${GREEN}Все файлы скриптов подготовлены!${NC}"
