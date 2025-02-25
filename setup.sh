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

echo -e "${GREEN}開始安裝Minecraft插件授權伺服器...${NC}"

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
    "dotenv": "^10.0.0"
  }
}
EOF

# 創建授權服務器
echo -e "${GREEN}創建授權服務器代碼...${NC}"
cat > license-server.js << 'EOF'
// 加載環境變量
require('dotenv').config();

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

// 插件功能定義 - 不同授權類型的功能差異
const licenseBenefits = {
    standard: {
        description: "標準版授權 - 基礎功能",
        features: ["基本功能", "優先支援", "單一服務器"]
    },
    premium: {
        description: "高級版授權 - 進階功能",
        features: ["標準版全部功能", "進階功能", "優先Bug修復", "最多3個服務器"]
    },
    unlimited: {
        description: "無限版授權 - 完整功能",
        features: ["高級版全部功能", "全部功能", "無限服務器數量", "自訂功能開發優先權"]
    }
};

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

    // 檢查許可證是否啟用
    if (!license.active) {
        console.log(`許可證金鑰 ${license_key} 未啟用`);
        return res.status(403).json({
            status: 'error',
            message: 'License not active'
        });
    }

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
        customer: license.customer_name,
        features: licenseBenefits[license.type]?.features || []
    });
});

// 管理API：創建新許可證
app.post('/api/admin/licenses', (req, res) => {
    const { admin_key, customer_name, expiry, allowed_ips, type } = req.body;
    
    // 檢查管理員密鑰
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    console.log('收到的管理員密鑰:', admin_key);
    console.log('系統配置的管理員密鑰:', ADMIN_KEY);
    
    if (admin_key !== ADMIN_KEY) {
        console.log('管理員密鑰驗證失敗');
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
        license: licensesDB[licenseKey],
        benefits: licenseBenefits[type || 'standard']
    });
});

// 管理API：獲取所有許可證
app.get('/api/admin/licenses', (req, res) => {
    const { admin_key } = req.query;
    
    // 檢查管理員密鑰
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    console.log('收到的管理員密鑰:', admin_key);
    console.log('系統配置的管理員密鑰:', ADMIN_KEY);
    
    if (admin_key !== ADMIN_KEY) {
        console.log('管理員密鑰驗證失敗');
        return res.status(401).json({
            status: 'error',
            message: 'Unauthorized'
        });
    }
    
    // 添加授權類型的權益信息
    const licensesWithBenefits = {};
    
    for (const [key, license] of Object.entries(licensesDB)) {
        licensesWithBenefits[key] = {
            ...license,
            benefits: licenseBenefits[license.type] || { features: [] }
        };
    }
    
    return res.json({
        status: 'success',
        licenses: licensesWithBenefits,
        license_types: licenseBenefits
    });
});

// 管理API：更新許可證
app.put('/api/admin/licenses/:key', (req, res) => {
    const { admin_key, active, expiry, allowed_ips, customer_name, type } = req.body;
    const licenseKey = req.params.key;
    
    // 檢查管理員密鑰
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    if (admin_key !== ADMIN_KEY) {
        console.log('管理員密鑰驗證失敗');
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
        license: licensesDB[licenseKey],
        benefits: licenseBenefits[licensesDB[licenseKey].type]
    });
});

// 管理API：修改管理員密鑰
app.post('/api/admin/change-key', (req, res) => {
    const { current_admin_key, new_admin_key } = req.body;
    
    // 檢查當前密鑰是否正確
    const ADMIN_KEY = process.env.ADMIN_KEY || 'your-secure-admin-key';
    
    if (current_admin_key !== ADMIN_KEY) {
        return res.status(401).json({
            status: 'error',
            message: '當前密鑰驗證失敗'
        });
    }
    
    // 更新環境變量文件
    try {
        const envPath = path.join(__dirname, '.env');
        let envContent = '';
        
        if (fs.existsSync(envPath)) {
            envContent = fs.readFileSync(envPath, 'utf8');
            if (envContent.includes('ADMIN_KEY=')) {
                envContent = envContent.replace(/ADMIN_KEY=.*(\r?\n|$)/, `ADMIN_KEY=${new_admin_key}$1`);
            } else {
                envContent += `\nADMIN_KEY=${new_admin_key}\n`;
            }
        } else {
            envContent = `PORT=3000\nADMIN_KEY=${new_admin_key}\n`;
        }
        
        fs.writeFileSync(envPath, envContent);
        
        // 更新當前進程中的環境變量
        process.env.ADMIN_KEY = new_admin_key;
        
        console.log('管理員密鑰已更新');
        
        return res.json({
            status: 'success',
            message: '管理員密鑰已成功更新'
        });
    } catch (error) {
        console.error('更新管理員密鑰時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '更新管理員密鑰時出錯: ' + error.message
        });
    }
});

