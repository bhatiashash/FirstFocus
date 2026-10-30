import FirstFocusCore
import Foundation

func registerSensitiveContentTests(_ runner: TestRunner) {
    runner.suite("isCodePattern") { r in
        r.run("a typical bank OTP message matches") {
            try expect(isCodePattern("482910 is your verification code") == true)
        }
        r.run("a message naming a code without digits does not match") {
            try expect(isCodePattern("what's the code for the front door") == false)
        }
        r.run("a digit run without a code keyword does not match") {
            try expect(isCodePattern("call me at 482910 whenever") == false)
        }
        r.run("common phrasing variants all match") {
            try expect(isCodePattern("Your OTP is 118422") == true)
            try expect(isCodePattern("G-113755 is your Google verification code") == true)
            try expect(isCodePattern("Use 5566 as your one-time passcode") == true)
        }
        r.run("ordinary conversation with a short number is not flagged") {
            try expect(isCodePattern("can you grab milk, it's like 5 bucks") == false)
        }
        r.run("case is ignored") {
            try expect(isCodePattern("482910 IS YOUR VERIFICATION CODE") == true)
        }
    }

    runner.suite("isConfidentialityTrigger") { r in
        r.run("an explicit don't-share instruction matches") {
            try expect(isConfidentialityTrigger("here's the wifi password, don't share it with anyone") == true)
        }
        r.run("a keep-between-us instruction matches") {
            try expect(isConfidentialityTrigger("just between us, I'm quitting next month") == true)
        }
        r.run("ordinary conversation does not match") {
            try expect(isConfidentialityTrigger("can you grab milk on your way home") == false)
        }
        r.run("case is ignored") {
            try expect(isConfidentialityTrigger("DON'T TELL ANYONE about this") == true)
        }
        r.run("the trigger phrase inside a longer message still matches") {
            try expect(isConfidentialityTrigger("ok cool, don't tell anyone though, see you at 5") == true)
        }
    }
}
