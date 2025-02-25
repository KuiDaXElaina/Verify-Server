#!/bin/bash

# 設置顏色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 檢查是否以root權限運行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}請使用root權限運行此腳本${NC}"
  exit 1
fi

echo -e "${GREEN}開始安裝Minecraft插件授權伺服器...${NC}"

# 更新系統
echo -e "${GREEN}更新系統中...${NC}"
apt update && apt upgrade -y

# 安裝Node.js和npm
echo -e "${GREEN}安裝Node.js和npm...${NC}"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
  apt install -y nodejs
fi

if ! command -v npm &> /dev/null; then
  apt install -y npm
fi

# 安裝Nginx
echo -e "${GREEN}安裝Nginx網頁伺服器...${NC}"
apt install -y nginx

# 啟用Nginx並設置為開機自啟
systemctl enable nginx
systemctl start nginx

# 安裝PM2用於進程管理
echo -e "${GREEN}安裝PM2進程管理器...${NC}"
npm install -g pm2

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
    "body-parser": "^1.19.0"
  }
}
EOF

# 創建授權服務器
echo -e "${GREEN}創建授權服務器代碼...${NC}"
cat > license-server.js << 'EOF'
const express = require('express');
const bodyParser = require('body-parser');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3000;

// 中間件
app.use(bodyParser.json());
app.use(express.static(__dirname));

// 讀取許可證數據庫 (簡單的JSON文件)
let licensesDB = {};
try {
    const dbPath = path.join(__dirname, 'licenses.json');
    if (fs.existsSync(dbPath)) {
        licensesDB = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
    } else {
        // 初始化空數據庫並保存
        fs.writeFileSync(dbPath, JSON.stringify(licensesDB, null, 2));
    }
} catch (error) {
    console.error('讀取許可證數據庫時出錯:', error);
}

// 保存許可證數據庫
function saveLicensesDB() {
    try {
        fs.writeFileSync(
            path.join(__dirname, 'licenses.json'),
            JSON.stringify(licensesDB, null, 2)
        );
    } catch (error) {
        console.error('保存許可證數據庫時出錯:', error);
    }
}

// 生成新的許可證金鑰
function generateLicenseKey() {
    return crypto.randomBytes(16).toString('hex');
}

// 驗證許可證的API端點
app.post('/api/validate', (req, res) => {
    const { license_key, server_ip, server_port, server_name, plugin_version } = req.body;

    // 記錄請求
    console.log(`收到來自 ${server_ip}:${server_port} (${server_name}) 的驗證請求，插件版本: ${plugin_version}`);

    // 檢查許可證是否存在
    if (!licensesDB[license_key]) {
        console.log(`許可證金鑰 ${license_key} 不存在`);
        return res.status(404).json({
            status: 'error',
            message: 'Invalid license key'
        });
    }

    const license = licensesDB[license_key];

    // 檢查許可證是否過期
    if (license.expiry && new Date(license.expiry) < new Date()) {
        console.log(`許可證金鑰 ${license_key} 已過期`);
        return res.status(403).json({
            status: 'error',
            message: 'License expired'
        });
    }

    // 檢查伺服器IP是否在允許列表中（如果有設定）
    if (license.allowed_ips && license.allowed_ips.length > 0 && !license.allowed_ips.includes(server_ip)) {
        console.log(`伺服器IP ${server_ip} 不在許可證的允許IP列表中`);
        return res.status(403).json({
            status: 'error',
            message: 'Server IP not authorized'
        });
    }

    // 更新許可證使用記錄
    if (!license.usage_history) {
        license.usage_history = [];
    }
    
    license.usage_history.push({
        timestamp: new Date().toISOString(),
        server_ip,
        server_port,
        server_name,
        plugin_version
    });
    
    // 限制歷史記錄大小
    if (license.usage_history.length > 100) {
        license.usage_history = license.usage_history.slice(-100);
    }
    
    // 更新最後使用時間
    license.last_used = new Date().toISOString();
    
    // 保存更新
    saveLicensesDB();
    
    console.log(`許可證 ${license_key} 驗證成功`);
    
    // 返回成功
    return res.json({
        status: 'success',
        message: 'License verified successfully',
        license_type: license.type,
        customer: license.customer_name
    });
});

