import Foundation

/// 按块语言判定「是否需要翻译」（中英混排"英语八级眼镜"模式）：
/// 目标语言是中文时，已是中文的块跳过翻译、跳过覆盖渲染；
/// 目标是拉丁文字语言（如英文）时反向。纯数字/标点块不翻。
/// 纯函数，无依赖，可独立编译自测。
enum LanguageClassifier {

    /// 只有能从文字本身得到明确证据时，才认定“已经是目标语言”。
    /// 误跳过会把外文原样留在图片上，所以这里宁可多翻译一次，也不猜测。
    static func confidentMatch(_ text: String, targetLanguage: Language) -> Bool {
        let evidence = ScriptEvidence(text)
        guard evidence.letterCount >= 2 else { return false }

        switch targetLanguage {
        case .auto:
            return false
        case .zhHans:
            guard !evidence.containsJapaneseKana, !evidence.containsHangul,
                  evidence.latin == 0, evidence.cjk >= 2,
                  evidence.traditionalOnly == 0, evidence.simplifiedOnly > 0 else {
                return false
            }
            // Pure kanji is inherently ambiguous: modern Japanese also shares several simplified
            // forms (for example, 学 and 会). Never let script length override the language tag.
            return evidence.dominantLanguage == "zh-Hans"
                || evidence.dominantLanguage == "zh"
        case .zhHant:
            guard !evidence.containsJapaneseKana, !evidence.containsHangul,
                  evidence.latin == 0, evidence.cjk >= 2,
                  evidence.simplifiedOnly == 0, evidence.traditionalOnly > 0 else {
                return false
            }
            return evidence.dominantLanguage == "zh-Hant"
                || evidence.dominantLanguage == "zh"
        case .en:
            guard evidence.cjk == 0, !evidence.containsJapaneseKana,
                  !evidence.containsHangul, evidence.latin >= 4,
                  !evidence.containsNonASCIILatin else { return false }
            return evidence.dominantLanguage == "en"
        case .ja:
            guard evidence.containsJapaneseKana, !evidence.containsHangul else { return false }
            return evidence.dominantLanguage == "ja" || evidence.kana >= 2
        case .ko:
            guard evidence.containsHangul, !evidence.containsJapaneseKana else { return false }
            return evidence.dominantLanguage == "ko" || evidence.hangul >= 2
        }
    }

