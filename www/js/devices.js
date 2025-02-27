// 顯示裝置管理界面
function showDeviceManagement(licenseKey, customerName, licenseType, licenseStatus) {
    currentLicenseKey = licenseKey;
    document.getElementById('main-navbar').classList.remove('hidden');
    document.getElementById('login-section').classList.add('hidden');
    document.getElementById('management-section').classList.add('hidden');
    document.getElementById('create-license-form').classList.add('hidden');
    document.getElementById('device-management').classList.remove('hidden');
    
    // 填充許可證詳情
    document.getElementById('detail-license-key').textContent = licenseKey;
    document.getElementById('detail-customer-name').textContent = customerName;
    document.getElementById('detail-license-type').textContent = getLicenseTypeName(licenseType);
    
    const statusBadge = document.createElement('span');
    statusBadge.className = licenseStatus ? 'badge bg-success' : 'badge bg-danger';
    statusBadge.textContent = licenseStatus ? '啟用' : '禁用';
    document.getElementById('detail-license-status').innerHTML = '';
    document.getElementById('detail-license-status').appendChild(statusBadge);
    
    loadDevices(licenseKey);
}

// 載入裝置列表
function loadDevices(licenseKey) {
    document.getElementById('devices-body').innerHTML = '<tr><td colspan="8" class="text-center"><div class="spinner-border spinner-border-sm text-primary me-2"></div>載入中...</td></tr>';
    
    fetch(`/api/admin/licenses/${licenseKey}`, {
        headers: {
            'Authorization': `Bearer ${authToken}`
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.status === 'success') {
            const devices = data.license.devices || {};
            const devicesTable = document.getElementById('devices-body');
            devicesTable.innerHTML = '';
            
            if (Object.keys(devices).length === 0) {
                devicesTable.innerHTML = '<tr><td colspan="8" class="text-center">尚無已註冊裝置</td></tr>';
            } else {
                for (const [deviceId, device] of Object.entries(devices)) {
                    const row = document.createElement('tr');
                    
                    // 設置裝置狀態樣式
                    const statusClass = device.active ? 'device-status-active' : 'device-status-inactive';
                    const statusIcon = device.active ? 'fa-check-circle' : 'fa-ban';
                    const statusText = device.active ? '啟用' : '禁用';
                    
                    // 構建地理位置信息
                    let locationInfo = device.location ? `${device.location.city || ''}, ${device.location.country || ''}` : '未知';
                    if (locationInfo === ', ') locationInfo = '未知';
                    
                    // 構建操作按鈕
                    const toggleBtnClass = device.active ? 'btn-outline-warning' : 'btn-outline-success';
                    const toggleBtnIcon = device.active ? 'fa-ban' : 'fa-check-circle';
                    const toggleBtnText = device.active ? '禁用' : '啟用';
                    
                    row.innerHTML = `
                        <td><code>${deviceId.substring(0, 8)}...</code></td>
                        <td>${device.server_name || '未知'}</td>
                        <td>${device.server_ip || '未知'}</td>
                        <td>${device.os || '未知'}</td>
                        <td>${locationInfo}</td>
                        <td>${device.last_login ? new Date(device.last_login).toLocaleString() : '未知'}</td>
                        <td><i class="fas ${statusIcon} ${statusClass}"></i> ${statusText}</td>
                        <td>
                            <div class="btn-group btn-group-sm" role="group">
                                <button class="btn ${toggleBtnClass}" onclick="toggleDeviceStatus('${licenseKey}', '${deviceId}', ${!device.active})">
                                    <i class="fas ${toggleBtnIcon}"></i> ${toggleBtnText}
                                </button>
                                <button class="btn btn-outline-danger" onclick="deleteDevice('${licenseKey}', '${deviceId}')">
                                    <i class="fas fa-trash-alt"></i> 刪除
                                </button>
                            </div>
                        </td>
                    `;
                    
                    devicesTable.appendChild(row);
                }
            }
        } else {
            Swal.fire({
                icon: 'error',
                title: '載入失敗',
                text: data.message || '無法載入裝置列表'
            });
        }
    })
    .catch(error => {
        console.error('載入裝置列表時出錯:', error);
        Swal.fire({
            icon: 'error',
            title: '連接錯誤',
            text: '無法連接到伺服器，請檢查您的網絡連接'
        });
    });
}

// 切換裝置狀態
function toggleDeviceStatus(licenseKey, deviceId, active) {
    Swal.fire({
        title: `確定要${active ? '啟用' : '禁用'}此裝置嗎？`,
        text: active ? "啟用後將允許裝置使用授權" : "禁用後將阻止裝置使用授權",
        icon: 'warning',
        showCancelButton: true,
        confirmButtonColor: active ? '#28a745' : '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: active ? '是，啟用它' : '是，禁用它',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            fetch(`/api/admin/licenses/${licenseKey}/devices/${deviceId}`, {
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
                        text: `裝置已${active ? '啟用' : '禁用'}`,
                        timer: 1500,
                        showConfirmButton: false
                    }).then(() => {
                        loadDevices(licenseKey);
                    });
                } else {
                    Swal.fire({
                        icon: 'error',
                        title: '更新失敗',
                        text: data.message || '無法更新裝置狀態'
                    });
                }
            })
            .catch(error => {
                console.error('更新裝置狀態時出錯:', error);
                Swal.fire({
                    icon: 'error',
                    title: '伺服器錯誤',
                    text: '無法連接到伺服器，請稍後再試'
                });
            });
        }
    });
}

// 刪除裝置
function deleteDevice(licenseKey, deviceId) {
    Swal.fire({
        title: '確定要刪除這個裝置嗎？',
        text: "此操作無法撤銷！",
        icon: 'warning',
        showCancelButton: true,
        confirmButtonColor: '#dc3545',
        cancelButtonColor: '#6c757d',
        confirmButtonText: '是，刪除它',
        cancelButtonText: '取消'
    }).then((result) => {
        if (result.isConfirmed) {
            fetch(`/api/admin/licenses/${licenseKey}/devices/${deviceId}`, {
                method: 'DELETE',
                headers: {
                    'Authorization': `Bearer ${authToken}`
                }
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    Swal.fire({
                        icon: 'success',
                        title: '刪除成功',
                        text: '裝置已從數據庫中刪除',
                        timer: 1500,
                        showConfirmButton: false
                    }).then(() => {
                        loadDevices(licenseKey);
                    });
                } else {
                    Swal.fire({
                        icon: 'error',
                        title: '刪除失敗',
                        text: data.message || '無法刪除裝置'
                    });
                }
            })
            .catch(error => {
                console.error('刪除裝置時出錯:', error);
                Swal.fire({
                    icon: 'error',
                    title: '伺服器錯誤',
                    text: '無法連接到伺服器，請稍後再試'
                });
            });
        }
    });
}

// 重設所有裝置
function resetAllDevices() {
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
                    Swal.fire({
                        icon: 'error',
                        title: '重設失敗',
                        text: data.message || '無法重設裝置'
                    });
                }
            })
            .catch(error => {
                console.error('重設裝置時出錯:', error);
                Swal.fire({
                    icon: 'error',
                    title: '伺服器錯誤',
                    text: '無法連接到伺服器，請稍後再試'
                });
            });
        }
    });
}