// 全局變數
let currentLicenseKey = '';
let authToken = localStorage.getItem('authToken');
let username = localStorage.getItem('username');
let changePasswordModal;

// 頁面加載完成後執行
window.onload = function() {
    // 初始化 Bootstrap modal
    changePasswordModal = new bootstrap.Modal(document.getElementById('changePasswordModal'));
    if (authToken) {
        verifyToken();
    } else {
        showLoginForm();
    }
    // 初始化表單提交事件
    document.getElementById('login-form').addEventListener('submit', function(e) {
        e.preventDefault();
        handleLogin();
    });
    document.getElementById('license-form').addEventListener('submit', function(e) {
        e.preventDefault();
        saveLicense();
    });

    // 綁定其他事件處理程序
    bindEventHandlers();
};

// 綁定所有事件處理程序
function bindEventHandlers() {
    // 創建許可證按鈕處理
    document.getElementById('create-license-btn').addEventListener('click', function() {
        showCreateLicenseForm();
    });

    // 取消創建許可證處理
    document.getElementById('cancel-license-btn').addEventListener('click', function() {
        showManagementInterface();
    });

    // 返回許可證列表處理
    document.getElementById('back-to-licenses-btn').addEventListener('click', function() {
        showManagementInterface();
    });
    
    document.getElementById('breadcrumb-home').addEventListener('click', function(e) {
        e.preventDefault();
        showManagementInterface();
    });

    // 重設所有裝置
    document.getElementById('reset-devices-btn').addEventListener('click', function() {
        resetAllDevices();
    });

    // 登出處理
    document.getElementById('logout-btn').addEventListener('click', function() {
        handleLogout();
    });

    // 修改密碼按鈕
    document.getElementById('change-password-btn').addEventListener('click', function() {
        document.getElementById('change-password-form').reset();
        changePasswordModal.show();
    });

    // 更新密碼
    document.getElementById('update-password-btn').addEventListener('click', function() {
        updatePassword();
    });
}

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
            document.getElementById('current-username').textContent = username;
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
    document.getElementById('main-navbar').classList.add('hidden');
    document.getElementById('login-section').classList.remove('hidden');
    document.getElementById('management-section').classList.add('hidden');
    document.getElementById('create-license-form').classList.add('hidden');
    document.getElementById('device-management').classList.add('hidden');
}

// 顯示管理界面
function showManagementInterface() {
    document.getElementById('main-navbar').classList.remove('hidden');
    document.getElementById('login-section').classList.add('hidden');
    document.getElementById('management-section').classList.remove('hidden');
    document.getElementById('create-license-form').classList.add('hidden');
    document.getElementById('device-management').classList.add('hidden');
}

// 顯示創建許可證表單
function showCreateLicenseForm() {
    document.getElementById('main-navbar').classList.remove('hidden');
    document.getElementById('login-section').classList.add('hidden');
    document.getElementById('management-section').classList.add('hidden');
    document.getElementById('create-license-form').classList.remove('hidden');
    document.getElementById('device-management').classList.add('hidden');
    
    // 重置表單
    document.getElementById('license-form').reset();
}

// 登入處理
function handleLogin() {
    let usernameInput = document.getElementById('username').value;
    let password = document.getElementById('password').value;
    
    // 顯示載入狀態
    document.getElementById('login-btn').innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>登入中...';
    document.getElementById('login-btn').disabled = true;
    
    fetch('/api/admin/login', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            username: usernameInput,
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
            
            Swal.fire({
                icon: 'success',
                title: '登入成功',
                text: '歡迎回來，' + username,
                timer: 1500,
                showConfirmButton: false
            }).then(() => {
                document.getElementById('current-username').textContent = username;
                showManagementInterface();
                loadLicenses();
            });
        } else {
            document.getElementById('login-error').textContent = data.message || '登入失敗，請檢查您的憑證';
            document.getElementById('login-error').classList.remove('hidden');
            document.getElementById('login-btn').innerHTML = '<i class="fas fa-sign-in-alt me-2"></i>登入';
            document.getElementById('login-btn').disabled = false;
        }
    })
    .catch(error => {
        console.error('登入出錯:', error);
        document.getElementById('login-error').textContent = '伺服器連接錯誤';
        document.getElementById('login-error').classList.remove('hidden');
        document.getElementById('login-btn').innerHTML = '<i class="fas fa-sign-in-alt me-2"></i>登入';
        document.getElementById('login-btn').disabled = false;
    });
}

// 處理登出
function handleLogout() {
    Swal.fire({
        title: '確定要登出嗎？',
        icon: 'question',
        showCancelButton: true,
        confirmButtonColor: '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: '是，登出',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            localStorage.removeItem('authToken');
            localStorage.removeItem('username');
            authToken = null;
            username = null;
            showLoginForm();
        }
    });
}

// 更新密碼
function updatePassword() {
    const currentPassword = document.getElementById('current-password').value;
    const newPassword = document.getElementById('new-password').value;
    const confirmPassword = document.getElementById('confirm-password').value;
    
    // 驗證輸入
    if (!currentPassword || !newPassword || !confirmPassword) {
        Swal.fire('錯誤', '所有欄位都必須填寫', 'error');
        return;
    }
    
    if (newPassword.length < 8) {
        Swal.fire('錯誤', '新密碼長度至少為8個字符', 'error');
        return;
    }
    
    if (newPassword !== confirmPassword) {
        Swal.fire('錯誤', '兩次輸入的新密碼不一致', 'error');
        return;
    }
    
    // 顯示載入狀態
    document.getElementById('update-password-btn').innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>更新中...';
    document.getElementById('update-password-btn').disabled = true;
    
    fetch('/api/admin/update-password', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${authToken}`
        },
        body: JSON.stringify({
            username: username,
            current_password: currentPassword,
            new_password: newPassword
        })
    })
    .then(response => response.json())
    .then(data => {
        document.getElementById('update-password-btn').innerHTML = '更新密碼';
        document.getElementById('update-password-btn').disabled = false;
        
        if (data.status === 'success') {
            changePasswordModal.hide();
            Swal.fire({
                icon: 'success',
                title: '密碼已更新',
                text: '您的密碼已成功更新',
                timer: 1500,
                showConfirmButton: false
            });
        } else {
            Swal.fire({
                icon: 'error',
                title: '更新失敗',
                text: data.message || '無法更新密碼'
            });
        }
    })
    .catch(error => {
        console.error('更新密碼時出錯:', error);
        document.getElementById('update-password-btn').innerHTML = '更新密碼';
        document.getElementById('update-password-btn').disabled = false;
        Swal.fire({
            icon: 'error',
            title: '伺服器錯誤',
            text: '無法連接到伺服器，請稍後再試'
        });
    });
}