    private struct ScriptEvidence {
        // 常见的一对多繁简字只作为“明确证据”，不是完整转换表。没有证据就 fail-open。
        private static let simplifiedOnlyCharacters = Set(
            "万与丑专业丛东丝丢两严丧个丰临为丽举么义乌乐乔习乡书买乱争于亏云亚产亩亲亵仅从仓仪们价众优会伞伟传伤伦体余侠侣侥侦侧侨俩俭债倾偿儿兑兰关兴养兽冈册写军农冲决况冻净凉减凑凤凭凯击凿划刘则刚创删别刽剂剑剧劝办务动励劳势勋匀汇汉汤沟没沧沪泞泪泻泼泽洁浅浆浇测济浑浓涂涛润涨涩淀渊渐渔湾湿溃滞滚满滤滥滨滩灭灯灵灾灿炉点炼烂争爷牍犹独狭狮现玛环电畅疗疟疡疮疯痪瘾皱盐监盖盘眯着矫矿码砖砚确碍礼祷祸离秃秆积称稳穷窝窥竞笔笋笼筑筛简粮纠纤红约级纪纬纯纱纲纳纵纷纸纹纺纽线练组细织终绍经绑绒结绕绘给绚络绝统绢继绩绪续绳维绵绷综绿缀缉缎缓编缘缚缝缠缩缴网罗罚罢羡翘耸联聪肃肠肤肾胆胜胶脏脑脚脱脸腊腻腾舱舰艺节芜苇苍苏范茧荐荡荣药莲获莹萝营萧萨葱蒋蓝蓟蔷蕴虏虑虚虫虽蚀蚁蚂蚕蛊蜗蝇蝉衅街补衬袜袭见观规觅视览觉触誉计订认讥讨让训议讯记讲讳讴讶许讹论讼设访诀证评识诈诉诊词译试诗诚话诞诡询该详语误诱说请诸诺读课谁调谅谈谋谢谣谤谨谱贝贞负贡财责贤败账货质贩贪贫购贯贱贴贵贸费贺贼贾资赋赌赏赞赵赶趋跃践跷车轨轩转轮软轰轴轻载较辅辆辈辉辑输辖辙辩边辽达迁过迈运还这进远违连迟适选逊递逻遗邮邻郑酝释里鉴钉钓钙钞钟钢钥钦钧钩钮钱钳钻铁铃铅铜铲银铸铺链销锁锅锈锋锐错锡锤锦键锯锻镇镜长门闩闪闭问闯闲间闷闸闹闻阁阀阅队阳阴阵阶际陆陈险随隐隶难雏鸡鸣鸭鸽鸿鹤鹭麦黄齐齿龙龟".unicodeScalars
        )
        private static let traditionalOnlyCharacters = Set(
            "萬與醜專業叢東絲丟兩嚴喪個豐臨為麗舉麼義烏樂喬習鄉書買亂爭於虧雲亞產畝親褻僅從倉儀們價眾優會傘偉傳傷倫體餘俠侶僥偵側僑倆儉債傾償兒兌蘭關興養獸岡冊寫軍農衝決況凍淨涼減湊鳳憑凱擊鑿劃劉則剛創刪別劊劑劍劇勸辦務動勵勞勢勳勻彙漢湯溝沒滄滬濘淚瀉潑澤潔淺漿澆測濟渾濃塗濤潤漲澀澱淵漸漁灣濕潰滯滾滿濾濫濱灘滅燈靈災燦爐點煉爛爺牘猶獨狹獅現瑪環電暢療瘧瘍瘡瘋瘓癮皺鹽監蓋盤瞇著矯礦碼磚硯確礙禮禱禍離禿稈積稱穩窮窩窺競筆筍籠築篩簡糧糾纖紅約級紀緯純紗綱納縱紛紙紋紡紐線練組細織終紹經綁絨結繞繪給絢絡絕統絹繼績緒續繩維綿繃綜綠綴緝緞緩編緣縛縫纏縮繳網羅罰罷羨翹聳聯聰肅腸膚腎膽勝膠臟腦腳脫臉臘膩騰艙艦藝節蕪葦蒼蘇範繭薦蕩榮藥蓮獲瑩蘿營蕭薩蔥蔣藍薊薔蘊虜慮虛蟲雖蝕蟻螞蠶蠱蝸蠅蟬釁補襯襪襲見觀規覓視覽覺觸譽計訂認譏討讓訓議訊記講諱謳訝許訛論訟設訪訣證評識詐訴診詞譯試詩誠話誕詭詢該詳語誤誘說請諸諾讀課誰調諒談謀謝謠謗謹譜貝貞負貢財責賢敗賬貨質販貪貧購貫賤貼貴貿費賀賊賈資賦賭賞贊趙趕趨躍踐蹺車軌軒轉輪軟轟軸輕載較輔輛輩輝輯輸轄轍辯邊遼達遷過邁運還這進遠違連遲適選遜遞邏遺郵鄰鄭醞釋裡鑒釘釣鈣鈔鐘鋼鑰欽鈞鉤鈕錢鉗鑽鐵鈴鉛銅鏟銀鑄鋪鏈銷鎖鍋鏽鋒銳錯錫錘錦鍵鋸鍛鎮鏡長門閂閃閉問闖閒間悶閘鬧聞閣閥閱隊陽陰陣階際陸陳險隨隱隸難雛雞鳴鴨鴿鴻鶴鷺麥黃齊齒龍龜".unicodeScalars
        )

        let cjk: Int
        let latin: Int
        let kana: Int
        let hangul: Int
        let simplifiedOnly: Int
        let traditionalOnly: Int
        let containsNonASCIILatin: Bool
        let dominantLanguage: String?

