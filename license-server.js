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