# 缓存迁移到D盘指南

## 为什么要迁移

C盘空间紧张时，各类应用缓存（临时文件、npm/yarn包、浏览器缓存、微信文件等）会持续消耗C盘空间。将缓存重定向到D盘后，新产生的缓存不再占C盘，从根源预防C盘爆满。

## 迁移清单

### 1. 系统临时文件 TEMP/TMP

```powershell
# 用户级环境变量（新开程序生效）
setx TEMP "D:\Cache\Temp"
setx TMP  "D:\Cache\Temp"
```

验证：

```powershell
[Environment]::GetEnvironmentVariable("TEMP","User")
[Environment]::GetEnvironmentVariable("TMP","User")
```

回滚：

```powershell
setx TEMP "%USERPROFILE%\AppData\Local\Temp"
setx TMP  "%USERPROFILE%\AppData\Local\Temp"
```

注意：当前已打开的程序仍用旧TEMP，重启或重开程序后生效。极少数软件对TEMP路径有特殊要求，如遇问题回滚即可。

### 2. npm 缓存

```powershell
npm config set cache "D:\Cache\npm"
```

验证：`npm config get cache`\ 回滚：`npm config delete cache`

### 3. Yarn 缓存

Yarn 1.x:

```powershell
yarn config set cache-folder "D:\Cache\yarn"
```

验证：`yarn config get cache-folder`\ 回滚：`yarn config delete cache-folder`

Yarn 2+/Berry：在项目 `.yarnrc.yml` 中加 `cacheFolder: "D:/Cache/yarn"`

### 4. Playwright 浏览器

```powershell
setx PLAYWRIGHT_BROWSERS_PATH "D:\Cache\ms-playwright"
```

之后 `npx playwright install` 会下载到D盘。\ 验证：`[Environment]::GetEnvironmentVariable("PLAYWRIGHT_BROWSERS_PATH","User")`\ 回滚：删除该环境变量（`[Environment]::SetEnvironmentVariable("PLAYWRIGHT_BROWSERS_PATH",$null,"User")`）

### 5. UV 缓存（Python包管理）

```powershell
setx UV_CACHE_DIR "D:\Tools\uv\cache"
```

验证：`[Environment]::GetEnvironmentVariable("UV_CACHE_DIR","User")`\ 回滚：删除该环境变量。

### 6. 浏览器缓存（可选，占位较小）

Edge/Chrome：快捷方式属性→目标，末尾加参数：

```
--disk-cache-dir="D:\Cache\browser"
```

注意：只改缓存目录，不改用户数据（书签/密码/历史记录仍在原位置）。

### 7. 微信/QQ 文件（个人数据，需在应用内设置）

- 微信：设置→文件管理→更改文件保存位置→选D盘目录→迁移历史文件

- QQ：设置→文件管理→更改目录

注意：这是个人文件（聊天接收的文档/图片/视频），不是缓存，迁移前建议备份。

### 8. WPS 缓存/文件

WPS：设置→配置工具→备份管理→更改备份位置；设置→缓存位置→改D盘。

### 9. 网易云音乐缓存

网易云音乐：设置→下载设置→缓存目录→改D盘。

## 验证迁移生效

环境变量类（TEMP/PLAYWRIGHT/UV）：设置后**重启或重开程序**，然后：

```powershell
# 查看当前进程实际生效值
echo $env:TEMP
echo $env:PLAYWRIGHT_BROWSERS_PATH
echo $env:UV_CACHE_DIR
```

npm/yarn类：立即生效，用 `npm config get cache` / `yarn config get cache-folder` 验证。

## 注意事项

1. 环境变量用 `setx` 设置的是**用户级**持久配置，写入注册表，重启后仍有效

2. `setx` 只影响**新开的进程**，当前已打开的终端/程序仍用旧值

3. 所有迁移操作可逆，回滚方法见上

4. 迁移前先在D盘创建对应目录（`D:\Cache\Temp`、`D:\Cache\npm` 等）

5. 个人文件类（微信/QQ/WPS）迁移前建议备份
