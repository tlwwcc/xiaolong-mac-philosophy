import Foundation

/// 翻译引擎配置（兼容 OpenAI Chat Completions 格式）
struct TranslationConfig: Codable {
    var apiEndpoint: String = "https://api.deepseek.com/v1/chat/completions"
    var apiKey: String = ""
    var modelName: String = "deepseek-v4-flash"
    var systemPrompt: String = """
    你是一个专业翻译引擎。请将用户提供的文字翻译为{targetLanguage}。
    规则：
    1. 只输出翻译结果，不要解释
    2. 保持原文的段落和换行格式
    3. 如果原文已经是目标语言，原样返回
    4. 专业术语保留英文并附中文注释
    """

    /// 预设引擎（展示顺序固定，免费档在名称里标注）
    static let presetOrder: [String] = [
        "DeepSeek（默认）",
        "硅基流动·混元翻译（免费）",
        "硅基流动·Qwen3-8B（免费）",
        "智谱 GLM（免费）",
        "阿里云百炼",
        "OpenAI",
    ]

    static let presets: [String: (endpoint: String, model: String)] = [
        "DeepSeek（默认）": ("https://api.deepseek.com/v1/chat/completions", "deepseek-v4-flash"),
        "硅基流动·混元翻译（免费）": ("https://api.siliconflow.cn/v1/chat/completions", "tencent/Hunyuan-MT-7B"),
        "硅基流动·Qwen3-8B（免费）": ("https://api.siliconflow.cn/v1/chat/completions", "Qwen/Qwen3-8B"),
        "智谱 GLM（免费）": ("https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash-250414"),
        "阿里云百炼": ("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.7-plus"),
        "OpenAI": ("https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
    ]

    private enum CodingKeys: String, CodingKey {
        case apiEndpoint, apiKey, modelName, systemPrompt
    }

    init(
        apiEndpoint: String = "https://api.deepseek.com/v1/chat/completions",
        apiKey: String = "",
        modelName: String = "deepseek-v4-flash",
        systemPrompt: String = """
        你是一个专业翻译引擎。请将用户提供的文字翻译为{targetLanguage}。
        规则：
        1. 只输出翻译结果，不要解释
        2. 保持原文的段落和换行格式
        3. 如果原文已经是目标语言，原样返回
        4. 专业术语保留英文并附中文注释
        """
    ) {
        self.apiEndpoint = apiEndpoint
        self.apiKey = apiKey
        self.modelName = modelName
        self.systemPrompt = systemPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiEndpoint = try container.decodeIfPresent(String.self, forKey: .apiEndpoint)
            ?? "https://api.deepseek.com/v1/chat/completions"
        // 只为旧明文迁移而读；新文件永不写这个字段。
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
            ?? "deepseek-v4-flash"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? TranslationConfig().systemPrompt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiEndpoint, forKey: .apiEndpoint)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(systemPrompt, forKey: .systemPrompt)
    }
}
