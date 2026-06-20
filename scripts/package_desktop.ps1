<#
打包桌面端 Windows 发布包：
  1. 复制 Flutter Windows release 产物到 dist/ide-claw-windows/
  2. 把 scripts/desktop-installer/* 一起放进去（setup-cascade.bat、requirements.txt、README.txt）
  3. 压成 dist/ide-claw-windows.zip
  4. （可选）-Upload 时上传到服务器

用法：
  pwsh scripts/package_desktop.ps1                # 仅本地打包
  pwsh scripts/package_desktop.ps1 -Upload        # 打包 + 上传到 push.shoot-game.cn
#>

param(
  [switch]$Upload,
  [string]$Server = 'push.shoot-game.cn'
)

$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$src     = Join-Path $repo 'app\build\windows\x64\runner\Release'
$extras  = Join-Path $repo 'scripts\desktop-installer'
$dist    = Join-Path $repo 'dist\ide-claw-windows'
$zip     = Join-Path $repo 'dist\ide-claw-windows.zip'

if (-not (Test-Path $src)) {
  Write-Error "Flutter Windows release 产物不存在: $src`n请先在 app/ 目录跑: flutter build windows --release"
  exit 1
}
if (-not (Test-Path $extras)) {
  Write-Error "未找到 desktop-installer 目录: $extras"
  exit 1
}

Write-Host "[1/4] 重置 dist 目录: $dist"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

Write-Host "[2/4] 复制 Flutter release 产物"
Copy-Item -Path "$src\*" -Destination $dist -Recurse -Force

Write-Host "[3/4] 复制 desktop-installer 文件"
Copy-Item -Path "$extras\*" -Destination $dist -Recurse -Force

$count = (Get-ChildItem $dist -Recurse -File | Measure-Object).Count
Write-Host "      dist 目录文件数: $count"
Get-ChildItem $dist -File | Select-Object Name, @{N='KB';E={[math]::Round($_.Length/1KB,1)}} | Format-Table | Out-String | Write-Host

Write-Host "[4/4] 压缩为 zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$dist\*" -DestinationPath $zip -CompressionLevel Optimal
$zipMB = [math]::Round((Get-Item $zip).Length / 1MB, 2)
Write-Host "      $zip ($zipMB MB)"

if ($Upload) {
  Write-Host ""
  Write-Host "[upload] scp -> $Server"
  scp $zip "root@${Server}:/var/www/push-server/data/uploads/ide-claw-windows.zip"
  if ($LASTEXITCODE -ne 0) { Write-Error "scp 失败"; exit 1 }
  Write-Host "[upload] 验证 HTTP 可达"
  ssh "root@$Server" "curl -fsSI https://$Server/dl/ide-claw-windows.zip | head -3"
}

Write-Host ""
Write-Host "[OK] 打包完成"