// 管理API：創建新許可證
app.post('/api/admin/licenses', (req, res) => {
    const { admin_key, customer_name, expiry, allowed_ips, type } = req.body;
    
    // 檢查管理員密鑰 (在實際生產環境中應使用更強的認證方式)
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    if (admin_key !== ADMIN_KEY) {
        return res.status(401).json({
            status: 'error',
            message: 'Unauthorized'
        });
    }
    
    // 生成新的許可證
    const licenseKey = generateLicenseKey();
    
    // 存儲許可證信息
    licensesDB[licenseKey] = {
        created_at: new Date().toISOString(),
        customer_name: customer_name || 'Unknown',
        expiry: expiry || null,
        allowed_ips: allowed_ips || [],
        type: type || 'standard',
        active: true,
        usage_history: []
    };
    
    // 保存更新
    saveLicensesDB();
    
    // 返回新許可證信息
    return res.status(201).json({
        status: 'success',
        license_key: licenseKey,
        license: licensesDB[licenseKey]
    });
});

// 管理API：獲取所有許可證
app.get('/api/admin/licenses', (req, res) => {
    const { admin_key } = req.query;
    
    // 檢查管理員密鑰
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    if (admin_key !== ADMIN_KEY) {
        return res.status(401).json({
            status: 'error',
            message: 'Unauthorized'
        });
    }
    
    return res.json({
        status: 'success',
        licenses: licensesDB
    });
});

// 管理API：更新許可證
app.put('/api/admin/licenses/:key', (req, res) => {
    const { admin_key, active, expiry, allowed_ips, customer_name, type } = req.body;
    const licenseKey = req.params.key;
    
    // 檢查管理員密鑰
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    if (admin_key !== ADMIN_KEY) {
        return res.status(401).json({
            status: 'error',
            message: 'Unauthorized'
        });
    }
    
    // 檢查許可證是否存在
    if (!licensesDB[licenseKey]) {
        return res.status(404).json({
            status: 'error',
            message: 'License not found'
        });
    }
    
    // 更新許可證
    if (active !== undefined) licensesDB[licenseKey].active = active;
    if (expiry !== undefined) licensesDB[licenseKey].expiry = expiry;
    if (allowed_ips !== undefined) licensesDB[licenseKey].allowed_ips = allowed_ips;
    if (customer_name !== undefined) licensesDB[licenseKey].customer_name = customer_name;
    if (type !== undefined) licensesDB[licenseKey].type = type;
    
    // 保存更新
    saveLicensesDB();
    
    return res.json({
        status: 'success',
        license: licensesDB[licenseKey]
    });
});

// 啟動伺服器
app.listen(PORT, () => {
    console.log(`許可證驗證伺服器在埠口 ${PORT} 上運行中`);
});
EOF