        var containsJapaneseKana: Bool { kana > 0 }
        var containsHangul: Bool { hangul > 0 }
        var letterCount: Int { cjk + latin + kana + hangul }

        init(_ text: String) {
            var cjk = 0, latin = 0, kana = 0, hangul = 0
            var simplifiedOnly = 0, traditionalOnly = 0
            var containsNonASCIILatin = false
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                    cjk += 1
                    if Self.simplifiedOnlyCharacters.contains(scalar) {
                        simplifiedOnly += 1
                    }
                    if Self.traditionalOnlyCharacters.contains(scalar) {
                        traditionalOnly += 1
                    }
                case 0x0041...0x005A, 0x0061...0x007A:
                    latin += 1
                case 0x00C0...0x024F:
                    latin += 1
                    containsNonASCIILatin = true
                case 0x3040...0x30FF:
                    kana += 1
                case 0xAC00...0xD7AF, 0x1100...0x11FF:
                    hangul += 1
                default:
                    break
                }
            }
            self.cjk = cjk
            self.latin = latin
            self.kana = kana
            self.hangul = hangul
            self.simplifiedOnly = simplifiedOnly
            self.traditionalOnly = traditionalOnly
            self.containsNonASCIILatin = containsNonASCIILatin

            let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
            tagger.string = text
            dominantLanguage = tagger.dominantLanguage
        }
    }

    /// 统计块内汉字与拉丁字母数量。
    /// 「汉字」只算中日韩统一表意文字 —— 日文假名/韩文音节不算，
    /// 避免把日文/韩文误判为"已是中文"而跳过翻译。
    static func cjkLatinCounts(_ text: String) -> (cjk: Int, latin: Int) {
        var cjk = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK 统一表意文字
                 0x3400...0x4DBF,   // 扩展 A
                 0xF900...0xFAFF:   // 兼容表意文字
                cjk += 1
            case 0x0041...0x005A,   // A-Z
                 0x0061...0x007A,   // a-z
                 0x00C0...0x024F:   // 拉丁扩展（含 accented 字符）
                latin += 1
            default:
                break
            }
        }
        return (cjk, latin)
    }

    /// 汉字占字母（汉字+拉丁）的比例；无字母时返回 0
    static func cjkRatio(_ text: String) -> Double {
        let counts = cjkLatinCounts(text)
        let total = counts.cjk + counts.latin
        guard total > 0 else { return 0 }
        return Double(counts.cjk) / Double(total)
    }

    /// 拉丁字母占比；无字母时返回 0
    static func latinRatio(_ text: String) -> Double {
        let counts = cjkLatinCounts(text)
        let total = counts.cjk + counts.latin
        guard total > 0 else { return 0 }
        return Double(counts.latin) / Double(total)
    }

    /// 非汉非拉丁的其他文字数量（假名/谚文/西里尔/阿拉伯/泰文等）——
    /// 这些块显然需要翻译，计入判定分母，避免被当成"无字母"跳过
    static func otherScriptCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF,   // 平假名+片假名
                 0xAC00...0xD7AF,   // 谚文音节
                 0x1100...0x11FF,   // 谚文字母
                 0x0400...0x04FF,   // 西里尔
                 0x0600...0x06FF,   // 阿拉伯
                 0x0E00...0x0E7F:   // 泰文
                count += 1
            default:
                break
            }
        }
        return count
    }

    /// 该块是否需要发给 LLM 翻译。
    /// - 纯数字/标点（任何文字都没有）→ 不翻
    /// - 只有高置信精确匹配目标语言时才跳过；不确定一律翻译
    static func shouldTranslate(_ text: String, targetLanguage: Language) -> Bool {
        // CharacterSet covers scripts not enumerated by ScriptEvidence (Greek, Hebrew, Devanagari,
        // CJK extensions, and future Unicode additions). Unknown letters must fail open to
        // translation; only true number/punctuation blocks are skipped.
        guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return false }
        return !confidentMatch(text, targetLanguage: targetLanguage)
    }
}
