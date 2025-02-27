#!/bin/bash
# 遇到錯誤就停止執行
set -e

# 添加錯誤處理函數
handle_error() {
    echo -e "${RED}安裝過程中發生錯誤！${NC}"
    echo "錯誤發生在第 $1 行"
    exit 1
}

trap 'handle_error $LINENO' ERR

# 設置顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 檢查是否以root權限運行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}請使用root權限運行此腳本${NC}"
  exit 1
fi

echo -e "${GREEN}開始安裝Minecraft插件授權伺服器...${NC}"

# ===== 第一階段：安裝基本套件 =====
# 獲取腳本所在目錄
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo -e "${GREEN}腳本運行目錄: ${SCRIPT_DIR}${NC}"

echo -e "${GREEN}第一階段：安裝基本套件${NC}"

# 更新系統
echo -e "${GREEN}更新系統中...${NC}"
apt update && apt upgrade -y

# 安裝Node.js
echo -e "${GREEN}安裝Node.js...${NC}"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
  apt install -y nodejs
fi

# 確保npm已安裝
echo -e "${GREEN}確保npm已安裝...${NC}"
apt install -y npm

# 安裝Nginx
echo -e "${GREEN}安裝Nginx網頁伺服器...${NC}"
apt install -y nginx

# 啟用Nginx並設置為開機自啟
systemctl enable nginx
systemctl start nginx

# 安裝PM2用於進程管理
echo -e "${GREEN}安裝PM2進程管理器...${NC}"
npm install -g pm2

# 安裝jq工具，用於處理JSON
echo -e "${GREEN}安裝jq工具...${NC}"
apt install -y jq

# ===== 第二階段：建立應用目錄 =====
echo -e "${GREEN}第二階段：建立應用目錄${NC}"

# 創建應用目錄
echo -e "${GREEN}創建應用目錄...${NC}"
mkdir -p /opt/license-server
cd /opt/license-server

# 創建package.json
echo -e "${GREEN}創建package.json...${NC}"
cat > package.json << 'EOF'
{
  "name": "minecraft-license-server",
  "version": "1.0.0",
  "description": "License server for Minecraft plugins",
  "main": "license-server.js",
  "scripts": {
    "start": "node license-server.js"
  },
  "dependencies": {
    "express": "^4.17.1",
    "body-parser": "^1.19.0",
    "dotenv": "^10.0.0",
    "geoip-lite": "^1.4.7",
    "jsonwebtoken": "^9.0.0",
    "sqlite3": "^5.1.6",
    "mysql2": "^3.6.0",
    "sequelize": "^6.32.1"
  }
}
EOF

# ===== 第三階段：創建授權服務器代碼 =====
echo -e "${GREEN}第三階段：複製授權服務器代碼...${NC}"

# 檢查 license-server.js 是否存在於腳本目錄中
if [ -f "$SCRIPT_DIR/license-server.js" ]; then
    # 複製 license-server.js 到應用目錄
    cp "$SCRIPT_DIR/license-server.js" /opt/license-server/
    echo -e "${GREEN}授權服務器代碼複製成功${NC}"
else
    echo -e "${RED}錯誤：找不到 license-server.js 文件！${NC}"
    echo -e "${YELLOW}請確保 license-server.js 與 setup.sh 在同一目錄下${NC}"
    exit 1
fi

# ===== 第四階段：複製網頁文件 =====
echo -e "${GREEN}第四階段：複製網頁文件...${NC}"

# 檢查www目錄是否存在
mkdir -p /opt/license-server/www
if [ -d "$SCRIPT_DIR/www" ]; then
    # 複製www目錄內容
    cp -r "$SCRIPT_DIR/www/"* /opt/license-server/www/
    # 設置正確的權限
    chown -R www-data:www-data /opt/license-server/www
    chmod -R 755 /opt/license-server/www
    echo -e "${GREEN}網頁文件複製成功${NC}"
else
    echo -e "${RED}錯誤：找不到 www 目錄！${NC}"
    echo -e "${YELLOW}請確保 www 目錄與 setup.sh 在同一目錄下${NC}"
    exit 1
fi

# ===== 第五階段：設置數據庫 =====
echo -e "${GREEN}第五階段：設置數據庫${NC}"

# 生成隨機的JWT密鑰
JWT_SECRET=$(openssl rand -hex 32)

# 詢問用戶選擇存儲方式
echo -e "${GREEN}選擇數據存儲方式...${NC}"
echo "1) SQLite (本地文件數據庫)"
echo "2) 傳統SQL (MySQL/MariaDB)"
read -p "請選擇數據存儲方式 [1/2]: " DB_CHOICE

# 設置數據庫配置
if [[ "$DB_CHOICE" == "2" ]]; then
    DB_TYPE="mysql"
    read -p "請輸入SQL伺服器IP: " DB_HOST
    read -p "請輸入SQL伺服器埠口 [3306]: " DB_PORT
    DB_PORT=${DB_PORT:-3306}
    read -p "請輸入SQL數據庫名稱: " DB_NAME
    read -p "請輸入SQL用戶名: " DB_USER
    read -s -p "請輸入SQL密碼: " DB_PASSWORD
    echo ""
    
    # 安裝MySQL客戶端
    echo -e "${GREEN}安裝MySQL客戶端...${NC}"
    apt install -y mysql-client
    
    # 測試數據庫連接
    echo -e "${GREEN}測試數據庫連接...${NC}"
    if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" 2>/dev/null; then
        echo -e "${RED}無法連接到MySQL數據庫，請檢查您的配置${NC}"
        exit 1
    fi
