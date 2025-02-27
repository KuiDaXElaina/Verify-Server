// 載入許可證列表
function loadLicenses() {
    document.getElementById('licenses-body').innerHTML = '<tr><td colspan="7" class="text-center"><div class="spinner-border spinner-border-sm text-primary me-2"></div>載入中...</td></tr>';
    
    fetch('/api/admin/licenses', {
        headers: {
            'Authorization': `Bearer ${authToken}`
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            const licenses = data.licenses;
            const licensesTable = document.getElementById('licenses-body');
            licensesTable.innerHTML = '';
            
            // 更新儀表板統計
            const totalLicenses = Object.keys(licenses).length;
            let activeLicenses = 0;
            
            if (totalLicenses === 0) {
                licensesTable.innerHTML = '<tr><td colspan="7" class="text-center">尚無許可證資料</td></tr>';
            } else {
                for (const [key, license] of Object.entries(licenses)) {
                    if (license.active) activeLicenses++;
                    
                    const row = document.createElement('tr');
                    
                    // 創建狀態徽章
                    const statusBadge = document.createElement('span');
                    statusBadge.className = license.active ? 'badge bg-success' : 'badge bg-danger';
                    statusBadge.textContent = license.active ? '啟用' : '禁用';
                    
                    // 創建裝置使用情況進度條
                    const deviceUsage = (license.activeDevices / license.maxDevices) * 100;
                    const progressBarClass = deviceUsage < 60 ? 'bg-success' : 
                                           deviceUsage < 90 ? 'bg-warning' : 'bg-danger';
                    const progressBar = `
                        <div class="progress" style="height: 20px;">
                            <div class="progress-bar ${progressBarClass}" role="progressbar" 
                                style="width: ${deviceUsage}%;" 
                                aria-valuenow="${license.activeDevices}" 
                                aria-valuemin="0" 
                                aria-valuemax="${license.maxDevices}">
                                ${license.activeDevices}/${license.maxDevices}
                            </div>
                        </div>
                    `;
                    
                    // 構建操作按鈕
                    const toggleBtnClass = license.active ? 'btn-outline-warning' : 'btn-outline-success';
                    const toggleBtnIcon = license.active ? 'fa-ban' : 'fa-check-circle';
                    const toggleBtnText = license.active ? '禁用' : '啟用';
                    
                    row.innerHTML = `
                        <td><code>${key}</code></td>
                        <td>${license.customer_name}</td>
                        <td>${getLicenseTypeName(license.type)}</td>
                        <td>${statusBadge.outerHTML}</td>
                        <td>${license.expiry ? new Date(license.expiry).toLocaleDateString() : '永久'}</td>
                        <td>${progressBar}</td>
                        <td>
                            <div class="btn-group btn-group-sm" role="group">
                                <button class="btn btn-outline-primary" onclick="showDeviceManagement('${key}', '${license.customer_name}', '${license.type}', ${license.active})">
                                    <i class="fas fa-laptop me-1"></i> 管理裝置
                                </button>
                                <button class="btn ${toggleBtnClass}" onclick="toggleLicenseStatus('${key}', ${!license.active})">
                                    <i class="fas ${toggleBtnIcon} me-1"></i> ${toggleBtnText}
                                </button>
                            </div>
                        </td>
                    `;
                    
                    licensesTable.appendChild(row);
                }
            }
            
            // 更新儀表板統計數字
            document.getElementById('total-licenses').textContent = totalLicenses;
            document.getElementById('active-licenses').textContent = activeLicenses;
            document.getElementById('inactive-licenses').textContent = totalLicenses - activeLicenses;
            
        } else {
            Swal.fire({
                icon: 'error',
                title: '載入失敗',
                text: data.message || '無法載入許可證列表'
            });
        }
    })
    .catch(error => {
        console.error('載入許可證列表時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '連接錯誤',
            text: '無法連接到伺服器，請檢查您的網絡連接'
        });
    });
}

// 儲存許可證處理
function saveLicense() {
    const customerName = document.getElementById('customer-name').value;
    const licenseType = document.getElementById('license-type').value;
    const expiryDate = document.getElementById('expiry-date').value;
    
    // 驗證輸入
    if (!customerName.trim()) {
        Swal.fire({
            icon: 'warning',
            title: '缺少資料',
            text: '請輸入客戶名稱'
        });
        return;
    }
    
    // 顯示載入狀態
    document.getElementById('save-license-btn').innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>儲存中...';
    document.getElementById('save-license-btn').disabled = true;
    document.getElementById('cancel-license-btn').disabled = true;
    
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
            Swal.fire({
                icon: 'success',
                title: '創建成功',
                text: `許可證金鑰: ${data.license_key}`,
                confirmButtonText: '複製金鑰',
                showCancelButton: true,
                cancelButtonText: '確定'
            }).then((result) => {
                if (result.isConfirmed) {
                    navigator.clipboard.writeText(data.license_key)
                        .then(() => {
                            Swal.fire({
                                icon: 'success',
                                title: '已複製!',
                                text: '許可證金鑰已複製到剪貼板',
                                timer: 1500,
                                showConfirmButton: false
                            });
                        })
                        .catch(err => {
                            console.error('無法複製: ', err);
                        });
                }
                showManagementInterface();
                loadLicenses();
            });
        } else {
            Swal.fire({
                icon: 'error',
                title: '創建失敗',
                text: data.message || '無法創建許可證'
            });
        }
        document.getElementById('save-license-btn').innerHTML = '<i class="fas fa-save me-2"></i>儲存';
        document.getElementById('save-license-btn').disabled = false;
        document.getElementById('cancel-license-btn').disabled = false;
    })
    .catch(error => {
        console.error('創建許可證時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '伺服器錯誤',
            text: '無法連接到伺服器，請稍後再試'
        });
        document.getElementById('save-license-btn').innerHTML = '<i class="fas fa-save me-2"></i>儲存';
        document.getElementById('save-license-btn').disabled = false;
        document.getElementById('cancel-license-btn').disabled = false;
    });
}

// 切換許可證狀態
function toggleLicenseStatus(licenseKey, active) {
    Swal.fire({
        title: `確定要${active ? '啟用' : '禁用'}此許可證嗎？`,
        text: active ? "啟用後客戶將可以使用此許可證" : "禁用後客戶將無法使用此許可證",
        icon: 'warning',
        showCancelButton: true,
        confirmButtonColor: active ? '#28a745' : '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: active ? '是，啟用它' : '是，禁用它',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            fetch(`/api/admin/licenses/${licenseKey}`, {
                method: 'PATCH',
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
                    Swal.fire({
                        icon: 'success',
                        title: '更新成功',
                        text: `許可證已${active ? '啟用' : '禁用'}`,
                        timer: 1500,
                        showConfirmButton: false
                    }).then(() => {
                        loadLicenses();
                    });
                } else {
                    Swal.fire({
                        icon: 'error',
                        title: '更新失敗',
                        text: data.message || '無法更新許可證狀態'
                    });
                }
            })
            .catch(error => {
                console.error('更新許可證狀態時出錯:', error);
                Swal.fire({
                    icon: 'error',
                    title: '伺服器錯誤',
                    text: '無法連接到伺服器，請稍後再試'
                });
            });
        }
    });
}

// 獲取許可證類型名稱
function getLicenseTypeName(type) {
    const typeNames = {
        'standard': '標準版',
        'premium': '高級版',
        'unlimited': '無限版'
    };
    return typeNames[type] || type;
}