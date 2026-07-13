import Testing
@testable import LocalVoice

struct TranscriptionOutputFilterTests {
    @Test func removesRussianHesitations() {
        #expect(TranscriptionOutputFilter.filter("Э-э, привет, м-м, как дела?") == "привет, как дела?")
        #expect(TranscriptionOutputFilter.filter("Я, эм, думаю, что это работает") == "Я, думаю, что это работает")
        #expect(TranscriptionOutputFilter.filter("Ммм... Хорошо") == "Хорошо")
    }

    @Test func removesUkrainianAndEnglishHesitations() {
        #expect(TranscriptionOutputFilter.filter("Е-е, це, um, працює") == "це, працює")
    }

    @Test func preservesSoundsInsideWordsAndMeaningfulSingleLetters() {
        #expect(TranscriptionOutputFilter.filter("схема і метро") == "схема і метро")
        #expect(TranscriptionOutputFilter.filter("м — позначення метра") == "м — позначення метра")
    }

    @Test func cleansSpacingAndPunctuationAfterRemovingHesitations() {
        #expect(TranscriptionOutputFilter.filter("Ну, э-э... давайте начнём") == "Ну, давайте начнём")
        #expect(TranscriptionOutputFilter.filter("Um — this, uh, works") == "this, works")
        #expect(TranscriptionOutputFilter.filter("Е-е... Гаразд!") == "Гаразд!")
    }
}
