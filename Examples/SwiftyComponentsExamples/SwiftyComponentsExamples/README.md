# SwiftyComponentsExamples 结构（示例 App）

建议分层：
- Scenes/：页面与导航入口（例如组件目录页、波形演示页）。
- Components/：示例专用的小型可复用视图。
- ViewModels/：示例业务的 `ObservableObject` 与状态管理。
- Models/：示例数据模型与样本结构体。
- Utilities/：示例级别工具方法与扩展。
- Resources/：示例资源（Audio/、Images/ 等）。

说明：工程启用了“文件系统同步分组”，在该目录下新增文件/文件夹会自动出现在 Xcode 中。
