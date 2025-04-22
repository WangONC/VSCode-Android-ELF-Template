param (
    [string]$BinaryPath="",      # 二进制文件路径
    [string]$DeviceTarget="/data/local/tmp",    # 可选: 设备中目标二进制的路径和lldb-server的路径
    [string]$DeviceSerial="", # 可选: 特定设备序列号
    [switch]$Deploy,  # 是否部署
    [switch]$Run,  # 是否后运行
    [switch]$Root,        # 是否使用root运行
    [switch]$StartLldb,  # 是否开启lldb-server
    [switch]$StopLldb,   # 是否停止lldb-server
    [int]$LldbPort=28086  # LLDB 端口，默认28086
)

function Exit-WithError {
    param (
        [string]$Message,
        [int]$ExitCode = 1
    )
    Write-Error $Message
    exit $ExitCode
}

# 获取root权限并返回root方法
function Get-RootAccess {
    param (
        [string]$AdbCmd
    )
    
    $rootMethod = $null
    
    # 检查su命令是否可用
    $suCheck = Invoke-Expression "$AdbCmd shell 'which su'"
    if ($suCheck -and $suCheck -ne "" -and $LASTEXITCODE -eq 0) {
        Write-Host "Device has su binary available."
        $rootMethod = "su"
        return $rootMethod
    }
    
    # 尝试adb root
    Write-Host "Attempting to restart adb as root..."
    Invoke-Expression "$AdbCmd root"
    if ($LASTEXITCODE -eq 0) {
        # 等待adb重新连接
        Start-Sleep -Seconds 2
        
        # 验证adb是否真正以root运行
        $idCheck = Invoke-Expression "$AdbCmd shell id"
        if ($idCheck -match "uid=0\(root\)") {
            Write-Host "ADB restarted in root mode successfully."
            $rootMethod = "adb_root"
            return $rootMethod
        } else {
            Write-Host "ADB root command didn't grant root privileges."
            return $null
        }
    }
    
    # 如果两种方法都失败，返回null
    return $null
}

# 使用root权限执行命令
function Invoke-RootCommand {
    param (
        [string]$AdbCmd,
        [string]$RootMethod,
        [string]$Command
    )
    
    if ($RootMethod -eq "su") {
        # 使用su执行命令
        return Invoke-Expression "$AdbCmd shell `"su -c '$Command'`""
    } 
    elseif ($RootMethod -eq "adb_root") {
        # 直接执行命令(adb已经以root运行)
        return Invoke-Expression "$AdbCmd shell `"$Command`""
    }
    else {
        Exit-WithError "No root method available."
    }
}

# 停止LLDB服务器进程
function Stop-LldbServer {
    param (
        [string]$AdbCmd,
        [bool]$FailOnError = $true
    )
    
    # 检查lldb-server是否在运行
    $lldbRunning = Invoke-Expression "$AdbCmd shell 'ps | grep lldb-server | grep -v grep'"
    
    if ($lldbRunning) {
        Write-Host "Terminating lldb-server processes..."
        
        # 检查lldb-server进程是否属于root
        $isRootProcess = $lldbRunning -match "root"
        
        # 根据进程所有者选择合适的权限进行终止
        if ($isRootProcess) {
            Write-Host "LLDB server is running as root, using root privileges to stop it..."
            # 获取root权限
            $rootMethod = Get-RootAccess -AdbCmd $AdbCmd
            
            if (-not $rootMethod) {
                if ($FailOnError) {
                    Exit-WithError "Device does not have root access. Cannot stop root LLDB server."
                } else {
                    Write-Warning "Device does not have root access. Cannot stop root LLDB server."
                    return $false
                }
            }
            
            # 使用root权限终止进程
            $command = "killall lldb-server 2>/dev/null || true"
            Invoke-RootCommand -AdbCmd $AdbCmd -RootMethod $rootMethod -Command $command
        } else {
            # 普通权限终止进程
            Write-Host "Stopping LLDB server with normal privileges..."
            Invoke-Expression "$AdbCmd shell 'killall lldb-server 2>/dev/null || true'"
        }
        
        # 验证进程是否真的被终止
        Start-Sleep -Seconds 1
        $stillRunning = Invoke-Expression "$AdbCmd shell 'ps | grep lldb-server | grep -v grep'"
        if ($stillRunning) {
            if ($FailOnError) {
                Exit-WithError "Failed to stop lldb-server processes. Please restart your device or check permissions."
            } else {
                Write-Warning "Failed to stop lldb-server processes. Please restart your device or check permissions."
                return $false
            }
        } else {
            Write-Host "Successfully stopped lldb-server processes."
        }
    } else {
        Write-Host "No running lldb-server processes found."
    }
    
    return $true
}

