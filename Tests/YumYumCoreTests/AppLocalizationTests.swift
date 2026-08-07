import Foundation
import Testing
@testable import YumYumCore

@Suite
struct AppLocalizationTests {
    @Test
    func resolvesOnlyKoreanAsKorean() {
        #expect(AppLanguage.resolved(preferredLanguages: ["ko-KR"]) == .korean)
        #expect(AppLanguage.resolved(preferredLanguages: ["en-KR", "ko-KR"]) == .english)
        #expect(AppLanguage.resolved(preferredLanguages: []) == .english)
    }

    @Test
    func persistsExplicitChoiceAndRejectsInvalidStoredValue() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let store = AppLanguageStore(
            defaults: defaults,
            preferredLanguages: { ["ko-KR"] }
        )

        #expect(store.load() == .korean)
        store.save(.english)
        #expect(store.load() == .english)
        defaults.set("invalid", forKey: AppLanguageStore.defaultsKey)
        #expect(store.load() == .korean)
    }

    @Test
    func localizesPluralFormatting() {
        #expect(AppText.files(1, language: .english) == "1 file")
        #expect(AppText.files(2, language: .english) == "2 files")
        #expect(AppText.files(2, language: .korean) == "파일 2개")
    }

    @Test
    func coversKnownStringsAndActionOrderInBothLanguages() {
        let korean = try! Regex("[\u{AC00}-\u{D7A3}]")
        #expect(AppText.knownKoreanStrings.allSatisfy {
            AppText.localized($0, language: .english).firstMatch(of: korean) == nil
        })
        #expect(ActionBubbleAction.allCases.map { $0.title(language: .english) } == [
            "Capture", "Choose Files", "Open Chat", "Settings", "Add Clipboard to Chat",
        ])
        #expect(ActionBubbleAction.allCases.map { $0.title(language: .korean) } == [
            "캡처하기", "파일 찾기", "채팅 열기", "설정", "클립보드를 채팅에 담기",
        ])
    }

    @Test
    func safeErrorCategoryRelocalizesWithoutPassingUnknownTextThrough() {
        let english = UserFacingErrorCategory.invalidFile.message(language: .english)
        let category = UserFacingErrorRedactor.category(forSafeMessage: english)

        #expect(category == .invalidFile)
        #expect(category.message(language: .korean) == "선택한 파일을 사용할 수 없습니다. 파일 형식과 크기를 확인해 주세요.")
        #expect(UserFacingErrorRedactor.category(forSafeMessage: "token=TEST_ONLY").message(language: .korean) == "입력을 처리하지 못했습니다. 다시 시도해 주세요.")
    }
}