# 創建管理介面
echo -e "${GREEN}創建管理介面...${NC}"
cat > admin.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Minecraft插件授權管理系統</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            background-color: #f4f4f4;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1, h2 {
            color: #333;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        table, th, td {
            border: 1px solid #ddd;
        }
        th, td {
            padding: 12px;
            text-align: left;
        }
        th {
            background-color: #f2f2f2;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .form-group {
            margin-bottom: 15px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
        }
        input, select {
            width: 100%;
            padding: 8px;
            border: 1px solid #ddd;
            border-radius: 4px;
        }
        button {
            background-color: #4CAF50;
            color: white;
            padding: 10px 15px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
        }
        button:hover {
            background-color: #45a049;
        }
        .license-details {
            background-color: #f9f9f9;
            padding: 15px;
            border-radius: 4px;
            margin-top: 10px;
            white-space: pre-wrap;
        }
        .error {
            color: red;
            background-color: #ffe6e6;
            padding: 10px;
            border-radius: 4px;
            margin: 10px 0;
        }
        .success {
            color: green;
            background-color: #e6ffe6;
            padding: 10px;
            border-radius: 4px;
            margin: 10px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Minecraft插件授權管理系統</h1>
        
        <div id="auth-section">
            <h2>管理員認證</h2>
            <div class="form-group">
                <label for="admin-key">管理員密鑰:</label>
                <input type="password" id="admin-key" placeholder="輸入管理員密鑰">
            </div>
            <button id="auth-button">認證</button>
            <div id="auth-message"></div>
        </div>
        
        <div id="main-content" style="display: none;">
            <h2>創建新授權</h2>
            <div class="form-group">
                <label for="customer-name">客戶名稱:</label>
                <input type="text" id="customer-name" placeholder="輸入客戶名稱">
            </div>
            <div class="form-group">
                <label for="license-type">授權類型:</label>
                <select id="license-type">
                    <option value="standard">標準版</option>
                    <option value="premium">高級版</option>
                    <option value="unlimited">無限版</option>
                </select>
            </div>
            <div class="form-group">
                <label for="expiry-date">到期日期:</label>
                <input type="date" id="expiry-date">
            </div>
            <div class="form-group">
                <label for="allowed-ips">允許的IP (用逗號分隔):</label>
                <input type="text" id="allowed-ips" placeholder="例如: 123.456.789.0,987.654.321.0">
            </div>
            <button id="create-license">創建授權</button>
            <div id="create-message"></div>
            <div id="license-result" class="license-details" style="display: none;"></div>
            
            <h2>現有授權</h2>
            <button id="refresh-licenses">刷新列表</button>
            <div id="licenses-table-container">
                <table id="licenses-table">
                    <thead>
                        <tr>
                            <th>授權金鑰</th>
                            <th>客戶名稱</th>
                            <th>類型</th>
                            <th>創建日期</th>
                            <th>到期日期</th>
                            <th>狀態</th>
                            <th>操作</th>
                        </tr>
                    </thead>
                    <tbody id="licenses-body">
                        <!-- 授權數據將在這裡動態生成 -->
                    </tbody>
                </table>
            </div>
            
            <h2>授權詳情</h2>
            <div id="license-details" class="license-details">
                選擇一個授權查看詳細資訊
            </div>
        </div>
    </div>

    <script>
        let adminKey = '';
        const baseUrl = window.location.origin; // 自動獲取當前域名
        
        // 認證功能
        document.getElementById('auth-button').addEventListener('click', authenticate);
        
        function authenticate() {
            adminKey = document.getElementById('admin-key').value.trim();
            if (!adminKey) {
                showMessage('auth-message', '請輸入管理員密鑰', 'error');
                return;
            }
            
            fetch(`${baseUrl}/api/admin/licenses?admin_key=${adminKey}`)
                .then(response => {
                    if (!response.ok) {
                        throw new Error('認證失敗');
                    }
                    return response.json();
                })
                .then(data => {
                    if (data.status === 'success') {
                        document.getElementById('auth-section').style.display = 'none';
                        document.getElementById('main-content').style.display = 'block';
                        loadLicenses();
                    } else {
                        showMessage('auth-message', '認證失敗: ' + data.message, 'error');
                    }
                })
                .catch(error => {
                    showMessage('auth-message', '認證失敗: ' + error.message, 'error');
                });
        }
        
        // 創建授權
        document.getElementById('create-license').addEventListener('click', createLicense);
        
        function createLicense() {
            const customerName = document.getElementById('customer-name').value.trim();
            const licenseType = document.getElementById('license-type').value;
            const expiryDate = document.getElementById('expiry-date').value;
            const allowedIPs = document.getElementById('allowed-ips').value.trim();
            
            if (!customerName) {
                showMessage('create-message', '請輸入客戶名稱', 'error');
                return;
            }
            
            const licenseData = {
                admin_key: adminKey,
                customer_name: customerName,
                type: licenseType,
                expiry: expiryDate || null,
                allowed_ips: allowedIPs ? allowedIPs.split(',').map(ip => ip.trim()) : []
            };
            
            fetch(`${baseUrl}/api/admin/licenses`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(licenseData)
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    showMessage('create-message', '授權創建成功', 'success');
                    document.getElementById('license-result').textContent = 
                        `授權金鑰: ${data.license_key}\n` +
                        `客戶: ${data.license.customer_name}\n` +
                        `類型: ${data.license.type}\n` +
                        `創建日期: ${new Date(data.license.created_at).toLocaleString()}\n` +
                        `到期日期: ${data.license.expiry ? new Date(data.license.expiry).toLocaleDateString() : '永不過期'}\n` +
                        `允許的IP: ${data.license.allowed_ips.join(', ') || '所有IP'}\n` +
                        `狀態: ${data.license.active ? '啟用' : '停用'}`;
                    document.getElementById('license-result').style.display = 'block';
                    
                    // 重新加載授權列表
                    loadLicenses();
                } else {
                    showMessage('create-message', '創建失敗: ' + data.message, 'error');
                }
            })
            .catch(error => {
                showMessage('create-message', '創建失敗: ' + error.message, 'error');
            });
        }
        
        // 載入授權列表
        document.getElementById('refresh-licenses').addEventListener('click', loadLicenses);
        
        function loadLicenses() {
            fetch(`${baseUrl}/api/admin/licenses?admin_key=${adminKey}`)
                .then(response => response.json())
                .then(data => {
                    if (data.status === 'success') {
                        const licenseBody = document.getElementById('licenses-body');
                        licenseBody.innerHTML = '';
                        
                        for (const [key, license] of Object.entries(data.licenses)) {
                            const row = document.createElement('tr');
                            
                            row.innerHTML = `
                                <td>${key}</td>
                                <td>${license.customer_name}</td>
                                <td>${license.type}</td>
                                <td>${new Date(license.created_at).toLocaleString()}</td>
                                <td>${license.expiry ? new Date(license.expiry).toLocaleString() : '永不過期'}</td>
                                <td>${license.active ? '啟用' : '停用'}</td>
                                <td>
                                    <button onclick="viewLicense('${key}')">查看</button>
                                    <button onclick="toggleLicense('${key}', ${!license.active})">${license.active ? '停用' : '啟用'}</button>
                                </td>`;
                            
                            licenseBody.appendChild(row);
                        }
                    } else {
                        showMessage('auth-message', '載入授權列表失敗: ' + data.message, 'error');
                    }
                })
                .catch(error => {
                    showMessage('auth-message', '載入授權列表失敗: ' + error.message, 'error');
                });
        }
        
        // 查看授權詳情
        function viewLicense(key) {
            fetch(`${baseUrl}/api/admin/licenses?admin_key=${adminKey}`)
                .then(response => response.json())
                .then(data => {
                    if (data.status === 'success' && data.licenses[key]) {
                        const license = data.licenses[key];
                        const licenseDetails = document.getElementById('license-details');
                        
                        let usageHistory = '';
                        if (license.usage_history && license.usage_history.length > 0) {
                            usageHistory = '使用記錄:\n';
                            license.usage_history.forEach(usage => {
                                usageHistory += `- ${new Date(usage.timestamp).toLocaleString()} | ${usage.server_name} (${usage.server_ip}:${usage.server_port}) | 版本: ${usage.plugin_version}\n`;
                            });
                        } else {
                            usageHistory = '尚無使用記錄';
                        }
                        
                        licenseDetails.textContent = 
                            `授權金鑰: ${key}\n` +
                            `客戶: ${license.customer_name}\n` +
                            `類型: ${license.type}\n` +
                            `創建日期: ${new Date(license.created_at).toLocaleString()}\n` +
                            `最後使用: ${license.last_used ? new Date(license.last_used).toLocaleString() : '從未使用'}\n` +
                            `到期日期: ${license.expiry ? new Date(license.expiry).toLocaleString() : '永不過期'}\n` +
                            `允許的IP: ${license.allowed_ips?.join(', ') || '所有IP'}\n` +
                            `狀態: ${license.active ? '啟用' : '停用'}\n\n` +
                            usageHistory;
                    } else {
                        showMessage('licenses-table-container', '獲取授權詳情失敗', 'error');
                    }
                })
                .catch(error => {
                    showMessage('licenses-table-container', '獲取授權詳情失敗: ' + error.message, 'error');
                });
        }
        
        // 啟用/停用授權
        function toggleLicense(key, active) {
            fetch(`${baseUrl}/api/admin/licenses/${key}`, {
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    admin_key: adminKey,
                    active: active
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    showMessage('licenses-table-container', `授權狀態已${active ? '啟用' : '停用'}`, 'success');
                    loadLicenses();
                } else {
                    showMessage('licenses-table-container', '更新授權狀態失敗: ' + data.message, 'error');
                }
            })
            .catch(error => {
                showMessage('licenses-table-container', '更新授權狀態失敗: ' + error.message, 'error');
            });
        }
        
        // 顯示訊息
        function showMessage(elementId, message, type) {
            const element = document.getElementById(elementId);
            const messageDiv = document.createElement('div');
            messageDiv.classList.add(type);
            messageDiv.textContent = message;
            
            // 清除先前的訊息
            const existingMessages = element.querySelectorAll('.error, .success');
            existingMessages.forEach(msg => msg.remove());
            
            element.appendChild(messageDiv);
            
            // 5秒後自動清除
            setTimeout(() => {
                if (messageDiv.parentNode === element) {
                    element.removeChild(messageDiv);
                }
            }, 5000);
        }
    </script>
