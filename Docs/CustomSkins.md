# 自定义皮肤与本地词频

版本保持 1.0。主 App → 键盘设置 → 我的皮肤，支持创建、编辑、使用、删除和导入导出。也可在「文件」App 中打开 `.vimeskin` 文件交给 Vime。导入后先打开编辑预览，保存并在列表选择「使用」。编辑当前皮肤后，重新打开键盘即可刷新。

编辑器支持七种颜色、系统/圆体/手写字体、菱格图案、键帽透明度/圆角/阴影、照片背景和功能键/逐字母贴图。照片会在后台缩小到最长边 1024 像素；带透明度的 PNG 适合按键贴图。横竖屏和九宫格仍采用 Vime 自身布局，装饰不接收触控。皮肤跨 App 使用需允许键盘完全访问以读取共享容器；不可读取的皮肤回退到默认外观。

## 文件格式

`.vimeskin` 是 UTF-8 JSON，版本标识为 `vime.skin.v1`。PNG/JPEG 以 base64 嵌入 `images`，不加载 URL、执行脚本或解压 ZIP。通过 App 导出可得到完整模板，示例骨架：

```json
{
  "format": "vime.skin.v1",
  "id": "5E528BC6-6E22-4A15-B9D6-24C322CA80A4",
  "name": "奶油菱格",
  "author": "",
  "palette": {
    "background": "#F3EBDF", "pattern": "#E9DFD2",
    "key": "#FFFAF5", "utility": "#E9DFD2", "text": "#51370B",
    "accent": "#2474F5", "pressed": "#DCCABA"
  },
  "style": {
    "font": "handwritten", "pattern": "diamonds", "keyOpacity": 0,
    "cornerRadius": 8, "shadowOpacity": 0
  },
  "images": {},
  "keyImages": {}
}
```

`backgroundImage` 可选，指向 `images` 中的图片 ID。`keyImages` 将语义按键映射到图片 ID，支持 `letter.a`…`letter.z`、通用 `letter`、`shift`、`backspace`、`space`、`return`、`emoji`、`numbers`、`language`、`comma`、`symbols`、`prolonged`、`brand`（左上角设置）。单字母图片优先于通用字母图片；未设置的按键保留正常字符/图标。输入或宿主改变回车含义时仍显示正确操作文字。

文件限 8 MB、最多 40 张图片/64 个映射；单张 PNG/JPEG ≤2 MB、长宽 ≤2048；总像素 ≤500 万，最多保存 30 个皮肤。导入会生成新的 UUID，避免覆盖已有皮肤。图片只在更换皮肤或设置修订变化时解码并缓存，不进入按键输入主路径。

参考图皮肤是本机单独交付的文件，位于 Git 忽略的 `Artifacts/Skins`，未加入 App 内置资源。

## 词频与模型排序

azooKey 已有真实候选确认 → 学习 → 持久化链路。原神经重排仅比较模型概率，会盖过学习的顺序；原下一词建议也没有记录点选行为。本次继续使用 azooKey 学习，并新增小规模本地选择记忆，为最终神经/经典排序补充它们不能直接读取的词频证据。

当前转换记忆同时记录 reading + surface 的全局证据，以及前文末尾 12 字/4 字的 SHA256 上下文桶。一次选择可以带来短暂会话加分；长期记忆要求重复确认，累计有效频次按 30 天半衰期衰减，更新前先衰减旧证据。下一词最多召回 3 条历史短语，经真实 LM 分数验证后与生成结果统一排序，共展示最多 5 项。评分上限为 3 个 log-probability 单位，强模型证据仍能胜出。

记忆最多 2048 条，存于 azooKey 学习目录中的 `VimeSelectionFrequency.json`，旧格式自动迁移。生产确认先等待宿主文本保留；短时间删除、光标/字段变化或缺失插入回执会撤回暂存反馈。接受反馈和生命周期边界在已有后台队列原子写盘，重建 converter 后继续有效。`clearLearning()` 同时清除两套学习。详见 [学习 Technical Report](PersonalizationLearningTechnicalReport.md)。

验证仅使用皮肤导入/尺寸校验、装饰不影响触控、重复选择/衰减/上下文隔离、converter 重建后的神经排序，以及原候选学习和下一词插入的定向检查；未重跑全量基准。

本轮结果：7 项不同的定向用例通过；真实 UIKit 皮肤预览已检查，并定向复核了字体居中和设置图标切换。重复选择测试中「箸」在神经重排后的索引由 1 提升至 0，converter 重建后仍有词频分数。App/键盘扩展 Debug 模拟器构建通过；没有重跑全量准确率、性能或真机基准。

文字避让修订：按实际可见字形边界保留标签空间，宽功能键采用图文并排；紧凑高度优先展示操作文字。皮肤字体和原字号保留（440pt 宽度下字母 18pt、底部功能键 16.5pt），不再按字体行距缩小文字。普通/紧凑高度下的换行、发送、确认、下一项和空格转换标签，以及实际皮肤渲染共两项定向检查通过。
