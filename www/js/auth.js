// 全局變數
let currentLicenseKey = '';
let authToken = localStorage.getItem('authToken');
let username = localStorage.getItem('username');
let changePasswordModal = null;

// 頁面加載完成後執行
document.addEventListener('DOMContentLoaded', function() {
    // 初始化 Bootstrap modal
    const modalElement = document.getElementById('changePasswordModal');
    if (modalElement) {
        try {
            changePasswordModal = new bootstrap.Modal(modalElement);
        } catch (error) {
            console.error('初始化修改密碼對話框失敗:', error);
        }
    }
    
    // 檢查登入狀態
    if (authToken) {
        verifyToken();
    } else {
        showLoginForm();
    }
    
    // 初始化所有必要的事件監聽器
    initializeEventListeners();
});

// 初始化所有事件監聽器
function initializeEventListeners() {
    const elements = {
        'login-form': handleLogin,
        'license-form': saveLicense,
        'create-license-btn': showCreateLicenseForm,
        'cancel-license-btn': showManagementInterface,
        'back-to-licenses-btn': showManagementInterface,
        'breadcrumb-home': handleBreadcrumbClick,
        'reset-devices-btn': resetAllDevices,
        'logout-btn': handleLogout,
        'change-password-btn': () => {
            const form = document.getElementById('change-password-form');
            if (form) form.reset();
            if (changePasswordModal) changePasswordModal.show();
        },
        'update-password-btn': updatePassword
    };

    for (const [id, handler] of Object.entries(elements)) {
        const element = document.getElementById(id);
        if (element) {
            if (id.endsWith('-form')) {
                element.addEventListener('submit', function(e) {
                    e.preventDefault();
                    handler();
                });
            } else {
                element.addEventListener('click', handler);
            }
        }
    }
}

// 驗證JWT token
function verifyToken() {
    fetch('/api/admin/verify-token', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${authToken}`
        },
        body: JSON.stringify({
            token: authToken,
            username: username
        })
    })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.json();
    })
    .then(data => {
        if (data.status === 'success') {
            const currentUsernameElement = document.getElementById('current-username');
            if (currentUsernameElement) {
                currentUsernameElement.textContent = username;
            }
            showManagementInterface();
            loadLicenses();
        } else {
            throw new Error(data.message || '驗證失敗');
        }
    })
    .catch(error => {
        console.error('驗證Token出錯:', error);
        handleAuthError();
    });
}

// 處理驗證錯誤
function handleAuthError() {
    localStorage.removeItem('authToken');
    localStorage.removeItem('username');
    authToken = null;
    username = null;
    showLoginForm();
}

// 顯示登入表單
function showLoginForm() {
    const elements = {
        'main-navbar': true,
        'login-section': false,
        'management-section': true,
        'create-license-form': true,
        'device-management': true
    };

    Object.entries(elements).forEach(([id, shouldHide]) => {
        const element = document.getElementById(id);
        if (element) {
            element.classList[shouldHide ? 'add' : 'remove']('hidden');
        }
    });

    // 清理登入表單
    const loginForm = document.getElementById('login-form');
    if (loginForm) loginForm.reset();
}

// 顯示管理界面
function showManagementInterface() {
    const elements = {
        'main-navbar': false,
        'login-section': true,
        'management-section': false,
        'create-license-form': true,
        'device-management': true
    };

    Object.entries(elements).forEach(([id, shouldHide]) => {
        const element = document.getElementById(id);
        if (element) {
            element.classList[shouldHide ? 'add' : 'remove']('hidden');
        }
    });
}

// 處理麵包屑點擊
function handleBreadcrumbClick(e) {
    e.preventDefault();
    showManagementInterface();
}

// 處理登入
function handleLogin() {
    const usernameInput = document.getElementById('username');
    const passwordInput = document.getElementById('password');
    const loginBtn = document.getElementById('login-btn');
    const loginError = document.getElementById('login-error');

    if (!usernameInput || !passwordInput || !loginBtn) {
        console.error('找不到必要的表單元素');
        return;
    }

    // 顯示載入狀態
    loginBtn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>登入中...';
    loginBtn.disabled = true;

    fetch('/api/admin/login', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            username: usernameInput.value,
            password: passwordInput.value
        })
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            handleLoginSuccess(data);
        } else {
            handleLoginError(loginBtn, loginError, data.message);
        }
    })
    .catch(error => {
        console.error('登入出錯:', error);
        handleLoginError(loginBtn, loginError, '伺服器連接錯誤');
    });
}

// 處理登入成功
function handleLoginSuccess(data) {
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
        const currentUsernameElement = document.getElementById('current-username');
        if (currentUsernameElement) {
            currentUsernameElement.textContent = username;
        }
        showManagementInterface();
        loadLicenses();
    });
}

// 處理登入錯誤
function handleLoginError(loginBtn, loginError, message) {
    if (loginError) {
        loginError.textContent = message || '登入失敗，請檢查您的憑證';
        loginError.classList.remove('hidden');
    }
    loginBtn.innerHTML = '<i class="fas fa-sign-in-alt me-2"></i>登入';
    loginBtn.disabled = false;
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
            handleAuthError();
        }
    });
}

// 更新密碼
function updatePassword() {
    const currentPassword = document.getElementById('current-password').value;
    const newPassword = document.getElementById('new-password').value;
    const confirmPassword = document.getElementById('confirm-password').value;
    const updatePasswordBtn = document.getElementById('update-password-btn');
    
    if (!validatePasswordInput(currentPassword, newPassword, confirmPassword)) {
        return;
    }
    
    updatePasswordRequest(currentPassword, newPassword, updatePasswordBtn);
}

// 驗證密碼輸入
function validatePasswordInput(currentPassword, newPassword, confirmPassword) {
    if (!currentPassword || !newPassword || !confirmPassword) {
        Swal.fire('錯誤', '所有欄位都必須填寫', 'error');
        return false;
    }
    
    if (newPassword.length < 8) {
        Swal.fire('錯誤', '新密碼長度至少為8個字符', 'error');
        return false;
    }
    
    if (newPassword !== confirmPassword) {
        Swal.fire('錯誤', '兩次輸入的新密碼不一致', 'error');
        return false;
    }
    
    return true;
}

// 發送更新密碼請求
function updatePasswordRequest(currentPassword, newPassword, updatePasswordBtn) {
    updatePasswordBtn.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>更新中...';
    updatePasswordBtn.disabled = true;
    
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
    .then(data => handlePasswordUpdateResponse(data, updatePasswordBtn))
    .catch(error => handlePasswordUpdateError(error, updatePasswordBtn));
}

// 處理密碼更新回應
function handlePasswordUpdateResponse(data, updatePasswordBtn) {
    updatePasswordBtn.innerHTML = '更新密碼';
    updatePasswordBtn.disabled = false;
    
    if (data.status === 'success') {
        if (changePasswordModal) changePasswordModal.hide();
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
}

// 處理密碼更新錯誤
function handlePasswordUpdateError(error, updatePasswordBtn) {
    console.error('更新密碼時出錯:', error);
    updatePasswordBtn.innerHTML = '更新密碼';
    updatePasswordBtn.disabled = false;
    Swal.fire({
        icon: 'error',
        title: '伺服器錯誤',
        text: '無法連接到伺服器，請稍後再試'
    });
}