else
    DB_TYPE="sqlite"
    DB_PATH="/opt/license-server/database.sqlite"
    # 安裝SQLite
    echo -e "${GREEN}安裝SQLite...${NC}"
    apt install -y sqlite3
fi

# 創建環境變量文件
echo -e "${GREEN}創建環境變量文件...${NC}"
cat > .env << EOF
PORT=3000
JWT_SECRET=${JWT_SECRET}
DB_TYPE=${DB_TYPE}
EOF

# 如果是MySQL，添加MySQL配置
if [[ "$DB_CHOICE" == "2" ]]; then
    cat >> .env << EOF
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF
else
    cat >> .env << EOF
DB_PATH=${DB_PATH}
EOF
fi

# ===== 第六階段：創建管理員帳號 =====
echo -e "${GREEN}第六階段：創建管理員帳號${NC}"

# 提示創建管理員帳號
echo -e "${GREEN}設置管理員帳號...${NC}"
read -p "請輸入管理員用戶名 (至少5個字符): " ADMIN_USERNAME
while [[ ${#ADMIN_USERNAME} -lt 5 ]]; do
  echo -e "${RED}用戶名至少需要5個字符${NC}"
  read -p "請輸入管理員用戶名 (至少5個字符): " ADMIN_USERNAME
done

read -s -p "請輸入管理員密碼 (至少8個字符): " ADMIN_PASSWORD
echo ""
while [[ ${#ADMIN_PASSWORD} -lt 8 ]]; do
  echo -e "${RED}密碼至少需要8個字符${NC}"
  read -s -p "請輸入管理員密碼 (至少8個字符): " ADMIN_PASSWORD
  echo ""
done

read -s -p "請再次輸入密碼確認: " ADMIN_PASSWORD_CONFIRM
echo ""
while [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; do
  echo -e "${RED}兩次輸入的密碼不一致${NC}"
  read -s -p "請再次輸入密碼確認: " ADMIN_PASSWORD_CONFIRM
  echo ""
done

# 創建管理員數據庫文件
echo -e "${GREEN}創建初始用戶數據...${NC}"
ADMIN_PASSWORD_HASH=$(echo -n "$ADMIN_PASSWORD" | sha256sum | awk '{print $1}')

# ===== 第七階段：配置 Nginx =====
echo -e "${GREEN}第七階段：配置 Nginx${NC}"

# Nginx 配置文件
cat > /etc/nginx/sites-available/license-server << EOF
server {
    listen 80;
    server_name $(hostname);

    root /opt/license-server/www;
    index index.html;

    # 添加安全headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.html;
        expires 1h;
        add_header Cache-Control "public, no-transform";
    }

    location /api/ {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
        
        # 添加 CORS 支持
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
    }

    # 禁止訪問 . 開頭的隱藏文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

# 啟用Nginx配置
ln -sf /etc/nginx/sites-available/license-server /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default # 移除默認配置
nginx -t # 測試配置
systemctl reload nginx # 重新加載Nginx

# ===== 第八階段：安裝依賴和管理工具 =====
echo -e "${GREEN}第八階段：安裝依賴和管理工具${NC}"

# 安裝依賴項
echo -e "${GREEN}安裝Node.js依賴項...${NC}"
cd /opt/license-server
npm install

# 創建重設管理員密碼腳本
echo -e "${GREEN}創建重設管理員密碼腳本...${NC}"
cat > /opt/license-server/reset_admin_password.sh << 'EOF'
#!/bin/bash

# 設置顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 檢查是否以root權限運行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}請使用root權限運行此腳本${NC}"
  exit 1
fi

# 獲取管理員用戶名
read -p "請輸入要重設密碼的管理員用戶名: " ADMIN_USERNAME

# 獲取資料庫類型
cd /opt/license-server
source .env

if [ "$DB_TYPE" == "mysql" ]; then
    # 使用MySQL
    echo -e "${YELLOW}使用MySQL數據庫${NC}"
    
    # 檢查管理員是否存在
    ADMIN_EXISTS=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT COUNT(*) FROM Users WHERE username='$ADMIN_USERNAME' AND is_admin=1;" 2>/dev/null | tail -n 1)
    
    if [ "$ADMIN_EXISTS" == "0" ] || [ -z "$ADMIN_EXISTS" ]; then
        echo -e "${RED}管理員 $ADMIN_USERNAME 不存在或不是管理員!${NC}"
        exit 1
    fi
else
    # 使用SQLite
    echo -e "${YELLOW}使用SQLite數據庫${NC}"
    
    # 檢查管理員是否存在
    if ! command -v sqlite3 &> /dev/null; then
        apt install -y sqlite3
    fi
    
    ADMIN_EXISTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM Users WHERE username='$ADMIN_USERNAME' AND is_admin=1;")
    
    if [ "$ADMIN_EXISTS" == "0" ]; then
        echo -e "${RED}管理員 $ADMIN_USERNAME 不存在或不是管理員!${NC}"
        exit 1
    fi
fi

# 設置新密碼
read -s -p "請輸入新密碼 (至少8個字符): " NEW_PASSWORD
echo ""
while [[ ${#NEW_PASSWORD} -lt 8 ]]; do
  echo -e "${RED}密碼至少需要8個字符${NC}"
  read -s -p "請輸入新密碼 (至少8個字符): " NEW_PASSWORD
  echo ""
done

read -s -p "請再次輸入密碼確認: " PASSWORD_CONFIRM
echo ""
while [[ "$NEW_PASSWORD" != "$PASSWORD_CONFIRM" ]]; do
  echo -e "${RED}兩次輸入的密碼不一致${NC}"
  read -s -p "請再次輸入密碼確認: " PASSWORD_CONFIRM
  echo ""
done

# 生成密碼哈希
PASSWORD_HASH=$(echo -n "$NEW_PASSWORD" | sha256sum | awk '{print $1}')

# 更新密碼
if [ "$DB_TYPE" == "mysql" ]; then
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "UPDATE Users SET password_hash='$PASSWORD_HASH' WHERE username='$ADMIN_USERNAME';"
else
    sqlite3 "$DB_PATH" "UPDATE Users SET password_hash='$PASSWORD_HASH' WHERE username='$ADMIN_USERNAME';"
fi

# 重啟服務
pm2 restart license-server

echo -e "${GREEN}管理員 $ADMIN_USERNAME 的密碼已成功重設!${NC}"
EOF

# 給腳本添加執行權限
chmod +x /opt/license-server/reset_admin_password.sh

# 複製重設密碼腳本到/usr/local/bin/
cp /opt/license-server/reset_admin_password.sh /usr/local/bin/
chmod +x /usr/local/bin/reset_admin_password.sh

# 創建測試腳本
echo -e "${GREEN}創建測試腳本...${NC}"
cat > /opt/license-server/test_license.sh << 'EOF'
#!/bin/bash

# 設置顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [ "$#" -ne 1 ]; then
    echo -e "${RED}使用方法: $0 <許可證金鑰>${NC}"
    exit 1
fi

LICENSE_KEY=$1
SERVER_IP=$(hostname -I | awk '{print $1}')
SERVER_PORT=25565
SERVER_NAME=$(hostname)
PLUGIN_VERSION="1.0.0"

echo -e "${YELLOW}測試許可證: ${LICENSE_KEY}${NC}"
echo "伺服器IP: ${SERVER_IP}"
echo "伺服器名稱: ${SERVER_NAME}"
echo "插件版本: ${PLUGIN_VERSION}"
echo

# 構建JSON請求
JSON_DATA="{\"license_key\":\"${LICENSE_KEY}\",\"server_ip\":\"${SERVER_IP}\",\"server_port\":\"${SERVER_PORT}\",\"server_name\":\"${SERVER_NAME}\",\"plugin_version\":\"${PLUGIN_VERSION}\"}"

# 發送請求到驗證API
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "${JSON_DATA}" "http://localhost:3000/api/validate")

# 檢查是否成功
if echo "${RESPONSE}" | grep -q "success"; then
    echo -e "${GREEN}許可證驗證成功!${NC}"
    echo "${RESPONSE}" | jq .
else
    echo -e "${RED}許可證驗證失敗!${NC}"
    echo "${RESPONSE}" | jq .
fi
EOF

# 給測試腳本添加執行權限
chmod +x /opt/license-server/test_license.sh
ln -sf /opt/license-server/test_license.sh /usr/local/bin/test_license

# 設置適當的檔案權限
echo -e "${GREEN}設置檔案權限...${NC}"
chmod 644 /opt/license-server/.env
chown -R www-data:www-data /opt/license-server
chmod -R 755 /opt/license-server

# ===== 第九階段：啟動服務 =====
echo -e "${GREEN}第九階段：啟動服務${NC}"

# 設置PM2啟動腳本
echo -e "${GREEN}設置PM2啟動腳本...${NC}"
cd /opt/license-server
pm2 start license-server.js --name license-server
pm2 save
pm2 startup

# ===== 第十階段：完成安裝 =====
# 顯示完成訊息
echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}             授權伺服器安裝完成！                            ${NC}"
echo -e "${GREEN}=================================================================${NC}"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}伺服器網址：${NC} http://${SERVER_IP}"
echo -e "${YELLOW}管理員用戶名：${NC} ${ADMIN_USERNAME}"
echo -e "${YELLOW}API端點：${NC} http://${SERVER_IP}/api/validate"
echo -e "${YELLOW}查看日誌：${NC} pm2 logs license-server"
echo -e "${YELLOW}重設密碼：${NC} sudo reset_admin_password.sh"
echo -e "${YELLOW}測試許可證：${NC} test_license <許可證金鑰>"
echo -e "${GREEN}=================================================================${NC}"