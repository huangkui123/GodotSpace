# 任务 1.5：PICO 与 Unity 3 TagTracking 真机验收

此项需要同一台 PICO、同一物理机柜、Unity 基线工程和 Godot 三端联机环境，不能由 headless 自检替代。

## 基线来源

Unity 对照实现为：

`SpaceProject/Assets/ARSpace/Scripts/TagTrackingController.cs`

需要分别记录 `OriginTagTracking`、`TagTracking2 + TagTracking2Offset` 和 `TagTracking3 + TagTracking3Offset` 的最终水平位置/朝向。Unity 中第二、第三 Tag 使用不同轴向和偏移公式，因此不能只比较一个 Tag。

## 测试步骤

1. 在机柜周围固定 5 个以上检查点，至少覆盖近端、远端、左、右和中间位置；标记不可在 Unity/Godot 两次运行间移动。
2. 使用 Unity 基线依次完成 3 个 Tag 的跟踪，在每个检查点静止 3 s，记录稳定后的机柜原点、HMD、批注点和窗口中心位置/水平朝向。
3. 完全退出 Unity，保持 PICO guardian/物理标记不变，启动 Godot PC Server、Ground VR 和 Astronaut 三端。
4. 在 Godot 完成标定并确认至少 3 个空间点；到相同检查点记录同一组对象。
5. 计算每个检查点的位置欧氏误差和水平朝向最小夹角，并汇总 RMS/最大值。
6. 断开再连接两个 Client，确认机柜、玩家、批注和窗口没有二次偏移。
7. 执行 clear → recalibrate，再重复第 4–6 步，确认 revision 更新且旧点全部消失。
8. 遮挡头显跟踪超过 15 s，确认出现恢复提示；恢复跟踪后应自动重定中，也可用 `R`/菜单键手动重试。

## 通过标准

- 位置 RMS ≤ 0.05 m，最大误差 ≤ 0.10 m。
- 水平朝向 RMS ≤ 3°，最大误差 ≤ 5°。
- late join、断线重连及重复快照均不产生二次偏移。
- clear/recalibrate 后三端只显示新 revision 的预览点和确认点。
- 机柜、玩家、批注和窗口在三端的相对关系一致。

结果需附设备型号、PICO OS/OpenXR 版本、Unity/Godot commit、检查点原始记录和失败截图。当前仓库自动化只能验证合同、版本与快照幂等性；未连接真实 PICO 时，本项保持未验收。
