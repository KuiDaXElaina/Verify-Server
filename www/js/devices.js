// 顯示裝置管理界面
function showDeviceManagement(licenseKey, customerName, licenseType, licenseStatus) {
    currentLicenseKey = licenseKey;
    
    // 更新麵包屑
    const breadcrumbCurrent = document.getElementById('breadcrumb-current');
    if (breadcrumbCurrent) {
        breadcrumbCurrent.textContent = `裝置管理 - ${customerName}`;
    }
    
    // 更新許可證資訊
    const licenseInfo = document.createElement('div');
    licenseInfo.innerHTML = `
        <h5>許可證資訊：</h5>
        <p>客戶名稱：${customerName}</p>
        <p>許可證類型：${licenseTypes[licenseType] || licenseType}</p>
        <p>狀態：<span class="badge ${licenseStatus ? 'bg-success' : 'bg-danger'}">${licenseStatus ? '啟用' : '禁用'}</span></p>
    `;
    
    // 切換介面顯示
    const elements = {
        'main-navbar': false,
        'management-section': true,
        'device-management': false
    };

    Object.entries(elements).forEach(([id, shouldHide]) => {
        const element = document.getElementById(id);
        if (element) {
            element.classList[shouldHide ? 'add' : 'remove']('hidden');
        }
    });

    // 載入裝置列表
    loadDevices(licenseKey);
}

// 載入裝置列表
function loadDevices(licenseKey) {
    fetch(`/api/admin/licenses/${licenseKey}/devices`, {
        headers: {
            'Authorization': `Bearer ${authToken}`
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            renderDevicesTable(data.devices);
        } else {
            throw new Error(data.message || '無法載入裝置列表');
        }
    })
    .catch(error => {
        console.error('載入裝置列表時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '載入失敗',
            text: '無法載入裝置列表，請稍後再試'
        });
    });
}

// 渲染裝置表格
function renderDevicesTable(devices) {
    const tbody = document.getElementById('devices-body');
    if (!tbody) return;

    tbody.innerHTML = '';
    devices.forEach(device => {
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${device.id}</td>
            <td>${device.server_name || '未知'}</td>
            <td>${device.ip_address || '未知'}</td>
            <td>${device.os || '未知'}</td>
            <td>${device.location || '未知'}</td>
            <td>${new Date(device.last_login).toLocaleString()}</td>
            <td>
                <span class="badge ${device.active ? 'bg-success' : 'bg-danger'}">
                    ${device.active ? '啟用' : '禁用'}
                </span>
            </td>
            <td>
                <button class="btn btn-sm ${device.active ? 'btn-outline-danger' : 'btn-outline-success'}"
                        onclick="toggleDeviceStatus('${currentLicenseKey}', '${device.id}', ${!device.active})">
                    <i class="fas fa-${device.active ? 'ban' : 'check'}"></i>
                </button>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// 切換裝置狀態
function toggleDeviceStatus(licenseKey, deviceId, active) {
    Swal.fire({
        title: `確定要${active ? '啟用' : '禁用'}此裝置嗎？`,
        text: active ? "啟用後此裝置將可以使用許可證" : "禁用後此裝置將無法使用許可證",
        icon: 'warning',
        showCancelButton: true,
        confirmButtonColor: active ? '#28a745' : '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: active ? '是，啟用它' : '是，禁用它',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            updateDeviceStatus(licenseKey, deviceId, active);
        }
    });
}

// 更新裝置狀態
function updateDeviceStatus(licenseKey, deviceId, active) {
    fetch(`/api/admin/licenses/${licenseKey}/devices/${deviceId}/status`, {
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
                text: `裝置已${active ? '啟用' : '禁用'}`,
                timer: 1500,
                showConfirmButton: false
            }).then(() => {
                loadDevices(licenseKey);
            });
        } else {
            throw new Error(data.message || '更新失敗');
        }
    })
    .catch(error => {
        console.error('更新裝置狀態時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '更新失敗',
            text: '無法更新裝置狀態，請稍後再試'
        });
    });
}

// 重設所有裝置
function resetAllDevices() {
    if (!currentLicenseKey) {
        console.error('未設置當前許可證金鑰');
        return;
    }

    Swal.fire({
        title: '確定要重設所有裝置嗎？',
        text: "這將刪除此許可證下的所有註冊裝置，此操作無法撤銷！",
        icon: 'warning',
        showCancelButton: true,
        confirmButtonColor: '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: '是，重設所有裝置',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            performDevicesReset();
        }
    });
}

// 執行裝置重設
function performDevicesReset() {
    fetch(`/api/admin/licenses/${currentLicenseKey}/devices/reset`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${authToken}`
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            Swal.fire({
                icon: 'success',
                title: '重設成功',
                text: '所有裝置已從數據庫中刪除',
                timer: 1500,
                showConfirmButton: false
            }).then(() => {
                loadDevices(currentLicenseKey);
            });
        } else {
            throw new Error(data.message || '重設失敗');
        }
    })
    .catch(error => {
        console.error('重設裝置時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '重設失敗',
            text: '無法重設裝置，請稍後再試'
        });
    });
}