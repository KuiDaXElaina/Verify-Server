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
    "dotenv": "^10.0.0",
    "geoip-lite": "^1.4.7",
    "jsonwebtoken": "^9.0.0",
    "sqlite3": "^5.1.6",
    "mysql2": "^3.6.0",
    "sequelize": "^6.32.1"
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
const geoip = require('geoip-lite'); // 用於獲取地理位置
const jwt = require('jsonwebtoken'); // 用於JWT認證
const { Sequelize, DataTypes, Op } = require('sequelize');

const app = express();
const PORT = process.env.PORT || 3000;

// 中間件
app.use(bodyParser.json());
app.use(express.static(__dirname));

// 數據庫設置
let sequelize;
if (process.env.DB_TYPE === 'mysql') {
    sequelize = new Sequelize(process.env.DB_NAME, process.env.DB_USER, process.env.DB_PASSWORD, {
        host: process.env.DB_HOST,
        port: process.env.DB_PORT,
        dialect: 'mysql',
        logging: false
    });
} else {
    sequelize = new Sequelize({
        dialect: 'sqlite',
        storage: process.env.DB_PATH || path.join(__dirname, 'database.sqlite'),
        logging: false
    });
}

// 定義模型
// 系統設置模型
const SystemSettings = sequelize.define('SystemSettings', {
    key: {
        type: DataTypes.STRING,
        primaryKey: true
    },
    value: DataTypes.TEXT
});

// 用戶模型
const User = sequelize.define('User', {
    username: {
        type: DataTypes.STRING,
        primaryKey: true
    },
    password_hash: DataTypes.STRING,
    is_admin: {
        type: DataTypes.BOOLEAN,
        defaultValue: false
    },
    created_at: {
        type: DataTypes.DATE,
        defaultValue: Sequelize.NOW
    }
});

// 許可證模型
const License = sequelize.define('License', {
    license_key: {
        type: DataTypes.STRING,
        primaryKey: true
    },
    customer_name: DataTypes.STRING,
    expiry: DataTypes.DATE,
    allowed_ips: {
        type: DataTypes.TEXT,
        get() {
            const value = this.getDataValue('allowed_ips');
            return value ? JSON.parse(value) : [];
        },
        set(value) {
            this.setDataValue('allowed_ips', JSON.stringify(value || []));
        }
    },
    type: {
        type: DataTypes.STRING,
        defaultValue: 'standard'
    },
    active: {
        type: DataTypes.BOOLEAN,
        defaultValue: true
    },
    last_used: DataTypes.DATE,
    usage_history: {
        type: DataTypes.TEXT,
        get() {
            const value = this.getDataValue('usage_history');
            return value ? JSON.parse(value) : [];
        },
        set(value) {
            this.setDataValue('usage_history', JSON.stringify(value || []));
        }
    }
});

// 裝置模型
const Device = sequelize.define('Device', {
    id: {
        type: DataTypes.INTEGER,
        primaryKey: true,
        autoIncrement: true
    },
    device_id: DataTypes.STRING,
    license_key: DataTypes.STRING,
    server_ip: DataTypes.STRING,
    server_port: DataTypes.STRING,
    server_name: DataTypes.STRING,
    plugin_version: DataTypes.STRING,
    location: DataTypes.STRING,
    operating_system: DataTypes.STRING,
    last_login: DataTypes.DATE,
    active: {
        type: DataTypes.BOOLEAN,
        defaultValue: true
    }
});

// 設置外鍵關係
License.hasMany(Device, { foreignKey: 'license_key' });
Device.belongsTo(License, { foreignKey: 'license_key' });

// 初始化數據庫
async function initializeDatabase() {
    try {
        // 同步模型到數據庫
        await sequelize.sync();
        
        // 檢查JWT_SECRET是否已經存在
        const jwtSecret = await SystemSettings.findOne({ where: { key: 'JWT_SECRET' } });
        if (!jwtSecret) {
            // 如果不存在，則創建
            await SystemSettings.create({
                key: 'JWT_SECRET',
                value: process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex')
            });
        }
        
        console.log('數據庫初始化成功');
    } catch (error) {
        console.error('數據庫初始化失敗:', error);
        process.exit(1);
    }
}

// 獲取JWT密鑰
async function getJwtSecret() {
    try {
        const setting = await SystemSettings.findOne({ where: { key: 'JWT_SECRET' } });
        return setting ? setting.value : null;
    } catch (error) {
        console.error('獲取JWT密鑰失敗:', error);
        return process.env.JWT_SECRET || 'your-jwt-secret-key';
    }
}

