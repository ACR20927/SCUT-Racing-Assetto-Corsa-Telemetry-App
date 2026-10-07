# 安装与使用

把完整 `CarDataRecorder` 文件夹复制到 AC 游戏根目录的 `apps/lua`，需要 CSP。发送端使用 EF26 的 `VehicleTelemetry` 协议；插件中的 `telemetry_channels.lua` 必须与模组发送端的同名文件一致。

进入赛道后打开插件，点击 Start Recording 开始录制；点击 Stop and Export CSV 停止，等状态显示 CSV READY 后再关闭游戏。

Windows 默认目录为 `C:\Users\<用户名>\Documents\Assetto Corsa`。如文档目录迁移至 OneDrive 或其他盘，跟随实际文档目录。文件为 `car_data_日期_时间.csv`；同名 `.journal.jsonl` 保留类型、来源、接收时刻和更新次数，可在插件 Recovery 页恢复。

# 数据列

CSV 保留原有车辆基础数据和电机控制数据，增加四轮车体三轴接地力、四轮轮胎侧偏角、配置质心侧偏角估计，以及四轮接地合力、关于该质心的合力矩。轮位统一为 FL/FR/RL/RR，字段名携带单位；默认共 54 列，具体定义见 `CarDataRecorder/telemetry_channels.lua` 和发送端 README。

主车体采用右手系：X 向前、Y 向左、Z 向上。三轴力矩依次为侧倾、俯仰、偏航；俯视时角度、横摆角速度和转向的逆时针方向为正。总量仅包含四轮接地作用，质心是静态配置估计点。

轮胎纵向力沿车轮滚动前向为正，数值为 `-AC raw fx`；轮胎侧向力沿接地点左切向为正，数值为 `AC raw fy`。每轮车体三轴力由同一接地力投影得到，并非把车轮局部纵向、侧向力直接当作车体 X、Y 分量。

轮胎侧偏角为 `-AC solver slipAngle`，保留求解器的低速松弛和倒车定义，不是完整范围的速度方向角。配置质心侧偏角为 `atan2(v_y, v_x)`；这里的速度已采用前 X、左 Y、上 Z 的车体系，平面速度低于 0.1 m/s 时留空。

`acceleration_body_x_g/y_g/z_g` 分别为前向、左向、上向加速度。`position_ac_world_x_m/y_m/z_m` 保留 AC 固定赛道世界坐标，随车身转向不会换轴或翻号。电机转矩、实际与目标横摆角速度、转向值保留原有物理含义和符号。

新字段会自动扩展列；字段删除或本采样没有收到新值时留空，真实零值保留。数据类型、接收时刻和次数保存在恢复日志，不再作为大量 Telemetry 诊断列显示。多个发送者分开记录。坐标系和角度正向保存在日志头，不增加 CSV 数据列。旧事件与旧恢复日志仍可读取，旧 CSV 不会被覆盖；没有坐标系元数据的旧日志会明确注明坐标系及角度正向未指定，恢复时不推测、不转换，也不会误标为新的车体系。

50 Hz 是受图形更新频率限制的目标采样率；`time_s` 是实际模拟采样时间。暂停、回放不录，不为错过的采样点补造行。CSV 为带会话说明、列名与单位行的 AiM 风格布局。

# 离线检查

在本仓库根目录执行，测试仅模拟 CSP 接口并将 CSV、恢复日志写入测试目录，不启动游戏：

```sh
nix-shell -p luajit lua51Packages.dkjson --run 'luajit CarDataRecorder/tests/recorder_spec.lua'
```

也可向测试脚本依次传入插件目录、测试输出目录、发送端源码目录。
