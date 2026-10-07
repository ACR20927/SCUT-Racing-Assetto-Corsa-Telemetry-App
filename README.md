# 安装与使用

把完整 `CarDataRecorder` 文件夹复制到 AC 游戏根目录的 `apps/lua`，需要 CSP。发送端使用 EF26 的 `VehicleTelemetry` 协议；插件中的 `telemetry_channels.lua` 必须与模组发送端的同名文件一致。

进入赛道后打开插件，点击 Start Recording 开始录制；点击 Stop and Export CSV 停止，等状态显示 CSV READY 后再关闭游戏。

Windows 默认目录为 `C:\Users\<用户名>\Documents\Assetto Corsa`。如文档目录迁移至 OneDrive 或其他盘，跟随实际文档目录。文件为 `car_data_日期_时间.csv`；同名 `.journal.jsonl` 保留类型、来源、接收时刻和更新次数，可在插件 Recovery 页恢复。

# 数据列

CSV 保留原有车辆基础数据和电机控制数据，增加四轮车体三轴接地力、四轮轮胎侧偏角、配置质心侧偏角估计，以及四轮接地合力、关于该质心的合力矩。轮位统一为 FL/FR/RL/RR，字段名携带单位；默认共 54 列，具体定义见 `CarDataRecorder/telemetry_channels.lua` 和发送端 README。

主车体 X 为横向、Y 为向上、Z 为向前；三轴力矩依次为俯仰、偏航、侧倾。总量仅包含四轮接地作用，质心是静态配置估计点。质心平面速度低于 0.1 m/s 时侧偏角留空。

新字段会自动扩展列；字段删除或本采样没有收到新值时留空，真实零值保留。数据类型、接收时刻和次数保存在恢复日志，不再作为大量 Telemetry 诊断列显示。多个发送者分开记录。旧事件与旧恢复日志仍可读取，旧 CSV 不会被覆盖。

50 Hz 是受图形更新频率限制的目标采样率；`time_s` 是实际模拟采样时间。暂停、回放不录，不为错过的采样点补造行。CSV 为带会话说明、列名与单位行的 AiM 风格布局。

# 离线检查

在本仓库根目录执行，测试仅模拟 CSP 接口并将 CSV、恢复日志写入测试目录，不启动游戏：

```sh
nix-shell -p luajit lua51Packages.dkjson --run 'luajit CarDataRecorder/tests/recorder_spec.lua'
```

也可向测试脚本依次传入插件目录、测试输出目录、发送端源码目录。