// 創建JWT token
async function generateToken(username) {
    const JWT_SECRET = await getJwtSecret();
    return jwt.sign({ username }, JWT_SECRET, { expiresIn: '30d' });
}

// 驗證密碼
function verifyPassword(password, hashedPassword) {
    const hash = crypto.createHash('sha256').update(password).digest('hex');
    return hash === hashedPassword;
}

// 哈希密碼
function hashPassword(password) {
    return crypto.createHash('sha256').update(password).digest('hex');
}

// 獲取操作系統名稱 (從 User-Agent)
function getOperatingSystem(userAgent) {
    if (!userAgent) return "未知";
    
    if (userAgent.includes("Windows")) return "Windows";
    if (userAgent.includes("Mac")) return "macOS";
    if (userAgent.includes("Linux")) return "Linux";
    if (userAgent.includes("Android")) return "Android";
    if (userAgent.includes("iOS")) return "iOS";
    
    return "其他";
}

// 驗證管理員權限的中間件
async function adminAuthMiddleware(req, res, next) {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return res.status(401).json({
            status: 'error',
            message: '未提供授權令牌'
        });
    }
    
    const token = authHeader.split(' ')[1];
    const JWT_SECRET = await getJwtSecret();
    
    try {
        // 驗證token
        const decoded = jwt.verify(token, JWT_SECRET);
        const { username } = decoded;
        
        // 檢查用戶是否是管理員
        const user = await User.findOne({ where: { username } });
        if (!user || !user.is_admin) {
            return res.status(403).json({
                status: 'error',
                message: '需要管理員權限'
            });
        }
        
        // 將用戶信息添加到請求對象
        req.user = { username, isAdmin: true };
        next();
    } catch (error) {
        return res.status(401).json({
            status: 'error',
            message: 'Token驗證失敗'
        });
    }
}

// 插件功能定義 - 不同授權類型的功能差異
const licenseBenefits = {
    standard: {
        description: "標準版授權 - 基礎功能",
        features: ["基本功能", "優先支援", "單一服務器"],
        maxDevices: 1 // 最多允許的裝置數
    },
    premium: {
        description: "高級版授權 - 進階功能",
        features: ["標準版全部功能", "進階功能", "優先Bug修復", "最多3個服務器"],
        maxDevices: 3 // 最多允許的裝置數
    },
    unlimited: {
        description: "無限版授權 - 完整功能",
        features: ["高級版全部功能", "全部功能", "無限服務器數量", "自訂功能開發優先權"],
        maxDevices: Infinity // 無限裝置數
    }
};

// 生成新的許可證金鑰
function generateLicenseKey() {
    return crypto.randomBytes(16).toString('hex');
}

