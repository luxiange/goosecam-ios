import Foundation

/// 双语字符串。Android 版用 values/values-en 切换，这里用词典保持同样的文案。
struct L10n {
    let raw: String
    var isZh: Bool { raw != "en" }

    func s(_ key: String) -> String {
        let table = isZh ? L10n.zh : L10n.en
        return table[key] ?? key
    }

    func deleteSelected(_ n: Int) -> String {
        isZh ? "删除（\(n)）" : "Delete (\(n))"
    }

    func remaining(_ text: String) -> String {
        isZh ? "剩余 \(text)" : "\(text) left"
    }

    static let zh: [String: String] = [
        "app_name": "鹅相机",
        "settings_title": "设置",
        "shoot": "拍摄",
        "back": "返回",
        "gallery_title": "相册",
        "gallery_empty": "还没有照片，先拍一张吧",
        "gallery_delete": "删除",
        "multi_select": "多选",
        "select_done": "完成",
        "gallery_delete_confirm": "确定要删除这张照片吗？",
        "cancel": "取消",
        "confirm_delete": "删除",
        "choose_camera": "选择相机",
        "goose72": "E72",
        "goose72_desc": "模拟中画幅胶片相机，4:5画幅比例，色彩温润柔和，对比度偏低",
        "upcoming": "待开发",
        "import_photo": "导入照片",
        "import_desc": "把照片按 M72 风格裁切调色并加上边框",
        "import_button": "导入",
        "import_estimate": "按相机风格运算，每张约 3 秒",
        "import_done": "运算完成",
        "open_gallery": "相册",
        "import_failed": "部分照片处理失败",
        "language": "选择语言",
        "chinese": "中文",
        "english": "English",
        "about": "软件说明",
        "version": "版本",
        "updated": "更新时间",
        "developer": "开发者",
        "contact": "联系方式",
        "updated_date": "2026-11-17",
        "developer_name": "录像鹅",
        "contact_email": "18666894113@163.com",
        "permission_camera": "需要相机权限才能拍摄",
        "processing": "正在运算"
    ]

    static let en: [String: String] = [
        "app_name": "goosecam",
        "settings_title": "Settings",
        "shoot": "Shoot",
        "back": "Back",
        "gallery_title": "Gallery",
        "gallery_empty": "No photos yet. Take one first.",
        "gallery_delete": "Delete",
        "multi_select": "Select",
        "select_done": "Done",
        "gallery_delete_confirm": "Delete this photo?",
        "cancel": "Cancel",
        "confirm_delete": "Delete",
        "choose_camera": "Camera",
        "goose72": "E72",
        "goose72_desc": "Medium-format film simulation, 4:5 frame, warm soft colour, low contrast",
        "upcoming": "Coming soon",
        "import_photo": "Import photos",
        "import_desc": "Crop and grade photos in the M72 style, then add the frame",
        "import_button": "Import",
        "import_estimate": "About 3s per photo",
        "import_done": "Processing done",
        "open_gallery": "Gallery",
        "import_failed": "Some photos failed",
        "language": "Language",
        "chinese": "中文",
        "english": "English",
        "about": "About",
        "version": "Version",
        "updated": "Updated",
        "developer": "Developer",
        "contact": "Contact",
        "updated_date": "2026-11-17",
        "developer_name": "录像鹅",
        "contact_email": "18666894113@163.com",
        "permission_camera": "Camera permission is required",
        "processing": "Processing"
    ]
}
