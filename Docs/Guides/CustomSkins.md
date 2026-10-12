# 自定义皮肤

主 App → 定制，支持创建、编辑、使用、删除、导入和导出。也可在「文件」App 中打开 `.vimeskin` 文件交给 Vime，导入后编辑预览，再保存并点选该皮肤。重新打开键盘后应用变更。

编辑器支持七种颜色、系统 / 圆体 / 手写字体、菱格图案、键帽透明度、圆角、阴影、照片背景以及功能键和逐字母贴图。照片缩小到最长边 1,024 像素；透明 PNG 适合按键装饰。装饰不改变按键命中或 ownership，操作文字仍应可读。

跨 App 读取自定义皮肤需要键盘完全访问以使用共享容器。皮肤不可读取时回退默认外观。

## 文件格式

`.vimeskin` 是 UTF-8 JSON，format 为 `vime.skin.v1`。PNG / JPEG 以 base64 嵌入 `images`，不使用远程 URL、脚本或 ZIP。通过 App 导出可得到完整模板；无图片的最小示例：

```json
{
  "format": "vime.skin.v1",
  "id": "5E528BC6-6E22-4A15-B9D6-24C322CA80A4",
  "name": "奶油菱格",
  "author": "",
  "palette": {
    "background": "#F3EBDF",
    "pattern": "#E9DFD2",
    "key": "#FFFAF5",
    "utility": "#E9DFD2",
    "text": "#51370B",
    "accent": "#2474F5",
    "pressed": "#DCCABA"
  },
  "style": {
    "font": "handwritten",
    "pattern": "diamonds",
    "keyOpacity": 0,
    "cornerRadius": 8,
    "shadowOpacity": 0
  },
  "images": {},
  "keyImages": {}
}
```

`backgroundImage` 可选，指向 `images` 中的图片 ID。`keyImages` 将语义按键映射到图片 ID，支持 `letter.a`…`letter.z`、通用 `letter`、`shift`、`backspace`、`space`、`return`、`emoji`、`numbers`、`language`、`comma`、`symbols`、`prolonged` 和左上角设置标志 `brand`。单字母图片优先于通用字母图片，未指定按键保留正常文字 / 图标；回车语义随宿主变化。

## 校验与存储

| 项目 | 限制 |
| --- | --- |
| 文件 | 不超过 8 MiB，合法 UUID，名称 1–60 字符 |
| 图片数量 / 映射 | 最多 40 张 / 64 个映射 |
| 单张图片 | 单帧 PNG / JPEG，不超过 2 MiB，宽高不超过 2,048 |
| 总图片像素 | 不超过 500 万 |
| 样式 | font 为 system / rounded / handwritten，pattern 为 none / diamonds |
| 数值 | 透明度 0…1，圆角 0…24，阴影透明度 0…0.5 |
| 本地皮肤数量 | 最多 30 个 |

导入生成新的 UUID，避免覆盖已有文件。皮肤保存在共享容器的 `Vime/Skins`；图片在皮肤变更时解码和缓存，不在每个按键重新读取。个人素材和皮肤包不属于 App 内置资源。

实现及格式校验见 [KeyboardSkin.swift](../../Shared/Preferences/KeyboardSkin.swift)。
