import Foundation

enum AppLocale: String, Codable, CaseIterable {
    case en, ja, ko

    var displayName: String {
        switch self {
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
}

/// String catalogue. Each property returns the proper translation for `locale`.
/// Order (en/ja/ko) chosen so every call site stays visually consistent.
struct LocalizedStrings {
    let locale: AppLocale

    // MARK: - Popover

    var appTitle: String { "Claude Code Usage" }

    var fiveHourSession: String {
        pick("5-hour session", "5時間セッション", "5시간 세션")
    }

    var used: String { pick(" used", " 使用中", " 사용됨") }

    var weeklyQuotaTitle: String {
        pick("Weekly (7-day)", "週間 (7日)", "일주일 (7일 한도)")
    }

    var sonnetSevenDayTitle: String {
        pick("Sonnet 7-day", "Sonnet 7日", "Sonnet 7일")
    }

    var autoRefreshAction: String {
        pick("Refresh", "更新", "자동 새로고침")
    }

    var openSettings: String { pick("Open settings", "設定を開く", "설정 열기") }

    var showRawToggle: String { pick("Toggle raw output", "生データ表示切替", "원문 보기 토글") }

    var rawOutput: String { pick("Raw output", "生データ", "원문 보기") }

    var quit: String { pick("Quit", "終了", "종료") }

    var manualRefresh: String { pick("Refresh now", "今すぐ更新", "수동 새로고침") }

    // MARK: - Footer auto label

    func autoAgo(seconds: Int) -> String {
        let label = pick("Auto", "自動", "자동")
        if seconds < 60 {
            return pick("\(label) · \(seconds)s ago",
                        "\(label)・\(seconds)秒前",
                        "\(label) · \(seconds)초 전")
        }
        let minutes = seconds / 60
        return pick("\(label) · \(minutes)m ago",
                    "\(label)・\(minutes)分前",
                    "\(label) · \(minutes)분 전")
    }

    func resetSuffix(duration: String) -> String {
        pick("resets in \(duration)",
             "\(duration)後リセット",
             "\(duration) 후 리셋")
    }

    func duration(totalMinutes: Int) -> String {
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            if hours > 0 {
                return pick("\(days)d \(hours)h", "\(days)日\(hours)時間", "\(days)일 \(hours)시간")
            }
            return pick("\(days)d", "\(days)日", "\(days)일")
        }
        if hours > 0 {
            return pick("\(hours)h \(minutes)m", "\(hours)時間\(minutes)分", "\(hours)시간 \(minutes)분")
        }
        return pick("\(minutes)m", "\(minutes)分", "\(minutes)분")
    }

    var resetPending: String {
        pick("checking reset time…", "リセット時刻を確認中…", "리셋 시각 확인 중")
    }

    // MARK: - State strings

    var claudeNotFound: String {
        pick("Claude CLI not found.", "Claude CLI が見つかりません。", "Claude CLI를 찾지 못했습니다.")
    }
    var claudeTimeout: String {
        pick("Response is delayed.", "応答が遅延しています。", "응답이 지연되고 있습니다.")
    }
    var claudeParseFailed: String {
        pick("Couldn't parse output.", "出力を解析できません。", "출력을 해석하지 못했습니다.")
    }
    var claudeProcessFailed: String {
        pick("claude process failed.", "claude の実行に失敗しました。", "claude 실행 실패.")
    }

    // MARK: - Menu bar tooltip

    var menuBarTooltipTitle: String {
        pick("Claude Code session usage", "Claude Code セッション使用量", "Claude Code 세션 사용량")
    }

    func tooltipSession(_ label: String) -> String {
        pick("5-hour: \(label)", "5時間: \(label)", "5시간 세션: \(label)")
    }
    func tooltipWeekly(_ label: String) -> String {
        pick("Weekly: \(label)", "週間: \(label)", "주간: \(label)")
    }
    func tooltipSonnet(_ label: String) -> String {
        pick("Sonnet: \(label)", "Sonnet: \(label)", "Sonnet: \(label)")
    }

    // MARK: - Notifications

    func notificationTitle(threshold: Int) -> String {
        pick("Claude Code at \(threshold)%",
             "Claude Code が \(threshold)% に到達",
             "Claude Code \(threshold)% 사용 중")
    }

    func notificationBody(currentLabel: String, resetLabel: String?) -> String {
        let head = pick("Now \(currentLabel)", "現在 \(currentLabel)", "현재 \(currentLabel)")
        guard let resetLabel else { return head }
        return "\(head) · \(resetLabel)"
    }

    // MARK: - Settings window

    var settingsWindowTitle: String {
        pick("CCU Bar Settings", "CCU Bar 設定", "CCU Bar 설정")
    }

    var settingsSectionRefresh: String { pick("Refresh", "更新", "갱신") }
    var settingsRefreshInterval: String { pick("Interval", "間隔", "갱신 주기") }
    var settingsInterval30s: String { pick("30s", "30秒", "30초") }
    var settingsInterval60s: String { pick("60s", "60秒", "60초") }
    var settingsInterval5m: String { pick("5m", "5分", "5분") }

    var settingsSectionNotifications: String { pick("Notifications", "通知", "알림") }
    var settingsNotificationsToggle: String {
        pick("Alert at 75% / 90%", "75% / 90% 到達時に通知", "75% / 90% 도달 시 알림")
    }

    var settingsSectionStartup: String { pick("Startup", "起動", "시작") }
    var settingsLaunchAtLogin: String {
        pick("Launch at login", "ログイン時に起動", "로그인 시 자동 실행")
    }

    var settingsSectionLanguage: String { pick("Language", "言語", "언어") }

    var settingsSectionMenuBar: String { pick("Menu bar display", "メニューバー表示", "메뉴바 표시") }
    var settingsMenuBarNumeric: String { pick("Number", "数値のみ", "숫자만") }
    var settingsMenuBarBar: String { pick("Bar", "バーのみ", "바만") }
    var settingsMenuBarBoth: String { pick("Both", "バー + 数値", "바 + 숫자") }
    var settingsMenuBarIcon: String { pick("Show 🤖 icon", "🤖 アイコンを表示", "🤖 아이콘 표시") }

    var settingsVersionLabel: String { "CCU Bar v0.1" }

    // MARK: - Connection status chip

    var statusOnline: String { pick("Online", "オンライン", "온라인") }
    var statusOffline: String { pick("Offline", "オフライン", "오프라인") }
    var statusLoading: String { pick("Loading", "読み込み中", "로딩 중") }

    // MARK: - Data source settings

    var settingsSectionSource: String {
        pick("Data source", "データソース", "데이터 소스")
    }
    var settingsScraperPortLabel: String {
        pick("Bridge port", "ブリッジポート", "브릿지 포트")
    }
    var settingsApplyPort: String { pick("Change", "変更", "변경") }
    var settingsBridgeRunning: String { pick("Running", "稼働中", "실행 중") }
    var settingsBridgeStopped: String { pick("Stopped", "停止中", "중지됨") }
    var settingsRandomizePort: String { pick("Randomize", "ランダム", "랜덤") }
    var settingsRestartBridge: String { pick("Restart bridge", "ブリッジを再起動", "브릿지 재시작") }
    var settingsSourceHelpLocal: String {
        pick("CCU Bar polls http://127.0.0.1:<port>/api/usage served by the bundled bridge service (see bridge/ in the repo).",
             "同梱の bridge サービスが提供する http://127.0.0.1:<port>/api/usage をポーリングします (リポジトリの bridge/ フォルダを参照)。",
             "저장소의 bridge/ 폴더에 포함된 브릿지 서비스가 노출하는 http://127.0.0.1:<포트>/api/usage 를 폴링합니다.")
    }

    // MARK: - Onboarding

    var onboardingTitle: String {
        pick("Welcome to CCU Bar", "CCU Bar へようこそ", "CCU Bar에 오신 것을 환영합니다")
    }
    var onboardingIntro: String {
        pick("Pick a port and CCU Bar will start the bridge service for you.",
             "ポート番号を選ぶと CCU Bar がブリッジサービスを自動起動します。",
             "포트만 입력하면 CCU Bar가 브릿지 서비스를 자동으로 실행합니다.")
    }
    var onboardingStepLanguageIntro: String {
        pick("Choose your preferred language. You can change this later in Settings.",
             "使用する言語を選んでください。後で設定から変更できます。",
             "사용할 언어를 선택하세요. 나중에 설정에서 변경할 수 있습니다.")
    }
    var onboardingBridgeAutoStart: String {
        pick("The bridge Python service is bundled with CCU Bar. It will be launched automatically when you save a port, and it will stop when you quit the app. If you enable Launch at login, the bridge follows the app.",
             "ブリッジ (Python) は CCU Bar に同梱されています。ポートを保存すると自動起動し、アプリ終了時に停止します。ログイン時自動起動を有効にすれば、ブリッジも一緒に起動します。",
             "브릿지(Python)는 CCU Bar에 포함되어 있습니다. 포트를 저장하면 자동으로 실행되고, 앱 종료 시 함께 멈춥니다. 로그인 시 자동 실행을 켜면 브릿지도 함께 시작됩니다.")
    }
    var onboardingNext: String {
        pick("Next", "次へ", "다음")
    }
    var onboardingBack: String {
        pick("Back", "戻る", "이전")
    }
    var onboardingStartupSpawning: String {
        pick("Starting the bridge service…", "ブリッジサービスを起動中…", "브릿지 서비스 시작 중…")
    }
    var onboardingStartupWaitingPort: String {
        pick("Waiting for the port to open…", "ポートの応答を待機中…", "포트 응답 대기 중…")
    }
    var onboardingStartupCallingAPI: String {
        pick("Fetching first usage snapshot…", "最初の使用量を取得中…", "사용량 데이터 가져오는 중…")
    }
    var onboardingStartupReady: String {
        pick("Ready! Enjoy CCU Bar.", "準備完了!CCU Bar をお楽しみください。", "준비 완료! CCU Bar를 이용해주세요.")
    }
    var onboardingCompleteTitle: String {
        pick("Setup complete", "セットアップ完了", "설정 완료")
    }
    var onboardingCompleteConfirm: String {
        pick("Done", "完了", "확인")
    }
    var onboardingCompleteBody: String {
        pick("The bridge is running and CCU Bar is now polling your Claude Code usage.",
             "ブリッジが起動し、CCU Bar が Claude Code 使用量の取得を開始しました。",
             "브릿지가 실행 중이고 CCU Bar가 Claude Code 사용량을 가져오기 시작했습니다.")
    }
    var onboardingStartupFailedTitle: String {
        pick("Startup failed", "起動に失敗しました", "시작 실패")
    }
    var onboardingStartupFailedHint: String {
        pick("Check that Python 3 is installed and `pip3 install -r bridge/requirements.txt` has been run. First-launch cookie access may also require granting Full Disk Access.",
             "Python 3 がインストールされ、`pip3 install -r bridge/requirements.txt` が実行済みか確認してください。初回はクッキー読み取りのためにフルディスクアクセス権限が必要な場合があります。",
             "Python 3 가 설치되어 있고 `pip3 install -r bridge/requirements.txt` 가 실행되었는지 확인하세요. 최초 실행 시 쿠키 접근을 위해 전체 디스크 접근 권한이 필요할 수 있습니다.")
    }
    var onboardingRetry: String {
        pick("Retry", "再試行", "다시 시도")
    }
    var onboardingInstallDeps: String {
        pick("Install dependencies", "依存関係をインストール", "의존성 설치")
    }
    var onboardingInstallingProgress: String {
        pick("Installing Python dependencies…",
             "Python の依存関係をインストール中…",
             "Python 의존성 설치 중…")
    }
    var onboardingInstallSucceeded: String {
        pick("Dependencies installed. Retrying…",
             "依存関係のインストール完了。再試行します…",
             "의존성 설치 완료. 다시 시도합니다…")
    }

    // MARK: - Support section

    var settingsSectionSupport: String {
        pick("Support", "サポート", "지원")
    }
    var settingsReportIssue: String {
        pick("Report an issue", "問題を報告する", "오류 보고하기")
    }
    var settingsReportIssueHint: String {
        pick("Opens GitHub with recent logs prefilled.",
             "最近のログをプリフィルして GitHub を開きます。",
             "최근 로그를 미리 채운 GitHub 이슈 페이지를 엽니다.")
    }
    var onboardingPrimaryButton: String {
        pick("Save & Start", "保存して開始", "저장하고 시작")
    }
    var onboardingLaterButton: String {
        pick("Skip for now", "後で設定", "나중에 설정")
    }

    // MARK: - Helpers

    private func pick(_ en: String, _ ja: String, _ ko: String) -> String {
        switch locale {
        case .en: return en
        case .ja: return ja
        case .ko: return ko
        }
    }
}