</body>
</html>
EOF

# 創建空的licenses.json文件
echo -e "${GREEN}創建licenses.json數據庫文件...${NC}"
echo "{}" > licenses.json

# 生成隨機的管理員密鑰
ADMIN_KEY=$(openssl rand -hex 16)
echo -e "${GREEN}生成的管理員密鑰: ${ADMIN_KEY}${NC}"
echo "請保存此密鑰，用於管理許可證"

# 創建環境變量文件
echo -e "${GREEN}創建環境變量文件...${NC}"
cat > .env << EOF
PORT=3000
ADMIN_KEY=${ADMIN_KEY}
EOF

# 安裝依賴項
echo -e "${GREEN}安裝Node.js依賴項...${NC}"
npm install

# 創建Nginx配置文件
echo -e "${GREEN}配置Nginx...${NC}"
cat > /etc/nginx/sites-available/license-server << EOF
server {
    listen 80;
    server_name \$HOSTNAME; # 使用主機名，你可以之後修改為你的域名

    # 日誌配置
    access_log /var/log/nginx/license_access.log;
    error_log /var/log/nginx/license_error.log;

    # 靜態文件
    location / {
        root /opt/license-server;
        index admin.html;
    }

    # API代理
    location /api/ {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# 啟用Nginx配置
ln -sf /etc/nginx/sites-available/license-server /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default # 移除默認配置
nginx -t # 測試配置
systemctl reload nginx # 重新加載Nginx

# 設置PM2啟動腳本
echo -e "${GREEN}設置PM2啟動腳本...${NC}"
pm2 start license-server.js --name license-server
pm2 save
pm2 startup

# 顯示完成訊息
echo -e "${GREEN}授權伺服器安裝完成！${NC}"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "伺服器運行在: http://${SERVER_IP}"
echo "管理界面: http://${SERVER_IP}/admin.html"
echo "管理API: http://${SERVER_IP}/api/admin/licenses"
echo "驗證API: http://${SERVER_IP}/api/validate"
echo -e "${GREEN}請記住您的管理員密鑰: ${ADMIN_KEY}${NC}"
echo "您可以使用此指令查看日誌: pm2 logs license-server"