# 停止端口转发
function Stop-Forword {
    param (
        [string]$AdbCmd,
        [int]$Port
    )

    # 检查目标端口是否已经在转发
    $portCheck = Invoke-Expression "$adbCmd forward --list" | Select-String "tcp:$Port tcp:"
    if ($portCheck) {
        # 端口转发存在，尝试移除
        Write-Host "Removing existing port forwarding..."
        Invoke-Expression "$adbCmd forward --remove tcp:$Port 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Exit-WithError "Failed to remove port forwarding." $LASTEXITCODE
        }
    } else {
        Write-Host "No existing port forwarding found for tcp:$Port."
    }
}

# 检查端口是否被占用
function Test-PortInUse {
    param (
        [string]$AdbCmd,
        [int]$Port
    )
    
    # 在设备上检查端口是否被占用
    $netstatOutput = Invoke-Expression "$AdbCmd shell 'netstat -tunla'"
    $netstatCheck = Write-Output $netstatOutput | Select-String '(?<=\s(?:\[?[\da-fA-F:\.]+]?:|0\.0\.0\.0:))$Port(?=\s|$)'
    
    if ($netstatCheck) {
        # 端口被占用
        return $true
    }
    
    # 在主机上检查ADB转发的端口是否被占用
    $portCheck = $null
    
    # 使用正则表达式匹配本地端口
    $portCheck = Invoke-Expression 'netstat -ano | Select-String -Pattern "(?:TCP|UDP)\s+.*\b$Port\b(?=\s|$)"'
    
    return ($null -ne $portCheck -and $portCheck -ne "")
}

# 使用PowerShell后台作业非阻塞启动lldb-server
function Start-LldbServer {
    param (
        [string]$AdbCmd,
        [string]$DeviceTarget,
        [int]$Port,
        [bool]$UseRoot = $false
    )
    
    if ($UseRoot) {
        # 获取root权限
        $rootMethod = Get-RootAccess -AdbCmd $AdbCmd
        
        if (-not $rootMethod) {
            Exit-WithError "Device is not rooted. Cannot start lldb-server as root."
        }
        
        Write-Host "Starting lldb-server with root privileges..."
        if ($rootMethod -eq "su") {
            # 使用su运行lldb-server
            $command = "su -c 'cd $DeviceTarget && ./lldb-server platform --server --listen *:$Port > /dev/null 2>&1 &'"
            # 使用PowerShell后台作业启动
            $job = Start-Job -ScriptBlock { 
                param($cmd, $shellcmd)
                & cmd /c "$cmd shell `"$shellcmd`""
            } -ArgumentList $AdbCmd, $command
        } else {
            # 使用adb root运行
            $command = "cd $DeviceTarget && ./lldb-server platform --server --listen *:$Port > /dev/null 2>&1 &"
            # 使用PowerShell后台作业启动
            $job = Start-Job -ScriptBlock { 
                param($cmd, $shellcmd)
                & cmd /c "$cmd shell `"$shellcmd`""
            } -ArgumentList $AdbCmd, $command
        }
    } else {
        # 普通权限运行
        Write-Host "Starting lldb-server with normal privileges..."
        $command = "cd $DeviceTarget && ./lldb-server platform --server --listen *:$Port > /dev/null 2>&1 &"
        # 使用PowerShell后台作业启动
        $job = Start-Job -ScriptBlock { 
            param($cmd, $shellcmd)
            & cmd /c "$cmd shell `"$shellcmd`""
        } -ArgumentList $AdbCmd, $command
    }
    
    # 给lldb-server启动一点时间
    Start-Sleep -Seconds 1
        
    # 检查作业状态并清理
    if (Get-Job -Id $job.Id -ErrorAction SilentlyContinue) {
        Write-Host "Cleaning up background job..."
        Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
    }
}

# 检查adb是否可用
try {
    Invoke-Expression "adb version"
} catch {
    Exit-WithError "ADB not found in PATH. Please install Android SDK Platform Tools or add it to PATH."
}

if ($Deploy) {
    # 确保参数有效
    if (-not $BinaryPath -or $BinaryPath -eq "") {
        Exit-WithError "Missing binary file path!"
    }

    # 检查二进制文件是否存在
    if (-not (Test-Path $BinaryPath)) {
        Exit-WithError "Binary file does not exist: $BinaryPath"
        exit 1
    }
}


# 构建adb命令
$adbCmd = "adb"
if ($DeviceSerial) {
    $adbCmd = "adb -s $DeviceSerial"
}

# 检查设备连接状态
$deviceCheck = Invoke-Expression "$adbCmd devices" | Select-String "device$"
if (-not $deviceCheck) {
    if ($DeviceSerial) {
        Exit-WithError "Device with serial '$DeviceSerial' not found or not authorized."
    } else {
        Exit-WithError "No connected devices found. Please connect a device or start an emulator."
    }
}

# 检查是否连接了多个设备，但未指定设备序列号
if (-not $DeviceSerial) {
    $deviceCount = @(Invoke-Expression "adb devices" | Select-String "device$").Count
    if ($deviceCount -gt 1) {
        $devicesList = Invoke-Expression "adb devices" | Select-String "device$"
        $devicesInfo = "Connected devices:`n" + ($devicesList -join "`n")
        Exit-WithError "Multiple devices detected but no specific device specified. Please use the -DeviceSerial parameter.`n$devicesInfo"
    }
}

if ($Deploy -or $Run) {
    # 提取文件名
    $fileName = Split-Path $BinaryPath -Leaf
}


if ($Deploy) {
    # 执行部署
    Write-Host "Deploying $fileName to device..."
    Invoke-Expression "$adbCmd push `"$BinaryPath`" `"$DeviceTarget/$fileName`""

    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Deployment failed! Check if target directory is writable." $LASTEXITCODE
    }

    # 设置执行权限
    Write-Host "Setting execution permissions..."
    Invoke-Expression "$adbCmd shell chmod 755 `"$DeviceTarget/$fileName`""
    
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Failed to set execution permissions." $LASTEXITCODE
    }
}

# 是否需要运行
if ($Run) {
    Write-Host "Running application on device..."
    
    if ($Root) {
        # 获取root权限
        $rootMethod = Get-RootAccess -AdbCmd $adbCmd
        
        if (-not $rootMethod) {
            Exit-WithError "Device does not appear to be rooted. Cannot run as root."
        }
        
        Write-Host "Running with root privileges..."
        $command = "cd $DeviceTarget && ./$fileName"
        Invoke-RootCommand -AdbCmd $adbCmd -RootMethod $rootMethod -Command $command
    } else {
        Write-Host "Running with normal privileges..."
        Invoke-Expression "$adbCmd shell `"cd $DeviceTarget && ./$fileName`""
    }
    
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Application execution failed with exit code $LASTEXITCODE." $LASTEXITCODE
    }
}