// 獲取授權類型信息
app.get('/api/license-types', (req, res) => {
    return res.json({
        status: 'success',
        license_types: licenseBenefits
    });
});

// 測試API：檢查服務器是否在運行
app.get('/api/status', (req, res) => {
    return res.json({
        status: 'success',
        message: '授權服務器正常運行中',
        timestamp: new Date().toISOString()
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
        .modal {
            display: none;
            position: fixed;
            z-index: 1000;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0,0,0,0.5);
        }
        .modal-content {
            background-color: #fefefe;
            margin: 10% auto;
            padding: 20px;
            border-radius: 5px;
            width: 70%;
            max-width: 700px;
            max-height: 80vh;
            overflow-y: auto;
        }
        .close {
            color: #aaa;
            float: right;
            font-size: 28px;
            font-weight: bold;
            cursor: pointer;
        }
        .close:hover {
            color: #000;
        }
        .feature-list {
            margin-top: 10px;
        }
        .feature-list li {
            margin-bottom: 5px;
        }
        .license-type-info {
            display: flex;
            justify-content: space-between;
            margin-bottom: 20px;
        }
        .license-type-card {
            flex: 1;
            background-color: #f9f9f9;
            margin: 0 10px;
            padding: 15px;
            border-radius: 5px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .license-type-card h3 {
            margin-top: 0;
            color: #4CAF50;
        }
        .change-key-section {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
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
            <p style="margin-top: 20px; font-size: 14px; color: #666;">
                如果您忘記密鑰，可以在伺服器上使用 <code>cat /opt/license-server/.env</code> 查看，或使用 <code>sudo reset_admin_key.sh</code> 重設密鑰。
            </p>
        </div>
        
        <div id="main-content" style="display: none;">
            <div class="license-type-info">
                <div class="license-type-card">
                    <h3>標準版</h3>
                    <p>基礎功能授權</p>
                    <ul class="feature-list" id="standard-features">
                        <li>基本功能</li>
                        <li>優先支援</li>
                        <li>單一服務器</li>
                    </ul>
                </div>
                <div class="license-type-card">
                    <h3>高級版</h3>
                    <p>進階功能授權</p>
                    <ul class="feature-list" id="premium-features">
                        <li>標準版全部功能</li>
                        <li>進階功能</li>
                        <li>優先Bug修復</li>
                        <li>最多3個服務器</li>
                    </ul>
                </div>
                <div class="license-type-card">
                    <h3>無限版</h3>
                    <p>完整功能授權</p>
                    <ul class="feature-list" id="unlimited-features">
                        <li>高級版全部功能</li>
                        <li>全部功能</li>
                        <li>無限服務器數量</li>
                        <li>自訂功能開發優先權</li>
                    </ul>
                </div>
            </div>
            
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
            
            <div class="change-key-section">
                <h2>修改管理員密鑰</h2>
                <div class="form-group">
                    <label for="new-admin-key">新管理員密鑰:</label>
                    <input type="password" id="new-admin-key" placeholder="輸入新的管理員密鑰">
                </div>
                <div class="form-group">
                    <label for="confirm-admin-key">確認新密鑰:</label>
                    <input type="password" id="confirm-admin-key" placeholder="再次輸入新的管理員密鑰">
                </div>
                <button id="change-key-button">更新密鑰</button>
                <div id="change-key-message"></div>
            </div>
        </div>
    </div>
    
    <!-- 授權詳情彈窗 -->
    <div id="license-modal" class="modal">
        <div class="modal-content">
            <span class="close">&times;</span>
            <h2>授權詳情</h2>
            <div id="modal-license-details"></div>
        </div>
    </div>

    <script>
        let adminKey = '';
        const baseUrl = window.location.origin; // 自動獲取當前域名
        const modal = document.getElementById('license-modal');
        const modalContent = document.getElementById('modal-license-details');
        const closeBtn = document.getElementsByClassName('close')[0];
        
        // 認證功能
        document.getElementById('auth-button').addEventListener('click', authenticate);
        
        // 關閉彈窗
        closeBtn.onclick = function() {
            modal.style.display = "none";
        }
        
        // 點擊彈窗外部關閉彈窗
        window.onclick = function(event) {
            if (event.target == modal) {
                modal.style.display = "none";
            }
        }
        
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
                        updateLicenseTypeInfo(data.license_types);
                    } else {
                        showMessage('auth-message', '認證失敗: ' + data.message, 'error');
                    }
                })
                .catch(error => {
                    showMessage('auth-message', '認證失敗: ' + error.message + '。<br>如果您忘記密鑰，可以在伺服器上使用 <code>cat /opt/license-server/.env</code> 查看密鑰，或使用 <code>sudo reset_admin_key.sh</code> 重設密鑰。', 'error');
                });
        }
        
        // 更新授權類型信息
        function updateLicenseTypeInfo(licenseTypes) {
            if (licenseTypes) {
                if (licenseTypes.standard && licenseTypes.standard.features) {
                    document.getElementById('standard-features').innerHTML = licenseTypes.standard.features.map(f => `<li>${f}</li>`).join('');
                }
                if (licenseTypes.premium && licenseTypes.premium.features) {
                    document.getElementById('premium-features').innerHTML = licenseTypes.premium.features.map(f => `<li>${f}</li>`).join('');
                }
                if (licenseTypes.unlimited && licenseTypes.unlimited.features) {
                    document.getElementById('unlimited-features').innerHTML = licenseTypes.unlimited.features.map(f => `<li>${f}</li>`).join('');
                }
            }
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
                    let featuresText = '';
                    if (data.benefits && data.benefits.features) {
                        featuresText = '\n\n功能列表:\n- ' + data.benefits.features.join('\n- ');
                    }
                    
                    document.getElementById('license-result').textContent = 
                        `授權金鑰: ${data.license_key}\n` +
                        `客戶: ${data.license.customer_name}\n` +
                        `類型: ${data.license.type}\n` +
                        `創建日期: ${new Date(data.license.created_at).toLocaleString()}\n` +
                        `到期日期: ${data.license.expiry ? new Date(data.license.expiry).toLocaleDateString() : '永不過期'}\n` +
                        `允許的IP: ${data.license.allowed_ips.join(', ') || '所有IP'}\n` +
                        `狀態: ${data.license.active ? '啟用' : '停用'}` + 
                        featuresText;
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
        
        // 查看授權詳情 - 使用彈窗
        function viewLicense(key) {
            fetch(`${baseUrl}/api/admin/licenses?admin_key=${adminKey}`)
                .then(response => response.json())
                .then(data => {
                    if (data.status === 'success' && data.licenses[key]) {
                        const license = data.licenses[key];
                        
                        let usageHistory = '';
                        if (license.usage_history && license.usage_history.length > 0) {
                            usageHistory = '<h3>使用記錄:</h3><ul>';
                            license.usage_history.forEach(usage => {
                                usageHistory += `<li>${new Date(usage.timestamp).toLocaleString()} | ${usage.server_name} (${usage.server_ip}:${usage.server_port}) | 版本: ${usage.plugin_version}</li>`;
                            });
                            usageHistory += '</ul>';
                        } else {
                            usageHistory = '<p>尚無使用記錄</p>';
                        }
                        
                        let features = '';
                        if (license.benefits && license.benefits.features) {
                            features = '<h3>功能列表:</h3><ul>';
                            license.benefits.features.forEach(feature => {
                                features += `<li>${feature}</li>`;
                            });
                            features += '</ul>';
                        }
                        
                        modalContent.innerHTML = `
                            <p><strong>授權金鑰:</strong> ${key}</p>
                            <p><strong>客戶:</strong> ${license.customer_name}</p>
                            <p><strong>類型:</strong> ${license.type}</p>
                            <p><strong>創建日期:</strong> ${new Date(license.created_at).toLocaleString()}</p>
                            <p><strong>最後使用:</strong> ${license.last_used ? new Date(license.last_used).toLocaleString() : '從未使用'}</p>
                            <p><strong>到期日期:</strong> ${license.expiry ? new Date(license.expiry).toLocaleString() : '永不過期'}</p>
                            <p><strong>允許的IP:</strong> ${license.allowed_ips?.join(', ') || '所有IP'}</p>
                            <p><strong>狀態:</strong> ${license.active ? '啟用' : '停用'}</p>
                            ${features}
                            ${usageHistory}
                        `;
                        
                        // 顯示彈窗
                        modal.style.display = "block";
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
        
        // 修改管理員密鑰
        document.getElementById('change-key-button').addEventListener('click', changeAdminKey);
        
        function changeAdminKey() {
            const newKey = document.getElementById('new-admin-key').value.trim();
            const confirmKey = document.getElementById('confirm-admin-key').value.trim();
            
            if (!newKey) {
                showMessage('change-key-message', '請輸入新密鑰', 'error');
                return;
            }
            
            if (newKey !== confirmKey) {
                showMessage('change-key-message', '兩次輸入的密鑰不一致', 'error');
                return;
            }
            
            fetch(`${baseUrl}/api/admin/change-key`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    current_admin_key: adminKey,
                    new_admin_key: newKey
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    showMessage('change-key-message', '管理員密鑰已成功更新', 'success');
                    adminKey = newKey;
                    document.getElementById('new-admin-key').value = '';
                    document.getElementById('confirm-admin-key').value = '';
                } else {
                    showMessage('change-key-message', '更新密鑰失敗: ' + data.message, 'error');
                }
            })
            .catch(error => {
                showMessage('change-key-message', '更新密鑰失敗: ' + error.message, 'error');
            });
        }
        
        // 顯示訊息
        function showMessage(elementId, message, type) {
            const element = document.getElementById(elementId);
            const messageDiv = document.createElement('div');
            messageDiv.classList.add(type);
            messageDiv.innerHTML = message;
            
            // 清除先前的訊息
            const existingMessages = element.querySelectorAll('.error, .success');
            existingMessages.forEach(msg => msg.remove());
            
            element.appendChild(messageDiv);
            
            // 5秒後自動清除 (錯誤訊息除外)
            if (type !== 'error') {
                setTimeout(() => {
                    if (messageDiv.parentNode === element) {
                        element.removeChild(messageDiv);
                    }
                }, 5000);
            }
        }
    </script>
</body>
</html>
EOF

# 創建重設密鑰腳本
echo -e "${GREEN}創建重設密鑰腳本...${NC}"
cat > reset_admin_key.sh << 'EOF'
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

if [ "$#" -eq 1 ]; then
    # 使用參數提供的密鑰
    NEW_KEY=$1
    echo -e "${YELLOW}使用指定的密鑰: ${NEW_KEY}${NC}"
else
    # 生成一個隨機密鑰
    NEW_KEY=$(openssl rand -hex 16)
    echo -e "${YELLOW}生成隨機密鑰: ${NEW_KEY}${NC}"
fi

# 更新 .env 文件
cd /opt/license-server
if [ -f .env ]; then
    # 檢查是否已有ADMIN_KEY
    if grep -q "ADMIN_KEY" .env; then
        # 更新現有的ADMIN_KEY
        sed -i "s/ADMIN_KEY=.*/ADMIN_KEY=${NEW_KEY}/" .env
    else
        # 添加ADMIN_KEY
        echo "ADMIN_KEY=${NEW_KEY}" >> .env
    fi
else
    # 創建新的.env文件
    echo "PORT=3000" > .env
    echo "ADMIN_KEY=${NEW_KEY}" >> .env
fi

# 重啟服務
pm2 restart license-server

echo -e "${GREEN}管理員密鑰已更新為: ${NEW_KEY}${NC}"
echo "請保存此密鑰用於登錄管理界面"
echo -e "${YELLOW}使用以下命令查看密鑰: cat /opt/license-server/.env${NC}"
EOF

# 給腳本添加執行權限
chmod +x reset_admin_key.sh

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

# 複製重設密鑰腳本到/usr/local/bin/
cp reset_admin_key.sh /usr/local/bin/
chmod +x /usr/local/bin/reset_admin_key.sh

# 創建測試腳本來驗證授權系統
echo -e "${GREEN}創建測試腳本...${NC}"
cat > test_license.sh << 'EOF'
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
chmod +x test_license.sh

# 檢查是否有jq工具 (用於格式化JSON輸出)
if ! command -v jq &> /dev/null; then
    apt install -y jq
fi

# 顯示完成訊息
echo -e "${GREEN}授權伺服器安裝完成！${NC}"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "伺服器運行在: http://${SERVER_IP}"
echo "管理界面: http://${SERVER_IP}/admin.html"
echo "管理API: http://${SERVER_IP}/api/validate"
echo -e "${GREEN}請記住您的管理員密鑰: ${ADMIN_KEY}${NC}"
echo "您可以使用以下指令重設管理員密鑰: sudo reset_admin_key.sh [新密鑰]"
echo "您可以使用以下指令查看日誌: pm2 logs license-server"
echo -e "${GREEN}您可以使用以下指令測試許可證: ./test_license.sh <許可證金鑰>${NC}"