// 驗證許可證的API端點
app.post('/api/validate', async (req, res) => {
    try {
        const { 
            license_key, 
            server_ip, 
            server_port, 
            server_name, 
            plugin_version,
            motherboard_id // 新增: 用於裝置識別的主機板ID
        } = req.body;

        // 記錄請求
        console.log(`收到來自 ${server_ip}:${server_port} (${server_name}) 的驗證請求，插件版本: ${plugin_version}, 主機板ID: ${motherboard_id}`);

        // 檢查許可證是否存在
        const license = await License.findOne({ where: { license_key } });
        if (!license) {
            console.log(`許可證金鑰 ${license_key} 不存在`);
            return res.status(404).json({
                status: 'error',
                message: 'Invalid license key'
            });
        }

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

        // 獲取地理位置信息
        const geo = geoip.lookup(server_ip) || { country: '未知', region: '未知', city: '未知' };
        const location = `${geo.country || '未知'}, ${geo.region || '未知'}, ${geo.city || '未知'}`;
        
        // 準備裝置信息
        const deviceInfo = {
            server_ip,
            server_port,
            server_name,
            plugin_version,
            location,
            operating_system: getOperatingSystem(req.headers['user-agent']),
            last_login: new Date(),
            active: true
        };

        // 檢查這個裝置是否已註冊
        let device = null;
        if (motherboard_id) {
            device = await Device.findOne({ 
                where: { 
                    license_key,
                    device_id: motherboard_id 
                } 
            });
        }

        if (motherboard_id && !device) {
            // 檢查裝置數量是否超過限制
            const activeDevices = await Device.count({ 
                where: { 
                    license_key, 
                    active: true 
                } 
            });
            
            const licenseType = license.type;
            const maxDevices = (licenseBenefits[licenseType] && licenseBenefits[licenseType].maxDevices) || 1;
            
            if (activeDevices >= maxDevices) {
                console.log(`許可證 ${license_key} 已達到最大裝置數 ${maxDevices}`);
                return res.status(403).json({
                    status: 'error',
                    message: 'Maximum device limit reached',
                    error: 'device_limit_reached'
                });
            }
            
            // 註冊新裝置
            device = await Device.create({
                license_key,
                device_id: motherboard_id,
                ...deviceInfo
            });
            console.log(`新裝置註冊: ${motherboard_id} 於許可證 ${license_key}`);
        } else if (motherboard_id && device) {
            // 檢查裝置是否被禁用
            if (!device.active) {
                console.log(`裝置 ${motherboard_id} 已被禁用, 拒絕訪問`);
                return res.status(403).json({
                    status: 'error',
                    message: 'Device has been deactivated',
                    error: 'device_deactivated'
                });
            }
            
            // 更新裝置信息
            await device.update(deviceInfo);
        }

        // 更新許可證使用記錄
        let usageHistory = license.usage_history || [];
        usageHistory.push({
            timestamp: new Date().toISOString(),
            server_ip,
            server_port,
            server_name,
            plugin_version,
            motherboard_id
        });
        
        // 限制歷史記錄大小
        if (usageHistory.length > 100) {
            usageHistory = usageHistory.slice(-100);
        }
        
        // 更新最後使用時間
        await license.update({
            last_used: new Date(),
            usage_history: usageHistory
        });
        
        console.log(`許可證 ${license_key} 驗證成功`);
        
        // 返回成功
        return res.json({
            status: 'success',
            message: 'License verified successfully',
            license_type: license.type,
            customer: license.customer_name,
            features: (licenseBenefits[license.type] && licenseBenefits[license.type].features) || []
        });
    } catch (error) {
        console.error('驗證許可證時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：獲取所有許可證
app.get('/api/admin/licenses', adminAuthMiddleware, async (req, res) => {
    try {
        const licenses = await License.findAll({
            include: [{
                model: Device,
                attributes: ['id', 'device_id', 'server_name', 'active']
            }]
        });
        
        // 處理結果並添加授權類型的權益信息
        const licensesWithBenefits = {};
        
        for (const license of licenses) {
            const licenseData = license.toJSON();
            const devices = licenseData.Devices || [];
            
            licensesWithBenefits[licenseData.license_key] = {
                ...licenseData,
                benefits: licenseBenefits[licenseData.type] || { features: [] },
                activeDevices: devices.filter(d => d.active).length,
                totalDevices: devices.length,
                maxDevices: (licenseBenefits[licenseData.type] && licenseBenefits[licenseData.type].maxDevices) || 1
            };
        }
        
        return res.json({
            status: 'success',
            licenses: licensesWithBenefits,
            license_types: licenseBenefits
        });
    } catch (error) {
        console.error('獲取許可證列表時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：創建新許可證
app.post('/api/admin/licenses', adminAuthMiddleware, async (req, res) => {
    try {
        const { customer_name, expiry, allowed_ips, type } = req.body;
        
        // 生成新的許可證
        const licenseKey = generateLicenseKey();
        
        // 存儲許可證信息
        const license = await License.create({
            license_key: licenseKey,
            created_at: new Date(),
            customer_name: customer_name || 'Unknown',
            expiry: expiry || null,
            allowed_ips: allowed_ips || [],
            type: type || 'standard',
            active: true,
            usage_history: []
        });
        
        // 返回新許可證信息
        return res.status(201).json({
            status: 'success',
            license_key: licenseKey,
            license: license.toJSON(),
            benefits: licenseBenefits[type || 'standard']
        });
    } catch (error) {
        console.error('創建許可證時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：更新許可證
app.put('/api/admin/licenses/:key', adminAuthMiddleware, async (req, res) => {
    try {
        const { active, expiry, allowed_ips, customer_name, type } = req.body;
        const licenseKey = req.params.key;
        
        // 檢查許可證是否存在
        const license = await License.findOne({ where: { license_key: licenseKey } });
        if (!license) {
            return res.status(404).json({
                status: 'error',
                message: 'License not found'
            });
        }
        
        // 準備更新數據
        const updateData = {};
        if (active !== undefined) updateData.active = active;
        if (expiry !== undefined) updateData.expiry = expiry;
        if (allowed_ips !== undefined) updateData.allowed_ips = allowed_ips;
        if (customer_name !== undefined) updateData.customer_name = customer_name;
        if (type !== undefined) updateData.type = type;
        
        // 更新許可證
        await license.update(updateData);
        
        // 獲取更新後的許可證
        const updatedLicense = await License.findOne({ 
            where: { license_key: licenseKey },
            include: [{
                model: Device,
                attributes: ['id', 'device_id', 'server_name', 'active']
            }]
        });
        
        return res.json({
            status: 'success',
            license: updatedLicense.toJSON(),
            benefits: licenseBenefits[updatedLicense.type]
        });
    } catch (error) {
        console.error('更新許可證時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：管理裝置狀態
app.put('/api/admin/licenses/:key/devices/:deviceId', adminAuthMiddleware, async (req, res) => {
    try {
        const { active } = req.body;
        const licenseKey = req.params.key;
        const deviceId = req.params.deviceId;
        
        // 檢查許可證是否存在
        const license = await License.findOne({ where: { license_key: licenseKey } });
        if (!license) {
            return res.status(404).json({
                status: 'error',
                message: 'License not found'
            });
        }
        
        // 檢查裝置是否存在
        const device = await Device.findOne({ 
            where: { 
                license_key: licenseKey,
                device_id: deviceId
            } 
        });
        
        if (!device) {
            return res.status(404).json({
                status: 'error',
                message: 'Device not found'
            });
        }
        
        // 更新裝置狀態
        await device.update({ active });
        
        return res.json({
            status: 'success',
            message: active ? '裝置已啟用' : '裝置已禁用',
            device: device.toJSON()
        });
    } catch (error) {
        console.error('管理裝置狀態時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：刪除裝置
app.delete('/api/admin/licenses/:key/devices/:deviceId', adminAuthMiddleware, async (req, res) => {
    try {
        const licenseKey = req.params.key;
        const deviceId = req.params.deviceId;
        
        // 檢查許可證是否存在
        const license = await License.findOne({ where: { license_key: licenseKey } });
        if (!license) {
            return res.status(404).json({
                status: 'error',
                message: 'License not found'
            });
        }
        
        // 檢查裝置是否存在
        const device = await Device.findOne({ 
            where: { 
                license_key: licenseKey,
                device_id: deviceId
            } 
        });
        
        if (!device) {
            return res.status(404).json({
                status: 'error',
                message: 'Device not found'
            });
        }
        
        // 刪除裝置
        await device.destroy();
        
        return res.json({
            status: 'success',
            message: '裝置已刪除'
        });
    } catch (error) {
        console.error('刪除裝置時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 管理API：重設所有裝置
app.post('/api/admin/licenses/:key/devices/reset', adminAuthMiddleware, async (req, res) => {
    try {
        const licenseKey = req.params.key;
        
        // 檢查許可證是否存在
        const license = await License.findOne({ where: { license_key: licenseKey } });
        if (!license) {
            return res.status(404).json({
                status: 'error',
                message: 'License not found'
            });
        }
        
        // 刪除所有裝置
        await Device.destroy({ where: { license_key: licenseKey } });
        
        return res.json({
            status: 'success',
            message: '所有裝置已重設'
        });
    } catch (error) {
        console.error('重設裝置時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 驗證JWT token
app.post('/api/admin/verify-token', async (req, res) => {
    try {
        const { token, username } = req.body;
        const JWT_SECRET = await getJwtSecret();
        
        try {
            const decoded = jwt.verify(token, JWT_SECRET);
            if (decoded.username === username) {
                const user = await User.findOne({ where: { username } });
                if (user) {
                    return res.json({
                        status: 'success',
                        message: 'Token有效'
                    });
                }
            }
            
            return res.status(401).json({
                status: 'error',
                message: 'Token無效'
            });
        } catch (error) {
            return res.status(401).json({
                status: 'error',
                message: 'Token驗證失敗'
            });
        }
    } catch (error) {
        console.error('驗證Token時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 檢查是否存在管理員帳號
app.get('/api/admin/check-exists', async (req, res) => {
    try {
        const adminCount = await User.count({ where: { is_admin: true } });
        return res.json({
            status: 'success',
            exists: adminCount > 0
        });
    } catch (error) {
        console.error('檢查管理員帳號時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 用戶登入API
app.post('/api/admin/login', async (req, res) => {
    try {
        const { username, password } = req.body;
        
        const user = await User.findOne({ where: { username } });
        if (!user) {
            return res.status(401).json({
                status: 'error',
                message: '用戶名或密碼錯誤'
            });
        }
        
        if (!verifyPassword(password, user.password_hash)) {
            return res.status(401).json({
                status: 'error',
                message: '用戶名或密碼錯誤'
            });
        }
        
        const token = await generateToken(username);
        
        return res.json({
            status: 'success',
            message: '登入成功',
            token,
            username
        });
    } catch (error) {
        console.error('登入時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 用戶註冊API
app.post('/api/admin/register', async (req, res) => {
    try {
        const { username, password } = req.body;
        
        // 檢查用戶名長度
        if (!username || username.length < 5) {
            return res.status(400).json({
                status: 'error',
                message: '用戶名至少需要5個字符'
            });
        }
        
        // 檢查密碼長度
        if (!password || password.length < 8) {
            return res.status(400).json({
                status: 'error',
                message: '密碼至少需要8個字符'
            });
        }
        
        // 檢查用戶名是否已存在
        const existingUser = await User.findOne({ where: { username } });
        if (existingUser) {
            return res.status(400).json({
                status: 'error',
                message: '用戶名已存在'
            });
        }
        
        // 檢查是否已有管理員（除非是第一個用戶）
        const adminCount = await User.count({ where: { is_admin: true } });
        const isAdmin = adminCount === 0; // 第一個註冊的用戶是管理員
        
        // 創建新用戶
        await User.create({
            username,
            password_hash: hashPassword(password),
            is_admin: isAdmin,
            created_at: new Date()
        });
        
        return res.status(201).json({
            status: 'success',
            message: '註冊成功',
            is_admin: isAdmin
        });
    } catch (error) {
        console.error('註冊時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
        });
    }
});

// 更新密碼API
app.post('/api/admin/update-password', async (req, res) => {
    try {
        // 獲取Authorization header
        const authHeader = req.headers.authorization;
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            return res.status(401).json({
                status: 'error',
                message: '未提供授權令牌'
            });
        }
        
        const token = authHeader.split(' ')[1];
        const JWT_SECRET = await getJwtSecret();
        
        try {
            // 驗證token
            const decoded = jwt.verify(token, JWT_SECRET);
            const { username } = decoded;
            
            const { current_password, new_password } = req.body;
            
            // 檢查用戶是否存在
            const user = await User.findOne({ where: { username } });
            if (!user) {
                return res.status(404).json({
                    status: 'error',
                    message: '用戶不存在'
                });
            }
            
            // 驗證當前密碼
            if (!verifyPassword(current_password, user.password_hash)) {
                return res.status(401).json({
                    status: 'error',
                    message: '當前密碼錯誤'
                });
            }
            
            // 檢查是否需要更新密碼
            if (new_password) {
                if (new_password.length < 8) {
                    return res.status(400).json({
                        status: 'error',
                        message: '新密碼至少需要8個字符'
                    });
                }
                
                // 更新密碼
                await user.update({ password_hash: hashPassword(new_password) });
                
                // 生成新token
                const newToken = await generateToken(username);
                
                return res.json({
                    status: 'success',
                    message: '密碼已成功更新',
                    token: newToken
                });
            } else {
                return res.json({
                    status: 'success',
                    message: '無密碼更新'
                });
            }
        } catch (error) {
            return res.status(401).json({
                status: 'error',
                message: 'Token驗證失敗'
            });
        }
    } catch (error) {
        console.error('更新密碼時出錯:', error);
        return res.status(500).json({
            status: 'error',
            message: '服務器內部錯誤'
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

// 初始化數據庫並啟動伺服器
initializeDatabase().then(() => {
    app.listen(PORT, () => {
        console.log(`許可證驗證伺服器在埠口 ${PORT} 上運行中`);
    });
}).catch(error => {
    console.error('啟動伺服器失敗:', error);
});
EOF

# 創建管理介面
sudo tee /opt/license-server/admin.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Minecraft 插件授權管理</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1, h2 {
            color: #333;
        }
        .card {
            background-color: white;
            border-radius: 5px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            padding: 20px;
            margin-bottom: 20px;
        }
        .btn {
            display: inline-block;
            padding: 8px 16px;
            background-color: #4CAF50;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
        }
        .btn:hover {
            background-color: #45a049;
        }
        input, select {
            padding: 8px;
            border: 1px solid #ddd;
            border-radius: 4px;
            width: 100%;
            margin-bottom: 15px;
        }
        .login-form {
            max-width: 400px;
            margin: 50px auto;
        }
        .error-message {
            color: red;
            margin-bottom: 15px;
        }
        .success-message {
            color: green;
            margin-bottom: 15px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
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
        .hidden {
            display: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Minecraft 插件授權管理系統</h1>

        <!-- 登入表單 -->
        <div id="login-section" class="card login-form">
            <h2>管理員登入</h2>
            <div id="login-error" class="error-message hidden"></div>
            <div>
                <label for="username">用戶名</label>
                <input type="text" id="username" placeholder="請輸入用戶名">
            </div>
            <div>
                <label for="password">密碼</label>
                <input type="password" id="password" placeholder="請輸入密碼">
            </div>
            <button id="login-btn" class="btn">登入</button>
        </div>

        <!-- 主要管理界面 -->
        <div id="management-section" class="hidden">
            <div class="card">
                <h2>許可證管理</h2>
                <button id="create-license-btn" class="btn">創建新許可證</button>
                <div id="licenses-table-container">
                    <table id="licenses-table">
                        <thead>
                            <tr>
                                <th>許可證金鑰</th>
                                <th>客戶名稱</th>
                                <th>授權類型</th>
                                <th>狀態</th>
                                <th>過期日期</th>
                                <th>已用裝置/最大裝置</th>
                                <th>操作</th>
                            </tr>
                        </thead>
                        <tbody id="licenses-body">
                            <!-- 許可證列表將在此動態生成 -->
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <!-- 創建許可證表單 -->
        <div id="create-license-form" class="card hidden">
            <h2>創建新許可證</h2>
            <div>
                <label for="customer-name">客戶名稱</label>
                <input type="text" id="customer-name" placeholder="請輸入客戶名稱">
            </div>
            <div>
                <label for="license-type">授權類型</label>
                <select id="license-type">
                    <option value="standard">標準版</option>
                    <option value="premium">高級版</option>
                    <option value="unlimited">無限版</option>
                </select>
            </div>
            <div>
                <label for="expiry-date">過期日期 (可選)</label>
                <input type="date" id="expiry-date">
            </div>
            <button id="save-license-btn" class="btn">儲存</button>
            <button id="cancel-license-btn" class="btn" style="background-color: #f44336;">取消</button>
        </div>

        <!-- 裝置管理界面 -->
        <div id="device-management" class="card hidden">
            <h2>裝置管理</h2>
            <h3 id="license-info"></h3>
            <button id="reset-devices-btn" class="btn" style="background-color: #f44336;">重設所有裝置</button>
            <div id="devices-table-container">
                <table id="devices-table">
                    <thead>
                        <tr>
                            <th>裝置ID</th>
                            <th>伺服器名稱</th>
                            <th>伺服器IP</th>
                            <th>操作系統</th>
                            <th>地理位置</th>
                            <th>最後登入</th>
                            <th>狀態</th>
                            <th>操作</th>
                        </tr>
                    </thead>
                    <tbody id="devices-body">
                        <!-- 裝置列表將在此動態生成 -->
                    </tbody>
                </table>
            </div>
            <button id="back-to-licenses-btn" class="btn">返回許可證列表</button>
        </div>
    </div>

    <script>
        // 全局變數
        let currentLicenseKey = '';
        let authToken = localStorage.getItem('authToken');
        let username = localStorage.getItem('username');

        // 檢查用戶是否已登入
        window.onload = function() {
            if (authToken) {
                verifyToken();
            } else {
                showLoginForm();
            }
        };

        // 驗證JWT token
        function verifyToken() {
            fetch('/api/admin/verify-token', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    token: authToken,
                    username: username
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    showManagementInterface();
                    loadLicenses();
                } else {
                    showLoginForm();
                }
            })
            .catch(error => {
                console.error('驗證Token出錯:', error);
                showLoginForm();
            });
        }

        // 顯示登入表單
        function showLoginForm() {
            document.getElementById('login-section').classList.remove('hidden');
            document.getElementById('management-section').classList.add('hidden');
            document.getElementById('create-license-form').classList.add('hidden');
            document.getElementById('device-management').classList.add('hidden');
        }

        // 顯示管理界面
        function showManagementInterface() {
            document.getElementById('login-section').classList.add('hidden');
            document.getElementById('management-section').classList.remove('hidden');
            document.getElementById('create-license-form').classList.add('hidden');
            document.getElementById('device-management').classList.add('hidden');
        }

        // 顯示創建許可證表單
        function showCreateLicenseForm() {
            document.getElementById('login-section').classList.add('hidden');
            document.getElementById('management-section').classList.add('hidden');
            document.getElementById('create-license-form').classList.remove('hidden');
            document.getElementById('device-management').classList.add('hidden');
        }

        // 顯示裝置管理界面
        function showDeviceManagement(licenseKey, customerName, licenseType) {
            currentLicenseKey = licenseKey;
            document.getElementById('login-section').classList.add('hidden');
            document.getElementById('management-section').classList.add('hidden');
            document.getElementById('create-license-form').classList.add('hidden');
            document.getElementById('device-management').classList.remove('hidden');
            document.getElementById('license-info').textContent = `許可證: ${licenseKey} (${customerName}, ${getLicenseTypeName(licenseType)})`;
            loadDevices(licenseKey);
        }

        // 登入處理
        document.getElementById('login-btn').addEventListener('click', function() {
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            
            fetch('/api/admin/login', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    username: username,
                    password: password
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    localStorage.setItem('authToken', data.token);
                    localStorage.setItem('username', data.username);
                    authToken = data.token;
                    username = data.username;
                    showManagementInterface();
                    loadLicenses();
                } else {
                    document.getElementById('login-error').textContent = data.message;
                    document.getElementById('login-error').classList.remove('hidden');
                }
            })
            .catch(error => {
                console.error('登入出錯:', error);
                document.getElementById('login-error').textContent = '伺服器連接錯誤';
                document.getElementById('login-error').classList.remove('hidden');
            });
        });

        // 載入許可證列表
        function loadLicenses() {
            fetch('/api/admin/licenses', {
                headers: {
                    'Authorization': `Bearer ${authToken}`
                }
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    const licensesTable = document.getElementById('licenses-body');
                    licensesTable.innerHTML = '';
                    
                    for (const [key, license] of Object.entries(data.licenses)) {
                        const row = document.createElement('tr');
                        
                        row.innerHTML = `
                            <td>${key}</td>
                            <td>${license.customer_name}</td>
                            <td>${getLicenseTypeName(license.type)}</td>
                            <td>${license.active ? '啟用' : '禁用'}</td>
                            <td>${license.expiry ? new Date(license.expiry).toLocaleDateString() : '永久'}</td>
                            <td>${license.activeDevices}/${license.maxDevices}</td>
                            <td>
                                <button class="btn" onclick="showDeviceManagement('${key}', '${license.customer_name}', '${license.type}')">管理裝置</button>
                                <button class="btn" onclick="toggleLicenseStatus('${key}', ${!license.active})">${license.active ? '禁用' : '啟用'}</button>
                            </td>
                        `;
                        
                        licensesTable.appendChild(row);
                    }
                } else {
                    console.error('載入許可證列表出錯:', data.message);
                }
            })
            .catch(error => {
                console.error('載入許可證列表時出錯:', error);
            });
        }

        // 創建許可證按鈕處理
        document.getElementById('create-license-btn').addEventListener('click', function() {
            showCreateLicenseForm();
        });

        // 儲存許可證處理
        document.getElementById('save-license-btn').addEventListener('click', function() {
            const customerName = document.getElementById('customer-name').value;
            const licenseType = document.getElementById('license-type').value;
            const expiryDate = document.getElementById('expiry-date').value;
            
            fetch('/api/admin/licenses', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${authToken}`
                },
                body: JSON.stringify({
                    customer_name: customerName,
                    type: licenseType,
                    expiry: expiryDate || null
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    showManagementInterface();
                    loadLicenses();
                    alert(`成功創建許可證: ${data.license_key}`);
                } else {
                    alert(`創建許可證失敗: ${data.message}`);
                }
            })
            .catch(error => {
                console.error('創建許可證時出錯:', error);
                alert('伺服器連接錯誤');
            });
        });

        // 取消創建許可證處理
        document.getElementById('cancel-license-btn').addEventListener('click', function() {
            showManagementInterface();
        });

        // 返回許可證列表處理
        document.getElementById('back-to-licenses-btn').addEventListener('click', function() {
            showManagementInterface();
        });

        // 載入裝置列表
        function loadDevices(licenseKey) {
            fetch(`/api/admin/licenses/${licenseKey}`, {
                headers: {
                    'Authorization': `Bearer ${authToken}`
                }
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    const devicesTable = document.getElementById('devices-body');
                    devicesTable.innerHTML = '';
                    
                    if (data.license.Devices && data.license.Devices.length > 0) {
                        data.license.Devices.forEach(device => {
                            const row = document.createElement('tr');
                            
                            row.innerHTML = `
                                <td>${device.device_id}</td>
                                <td>${device.server_name || 'N/A'}</td>
                                <td>${device.server_ip || 'N/A'}</td>
                                <td>${device.operating_system || 'N/A'}</td>
                                <td>${device.location || 'N/A'}</td>
                                <td>${device.last_login ? new Date(device.last_login).toLocaleString() : 'N/A'}</td>
                                <td>${device.active ? '啟用' : '禁用'}</td>
                                <td>
                                    <button class="btn" onclick="toggleDeviceStatus('${licenseKey}', '${device.device_id}', ${!device.active})">${device.active ? '禁用' : '啟用'}</button>
                                    <button class="btn" style="background-color: #f44336;" onclick="deleteDevice('${licenseKey}', '${device.device_id}')">刪除</button>
                                </td>
                            `;
                            
                            devicesTable.appendChild(row);
                        });
                    } else {
                        devicesTable.innerHTML = '<tr><td colspan="8">尚無裝置註冊</td></tr>';
                    }
                } else {
                    console.error('載入裝置列表出錯:', data.message);
                }
            })
            .catch(error => {
                console.error('載入裝置列表時出錯:', error);
            });
        }

        // 切換許可證狀態
        function toggleLicenseStatus(licenseKey, active) {
            fetch(`/api/admin/licenses/${licenseKey}`, {
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${authToken}`
                },
                body: JSON.stringify({
                    active: active
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    loadLicenses();
                } else {
                    alert(`更新許可證狀態失敗: ${data.message}`);
                }
            })
            .catch(error => {
                console.error('更新許可證狀態時出錯:', error);
                alert('伺服器連接錯誤');
            });
        }

        // 切換裝置狀態
        function toggleDeviceStatus(licenseKey, deviceId, active) {
            fetch(`/api/admin/licenses/${licenseKey}/devices/${deviceId}`, {
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${authToken}`
                },
                body: JSON.stringify({
                    active: active
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    loadDevices(licenseKey);
                } else {
                    alert(`更新裝置狀態失敗: ${data.message}`);
                }
            })
            .catch(error => {
                console.error('更新裝置狀態時出錯:', error);
                alert('伺服器連接錯誤');
            });
        }

        // 刪除裝置
        function deleteDevice(licenseKey, deviceId) {
            if (confirm('確定要刪除這個裝置嗎？')) {
                fetch(`/api/admin/licenses/${licenseKey}/devices/${deviceId}`, {
                    method: 'DELETE',
                    headers: {
                        'Authorization': `Bearer ${authToken}`
                    }
                })
                .then(response => response.json())
                .then(data => {
                    if (data.status === 'success') {
                        loadDevices(licenseKey);
                    } else {
                        alert(`刪除裝置失敗: ${data.message}`);
                    }
                })
                .catch(error => {
                    console.error('刪除裝置時出錯:', error);
                    alert('伺服器連接錯誤');
                });
            }
        }

        // 重設所有裝置
        document.getElementById('reset-devices-btn').addEventListener('click', function() {
            if (confirm('確定要重設所有裝置嗎？這將刪除此許可證下的所有註冊裝置。')) {
                fetch(`/api/admin/licenses/${currentLicenseKey}/devices/reset`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${authToken}`
                    }
                })
                .then(response => response.json())
                .then(data => {
                    if (data.status === 'success') {
                        loadDevices(currentLicenseKey);
                    } else {
                        alert(`重設裝置失敗: ${data.message}`);
                    }
                })
                .catch(error => {
                    console.error('重設裝置時出錯:', error);
                    alert('伺服器連接錯誤');
                });
            }
        });

        // 獲取許可證類型名稱
        function getLicenseTypeName(type) {
            const typeNames = {
                'standard': '標準版',
                'premium': '高級版',
                'unlimited': '無限版'
            };
            return typeNames[type] || type;
        }
    </script>
</body>
</html>
EOF

# 創建空的licenses.json文件
echo -e "${GREEN}創建licenses.json數據庫文件...${NC}"
echo "{}" > licenses.json

# 生成隨機的JWT密鑰
JWT_SECRET=$(openssl rand -hex 32)

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
# 創建重設管理員密碼腳本
echo -e "${GREEN}創建重設管理員密碼腳本...${NC}"
cat > reset_admin_password.sh << 'EOF'
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
chmod +x reset_admin_password.sh

# 複製重設密碼腳本到/usr/local/bin/
cp reset_admin_password.sh /usr/local/bin/
chmod +x /usr/local/bin/reset_admin_password.sh

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
echo -e "${GREEN}創建管理員數據庫文件...${NC}"
cat > users.json << EOF
{
  "$ADMIN_USERNAME": {
    "password_hash": "$(echo -n "$ADMIN_PASSWORD" | sha256sum | awk '{print $1}')",
    "is_admin": true,
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }
}
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
echo "您可以使用以下指令查看日誌: pm2 logs license-server"
echo "如果忘記密碼，您可以使用以下指令重設管理員密碼: sudo reset_admin_password.sh"