# 开启lldb-server
if ($StartLldb) {
    Write-Host "Setting up LLDB server..."
    
    # 检查设备上是否存在lldb服务器
    $lldbPath = "$DeviceTarget/lldb-server"
    $lldbCheck = Invoke-Expression "$adbCmd shell 'ls $lldbPath 2>/dev/null'"
    $lldbExists = ($LASTEXITCODE -eq 0)

    if (-not $lldbExists) {
        Exit-WithError "lldb-server not found at $lldbPath on device. Please push it first."
    }

    # 移除端口转发
    Stop-Forword -AdbCmd $adbCmd -Port $LldbPort

    # 检查设备上端口是否被占用
    Write-Host "Checking if port $LldbPort is available on device..."
    $devicePortInUse = Test-PortInUse -AdbCmd $adbCmd -Port $LldbPort

    if ($devicePortInUse) {
        Exit-WithError "Port $LldbPort is already in use on the device. Cannot start lldb-server. Please choose a different port or stop the process using this port."
    }
    
    # 设置端口转发
    Write-Host "Setting up port forwarding from localhost:$LldbPort to device:$LldbPort..."
    Invoke-Expression "$adbCmd forward tcp:$LldbPort tcp:$LldbPort"
    
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Failed to set up port forwarding." $LASTEXITCODE
    }
    
    # 使用非阻塞方式启动lldb-server
    Start-LldbServer -AdbCmd $adbCmd -DeviceTarget $DeviceTarget -Port $LldbPort -UseRoot $Root
    
    # 检查lldb-server是否成功启动
    Start-Sleep -Seconds 1
    $lldbRunning = Invoke-Expression "$adbCmd shell 'ps | grep lldb-server | grep -v grep'"
    
    if (-not $lldbRunning) {
        Exit-WithError "lldb-server failed to start properly."
    }
    
    Write-Host "LLDB server successfully started on port $LldbPort"
    Write-Host "Port forwarding established: localhost:$LldbPort -> device:$LldbPort"
    exit 0
}

if ($StopLldb) {
    Write-Host "Stopping LLDB server..."
    # 停止lldb-server进程
    Stop-LldbServer -AdbCmd $adbCmd

    # 移除端口转发
    Stop-Forword -AdbCmd $adbCmd -Port $LldbPort

    Write-Host "LLDB server successfully stopped."
    exit 0
}