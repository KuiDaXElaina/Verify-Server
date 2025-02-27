let licenseTypes = {
    'standard': '標準版',
    'premium': '高級版',
    'unlimited': '無限版'
};

// 載入許可證列表
function loadLicenses() {
    fetch('/api/admin/licenses', {
        method: 'GET',
        headers: {
            'Authorization': `Bearer ${authToken}`
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            updateDashboardSummary(data.licenses);
            renderLicensesTable(data.licenses);
        } else {
            throw new Error(data.message || '無法載入許可證');
        }
    })
    .catch(error => {
        console.error('載入許可證時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '載入失敗',
            text: '無法載入許可證列表，請稍後再試'
        });
    });
}

// 更新儀表板摘要
function updateDashboardSummary(licenses) {
    const totalLicenses = licenses.length;
    const activeLicenses = licenses.filter(license => license.active).length;
    const totalDevices = licenses.reduce((sum, license) => sum + (license.devices?.length || 0), 0);

    document.getElementById('total-licenses').textContent = totalLicenses;
    document.getElementById('active-licenses').textContent = activeLicenses;
    document.getElementById('total-devices').textContent = totalDevices;
}

// 渲染許可證表格
function renderLicensesTable(licenses) {
    const tbody = document.getElementById('licenses-table-body');
    if (!tbody) return;

    tbody.innerHTML = '';
    licenses.forEach(license => {
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${license.key}</td>
            <td>${license.customer_name}</td>
            <td>${licenseTypes[license.type] || license.type}</td>
            <td>${license.expiry ? new Date(license.expiry).toLocaleDateString() : '永久'}</td>
            <td>${license.devices?.length || 0}</td>
            <td>
                <span class="badge ${license.active ? 'bg-success' : 'bg-danger'}">
                    ${license.active ? '啟用' : '禁用'}
                </span>
            </td>
            <td>
                <div class="btn-group">
                    <button class="btn btn-sm btn-outline-primary" onclick="showDeviceManagement('${license.key}', '${license.customer_name}', '${license.type}', ${license.active})">
                        <i class="fas fa-desktop"></i>
                    </button>
                    <button class="btn btn-sm ${license.active ? 'btn-outline-danger' : 'btn-outline-success'}" onclick="toggleLicenseStatus('${license.key}', ${!license.active})">
                        <i class="fas fa-${license.active ? 'ban' : 'check'}"></i>
                    </button>
                </div>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// 儲存許可證
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
    .then(data => handleLicenseSaveResponse(data))
    .catch(error => handleLicenseSaveError(error));
}

// 處理許可證保存回應
function handleLicenseSaveResponse(data) {
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
    resetLicenseFormButtons();
}

// 處理許可證保存錯誤
function handleLicenseSaveError(error) {
    console.error('創建許可證時出錯:', error);
    Swal.fire({
        icon: 'error',
        title: '伺服器錯誤',
        text: '無法連接到伺服器，請稍後再試'
    });
    resetLicenseFormButtons();
}

// 重置許可證表單按鈕
function resetLicenseFormButtons() {
    document.getElementById('save-license-btn').innerHTML = '<i class="fas fa-save me-2"></i>儲存';
    document.getElementById('save-license-btn').disabled = false;
    document.getElementById('cancel-license-btn').disabled = false;
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
            updateLicenseStatus(licenseKey, active);
        }
    });
}

// 更新許可證狀態
function updateLicenseStatus(licenseKey, active) {
    fetch(`/api/admin/licenses/${licenseKey}/status`, {
        method: 'PUT',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${authToken}`
        },
        body: JSON.stringify({ active })
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
            throw new Error(data.message || '更新失敗');
        }
    })
    .catch(error => {
        console.error('更新許可證狀態時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '更新失敗',
            text: '無法更新許可證狀態，請稍後再試'
        });
    });
}